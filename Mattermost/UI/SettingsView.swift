import SwiftUI

/// Native port of the desktop renderer `SettingsModal` (parity row design §4d:
/// `SettingsModal/*` -> `SettingsView` — `Form` with `Toggle`, `Picker`, `Stepper`, with the
/// renderer's IPC `getLocalConfiguration`/`updateConfiguration` replaced by the native
/// `AppSettings` store).
///
/// The desktop modal groups settings into a sidebar of categories (General / Notifications /
/// Language / Servers / Advanced) built from `definition.tsx`; iOS renders the same categories
/// as `Form` sections. Rows map 1:1 onto desktop component types:
///
///   - `CheckSetting`  -> `Toggle` (theme syncing, unread badge)
///   - `SelectSetting` -> `Picker` (app language, log level)
///   - `NumberSetting` -> `Stepper` (download history limit; the desktop's `viewLimit` has no
///     iOS analog — one webview per server, no tabs — so the Stepper binds to a real shell
///     number instead, see `AppSettings`)
///   - `ServerSetting` -> inline servers list with Add/Edit/Remove (reuses `ServerFormView`)
///   - `DownloadSetting`-> read-only location row: iOS sandbox pins files to the app Downloads
///     directory (the desktop's folder picker has no iOS meaning)
///
/// Rows with no iOS analog are omitted (documented in `AppSettings` + docs/t11-build-note.md):
/// window/tray chrome, updates (App Store owns them), metrics/Sentry, session attributes,
/// hardware acceleration, spell checker (WKWebView inputs aren't shell-controllable).
struct SettingsView: View {
    @ObservedObject var serverStore: ServerStore
    let viewStore: ViewStore?
    @ObservedObject var appSettings: AppSettings
    @ObservedObject var sessionStore: SessionStore
    /// T31: the app-level auth owner. Settings is the shell's home for "sign out of this server":
    /// the native session lives in this object, so a sign-out here and a 401 anywhere else are the
    /// same state change.
    @EnvironmentObject private var auth: AuthCoordinator

    @Environment(\.dismiss) private var dismiss

    /// Server opened in `ServerFormView` (edit mode when non-nil).
    @State private var editingServer: ServerConfig?
    @State private var isPresentingServerForm = false
    @State private var serverPendingRemoval: ServerConfig?
    /// Non-nil while the sign-out confirmation is up for that server.
    @State private var serverPendingSignOut: ServerConfig?

    // T19a: diagnostics report state (generated report files for the ShareLinks).
    @State private var diagnosticsReportURLs: [URL]?
    @State private var isRunningDiagnostics = false
    @State private var diagnosticsError: String?

    #if DEBUG
    // T26: debug-only Surface inspector sheet (dual-render switch).
    @State private var isPresentingSurfaceInspector = false
    #endif

