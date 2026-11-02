// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/forgot_password/index.tsx ("Reset Your Password", the email field, the
//        "Reset Link Sent" state, "Return to Log In", and the failure copy) and
//        app/actions/remote/session.ts (`sendPasswordResetEmail` →
//        `POST /users/password/reset/send`).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §3; no
// upstream source copied. SwiftUI decomposition is this repo's own (S04).

import SwiftUI

/// **Forgot / reset password** (S04).
///
/// The flow is upstream's: one email field, a client-side `isEmail` check, then
/// `POST /api/v4/users/password/reset/send`. A `{"status":"OK"}` answer shows the sent state —
/// "If the account exists, a password reset email will be sent to: <address>" — deliberately
/// identical whether or not the address exists, because the server's answer must not become an
/// account oracle. Anything else is shown honestly rather than as a fake success, which matters on
/// a server whose SMTP is not configured: the endpoint then answers `500
/// api.user.send_password_reset.send.app_error`, and that is what the reader sees.
struct ForgotPasswordView: View {
    @ObservedObject var model: ForgotPasswordViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if case .sent(let email) = model.phase {
                    sent(email: email)
                } else {
                    form
                }
            }
            .navigationTitle("Reset Your Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("forgotPasswordCancelButton")
                }
            }
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("To reset your password, enter the email address you used to sign up.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Email")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("Email", text: $model.email)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .submitLabel(.go)
                        .onSubmit { Task { await model.submit() } }
                        .onChange(of: model.email) { _, _ in model.clearError() }
                        .accessibilityIdentifier("forgotPasswordEmailField")
                }

                if let error = model.errorMessage {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .accessibilityHidden(true)
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("forgotPasswordError")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    Task { await model.submit() }
                } label: {
                    HStack(spacing: 8) {
                        if model.isSubmitting { ProgressView().controlSize(.small) }
                        Text(model.isSubmitting ? "Sending…" : "Reset Your Password")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canSubmit)
                .accessibilityIdentifier("forgotPasswordSubmitButton")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("forgotPasswordForm")
    }

    private func sent(email: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "envelope.badge.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Reset Link Sent")
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("forgotPasswordSentTitle")
            Text("If the account exists, a password reset email will be sent to:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(email)
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("forgotPasswordSentEmail")
            Button("Return to Log In") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("forgotPasswordReturnButton")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The request

@MainActor
final class ForgotPasswordViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case submitting
        case sent(email: String)
        case failed
    }

    @Published var email = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var errorMessage: String?

    private let service: AccountServicing

    init(service: AccountServicing) {
        self.service = service
    }

    var isSubmitting: Bool { phase == .submitting }

    var canSubmit: Bool {
        if isSubmitting { return false }
        if case .sent = phase { return false }
        return !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func submit() async {
        guard !isSubmitting else { return }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard EmailAddress.isValid(address) else {
            phase = .failed
            errorMessage = "Please enter a valid email address."
            return
        }

        phase = .submitting
        errorMessage = nil
        do {
            try await service.requestPasswordReset(email: address)
            phase = .sent(email: address)
        } catch {
            phase = .failed
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
