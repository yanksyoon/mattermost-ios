import Foundation
import WebKit
import XCTest
@testable import Mattermost

// t_249bc296 — the production paths that reached WebKit cookie IO off-main.
//
// `WKWebsiteDataStore` / `WKHTTPCookieStore` are UI-process API and are not executor-neutral: a
// per-identifier store resolves through `WebKit::allDataStores()`, and the first cookie call creates
// the store's WebKit **Networking** process on the calling thread — that path traps off-main
// (`EXC_BREAKPOINT`, crash report `Mattermost-2026-11-05-073146.ips`, root-caused on t_d393d211).
//
// Every case below enters the production types from a **nonisolated** async test method: that is
// the cooperative-pool executor the crash was measured on, and the executor the diagnostics step
// closures really run on. Each one is a must-run real-store case — no skip, no gate; a skip is
// exactly how the defect survived its first round. Do not mark this class `@MainActor`: the caller's
// executor is the subject.
//
// One measured detail these cases share: a `WKWebsiteDataStore(forIdentifier:)` that nothing holds
// on to is torn down, and a *later* instance of the same identifier starts empty (measured here —
// seed, release the store, re-resolve it, `allCookies() == []`). The app always holds one per server
// (`ViewStore.ensureStore` keeps a `WebViewStore`, whose `WKWebViewConfiguration` owns the store), so
// each case holds its store for the length of the test, exactly as the app does.
final class T249bc296WebKitCookieIsolationTests: XCTestCase {

    private let serverURL = URL(string: "https://mm.example.com")!

    // MARK: - Store helpers (main actor: the store is created where WebKit expects to be entered)

    private func cookie(_ name: String, _ value: String) throws -> HTTPCookie {
        try XCTUnwrap(HTTPCookie(properties: [
            .name: name, .value: value, .domain: "mm.example.com", .path: "/",
        ]))
    }

    /// The app's per-server store, created where WebKit expects to be entered. The case keeps the
    /// returned object alive for its whole body (see the note at the top of the file).
    @MainActor
    private func makeStore(_ serverID: UUID) -> WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: serverID)
    }

    /// Seed through the **verifying** installer, not bare `setCookie`: a write into a store whose
    /// Networking process is still coming up is dropped without an error (measured, t_4528b67e — see
    /// the note on `WebSessionCookieInstaller`). Seeding with a raw `setCookie` would leave these
    /// cases asserting against an empty store.
    @MainActor
    private func seed(_ cookies: [HTTPCookie], in store: WKWebsiteDataStore) async {
        let notStored = await WebSessionCookieInstaller(dataStore: store).install(cookies)
        XCTAssertTrue(notStored.isEmpty, "seed cookies never landed in the store: \(notStored)")
    }

    @MainActor
    private func names(in store: WKWebsiteDataStore) async -> [String] {
        let cookies = await store.httpCookieStore.allCookies()
        return cookies.map(\.name)
    }

    @MainActor
    private func wipe(_ store: WKWebsiteDataStore) async {
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                               modifiedSince: .distantPast)
    }

    // MARK: - Diagnostics step-4 / step-11 reader

    /// `WebKitCookieSessionProvider.sessionData` is awaited from `DiagnosticStep.run`, a nonisolated
    /// async closure. Before t_249bc296 that put `WKWebsiteDataStore(forIdentifier:)` and
    /// `allCookies()` on a cooperative thread; the store work now happens on the main actor.
    func testTheDiagnosticsSessionProviderReadsTheServersStoreFromANonisolatedCaller() async throws {
        let server = ServerConfig(name: "T", url: serverURL)
        let store = await makeStore(server.id)
        defer { withExtendedLifetime(store) {} }
        let seeded = try [cookie("MMUSERID", "u1"),
                          cookie("MMCSRF", "csrf-1"),
                          cookie("MMAUTHTOKEN", "tok-1")]
        await seed(seeded, in: store)

        let snapshot = await WebKitCookieSessionProvider().sessionData(for: server)

        XCTAssertTrue(snapshot.hasUserID, "the reader sees MMUSERID in the server's own store")
        XCTAssertTrue(snapshot.hasCSRF, "the reader sees MMCSRF in the server's own store")
        XCTAssertTrue(snapshot.hasAuthToken, "the reader sees MMAUTHTOKEN in the server's own store")

        await wipe(store)
    }

    /// A store that holds none of the three cookies must read as all-absent, not as an error — this
    /// is the signed-out row of the diagnostics report.
    func testTheDiagnosticsSessionProviderReportsAbsentCookiesFromANonisolatedCaller() async throws {
        let server = ServerConfig(name: "T", url: serverURL)
        let store = await makeStore(server.id)
        defer { withExtendedLifetime(store) {} }
        let seeded = try [cookie("MMCSRF", "csrf-1")]
        await seed(seeded, in: store)

        let snapshot = await WebKitCookieSessionProvider().sessionData(for: server)

        XCTAssertFalse(snapshot.hasUserID)
        XCTAssertTrue(snapshot.hasCSRF)
        XCTAssertFalse(snapshot.hasAuthToken)

        await wipe(store)
    }

    // MARK: - Sign-out clearing

    /// `WebKitSessionCookieClearing.clearAuthCookie` is the webview half of sign-out. `deleteCookie`
    /// needs the same networking process as `setCookie`, so it carries the same off-main trap; the
    /// store work now happens on the main actor, and this case proves the clear still lands when the
    /// caller is not on the main actor.
    func testSignOutCookieClearingRemovesOnlyTheAuthCookieFromANonisolatedCaller() async throws {
        let serverID = UUID()
        let store = await makeStore(serverID)
        defer { withExtendedLifetime(store) {} }
        let seeded = try [cookie("MMAUTHTOKEN", "sso-token-offmain"),
                          cookie("MMCSRF", "csrf-1")]
        await seed(seeded, in: store)

        await WebKitSessionCookieClearing().clearAuthCookie(for: serverURL, serverID: serverID)

        let remaining = await WebKitSessionCookieReader(serverID: serverID).authToken(for: serverURL)
        XCTAssertNil(remaining, "the MMAUTHTOKEN cookie is gone after the sign-out clear")
        let remainingNames = await names(in: store)
        XCTAssertTrue(remainingNames.contains("MMCSRF"),
                      "an unrelated cookie on the same server is untouched")

        await wipe(store)
    }

    // MARK: - The session reader's own store resolution

    /// `WebKitSessionCookieReader(serverID:)` used to resolve its store in the **initializer**, which
    /// is a nonisolated call site: t_249bc296 reproduced the `EXC_BREAKPOINT` there ("Test crashed
    /// with signal trap") from exactly this kind of test. Construction is now a plain value again and
    /// the store is resolved on the main actor inside `authToken(for:)`.
    func testTheSessionCookieReaderIsConstructibleAndUsableFromANonisolatedCaller() async throws {
        let serverID = UUID()
        let store = await makeStore(serverID)
        defer { withExtendedLifetime(store) {} }
        let seeded = try [cookie("MMAUTHTOKEN", "reader-token-offmain")]
        await seed(seeded, in: store)

        let token = await WebKitSessionCookieReader(serverID: serverID).authToken(for: serverURL)

        XCTAssertEqual(token, "reader-token-offmain",
                       "the reader answers from the server's own store when built off-main")

        await wipe(store)
    }
}
