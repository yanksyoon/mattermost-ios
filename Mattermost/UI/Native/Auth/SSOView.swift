// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/sso/sso.tsx, sso_authentication.tsx, sso_authentication_with_external_browser.tsx
// (the identity provider runs in a web surface; the app then adopts the resulting session).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §3; no
// upstream source copied.

import SwiftUI

/// The SSO hand-off: the identity provider runs in the shell's **own** webview, and the native
/// client adopts the session it establishes.
///
/// Why a sheet around `WebViewContainer` rather than a native OIDC client: `WebViewContainer`'s
/// navigation policy, popup handling, app-switch hand-off and `CertTrust` behaviour are the SSO
/// flow that already works on this shell (card scope: "do not change them"). This view changes
/// nothing about it — it mounts the same `WKWebView` instance the server's store owns, and watches
/// the `HttpOnly` `MMAUTHTOKEN` cookie through `WKWebsiteDataStore` (never page JavaScript, never a
/// token handed over the bridge).
///
/// On adoption `AuthCoordinator` flips the server to signed-in, the sheet dismisses itself, and the
/// shell renders the workspace — "capture the resulting session, and land back on the native shell".
struct SSOView: View {

    let server: ServerConfig
    let coordinator: AuthCoordinator
    @ObservedObject var viewStore: ViewStore

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SSOViewModel
    @State private var store: WebViewStore?
    /// Bumped by "Try again"; a new value restarts the polling task.
    @State private var attempt = 0

    init(server: ServerConfig, coordinator: AuthCoordinator, viewStore: ViewStore) {
        self.server = server
        self.coordinator = coordinator
        self.viewStore = viewStore
        _model = StateObject(wrappedValue: SSOViewModel(serverName: server.name,
                                                        serverURL: server.url))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if coordinator.phase(for: server.id).isExpired {
                    SessionExpiredBanner(serverName: server.name)
                        .padding([.horizontal, .top], 12)
                }
                statusRow
                Divider()
                webViewHost
            }
            .navigationTitle("Sign in with SSO")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("ssoCancelButton")
                }
            }
        }
        .accessibilityIdentifier("ssoSheet")
        .task { attachWebView() }
        .task(id: attempt) { await poll() }
        .onChange(of: store?.url) { _, url in model.noteNavigation(to: url) }
        .onChange(of: model.phase) { _, phase in
            if case .signedIn = phase { dismiss() }
        }
    }

    // MARK: - Webview

    @ViewBuilder
    private var webViewHost: some View {
        if let store {
            WebViewContainer(store: store, serverID: server.id, serverURL: server.url)
                .ignoresSafeArea(edges: .bottom)
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("Opening \(server.url.host ?? "the server")…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Attach the server's existing webview (the store that `RootView`/`ViewStore` already owns) and
    /// make sure it is showing something. `loadIfNeeded` rather than `load`: a page already loaded
    /// for this server is never restarted, so an already-signed-in session adopts immediately.
    private func attachWebView() {
        let resolved = viewStore.ensureStore(for: server)
        resolved.loadIfNeeded(viewStore.lastURLs[server.id] ?? server.url)
        store = resolved
        model.noteNavigation(to: resolved.url)
    }

    // MARK: - Polling

    private func poll() async {
        await model.observe(reader: WebKitSessionCookieReader(serverID: server.id)) { [coordinator, server] in
            try await coordinator.adoptWebSession(server,
                                                  using: WebKitSessionCookieReader(serverID: server.id))
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusRow: some View {
        switch model.phase {
        case .waiting:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finish signing in above. This screen continues by itself.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .statusBarChrome()
        case .adopting:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Signed in. Setting up this device…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .statusBarChrome()
        case .signedIn(let username):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Signed in as \(username).").font(.footnote)
                Spacer(minLength: 0)
            }
            .statusBarChrome()
        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Try again") {
                    model.restart()
                    attempt += 1
                }
                .font(.footnote)
                .accessibilityIdentifier("ssoRetryButton")
            }
            .statusBarChrome()
        }
    }
}

private extension View {
    /// Shared padding/identifier for the sheet's status strip.
    func statusBarChrome() -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ssoStatusText")
    }
}