    // Binding shim: `SessionStore.showUnreadBadge` is the source of truth (desktop
    // `showUnreadBadge` — it drives the app-icon badge via `SessionStore`), so the form row
    // writes straight into it rather than duplicating the flag in `AppSettings`.
    private var showUnreadBadgeBinding: Binding<Bool> {
        Binding(
            get: { sessionStore.showUnreadBadge },
            set: { sessionStore.showUnreadBadge = $0 }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                generalSection
                notificationsSection
                languageSection
                serversSection
                sessionSection
                advancedSection
                diagnosticsSection
                #if DEBUG
                developerSection
                #endif
            }
            .navigationTitle("Desktop App Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $isPresentingServerForm) {
                ServerFormView(serverStore: serverStore, viewStore: viewStore, editing: editingServer)
            }
            #if DEBUG
            .sheet(isPresented: $isPresentingSurfaceInspector) {
                SurfaceInspector()
            }
            #endif
            .confirmationDialog(
                "Remove \(serverPendingRemoval?.name ?? "this server")?",
                isPresented: Binding(get: { serverPendingRemoval != nil }, set: { if !$0 { serverPendingRemoval = nil } }),
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let server = serverPendingRemoval {
                        // T31: removing a server must not leave its credential behind. The vault
                        // token and the webview's session cookie are what a *later* re-add of the
                        // same URL would silently inherit, so removal signs the server out first.
                        // The local clear is **synchronous** and happens on this turn, before the
                        // server disappears (T31-AV F2: a detached `Task` has not run a line by the
                        // time `remove` executes, and a termination in that window used to keep a
                        // usable Keychain token for a server the user had just removed). The
                        // cookie clear and the network revocation follow asynchronously.
                        let discarded = auth.beginSignOut(server)
                        _ = serverStore.remove(id: server.id)
                        Task { await auth.finishSignOut(discarded) }
                    }
                    serverPendingRemoval = nil
                }
                Button("Cancel", role: .cancel) { serverPendingRemoval = nil }
            } message: {
                Text("This clears the server's signed-in session on this device.")
            }
            .confirmationDialog(
                "Sign out of \(serverPendingSignOut?.name ?? "this server")?",
                isPresented: Binding(get: { serverPendingSignOut != nil },
                                     set: { if !$0 { serverPendingSignOut = nil } }),
                titleVisibility: .visible
            ) {
                Button("Sign out", role: .destructive) {
                    if let server = serverPendingSignOut {
                        Task { await auth.signOut(server) }
                    }
                    serverPendingSignOut = nil
                }
                Button("Cancel", role: .cancel) { serverPendingSignOut = nil }
            } message: {
                Text("The session stored for this server on this device is cleared, and revoked on "
                     + "the server. You will need to sign in again. Messages on the server are not "
                     + "affected.")
            }
        }
        .accessibilityIdentifier("settingsView")
    }

    // MARK: - General (desktop `general` category)

    private var generalSection: some View {
        Section {
            Toggle(isOn: $appSettings.themeSyncing) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Synchronize app theme with server")
                    Text("If enabled, the app theme will follow the server theme.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent {
                Text(URL.downloadsDirectory.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download Location")
                    Text("Files are saved to the app's Downloads folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Stepper(value: $appSettings.downloadHistoryLimit,
                    in: AppSettings.downloadHistoryLimitRange) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep up to \(appSettings.downloadHistoryLimit) downloads in history")
                    Text("The maximum number of completed downloads retained in the Downloads list. 0 means no limit on desktop; this shell keeps at least one row.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("General")
        }
    }

    // MARK: - Notifications (desktop `notifications` category)

    private var notificationsSection: some View {
        Section {
            Toggle(isOn: showUnreadBadgeBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show red badge on app icon to indicate unread messages")
                    Text("Regardless of this setting, mentions are always indicated with a red badge and item count on the app icon.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Notifications")
        }
    }

    // MARK: - Language (desktop `language` category)

    private var languageSection: some View {
        Section {
            Picker(selection: $appSettings.appLanguage) {
                ForEach(AppSettings.availableLanguages, id: \.code) { language in
                    Text(language.label).tag(language.code)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("App Language")
                    Text("The language the app will use for menus and popups. The shell is English-only today; the setting is persisted for the future i18n pass.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Language")
        }
    }

    // MARK: - Servers (desktop `servers` / `ServerSetting` category)

    private var serversSection: some View {
        Section {
            if serverStore.servers.isEmpty {
                Text("No servers added")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(serverStore.servers) { server in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name)
                            Text(server.url.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            editingServer = server
                            isPresentingServerForm = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Edit \(server.name)")
                        Button(role: .destructive) {
                            serverPendingRemoval = server
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(server.name)")
                    }
                }
            }
            Button {
                editingServer = nil
                isPresentingServerForm = true
            } label: {
                Label("Add a server", systemImage: "plus")
            }
        } header: {
            Text("Servers")
        }
    }

    // MARK: - Session (T31: sign-out + confirmation)

    /// The native session's home in the shell: which servers this device holds a session for, and
    /// the sign-out action with its confirmation.
    ///
    /// Only servers with a **native** session appear. After a webview-only sign-in there is no
    /// vault credential to clear, so a "sign out" row there would be a button that does nothing —
    /// the web app's own account menu remains the answer for that path.
    @ViewBuilder
    private var sessionSection: some View {
        let signedIn = serverStore.servers.filter { auth.authState(for: $0) == .signedIn }
        if !signedIn.isEmpty {
            Section {
                ForEach(signedIn) { server in
                    Button(role: .destructive) {
                        serverPendingSignOut = server
                    } label: {
                        Label("Sign out of \(server.name)",
                              systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .accessibilityIdentifier("signOutButton")
                }
            } header: {
                Text("Session")
            } footer: {
                Text("Signing out clears the session this device stores for the server, and revokes "
                     + "it on the server.")
                    .font(.caption)
            }
        }
    }

    // MARK: - Advanced (desktop `advanced` category)

    private var advancedSection: some View {
        Section {
            Picker(selection: $appSettings.logLevel) {
                ForEach(AppSettings.availableLogLevels, id: \.self) { level in
                    Text(Self.logLevelLabel(level)).tag(level)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Logging level")
                    Text("Logging is helpful for developers and support to isolate issues you may be encountering with the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Advanced")
        }
    }

    // MARK: - Diagnostics (T19a: desktop Help → Run diagnostics → shareable report)

    private var diagnosticsSection: some View {
        Section {
            if isRunningDiagnostics {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Running diagnostics…")
                }
            } else if let urls = diagnosticsReportURLs, urls.count == 2 {
                ShareLink(item: urls[0]) {
                    Label("Share diagnostics report (markdown)", systemImage: "square.and.arrow.up")
                }
                ShareLink(item: urls[1]) {
                    Label("Share diagnostics report (JSON)", systemImage: "square.and.arrow.up")
                }
                Button("Run diagnostics again") { runDiagnostics() }
            } else {
                Button { runDiagnostics() } label: {
                    Label("Generate diagnostics report", systemImage: "wrench.and.screwdriver")
                }
            }
            if let diagnosticsError {
                Text(diagnosticsError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Runs the 12 desktop diagnostic steps (log level, connectivity, config, session, server connect, permissions, perf) and produces a shareable, masked report.")
        }
    }

    #if DEBUG
    // MARK: - Developer (T26 debug-only dual-render switch)

    private var developerSection: some View {
        Section {
            Button {
                isPresentingSurfaceInspector = true
            } label: {
                Label("Surface render modes…", systemImage: "square.stack.3d.up")
            }
            .accessibilityIdentifier("surfaceInspectorButton")
        } header: {
            Text("Developer")
        } footer: {
            Text("Debug build only. The dual-render switch lets each surface render natively "
                 + "(Path B, a SwiftUI screen card) or through the web view (Path A). Nothing "
                 + "ships native-by-default until its -AV validator passes.")
        }
    }
    #endif

    /// Builds a value-type `DiagnosticsContext` on the main actor (stores/webviews/vault are
    /// main-actor state; only the snapshot travels into the runner) and runs the service.
    private func runDiagnostics() {
        isRunningDiagnostics = true
        diagnosticsError = nil
        diagnosticsReportURLs = nil

        let diagDir = SentryService.crashReportsDirectory()
        let statuses: [WebViewStatusItem] = serverStore.servers.map { server in
            guard let store = viewStore?.view(forServerID: server.id) else {
                return WebViewStatusItem(serverID: server.id, serverName: server.name,
                                         mounted: false, hasURL: false, hasPageError: false, isLoading: false)
            }
            return WebViewStatusItem(serverID: server.id, serverName: server.name,
                                     mounted: true, hasURL: store.url != nil,
                                     hasPageError: store.pageError != nil, isLoading: store.isLoading)
        }
        let context = DiagnosticsContext(
            servers: serverStore.servers,
            preferences: AppPreferences(),
            vault: SecureVault(),
            settings: ShellSettingsSnapshot(
                themeSyncing: appSettings.themeSyncing,
                downloadHistoryLimit: appSettings.downloadHistoryLimit,
                appLanguage: appSettings.appLanguage,
                logLevel: appSettings.logLevel,
                appName: "Mattermost iOS",
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
                buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
            ),
            webViewStatuses: statuses,
            diagnosticsDirectory: diagDir,
            crashReportsDirectory: diagDir
        )

        Task {
            let service = DiagnosticsService(context: context)
            let report = await service.run()
            do {
                let (txt, json) = try service.writeReportFiles(report, to: diagDir)
                SentryService.shared.addBreadcrumb(category: "diagnostics",
                                                   message: "report generated",
                                                   level: "info")
                diagnosticsReportURLs = [txt, json]
            } catch {
                diagnosticsError = "Could not write report: \(error.localizedDescription)"
            }
            isRunningDiagnostics = false
        }
    }

    /// Desktop `defaultMessage` labels for the log-level options
    /// (`loggingLevel.level.{error,warn,info,verbose,debug,silly}`).
    private static func logLevelLabel(_ level: String) -> String {
        switch level {
        case "error": return "Errors (error)"
        case "warn": return "Errors and Warnings (warn)"
        case "info": return "Info (info)"
        case "verbose": return "Verbose (verbose)"
        case "debug": return "Debug (debug)"
        case "silly": return "Finest (silly)"
        default: return level
        }
    }
}

#Preview {
    SettingsView(serverStore: ServerStore(),
                 viewStore: nil,
                 appSettings: AppSettings(),
                 sessionStore: SessionStore())
}
