import Foundation
import CryptoKit

/// File-backed encrypted secret store — the non-Keychain fallback used ONLY when the Keychain
/// itself is unavailable (`errSecMissingEntitlement`, -34018, ad-hoc Mac Catalyst). The Keychain
/// stays primary on every platform; this class is only reached through
/// `FallbackSecretPersisting` when the Keychain rejects the operation.
///
/// Layout under Application Support/Mattermost/:
/// - `vault-secrets.json.enc` — the payload, a JSON dictionary `service → account → base64 value`,
///   sealed with AES-GCM (CryptoKit) under a 256-bit random key.
/// - `vault-secrets.key` — the key, 0600. Both files are written atomically with
///   owner-read/write-only POSIX permissions.
///
/// Honest security note: without a Keychain there is no hardware-backed encryption key on this
/// machine, so the key sits in a 0600 file next to the data. That protects the payload from
/// casual exposure, accidental sharing, and non-privileged readers, but it is NOT
/// hardware-device-backed like the real Keychain path — malware running as the same user can
/// read both files. That is the unavoidable tradeoff of running an ad-hoc-signed Catalyst
/// binary with no `application-identifier` entitlement, and it mirrors Electron `safeStorage`'s
/// Linux fallback (which is plaintext with a warning). Team-signed builds never touch this
/// store (the Keychain works).
///
/// Interface stability: values are addressed by `(service, account)`, the same primary key the
/// Keychain backend uses, so `SecureVault` and `CertTrust` route through either backend with no
/// key-mapping changes.
final class EncryptedFileSecretPersisting: SecretPersisting {

    /// The default location: `~/Library/Application Support/Mattermost/`.
    static func makeDefault() -> EncryptedFileSecretPersisting {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = support.appendingPathComponent("Mattermost", isDirectory: true)
        return EncryptedFileSecretPersisting(directory: directory)
    }

    let directory: URL
    let dataFile: URL
    let keyFile: URL

    var backendDescription: String { "Encrypted file \(dataFile.path)" }

    private let lock = NSLock()
    /// service → account → value; the in-memory mirror of the sealed file.
    private var cache: [String: [String: Data]] = [:]
    private var loaded = false
    private var cipherKey: SymmetricKey?

    init(directory: URL) {
        self.directory = directory
        self.dataFile = directory.appendingPathComponent("vault-secrets.json.enc")
        self.keyFile = directory.appendingPathComponent("vault-secrets.key")
    }

    // MARK: SecretPersisting

    func get(service: String, account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        try loadLocked()
        return cache[service]?[account]
    }

    func set(service: String, account: String, value: Data) throws {
        lock.lock(); defer { lock.unlock() }
        try loadLocked()
        cache[service, default: [:]][account] = value
        try persistLocked()
    }

    func delete(service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        try loadLocked()
        guard cache[service]?.removeValue(forKey: account) != nil else { return }
        try persistLocked()
    }

    func deleteAll(service: String) throws {
        lock.lock(); defer { lock.unlock() }
        try loadLocked()
        guard cache.removeValue(forKey: service) != nil else { return }
        try persistLocked()
    }

    // MARK: File plumbing

    /// Load the key and payload once. Missing files = a fresh store (empty). A corrupt or
    /// unreadable payload is logged and treated as empty rather than crashing the shell.
    private func loadLocked() throws {
        guard !loaded else { return }
        loaded = true

        // Reuse an existing key even if the payload is missing (e.g. first write crashed
        // between the two writes) so a later persist doesn't orphan earlier data under a
        // regenerated key.
        if let keyData = try? Data(contentsOf: keyFile) {
            cipherKey = SymmetricKey(data: keyData)
        }

        guard FileManager.default.fileExists(atPath: keyFile.path),
              FileManager.default.fileExists(atPath: dataFile.path),
              let sealedData = try? Data(contentsOf: dataFile),
              let key = cipherKey,
              let combined = try? AES.GCM.SealedBox(combined: sealedData),
              let payload = try? AES.GCM.open(combined, using: key),
              let dict = try? JSONSerialization.jsonObject(with: payload) as? [String: [String: String]]
        else {
            Logger.error("SecretStore", "fallback payload missing/corrupt at \(dataFile.path); starting empty")
            return
        }

        var decoded: [String: [String: Data]] = [:]
        for (service, accounts) in dict {
            var row: [String: Data] = [:]
            for (account, base64) in accounts {
                if let value = Data(base64Encoded: base64) {
                    row[account] = value
                }
            }
            decoded[service] = row
        }
        cache = decoded
    }

    /// Serialize, encrypt, and atomically persist the whole cache.
    private func persistLocked() throws {
        let key: SymmetricKey
        if let existing = cipherKey {
            key = existing
        } else {
            let fresh = SymmetricKey(size: .bits256)
            let keyData = fresh.withUnsafeBytes { Data($0) }
            try write(keyData, to: keyFile)
            cipherKey = fresh
            key = fresh
        }

        var plain: [String: [String: String]] = [:]
        for (service, accounts) in cache {
            var row: [String: String] = [:]
            for (account, value) in accounts {
                row[account] = value.base64EncodedString()
            }
            plain[service] = row
        }
        // `JSONSerialization.data` returns `Data?`; fail loud rather than silently dropping data.
        guard let payload = try? JSONSerialization.data(withJSONObject: plain) else {
            throw NSError(domain: "SecretStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "failed to serialize the secret-store payload"])
        }
        let sealed = try AES.GCM.seal(payload, using: key)
        guard let combined = sealed.combined else {
            throw NSError(domain: "SecretStore", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "sealed-box produced no combined bytes"])
        }
        try write(combined, to: dataFile)
    }

    /// Atomic, owner-only write (creates the directory on first use).
    private func write(_ contents: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
