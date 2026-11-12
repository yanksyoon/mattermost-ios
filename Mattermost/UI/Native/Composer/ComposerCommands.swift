// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/components/autocomplete/slash_suggestion/slash_suggestion.tsx (which commands are
//        offered, the prefix match, the hidden-on-mobile list, the `/<trigger> ` completion),
//        slash_suggestion_item.tsx (the row: suggestion + argument hint + description),
//        app/actions/remote/command.ts (`fetchCommands` → GET /commands?team_id=;
//        `executeCommand` → the command string's normalization and the POST),
//        app/client/rest/integrations.ts (`getCommandsList`, `executeCommand`),
//        app/hooks/handle_send_message.ts (`sendCommand`: a message beginning with `/` is executed,
//        not posted; a failure is the server's sentence and the composer keeps the words).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §12; no
// upstream source copied. Everything here is pure (no I/O, no main actor, no SwiftUI) except the
// per-team cache, whose only dependency is a `fetch` closure the caller supplies.
//
// Scope, stated up front so the next reader does not assume more: this is the **base** command list
// (`/` with no space typed). Upstream additionally asks
// `GET /teams/{id}/commands/autocomplete_suggestions?user_input=…` once the reader types past the
// trigger, to complete a command's own arguments (a Playbooks run id, for instance). That endpoint
// answers a `[AutocompleteSuggestion]` for *apps and plugin commands*, and the Apps framework as a
// whole is a separate, uncarded capability (S34, docs/PARITY.md). Until it exists there is nothing
// to complete arguments *for*, so the argument completion is deliberately not implemented; the
// argument **hint** (`auto_complete_hint`) is shown, which is what the base list can honestly say.

import Foundation

// MARK: - The server's command record

/// One row of `GET /commands?team_id=` (https://api.mattermost.com/#tag/commands).
///
/// The endpoint mixes three kinds of command in one list: the server's built-ins (id/creator empty),
/// custom integrations registered for the team, and plugin commands (`plugin_id` set). Only the
/// fields this client reads are modelled; the rest of the payload is ignored, which is what lets a
/// server that grows a field not break the list.
struct MMCommand: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var trigger: String
    /// The name the row matches on second (`/msg` is triggered as `msg` but named `message`).
    var displayName: String
    /// Whether the command may appear in the suggestion list at all.
    var autoComplete: Bool
    var autoCompleteDesc: String
    /// The argument grammar, shown beside the trigger (`@[username]... ~[channel]...`).
    var autoCompleteHint: String
    var iconURL: String
    var deleteAt: Int64
    var teamID: String

    enum CodingKeys: String, CodingKey {
        case id, trigger
        case displayName = "display_name"
        case autoComplete = "auto_complete"
        case autoCompleteDesc = "auto_complete_desc"
        case autoCompleteHint = "auto_complete_hint"
        case iconURL = "icon_url"
        case deleteAt = "delete_at"
        case teamID = "team_id"
    }

    init(id: String = "",
         trigger: String,
         displayName: String = "",
         autoComplete: Bool = true,
         autoCompleteDesc: String = "",
         autoCompleteHint: String = "",
         iconURL: String = "",
         deleteAt: Int64 = 0,
         teamID: String = "") {
        self.id = id
        self.trigger = trigger
        self.displayName = displayName
        self.autoComplete = autoComplete
        self.autoCompleteDesc = autoCompleteDesc
        self.autoCompleteHint = autoCompleteHint
        self.iconURL = iconURL
        self.deleteAt = deleteAt
        self.teamID = teamID
    }

    /// Every field is optional on the wire, deliberately: a custom integration created before a
    /// field existed answers without it, and one missing `auto_complete_hint` must not take the
    /// whole list down (the composer would then silently suggest nothing, which reads exactly like
    /// an empty server).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        trigger = try container.decodeIfPresent(String.self, forKey: .trigger) ?? ""
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        autoComplete = try container.decodeIfPresent(Bool.self, forKey: .autoComplete) ?? false
        autoCompleteDesc = try container.decodeIfPresent(String.self, forKey: .autoCompleteDesc) ?? ""
        autoCompleteHint = try container.decodeIfPresent(String.self, forKey: .autoCompleteHint) ?? ""
        iconURL = try container.decodeIfPresent(String.self, forKey: .iconURL) ?? ""
        deleteAt = try container.decodeIfPresent(Int64.self, forKey: .deleteAt) ?? 0
        teamID = try container.decodeIfPresent(String.self, forKey: .teamID) ?? ""
    }
}

