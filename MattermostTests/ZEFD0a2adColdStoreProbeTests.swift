import Foundation
import WebKit
import XCTest
@testable import Mattermost

// t_efd0a2ad — TEMPORARY MEASUREMENT. Deleted by the decision commit.
//
// The question this answers on a real hosted runner: when the first cookie write into a fresh
// per-server `WKWebsiteDataStore` *does* answer, what does it cost? The gate pass has one healthy
// call at 13.991 s (T31WebSessionHarvestTests) and one skip at 15.012 s (T31SSOViewModelTests), both
// against a 15 s window, and the case line alone cannot tell a slow-but-alive call from a dead one.
//
// The class is named `Z…` on purpose: XCTest runs classes in name order, so it runs *after* every
// real class in the gate pass and cannot pay the process's first WebKit cost on their behalf. What
// it measures is therefore the cost of a fresh store after WebKit is already up — and, by running
// four fresh stores in a row, whether that cost is per **process** (first one expensive, the rest
// cheap) or per **store** (every fresh store pays it).
//
// Every `await` goes through `withWebKitAnswer` with a 120 s window, and that helper logs one
// `WEBKITPROBE …` line per call with its own elapsed time, so the number is per call and not
// inferred from a case total.
@MainActor
final class ZEFD0a2adColdStoreProbeTests: XCTestCase {

    private func cookie(_ name: String, _ value: String) throws -> HTTPCookie {
        try XCTUnwrap(HTTPCookie(properties: [
            .name: name,
            .value: value,
            .domain: "mm.example.com",
            .path: "/",
            .expires: Date().addingTimeInterval(3600),
        ]))
    }

    /// Four fresh stores, each: first write, second write, read back, wipe.
    func testWhatAFreshStoresFirstCookieWriteCosts() async throws {
        NSLog("%@", "WEBKITPROBE probe start, uptime \(ProcessInfo.processInfo.systemUptime) s")

        for index in 1...4 {
            let store = WKWebsiteDataStore(forIdentifier: UUID())
            let auth = try cookie("MMAUTHTOKEN", "probe-\(index)")
            let csrf = try cookie("MMCSRF", "csrf-\(index)")

            _ = await withWebKitAnswer("probe#\(index).setCookie(MMAUTHTOKEN) first",
                                       timeout: 120) {
                await store.httpCookieStore.setCookie(auth)
            }
            _ = await withWebKitAnswer("probe#\(index).setCookie(MMCSRF) second",
                                       timeout: 120) {
                await store.httpCookieStore.setCookie(csrf)
            }
            _ = await withWebKitAnswer("probe#\(index).allCookies", timeout: 120) {
                await store.httpCookieStore.allCookies()
            }
            _ = await withWebKitAnswer("probe#\(index).removeData", timeout: 120) {
                await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                       modifiedSince: .distantPast)
            }
        }

        NSLog("%@", "WEBKITPROBE probe end, uptime \(ProcessInfo.processInfo.systemUptime) s")
    }
}
