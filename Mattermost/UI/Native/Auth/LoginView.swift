// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/login/index.tsx (server name, login form, SSO options row),
//        app/screens/login/form.tsx (email/username + password fields, log-in button, error placement),
//        app/screens/login/sso_options.tsx (SSO as an alternative to the password form).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §3; no
// upstream source copied. SwiftUI decomposition per docs/component-map.md §1.

import SwiftUI
import UIKit

/// The pane's auth card: the native sign-in surface for a server with no session.
///
/// It is gated by `SurfaceHost(.auth)`, like every other screen card (docs/dual-render.md §2):
///
///  - `.auth` resolves **native** → this screen (password form → MFA → signed in);
///  - `.auth` resolves **web** → the existing `NativeAuthPlaceholderView`, i.e. the honest stand-in
///    that names the state and offers the documented escape hatch (the pane's webview). That is the
///    shipping configuration until this card's `-AV` approves the surface, so the flag-off path is
///    byte-for-byte the T30-R behaviour and its UI tests keep asserting it.
///
/// SSO deliberately does **not** go native: the "Sign in with SSO" action presents `SSOView`, which
/// hosts the *existing* `WebViewContainer` (that flow and its certificate handling are load-bearing)
/// and adopts the session it establishes. Both routes therefore end in the same place — one
/// `AuthCoordinator` phase change, then the native shell.
struct AuthSurfaceView: View {
    let server: ServerConfig
    /// Explicit rather than an environment lookup: `LoginViewModel` needs its authenticator at
    /// `@StateObject` construction time, which is before the environment exists.
    @ObservedObject var coordinator: AuthCoordinator

    @EnvironmentObject private var resolver: SurfaceModeResolver
    @EnvironmentObject private var viewStore: ViewStore

    @StateObject private var model: LoginViewModel
    @State private var isPresentingSSO = false

    init(server: ServerConfig, coordinator: AuthCoordinator) {
        self.server = server
        self.coordinator = coordinator
        _model = StateObject(wrappedValue: LoginViewModel(
            serverName: server.name,
            serverURL: server.url,
            authenticator: ServerSignIn(server: server, coordinator: coordinator)))
    }

    var body: some View {
        SurfaceHost(.auth) {
            nativeSignIn
        } web: {
            NativeAuthPlaceholderView(server: server, resolver: resolver)
        }
    }

    // MARK: - Native branch

