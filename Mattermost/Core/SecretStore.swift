import Foundation
import Security

/// The persistence surface used by the shell's two storage services (`SecureVault` and
/// `CertTrust`). A store addresses a value by `(service, account)` — exactly the primary
/// key of a `kSecClassGenericPassword` item — so the Keychain backend and the encrypted-file
/// fallback share one shape.
///
/// Backends:
/// - `KeychainSecretPersisting` — the normal path. Works on iOS (simulator + device) and on a
///   Mac build signed with any team.
/// - `EncryptedFileSecretPersisting` — a CryptoKit AES-GCM sealed file under Application
///   Support, used ONLY when the Keychain rejects every call with `errSecMissingEntitlement`
///   (-34018, ad-hoc Mac Catalyst).
/// - `FallbackSecretPersisting` — the production composite: try the Keychain first, transparently
///   route to the encrypted file when and only when the Keychain reports exactly -34018.
protocol SecretPersisting {
    /// The value stored under `(service, account)`, or `nil` when not present.
    /// Implementations may throw when the backend itself is broken (not on "not found").
    func get(service: String, account: String) throws -> Data?
    /// Store `value` under `(service, account)`, replacing any existing value (add-or-update).
    func set(service: String, account: String, value: Data) throws
    /// Remove `(service, account)`. Not-present is a no-op.
    func delete(service: String, account: String) throws
    /// Remove every account under `service`.
    func deleteAll(service: String) throws
    /// Human-readable backend name for logs / diagnostics ("Keychain", "Encrypted file …").
    var backendDescription: String { get }
}

extension SecretPersisting {
    var backendDescription: String { "secret store" }
}

/// Errors the Keychain backend reports. Callers must distinguish "the Keychain exists but
/// refused this process" (entitlement problem — safe to fall back) from genuine Keychain
/// failures (do NOT silently fall back — that would mask a real bug on iOS).
enum SecretStoreError: Error, CustomStringConvertible {
    /// The Keychain rejected the call because this process has no entitlement
    /// (`errSecMissingEntitlement`, -34018 — an ad-hoc signed Catalyst process always hits
    /// this). The only legitimate trigger for the encrypted-file fallback.
    case keychainUnavailable(OSStatus)
    /// Any other Keychain failure (bad access policy, interaction blocked, …). Surfaced, never
    /// silently routed to the file fallback.
    case keychainFailure(OSStatus)

    var description: String {
        switch self {
        case .keychainUnavailable(let s): return "Keychain unavailable (status \(s), -34018 class — no application-identifier entitlement)"
        case .keychainFailure(let s): return "Keychain operation failed (status \(s))"
        }
    }
}

/// Keychain backend shim for the two supported platforms (kept from T20, same behaviour).
///
/// iOS uses the data-protection keychain, which is gated on the `application-identifier` /
/// `keychain-access-groups` entitlement. A locally built Mac Catalyst app signed ad hoc has no
/// team, so no such entitlement can be issued and every `SecItem*` call fails with
/// `errSecMissingEntitlement` (-34018). Opting out per-query with
/// `kSecUseDataProtectionKeychain = false` does NOT help on Catalyst (measured T20) — the
/// process still routes to the data-protection keychain. iOS keeps the default behaviour,
/// unchanged. The flag is still applied because it is harmless and documents intent; the real
/// fix for the -34018 path is `FallbackSecretPersisting`.
enum KeychainPlatform {
    static func apply(to query: inout [String: Any]) {
        #if targetEnvironment(macCatalyst)
        query[kSecUseDataProtectionKeychain as String] = false
        #endif
    }
}

/// The Keychain backend: one `kSecClassGenericPassword` item per `(service, account)`, with the
/// access policy set on writes (`AfterFirstUnlockThisDeviceOnly`: survives relaunch, stays off
/// iCloud/backups). This is exactly the item layout `SecureVault`/`CertTrust` used before the
/// backend split, so nothing stored earlier is orphaned.
struct KeychainSecretPersisting: SecretPersisting {
    var backendDescription: String { "Keychain" }

