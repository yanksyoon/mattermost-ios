// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/terms_of_service/terms_of_service.tsx (the blocking screen: document text,
//        Accept, Decline with the "You must accept the terms of service" logout copy, and the
//        "Failed to get the ToS." retry state).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §3; no
// upstream source copied. SwiftUI decomposition is this repo's own.

import SafariServices
import SwiftUI

/// **The blocking terms-of-service gate** (S06).
///
/// Shown by `NativeShellView` as a top-level branch when the auth gate says
/// `.termsOfServiceRequired` — not a sheet, not an alert: there is nothing to swipe away, because
/// the shell behind it would be a workspace whose every write the server refuses. The only ways
/// out are Accept (the server records it, the gate disappears), Retry (when the answer could not
/// be read), or Decline (sign out and return to the sign-in form).
///
/// The document shown is the server's own `text` from `GET /terms_of_service`. When the server
/// also publishes a `TermsOfServiceLink`, "Read the full terms" opens that URL in an in-app
/// `SFSafariViewController` — the document itself, in a webview, with no bridge and no script
/// surface of ours.
struct TermsOfServiceView: View {
    let server: ServerConfig
    @ObservedObject var coordinator: AuthCoordinator

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isAccepting = false
    @State private var isConfirmingDecline = false
    @State private var errorMessage: String?
    @State private var policy: ServerAuthPolicy?
    @State private var presentedLink: DocumentLink?

    private var state: TermsOfServiceState { coordinator.termsState(for: server) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                content
                actions
            }
            .padding(.horizontal, 24)
            .padding(.top, max(28, statusBarInset + 8))
            .padding(.bottom, 32)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .task {
            // The link is a nicety; a server that does not publish the policy still gets a usable
            // gate (the document text is already in hand).
            policy = try? await coordinator.authPolicy(for: server)
        }
        .confirmationDialog("Sign out of \(server.name)?",
                            isPresented: $isConfirmingDecline,
                            titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task { await coordinator.signOut(server) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You must accept the terms of service to access this server. You will now be signed out.")
        }
        .sheet(item: $presentedLink) { link in
            InAppBrowser(url: link.url)
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("Terms of Service")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("termsOfServiceTitle")

            Text("To continue to \(server.name), accept the Terms of Service this server requires.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .pending(let document):
            Text(document.text.isEmpty
                 ? "This server requires you to accept its Terms of Service."
                 : document.text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("termsOfServiceText")
        case .unreadable(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Text("We could not load the Terms of Service.")
                    .font(.subheadline.weight(.semibold))
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("termsOfServiceUnreadable")
        case .unknown, .notRequired, .accepted:
            // `.notRequired`/`.accepted` never render this view (the gate is only mounted while
            // blocked); `.unknown` is the frame before the check lands.
            HStack(spacing: 10) {
                ProgressView()
                Text("Checking the Terms of Service…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("termsOfServiceChecking")
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let errorMessage {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("termsOfServiceError")
                }
            }

            if let link = policy?.termsOfServiceLink {
                Button {
                    presentedLink = DocumentLink(url: link)
                } label: {
                    Label("Read the full terms", systemImage: "safari")
                }
                .accessibilityIdentifier("termsOfServiceDocumentLink")
            }

            Button {
                isConfirmingDecline = false
                accept()
            } label: {
                HStack(spacing: 8) {
                    if isAccepting { ProgressView().controlSize(.small) }
                    Text(isAccepting ? "Accepting…" : "Accept")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isAccepting)
            .accessibilityIdentifier("termsOfServiceAcceptButton")

            if blocksOnUnreadable {
                Button("Try again") {
                    errorMessage = nil
                    Task { await coordinator.retryTermsOfService(server) }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("termsOfServiceRetryButton")
            }

            Button("Decline and sign out", role: .destructive) {
                isConfirmingDecline = true
            }
            .font(.footnote)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("termsOfServiceDeclineButton")
        }
        .frame(maxWidth: .infinity)
    }

    private var blocksOnUnreadable: Bool {
        if case .unreadable = state { return true }
        return false
    }

    // MARK: Actions

    private func accept() {
        guard !isAccepting else { return }
        isAccepting = true
        errorMessage = nil
        Task {
            do {
                try await coordinator.acceptTermsOfService(server)
            } catch {
                errorMessage = LoginErrorCopy.message(for: error)
            }
            isAccepting = false
        }
    }

    private var statusBarInset: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow }
        return window?.safeAreaInsets.top ?? 0
    }
}

// MARK: - The document, in a webview

/// A server-published link, wrapped so `sheet(item:)` can carry it without adding
/// `Identifiable` to `URL` itself (a retroactive conformance on a Foundation type is a
/// cross-repo collision waiting to happen).
struct DocumentLink: Identifiable, Equatable {
    let url: URL
    var id: String { url.absoluteString }
}

/// The server's published TOS link, rendered in the system's in-app browser: a real webview for
/// the document itself, with no `WKScriptMessageHandler` of ours behind it — nothing about this
/// sheet is reachable from the page's JavaScript.
struct InAppBrowser: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
