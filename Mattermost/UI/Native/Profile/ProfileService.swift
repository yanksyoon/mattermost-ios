// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/actions/remote/user.ts (`fetchUserIfNeeded`, `setStatus`, `setCustomStatus`,
//        `unsetCustomStatus`, `getStatusesByIds`, `fetchStatusesForUserIds`),
//        app/actions/remote/channel.ts (`createDirectChannel`, `switchToChannel`).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §18; no
// upstream source copied. The protocol/implementation split is this repo's own
// (docs/component-map.md §1), matching `ChannelInfoServing` (T40) and `SearchServing` (T39).
//
// Why a protocol: every rule the card asserts about the screen — a profile is fetched rather than
// invented, a custom status write is refused locally when the server would refuse it, an auto-away
// pass does not overrule a deliberate status — has to be testable without a server. The fakes in
// `MattermostTests/T41ProfileTests.swift` implement this protocol; the class below is the only thing
// that knows about `AuthSession`/`APIClient`.

import Foundation

/// What the profile surface needs from one server.
@MainActor
protocol ProfileServing: AnyObject {
    /// `GET /users/{id}` — the whole profile, including roles, timezone and `props`.
    func profile(id: String) async throws -> MMUserProfile
    /// `POST /users/ids` — the batch read, used when a row only has an id.
    func profiles(ids: [String]) async throws -> [MMUserProfile]
    /// `POST /users/status/ids` — batched presence.
    func statuses(ids: [String]) async throws -> [MMStatus]
    /// `PUT /users/{id}/status` — my own presence, with an optional DND end time (epoch ms).
    func setPresence(_ presence: UserPresence, dndEndTime: Int64?, userID: String) async throws -> MMStatus
    /// `PUT /users/{id}/status/custom`, flat body.
    func setCustomStatus(userID: String, body: CustomStatusBody) async throws
    /// `DELETE /users/{id}/status/custom`.
    func clearCustomStatus(userID: String) async throws
    /// `POST /channels/direct`.
    func directChannel(myUserID: String, otherUserID: String) async throws -> MMChannel
    /// The avatar bytes; `nil` means the read failed — **not** "there is no picture". Measured on
    /// 9.11.19: `/users/{id}/image` answers a generated initial for an account without one (T50 §3).
    func profileImage(userID: String, lastUpdateAt: Int64) async -> Data?

    // MARK: - T50: the reader's own profile

    /// `PUT /users/{id}/patch` — save the fields the edit form changed.
    func updateProfile(userID: String, patch: MMProfilePatch) async throws -> MMUserProfile
    /// `POST /users/{id}/image` — one multipart part named `image`.
    func uploadProfileImage(userID: String, data: Data, filename: String, mimeType: String) async throws
    /// `DELETE /users/{id}/image` — back to the server's generated fallback.
    func removeProfileImage(userID: String) async throws
    /// `GET /custom_profile_attributes/fields` (S39).
    func customProfileAttributeFields() async throws -> [MMCustomProfileAttributeField]
    /// `GET /users/{id}/custom_profile_attributes`.
    func customProfileAttributeValues(userID: String) async throws -> MMCustomProfileAttributeValues
    /// `PUT /users/{id}/custom_profile_attributes`.
    func setCustomProfileAttributeValues(userID: String, values: [String: String]) async throws
}

extension ProfileServing {
    /// A service that cannot answer the batch read simply answers the single read for each id — the
    /// screen then still shows the truth, one request per row instead of one for all of them.
    func profiles(ids: [String]) async throws -> [MMUserProfile] {
        var result: [MMUserProfile] = []
        for id in ids {
            if let profile = try? await profile(id: id) { result.append(profile) }
        }
        return result
    }

    /// A service with no avatar support draws initials. Profile images are optional in Mattermost, so
    /// this is a legitimate answer rather than a degraded one.
    func profileImage(userID: String, lastUpdateAt: Int64) async -> Data? { nil }

