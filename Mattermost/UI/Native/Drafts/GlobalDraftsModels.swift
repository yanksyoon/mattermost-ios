// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/global_drafts/index.tsx + global_drafts_list.tsx (one row per stored draft:
//        channel label, snippet, "last edited", swipe delete, tap to open that conversation),
//        app/screens/global_drafts/empty.tsx (the empty state), and
//        app/database/schema/server/table_schemas/draft.ts (the rows this list reads — the same
//        table the composer writes; the list adds no local storage of its own).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §20; no
// upstream source copied. The Swift value types and the pure `GlobalDraftDerivation` split are this
// repo's own (docs/component-map.md §1), matching `ChannelSidebarDerivation`.
//
// Why a sheet over the shell rather than a `Surface`: the drafts list has no web counterpart to fall
// back to (upstream's own screen is a list over the local table), so it is a **route inside the
// native sidebar**, exactly like T46's permanent-web rows. Adding a `Surface` case would put a
// one-legal-state key into a catalogue that forbids them (docs/dual-render.md §13).

import Foundation

// MARK: - What the list shows

/// One channel a draft belongs to, as the drafts list draws it.
///
/// Built from the sidebar's loaded entries for the **current team**: that is the only local source
/// of "channel id → name/kind" the app holds (the channel repository T29 defined is not wired into
/// the shell), and the sidebar is where the drafts sheet is opened from, so its list is what the
/// reader was just looking at.
struct DraftChannelLabel: Equatable, Sendable {
    let channelID: String
    /// The channel's URL name (`ops-standup`, `id__id` for a DM).
    let name: String
    /// What a row shows: the display name, or the resolved person(s) for a DM/GM.
    let displayName: String
    let kind: SidebarChannelKind?
    let teamID: String?

    init(channelID: String, name: String, displayName: String,
         kind: SidebarChannelKind?, teamID: String?) {
        self.channelID = channelID
        self.name = name
        self.displayName = displayName
        self.kind = kind
        self.teamID = teamID
    }

    init(entry: ChannelSidebarEntry, teamID: String?) {
        self.init(channelID: entry.id, name: entry.name, displayName: entry.displayName,
                  kind: entry.kind, teamID: teamID)
    }
}

/// One row of the global drafts list.
///
/// Every displayed fact is derived here, once, so the row is a value and the copy is testable without
/// a view (the same rule as `ChannelSidebarEntry`).
struct GlobalDraftRow: Identifiable, Equatable, Sendable {
    /// Where the channel's name came from. A draft whose channel is not in the team's current list
    /// is **still listed** (the card's rule) and says so, instead of being silently dropped: a draft
    /// in a channel the reader left is exactly the one they might want back.
    enum Availability: Equatable, Sendable {
        /// The channel is in the team's sidebar list; its name and kind are the server's.
        case listed
        /// The channel is not in the sidebar's list (left, archived, or another team's channel).
        case notListed
    }

    let channelID: String
    let rootID: String
    let message: String
    let attachmentCount: Int
    let updateAt: Int64
    let availability: Availability
    /// Nil when `availability == .notListed`: the app has no local name for that channel.
    let channelLabel: DraftChannelLabel?
    let teamID: String?

    var id: String { rootID.isEmpty ? channelID : "\(channelID).\(rootID)" }
    var isThreadDraft: Bool { !rootID.isEmpty }

    /// Upstream's row title: the channel's display name, or `#name` for a public channel the sidebar
    /// knows. A DM keeps the people's names (a channel name would be `id__id`).
    var title: String {
        guard let channelLabel else { return GlobalDraftDerivation.unlistedTitle(channelID: channelID) }
        if channelLabel.kind == .publicChannel { return "#\(channelLabel.displayName)" }
        return channelLabel.displayName
    }

