// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/channel_add_members/channel_add_members.tsx (the field, the paged list, the
//        multi-select set, the Add button, and the transition into the channel), and
//        app/client/rest/users.ts (`getProfilesNotInChannel`, `searchProfiles`).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §17; no
// upstream source copied.
//
// Two rules from upstream are worth stating because they are easy to get wrong:
//
//  1. The picker **opens on a list**, not on a search: `POST /users/search` refuses an empty term
//     (`400 Invalid or missing term`, measured), so an empty field must list
//     `GET /users?in_team=&not_in_channel=` instead.
//  2. Selection is a **set** across pages and across refinements of the term — a reader who types,
//     selects somebody, then clears the field must not lose the selection (upstream keeps the selected
//     ids in state and merges them into the "chosen" list above the results).
//
// This view model performs **no writes**: it answers "who could be added" and "who did the reader
// choose", and hands the ids to `ChannelInfoViewModel.addMembers`, so the permission gate and the
// optimistic row live in one place.

import Foundation
import Combine

@MainActor
final class AddMembersViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case loading
        case ready
        /// The list could not be read; the sentence is the reader's.
        case failed(String)
    }

    /// One candidate row.
    struct Candidate: Identifiable, Equatable {
        var id: String
        var displayName: String
        var username: String
        var initials: String
    }

    let channelID: String
    let teamID: String

    @Published var term: String = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var rows: [Candidate] = []
    @Published private(set) var selection: Set<String> = []
    /// The rows the reader chose, kept so a term change does not lose them (upstream's chosen list).
    @Published private(set) var selectedRows: [Candidate] = []
    @Published private(set) var hasMore = false
    @Published private(set) var isLoadingMore = false

    private let service: ChannelInfoServing
    private var page = 0
    /// Every list/search bumps this; a late answer for an older request is dropped (a fast typist must
    /// not see the results of the term they already replaced).
    private var generation = 0
    private var profiles: [String: MMUser] = [:]

    init(channelID: String, teamID: String, service: ChannelInfoServing) {
        self.channelID = channelID
        self.teamID = teamID
        self.service = service
    }

    var canSubmit: Bool { !selection.isEmpty }
    var submitTitle: String {
        selection.count == 1 ? "Add 1 member" : "Add \(selection.count) members"
    }
    var emptyCopy: String {
        term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Everyone in this team is already in this channel."
            : "No one here matches “\(term)”."
    }

    /// The profiles behind the selection, so the info screen can draw the optimistic rows with real
    /// names instead of ids.
    var selectedProfiles: [String: MMUser] { profiles.filter { selection.contains($0.key) } }
    var selectedIDs: [String] { selectedRows.map(\.id) }

    // MARK: Loading

    /// The opening list: team members who are not in this channel.
    func load() async {
        generation += 1
        let token = generation
        if phase != .ready { phase = .loading }
        page = 0
        do {
            let users = try await service.usersNotInChannel(teamID: teamID,
                                                            channelID: channelID,
                                                            page: 0,
                                                            perPage: service.pickerPageSize)
            guard token == generation else { return }
            absorb(users)
            page = 1
            hasMore = users.count >= service.pickerPageSize
            phase = .ready
        } catch {
            guard token == generation else { return }
            phase = .failed(ChannelInfoViewModel.copy(for: error,
                                                      fallback: "People could not be loaded."))
        }
    }

    /// A typed search, or back to the opening list when the field is cleared.
    func search(_ term: String) async {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await load()
            return
        }
        generation += 1
        let token = generation
        if phase != .ready { phase = .loading }
        page = 0
        do {
            let users = try await service.searchUsersNotInChannel(teamID: teamID,
                                                                  channelID: channelID,
                                                                  term: trimmed)
            guard token == generation else { return }
            absorb(users)
            page = 1
            hasMore = users.count >= service.pickerPageSize
            phase = .ready
        } catch {
            guard token == generation else { return }
            // A failed search is an empty result list with a sentence, never a stale list of the
            // previous term's people (that would let somebody be added by accident).
            rows = []
            hasMore = false
            phase = .failed(ChannelInfoViewModel.copy(for: error,
                                                      fallback: "That search could not be run."))
        }
    }

    /// The next page of the same question (list or term).
    func loadMore() async {
        guard hasMore, !isLoadingMore, phase == .ready else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let token = generation
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let users: [MMUser]
            if trimmed.isEmpty {
                users = try await service.usersNotInChannel(teamID: teamID,
                                                            channelID: channelID,
                                                            page: page,
                                                            perPage: service.pickerPageSize)
            } else {
                // The search endpoint in this client is single-page (the picker caps its own list), so
                // "more" for a search is honestly "no more".
                users = []
            }
            guard token == generation else { return }
            absorb(users)
            page += 1
            hasMore = users.count >= service.pickerPageSize
        } catch {
            guard token == generation else { return }
            hasMore = false
        }
    }

    // MARK: Selection

    func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
            selectedRows.removeAll { $0.id == id }
        } else {
            selection.insert(id)
            if let row = rows.first(where: { $0.id == id }) { selectedRows.append(row) }
        }
    }

    func isSelected(_ id: String) -> Bool { selection.contains(id) }

    /// Clear the selection after a successful add.
    func clearSelection() {
        selection = []
        selectedRows = []
    }

    // MARK: Helpers

    private func absorb(_ users: [MMUser]) {
        for user in users { profiles[user.id] = user }
        // The selected ids the reader already has stay at the top (upstream's "chosen" block) and are
        // not repeated in the results below it.
        let selectedIDs = selection
        rows = users
            .filter { !selectedIDs.contains($0.id) }
            .map { user in
                Candidate(id: user.id,
                          displayName: PostListDerivation.displayName(for: user),
                          username: user.username,
                          initials: ChannelMemberDerivation.initials(PostListDerivation.displayName(for: user)))
            }
    }
}