    // T50 defaults: a service that does not implement profile editing refuses the writes rather
    // than pretending they landed. The fakes in the T41/T5449 suites do not implement them and are
    // not asked to; only the T50 tests drive these.
    func updateProfile(userID: String, patch: MMProfilePatch) async throws -> MMUserProfile {
        throw MMError.client(status: 501, message: "This service cannot edit a profile.")
    }
    func uploadProfileImage(userID: String, data: Data,
                            filename: String, mimeType: String) async throws {
        throw MMError.client(status: 501, message: "This service cannot change a profile picture.")
    }
    func removeProfileImage(userID: String) async throws {
        throw MMError.client(status: 501, message: "This service cannot remove a profile picture.")
    }
    /// No custom profile attributes: `.absent` is the correct answer for a server that has no such
    /// feature, which is exactly this default (the card: an absent section, not an empty form).
    func customProfileAttributeFields() async throws -> [MMCustomProfileAttributeField] { [] }
    func customProfileAttributeValues(userID: String) async throws -> MMCustomProfileAttributeValues {
        MMCustomProfileAttributeValues()
    }
    func setCustomProfileAttributeValues(userID: String, values: [String: String]) async throws {
        throw MMError.client(status: 501, message: "This service cannot save profile attributes.")
    }
}

/// The production implementation: the server's own `AuthSession.client`, resolved **per call** so a
/// service built before the session finished restoring is not a permanently signed-out one (the same
/// reason `SessionChannelInfoService` resolves per call).
@MainActor
final class SessionProfileService: ProfileServing {
    private let resolve: () -> APIClient?

    init(resolve: @escaping () -> APIClient?) {
        self.resolve = resolve
    }

    private func client() throws -> APIClient {
        guard let client = resolve() else { throw MMError.notSignedIn }
        return client
    }

    func profile(id: String) async throws -> MMUserProfile {
        try await client().userProfile(id: id)
    }

    func profiles(ids: [String]) async throws -> [MMUserProfile] {
        let unique = Array(Set(ids.filter { !$0.isEmpty })).sorted()
        guard !unique.isEmpty else { return [] }
        return try await client().userProfiles(ids: unique)
    }

    func statuses(ids: [String]) async throws -> [MMStatus] {
        let unique = Array(Set(ids.filter { !$0.isEmpty })).sorted()
        guard !unique.isEmpty else { return [] }
        return try await client().statuses(ids: unique)
    }

    func setPresence(_ presence: UserPresence, dndEndTime: Int64?, userID: String) async throws -> MMStatus {
        try await client().setMyStatus(presence, dndEndTime: dndEndTime, userID: userID)
    }

    func setCustomStatus(userID: String, body: CustomStatusBody) async throws {
        _ = try await client().setCustomStatus(userID: userID, body: body)
    }

    func clearCustomStatus(userID: String) async throws {
        _ = try await client().clearCustomStatus(userID: userID)
    }

    func directChannel(myUserID: String, otherUserID: String) async throws -> MMChannel {
        try await client().directChannel(userIDs: [myUserID, otherUserID])
    }

    func profileImage(userID: String, lastUpdateAt: Int64) async -> Data? {
        // The avatar is decoration: a failure draws initials, so a thrown error here is swallowed on
        // purpose rather than turned into a banner over a profile that loaded fine.
        guard let client = try? client() else { return nil }
        return await client.userProfileImage(userID: userID, lastUpdateAt: lastUpdateAt)
    }

    // MARK: - T50

    func updateProfile(userID: String, patch: MMProfilePatch) async throws -> MMUserProfile {
        try await client().updateProfile(userID: userID, patch: patch)
    }

    func uploadProfileImage(userID: String, data: Data,
                            filename: String, mimeType: String) async throws {
        try await client().uploadProfileImage(userID: userID, data: data,
                                              filename: filename, mimeType: mimeType)
    }

    func removeProfileImage(userID: String) async throws {
        try await client().removeProfileImage(userID: userID)
    }

    func customProfileAttributeFields() async throws -> [MMCustomProfileAttributeField] {
        try await client().customProfileAttributeFields()
    }

    func customProfileAttributeValues(userID: String) async throws -> MMCustomProfileAttributeValues {
        try await client().customProfileAttributeValues(userID: userID)
    }

    func setCustomProfileAttributeValues(userID: String, values: [String: String]) async throws {
        try await client().setCustomProfileAttributeValues(userID: userID, values: values)
    }
}