// MARK: - Which commands the composer offers

enum ComposerCommandList {

    /// Commands upstream hides on mobile because the native client has no screen for them: three it
    /// has not implemented yet (`collapse`, `expand`, `logout` — MM-43478) and three that are
    /// desktop-only (`shortcuts`, `search`, `settings`). Offering a row that can only fail is worse
    /// than not offering it: the reader sees "Command with a trigger of 'settings' not found" for a
    /// command the server does have.
    static let hiddenOnMobile: Set<String> = [
        "collapse", "expand", "logout", "shortcuts", "search", "settings",
    ]

    /// The list the suggestion source may draw.
    static func offered(_ commands: [MMCommand]) -> [MMCommand] {
        var seen: Set<String> = []
        return commands.filter { command in
            let trigger = command.trigger.lowercased()
            guard command.deleteAt == 0, command.autoComplete, !trigger.isEmpty else { return false }
            guard !hiddenOnMobile.contains(trigger) else { return false }
            // Two rows for one trigger would make the list's first row unstable under the finger.
            return seen.insert(trigger).inserted
        }
    }

    /// The rows for a typed `term` (the text after `/`), in the order the list draws them.
    ///
    /// The match is a **prefix** of the trigger or of the display name, which is upstream's rule
    /// (`command.display_name.startsWith(matchTerm) || command.trigger.startsWith(matchTerm)`) and
    /// is what makes `/mes` find `msg` without also matching every command whose description
    /// happens to contain the letters. Case-insensitive: the keyboard's first letter is usually
    /// capitalised.
    static func suggestions(_ commands: [MMCommand], term: String) -> [ComposerSuggestion] {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows = commands
            .filter { command in
                guard !needle.isEmpty else { return true }
                return command.trigger.lowercased().hasPrefix(needle)
                    || command.displayName.lowercased().hasPrefix(needle)
            }
            .map { command in
                ComposerSuggestion(kind: .slash,
                                   value: command.trigger,
                                   label: "/\(command.trigger)",
                                   detail: command.autoCompleteDesc,
                                   insertion: slashInsertion(command.trigger),
                                   glyph: nil,
                                   hint: command.autoCompleteHint.isEmpty ? nil : command.autoCompleteHint)
            }
        // Upstream sorts the finished suggestion strings; keeping that order here means the list
        // does not re-order itself under the reader's finger as the term grows.
        return rows.sorted {
            $0.insertion.localizedStandardCompare($1.insertion) == .orderedAscending
        }
    }
}

/// How a command is completed: `/trigger` (the space after it is the caller's, as for every other
/// suggestion kind — `ComposerTriggerParser.apply` adds one when the caret is not already separated).
func slashInsertion(_ trigger: String) -> String { "/\(trigger)" }

// MARK: - The command string

/// Turning what the reader typed into what `POST /commands/execute` receives.
///
/// Upstream (`filterEmDashForCommand`, then the `/code` special case) is not cosmetic:
///  * a message pasted from a word processor carries `—` (U+2014), and the server's parser reads
///    `--` as a flag — the em dash is replaced first so `/echo —hi` is not a flag error;
///  * the trigger is sent **lower-cased** (the server's triggers are lower case), while the
///    arguments keep their case (`/echo Hello` must echo "Hello");
///  * exactly one space separates trigger from arguments, and arguments are trimmed — except for
///    `/code`, whose whole point is the text as typed, so only the *trailing* whitespace is
///    trimmed there.
enum ComposerSlashCommand {

