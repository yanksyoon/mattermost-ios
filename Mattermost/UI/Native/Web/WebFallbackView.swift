// T46 — the presentation for a permanently-web surface (`docs/dual-render.md` §13).
//
// The sheet is deliberately thin: the webview it hosts is the *same* `WebViewContainer` the pane
// uses, so navigation policy, the certificate trust bag, popup handling and the JS-dialog guard are
// one implementation, not two. What this file adds is the seam the reader notices — a native
// title, a way back, a reload — and the teardown that keeps the memory goal intact.

import SwiftUI
import WebKit

/// A permanently-web surface, presented over the native shell.
struct WebFallbackSheet: View {
    @StateObject private var model: WebFallbackModel
    @Environment(\.dismiss) private var dismiss

    init(server: ServerConfig, surface: WebFallbackSurface) {
        _model = StateObject(wrappedValue: WebFallbackModel(server: server, surface: surface))
    }

    var body: some View {
        NavigationStack {
            Group {
                // T46-R R1: the sheet says what it can show instead of opening a page the
                // server does not serve (Boards/Playbooks are product plugins; measured on a
                // 9.11.19 server without focalboard: `/boards` painted 61 characters of nothing).
                //
                // The webview is mounted as soon as there is a route — **before** the capability
                // answer arrives — and the informational states are drawn over it. Mounting first
                // is not cosmetic: `WebViewContainer` is what installs the navigation delegate, and
                // a navigation that starts before its delegate exists never reports `didFinish`
                // (T26-R `t_065c8753`: the pane sat blank at 10 %), which would leave the paint
                // probe and the live state stuck at `loading`. A webview that never navigates
                // paints nothing, so mounting early costs the reader nothing.
                ZStack {
                    if let store = model.store {
                        WebFallbackPane(store: store, model: model,
                                        server: model.server, surface: model.surface)
                            .opacity(model.availability == .available ? 1 : 0)
                            .accessibilityHidden(model.availability != .available)
                    }
                    switch model.availability {
                    case .checking:
                        checking
                    case .notEnabled:
                        notEnabled
                    case .unaddressable:
                        unavailable
                    case .available:
                        EmptyView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .navigationTitle(model.surface.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Closing is the way back to the native stack: the sheet is the only thing
                    // the fallback adds to the navigation, so leaving it is leaving the surface.
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("webFallbackClose")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.store?.goBack()
                    } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                    .disabled(!model.canGoBack)
                    .accessibilityIdentifier("webFallbackBack")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.store?.reload()
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("webFallbackReload")
                }
            }
        }
        // One entry per presentation: a closed sheet is not reused, so the next open builds a
        // fresh webview (and the previous one is gone — `tearDown` on disappear).
        .task { await model.start() }
        .onDisappear { model.tearDown() }
        .accessibilityIdentifier("webFallbackSheet")
    }

    /// The entry names no loadable route (an empty or malformed plugin id). Nothing was created —
    /// saying so is better than a blank webview.
    private var unavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.square.dashed")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("This surface cannot be opened")
                .font(.headline)
            Text("\(model.surface.title) has no web route on this server.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("webFallbackUnavailable")
        .accessibilityValue("unaddressable")
    }

    /// The server answered and does not serve this surface's product plugin.
    ///
    /// This is the state T46 was missing: the row opened `/boards`, the server's web app answered
    /// with its HTML shell, no Boards bundle existed to mount, and the reader got a blank navy
    /// page (measured: 61 characters, `docs/t46-av-verdict.md` §F1). The identifier is the same
    /// "cannot be opened" state as `unavailable` — the difference is the sentence and its
    /// accessibility value, which is what the live suite asserts.
    private var notEnabled: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(model.notEnabledMessage)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(model.notEnabledDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("webFallbackUnavailable")
        .accessibilityValue("notEnabled")
    }

    /// Asking the server which plugins it serves. A spinner with a sentence, never an empty
    /// rectangle: this state is on screen only while the capability request is in flight.
    private var checking: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Checking whether \(model.surface.title) is available…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("webFallbackChecking")
    }
}

/// The webview plus the page-state chrome that only makes sense while it is the web app.
private struct WebFallbackPane: View {
    @ObservedObject var store: WebViewStore
    @ObservedObject var model: WebFallbackModel
    let server: ServerConfig
    let surface: WebFallbackSurface

    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var notificationWorker: NotificationWorker
    /// T45: the progress bar's fade is incidental — under Reduce Motion it appears in place.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            WebViewContainer(store: store,
                             serverID: server.id,
                             serverURL: server.url,
                             // This is not the pane: it must not claim the server's mention
                             // input. The page may still report a mention; the arbitration in
                             // `NotificationInputGate` then decides, exactly as for any webview.
                             claimsMentionInput: false)
                // The shell's own page lifecycle, readable by the UI suite (the web content
                // process's tree is not reachable from the runner — `t_065c8753`), plus where the
                // session came from and the committed URL. One value, so "it rendered exactly this
                // surface, signed in" is a single assertion.
                .accessibilityIdentifier("webFallbackPane")
                .accessibilityValue(model.observableState)

            if store.pageError != nil {
                ErrorStateView(
                    url: store.url ?? model.target,
                    error: store.pageError,
                    onRetry: { store.retry() },
                    onClearCacheAndReload: { store.clearCacheAndReload() },
                    onOpenExternal: { openExternally(store.url ?? model.target) }
                )
                .background(Color(.systemBackground))
            } else if store.isLoading && store.progress < 1 {
                ProgressView(value: store.progress)
                    .progressViewStyle(.linear)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(MotionPolicy.transition(.opacity, for: .incidental, reduceMotion: reduceMotion))
            }
        }
        .sheet(item: $store.pendingCertificatePrompt) { prompt in
            CertPromptSheet(prompt: prompt) { trust, dontTrustAgain in
                store.resolveCertificatePrompt(trust: trust, dontTrustAgain: dontTrustAgain)
            }
        }
    }

    private func openExternally(_ url: URL?) {
        guard let url else { return }
        UIApplication.shared.open(url)
    }
}

/// The "Plugin screen…" prompt: a plugin screen is whatever the plugin serves at
/// `/plugins/<id>`, so the reader supplies the id and the shell validates it as one path segment.
struct PluginScreenPrompt: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pluginID = ""
    let onOpen: (WebFallbackSurface) -> Void

    private var surface: WebFallbackSurface {
        WebFallbackSurface(kind: .plugin, pluginID: pluginID.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("com.mattermost.calls", text: $pluginID)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                        .accessibilityIdentifier("webFallbackPluginField")
                } header: {
                    Text("Plugin route")
                } footer: {
                    // T46-R R2: the row used to be called "Plugin screen", which promised a screen
                    // the shell cannot guarantee. `/plugins/<id>` is a request into the server's
                    // plugin namespace; a plugin's own UI is a client-side route inside the web
                    // app, and a server with no page there answers with the workspace (measured
                    // on 9.11.19: `301 → /` for every installed plugin). Say what it does.
                    Text("Opens /plugins/<id> in this server's web app. The id is the plugin's "
                         + "manifest id — for example com.mattermost.calls. A plugin whose UI is a "
                         + "client-side route inside the web app answers this path with the "
                         + "workspace, so this row opens the route, not a guaranteed plugin screen.")
                }
            }
            .navigationTitle("Plugin route")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("webFallbackPluginCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open") {
                        onOpen(surface)
                        dismiss()
                    }
                    .disabled(surface.path == nil)
                    .accessibilityIdentifier("webFallbackPluginOpen")
                }
            }
        }
    }
}
