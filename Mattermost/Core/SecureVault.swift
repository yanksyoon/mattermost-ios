import Foundation
import Security

/// Native counterpart of desktop `secureStorage.ts` (Electron `safeStorage`). Parity row:
/// `secureStorage` -> `SecureVault` (per-server credential store, Keychain-first). Status:
/// native, Phase 2; T22 adds the Keychain-unavailable fallback.
///
/// The desktop app encrypts a secrets file with `safeStorage` and keys it by
/// `normalizedUrl:keySuffix`. This shell stores the same secrets as
/// `kSecClassGenericPassword` items in the OS Keychain — one per `(server, key)` — and when the
/// Keychain is entirely refused on this build (ad-hoc Mac Catalyst, -34018), transparently
/// falls back to an AES-GCM sealed file under Application Support (see `SecretStore.swift` /
/// `EncryptedFileSecretPersisting.swift`). The Keychain remains primary; the file fallback is
/// used only when every `SecItem*` call fails with `errSecMissingEntitlement`.
///
/// The Keychain item's `service` is scoped to the canonical server URL — the same identity the
/// desktop derives from `parseURL` (origin + formatted path) — and `account` names the
/// individual secret (auth token, user id, pre-auth secret, …). This gives:
///
///   - **Survives relaunch**: items are persisted on the device by the OS (or in the fallback
///     file on the ad-hoc Mac build); a fresh vault instance (or a relaunched app) reads the
///     same token back.
///   - **Readable only via the vault**: the value lives only as a Keychain item / sealed file
///     (encrypted at rest), never in `UserDefaults`, plists, or a plaintext file. The only
///     in-process path to the value is this class's `secret(_:serverURL:)` (and per-name keys
///     are never logged or dumped).
///
/// Security boundary: `SecureVault` stays in the app's `Core` and is reachable only from the
/// shell — it is **not** exposed through `Bridge`/`window.desktop` (no JS-backed IPC reaches
/// it), mirroring how the preload never ships raw `safeStorage` to arbitrary page JS.
final class SecureVault {

    /// The named secrets the shell stores per server. Mirrors the desktop's
    /// `secureStorage` key suffixes + the auth-token credential the task targets.
    enum Key: String, CaseIterable {
        /// Persistent Mattermost auth/session token for the server (the task's headline item).
        case authToken = "authToken"
        /// User id associated with the stored token (desktop `AuthInfo.userId`).
        case userID = "userId"
        /// Shared pre-auth secret (desktop `SECURE_STORAGE_KEYS.PREAUTH`).
        case preauth = "preauth"

        /// Backwards-compatible alias used by older builds / callers that spelled it `token`.
        var aliases: [String] {
            switch self {
            case .authToken: return ["token"]
            default: return []
            }
        }
    }

    /// Error surfaced when a secret-store operation fails (the desktop's `getSecret` returns null
    /// on failure; here we throw so callers can distinguish "not stored" from "store broken").
    enum VaultError: Error, CustomStringConvertible {
        case copyFailed(OSStatus)
        case addFailed(OSStatus)
        case deleteFailed(OSStatus)
        case updateFailed(OSStatus)
        case unexpectedResultType
        /// Wrap of a lower-layer failure (includes `SecretStoreError` surfaced by the backends).
        case storeFailed(String)

        var description: String {
            switch self {
            case .copyFailed(let s): return "Keychain copy failed (status \(s))"
            case .addFailed(let s): return "Keychain add failed (status \(s))"
            case .deleteFailed(let s): return "Keychain delete failed (status \(s))"
            case .updateFailed(let s): return "Keychain update failed (status \(s))"
            case .unexpectedResultType: return "Keychain returned an unexpected result type"
            case .storeFailed(let message): return "Credential store failed: \(message)"
            }
        }

        /// Map a backend error onto the public vault error vocabulary.
        static func from(_ error: Error) -> VaultError {
            if let storeError = error as? SecretStoreError {
                return .storeFailed(storeError.description)
            }
            return .storeFailed(String(describing: error))
        }
    }

    /// Namespace inserted into every item's `service`, so the vault's items never collide with
    /// other apps'/items' same-named services. Defaulted to the bundle id; tests pass a unique
    /// forge to keep their items isolated from stored user data.
    private let serviceNamespace: String

    /// The backend the vault reads/writes through. Defaults to
    /// `SecretStore.makeDefault()` — Keychain-first with the encrypted-file fallback for the
    /// -34018 ad-hoc-Catalyst path. Tests inject a store to force either backend.
    private let secureStore: SecretPersisting

