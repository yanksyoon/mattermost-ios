import SwiftUI

/// One server's scene: hosts that server's `WKWebView` with a native loading bar, an inline
/// error/retry state, and the certificate-prompt sheet for untrusted self-signed certs.
/// Rendered by `RootView` for every configured server, so a scene keeps its webview (and
/// therefore its session and scroll position) while another server is on screen.
///
/// Parity rows: `BaseWindow` scene + `LoadingScreen` -> per-server scene with `ProgressView`
/// skeleton, `ConnectionErrorView` -> `ErrorStateView`, `modals/certificate` ->
/// `CertPromptSheet`. Status: native, P0.3/P1.2/P3.
struct ContentView: View {
    let server: ServerConfig
    @ObservedObject var store: WebViewStore

    var body: some View {
        ZStack {
            WebViewContainer(store: store, serverID: server.id, serverURL: server.url)
                .ignoresSafeArea()

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
        .sheet(item: $store.pendingCertificatePrompt) { prompt in
            CertPromptSheet(prompt: prompt) { trust, dontTrustAgain in
                store.resolveCertificatePrompt(trust: trust, dontTrustAgain: dontTrustAgain)
            }
        }
        .onAppear {
            // First mount of this server's scene: start the one navigation it owns.
            if store.url == nil {
                store.load(server.url)
            }
        }
    }

    /// Desktop `handleLink` for the error bullets: open the URL in Safari (the shell cannot
    /// open a browser window like Electron can; iOS has a system browser).
    private func openExternally(_ url: URL) {
        UIApplication.shared.open(url)
    }
}
