import Foundation
import WebKit
import Combine

/// Maps each configured server (by uuid) to its own `WKWebView` + **isolated** persistent
/// `WKWebsiteDataStore`. Native counterpart of desktop `ViewManager` (`views/viewManager.ts`):
/// one web contents view per server, with a tracked "primary" view.
/// Parity row: `ViewManager` -> `ViewStore`. Status: native, P1.2/P1.3.
///
/// Why a store per server: the shell keeps every server's webview alive for the app's lifetime
/// (desktop keeps tabs' web contents alive too), so switching back to a server is instant and
/// does not re-run sign-in. Isolation comes from `WKWebsiteDataStore(forIdentifier:)` keyed by
/// the server's uuid — cookies, localStorage and IndexedDB (i.e. the Mattermost session) are
/// strictly per-server, so two servers can be signed in as different users simultaneously.
///
/// **Warm by default, released only on a pane-owning approval** (`docs/dual-render.md` §12):
/// `release(serverID:)` destroys a store (WKWebView + its WebContent process) when — and only
/// when — an `-AV`-approved, pane-owning native card renders the whole work area that webview
/// used to paint. Both registries are empty today, so no store is ever released in a shipping
/// configuration; the policy is the mechanism, not a behaviour change.
@MainActor
final class ViewStore: ObservableObject {

    /// The server whose scene is currently on screen. Drives which scene is visible; the other
    /// scenes stay mounted (hidden) so their webviews keep their state.
    @Published private(set) var primaryServerID: UUID?

    /// Per-server webview stores. Deliberately **not** `@Published`: views call `view(for:)`
    /// while building their body, and publishing from inside a body update would loop.
    /// Scene identity is driven by `ServerStore.servers` instead.
    private(set) var stores: [UUID: WebViewStore] = [:]

    /// The last page a server's webview had committed when it was released, so the return trip
    /// can land on the channel the user was on instead of the server root (§12.3).
    ///
    /// Plain `private(set)`, **not** `@Published`: it is read from `WebPaneHost`'s appearance and
    /// never rendered, so publishing it would only add body invalidations (the same reason
    /// `stores` is not published).
    private(set) var lastURLs: [UUID: URL] = [:]

    /// Invalidation signal for store **membership**: bumped whenever a store is created, released
    /// or removed.
    ///
    /// `stores` itself must not be published (views read it during body construction), but the
    /// *existence* of a store does have to re-run `RootView`'s body: the webview-only Back/Reload
    /// toolbar must disappear when a pane is released and must come back when the web branch
    /// re-creates its store (§12.4). This counter is only mutated from lifecycle callbacks —
    /// never from a body pass — so observing it cannot loop; `RootView` does not even have to read
    /// it, it only has to be published so the observation fires.
    @Published private(set) var storeGeneration: Int = 0

    init() {}

    // MARK: Access

    /// The store for a server, created on first use and reused afterwards. Calling this twice
    /// for the same server returns the identical instance (session continuity).
    ///
    /// This is the **creating** accessor (`docs/dual-render.md` §12.4, "the resurrection trap"):
    /// it may only be called from lifecycle callbacks — `RootView`'s appearance/activation, the
    /// web pane's own appearance, and the perf seam — never from a view body, or a released store
    /// would be resurrected by a SwiftUI update pass. Reads go through `view(forServerID:)`.
    @discardableResult
    func ensureStore(for server: ServerConfig) -> WebViewStore {
        if let existing = stores[server.id] { return existing }
        let store = WebViewStore(dataStoreIdentifier: server.id)
        stores[server.id] = store
        storeGeneration &+= 1
        return store
    }

    /// Non-creating read: the store for a server **iff** one is alive. `nil` means the pane is
    /// released (or the server was never warmed), and callers must not create one.
    func view(forServerID id: UUID) -> WebViewStore? {
        stores[id]
    }

    /// All mounted stores, ordered by the servers' display order.
    func mountedStores(for servers: [ServerConfig]) -> [WebViewStore] {
        servers.compactMap { stores[$0.id] }
    }

    // MARK: Release (T26-R R4, docs/dual-render.md §12)

    /// Destroy a server's webview because an approved, pane-owning native card now renders the
    /// whole work area it used to paint.
    ///
    /// Exactly the three steps §12.2 names, and nothing else:
    ///  1. `stopLoading()` — the page must not keep fetching while it is going away;
    ///  2. drop the navigation/UI delegates — nothing may answer a late WebKit callback for a
    ///     store that is being destroyed;
    ///  3. remember the committed URL in `lastURLs` and drop the store, which deallocates the
    ///     `WKWebView` and lets WebKit terminate its WebContent process (destroy, not park).
    ///
    /// It deliberately does **not** call `WKWebsiteDataStore.remove(forIdentifier:)` — that is
    /// `remove(serverID:)` (an explicit server removal) and it is the only path that logs the
    /// user out. The session (cookies / localStorage / IndexedDB in the persistent per-server
    /// data store) therefore survives a release, which is what makes the return trip one page
    /// load instead of a re-login (§12.3). It also does not touch `mm.surfaceModes`: releasing a
    /// webview is not a render-mode decision and must never write one.
    ///
    /// Idempotent: releasing a server with no live store is a no-op, so a sweep that runs on
    /// every appearance/`onChange` is safe.
    func release(serverID: UUID) {
        guard let store = stores.removeValue(forKey: serverID) else { return }
        store.stopLoading()
        store.webView.navigationDelegate = nil
        store.webView.uiDelegate = nil
        // Break the store ↔ coordinator keep-alive a mounted container installed (`t_065c8753`):
        // the pane is going away, so nothing needs to answer this webview any more.
        store.installCoordinator(nil)
        if let committed = store.url ?? lastURLs[serverID] {
            lastURLs[serverID] = committed
        }
        storeGeneration &+= 1
        Logger.info("ViewStore",
                    "released webview for server \(serverID) "
                    + "(last url: \(lastURLs[serverID]?.absoluteString ?? "none"); data store kept)")
    }