    /// Access policy for written items: usable after first unlock, `ThisDeviceOnly` keeps
    /// credentials and trust decisions off iCloud/backups.
    private let accessible: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    func get(service: String, account: String) throws -> Data? {
        var query = Self.baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        case errSecMissingEntitlement:
            throw SecretStoreError.keychainUnavailable(status)
        default:
            throw SecretStoreError.keychainFailure(status)
        }
    }

    func set(service: String, account: String, value: Data) throws {
        // Identity of the item: class + service + account (+ platform shim). This — and only this —
        // is a legal `SecItemUpdate` search query. `kSecAttrAccessible` is an *attribute*, not a
        // search key: putting it in the query makes SecItemUpdate return `errSecParam` (-50) on iOS,
        // so every "write over an existing item" silently failed (measured on iOS 26 sim: re-trusting
        // an origin whose `wss://` mirror already existed threw and dropped the user's decision —
        // t_ca6db268). It belongs in the attributes on add, and is kept up to date on update.
        let identity = Self.baseQuery(service: service, account: account)

        // Probe-then-write, mirroring the iOS-proven pattern from the pre-refactor
        // `SecureVault`: check existence first (read query, no return data), then update the
        // existing item in place or add a new one. Calling `SecItemUpdate` on an *absent*
        // item is unreliable on iOS (surfaces `errSecInteractionNotAllowed`, -25303, rather
        // than `errSecItemNotFound`), so we must know existence before choosing the write.
        var probe = identity
        probe[kSecReturnData as String] = false
        probe[kSecMatchLimit as String] = kSecMatchLimitOne
        var probeResult: AnyObject?
        let probeStatus = SecItemCopyMatching(probe as CFDictionary, &probeResult)
        switch probeStatus {
        case errSecSuccess:
            // Present → update the payload in place (generic-password UX: same primary key).
            try self.update(identity: identity, value: value)
            return
        case errSecItemNotFound:
            // Absent → add; a duplicate here means another writer won the race, so retry as
            // an update (same add-or-update contract as the earlier explicit has-then-add).
            var add = identity
            add[kSecAttrAccessible as String] = accessible
            add[kSecValueData as String] = value
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            switch addStatus {
            case errSecSuccess:
                return
            case errSecDuplicateItem:
                try self.update(identity: identity, value: value)
            case errSecMissingEntitlement:
                throw SecretStoreError.keychainUnavailable(addStatus)
            default:
                throw SecretStoreError.keychainFailure(addStatus)
            }
        case errSecMissingEntitlement:
            throw SecretStoreError.keychainUnavailable(probeStatus)
        default:
            throw SecretStoreError.keychainFailure(probeStatus)
        }
    }

    /// Update the existing item's payload in place. The search query carries the item identity
    /// only; the access policy is re-asserted as an updatable attribute.
    private func update(identity: [String: Any], value: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: accessible,
        ]
        let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess: return
        case errSecMissingEntitlement: throw SecretStoreError.keychainUnavailable(status)
        default: throw SecretStoreError.keychainFailure(status)
        }
    }

    func delete(service: String, account: String) throws {
        let query = Self.baseQuery(service: service, account: account)
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        case errSecMissingEntitlement:
            throw SecretStoreError.keychainUnavailable(status)
        default:
            throw SecretStoreError.keychainFailure(status)
        }
    }

    func deleteAll(service: String) throws {
        // Match on the service only (no account) so every item under it is removed.
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        KeychainPlatform.apply(to: &query)
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        case errSecMissingEntitlement:
            throw SecretStoreError.keychainUnavailable(status)
        default:
            throw SecretStoreError.keychainFailure(status)
        }
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        KeychainPlatform.apply(to: &query)
        return query
    }
}

