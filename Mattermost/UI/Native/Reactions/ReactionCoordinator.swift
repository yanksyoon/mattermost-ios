// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/actions/remote/reactions.ts (`toggleReaction`, `addReaction`, `removeReaction` — the
//        alias write, the "already reacted" short-circuit and the recent-reaction record),
//        app/actions/websocket/reactions.ts (`reaction_added`/`reaction_removed` applied locally).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §14.
//
// Why the coordinator is a separate object from the view model:
//  - the *write* needs a service, a user id and a queue; the *window* (page cursor, scroll anchor,
//    thread membership) does not. Keeping them apart is what lets `ChannelViewModel` stay the
//    "loaded window" and this file stay the "one tap, one last intent" rule;
//  - both panes that draw a reaction bar (the channel list, the thread pane) need exactly this logic,
//    so it cannot live in either one;
//  - it is the seam the live suite drives: the pill is the UI, `ReactionToggles` is the state, and a
//    test can pump a hundred taps through the state machine with no server at all.
//
// The reconciliation contract, stated once:
//  1. a tap applies to the pill **immediately** through `target.applyReaction` (the same call the
//     socket handler uses, so a socket echo and an optimistic write mutate by the same rule);
//  2. at most one request per (post, alias group) is in flight; taps during a flight only move
//     `desired`, and the completion sends the final desire — so two quick taps cost one request after
//     the current one, never two racing requests;
//  3. a rejected write rolls the pill back to the last state the server is known to hold — once;
//  4. a socket event for my own reaction (whether it echoes my write or comes from another device)
//     only aligns the bookkeeping, because the pane's handler has already applied it to the post.

import Foundation
import Combine

/// What the reaction coordinator needs from the pane that shows a post.
///
/// Implemented by `ChannelViewModel` and `ThreadViewModel`. Both already own the post window and the
/// socket patch, which is exactly the state this needs; neither delegates it.
@MainActor
protocol ReactionTarget: AnyObject {
    var myUserID: String? { get }
    /// Profiles the pane already holds, for the reactor list (never fetched from here).
    var reactionUserProfiles: [String: MMUser] { get }
    func post(id: String) -> MMPost?
    /// Apply one reaction to the pane's copy of the post. Set-shaped and idempotent: adding a pair that
    /// is already present, or removing one that is not, is a no-op that returns false.
    @discardableResult
    func applyReaction(_ reaction: MMReaction, adding: Bool) -> Bool
    /// Fetch the profiles the reactor list is missing (a no-op when they are all known).
    func loadReactionProfiles(for userIDs: [String]) async
}

typealias ReactionWriter = @MainActor (String, String, String) async throws -> MMReaction
typealias ReactionRemover = @MainActor (String, String, String) async throws -> Void

/// One pane's reaction writes: optimistic apply, coalesced requests, rollback, socket alignment.
@MainActor
final class ReactionCoordinator: ObservableObject {

    /// The last failed write, for the pane's banner. Cleared by the next successful write.
    @Published private(set) var lastFailure: String?
    /// Exposed for diagnostics and tests; the pill itself renders `PostRowModel.reactions`.
    @Published private(set) var toggles = ReactionToggles()

    private let add: ReactionWriter
    private let remove: ReactionRemover
    private let system: SystemEmojiCatalogue
    private weak var target: ReactionTarget?
    /// Called after a *successful* add, so the picker's "recently used" row records what the reader
    /// actually used (upstream records it inside `addReaction`, after the client call).
    private let onReactionAdded: ((String) -> Void)?

    /// How many requests this coordinator has sent (diagnostics/tests: proves coalescing).
    private(set) var requestsSent = 0

    init(add: @escaping ReactionWriter,
         remove: @escaping ReactionRemover,
         target: ReactionTarget,
         system: SystemEmojiCatalogue = .shared,
         onReactionAdded: ((String) -> Void)? = nil) {
        self.add = add
        self.remove = remove
        self.target = target
        self.system = system
        self.onReactionAdded = onReactionAdded
    }

