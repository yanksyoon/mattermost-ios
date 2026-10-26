// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/actions/remote/reactions.ts (`toggleReaction` → `addReaction`/`removeReaction`,
//        `getIsReactionAlreadyAddedToPost`, `getEmojiFirstAlias` on every write),
//        app/screens/reactions/reactions.tsx (one pill per *alias group*, order stable while the
//        sheet is open), app/screens/reactions/reactors_list/* (one row per reactor user).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §14.
//
// What this file owns (and why it is a separate, I/O-free unit):
//  - the alias rule: `thumbsup` and `+1` are *two* reactions on the server (measured: both rows
//    survive, `scripts/t37_reaction_probe.py`) but one pill to a reader. Grouping by canonical alias
//    is what makes "one pill, one count" true, and it is the rule upstream applies in `getSortedReactions`;
//  - the per-(post, emoji) toggle machine: desired state, the one request in flight, the last state the
//    server is known to hold. It is a value type so a test can drive a hundred-tap sequence through it
//    without a server, a clock or a view;
//  - the reactor projection (who reacted, and "you" for the session user).
//
// The machine's central claim, which the acceptance criteria are about: **a tap is applied to the pill
// immediately, and no sequence of taps + socket echoes can make the count drift.** That holds because
// every mutation is set-shaped (this user's reaction on this emoji is present or absent), never a
// "+1/-1" adjustment, and because a socket echo for a (user, emoji) pair that is already present is a
// no-op at the apply site (`ChannelViewModel.appendReaction`). The machine's job is to make sure the
// *last* intent reaches the server and that a failed write is rolled back exactly once.

import Foundation

// MARK: - Aliases

/// One reaction name's identity: several shortcodes are the same reaction.
enum ReactionAliases {

    /// The name to send for `name`: the system table's canonical alias (`thumbsup` → `+1`), or the
    /// name itself when the system table does not know it (a server custom emoji, which keeps its own
    /// spelling — the server's custom-emoji names are case-sensitive and must not be rewritten).
    static func canonical(_ name: String, system: SystemEmojiCatalogue) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return trimmed }
        return system.canonicalName(for: trimmed) ?? trimmed
    }

    /// Group reaction names by canonical alias, keeping first-appearance order of both the groups and
    /// their members (the order the server listed them in).
    static func groups(_ names: [String], system: SystemEmojiCatalogue) -> [(key: String, names: [String])] {
        var order: [String] = []
        var members: [String: [String]] = [:]
        for name in names {
            let key = canonical(name, system: system)
            if members[key] == nil { order.append(key) }
            if members[key]?.contains(name) == false || members[key] == nil {
                members[key, default: []].append(name)
            }
        }
        return order.map { (key: $0, names: members[$0] ?? []) }
    }
}

// MARK: - Toggle machine

/// One (post, canonical emoji) pair's write state.
struct ReactionToggle: Equatable, Sendable {
    /// What the reader's taps have asked for. Optimistic: the pill already shows it.
    var desired: Bool
    /// The last state the server is *known* to hold.
    var confirmed: Bool
    /// A request for this pair is in flight; at most one at a time, so the server sees a sequence it
    /// can order, not two adds racing a remove.
    var inFlight: Bool
    /// Counts taps, so a test (and the log) can tell "one tap" from "five taps, coalesced".
    var generation: Int

    init(desired: Bool, confirmed: Bool = false, inFlight: Bool = false, generation: Int = 0) {
        self.desired = desired
        self.confirmed = confirmed
        self.inFlight = inFlight
        self.generation = generation
    }
}

/// What the caller must do next after feeding the machine an event.
enum ReactionStep: Equatable, Sendable {
    /// Nothing to do (a state that already matches, or an event that does not concern us).
    case none
    /// Send the write for `desired` (an add when true, a remove when false).
    case send(desired: Bool)
    /// Apply this state to the pill — the write failed, and the server's last known state is the truth.
    case rollback(to: Bool)
    /// A tap arrived while a request was in flight; its completion will send the final desire.
    case deferred
}

/// The toggles for one pane, keyed by (post id, canonical emoji name).
struct ReactionToggles: Equatable, Sendable {

    struct Key: Hashable, Sendable {
        var postID: String
        var emojiName: String
    }

    private(set) var toggles: [Key: ReactionToggle] = [:]

    func toggle(_ key: Key) -> ReactionToggle? { toggles[key] }

    /// How many writes are in flight (diagnostics and tests).
    var inFlightCount: Int { toggles.values.filter(\.inFlight).count }

    /// The reader tapped the pill. `current` is the state the host holds **right now**, which already
    /// includes any earlier optimistic tap — reading it (rather than the server's state) is what makes
    /// two quick taps a remove rather than a second add.
    mutating func tapped(_ key: Key, current: Bool) -> ReactionStep {
        var state = toggles[key] ?? ReactionToggle(desired: current, confirmed: current)
        state.generation += 1
        // Flip the *intended* state, not the host's: within one run-loop the host may not have
        // re-rendered yet, and "the second tap flips the first" is the reader's model.
        state.desired.toggle()
        toggles[key] = state
        if state.inFlight { return .deferred }
        state.inFlight = true
        toggles[key] = state
        return .send(desired: state.desired)
    }

