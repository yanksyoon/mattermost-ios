// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/mfa/index.tsx (shield glyph + `Enter MFA Token` heading + subheader +
//        numeric code field + `Proceed`), app/screens/mfa/shield.tsx.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §3; no
// upstream source copied. SwiftUI decomposition per docs/component-map.md §1.

import SwiftUI

/// The TOTP/TFA challenge screen (component map S02), rendered inside the auth surface when
/// `POST /users/login` answers `api.context.mfa_required`.
///
/// Structure follows the mobile screen: a security glyph, "Enter MFA Token", the explanation, one
/// numeric field and a single action. A wrong code is shown *here*, with the field cleared, rather
/// than thrown back to the password form — the distinction the acceptance criteria name.
struct MFAView: View {

    @ObservedObject var model: MFAViewModel
    /// Back to the password form (upstream's back button). Not a dismiss: nothing was signed in.
    var onBack: () -> Void

    @FocusState private var isCodeFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 44))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .padding(.top, 8)
                .accessibilityHidden(true)

            Text("Enter MFA Token")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text("To complete the sign in process, please enter the code from your authenticator app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            VStack(alignment: .leading, spacing: 6) {
                TextField("Enter MFA Token", text: $model.code)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($isCodeFocused)
                    .submitLabel(.go)
                    .onSubmit { Task { await model.submit() } }
                    // Typing clears the previous rejection — but only *typing*: a failed attempt
                    // clears the field itself, and that programmatic empty must not wipe the very
                    // message that explains it.
                    .onChange(of: model.code) { _, newValue in
                        if !newValue.isEmpty { model.clearError() }
                    }
                    .accessibilityLabel("MFA token")
                    .accessibilityIdentifier("mfaCodeField")
            }

            if let error = model.errorMessage {
                errorText(error)
            }

            Button {
                Task { await model.submit() }
            } label: {
                HStack(spacing: 8) {
                    if model.isSubmitting { ProgressView().controlSize(.small) }
                    Text(model.isSubmitting ? "Verifying…" : "Proceed")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canSubmit)
            .accessibilityIdentifier("mfaSubmitButton")

            Button("Use a different account", action: onBack)
                .font(.footnote)
                .accessibilityIdentifier("mfaBackButton")
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .frame(maxWidth: 480)
        .onAppear { isCodeFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mfaView")
    }

    private func errorText(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)   // the sentence is the message; the glyph is not
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("mfaErrorText")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