    /// The command a send should execute, or `nil` when the message is an ordinary post.
    ///
    /// A slash command is the **whole message** starting with `/` followed by a trigger. A message
    /// that merely contains a slash later (`see /help`) is a post — the same reason the trigger
    /// parser refuses a `/` that is not at offset 0.
    static func command(in message: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trigger(in: trimmed).count > 0 else { return nil }
        return normalized(trimmed)
    }

    /// The trigger without its slash: the first whitespace-delimited token, minus the `/`.
    static func trigger(in message: String) -> String {
        let token = message.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        return String(token.dropFirst())
    }

    static func normalized(_ message: String) -> String {
        let filtered = message.replacingOccurrences(of: "\u{2014}", with: "--")
        let triggerEnd = filtered.firstIndex(where: { $0.isWhitespace }) ?? filtered.endIndex
        let trigger = String(filtered[..<triggerEnd]).lowercased()
        let rest = String(filtered[triggerEnd...])
        // `/code` keeps the body verbatim apart from trailing whitespace; every other command's
        // arguments are trimmed on both ends (a leading space is the separator, not an argument).
        let arguments = trigger == "/code" ? trimmingTrailingWhitespace(rest)
                                           : rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return trigger + " " + arguments
    }

    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            guard text[previous].isWhitespace else { break }
            end = previous
        }
        return String(text[..<end])
    }
}

// MARK: - The wire shapes

/// `POST /commands/execute` request body.
///
/// `channel_id` is required (the server checks the caller's permission against it); `team_id` and
/// `root_id` are optional and only sent when known, because an empty string is *not* the same as
/// "absent" to the server's argument parser.
///
/// **`parent_id` is sent beside `root_id`, with the same value** — upstream's `executeCommand`
/// (`app/actions/remote/command.ts:41-46`) builds `{channel_id, team_id, root_id: rootId,
/// parent_id: rootId}` from one argument. The two are not redundant on the server: `CommandArgs`
/// carries both, and a plugin reads `args.ParentId` to know which thread the command was typed in
/// (kanban t_08826621 measured that a *custom* HTTP integration never sees either id — the server
/// forwards `channel_id`, `team_id`, `channel_name`, `team_domain`, `response_url`, `text`, `token`,
/// `trigger_id`, `user_id`, `user_name` and nothing else — while plugin commands get the whole
/// `CommandArgs`). Sending it is parity, and it costs one key.
struct ComposerCommandBody: Encodable, Equatable, Sendable {
    var command: String
    var channelId: String
    var teamId: String?
    var rootId: String?
    var parentId: String?

    enum CodingKeys: String, CodingKey {
        case command
        case channelId = "channel_id"
        case teamId = "team_id"
        case rootId = "root_id"
        case parentId = "parent_id"
    }

    /// `parentId` defaults to `rootId`, which is what upstream sends. Callers that predate the
    /// field keep compiling and immediately gain the key; nothing else can make the two disagree.
    init(command: String,
         channelId: String,
         teamId: String? = nil,
         rootId: String? = nil,
         parentId: String? = nil) {
        self.command = command
        self.channelId = channelId
        self.teamId = teamId
        self.rootId = rootId
        self.parentId = parentId ?? rootId
    }
}

/// The server's answer to `POST /commands/execute`.
///
/// `response_type` is `in_channel` (the command posted its own message — it arrives over the socket
/// like any other post) or `ephemeral` (the answer is for the caller only; the server sends it as an
/// `ephemeral_message` socket event). `text` is the same sentence the event carries, kept because a
/// caller without a socket still needs to show something.
struct ComposerCommandResponse: Decodable, Equatable, Sendable {
    var responseType: String
    var text: String
    var gotoLocation: String
    var triggerID: String

