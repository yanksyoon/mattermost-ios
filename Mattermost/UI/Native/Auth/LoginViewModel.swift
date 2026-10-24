// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/login/form.tsx (field rules, disabled-button rule, `loginId.toLowerCase()`,
//        MFA routing on `api.context.mfa_required`, error copy for invalid credentials),
//        app/utils/errors.ts (error → user copy).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §3; no
// upstream source copied. The `@Observable`-style view model is this repo's own decomposition
// (docs/component-map.md §1: `useState` → owned view-model state).

import Foundation
import Combine

/// The sign-in form's state machine, split out of the view so the rules the card is graded on are
/// unit-testable without a UI host:
///
///  - **When the button is live** — mobile's `getButtonDisabled`: a login id *and* a password, and
///    not already submitting.
///  - **What the id becomes** — upstream lowercases it before `POST /users/login`; so does this.
///  - **Which failure lands where** — an MFA challenge moves to the MFA step (and keeps the
///    credential for the second call, as the mobile client does); a wrong password becomes an
///    inline error *on the form*; an expired/stored session is a different, earlier state owned by
///    `AuthCoordinator`.
///
/// Security: the password lives in memory only, is never logged, never written anywhere, and is
/// dropped as soon as the session is established. `description` is implemented to prove the last
/// part is not an accident.
@MainActor
final class LoginViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case submitting
        case failed
        case signedIn(username: String)
    }

    @Published var loginID = ""
    @Published var password = ""
    /// The second-factor step, non-nil while the server is asking for a code.
    @Published private(set) var mfa: MFAViewModel?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var errorMessage: String?

    let serverName: String
    let serverURL: URL
    let authenticator: LoginAuthenticating

    init(serverName: String, serverURL: URL, authenticator: LoginAuthenticating) {
        self.serverName = serverName
        self.serverURL = serverURL
        self.authenticator = authenticator
    }

    // MARK: - Derived state (what the view binds to)

    var trimmedLoginID: String {
        loginID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isSubmitting: Bool { phase == .submitting }

    /// Mobile `getButtonDisabled`, minus the magic-link/deactivated branches (guest magic links and
    /// EMM are not part of this client).
    var canSubmit: Bool {
        !trimmedLoginID.isEmpty && !password.isEmpty && !isSubmitting
    }

    var isShowingMFA: Bool { mfa != nil }

    var isSignedIn: Bool {
        if case .signedIn = phase { return true }
        return false
    }

    /// The connection copy under the form (server host, not the full URL: the URL is already in the
    /// shell's title and is not useful twice).
    var serverHost: String {
        serverURL.host ?? serverURL.absoluteString
    }

    // MARK: - Actions

    /// `POST /users/login`. A `mfaRequired` answer switches to the MFA step and keeps the
    /// credential in memory for the follow-up call; everything else is an inline error.
    func submit() async {
        guard !isSubmitting else { return }
        let identifier = trimmedLoginID.lowercased()
        guard !identifier.isEmpty, !password.isEmpty else {
            phase = .failed
            errorMessage = "Enter your email or username and password."
            return
        }
        phase = .submitting
        errorMessage = nil
        do {
            let session = try await authenticator.login(loginID: identifier,
                                                        password: password,
                                                        mfaToken: nil)
            finish(with: session)
        } catch let error as MMError {
            if case .mfaRequired = error {
                beginMFA(loginID: identifier)
                return
            }
            phase = .failed
            errorMessage = LoginErrorCopy.message(for: error)
        } catch {
            phase = .failed
            errorMessage = LoginErrorCopy.message(for: error)
        }
    }

    /// Leave the MFA step (upstream's back button): the credential is kept so the user can simply
    /// re-enter the code, but a fresh challenge is required if they change the id.
    func leaveMFA() {
        mfa = nil
        phase = .idle
        errorMessage = nil
    }

    /// A field edit clears the inline error, as on the mobile form.
    func clearError() {
        if errorMessage != nil {
            errorMessage = nil
            if phase == .failed { phase = .idle }
        }
    }

    // MARK: - Internals

    private func beginMFA(loginID identifier: String) {
        phase = .idle
        errorMessage = nil
        let model = MFAViewModel(serverName: serverName,
                                 loginID: identifier,
                                 password: password,
                                 authenticator: authenticator)
        model.onSignedIn = { [weak self] session in
            self?.finish(with: session)
        }
        mfa = model
    }

    private func finish(with session: AuthSession.Session) {
        // The credential has done its job: drop it rather than keep it alive with the screen.
        password = ""
        mfa = nil
        errorMessage = nil
        phase = .signedIn(username: session.username)
    }
}

extension LoginViewModel {
    /// Redacted summary for diagnostics and tests. Not `CustomStringConvertible`: the conformance
    /// itself would cross the main-actor boundary (a Swift 6 error), and a computed property the
    /// tests call directly proves the same thing — the password and the login id never appear in a
    /// string this model can produce.
    var redactedDescription: String {
        "LoginViewModel(server: \(serverName), phase: \(phase), password: <redacted>, login: <redacted>)"
    }
}

/// Error → copy for the auth screens. Pure, so every branch the acceptance criteria name has a
/// test: wrong password, MFA required / wrong code, network failure.
enum LoginErrorCopy {

    static func message(for error: Error) -> String {
        guard let mmError = error as? MMError else {
            return error.localizedDescription
        }
        switch mmError {
        case .unauthorized(let message):
            // The server's own sentence is the most precise explanation ("Enter a valid email or
            // username and/or password."), and it is what the web app shows. Fall back to the
            // mobile client's copy when the server sent none.
            if let message = message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
                return message
            }
            return "The email and password combination is incorrect."
        case .invalidMFA(let message):
            if let message = message?.trimmingCharacters(in: .whitespacesAndNewlines),
               !message.isEmpty, message.lowercased() != "invalid mfa token" {
                return message
            }
            return "That authentication code was not accepted."
        case .mfaRequired:
            return "Enter your multi-factor authentication code."
        case .offline:
            return "You appear to be offline. Check your connection and try again."
        case .timeout:
            return "The server took too long to respond. Try again."
        case .certificateUntrusted:
            return "This server's certificate is not trusted yet. Review it, then try again."
        case .forbidden:
            return "You do not have permission to sign in to this server."
        case .notFound:
            return "This server has no sign-in endpoint. Check the server address."
        case .rateLimited(let retryAfter):
            if let retryAfter { return "Too many attempts. Try again in \(Int(retryAfter.rounded()))s." }
            return "Too many attempts. Try again shortly."
        case .server(let status, let message):
            if let message, !message.isEmpty { return message }
            return "The server had a problem (\(status)). Try again."
        case .client(_, let message):
            if let message, !message.isEmpty { return message }
            return "The server rejected that sign-in."
        case .malformedResponse:
            return "The server's answer could not be read. Check that this is a Mattermost server."
        case .transport:
            return "Could not reach the server. Check the address and your connection."
        case .notSignedIn:
            return "Your session expired. Sign in again."
        case .cancelled:
            return "Sign-in was cancelled."
        case .invalidURL:
            return "That server address is not valid."
        }
    }
}