    /// "Thread draft" or the channel kind. Kept separate from the title so VoiceOver reads a sentence
    /// instead of a run-on, and so a thread draft is never mistaken for the channel's own composer.
    var kindCopy: String {
        if isThreadDraft { return "Thread draft" }
        guard let kind = channelLabel?.kind else { return "Draft" }
        switch kind {
        case .publicChannel, .privateChannel: return "Channel draft"
        case .directMessage: return "Direct message draft"
        case .groupMessage: return "Group message draft"
        }
    }

    var snippet: String { GlobalDraftDerivation.snippet(message: message,
                                                        attachmentCount: attachmentCount) }

    func editedCopy(now: Date) -> String {
        GlobalDraftDerivation.editedCopy(updateAt: updateAt, now: now)
    }

    /// The route that opens this draft's conversation: the channel's composer, or — for a thread
    /// draft — the thread pane at the draft's root, whose composer is keyed by
    /// `(channel, root)` and restores the text.
    func request(serverID: UUID) -> NativeChannelRequest {
        NativeChannelRequest(serverID: serverID,
                             teamID: teamID,
                             channelID: channelID,
                             channelName: channelLabel?.name,
                             postID: rootID.isEmpty ? nil : rootID)
    }

    /// VoiceOver's one sentence for the row: title, kind, snippet, age. The view draws the same
    /// facts, split across three lines.
    func accessibilityLabel(now: Date) -> String {
        "\(title), \(kindCopy), \(snippet), \(editedCopy(now: now))"
    }
}

// MARK: - The pure rules

enum GlobalDraftDerivation {

    /// Upstream's `maximumDraftMessageLength` for the list row is a line, not the message: the row
    /// is a *pointer* to the composer, so it shows enough to recognise the draft and no more.
    static let snippetLimit = 140

    /// The one-line preview of a draft.
    ///
    /// Whitespace is collapsed (a draft with three newlines must not draw an empty-looking row), a
    /// message that is only an attachment says how many, and the ellipsis is added only when text was
    /// actually cut.
    static func snippet(message: String, attachmentCount: Int) -> String {
        let collapsed = message
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        if collapsed.isEmpty {
            switch attachmentCount {
            case 0: return "Empty draft"
            case 1: return "1 attachment"
            default: return "\(attachmentCount) attachments"
            }
        }
        guard collapsed.count > snippetLimit else { return collapsed }
        let cut = collapsed.prefix(snippetLimit).trimmingCharacters(in: .whitespaces)
        return cut + "…"
    }

    /// "Edited just now" / "Edited 5 min ago" / "Edited 3 h ago" / "Edited 2 d ago", and an absolute
    /// date after a week. `updateAt` is epoch **milliseconds**, the unit T29's draft row stores.
    static func editedCopy(updateAt: Int64, now: Date) -> String {
        guard updateAt > 0 else { return "Saved earlier" }
        let edited = Date(timeIntervalSince1970: Double(updateAt) / 1000)
        let seconds = now.timeIntervalSince(edited)
        // A clock that is behind the row (a server-corrected timestamp, a device time change) is
        // "just now", never "in -3 minutes".
        if seconds < 45 { return "Edited just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return minutes <= 1 ? "Edited 1 min ago" : "Edited \(minutes) min ago"
        }
        let hours = minutes / 60
        if hours < 24 {
            return hours == 1 ? "Edited 1 h ago" : "Edited \(hours) h ago"
        }
        let days = hours / 24
        if days < 7 {
            return days == 1 ? "Edited 1 d ago" : "Edited \(days) d ago"
        }
        return "Edited \(absoluteDate(edited))"
    }

    /// The absolute form, fixed to a POSIX locale so the string is stable in a unit test and in a
    /// screenshot; the row's *relative* copy is the one that carries the person's locale.
    static func absoluteDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    static func unlistedTitle(channelID: String) -> String {
        "Channel not in this team's list"
    }

