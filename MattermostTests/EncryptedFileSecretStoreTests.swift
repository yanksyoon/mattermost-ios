import XCTest
@testable import Mattermost

/// Unit tests for `EncryptedFileSecretPersisting`, the AES-GCM sealed-file fallback used only
/// when the Keychain rejects every call (-34018, ad-hoc Mac Catalyst).
///
/// These exercise the file backend directly in a temp directory: round-trip, relaunch
/// persistence (fresh instance, same directory), delete semantics, per-service isolation, and
/// the two security properties the fallback actually provides — the payload on disk is NOT
/// plaintext, and both files are owner-read/write only.
final class EncryptedFileSecretStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EncryptedFileSecretStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() throws -> EncryptedFileSecretPersisting {
        EncryptedFileSecretPersisting(directory: dir)
    }

    private func sampleData(_ text: String) -> Data { Data(text.utf8) }

    // MARK: Round-trip + persistence

    func testSetGetRoundTrip() throws {
        let store = try makeStore()
        try store.set(service: "svc-a", account: "acct-1", value: sampleData("token-1"))
        XCTAssertEqual(try store.get(service: "svc-a", account: "acct-1"), sampleData("token-1"))
    }

    func testValueSurvivesFreshInstance_simulatingRelaunch() throws {
        let first = try makeStore()
        try first.set(service: "svc-a", account: "acct-1", value: sampleData("persist-me"))

        // A brand-new store object on the same directory (as after a relaunch) must read the
        // same value back — the sealed file is durable on disk, not held in memory.
        let second = try makeStore()
        XCTAssertEqual(try second.get(service: "svc-a", account: "acct-1"), sampleData("persist-me"))
    }

    func testOverwriteReplacesValue() throws {
        let store = try makeStore()
        try store.set(service: "svc-a", account: "acct-1", value: sampleData("v1"))
        try store.set(service: "svc-a", account: "acct-1", value: sampleData("v2"))
        XCTAssertEqual(try store.get(service: "svc-a", account: "acct-1"), sampleData("v2"))
    }

    // MARK: Per-service / per-account isolation

    func testValuesAreIsolatedPerServiceAndAccount() throws {
        let store = try makeStore()
        try store.set(service: "svc-a", account: "acct-1", value: sampleData("A1"))
        try store.set(service: "svc-a", account: "acct-2", value: sampleData("A2"))
        try store.set(service: "svc-b", account: "acct-1", value: sampleData("B1"))
        XCTAssertEqual(try store.get(service: "svc-a", account: "acct-1"), sampleData("A1"))
        XCTAssertEqual(try store.get(service: "svc-a", account: "acct-2"), sampleData("A2"))
        XCTAssertEqual(try store.get(service: "svc-b", account: "acct-1"), sampleData("B1"))
        XCTAssertNil(try store.get(service: "svc-b", account: "acct-2"))
    }

    // MARK: Delete semantics

    func testDeleteRemovesValue() throws {
        let store = try makeStore()
        try store.set(service: "svc-a", account: "acct-1", value: sampleData("dying"))
        try store.delete(service: "svc-a", account: "acct-1")
        XCTAssertNil(try store.get(service: "svc-a", account: "acct-1"))
    }

    func testDeleteMissingIsNoOp() throws {
        let store = try makeStore()
        XCTAssertNoThrow(try store.delete(service: "svc-a", account: "nope"))
    }

    func testDeleteAllClearsEveryAccountInService() throws {
        let store = try makeStore()
        try store.set(service: "svc-a", account: "acct-1", value: sampleData("A1"))
        try store.set(service: "svc-a", account: "acct-2", value: sampleData("A2"))
        try store.set(service: "svc-b", account: "acct-1", value: sampleData("B1"))
        try store.deleteAll(service: "svc-a")
        XCTAssertNil(try store.get(service: "svc-a", account: "acct-1"))
        XCTAssertNil(try store.get(service: "svc-a", account: "acct-2"))
        XCTAssertEqual(try store.get(service: "svc-b", account: "acct-1"), sampleData("B1"))
    }

    // MARK: Security posture of the at-rest files

    func testPayloadOnDiskIsNotPlaintext() throws {
        let secret = "super-secret-token-42-\(UUID().uuidString)"
        let store = try makeStore()
        try store.set(service: "svc-a", account: "acct-1", value: sampleData(secret))

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.keyFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.dataFile.path))

        let ciphertext = try Data(contentsOf: store.dataFile)
        let asString = String(data: ciphertext, encoding: .utf8) ?? ""
        XCTAssertFalse(asString.contains(secret),
                       "The sealed payload must not contain the plaintext secret")
        // And it is not a plaintext JSON dictionary containing the value either.
        XCTAssertNil(try? JSONSerialization.jsonObject(with: ciphertext) as? [String: Any],
                     "The payload must be a sealed box, not readable JSON")
    }

    func testFilesAreOwnerReadWriteOnly() throws {
        let store = try makeStore()
        try store.set(service: "svc-a", account: "acct-1", value: sampleData("x"))
        for url in [store.keyFile, store.dataFile] {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
            XCTAssertEqual(perms & 0o777, 0o600, "\(url.lastPathComponent) must be 0600 (got \(String(perms, radix: 8)))")
        }
    }

    func testKeyFileIsReusedAcrossWrites() throws {
        let store = try makeStore()
        try store.set(service: "svc-a", account: "acct-1", value: sampleData("first"))
        let keyBefore = try Data(contentsOf: store.keyFile)
        try store.set(service: "svc-b", account: "acct-2", value: sampleData("second"))
        let keyAfter = try Data(contentsOf: store.keyFile)
        XCTAssertEqual(keyBefore, keyAfter,
                       "The key must be created once and reused, so earlier values stay decryptable")
    }

    // MARK: Corruption / tamper handling

    func testCorruptPayloadReadsAsEmptyWithoutThrowing() throws {
        let store = try makeStore()
        try store.set(service: "svc-a", account: "acct-1", value: sampleData("real"))

        // Tamper with the sealed payload in place, then read with a fresh instance (cold load).
        try Data("garbage-garbage".utf8).write(to: store.dataFile, options: .atomic)
        let fresh = try makeStore()
        XCTAssertNoThrow(try fresh.get(service: "svc-a", account: "acct-1"))
        XCTAssertNil(try fresh.get(service: "svc-a", account: "acct-1"),
                     "A corrupt payload is treated as an empty store, not a crash")
    }
}