/// Production composite: Keychain first, encrypted-file fallback when — and only when — the
/// Keychain refuses the operation for this process. On iOS the Keychain always works and the
/// fallback file is never created — behaviour unchanged. On a team-signed Mac build the same
/// holds. On the ad-hoc Mac build every Keychain operation is refused, so reads/writes
/// transparently land in the AES-GCM sealed file (see `EncryptedFileSecretPersisting`).
///
/// Two distinct refusal modes are observed on ad-hoc Catalyst (measured, securityd log):
///   - **Writes** (`SecItemAdd`/`SecItemUpdate`/`SecItemDelete`) throw `errSecMissingEntitlement`
///     (-34018). These fault the composite into `fallbackEngaged`.
///   - **Reads** (`SecItemCopyMatching`) return `errSecItemNotFound` rather than -34018 — they
///     appear to "succeed, finding nothing" against the empty keychain. `get` reads through so a
///     not-found from the Keychain still consults the (value-bearing) fallback file.
final class FallbackSecretPersisting: SecretPersisting {
    let primary: SecretPersisting
    let fallback: SecretPersisting

    /// True once any operation had to be routed around the Keychain (a `-34018` write was
    /// observed). Once latched, the composite treats the Keychain as unusable for this process
    /// and reports it as such (writes keep trying primary-first; reads read-through). Class
    /// (not struct), so the composite can flip this once the -34018 path is observed.
    private(set) var fallbackEngaged = false

    init(primary: SecretPersisting, fallback: SecretPersisting) {
        self.primary = primary
        self.fallback = fallback
    }

    var backendDescription: String {
        fallbackEngaged ? "Keychain unavailable → " + fallback.backendDescription : primary.backendDescription
    }

    // MARK: Read path
    //
    // Reads need extra care because a broken Keychain does not *throw* on ad-hoc Catalyst: a
    // `SecItemCopyMatching` against the empty (inaccessible) keychain returns
    // `errSecItemNotFound` rather than `errSecMissingEntitlement` (-34018), while the matching
    // *write* (`SecItemAdd`/`SecItemUpdate`/`SecItemDelete`) fails -34018 (measured; securityd
    // logs the -34018 on writes and returns not-found on reads). So a plain `return
    // try primary.get(...)` would read nil forever and never reach the value that an earlier
    // -34018 write put into the fallback file — silently breaking relaunch persistence.
    //
    // `get` therefore reads through: it tries the primary, and when the primary reports "not
    // found" it also consults the fallback. On iOS / a team-signed Mac the fallback is never
    // written, so this second probe is a no-op read of an absent store. Latches `fallbackEngaged`
    // only when the fallback actually returns a value. Genuine keychain failures still propagate.
    func get(service: String, account: String) throws -> Data? {
        do {
            let primaryValue = try primary.get(service: service, account: account)
            if primaryValue != nil {
                return primaryValue
            }
            // Not in the Keychain. Consult the (never-written-on-working-platforms) fallback
            // read-through; ignore a broken fallback rather than masking a legitimate miss.
            if let fallbackValue = try? fallback.get(service: service, account: account) {
                fallbackEngaged = true
                return fallbackValue
            }
            return nil
        } catch SecretStoreError.keychainUnavailable {
            fallbackEngaged = true
            return try fallback.get(service: service, account: account)
        }
    }

    func set(service: String, account: String, value: Data) throws {
        do {
            try primary.set(service: service, account: account, value: value)
        } catch SecretStoreError.keychainUnavailable {
            fallbackEngaged = true
            try fallback.set(service: service, account: account, value: value)
        }
    }

    func delete(service: String, account: String) throws {
        do {
            try primary.delete(service: service, account: account)
        } catch SecretStoreError.keychainUnavailable {
            fallbackEngaged = true
            try fallback.delete(service: service, account: account)
        }
    }

    func deleteAll(service: String) throws {
        do {
            try primary.deleteAll(service: service)
        } catch SecretStoreError.keychainUnavailable {
            fallbackEngaged = true
            try fallback.deleteAll(service: service)
        }
    }
}

/// Factory for the shell's default secret persistence — the one `SecureVault()` / `CertTrust()`
/// use when callers don't inject a store.
enum SecretStore {
    static func makeDefault() -> SecretPersisting {
        FallbackSecretPersisting(
            primary: KeychainSecretPersisting(),
            fallback: EncryptedFileSecretPersisting.makeDefault()
        )
    }
}