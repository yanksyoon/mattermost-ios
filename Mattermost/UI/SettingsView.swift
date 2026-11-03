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
    /// T43: which input reports mentions (backed by the process-wide `NotificationInputRouting`), and the
    /// native input's own read-out. Optional so the view still renders in a preview or a test host that has
    /// no shell; the app always passes both (`RootView` → here).
    var notificationPath: NotificationPathStore? = nil
    var notificationFeed: NativeNotificationFeed? = nil
    /// T31: the app-level auth owner. Settings is the shell's home for "sign out of this server":
    /// the native session lives in this object, so a sign-out here and a 401 anywhere else are the
    /// same state change.
    @EnvironmentObject private var auth: AuthCoordinator
    /// T50: the profile owner, read for the signed-in account's id (Settings → Account is one of the
    /// two ways into the edit form; the reader's own profile is the other).
    @EnvironmentObject private var profiles: ProfileCoordinator

    @Environment(\.dismiss) private var dismiss
    /// T45-AV-R: the download-location row stacks at accessibility text sizes (see
    /// `downloadLocationRow`).
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Server opened in `ServerFormView` (edit mode when non-nil).
    @State private var editingServer: ServerConfig?
    @State private var isPresentingServerForm = false
    @State private var serverPendingRemoval: ServerConfig?
    /// Non-nil while the sign-out confirmation is up for that server.
    @State private var serverPendingSignOut: ServerConfig?
    /// T50: the account whose edit-profile sheet is up, if any.
    @State private var editProfileTarget: EditProfileTarget?

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
                accountSection
                generalSection
                notificationsSection
                notificationInputSection
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
            .sheet(item: $editProfileTarget) { target in
                EditProfileSheet(server: target.server, userID: target.userID)
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

    // MARK: - Account (T50: edit profile / picture / custom fields)

    /// The reader's own account, per server: the entry point the card measures (Settings → Account).
    ///
    /// Only servers with a native session appear, for the same reason the Session section lists only
    /// those: a webview-only sign-in has no account this shell can write, and a row that would fail
    /// is worse than an absent one.
    @ViewBuilder
    private var accountSection: some View {
        let signedIn = serverStore.servers.filter { auth.authState(for: $0) == .signedIn }
        let entries = signedIn.compactMap { server -> (server: ServerConfig, userID: String)? in
            guard let id = profiles.myUserID(for: server), !id.isEmpty else { return nil }
            return (server, id)
        }
        if !entries.isEmpty {
            Section {
                ForEach(entries, id: \.server.id) { entry in
                    Button {
                        editProfileTarget = EditProfileTarget(server: entry.server,
                                                              userID: entry.userID)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Edit profile", systemImage: "person.crop.circle")
                            if serverStore.servers.count > 1 {
                                Text(entry.server.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("settings.editProfile.\(entry.server.id.uuidString)")
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Change your name, position, picture and the profile fields this server offers.")
                    .font(.caption)
            }
        }
    }

    // MARK: - General (desktop `general` category)

    /// T45-AV-R §2: the download location row.
    ///
    /// T45 shipped this as a `LabeledContent` with the path in the value and `.lineLimit(2)`. At
    /// AX3 that is a two-column row in a ~330 pt form: the label column was squeezed until
    /// "Download Location" broke mid-word (`Down-/load/Location`) and the value, a sandbox path
    /// three times the width of its column, was cut to `/Users/…/Downloads/` — Apple's audit
    /// reported `Text clipped` on it. At an accessibility size the row now keeps the
    /// `LabeledContent` pairing but stacks it — label above value, both full width — and the
    /// value's line cap goes away, so the path wraps in full instead of being truncated. The full
    /// path is also the value's `accessibilityValue`, so a truncated *drawing* can never hide
    /// what the row points at.
    ///
    /// Why not a bare `VStack` and nothing else: measured at AX3, the two label sentences are
    /// reported as `Text clipped` whatever their accessibility shape (see the comment in the AX
    /// branch) — so this fix is judged on the drawing and on the value, which is what T45 actually
    /// cut. `docs/t45-avr-a11y-pass.md` §3 carries the measurement table.
    @ViewBuilder
    private var downloadLocationRow: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                downloadLocationLabel
                downloadLocationValue
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Measured, not assumed — the audit's `Text clipped` on these two sentences survives
            // every shape I can give them from SwiftUI, with byte-identical frames (AX3: 181×96
            // and 294×116; AX5: 221×117) across: loose `StaticText`s, `children: .contain`,
            // `children: .ignore` with a short label + value, `children: .combine`, and
            // `LabeledContent`'s label slot. The one arrangement that reported zero was
            // `LabeledContent { path } label: { heading, caption }` at AX5 — where the two-column
            // style squeezed the label column to zero width so the heading was not drawn at all
            // (capture in the evidence dir): a clean audit bought by deleting the label, which is
            // not a fix. The finding T45 shipped — the path cut to `/Users/…/Downloads/` — is gone:
            // the value below draws the whole `/Users/…/CoreSimulator/…/Downloads` at AX3 and AX5,
            // and the value element is not reported at either size.
            // docs/t45-avr-a11y-pass.md §3 carries the table and the residual findings.
        } else {
            LabeledContent {
                downloadLocationValue
                    .multilineTextAlignment(.trailing)
            } label: {
                downloadLocationLabel
            }
        }
    }

    private var downloadLocationLabel: some View {
        // One `Text`, not two: the heading and the explanation are joined into a single text layer
        // with two styles, and the layer carries an explicit label and value — the same shape the
        // path below uses, and the only shape on this row that Apple's audit does not report. Two
        // separate `Text`s are reported at both AX3 and AX5 (AX3: 296×43 drawn on one line, i.e.
        // nothing is clipped, and still reported), so the finding tracks the element shape, not the
        // drawing. `+` on `Text` keeps the heading at `subheadline` and the explanation at
        // `caption`, so the hierarchy the row had is unchanged.
        (Text("Download Location")
            .font(.subheadline)
         + Text("\n")
         + Text("Files are saved to the app's Downloads folder.")
            .font(.caption)
            .foregroundColor(.secondary))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Download location")
            .accessibilityValue("Files are saved to the app's Downloads folder.")
    }

    private var downloadLocationValue: some View {
        Text(Self.downloadsPath)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            .truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("settingsDownloadLocationValue")
            // The row's answer to "where do downloads go", independent of how much of it fits.
            .accessibilityLabel("Download location")
            .accessibilityValue(Self.downloadsPath)
    }

    private static var downloadsPath: String {
        URL.downloadsDirectory.path(percentEncoded: false)
    }

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
            downloadLocationRow
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

    // MARK: - Mention input (T43: which path reports mentions, and what it has done)

    /// Renders only when the shell handed the two objects in (the app always does; a preview or a bare
    /// test host gets no row rather than a crash).
    @ViewBuilder
    private var notificationInputSection: some View {
        if let notificationPath, let notificationFeed {
            NotificationInputSection(path: notificationPath,
                                     feed: notificationFeed,
                                     routing: .shared)
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

/// T45-AV-R §2 measurement note: a custom `LabeledContentStyle` that stacked the label above the
/// value was tried and **crashed the app** under `performAccessibilityAudit` (twice, with and
/// without a `frame`), so the row stacks with a plain `VStack` and the label/value pairing is
/// carried by `accessibilityLabel`/`accessibilityValue` on the value instead. Deleted rather than
/// shipped as dead code.
#Preview {
    SettingsView(serverStore: ServerStore(),
                 viewStore: nil,
                 appSettings: AppSettings(),
                 sessionStore: SessionStore())
}
