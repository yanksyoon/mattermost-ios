import Foundation
import Security

/// Native counterpart of desktop `secureStorage.ts` (Electron `safeStorage`). Parity row:
/// `secureStorage` -> `SecureVault` (Keychain, `kSecClassGenericPassword`, service per server).
/// Status: native, Phase 2.
///
/// The desktop app encrypts a secrets file with `safeStorage` and keys it by
/// `normalizedUrl:keySuffix`. On iOS the OS Keychain is the on-disk, hardware-backed encrypted
/// store, so this class replaces that file with a `kSecClassGenericPassword` item per
/// (server, key). The Keychain item's `service` is scoped to the canonical server URL — the
/// same identity the desktop derives from `parseURL` (origin + formatted path) — and `account`
/// names the individual secret (auth token, user id, pre-auth secret, …). This gives:
///
///   - **Survives relaunch**: Keychain items are persisted on the device by the OS; a fresh
///     vault instance (or a relaunched app) reads the same token from disk.
///   - **Readable only via the vault**: the value lives only as a Keychain item (encrypted
///     at rest on the device's hardware keychain), never in `UserDefaults`, plists, or a
///     plaintext file. The only in-process path to the value is this class's
///     `secret(_:serverURL:)` (and per-name keys are never logged or dumped).
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

    /// Error surfaced when a Keychain operation fails (the desktop's `getSecret` returns null
    /// on failure; here we throw so callers can distinguish "not stored" from "store broken").
    enum VaultError: Error, CustomStringConvertible {
        case copyFailed(OSStatus)
        case addFailed(OSStatus)
        case deleteFailed(OSStatus)
        case updateFailed(OSStatus)
        case unexpectedResultType

        var description: String {
            switch self {
            case .copyFailed(let s): return "Keychain copy failed (status \(s))"
            case .addFailed(let s): return "Keychain add failed (status \(s))"
            case .deleteFailed(let s): return "Keychain delete failed (status \(s))"
            case .updateFailed(let s): return "Keychain update failed (status \(s))"
            case .unexpectedResultType: return "Keychain returned an unexpected result type"
            }
        }
    }

    /// Namespace inserted into every `kSecAttrService`, so the vault's items never collide with
    /// other apps'/items' same-named services. Defaulted to the bundle id; tests pass a unique
    /// forge to keep their items isolated from stored user data.
    private let serviceNamespace: String

    /// Access policy: only usable after first unlock, `ThisDeviceOnly` keeps the token off
    /// iCloud/backups (a credential, not a passenger). Still persists across relaunch.
    private let accessible: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    init(serviceNamespace: String = Bundle.main.bundleIdentifier ?? "com.mattermost.ios") {
        self.serviceNamespace = serviceNamespace
    }

    // MARK: Public API (mirrors desktop secureStorage set/get/has/delete)

    /// Store `value` as `key` for `serverURL`. Passing an empty/whitespace value deletes the
    /// key instead (desktop `setSecret` behaviour). Thread-safe via the item-based Keychain API.
    func setSecret(_ value: String, key: Key, serverURL: URL) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteSecret(key, serverURL: serverURL)
            return
        }

        let canonicalURL = Self.canonicalServerURL(serverURL)
        var base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: canonicalURL),
            kSecAttrAccount as String: account(for: key),
            kSecAttrAccessible as String: accessible,
        ]
        KeychainPlatform.apply(to: &base)

        if hasSecret(key: key, serverURL: serverURL) {
            // Update the existing item's payload in place (generic-password UX: same primary key).
            var attr = base
            attr[kSecValueData as String] = Data(trimmed.utf8)
            let status = SecItemUpdate(base as CFDictionary, attr as CFDictionary)
            guard status == errSecSuccess else { throw VaultError.updateFailed(status) }
        } else {
            var add = base
            add[kSecValueData as String] = Data(trimmed.utf8)
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw VaultError.addFailed(status) }
        }
        Logger.debug("SecureVault", "stored \(key.rawValue) for \(canonicalURL) (encrypted) ")
    }

    /// The stored value for `key` on `serverURL`, or `nil` when not present.
    func getSecret(key: Key, serverURL: URL) -> String? {
        let canonicalURL = Self.canonicalServerURL(serverURL)
        var query = baseQuery(for: key, canonicalURL: canonicalURL)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            // not-found (not an error worth surfacing) reads as "no secret".
            if status != errSecItemNotFound {
                Logger.debug("SecureVault", "copy failed \(status) for \(canonicalURL)/\(key.rawValue)")
            }
            return nil
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Whether `key` is present for `serverURL`.
    func hasSecret(key: Key, serverURL: URL) -> Bool {
        var query = baseQuery(for: key, canonicalURL: Self.canonicalServerURL(serverURL))
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Remove `key` for `serverURL`. Not-present is a no-op (desktop `deleteSecret`).
    func deleteSecret(_ key: Key, serverURL: URL) throws {
        let query = baseQuery(for: key, canonicalURL: Self.canonicalServerURL(serverURL))
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        throw VaultError.deleteFailed(status)
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
                var query = baseQuery(canonicalURL: canonicalURL, account: alias)
                query[kSecClass as String] = kSecClassGenericPassword
                SecItemDelete(query as CFDictionary)
            }
        }
        Logger.debug("SecureVault", "deleted all secrets for \(canonicalURL)")
    }

    // MARK: Server identity

    /// Canonical per-server identity for Keychain scoping — mirrors desktop
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

    // MARK: Keychain item composition

    /// The `kSecAttrService` a server maps to: a namespaced string embedding the canonical URL.
    private func service(for canonicalURL: String) -> String {
        "\(serviceNamespace).vault.\(canonicalURL)"
    }

    /// The `kSecAttrAccount` a named secret maps to (primary account for the generic password).
    private func account(for key: Key) -> String {
        key.rawValue
    }

    private func baseQuery(for key: Key, canonicalURL: String) -> [String: Any] {
        baseQuery(canonicalURL: canonicalURL, account: account(for: key))
    }

    private func baseQuery(canonicalURL: String, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: canonicalURL),
            kSecAttrAccount as String: account,
        ]
        KeychainPlatform.apply(to: &query)
        return query
    }
}

/// Keychain backend shim for the two supported platforms.
///
/// iOS uses the data-protection keychain, which is gated on the `application-identifier` /
/// `keychain-access-groups` entitlement. A locally built Mac Catalyst app signed ad hoc has no
/// team, so no such entitlement can be issued and every `SecItem*` call fails with
/// `errSecMissingEntitlement` (-34018) — the credential vault and the certificate-trust bag would
/// silently stop working on the Mac. The login (file-based) keychain has no entitlement
/// requirement, so on Catalyst we opt out of the data-protection keychain per query. iOS keeps
/// the default behaviour, unchanged.
enum KeychainPlatform {
    static func apply(to query: inout [String: Any]) {
        #if targetEnvironment(macCatalyst)
        query[kSecUseDataProtectionKeychain as String] = false
        #endif
    }
}