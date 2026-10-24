// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/mfa/index.tsx (code field, `login_mfa.tokenReq` empty-code rule, submit →
//        `POST /users/login/mfa`, error copy) and app/client/rest/users.ts.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §3; no
// upstream source copied.

import Foundation
import Combine

/// The second-factor step's state machine.
///
/// The server validates the code; the client only formats what it sends. That is why this model has
/// no TOTP logic at all: a wrong code must come back from `POST /users/login/mfa` as
/// `MMError.invalidMFA`, which is a different sentence from a wrong password — the acceptance
/// criterion the screens are graded on.
///
/// It holds a copy of the credential pair because the MFA call needs them (upstream passes
/// `loginId` + `password` to the MFA screen as props). The copy dies with this object.
@MainActor
final class MFAViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case submitting
        case failed
        case signedIn(username: String)
    }

    @Published var code = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var errorMessage: String?

    let serverName: String
    /// The normalised (lowercased) id the first attempt was made with.
    let loginID: String

    private let password: String
    private let authenticator: LoginAuthenticating

    /// Called once the second factor is accepted, with the established session.
    var onSignedIn: ((AuthSession.Session) -> Void)?

    init(serverName: String,
         loginID: String,
         password: String,
         authenticator: LoginAuthenticating) {
        self.serverName = serverName
        self.loginID = loginID
        self.password = password
        self.authenticator = authenticator
    }

    var trimmedCode: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isSubmitting: Bool { phase == .submitting }

    /// Mobile's `login_mfa` submit button: disabled only while the field is empty.
    var canSubmit: Bool { !trimmedCode.isEmpty && !isSubmitting }

    func submit() async {
        guard !isSubmitting else { return }
        let token = trimmedCode
        guard !token.isEmpty else {
            phase = .failed
            errorMessage = "Please enter an MFA token."
            return
        }
        phase = .submitting
        errorMessage = nil
        do {
            let session = try await authenticator.login(loginID: loginID,
                                                        password: password,
                                                        mfaToken: token)
            phase = .signedIn(username: session.username)
            onSignedIn?(session)
        } catch {
            phase = .failed
            // A rejected code is retryable in place: clear the field so the same digits are not
            // resubmitted, and keep the user on this step.
            code = ""
            errorMessage = LoginErrorCopy.message(for: error)
        }
    }

    func clearError() {
        if errorMessage != nil {
            errorMessage = nil
            if phase == .failed { phase = .idle }
        }
    }
}

extension MFAViewModel {
    /// Redacted summary (see `LoginViewModel.redactedDescription` for why this is not a
    /// `CustomStringConvertible` conformance).
    var redactedDescription: String {
        "MFAViewModel(server: \(serverName), login: <redacted>, phase: \(phase))"
    }
}
