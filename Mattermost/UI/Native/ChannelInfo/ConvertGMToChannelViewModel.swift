// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/convert_gm_to_channel/convert_gm_to_channel.tsx (the two reads that gate the
//        form: `fetchGroupMessageMembersCommonTeams` and `fetchChannelMemberships`, and the loading
//        phase between them), convert_gm_to_channel_form.tsx (the selected team, the name, the
//        submit-enabled rule, the duplicate-name error and `switchToChannelById` on success),
//        app/actions/remote/channel.ts (`convertGroupMessageToPrivateChannel`).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §25; no
// upstream source copied. The view-model shape is this repo's own (component-map.md §1) and mirrors
// `ChannelCreateViewModel`: a generation guard, a service seam, and the rules kept out of the view.
//
// The card's two acceptance criteria map here:
//   * **the gate** — `isAvailable` is `ConvertGMToChannelGate` over the channel type, the guest flag and
//     the server release, and `convert()` refuses to send anything when it is false. Hiding the row is a
//     UI state; refusing the write is the guarantee;
//   * **the body** — `draft.body(channelID:)`, whose `name` comes from `ChannelNameRule` (the same rule
//     `CreateChannelDraft` uses), frozen before the `await` so the request and the answer are compared
//     against the same capture.
//
// Two reads gate the form, as upstream's 1.2 s loading phase does:
//   1. `GET /channels/{id}/common_teams` — **the** gate: no shared team means no conversion, and the
//      screen says why instead of offering a form the server would refuse (`incorrect_team`);
//   2. the conversation's members — the warning names them ("with Alice, Bob and Carol").

import Foundation
import Combine

