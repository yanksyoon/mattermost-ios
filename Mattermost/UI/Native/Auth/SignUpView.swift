// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/client/rest/users.ts (`createUser` → `POST /users` with `email` + `password`),
//        app/screens/forgot_password/index.tsx (the account-flow layout: a title, one sentence of
//        guidance, one field, one primary button — the shape reused here),
//        app/utils/helpers.ts (`isEmail`).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §3; no
// upstream source copied. The server-policy-driven form is this repo's own (S04).

import SwiftUI

/// **Create an account** (S04): email + password against the server's *own* policy.
///
/// The password rule is not hard-coded: `ServerAuthPolicy` decodes `PasswordMinimumLength`,
/// the four requirement switches and the server's 72-character cap from
/// `GET /config/client?format=old`, and the sentence under the field plus the submit rule are both
/// derived from it. On the 9.11 pin the fixture publishes `PasswordMinimumLength: "8"`, so the copy
/// reads "Use 8–72 characters."; a server configured to 14 (or with requirement switches on) gets
/// its own sentence without a code change.
///
/// After `POST /api/v4/users` succeeds the flow becomes an honest verification state: the server
/// does not tell this client whether the address still needs verifying, so the copy says what is
/// true either way — an email may be on its way, and sign-in is available now.
struct SignUpView: View {
    @ObservedObject var model: SignUpViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .created(let email):
                    success(email: email)
                default:
                    form
                }
            }
            .navigationTitle("Create account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.phase.isCreated ? "Done" : "Cancel") { dismiss() }
                        .accessibilityIdentifier("signUpCancelButton")
                }
            }
        }
        .task { await model.loadPolicy() }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Create an account on \(model.serverName).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let policy = model.policy, !policy.offersSignUp {
                    policyMessage("This server does not allow creating accounts by email. Ask its administrator for an invitation.")
                }

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
                        .onChange(of: model.email) { _, _ in model.clearError() }
                        .accessibilityIdentifier("signUpEmailField")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Password")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    SecureField("Password", text: $model.password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.newPassword)
                        .onChange(of: model.password) { _, _ in model.clearError() }
                        .accessibilityIdentifier("signUpPasswordField")
                    if let policy = model.policy {
                        Text(policy.passwordPolicyCopy)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("signUpPasswordPolicy")
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Confirm password")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    SecureField("Confirm password", text: $model.confirmPassword)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.newPassword)
                        .onChange(of: model.confirmPassword) { _, _ in model.clearError() }
                        .onSubmit { Task { await model.submit() } }
                        .accessibilityIdentifier("signUpConfirmPasswordField")
                }

                if let error = model.errorMessage {
                    errorRow(error, identifier: "signUpError")
                }

                Button {
                    Task { await model.submit() }
                } label: {
                    HStack(spacing: 8) {
                        if model.isSubmitting { ProgressView().controlSize(.small) }
                        Text(model.isSubmitting ? "Creating account…" : "Create account")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canSubmit)
                .accessibilityIdentifier("signUpSubmitButton")
                .accessibilityValue(model.blockingReason)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("signUpForm")
    }

    private func success(email: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Check your email")
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("signUpSuccessTitle")
            Text("Your account on \(model.serverName) was created. If this server requires email verification, a message is on its way to \(email). You can sign in once it is verified.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("signUpSuccessMessage")
            Button("Back to sign in") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("signUpDoneButton")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func policyMessage(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func errorRow(_ text: String, identifier: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The form's state machine

/// The rules the card grades, out of the view so they are unit-testable: what makes the button
/// live, which sentence a failure shows, and the verification state after a successful create.
@MainActor
final class SignUpViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case submitting
        /// `POST /users` succeeded. Carries the address the verification copy names.
        case created(email: String)
        case failed

        var isCreated: Bool {
            if case .created = self { return true }
            return false
        }
    }

    @Published var email = ""
    @Published var password = ""
    @Published var confirmPassword = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var policy: ServerAuthPolicy?

    let serverName: String
    private let service: AccountServicing

    init(serverName: String, service: AccountServicing) {
        self.serverName = serverName
        self.service = service
    }

    var isSubmitting: Bool { phase == .submitting }

    /// The server's rules, once known. A policy read failure leaves `policy` nil, which relaxes the
    /// local length check to "non-empty": the server still enforces its own rule and answers with
    /// its own sentence, and a form that refuses to submit because it could not learn the rule
    /// would be worse than one the server can correct.
    var canSubmit: Bool { blockingReason == Self.ready }

    static let ready = "ready"

    /// Why Submit is disabled, in the form's own words. Rendered as the button's accessibility
    /// value: a reader (and the UI suite) is told what is still missing instead of facing a dead
    /// control, and a live run can say *which* rule held the form back.
    var blockingReason: String {
        if phase.isCreated { return "the account has been created" }
        if isSubmitting { return "creating the account" }
        guard policy?.offersSignUp ?? true else { return "this server does not allow sign-up" }
        guard EmailAddress.isValid(email) else { return "enter a valid email address" }
        guard !password.isEmpty else { return "enter a password" }
        guard password == confirmPassword else { return "the passwords do not match" }
        if let problem = policy?.passwordProblem(password) { return problem }
        return Self.ready
    }

    func loadPolicy() async {
        guard policy == nil else { return }
        do {
            policy = try await service.policy()
        } catch {
            // A policy read failure must not make sign-up impossible: the server still enforces
            // its own rule and answers with its own sentence. Leave `policy` nil, which relaxes
            // the local length check to "non-empty".
            MMLog.info("MMAuth", "sign-up policy could not be read: \(LoginErrorCopy.message(for: error))")
        }
    }

    func submit() async {
        guard !isSubmitting else { return }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard EmailAddress.isValid(address) else {
            phase = .failed
            errorMessage = "Please enter a valid email address."
            return
        }
        if password != confirmPassword {
            phase = .failed
            errorMessage = "The passwords do not match."
            return
        }
        if let problem = policy?.passwordProblem(password) {
            phase = .failed
            errorMessage = problem
            return
        }
        guard !password.isEmpty else {
            phase = .failed
            errorMessage = "Enter a password."
            return
        }

        phase = .submitting
        errorMessage = nil
        do {
            _ = try await service.createAccount(email: address, password: password)
            password = ""
            confirmPassword = ""
            phase = .created(email: address)
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