    convenience init(service: ReactionServing,
                     target: ReactionTarget,
                     system: SystemEmojiCatalogue = .shared,
                     onReactionAdded: ((String) -> Void)? = nil) {
        self.init(add: { postID, emoji, userID in
                      try await service.add(postID: postID, emojiName: emoji, userID: userID)
                  },
                  remove: { postID, emoji, userID in
                      try await service.remove(postID: postID, emojiName: emoji, userID: userID)
                  },
                  target: target,
                  system: system,
                  onReactionAdded: onReactionAdded)
    }

    // MARK: - Reading

    /// Whether my reaction to this alias group is currently on the pill — the *pane's* state, which
    /// includes an optimistic tap that has not been answered yet.
    func includesMe(postID: String, emojiName: String) -> Bool {
        guard let target, let post = target.post(id: postID), let myUserID = target.myUserID else {
            return false
        }
        return !myReactionNames(in: post, emojiName: emojiName).isEmpty && !myUserID.isEmpty
    }

    private func myReactionNames(in post: MMPost, emojiName: String) -> [String] {
        guard let myUserID = target?.myUserID, !myUserID.isEmpty else { return [] }
        let key = ReactionAliases.canonical(emojiName, system: system)
        var names: [String] = []
        for value in post.metadata?["reactions"]?.arrayValue ?? [] {
            guard let reaction = try? MMRawJSON(value).decode(MMReaction.self),
                  reaction.userId == myUserID,
                  ReactionAliases.canonical(reaction.emojiName, system: system) == key,
                  !names.contains(reaction.emojiName) else { continue }
            names.append(reaction.emojiName)
        }
        return names
    }

    // MARK: - Writing

    /// Dismiss the failure banner — the reader acknowledged it.
    func clearFailure() {
        lastFailure = nil
    }

    /// The reader tapped a reaction pill. Returns whether an optimistic change was applied.
    ///
    /// - Parameters:
    ///   - postID: the post the pill belongs to.
    ///   - emojiName: the pill's name — the *server's* spelling of one alias group (any alias is
    ///     accepted; the write always uses the canonical alias, as upstream does).
    @discardableResult
    func toggle(postID: String, emojiName: String) -> Bool {
        guard let target, let myUserID = target.myUserID, !myUserID.isEmpty else { return false }
        guard let post = target.post(id: postID), post.deleteAt == 0 else { return false }
        let key = ReactionToggles.Key(postID: postID,
                                      emojiName: ReactionAliases.canonical(emojiName, system: system))
        // The aliases **I** hold in this group, read before the optimistic apply erases them: the
        // remove request has to name each row the server really stores. `thumbsup` and `+1` are two
        // rows (measured), and a client that sends only the canonical spelling leaves the other one
        // behind — the pill would come back on the next page load.
        let held = myReactionNames(in: post, emojiName: emojiName)
        let step = toggles.tapped(key, current: !held.isEmpty)
        guard let state = toggles.toggle(key) else { return false }
        // 1. Optimistic: the pill changes now, before any network call.
        apply(state.desired, for: key, postID: postID)
        // 2. The machine decides whether a request is due.
        run(step, for: key, heldAliases: held)
        return true
    }

    /// A socket event about **my own** reaction. The pane's handler has already applied it to the post
    /// (`ReactionTarget.applyReaction` is the same call), so this only aligns the machine.
    func noteSocketEvent(_ reaction: MMReaction, adding: Bool) {
        guard let myUserID = target?.myUserID, reaction.userId == myUserID else { return }
        let key = ReactionToggles.Key(postID: reaction.postId,
                                      emojiName: ReactionAliases.canonical(reaction.emojiName,
                                                                           system: system))
        toggles.socketEvent(key, present: adding)
    }

    /// A freshly loaded page is the strongest truth about a post: adopt it for every pair the machine
    /// is tracking on that post, so a page merge cannot leave the bookkeeping stale.
    func adoptServerState(postID: String) {
        guard let post = target?.post(id: postID) else { return }
        for key in toggles.keys where key.postID == postID {
            let present = !myReactionNames(in: post, emojiName: key.emojiName).isEmpty
            toggles.adoptServerState(key, present: present)
        }
    }

