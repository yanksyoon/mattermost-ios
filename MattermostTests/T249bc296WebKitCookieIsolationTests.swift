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
//
// t_e687bad5 — every `await` in this file that crosses WebKit's XPC boundary is bounded and named.
// The calls that can stall are the installer's writes and reads, `allCookies`, the production
// diagnostics reader / sign-out clearer / session reader, and the cleanup `removeData`. Each is
// awaited through `requireWebKitAnswer` (a hang detector, `T28TestSupport`): an answer is
// returned at its own cost, and a host whose WebKit Networking service never comes up **skips** the
// case naming the call instead of burning the 300 s allowance and reddening the gate unlabelled
// (run `43240373846` — `docs/t_a5321d5e-build-note.md`). The wipe is best-effort
// (`withWebKitAnswer`, result ignored) so a silent host cannot red a case after its assertions ran.
//
// The seed write in `seed(_:in:)` is the one call in each case that starts that store's WebKit
// service, so it carries the 60 s cold-store window; everything after it stays on the 15 s ambient
// detector. Measured on the hosted runner (card `t_efd0a2ad`): that call answers at 38.330 s in one
// case and never answers in the next, so a single 15 s window cannot tell the two apart.
//
// Two things deliberately stay outside the wrapper:
//
//   * `WKWebsiteDataStore(forIdentifier:)` is a synchronous registry lookup, not an XPC round trip
//     (13.9 ms measured on t_a5321d5e), so there is no wait to bound; and
//   * the construction of `WebKitSessionCookieReader` happens in the case body, at this class's own
//     nonisolated isolation, because "the store must not be resolved in a nonisolated initializer"
//     is itself one of the claims here (see the last case). Hoisting it out of the closure keeps
//     that construction where the class means it to be measured.
//
// The wrapper is `@MainActor`, but the methods it awaits (`sessionData`, `clearAuthCookie`,
// `authToken`, `install`) are nonisolated async functions: they do not inherit the wrapper's actor
// (SE-0338), they run on the cooperative pool — the executor these cases are about — and the wrapper
// only bounds how long the case waits for them. So the bound does not move the subject.
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
    ///
    /// Bounded (t_e687bad5): the installer's `setCookie`/`allCookies` rounds are the first calls that
    /// start the store's Networking service, so they are the most likely of all of these to be the
    /// one that never comes back. Silence is a skip naming the installer, not a hang: the assertions
    /// below cannot mean anything against a store that was never seeded.
    ///
    /// The window is the **cold-store** one (60 s), not the 15 s ambient detector: this is the call
    /// that starts WebKit's Networking service for a fresh per-server store, and on the hosted runner
    /// it is measured at 38.330 s when it answers at all (run `43315247724`; see
    /// `WebKitAnswerWindow`, card `t_efd0a2ad`).
    @MainActor
    private func seed(_ cookies: [HTTPCookie], in store: WKWebsiteDataStore) async throws {
        let notStored = try await requireWebKitAnswer(
            "WebSessionCookieInstaller.install(\(cookies.map(\.name).joined(separator: ",")))",
            timeout: WebKitAnswerWindow.coldStore
        ) {
            await WebSessionCookieInstaller(dataStore: store).install(cookies)
        }
        XCTAssertTrue(notStored.isEmpty, "seed cookies never landed in the store: \(notStored)")
    }

    @MainActor
    private func names(in store: WKWebsiteDataStore) async throws -> [String] {
        let cookies = try await requireWebKitAnswer("httpCookieStore.allCookies") {
            await store.httpCookieStore.allCookies()
        }
        return cookies.map(\.name)
    }

    /// Best effort on purpose: every assertion of the case has already run when this is called, so a
    /// host that will not answer the wipe either must not turn the case red after the fact (the rule
    /// t_a5321d5e's T31 case keeps for its trailing `removeData`).
    @MainActor
    private func wipe(_ store: WKWebsiteDataStore) async {
        _ = await withWebKitAnswer("removeData(allWebsiteDataTypes)") {
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                   modifiedSince: .distantPast)
        }
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
        try await seed(seeded, in: store)

        let snapshot = try await requireWebKitAnswer("WebKitCookieSessionProvider.sessionData") {
            await WebKitCookieSessionProvider().sessionData(for: server)
        }

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
        try await seed(seeded, in: store)

        let snapshot = try await requireWebKitAnswer("WebKitCookieSessionProvider.sessionData") {
            await WebKitCookieSessionProvider().sessionData(for: server)
        }

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
    ///
    /// Both store calls are bounded (t_e687bad5), and the reader is built here, in the test body,
    /// rather than inside the wrapped closure — see the note at the top of the file.
    func testSignOutCookieClearingRemovesOnlyTheAuthCookieFromANonisolatedCaller() async throws {
        let serverID = UUID()
        let url = serverURL
        let store = await makeStore(serverID)
        defer { withExtendedLifetime(store) {} }
        let seeded = try [cookie("MMAUTHTOKEN", "sso-token-offmain"),
                          cookie("MMCSRF", "csrf-1")]
        try await seed(seeded, in: store)

        try await requireWebKitAnswer("WebKitSessionCookieClearing.clearAuthCookie") {
            await WebKitSessionCookieClearing().clearAuthCookie(for: url, serverID: serverID)
        }

        let reader = WebKitSessionCookieReader(serverID: serverID)
        let remaining = try await requireWebKitAnswer("WebKitSessionCookieReader.authToken") {
            await reader.authToken(for: url)
        }
        XCTAssertNil(remaining, "the MMAUTHTOKEN cookie is gone after the sign-out clear")
        let remainingNames = try await names(in: store)
        XCTAssertTrue(remainingNames.contains("MMCSRF"),
                      "an unrelated cookie on the same server is untouched")

        await wipe(store)
    }

    // MARK: - The session reader's own store resolution

    /// `WebKitSessionCookieReader(serverID:)` used to resolve its store in the **initializer**, which
    /// is a nonisolated call site: t_249bc296 reproduced the `EXC_BREAKPOINT` there ("Test crashed
    /// with signal trap") from exactly this kind of test. Construction is now a plain value again and
    /// the store is resolved on the main actor inside `authToken(for:)`.
    ///
    /// That is why the construction stays on this method's own (nonisolated) executor and only the
    /// `authToken` await is wrapped (t_e687bad5): a bound that also moved the initializer onto the
    /// main actor would stop measuring the very call site this case exists for.
    func testTheSessionCookieReaderIsConstructibleAndUsableFromANonisolatedCaller() async throws {
        let serverID = UUID()
        let url = serverURL
        let store = await makeStore(serverID)
        defer { withExtendedLifetime(store) {} }
        let seeded = try [cookie("MMAUTHTOKEN", "reader-token-offmain")]
        try await seed(seeded, in: store)

        let reader = WebKitSessionCookieReader(serverID: serverID)
        let token = try await requireWebKitAnswer("WebKitSessionCookieReader.authToken") {
            await reader.authToken(for: url)
        }

        XCTAssertEqual(token, "reader-token-offmain",
                       "the reader answers from the server's own store when built off-main")

        await wipe(store)
    }
}
