// T5449 C3 — the channel picker upstream opens from "Add to a Channel"
// (`mattermost/mattermost` v9.11.0,
// `webapp/channels/src/components/add_user_to_channel_modal/add_user_to_channel_modal.tsx`).
//
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §18; no
// upstream source copied.
//
// ## The shape, and why it is not "add to this channel"
//
// The card this surface comes from assumed the profile sheet needed the *pane's* channel injected.
// Upstream's row is **team-scoped** and opens a **picker**: the list is my channels on the current
// team, narrowed to the ones whose members I may manage
// (`ChannelInfoCapabilities.canManageMembers`), and the reader chooses where the account goes
// (`docs/t_8f9f5449-profile-popover-parity.md` §1, §6).
//
// The rules this model exists to keep:
//
//  1. **The list is proved, not guessed.** It comes from `ChannelMemberAdminAnswer`, i.e. from
//     `GET /users/me/teams/{tid}/channels` + my channel roles + my system/team roles resolved to
//     permission ids. A service that answers nothing yields an empty answer, and an empty answer
//     offers an empty list — never "everything".
//  2. **Membership is asked per channel, once.** Selecting a row reads
//     `GET /channels/{id}/members/{userID}`: `200` means "already a member" (Add stays disabled and
//     the row says so), `404` means "not a member" (Add is enabled). Any other failure is a banner,
//     not a guess.
//  3. **The write is optimistic and rolls back.** Add shows the row as a member immediately — the
//     shape `ChannelInfoViewModel.addMembers` uses — and on failure puts it back and names what
//     failed. A membership is a promise to the reader; showing one the server rejected is worse
//     than showing a spinner.

import Foundation
import Combine

/// One row of the picker.
struct AddToChannelRow: Identifiable, Equatable {
    let channelID: String
    let title: String
    let kind: ChannelInfoKind
    /// `true` = the account is already in it, `false` = confirmed not in it, `nil` = not asked yet.
    var isMember: Bool?

    var id: String { channelID }

    /// What the row says beside its name: the kind of channel, and the membership once known.
    var subtitle: String {
        if isMember == true { return "Member" }
        return kind.typeLabel
    }
}

