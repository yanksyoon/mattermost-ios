// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/create_or_edit_channel/ (create mode: the type toggle, the display name, the
//        derived URL name, the permission-gated submit), app/actions/remote/role.ts +
//        app/queries/servers/role.ts (the permission union), app/actions/remote/channel.ts
//        (`createChannel`).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §17; no
// upstream source copied. The view-model shape is this repo's own (component-map.md §1) and mirrors
// `BrowseChannelsViewModel`: a generation guard, a service seam, and the rules kept out of the view.
//
// The card's security criterion — "offer create only when the server's permission ids for the union of
// my system+team roles include `create_public_channel` / `create_private_channel`" — is answered in two
// places on purpose:
//
//   * `menuActions` (what the sidebar's create menu draws) and `creatableKinds` (what the form's toggle
//     offers) come from `ChannelCreatePermissions.derive`, i.e. permission **ids**; and
//   * `create()` refuses to send anything when the flag for the chosen kind is false. Hiding a row is a
//     UI state; refusing the write is the guarantee. A test removes that second check and must go red
//     (docs/t47-build-note.md §4).

import Foundation
import Combine

@MainActor
final class ChannelCreateViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case loading
        case ready
        /// The permission lookup failed; the sentence is the reader's.
        case failed(String)
    }

    let teamID: String

    @Published private(set) var phase: Phase = .idle
    /// The permission ids the server answered for the union of my system and team roles.
    @Published private(set) var permissions: ChannelCreatePermissions = .none
    @Published var draft: ChannelCreateDraft
    @Published private(set) var isCreating = false
    /// A refused or failed create, in the reader's words. Never a silent no-op.
    @Published private(set) var errorMessage: String?
    /// The channel the server created (the host dismisses the sheet and navigates to it).
    @Published private(set) var createdChannel: MMChannel?

    private let service: ChannelCreationServing
    /// Bumped by every load; a late answer for an older load is dropped.
    private var generation = 0

    init(teamID: String,
         kind: ChannelInfoKind = .open,
         service: ChannelCreationServing) {
        self.teamID = teamID
        self.service = service
        self.draft = ChannelCreateDraft(kind: kind)
    }

    // MARK: Derived

    /// The create menu, ordered and gated (`ChannelCreateMenu.orderedActions`).
    var menuActions: [ChannelCreateMenuActionID] {
        ChannelCreateMenu.orderedActions(for: permissions)
    }

    /// The kinds the form may offer, in the order it draws them.
    var creatableKinds: [ChannelInfoKind] { permissions.creatableKinds }

    /// The reason the draft cannot be sent, or `nil`.
    var validationMessage: String? { draft.validation(permissions: permissions) }

    /// Whether the Create button is enabled. A validation sentence is shown *instead* of a dead button
    /// with no explanation, but the button still refuses until the draft is valid.
    var canSubmit: Bool {
        !isCreating && permissions.canCreate(draft.kind) && validationMessage == nil
    }

    /// Whether the kind toggle is drawn at all: one creatable kind means nothing to choose.
    var showsKindToggle: Bool { creatableKinds.count > 1 }

    // MARK: Loading

    /// Resolve the permission union: my system roles (`GET /users/me`), the team membership's roles, and
    /// `POST /roles/names` for both. A role the server does not answer grants nothing.
    func load() async {
        generation += 1
        let token = generation
        if phase != .ready { phase = .loading }
        errorMessage = nil
        do {
            let principal = try await service.principal()
            let teamMembership = try? await service.myTeamMembership(teamID: teamID)
            guard token == generation else { return }
            let roleNames = ChannelPermissions.roleNames(systemRoles: principal.roles,
                                                         teamRoles: teamMembership?.roles ?? "",
                                                         channelRoles: "")
            let roles = (try? await service.rolePermissions(names: roleNames)) ?? []
            guard token == generation else { return }
            let permissions = ChannelCreatePermissions.derive(from: ChannelPermissions.union(roles: roles))
            self.permissions = permissions
            // The form opens on a kind the reader may actually create. Opening on "Public" for a reader
            // who may only create private channels would draw a toggle whose first option is refused.
            if !permissions.canCreate(draft.kind), let first = permissions.creatableKinds.first {
                draft.kind = first
            }
            phase = .ready
        } catch {
            guard token == generation else { return }
            phase = .failed(ChannelInfoViewModel.copy(for: error,
                                                      fallback: "Your permissions could not be read."))
        }
    }

    // MARK: Edits

    /// Choose a kind. Refused (and explained) when the reader may not create that kind — the toggle
    /// itself only offers `creatableKinds`, so this is the second line of defence.
    func setKind(_ kind: ChannelInfoKind) {
        guard permissions.canCreate(kind) else {
            errorMessage = kind == .privateChannel
                ? "You do not have permission to create private channels on this team."
                : "You do not have permission to create public channels on this team."
            return
        }
        draft.kind = kind
        errorMessage = nil
    }

    // MARK: Create

    /// Send `POST /channels`.
    ///
    /// - Returns: the server's channel, or `nil` when nothing was sent or the write failed. The caller
    ///   navigates only on a channel.
    @discardableResult
    func create() async -> MMChannel? {
        guard !isCreating else { return nil }
        // The gate. Not decoration: the menu and the toggle are UI state, this is the check that the
        // request is only ever made by a reader the server would allow.
        guard permissions.canCreate(draft.kind) else {
            errorMessage = draft.kind == .privateChannel
                ? "You do not have permission to create private channels on this team."
                : "You do not have permission to create public channels on this team."
            return nil
        }
        if let validationMessage {
            errorMessage = validationMessage
            return nil
        }
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        do {
            let channel = try await service.createChannel(draft.body(teamID: teamID))
            guard !channel.id.isEmpty else {
                errorMessage = "The server answered a channel without an id."
                return nil
            }
            // A create answers the channel itself; anything but the requested kind means the server
            // stored something this screen did not ask for, and navigating there would be a lie.
            if !channel.type.isEmpty, channel.type != draft.kind.rawValue {
                errorMessage = "The server answered a channel this app did not ask for."
                return nil
            }
            createdChannel = channel
            return channel
        } catch {
            errorMessage = Self.copy(for: error)
            return nil
        }
    }

    /// Forget the created channel once the host has navigated (a re-presented sheet must not re-open it).
    func consumeCreatedChannel() { createdChannel = nil }

    /// The failure copy. The duplicate-name case is the one a reader can act on, and the server's own
    /// sentence for it is already exact ("A channel with that name already exists on the same team."),
    /// so a `400`'s message is preferred over a generic one.
    static func copy(for error: Error) -> String {
        if case .client(let status, let message) = error as? MMError ?? .notFound {
            if status == 400, let message, !message.isEmpty { return message }
        }
        return MMErrorCopy.message(
            for: error,
            offline: "You appear to be offline. The channel was not created.",
            timeout: "The server took too long to answer. The channel was not created.",
            unauthorized: "Your session has expired. Sign in again to create a channel.",
            forbidden: "You do not have permission to create a channel on this team.",
            notFound: "That team no longer exists.",
            rateLimited: "The server is busy. Try again shortly.",
            fallback: "The channel could not be created."
        )
    }
}