    /// The request the machine asked for came back. `sent` is the state that request carried — not
    /// `desired`, which may have moved on while it was in flight.
    mutating func sent(_ key: Key, state sent: Bool, success: Bool) -> ReactionStep {
        guard var state = toggles[key], state.inFlight else { return .none }
        state.inFlight = false
        guard success else {
            // The write was rejected: the server still holds `confirmed`. Drop the failed intent so a
            // later tap starts from the truth rather than from a desire the server refused.
            let rollback = state.confirmed
            state.desired = rollback
            toggles[key] = state
            return sent == rollback ? .none : .rollback(to: rollback)
        }
        state.confirmed = sent
        // A tap arrived during the flight: send the final desire now.
        if state.desired != state.confirmed {
            state.inFlight = true
            toggles[key] = state
            return .send(desired: state.desired)
        }
        toggles[key] = state
        return .none
    }

    /// A socket event about **my own** reaction on this pair arrived. The host has already applied it
    /// to the post, so this only aligns the bookkeeping.
    mutating func socketEvent(_ key: Key, present: Bool) -> ReactionStep {
        guard var state = toggles[key] else { return .none }
        state.confirmed = present
        if !state.inFlight {
            // No request of ours is pending: the server is the truth, and the host already shows it.
            state.desired = present
        }
        toggles[key] = state
        return .none
    }

    /// The pane reloaded a page, which is the strongest truth available: adopt it, and keep any
    /// in-flight desire (its completion would otherwise be undone by a page that predates it).
    mutating func adoptServerState(_ key: Key, present: Bool) -> ReactionStep {
        guard var state = toggles[key] else { return .none }
        state.confirmed = present
        if !state.inFlight { state.desired = present }
        toggles[key] = state
        return .none
    }

    /// Forget a post that left the window.
    mutating func forget(postID: String) {
        toggles = toggles.filter { $0.key.postID != postID }
    }
}

// MARK: - Reactors

/// One row of the reactor list.
struct ReactionReactor: Identifiable, Equatable, Sendable {
    var userID: String
    var displayName: String
    var username: String
    var isMe: Bool

    var id: String { userID }

    /// What the row reads: the name, `(you)` for the session user, and *unknown* when the server has
    /// not answered a profile yet — an invented name would be worse than an honest placeholder.
    var label: String {
        var text = displayName.isEmpty ? "Unknown user" : displayName
        if isMe { text += " (you)" }
        return text
    }

    var detail: String { username.isEmpty ? "" : "@\(username)" }
}

enum ReactionReactors {

    /// The reactor user ids of one alias group, in server order, from a post's raw metadata.
    static func userIDs(forPillEmoji pill: String,
                        in post: MMPost,
                        system: SystemEmojiCatalogue) -> [String] {
        let key = ReactionAliases.canonical(pill, system: system)
        var ids: [String] = []
        for value in post.metadata?["reactions"]?.arrayValue ?? [] {
            guard let reaction = try? MMRawJSON(value).decode(MMReaction.self),
                  ReactionAliases.canonical(reaction.emojiName, system: system) == key,
                  !ids.contains(reaction.userId) else { continue }
            ids.append(reaction.userId)
        }
        return ids
    }

    /// Project the reactor user ids of one pill into rows, resolving names from whatever profiles the
    /// pane already holds. Order is the server's order (the order the reactions arrived in), which is
    /// what the sheet keeps stable while it is open.
    static func rows(userIDs: [String],
                     myUserID: String?,
                     users: [String: MMUser]) -> [ReactionReactor] {
        var seen = Set<String>()
        var rows: [ReactionReactor] = []
        for userID in userIDs where !userID.isEmpty && seen.insert(userID).inserted {
            if let user = users[userID] {
                rows.append(ReactionReactor(userID: userID,
                                            displayName: PostListDerivation.displayName(for: user),
                                            username: user.username,
                                            isMe: userID == myUserID))
            } else {
                rows.append(ReactionReactor(userID: userID,
                                            displayName: "",
                                            username: "",
                                            isMe: userID == myUserID))
            }
        }
        return rows
    }
}

// MARK: - Sheet order

/// The reaction sheet's emoji bar keeps its order while the sheet is open.
///
/// Upstream is explicit about why (`app/screens/reactions/reactions.tsx`, `getSortedReactions`): a
/// reaction that arrives while the reader is looking at the list must not move the tab they are
/// reading. New reactions are appended, removed ones dropped, everything else keeps its place.
enum ReactionSheetOrder {
    static func merged(previous: [String], current: [String]) -> [String] {
        var order = previous
        for name in current where !order.contains(name) { order.append(name) }
        order.removeAll { !current.contains($0) }
        return order
    }
}