    /// The rows the list draws, from the stored drafts and the team's channel directory.
    ///
    /// Team scoping is the card's "every draft for the server+team":
    ///  - a draft that knows its team is shown only on that team;
    ///  - a draft written before T51 (no `team_id` in its row) is shown on every team, because hiding
    ///    it would make an existing draft unreachable again — the very defect this card closes. Its
    ///    channel label still comes from the current team's list, so it is drawn honestly either way;
    ///  - a channel missing from the directory is `.notListed`, never dropped.
    static func rows(drafts: [ComposerDraft],
                     teamID: String?,
                     labels: [String: DraftChannelLabel],
                     now: Date) -> [GlobalDraftRow] {
        drafts
            .filter { !$0.isEmpty }
            .filter { draft in
                guard let draftTeam = draft.teamID, let teamID else { return true }
                return draftTeam == teamID
            }
            .map { draft in
                let label = labels[draft.channelID]
                return GlobalDraftRow(channelID: draft.channelID,
                                      rootID: draft.rootID,
                                      message: draft.message,
                                      attachmentCount: draft.files.count,
                                      updateAt: draft.updateAt,
                                      availability: label == nil ? .notListed : .listed,
                                      channelLabel: label,
                                      teamID: draft.teamID ?? teamID)
            }
            .sorted { left, right in
                if left.updateAt != right.updateAt { return left.updateAt > right.updateAt }
                return left.id < right.id
            }
    }
}

// MARK: - The screen's state

/// The drafts sheet's model: read the server's draft table, derive rows, delete a row.
///
/// One instance per presentation. It reads the **same** `ComposerDraftStoring` the composer writes
/// (the pane coordinator's per-server store), so the list cannot hold a second copy of a draft and
/// drift from the composer.
@MainActor
final class GlobalDraftsViewModel: ObservableObject {

    enum Phase: Equatable {
        case loading
        case loaded
        /// The store answered nothing usable. `ComposerDraftStoring` swallows write/read errors by
        /// design (a composer must still type), so this is only reached when the *rows* cannot be
        /// derived — kept explicit so a future throwing store does not need a new state.
        case failed(String)
    }

    @Published private(set) var rows: [GlobalDraftRow] = []
    @Published private(set) var phase: Phase = .loading
    /// A delete that the store did not honour: the row is still there, and the list says why.
    @Published private(set) var actionError: String?

    let teamID: String?
    private let drafts: ComposerDraftStoring
    private let labels: [String: DraftChannelLabel]
    private let limit: Int
    private let now: () -> Date

    /// Test/diagnostics: how many store reads this model has made.
    private(set) var loadCount = 0

    init(teamID: String?,
         drafts: ComposerDraftStoring,
         labels: [String: DraftChannelLabel],
         limit: Int = 500,
         now: @escaping () -> Date = { Date() }) {
        self.teamID = teamID
        self.drafts = drafts
        self.labels = labels
        self.limit = limit
        self.now = now
    }

    func load() async {
        loadCount += 1
        if rows.isEmpty { phase = .loading }
        let stored = await drafts.allDrafts(limit: limit)
        rows = GlobalDraftDerivation.rows(drafts: stored, teamID: teamID, labels: labels, now: now())
        phase = .loaded
    }

    /// Delete one draft. The row is removed **after the store answers**, and then the list is re-read
    /// from the store: "the row is gone from the list" and "the row is gone from disk" must be the
    /// same fact, so the UI never claims a delete the store did not make.
    ///
    /// `onDiscard` lets the host drop a warm composer's in-memory copy of the same draft (see
    /// `ComposerViewModel.discardStoredDraft`); the store is the only thing this model writes.
    func delete(_ row: GlobalDraftRow, onDiscard: ((GlobalDraftRow) -> Void)? = nil) async {
        actionError = nil
        onDiscard?(row)
        await drafts.delete(channelID: row.channelID, rootID: row.rootID)
        let stored = await drafts.allDrafts(limit: limit)
        rows = GlobalDraftDerivation.rows(drafts: stored, teamID: teamID, labels: labels, now: now())
        if rows.contains(where: { $0.id == row.id }) {
            actionError = "That draft could not be deleted. Try again."
        }
    }
}
