// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/actions/local/reactions.ts (`addRecentReaction`, `MAXIMUM_RECENT_EMOJI = 27`),
//        app/screens/emoji_picker/picker/sections/index.tsx (the `recent` section, omitted entirely
//        when the list is empty), app/actions/remote/reactions.ts (a successful react records it).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §14.
//
// Where the list lives: upstream keeps it in the per-server database (`SYSTEM_IDENTIFIERS.RECENT_REACTIONS`),
// which is local storage on the device either way. This client has no store wired into the running app
// (T29 delivered the module; T34/T35 read REST + socket), so the equivalent local home is
// `UserDefaults`, keyed by server **and** user — two accounts on one server must not share a "recently
// used" row, and a different server certainly must not. The cap and the de-duplication rule are
// upstream's, exactly: newest first, an existing entry is moved to the front (not duplicated), 27 kept.

import Foundation

/// The MRU rules, separated from storage so they are testable without a defaults domain.
enum EmojiRecentsRule {

    /// Upstream's `MAXIMUM_RECENT_EMOJI`.
    static let limit = 27

    /// Insert `name` at the front, dropping any earlier occurrence, capped at `limit`.
    static func adding(_ name: String, to recents: [String]) -> [String] {
        adding(contentsOf: [name], to: recents)
    }

    /// Insert several names at the front — upstream unshifts them in the order given, so the *last*
    /// name of `names` ends up first; that is not what a picker record wants, so this inserts each in
    /// turn (first given ends up first) and de-duplicates across the batch.
    static func adding(contentsOf names: [String], to recents: [String]) -> [String] {
        var result = recents
        for name in names.reversed() where !name.isEmpty {
            result.removeAll { $0 == name }
            result.insert(name, at: 0)
        }
        return Array(result.prefix(limit))
    }

    /// Drop entries this server/user can no longer resolve: a custom emoji that was deleted stays in
    /// the stored list otherwise, and the picker would draw a chip for something the server refuses.
    static func pruned(_ recents: [String], keeping isKnown: (String) -> Bool) -> [String] {
        recents.filter(isKnown)
    }
}

/// The persisted "recently used" list for one (server, user).
///
/// `ObservableObject` so the picker's recent row redraws when a pick is recorded while the sheet is up.
@MainActor
final class EmojiRecentsStore: ObservableObject {

    /// The defaults domain key for one server and user. Not private: a test asserts two users/servers
    /// cannot collide, and a sign-out purge has to name the key it removes.
    static func key(serverID: UUID, userID: String) -> String {
        "mm.emoji.recent.\(serverID.uuidString).\(userID)"
    }

    static let keyPrefix = "mm.emoji.recent."

    @Published private(set) var names: [String]

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String) {
        self.defaults = defaults
        self.key = key
        self.names = defaults.stringArray(forKey: key) ?? []
    }

    convenience init(defaults: UserDefaults = .standard, serverID: UUID, userID: String) {
        self.init(defaults: defaults, key: Self.key(serverID: serverID, userID: userID))
    }

    /// Record a pick (a react, or an emoji inserted into the composer — both are "used").
    func record(_ name: String) {
        // The persisted list is the base, not this instance's copy: two stores for the same key (the
        // picker beside the pane's, a relaunched app, a test) must not be able to rewind the list with
        // a stale snapshot.
        let base = defaults.stringArray(forKey: key) ?? names
        let updated = EmojiRecentsRule.adding(name, to: base)
        guard updated != names else { return }
        names = updated
        defaults.set(updated, forKey: key)
    }

    func record(contentsOf names: [String]) {
        let base = defaults.stringArray(forKey: key) ?? self.names
        let updated = EmojiRecentsRule.adding(contentsOf: names, to: base)
        guard updated != self.names else { return }
        self.names = updated
        defaults.set(updated, forKey: key)
    }

    /// Forget entries nothing can resolve any more (a deleted custom emoji).
    func prune(keeping isKnown: (String) -> Bool) {
        let base = defaults.stringArray(forKey: key) ?? names
        let kept = EmojiRecentsRule.pruned(base, keeping: isKnown)
        guard kept != names else { return }
        names = kept
        defaults.set(kept, forKey: key)
    }

    /// Sign-out: remove this key only, never the whole domain (another server's list is not ours).
    func clear() {
        names = []
        defaults.removeObject(forKey: key)
    }
}