    enum CodingKeys: String, CodingKey {
        case text
        case responseType = "response_type"
        case gotoLocation = "goto_location"
        case triggerID = "trigger_id"
    }

    init(responseType: String = "", text: String = "", gotoLocation: String = "", triggerID: String = "") {
        self.responseType = responseType
        self.text = text
        self.gotoLocation = gotoLocation
        self.triggerID = triggerID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        responseType = try container.decodeIfPresent(String.self, forKey: .responseType) ?? ""
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        gotoLocation = try container.decodeIfPresent(String.self, forKey: .gotoLocation) ?? ""
        triggerID = try container.decodeIfPresent(String.self, forKey: .triggerID) ?? ""
    }

    /// The answer belongs to the reader alone: it is drawn as an ephemeral row, never as a message
    /// in the conversation.
    var isEphemeral: Bool { responseType == "ephemeral" }
}

// MARK: - Which endpoint a command belongs to

/// What the server says about the Apps framework — the two facts upstream's split reads.
///
/// Upstream's `executeCommand` asks `AppsManager.isAppsEnabled(serverUrl)` and then
/// `AppCommandParser.isAppCommand(message)` **before** it considers `POST /commands/execute`
/// (`app/actions/remote/command.ts:48-54`). Both inputs are server answers, so the native client has
/// to ask for the same two:
///
///  * `isEnabled` — `GET /config/client?format=old` → `FeatureFlagAppsEnabled`. Measured on the
///    9.11.19 fixture: `true`, even though the Apps plugin itself is **not installed** (its routes
///    404). The flag alone therefore does not mean an app command exists.
///  * `commandLabels` — the `command`-location bindings from the Apps runtime
///    (`GET /plugins/com.mattermost.apps/api/v1/bindings`). An app command is recognised by its
///    binding's **label**, never by the trigger list: app commands are not registered as slash
///    commands at all, which is why `/commands/execute` is the wrong endpoint for them.
struct ComposerAppsPosture: Equatable, Sendable {
    var isEnabled: Bool
    /// The labels as the runtime returned them (`/gif`, or `gif` — both are normalised here).
    var commandLabels: [String]

    /// Apps off, or bindings unreadable: every command is a `/commands/execute` command.
    static let unavailable = ComposerAppsPosture(isEnabled: false, commandLabels: [])

    init(isEnabled: Bool, commandLabels: [String]) {
        self.isEnabled = isEnabled
        self.commandLabels = commandLabels.compactMap { label in
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        }
    }
}

/// Where one typed line has to go.
enum ComposerCommandDestination: Equatable, Sendable {
    /// `POST /commands/execute` — built-ins, custom integrations, plugin commands.
    case execute
    /// The Apps framework's call cycle, identified by the binding that claimed the line.
    case app(binding: String)
}

/// Upstream's `AppCommandParser.isAppCommand`, reduced to the one rule it is.
///
/// The rule is not "the trigger matches a binding" — it is
///
///     command.startsWith(binding.label + ' ')
///
/// (`app_command_parser.ts:1526-1543`), i.e. **an app command is only recognised once it has an
/// argument**. `/gif` on its own is therefore *not* an app command even on a server with the GIF app
/// bound; it goes to `/commands/execute` like any other line, and only `/gif cats` takes the apps
/// path. That is upstream's behaviour, verbatim, and it is worth knowing before anyone "fixes" it.
enum ComposerCommandRouting {

    static func destination(for message: String,
                            posture: ComposerAppsPosture) -> ComposerCommandDestination {
        guard posture.isEnabled else { return .execute }
        let line = message.lowercased()
        // Longest label first: two apps can share a prefix, and the more specific binding owns the
        // line. (Upstream returns the first match in binding order; ordering by length is the
        // deterministic version of the same intent.)
        let labels = posture.commandLabels.sorted { $0.count > $1.count }
        for label in labels where line.hasPrefix(label.lowercased() + " ") {
            return .app(binding: label)
        }
        return .execute
    }