@MainActor
final class ConvertGMToChannelViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case loading
        case ready
        /// The members share no team: the screen shows the "cannot be converted" state, not a form.
        case noCommonTeams
        case failed(String)
    }

    /// The conversation being converted, as the info screen read it.
    let channel: MMChannel
    /// The server's release, as `ConvertGMToChannelGate` needs it. Empty is "unknown".
    let serverVersion: String
    /// Whether I am a guest on this server (upstream's `!guest` clause).
    let isGuest: Bool

    @Published private(set) var phase: Phase = .idle
    /// The teams every member belongs to (`GET …/common_teams`), in the server's order.
    @Published private(set) var teams: [MMTeam] = []
    /// The other people in the conversation, by display name, for the warning. Sorted, deduplicated.
    @Published private(set) var memberNames: [String] = []
    @Published var draft = ConvertGMToChannelDraft()
    @Published private(set) var isConverting = false
    /// A failure the screen draws on its own line (anything that is not a field-level answer).
    @Published private(set) var errorMessage: String?
    /// The duplicate-name sentence, drawn under the name field.
    @Published private(set) var nameErrorMessage: String?
    /// The "members are not all on this team" sentence, drawn under the team row.
    @Published private(set) var teamErrorMessage: String?
    /// The converted channel, once the server answered. The host navigates on it.
    @Published private(set) var convertedChannel: MMChannel?
    /// Where the host should land, once `convertedChannel` is set.
    @Published private(set) var target: ConvertedChannelTarget?

    private let service: ChannelConversionServing
    /// The in-flight registry the socket router reads (upstream's `EphemeralStore`).
    ///
    /// `nil` in a unit test that only exercises the form: the three calls are then no-ops, and the
    /// screen still works. The shell passes `NativeNavigation`.
    private let conversions: ChannelConversionTracking?
    private var myUserID: String?
    private var generation = 0

    init(channel: MMChannel,
         isGuest: Bool,
         serverVersion: String?,
         service: ChannelConversionServing,
         conversions: ChannelConversionTracking? = nil) {
        self.channel = channel
        self.isGuest = isGuest
        self.serverVersion = serverVersion ?? ""
        self.service = service
        self.conversions = conversions
    }

    // MARK: Derived

    /// The gate. Off for a direct message, a public/private channel, a guest, an archived conversation,
    /// and a server older than 9.1 — the same four facts upstream consults.
    var isAvailable: Bool {
        ConvertGMToChannelGate.isAvailable(kind: ChannelInfoKind(raw: channel.type),
                                           isGuest: isGuest,
                                           isArchived: channel.deleteAt != 0,
                                           serverVersion: serverVersion)
    }

    /// The warning line: the conversation's other members, in upstream's list form.
    var warningBody: String { ConvertGMToChannelCopy.warningBody(memberNames: memberNames) }

    /// Whether the team row is drawn. Upstream draws it only when there is a choice to make
    /// (`commonTeams.length > 1`); a single common team is preselected and not shown.
    var showsTeamPicker: Bool { teams.count > 1 }

    /// The team the form will convert into, as a row label.
    var selectedTeamName: String {
        guard let teamID = draft.teamID, let team = teams.first(where: { $0.id == teamID }) else {
            return teams.first?.displayName ?? ""
        }
        return team.displayName.isEmpty ? team.name : team.displayName
    }

    /// The reason the draft cannot be sent, or `nil`. Permission-independent: the gate is checked
    /// separately (and again inside `convert()`).
    var validationMessage: String? { draft.validation(teams: teams) }

    /// The note actually drawn under the name field.
    ///
    /// Empty on arrival: nothing has been typed yet, so the disabled button is the whole "you must name
    /// it" signal and a red line under an untouched field is noise (upstream's `channel_name_input`
    /// draws its error only once the reader has typed). Anything typed — valid or not — is judged.
    var visibleValidationMessage: String? {
        draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : validationMessage
    }

    /// Whether the submit button is enabled.
    var canSubmit: Bool {
        !isConverting && isAvailable && phase == .ready && validationMessage == nil
    }

    // MARK: Load

    /// Read the shared teams and the conversation's members, then preselect the first team.
    ///
    /// The teams read is the only **required** answer: without it there is no target team, and the
    /// screen is either the "no common team" state (an empty answer) or a failure with a Retry (a read
    /// that did not happen) — never a form the server would refuse.
    func load() async {
        generation += 1
        let token = generation
        if phase != .ready && phase != .noCommonTeams { phase = .loading }
        errorMessage = nil
        nameErrorMessage = nil
        teamErrorMessage = nil

        do {
            let teams = try await service.commonTeams(channelID: channel.id)
            guard token == generation else { return }
            self.teams = teams.filter { $0.deleteAt == 0 }
            if self.teams.isEmpty {
                phase = .noCommonTeams
                await loadMemberNames(token: token)
                return
            }
            if draft.teamID == nil { draft.teamID = self.teams.first?.id }
            phase = .ready
        } catch {
            guard token == generation else { return }
            phase = .failed(ChannelInfoViewModel.copy(for: error,
                                                      fallback: "The teams this conversation could be "
                                                          + "converted into could not be read."))
            return
        }
        await loadMemberNames(token: token)
    }

    /// The other people in the conversation. A failure is an empty list, never an invented name:
    /// the warning then says "yourself", which is upstream's answer for an unnamed conversation.
    private func loadMemberNames(token: Int) async {
        let members = await (try? service.members(channelID: channel.id, page: 0, perPage: 200)) ?? []
        guard token == generation else { return }
        if let principal = try? await service.principal() { myUserID = principal.id }
        guard token == generation else { return }
        let others = members.map(\.userId).filter { $0 != myUserID }
        guard !others.isEmpty else {
            memberNames = []
            return
        }
        let profiles = await (try? service.users(ids: others)) ?? []
        guard token == generation else { return }
        let byID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        memberNames = others
            .map { id in byID[id].map { PostListDerivation.displayName(for: $0) } ?? "" }
            .filter { !$0.isEmpty }
    }

    /// Choose the team the channel will live in.
    func selectTeam(_ team: MMTeam) {
        guard teams.contains(where: { $0.id == team.id }) else { return }
        draft.teamID = team.id
        teamErrorMessage = nil
    }

    // MARK: Convert

    /// Send the conversion.
    ///
    /// - Returns: the server's channel, or `nil` when nothing was sent or the write failed. The host
    ///   navigates only on a channel, and only after checking it is a private channel.
    @discardableResult
    func convert() async -> MMChannel? {
        guard !isConverting else { return nil }
        // The gate. Not decoration: the row and the form are UI state, this is the check that the
        // request is only ever made for a conversation the server would convert.
        guard isAvailable else {
            errorMessage = ConvertGMToChannelCopy.refused
            return nil
        }
        guard phase == .ready, let teamID = draft.teamID, !teamID.isEmpty else {
            errorMessage = ConvertGMToChannelCopy.refused
            return nil
        }
        if let validationMessage {
            errorMessage = validationMessage
            return nil
        }
        // What this screen is asking for, frozen before the `await`: the reader can still edit the
        // fields while the request is in flight (only the button is disabled), and the answer is
        // compared against this capture, never against the live draft.
        let requestedTeamID = teamID
        let requestedType = ChannelInfoKind.privateChannel.rawValue
        let requestBody = draft.body(channelID: channel.id)
        // Upstream's `EphemeralStore.addConvertingChannel` (`app/actions/remote/channel.ts:1560`):
        // the socket's echo of this write is suppressed while it is in flight, and cleared in the
        // `finally` on both answers (the `defer` below is the same bracket).
        conversions?.beginChannelConversion(channel.id)
        defer { conversions?.endChannelConversion(channel.id) }
        isConverting = true
        errorMessage = nil
        nameErrorMessage = nil
        teamErrorMessage = nil
        defer { isConverting = false }
        do {
            let converted = try await service.convertGroupMessage(channelID: channel.id,
                                                                  teamID: requestedTeamID,
                                                                  displayName: requestBody.displayName,
                                                                  name: requestBody.name)
            guard !converted.id.isEmpty else {
                errorMessage = "The server answered a channel without an id."
                return nil
            }
            // A conversion answers the channel itself. Anything but a private channel means the server
            // stored something this screen did not ask for, and navigating there would be a lie.
            guard converted.type.isEmpty || converted.type == requestedType else {
                errorMessage = "The server answered a channel this app did not ask for."
                return nil
            }
            guard let target = ConvertedChannelTarget(channel: converted,
                                                      requestedTeamID: requestedTeamID) else {
                errorMessage = "The server answered a channel this app cannot open."
                return nil
            }
            self.target = target
            convertedChannel = converted
            return converted
        } catch {
            let answer = ConvertGMToChannelFailure.classify(error)
            switch answer.field {
            case .name: nameErrorMessage = answer.message
            case .team: teamErrorMessage = answer.message
            case .banner: errorMessage = answer.message
            }
            return nil
        }
    }
}