    // MARK: Primary view

    func setPrimary(_ serverID: UUID) {
        primaryServerID = serverID
    }

    // MARK: Removal

    /// Tear down a removed server: drop its webview and delete its isolated on-disk data store
    /// (desktop's `ServerManager.removeServer` also purges that server's session/config).
    func remove(serverID: UUID) {
        stores[serverID]?.installCoordinator(nil)
        stores[serverID] = nil
        lastURLs[serverID] = nil
        if primaryServerID == serverID { primaryServerID = nil }
        storeGeneration &+= 1
        Task {
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: serverID)
                Logger.info("ViewStore", "purged data store for removed server \(serverID)")
            } catch {
                // Purge failures are not fatal: the server is already gone from the shell, and
                // an orphaned data store is invisible to the user (it is keyed by a dead uuid).
                Logger.error("ViewStore", "failed to purge data store \(serverID): \(error)")
            }
        }
        Logger.info("ViewStore", "removed server \(serverID) and released its webview")
    }
}

/// The webview release policy (`docs/dual-render.md` §12.1) as a pure function, so the truth
/// table is unit-testable without a `WKWebView` (`ViewStoreTests.testMayReleaseTruthTable`).
///
/// A per-server webview may be released only when **all four** hold:
///  1. the pane host surface (`SurfaceDefaults.paneHostSurface`) resolves `.native` — the only
///     surface whose native branch takes the webview's place;
///  2. that surface is `-AV`-approved (`nativeApprovedSurfaces`) — approval is the only evidence
///     that a real card exists, so eviction can never hide behind a placeholder pane;
///  3. that surface is pane-owning (`paneOwningSurfaces`) — the card renders *every* region the
///     webview paints, so nothing in the web app is still needed;
///  4. no navigation is in flight — never kill a login/SSO mid-flight.
///
/// `allowUnapproved` is the one sanctioned bypass, and it exists for **measurement, not for
/// shipping**: the perf probe's `nativeEvicted` arm (`#if DEBUG || PERF_PROBE`) and the debug-only
/// UI-test flag `-releaseWebViewForTesting` need to exercise the mechanism before any surface is
/// approved. `scripts/verify-dual-render-gates.sh` asserts that every call site passing
/// `allowUnapproved: true` compiles only inside `#if DEBUG` / `#if DEBUG || PERF_PROBE`.
enum WebViewReleasePolicy {

    static func mayRelease(paneSurfaceResolved: SurfaceRenderMode,
                           approved: Bool,
                           paneOwning: Bool,
                           navigationInFlight: Bool,
                           allowUnapproved: Bool = false) -> Bool {
        paneSurfaceResolved == .native
            && paneOwning
            && (approved || allowUnapproved)
            && !navigationInFlight
    }

    /// The decision the shell actually applies (`RootView.releaseIfNeeded`): the four-condition
    /// rule, plus the DEBUG-only UI-test seam, and nothing else.
    ///
    /// The seam is a *launch argument* (`-releaseWebViewForTesting`) and is only honoured when
    /// `SurfaceModeResolver.debugAffordancesEnabled` is true, so it is doubly unreachable in a
    /// Release build: the code does not exist (`#if DEBUG`) and the switch that parses it is a
    /// compile-time constant.
    ///
    /// What it stands in for, exactly: **both** `-AV` claims a real pane card would make —
    /// `approved` (whose registry the caller passes truthfully) *and* `paneOwning`. It has to,
    /// because this commit ships with `paneOwningSurfaces` empty by design, so `allowUnapproved`
    /// alone can never reach `release(...)` (that is `testEmptyRegistriesMakeReleaseUnreachable`).
    /// The pure predicate is not weakened: `mayRelease` still requires pane ownership, and this
    /// DEBUG-only seam is the only code that supplies it without an approval.
    static func shouldRelease(paneSurfaceResolved: SurfaceRenderMode,
                              approved: Bool,
                              paneOwning: Bool,
                              navigationInFlight: Bool) -> Bool {
        #if DEBUG
        if debugReleaseForTestingArmed {
            return mayRelease(paneSurfaceResolved: paneSurfaceResolved,
                              approved: approved,
                              paneOwning: true,
                              navigationInFlight: navigationInFlight,
                              allowUnapproved: true)
        }
        #endif
        return mayRelease(paneSurfaceResolved: paneSurfaceResolved,
                          approved: approved,
                          paneOwning: paneOwning,
                          navigationInFlight: navigationInFlight)
    }

    #if DEBUG
    /// `-releaseWebViewForTesting` — DEBUG builds only, and only when the debug affordances
    /// themselves are compiled in. Never present in a Release binary (asserted by the acceptance
    /// evidence for T26-R R4a: the literal is absent from the Release executable).
    static var debugReleaseForTestingArmed: Bool {
        guard SurfaceModeResolver.debugAffordancesEnabled else { return false }
        return ProcessInfo.processInfo.arguments.contains("-releaseWebViewForTesting")
    }
    #endif
}