    init(serviceNamespace: String = Bundle.main.bundleIdentifier ?? "com.mattermost.ios",
         secureStore: SecretPersisting? = nil) {
        self.serviceNamespace = serviceNamespace
        self.secureStore = secureStore ?? SecretStore.makeDefault()
    }

    // MARK: Public API (mirrors desktop secureStorage set/get/has/delete)

    /// Store `value` as `key` for `serverURL`. Passing an empty/whitespace value deletes the
    /// key instead (desktop `setSecret` behaviour). Thread-safe via the item-based backends.
    func setSecret(_ value: String, key: Key, serverURL: URL) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteSecret(key, serverURL: serverURL)
            return
        }

        let canonicalURL = Self.canonicalServerURL(serverURL)
        do {
            try secureStore.set(service: service(for: canonicalURL),
                                account: account(for: key),
                                value: Data(trimmed.utf8))
        } catch {
            throw VaultError.from(error)
        }
        // One-time orientation log when the ad-hoc-Catalyst fallback is engaged.
        if secureStore.backendDescription != "Keychain" {
            Logger.debug("SecureVault", "Keychain unavailable; using \(secureStore.backendDescription)")
        }
        Logger.debug("SecureVault", "stored \(key.rawValue) for \(canonicalURL) (encrypted) ")
    }

    /// The stored value for `key` on `serverURL`, or `nil` when not present.
    func getSecret(key: Key, serverURL: URL) -> String? {
        let canonicalURL = Self.canonicalServerURL(serverURL)
        do {
            guard let data = try secureStore.get(service: service(for: canonicalURL),
                                                 account: account(for: key)) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        } catch {
            // Reads stay non-throwing on the public surface: a broken store reads as "no
            // secret" (desktop getSecret returns null on failure).
            Logger.debug("SecureVault", "read failed \(error) for \(canonicalURL)/\(key.rawValue)")
            return nil
        }
    }

    /// Whether `key` is present for `serverURL`.
    func hasSecret(key: Key, serverURL: URL) -> Bool {
        getSecret(key: key, serverURL: serverURL) != nil
    }

    /// Remove `key` for `serverURL`. Not-present is a no-op (desktop `deleteSecret`).
    func deleteSecret(_ key: Key, serverURL: URL) throws {
        do {
            try secureStore.delete(service: service(for: Self.canonicalServerURL(serverURL)),
                                   account: account(for: key))
        } catch {
            throw VaultError.from(error)
        }
    }

    /// Remove every key for a server (used when removing a server from the shell). Mirrors
    /// desktop `removeAuthInfo(baseUrl)`.
    func deleteAllSecrets(for serverURL: URL) {
        let canonicalURL = Self.canonicalServerURL(serverURL)
        for key in Key.allCases {
            try? deleteSecret(key, serverURL: serverURL)
        }
        // Also sweep legacy aliases so old spellings can't linger after a server is removed.
        for key in Key.allCases {
            for alias in key.aliases {
                try? secureStore.delete(service: service(for: canonicalURL), account: alias)
            }
        }
        Logger.debug("SecureVault", "deleted all secrets for \(canonicalURL)")
    }

    // MARK: Server identity

    /// Canonical per-server identity for store scoping — mirrors desktop
    /// `SecureStorage.normalizeUrl` (parseURL → `origin + formattedPath`). This keeps
    /// sub-paths distinct (`https://co/x/dev` vs `https://co/x/prod`) while collapsing
    /// default ports and trailing slashes, matching how desktop keys its secrets file.
    static func canonicalServerURL(_ url: URL) -> String {
        var comps = URLComponents()
        comps.scheme = (url.scheme ?? "https").lowercased()
        comps.host = url.host?.lowercased()
        if let port = url.port, !isDefaultPort(port, forScheme: comps.scheme) {
            comps.port = port
        }
        var path = url.path
        if path == "/" {
            path = "" // collapse a bare root trailing slash, per desktop's origin + path identity
        } else {
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        }
        comps.path = path
        return comps.string ?? url.absoluteString
    }

    private static func isDefaultPort(_ port: Int, forScheme scheme: String?) -> Bool {
        switch scheme {
        case "https": return port == 443
        case "http": return port == 80
        default: return false
        }
    }

    // MARK: Item composition

    /// The `service` a server maps to: a namespaced string embedding the canonical URL.
    private func service(for canonicalURL: String) -> String {
        "\(serviceNamespace).vault.\(canonicalURL)"
    }

    /// The `account` a named secret maps to (primary account for the generic password).
    private func account(for key: Key) -> String {
        key.rawValue
    }
}
