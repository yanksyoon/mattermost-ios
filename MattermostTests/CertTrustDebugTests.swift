import XCTest
@testable import Mattermost

final class CertTrustDebugTests: XCTestCase {
    func testDebugFreshStoreLookup() throws {
        let store = CertTrust(serviceNamespace: "DebugUnique-\(UUID().uuidString)")
        let url = URL(string: "https://mattermost-dev.example")!
        let rec = store.trustedCertificate(for: url)
        print("DEBUG stored(for: \(url)) = \(String(describing: rec))")
        print("DEBUG isExisting = \(store.isExisting(for: url))")
        print("DEBUG isExplicitlyUntrusted = \(store.isExplicitlyUntrusted(for: url))")
        // Trigger a read path and print status via a false call
        MXPrintKeychain();
        XCTAssertTrue(true)
    }

    func MXPrintKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        print("DEBUG all-generic-password status=\(status)")
        if let arr = result as? [[String: Any]] {
            for item in arr {
                if let svc = item[kSecAttrService as String] as? String,
                   let acct = item[kSecAttrAccount as String] as? String {
                    print("DEBUG   item service=\(svc) account=\(acct)")
                }
            }
        }
    }
}