    /// The sentence a reader sees when a line belongs to an app and this client cannot run it.
    ///
    /// **Invented copy, deliberately.** There is no upstream sentence for "the runtime is not
    /// ported": upstream's `apps.error.*` strings all describe a call that failed, not a missing
    /// runtime. What this replaces is worse — the line used to be posted to `/commands/execute`,
    /// where an app command is not registered, so the reader got the server's "Command with a
    /// trigger of 'x' not found" for a command the server *does* have (kanban t_08826621 §3).
    /// `docs/t_61525849-s34-apps-forms-decision.md` §5 D2 records the Apps runtime as out of scope
    /// for v1; this sentence is the honest stand-in until that changes.
    static let appRuntimeUnavailable =
        "That command is provided by an app, and this client cannot run app commands yet."

    /// Whether an answer's `goto_location` should be followed.
    ///
    /// Upstream follows it for everything **except `/leave`** (`handle_send_message.ts:244`): the
    /// link points back into the conversation the command just removed the reader from, so following
    /// it can only fail (or bounce them straight back in). Measured on 9.11.19 with a stub
    /// integration: the response carries `goto_location` and the socket delivers only the answer
    /// text, so nothing navigates unless the client does it.
    static func followsGotoLocation(_ command: String) -> Bool {
        !command.lowercased().hasPrefix("/leave")
    }
}

// MARK: - The per-team cache

/// The command list, fetched once per team and shared by every composer of that team.
///
/// Why it is not a property of one composer: a composer is created per (channel, thread root), so a
/// team with ten channels would ask the server ten times for the same list — and the list is asked
/// for at the moment the reader types `/`, which is the least forgiving moment to wait. Upstream's
/// `IntegrationsManager` is the same shape: one cache per server+team, filled on first use.
///
/// The cache is in memory and per process, which is deliberate: commands are short-lived
/// configuration (an integration can be deleted while the app runs), and a failed fetch is **not**
/// cached — the next `/` tries again rather than leaving the reader with a list that never appears
/// until relaunch.
@MainActor
final class SlashCommandCatalogue {

    static let shared = SlashCommandCatalogue()

    private var byTeam: [String: [MMCommand]] = [:]
    private var inFlight: [String: Task<[MMCommand], Error>] = [:]
    /// Tests/diagnostics: how many real fetches this cache has performed.
    private(set) var fetchCount = 0

    /// The offered commands for `teamID`, fetching at most once.
    ///
    /// Concurrent callers (`ComposerViewModel` debounces its own typing, but two panes can mount at
    /// once) join the in-flight request instead of starting a second one, and every failure answers
    /// an empty list — never a throw — because "no suggestions" is a state the composer already
    /// draws, while a throw from a suggestion source would need a second error path.
    func commands(teamID: String,
                  fetch: @escaping @MainActor () async throws -> [MMCommand]) async -> [MMCommand] {
        guard !teamID.isEmpty else { return [] }
        if let cached = byTeam[teamID] { return cached }
        if let running = inFlight[teamID] {
            return (try? await running.value) ?? []
        }
        fetchCount += 1
        let task = Task { try await fetch() }
        inFlight[teamID] = task
        defer { inFlight[teamID] = nil }
        do {
            let offered = ComposerCommandList.offered(try await task.value)
            byTeam[teamID] = offered
            return offered
        } catch {
            return []
        }
    }

    /// What the cache holds for a team, without fetching (`nil` = never fetched).
    func cached(teamID: String) -> [MMCommand]? { byTeam[teamID] }

    /// Seed the cache (a test, or a caller that already has the list).
    func store(_ commands: [MMCommand], forTeam teamID: String) {
        byTeam[teamID] = ComposerCommandList.offered(commands)
    }

    func reset() {
        byTeam.removeAll()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        fetchCount = 0
    }
}
