// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
//   app/actions/remote/notifications.ts  `openNotification` / `fetchNotificationData` (the tap path and
//                                        the four `emitNotificationError` outcomes),
//   app/actions/remote/channel.ts        `fetchMyChannel` (the channel + membership pair),
//   app/utils/notification/index.ts      `notificationError` (the sentences this file's caller shows),
//   app/actions/remote/entry/notification.ts (403 → team/channel copy, anything else → connection copy).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §3; no
// upstream source copied. The two-probe shape and this decomposition are this repo's own.
//
// Why a resolver at all: `NotificationWorker.route(userInfo:)` owns the tap, but the answer to "is this
// conversation still mine?" belongs to the objects that hold the data — the sidebar's channel list
// (local, free) and the session's client (remote, measured). This type is the one place those two are
// joined, so the worker's routing table stays a table a unit test can read.

import Foundation

/// The app's `NotificationTapResolving`.
///
/// Two answers, in the order that keeps a tap cheap:
///  1. **local** — the channel list the sidebar already loaded knows every conversation the account is
///     in, so a tap on a live channel costs no request at all;
///  2. **remote** — only when the list cannot speak (another team, nothing loaded, a DM): upstream's
///     `fetchMyChannel` pair, `GET /channels/{id}/members/me` + `GET /channels/{id}` for `delete_at`,
///     and for a thread mention `GET /posts/{root_id}`.
///
/// Every status here was measured against Mattermost 9.11.19 by
/// `scripts/t14c_notification_tap_probe.py` — including the two that surprise a reading of the API:
/// the membership probe answers `403` (not `404`) to an ordinary account that is not in a channel, and
/// `GET /channels/{id}` answers `200` to anyone for a public channel, so *membership* is the decisive
/// question and the channel fetch only contributes `delete_at`.
@MainActor
final class SessionNotificationTapResolver: NotificationTapResolving {

    /// The session owner: the tap's probes go through the server's own `APIClient`, so a `401` reaches
    /// the same re-auth funnel every other authenticated call uses (and never a second token source).
    weak var auth: AuthCoordinator?
    weak var serverStore: ServerStore?
    /// The loaded channel list. A webview-rendered shell (Path A) has none, answers `.unknown`, and the
    /// tap then asks the server — which is the correct cost there: the page holds the list, not us.
    weak var directory: (any NativeChannelDirectory)?

    /// The client a probe goes through. `nil` (production) resolves the server's own session; a test
    /// supplies a client over a scripted transport, so the status → state table below is exercised
    /// without a vault, a session or a network.
    var clientProvider: ((UUID) -> APIClient?)?

    init(auth: AuthCoordinator? = nil,
         serverStore: ServerStore? = nil,
         directory: (any NativeChannelDirectory)? = nil) {
        self.auth = auth
        self.serverStore = serverStore
        self.directory = directory
    }

    // MARK: - Local (no request)

    func localMembership(serverID: UUID, channelID: String,
                         teamID: String?) -> NotificationChannelMembership {
        directory?.membership(serverID: serverID, channelID: channelID, teamID: teamID) ?? .unknown
    }

    // MARK: - Remote (only when the local answer is `.unknown`)

    func remoteMembership(serverID: UUID, channelID: String) async -> NotificationChannelMembership {
        guard let client = client(for: serverID) else { return .unknown }

        do {
            _ = try await client.channelMember(channelID: channelID)
        } catch {
            return Self.membershipFailure(error)
        }

        // In the channel. Archival is **not** a "gone" signal: the pane draws the composer's own
        // archived banner ("You are viewing an archived channel. New messages cannot be posted.") and
        // upstream's `fetchMyChannel` navigates into it too. What is gone is a channel that no longer
        // answers at all — its membership row outlives the channel.
        do {
            _ = try await client.channel(id: channelID, useETag: false)
            return .member
        } catch {
            guard let mm = error as? MMError else { return .member }
            switch mm {
            case .notFound:
                return .gone
            case .unauthorized, .notSignedIn:
                return .sessionExpired
            default:
                // The membership is proven. A second probe failing must not dead-end a tap that is
                // otherwise fine — the pane will show the channel's own error if there is one.
                return .member
            }
        }
    }

    func postState(serverID: UUID, postID: String) async -> NotificationPostState {
        guard let client = client(for: serverID), !postID.isEmpty else { return .unknown }
        do {
            let post = try await client.post(id: postID, useETag: false)
            return post.deleteAt == 0 ? .exists : .gone
        } catch {
            guard let mm = error as? MMError else { return .unknown }
            switch mm {
            case .notFound:
                // Measured: a soft-deleted post and an id that never existed answer the same
                // `404 app.post.get.app_error`, so a tap on either is "the message has not been found".
                return .gone
            case .forbidden:
                return .notPermitted
            case .unauthorized, .notSignedIn:
                return .sessionExpired
            case .offline, .timeout, .transport, .certificateUntrusted:
                return .unreachable
            default:
                return .unknown
            }
        }
    }

    // MARK: - Plumbing

    private func client(for serverID: UUID) -> APIClient? {
        if let clientProvider { return clientProvider(serverID) }
        guard let auth,
              let server = serverStore?.servers.first(where: { $0.id == serverID }),
              let session = try? auth.session(for: server) else { return nil }
        return session.client
    }

    /// A membership probe's failure, in the words the tap fallback uses.
    ///
    /// `404 app.channel.get_member.missing.app_error` and `403 api.context.permissions.app_error` are
    /// **the same answer to the reader** — "you are not in it" — and both were measured for a channel
    /// the account is not in: the 404 as a system admin, the 403 as an ordinary account (and for a
    /// channel id that does not exist at all).
    nonisolated static func membershipFailure(_ error: Error) -> NotificationChannelMembership {
        guard let mm = error as? MMError else { return .unknown }
        switch mm {
        case .notFound, .forbidden:
            return .notMember
        case .unauthorized, .notSignedIn:
            return .sessionExpired
        case .offline, .timeout, .transport, .certificateUntrusted:
            return .unreachable
        default:
            return .unknown
        }
    }
}
