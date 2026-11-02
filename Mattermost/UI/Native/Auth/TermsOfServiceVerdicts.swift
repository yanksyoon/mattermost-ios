// T49 — the launch-memory half of the terms-of-service gate.
//
// Why this exists: `AuthCoordinator` answers the shell's gate from the vault during the optimistic
// launch window (before `restore()` has round-tripped), which is what keeps a relaunch from
// flashing a sign-in form. For a user whose terms are outstanding that optimism is exactly the bug
// this card fixes — the shell would mount the workspace for the length of the restore call, then
// swap to the gate. Remembering the last verdict per server closes that window: the launch reads
// the same answer the previous run paid a round trip for, and `restore()` re-validates it.
//
// What is stored is the *verdict*, not a credential: the published document (public text, the same
// bytes the server serves to anyone signed in) and whether this user had accepted it. It is
// cleared on sign-out and on accept, and it is overwritten by every fresh check.

import Foundation

/// Per-server memory of the last terms-of-service verdict, in `UserDefaults`.
///
/// Keyed by the server's canonical URL (the same key `SecureVault` uses), never by the app's
/// per-install `ServerConfig.id`: a re-added server with a new uuid must not inherit another
/// entry's verdict, and the URL is the identity the credential store already trusts.
final class TermsOfServiceVerdictStore {

    static let keyPrefix = "mm.termsOfService.verdict."

    private struct Entry: Codable {
        /// "notRequired" | "pending" | "accepted". `.unknown` and `.unreadable` are never stored:
        /// an unreadable answer is a fact about one run's network, not a durable verdict.
        var state: String
        var document: TermsOfServiceDocument?
    }

    private let defaults: UserDefaults
    private let keyPrefix: String
    private var memory: [String: TermsOfServiceState] = [:]

    init(defaults: UserDefaults = .standard, keyPrefix: String = TermsOfServiceVerdictStore.keyPrefix) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func verdict(for serverURL: URL) -> TermsOfServiceState? {
        let key = keyPrefix + serverURL.absoluteString
        if let cached = memory[key] { return cached }
        guard let data = defaults.data(forKey: key),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        let state: TermsOfServiceState
        switch entry.state {
        case "notRequired": state = .notRequired
        case "accepted": state = .accepted
        case "pending":
            guard let document = entry.document else { return nil }
            state = .pending(document)
        default:
            return nil
        }
        memory[key] = state
        return state
    }

    func save(_ state: TermsOfServiceState, for serverURL: URL) {
        let key = keyPrefix + serverURL.absoluteString
        switch state {
        case .notRequired, .accepted:
            memory[key] = state
            let entry = Entry(state: state == .accepted ? "accepted" : "notRequired", document: nil)
            defaults.set(try? JSONEncoder().encode(entry), forKey: key)
        case .pending(let document):
            memory[key] = state
            defaults.set(try? JSONEncoder().encode(Entry(state: "pending", document: document)),
                         forKey: key)
        case .unknown, .unreadable:
            clear(for: serverURL)
        }
    }

    func clear(for serverURL: URL) {
        let key = keyPrefix + serverURL.absoluteString
        memory[key] = nil
        defaults.removeObject(forKey: key)
    }
}
