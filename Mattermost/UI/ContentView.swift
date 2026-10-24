import SwiftUI

/// One server's scene: hosts that server's `WKWebView` with a native loading bar, an inline
/// error/retry state, and the certificate-prompt sheet for untrusted self-signed certs.
/// Rendered by `RootView` for every configured server, so a scene keeps its webview (and
/// therefore its session and scroll position) while another server is on screen.
///
/// T26 dual-render: the workspace pane — the region the one-per-server webview maps to, named once
/// as `SurfaceDefaults.paneHostSurface` — is gated by `SurfaceHost`. When that surface resolves
/// `native` the pane shows the `UnportedSurfaceView` stand-in; when it resolves `web` (the default
/// for every surface today) the pane renders the web app.
///
/// T26-R R4 (`docs/dual-render.md` §12): the scene **no longer takes a `WebViewStore`**. A released
/// pane has no store at all, so the web branch resolves one from the `ViewStore` when it appears
/// (`WebPaneHost`) and shows an honest blocking "Reopening web view…" state until that store's
/// first commit. While the pane is released this view therefore performs **no** load — the whole
/// point of the policy is that there is no web engine behind a pane-owning native card.
///
/// Parity rows: `BaseWindow` scene + `LoadingScreen` -> per-server scene with `ProgressView`
/// skeleton, `ConnectionErrorView` -> `ErrorStateView`, `modals/certificate` -> `CertPromptSheet`.
/// Status: native, P0.3/P1.2/P3.
struct ContentView: View {
    let server: ServerConfig
    /// The owner of this server's webview. Passing the store *owner* rather than a store instance
    /// is what makes a released pane representable: there may simply be no store to pass.
    @ObservedObject var viewStore: ViewStore

    /// T30: the native navigation model (injected by `MattermostApp`). The shell is the pane's
    /// native branch, and `RootView` binds its `path` for the compact push.
    @EnvironmentObject private var navigation: NativeNavigation

    var body: some View {
        SurfaceHost(SurfaceDefaults.paneHostSurface) {
            // T30: the native shell — sidebar + channel view + threads as placeholders — is the
            // pane's native card. It is **not** in `SurfaceDefaults.nativeApprovedSurfaces` and not
            // pane-owning, so this branch is reachable only through the DEBUG dual-render
            // affordances (`-surfaceMode` / the Surface inspector); every shipping configuration
            // still renders the webview below, and the release policy still refuses to release a
            // webview for it.
            NativeShellView(server: server, navigation: navigation)
                .ignoresSafeArea()
        } web: {
            WebPaneHost(server: server, viewStore: viewStore)
        }
    }
}

// MARK: - The web branch

/// The web branch of the pane: resolves (and, on a first appearance after a release, **creates**)
/// this server's store, starts its navigation, and renders the web app once it has committed.
///
/// Responsibility split, on purpose (§12.4):
///  - **creating** a store is this view's appearance, never a body pass — a released store must not
///    be resurrected by SwiftUI re-evaluating `RootView`;
///  - this view holds **no strong reference** to the store (`view(forServerID:)` is a lookup, and
///    re-runs when `ViewStore.storeGeneration` changes). If it kept the store in `@State`, dropping
///    it from `ViewStore.stores` would not actually deallocate the `WKWebView`/WebContent process
///    until SwiftUI discarded this view's state — which is the memory claim the policy is about;
///  - the load is started once per appearance (`loadIfNeeded`, so a page stopped mid-flight by a
///    surface toggle is resumed rather than stranded — T26-R R6).
private struct WebPaneHost: View {
    let server: ServerConfig
    @ObservedObject var viewStore: ViewStore

    var body: some View {
        ZStack {
            if let store = viewStore.view(forServerID: server.id) {
                WebPane(store: store,
                        server: server,
                        isReopen: viewStore.lastURLs[server.id] != nil)
            } else {
                // First frame of the branch, before `onAppear` has created the store: the same
                // honest state, not a blank pane.
                WebPaneReopening(isReopen: viewStore.lastURLs[server.id] != nil)
            }
        }
        .onAppear(perform: resolveAndLoad)
    }

    /// The one creation + load point of the web branch. `ensureStore` is idempotent, so a warm
    /// webview is re-attached untouched (instant, as §7 promises) and only a released pane pays
    /// the reopen.
    private func resolveAndLoad() {
        let store = viewStore.ensureStore(for: server)
        store.loadIfNeeded(viewStore.lastURLs[server.id] ?? server.url)
    }
}

/// The web app plus the webview-specific chrome (error / progress) that only makes sense while the
/// pane really is the web app, and the certificate prompt (which needs a store to exist at all, so
/// it lives here rather than on `ContentView`).
///
/// The `WKWebView` is mounted only once the store has a **committed** page (or a genuine error).
/// Before that the pane is the blocking `WebPaneReopening` state — one view at a time, no webview
/// hiding underneath a spinner — which is also what makes the honest state observable to the UI
/// suite at all (`webPaneReopening`).
private struct WebPane: View {
    @ObservedObject var store: WebViewStore
    let server: ServerConfig
    /// The pane had a committed page before it was released: this is §12.4's return trip.
    let isReopen: Bool

    var body: some View {
        ZStack {
            WebViewContainer(store: store, serverID: server.id, serverURL: server.url)
                .ignoresSafeArea()

            if isReopen && store.pageError == nil && !store.hasFinishedPageLoad {
                // §12.4: the return trip of a released pane. Opaque and covering, so the user
                // cannot interact with a half-bootstrapped page, and it lifts by itself the moment
                // the page finishes (`hasFinishedPageLoad`) — no second tap, no silent blank pane.
                WebPaneReopening(isReopen: true)
            } else if store.pageError != nil {
                // Cover the webview with the retryable error state when navigation failed.
                ErrorStateView(
                    url: store.url ?? server.url,
                    error: store.pageError,
                    onRetry: { store.retry() },
                    onClearCacheAndReload: { store.clearCacheAndReload() },
                    onOpenExternal: { openExternally(store.url ?? server.url) }
                )
                .background(Color(.systemBackground))
            } else if store.isLoading && store.progress < 1 {
                ProgressView(value: store.progress)
                    .progressViewStyle(.linear)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
            }
        }
        .sheet(item: $store.pendingCertificatePrompt) { prompt in
            CertPromptSheet(prompt: prompt) { trust, dontTrustAgain in
                store.resolveCertificatePrompt(trust: trust, dontTrustAgain: dontTrustAgain)
            }
        }
    }

    /// Desktop `handleLink` for the error bullets: open the URL in Safari (the shell cannot
    /// open a browser window like Electron can; iOS has a system browser).
    private func openExternally(_ url: URL) {
        UIApplication.shared.open(url)
    }
}

/// The blocking, honest state of a web pane whose webview was released and is coming back
/// (§12.4) — or, via `WebPaneHost`, the frame before the store exists at all.
///
/// "Blocking" is literal: opaque, full-pane, and over the webview, so the user cannot interact with
/// a half-bootstrapped page and there is no second tap to take. It lifts by itself when the page
/// finishes. The `accessibilityIdentifier` is the evidence the UI suite asserts on
/// (`testReleasedPaneReopensWebViewWithSessionAndHonestState`).
private struct WebPaneReopening: View {
    let isReopen: Bool

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(isReopen ? "Reopening web view…" : "Loading web view…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("webPaneReopening")
        .accessibilityLabel(isReopen ? "Reopening web view" : "Loading web view")
    }
}
