import SwiftUI

/// One server's scene: hosts that server's `WKWebView` with a native loading bar, an inline
/// error/retry state, and the certificate-prompt sheet for untrusted self-signed certs.
/// Rendered by `RootView` for every configured server, so a scene keeps its webview (and
/// therefore its session and scroll position) while another server is on screen.
///
/// T26 dual-render: the workspace pane — the region the one-per-server webview maps to, i.e. the
/// `channelView` surface — is gated by `SurfaceHost`. When that surface resolves `native` the pane
/// shows the `UnportedSurfaceView` stand-in; when it resolves `web` (the default for every
/// surface today) the pane renders exactly as before. The `WKWebView` object itself is still owned
/// by the per-server `WebViewStore`, so flipping back to `web` re-attaches the *identical*
/// instance with its session, cookies and in-memory page intact — no duplicate webview, no
/// re-login. The shell chrome (toolbar, server switcher, settings, downloads, notifications) lives
/// in `RootView` and is untouched by this decision.
///
/// Parity rows: `BaseWindow` scene + `LoadingScreen` -> per-server scene with `ProgressView`
/// skeleton, `ConnectionErrorView` -> `ErrorStateView`, `modals/certificate` -> `CertPromptSheet`.
/// Status: native, P0.3/P1.2/P3.
struct ContentView: View {
    let server: ServerConfig
    @ObservedObject var store: WebViewStore

    var body: some View {
        SurfaceHost(.channelView) {
            // No channel-view screen card has passed its -AV validation yet, so the native branch
            // is the explicit stand-in (never a blank pane). When S11 lands it plugs in here and
            // this branch becomes `ChannelView(...)`.
            UnportedSurfaceView(surface: .channelView)
                .ignoresSafeArea()
        } web: {
            webPane
        }
        .sheet(item: $store.pendingCertificatePrompt) { prompt in
            CertPromptSheet(prompt: prompt) { trust, dontTrustAgain in
                store.resolveCertificatePrompt(trust: trust, dontTrustAgain: dontTrustAgain)
            }
        }
        .onAppear {
            // First mount of this server's scene: start the one navigation it owns. This runs
            // regardless of the surface mode, so the webview is warm (loaded, signed in) and
            // ready to be re-attached rather than blank if the user flips the surface back.
            loadIfNeeded()
        }
    }

    /// The webview fallback plus the webview-specific chrome (error / progress) that only makes
    /// sense while the pane really is the web app.
    @ViewBuilder
    private var webPane: some View {
        ZStack {
            WebViewContainer(store: store, serverID: server.id, serverURL: server.url)
                .ignoresSafeArea()
                // Re-creatable on demand: a store that was never loaded (launched straight into
                // native, or re-added after `ViewStore.remove(serverID:)`) loads the first time
                // the web branch actually appears.
                .onAppear { loadIfNeeded() }

            if store.pageError != nil {
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
    }

    /// Start the scene's single navigation, once. Idempotent: a store that is already loading or
    /// loaded (its `url` is committed) is left alone, so re-attaching the webview never
    /// re-navigates and never discards the signed-in page.
    private func loadIfNeeded() {
        guard store.url == nil else { return }
        store.load(server.url)
    }

    /// Desktop `handleLink` for the error bullets: open the URL in Safari (the shell cannot
    /// open a browser window like Electron can; iOS has a system browser).
    private func openExternally(_ url: URL) {
        UIApplication.shared.open(url)
    }
}