@MainActor
final class AddToChannelPickerViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let serverID: UUID
    let teamID: String
    /// The signed-in account (whose channel roles are the ones that matter).
    let myUserID: String
    /// The account being added.
    let userID: String
    /// Their name, for the sentences ("Alice is already a member of this channel.").
    let userDisplayName: String

    private let service: ChannelInfoServing
    private let now: () -> Date

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var rows: [AddToChannelRow] = []
    /// The search field's text (upstream's `search_channel_with_permissions_provider` equivalent).
    @Published var query = ""
    @Published private(set) var selectedID: String?
    @Published private(set) var isSubmitting = false
    @Published private(set) var banner: String?
    /// When the list was read — drawn by nothing, kept so a later "refresh" has something to age.
    private(set) var loadedAt: Date?

    init(serverID: UUID,
         teamID: String,
         myUserID: String,
         userID: String,
         userDisplayName: String,
         service: ChannelInfoServing,
         now: @escaping () -> Date = Date.init) {
        self.serverID = serverID
        self.teamID = teamID
        self.myUserID = myUserID
        self.userID = userID
        self.userDisplayName = userDisplayName
        self.service = service
        self.now = now
    }

    // MARK: Derived

    /// The rows the search field leaves visible.
    var visibleRows: [AddToChannelRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rows }
        return rows.filter { $0.title.localizedCaseInsensitiveContains(needle) }
    }

    var selectedRow: AddToChannelRow? {
        guard let selectedID else { return nil }
        return rows.first { $0.channelID == selectedID }
    }

    /// Add is offered only when the answer proved the account is **not** already there.
    var canSubmit: Bool {
        guard let selectedRow, !isSubmitting else { return false }
        return selectedRow.isMember == false
    }

    /// The sentence the picker shows under a row the account is already in (and why Add is off).
    var alreadyMemberMessage: String? {
        guard let selectedRow, selectedRow.isMember == true else { return nil }
        let name = userDisplayName.isEmpty ? "This account" : userDisplayName
        return "\(name) is already a member of this channel."
    }

    /// A copy of the rows for a given answer — the pure half of the filter, so a test can pin it
    /// without a service.
    static func rows(from answer: ChannelMemberAdminAnswer) -> [AddToChannelRow] {
        answer.manageableChannels.map { channel in
            AddToChannelRow(channelID: channel.id,
                            title: channel.displayName.isEmpty ? channel.name : channel.displayName,
                            kind: ChannelInfoKind(raw: channel.type),
                            isMember: nil)
        }
    }

    // MARK: Load

    /// Fill the list. A cached team answer (`ProfileCoordinator`'s `ChannelMemberAdminDirectory`) is
    /// used when there is one — the profile row that opened this screen was drawn from it.
    func load(answer: ChannelMemberAdminAnswer? = nil) async {
        guard phase != .loaded else { return }
        phase = .loading
        banner = nil
        do {
            let resolved: ChannelMemberAdminAnswer
            if let answer {
                resolved = answer
            } else {
                resolved = try await ChannelMemberAdminDirectory.resolve(service: service,
                                                                         teamID: teamID,
                                                                         myUserID: myUserID)
            }
            rows = Self.rows(from: resolved)
            loadedAt = now()
            phase = .loaded
        } catch {
            phase = .failed(Self.loadFailureCopy(error))
        }
    }

    // MARK: Selection

    /// Select a row and ask the server whether the account is already in it.
    ///
    /// Answered once per row: a second tap on a row whose membership is known does not re-ask.
    func select(_ channelID: String) async {
        selectedID = channelID
        banner = nil
        guard let index = rows.firstIndex(where: { $0.channelID == channelID }) else { return }
        guard rows[index].isMember == nil else { return }
        do {
            _ = try await service.member(channelID: channelID, userID: userID)
            update(at: index) { $0.isMember = true }
        } catch MMError.notFound {
            update(at: index) { $0.isMember = false }
        } catch {
            // Unknown stays unknown: neither "already a member" nor "ready to add" is a claim this
            // screen has earned.
            banner = Self.copy(for: error,
                               offline: "You appear to be offline, so this channel could not be checked.",
                               fallback: "This channel could not be checked.")
        }
    }

    /// Add the account to the selected channel. Returns whether the write landed.
    @discardableResult
    func add() async -> Bool {
        guard let selectedRow, let index = rows.firstIndex(where: { $0.channelID == selectedRow.channelID })
        else { return false }
        guard rows[index].isMember == false, !isSubmitting else { return false }
        isSubmitting = true
        banner = nil
        // Optimistic: the row says "Member" and Add disables, while the write is in flight.
        update(at: index) { $0.isMember = true }
        do {
            _ = try await service.addMember(channelID: selectedRow.channelID, userID: userID)
            isSubmitting = false
            return true
        } catch {
            update(at: index) { $0.isMember = false }
            isSubmitting = false
            banner = Self.copy(for: error,
                               offline: "You appear to be offline, so \(nameForSentence) was not added.",
                               fallback: "\(nameForSentence) could not be added to that channel.")
            return false
        }
    }

    func consumeBanner() { banner = nil }

    // MARK: Internals

    private var nameForSentence: String {
        userDisplayName.isEmpty ? "this account" : userDisplayName
    }

    private func update(at index: Int, _ change: (inout AddToChannelRow) -> Void) {
        guard rows.indices.contains(index) else { return }
        var row = rows[index]
        change(&row)
        rows[index] = row
    }

    private static func copy(for error: Error, offline: String, fallback: String) -> String {
        MMErrorCopy.message(for: error,
                            offline: offline,
                            timeout: "The server took too long to answer.",
                            unauthorized: "Your session has expired. Sign in again.",
                            forbidden: "You do not have permission to manage that channel's members.",
                            notFound: "That channel no longer exists.",
                            rateLimited: "The server is busy. Try again shortly.",
                            fallback: fallback)
    }

    static func loadFailureCopy(_ error: Error) -> String {
        MMErrorCopy.message(for: error,
                            offline: "You appear to be offline, so the channel list could not be read.",
                            timeout: "The server took too long to answer.",
                            unauthorized: "Your session has expired. Sign in again.",
                            forbidden: "You do not have permission to see this team's channels.",
                            notFound: "That team no longer exists on this server.",
                            rateLimited: "The server is busy. Try again shortly.",
                            fallback: "The channel list could not be read.")
    }
}