    private var nativeSignIn: some View {
        ScrollView {
            VStack(spacing: 18) {
                if coordinator.phase(for: server.id).isExpired {
                    SessionExpiredBanner(serverName: server.name)
                }

                // On the MFA step the token form is the whole screen (upstream `mfa/index.tsx`);
                // repeating the server heading above it would push the numeric keypad up into it.
                if model.mfa == nil { header }

                if let mfa = model.mfa {
                    MFAView(model: mfa) { model.leaveMFA() }
                } else {
                    LoginView(model: model) {
                        isPresentingSSO = true
                    } useWebView: {
                        // The escape hatch (docs/dual-render.md §8): hand the whole pane back to the
                        // webview for the rest of this run. It is the same guarantee the T26
                        // placeholder offered, kept exactly because sign-in is the one flow a user
                        // must never be locked out of.
                        resolver.forceWebForThisRun(SurfaceDefaults.paneHostSurface)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, max(28, statusBarInset + 8))
            .padding(.bottom, 28)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        // The sign-in screen is the one place in the shell that has **no** workspace chrome.
        //
        // Two reasons, both concrete: the shell's floating navigation bar overlays the stack's
        // content on iOS 26 and this scroll view is not the stack's primary scroll view (it lives
        // under `SurfaceHost`), so the bar would draw over the heading — the T31 evidence run
        // captured exactly that (the blue glyph and "Sign in to …" under the pill). And the
        // upstream mobile login screen has no switcher or settings chrome either: before there is
        // a session, switching workspace/settings are not actions that can do anything. Hiding the
        // bar removes the overlap structurally instead of guessing a bar height, and the escape
        // hatch below ("Use the web view instead") stays available for a server that misbehaves.
        //
        // Reached only while `.auth` resolves native, i.e. after this card's `-AV` approval: the
        // shipping (web) branch is the untouched T30 stand-in, chrome included.
        .toolbar(.hidden, for: .navigationBar)
        .background(Color(.systemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeAuthSurface")
        .sheet(isPresented: $isPresentingSSO) {
            SSOView(server: server, coordinator: coordinator, viewStore: viewStore)
        }
        .sheet(item: $coordinator.pendingCertificatePrompt) { prompt in
            // The native transport met an untrusted certificate. Same sheet, same trust bag as the
            // webview path — trusting it here also lets the webview in, and vice versa (T28 §4).
            CertPromptSheet(prompt: prompt) { trust, dontTrustAgain in
                coordinator.resolveCertificatePrompt(trust: trust, dontTrustAgain: dontTrustAgain)
            }
        }
    }

    private var statusBarInset: CGFloat {
        // The shell lays each mounted server scene out edge to edge (`RootView`'s ZStack sits under
        // the navigation bar), so inside a native pane the SwiftUI safe area is zero and a plain
        // scroll view would start at y = 0 — under the status bar. Read the window's real inset
        // rather than hard-coding a device height; Catalyst reports 0 and falls back to the padding.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow }
        return window?.safeAreaInsets.top ?? 0
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 40))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("Sign in to \(server.name)")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("authServerTitle")

            Text(model.serverHost)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("authServerHost")
        }
        .padding(.bottom, 4)
    }
}

// MARK: - The form

/// Email/username + password, with the server's own error sentence under the fields — the placement
/// the mobile form uses (`form.tsx` passes the error into the password input).
struct LoginView: View {

    @ObservedObject var model: LoginViewModel
    /// SSO alternative (mobile `sso_options.tsx`): a second route to the same session.
    var useSSO: () -> Void
    /// The always-usable escape hatch back to the webview.
    var useWebView: () -> Void

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case loginID
        case password
    }

    var body: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Email or username")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Email or username", text: $model.loginID)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .textContentType(.username)
                    .submitLabel(.next)
                    .focused($focusedField, equals: .loginID)
                    .onSubmit { focusedField = .password }
                    .onChange(of: model.loginID) { _, newValue in
                        if !newValue.isEmpty { model.clearError() }
                    }
                    .accessibilityIdentifier("loginIDField")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Password")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                SecureField("Password", text: $model.password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .onSubmit { Task { await model.submit() } }
                    .onChange(of: model.password) { _, newValue in
                        if !newValue.isEmpty { model.clearError() }
                    }
                    .accessibilityIdentifier("loginPasswordField")
            }

            if let error = model.errorMessage {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)   // the sentence is the message; the glyph is not
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("loginErrorText")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                focusedField = nil
                Task { await model.submit() }
            } label: {
                HStack(spacing: 8) {
                    if model.isSubmitting { ProgressView().controlSize(.small) }
                    Text(model.isSubmitting ? "Logging in…" : "Log In")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canSubmit)
            .accessibilityIdentifier("loginSubmitButton")

            HStack(spacing: 10) {
                Rectangle().fill(Color.secondary.opacity(0.24)).frame(height: 1)
                Text("or").font(.caption).foregroundStyle(.secondary)
                Rectangle().fill(Color.secondary.opacity(0.24)).frame(height: 1)
            }
            .padding(.vertical, 2)

            Button(action: useSSO) {
                Label("Sign in with SSO", systemImage: "person.badge.key")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("authSSOButton")

            Button("Use the web view instead", action: useWebView)
                .font(.footnote)
                .accessibilityIdentifier("authUseWebViewButton")
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("loginView")
    }
}

// MARK: - Session expired

/// The re-auth banner: the one screen state a 401 produces.
///
/// A 401 (a rejected stored token at launch, or any authenticated native call later) resolves the
/// server to `.expired` in `AuthCoordinator`; the shell then renders this surface, and this banner
/// explains *why* the user is looking at a login form again. That is the "one re-auth path, never a
/// dead screen" criterion: the state is a property of the auth layer, not of whichever screen
/// happened to make the call.
struct SessionExpiredBanner: View {
    let serverName: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your session expired")
                    .font(.subheadline.weight(.semibold))
                Text("Sign in again to \(serverName) to continue.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sessionExpiredBanner")
    }
}
