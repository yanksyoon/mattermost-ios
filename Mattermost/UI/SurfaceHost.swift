import SwiftUI

/// The dual-render host — the one place a surface decides between its native screen card and the
/// webview fallback (T26 scope §2).
///
/// ```swift
/// SurfaceHost(.channelView) {
///     ChannelView(native: model)          // Path B screen card
/// } web: {
///     WebViewContainer(store: store, serverID: server.id, serverURL: server.url)
/// }
/// ```
///
/// Contract (see `docs/dual-render.md`):
///  - **One decision point.** The mode comes from `SurfaceModeResolver`, never from a view-local
///    `#if DEBUG` or a hard-coded `.native`. A screen card that bypasses the host is rejected by
///    its `-AV` validator.
///  - **Webview identity is preserved.** The `web` branch must render the webview the app already
///    owns (`ViewStore.ensureStore(for:)` → `WebViewStore.webView`), never construct a `WKWebView`. The
///    store owns the instance, so switching to native dismantles the `UIViewRepresentable` but not
///    the webview: its cookies/localStorage/scroll state and in-memory page survive, and switching
///    back re-attaches the *same* object (asserted by
///    `SurfaceModeResolverTests.testWebViewInstanceIsStableAcrossSurfaceToggles`).
///  - **Never a blank screen.** A surface may resolve `native` before its card lands; callers pass
///    `UnportedSurfaceView` as the native branch when they have nothing ported yet, which explains
///    the state and offers a one-tap route back to the webview.
///  - **Re-creatable.** If the webview was torn down (`ViewStore.remove(serverID:)` on server
///    removal, or a never-loaded store), the `web` branch must load on appear — `ContentView` does
///    this, so a surface can always come back to a working webview.
struct SurfaceHost<Native: View, Web: View>: View {
    /// The surface this host gates.
    let surface: Surface

    private let nativeContent: () -> Native
    private let webContent: () -> Web

    @EnvironmentObject private var resolver: SurfaceModeResolver

    init(_ surface: Surface,
         @ViewBuilder native: @escaping () -> Native,
         @ViewBuilder web: @escaping () -> Web) {
        self.surface = surface
        self.nativeContent = native
        self.webContent = web
    }

    var body: some View {
        // One `some View`: SwiftUI folds the two branches into `_ConditionalContent`, so flipping
        // the mode changes which representable is mounted without invalidating the parent.
        if resolver.resolvedMode(for: surface) == .native {
            nativeContent()
        } else {
            webContent()
        }
    }
}