    /// The pane dropped a post: forget its bookkeeping.
    func forget(postID: String) {
        toggles.forget(postID: postID)
    }

    // MARK: - Applying

    /// Write one state to the pane. Set-shaped: an add that is already present and a remove that is
    /// not are both no-ops, which is what makes a socket echo harmless.
    private func apply(_ desired: Bool, for key: ReactionToggles.Key, postID: String) {
        guard let target, let myUserID = target.myUserID, !myUserID.isEmpty else { return }
        guard let post = target.post(id: postID) else { return }
        let held = myReactionNames(in: post, emojiName: key.emojiName)
        if desired {
            guard held.isEmpty else { return }
            let reaction = MMReaction(userId: myUserID,
                                      postId: postID,
                                      emojiName: key.emojiName,
                                      createAt: Int64(Date().timeIntervalSince1970 * 1000))
            target.applyReaction(reaction, adding: true)
        } else {
            // Removing the pill removes *every* alias I hold in this group: the server treats
            // `thumbsup` and `+1` as two rows (measured), so deleting only the canonical one would
            // leave my reaction on screen after a tap that clearly said "remove".
            for name in held {
                target.applyReaction(MMReaction(userId: myUserID, postId: postID, emojiName: name),
                                     adding: false)
            }
        }
    }

    private func run(_ step: ReactionStep, for key: ReactionToggles.Key, heldAliases: [String] = []) {
        switch step {
        case .none, .deferred:
            return
        case .rollback(let state):
            apply(state, for: key, postID: key.postID)
        case .send(let desired):
            send(desired: desired, key: key, heldAliases: heldAliases)
        }
    }

    private func send(desired: Bool, key: ReactionToggles.Key, heldAliases: [String] = []) {
        guard let myUserID = target?.myUserID, !myUserID.isEmpty else { return }
        requestsSent += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            var failure: String?
            do {
                if desired {
                    _ = try await self.add(key.postID, key.emojiName, myUserID)
                } else {
                    // One DELETE per row this reader holds in the group (see `toggle`). A row the
                    // server already dropped is *not* a failure: the desired state — absent — holds.
                    let names = heldAliases.isEmpty ? [key.emojiName] : heldAliases
                    for name in names {
                        do {
                            try await self.remove(key.postID, name, myUserID)
                        } catch MMError.notFound {
                            continue
                        }
                    }
                }
            } catch {
                failure = Self.message(for: error, adding: desired, emoji: key.emojiName)
            }
            // The completion is fed back with the state it *carried*, not the current desire: a tap
            // that arrived while the request was out must survive it, and `sent` is what decides
            // whether another request is due.
            let step = self.toggles.sent(key, state: desired, success: failure == nil)
            if let failure {
                self.lastFailure = failure
            } else {
                self.lastFailure = nil
                if desired { self.onReactionAdded?(key.emojiName) }
            }
            self.run(step, for: key)
        }
    }

    static func message(for error: Error, adding: Bool, emoji: String) -> String {
        let verb = adding ? "add :\(emoji):" : "remove :\(emoji):"
        if let mm = error as? MMError {
            switch mm {
            case .notSignedIn: return "Couldn't \(verb) — you are signed out."
            case .offline, .timeout: return "Couldn't \(verb) — the server did not answer."
            case .notFound, .forbidden, .client: return "Couldn't \(verb) — the server refused it."
            case .rateLimited: return "Couldn't \(verb) — the server is rate-limiting; try again."
            case .unauthorized: return "Couldn't \(verb) — your session expired."
            default: return "Couldn't \(verb) — " + (mm.errorDescription ?? "try again.")
            }
        }
        return "Couldn't \(verb) — try again."
    }
}

extension ReactionToggles {
    /// The keys the machine is tracking (adoption after a page load needs to enumerate them).
    var keys: [Key] { Array(toggles.keys) }
}