// MARK: - The direct-message picker

/// The "Create a direct message" sheet's model.
///
/// Two sources, the same split as T40's add-members picker: `GET /users?in_team=` for the opening list
/// (`POST /users/search` refuses an empty term, measured) and `POST /users/search` once a term is typed.
/// A tap **is** the action — there is no second "Start" button, because the row already names the person
/// the conversation would be with.
@MainActor
final class NewDirectMessageViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    let teamID: String

    @Published var term: String = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var rows: [DirectMessageCandidate] = []
    @Published private(set) var isOpening = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var openedChannel: MMChannel?

    private let service: ChannelCreationServing
    private var myUserID: String?
    private var users: [String: MMUser] = [:]
    private var statuses: [String: MMStatus] = [:]
    private var generation = 0

    init(teamID: String, service: ChannelCreationServing) {
        self.teamID = teamID
        self.service = service
    }

    var emptyCopy: String {
        term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Nobody else is on this team."
            : "No one here matches “\(term)”."
    }

    // MARK: Loading

    func load() async {
        generation += 1
        let token = generation
        if phase != .ready { phase = .loading }
        do {
            let principal = try? await service.principal()
            guard token == generation else { return }
            myUserID = principal?.id
            let page = try await service.teamMembers(teamID: teamID, page: 0,
                                                     perPage: service.pickerPageSizeForPeople)
            guard token == generation else { return }
            await absorb(page, token: token)
            phase = .ready
        } catch {
            guard token == generation else { return }
            phase = .failed(ChannelInfoViewModel.copy(for: error,
                                                      fallback: "People could not be loaded."))
        }
    }

    /// A typed search, or back to the team list when the field is cleared.
    func search(_ term: String) async {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await load()
            return
        }
        generation += 1
        let token = generation
        if phase != .ready { phase = .loading }
        do {
            let people = try await service.searchTeamMembers(teamID: teamID,
                                                             term: trimmed,
                                                             page: 0,
                                                             perPage: service.pickerPageSizeForPeople)
            guard token == generation else { return }
            // A failed/empty search must not leave the previous term's people tappable.
            users = [:]
            await absorb(people, token: token)
            phase = .ready
        } catch {
            guard token == generation else { return }
            users = [:]
            rows = []
            phase = .failed(ChannelInfoViewModel.copy(for: error,
                                                      fallback: "That search could not be run."))
        }
    }

    // MARK: Open

    /// `POST /channels/direct` with me and this person; answers the conversation to navigate to.
    @discardableResult
    func open(_ candidate: DirectMessageCandidate) async -> MMChannel? {
        guard !isOpening else { return nil }
        guard let myUserID, !myUserID.isEmpty else {
            errorMessage = "You appear to be signed out. Please sign in again."
            return nil
        }
        guard candidate.id != myUserID else {
            errorMessage = "A conversation needs somebody else on the other side."
            return nil
        }
        isOpening = true
        errorMessage = nil
        defer { isOpening = false }
        do {
            let channel = try await service.createDirectChannel(userIDs: [myUserID, candidate.id])
            guard !channel.id.isEmpty else {
                errorMessage = "The server answered a conversation without an id."
                return nil
            }
            guard channel.type.isEmpty || channel.type == ChannelInfoKind.direct.rawValue else {
                errorMessage = "The server answered a channel this app cannot open as a conversation."
                return nil
            }
            openedChannel = channel
            return channel
        } catch {
            errorMessage = MMErrorCopy.message(
                for: error,
                offline: "You appear to be offline. The conversation was not created.",
                timeout: "The server took too long to answer. The conversation was not created.",
                unauthorized: "Your session has expired. Sign in again to send a message.",
                forbidden: "You do not have permission to message this account.",
                notFound: "That account no longer exists.",
                rateLimited: "The server is busy. Try again shortly.",
                fallback: "The conversation could not be created."
            )
            return nil
        }
    }

    func consumeOpenedChannel() { openedChannel = nil }

    // MARK: Helpers

    private func absorb(_ people: [MMUser], token: Int) async {
        for user in people { users[user.id] = user }
        let identifiers = people.map(\.id)
        let presence = await service.statusesOrEmpty(ids: identifiers)
        guard token == generation else { return }
        for status in presence { statuses[status.userId] = status }
        rows = DirectMessageDerivation.rows(users: Array(users.values),
                                            statuses: statuses,
                                            myUserID: myUserID,
                                            term: term)
    }
}
