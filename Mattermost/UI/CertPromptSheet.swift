import SwiftUI

/// Native counterpart of the desktop certificate prompt cluster (parity row: `modals/certificate`
/// / `showCertificateModal` + `certificateStore` -> `CertPromptSheet`, design §4d).
///
/// The desktop shows a modal when a server presents an untrusted / self-signed certificate:
/// the renderer's `modals/certificate` flow lets the user inspect the certificate
/// (`ShowCertificateModal`) and then either accept it into the trust bag (`certificateStore.add`)
/// or refuse it. On iOS the webview's `didReceive` server-trust challenge already consults the
/// trust bag (`WebViewContainer`); when the certificate is unseen the Coordinator publishes a
/// `CertificatePrompt` and this sheet collects the user's decision:
///
///   - **Trust** — record `certTrust.add(origin, cert, dontTrust: false)` and reload; the next
///     challenge auto-accepts (desktop `add` + `reload`).
///   - **Don't ask again** — record `dontTrust: true` so future challenges hard-reject without
///     a prompt (desktop cancel-with-remember).
///   - **Certificate Information** — push the `ShowCertificateModal` port (subject/issuer/serial/
///     validity/fingerprint).
///
/// Security boundary: this sheet is the ONLY path that writes the trust bag; page JS has no
/// access to it (the bridge surface is closed), mirroring the desktop where only the native
/// modal flow calls `certificateStore.add`.
struct CertPromptSheet: View {

    /// The certificate + origin being decided (published by the webview coordinator).
    let prompt: CertificatePrompt
    /// Called with (trust: Bool, dontTrustAgain: Bool). `trust` == accept into the bag;
    /// `dontTrustAgain` marks an explicit refusal that suppresses future prompts.
    let onDecision: (_ trust: Bool, _ dontTrustAgain: Bool) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 34))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Untrusted certificate")
                            .font(.headline)
                        Text(prompt.certificate.issuerName)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Text("The server at \(prompt.origin.absoluteString) presented a certificate that this device does not trust. If you know this server is legitimate, you can trust its certificate to connect.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let info = prompt.info, !info.subject.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Subject", value: info.subject)
                        if !info.issuer.isEmpty { LabeledContent("Issuer", value: info.issuer) }
                        if !info.serialNumber.isEmpty { LabeledContent("Serial", value: info.serialNumber) }
                    }
                    .font(.footnote)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Certificate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Trust") {
                        onDecision(true, false)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDecision(false, false)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if prompt.info != nil {
                        NavigationLink {
                            CertificateInfoSheet(info: prompt.info!)
                        } label: {
                            Text("Certificate Information")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    Button(role: .destructive) {
                        onDecision(false, true)
                    } label: {
                        Text("Don't Trust and Don't Ask Again")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .padding()
                .background(.bar)
            }
        }
        .accessibilityIdentifier("certPromptSheet")
    }
}

/// Native counterpart of desktop `ShowCertificateModal` (`modals/certificate`): the read-only
/// "Certificate information" detail listing subject/issuer/serial/validity/fingerprint — the
/// exact fields the desktop renders from Electron's `Certificate` object.
struct CertificateInfoSheet: View {
    let info: CertificateInfo

    var body: some View {
        List {
            Section("Subject Name") {
                LabeledContent("Common Name", value: info.subject)
            }
            Section("Issuer Name") {
                LabeledContent("Common Name", value: info.issuer)
            }
            Section {
                LabeledContent("Serial Number", value: info.serialNumber.isEmpty ? "—" : info.serialNumber)
                LabeledContent("Not Valid Before", value: Self.dateString(info.notValidBefore))
                LabeledContent("Not Valid After", value: Self.dateString(info.notValidAfter))
            }
            Section("Public Key Info") {
                LabeledContent("Fingerprint (SHA-256)", value: info.fingerprint)
                    .font(.caption2.monospaced())
            }
        }
        .navigationTitle("Certificate information")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Desktop formats dates with `toLocaleString('en-US', {dateStyle: 'full', timeStyle: 'full'})`.
    private static func dateString(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.dateTime
            .year().month().day().hour().minute().second()
            .locale(Locale(identifier: "en-US")))
    }
}

#Preview {
    CertPromptSheet(prompt: CertificatePrompt(
        origin: URL(string: "https://self-signed.example")!,
        certificate: ComparableCertificate(data: "abc", issuerName: "CN=self-signed.example"),
        info: CertificateInfo(subject: "CN=self-signed.example", issuer: "CN=self-signed.example",
                              serialNumber: "01:AB", notValidBefore: Date(), notValidAfter: Date(),
                              fingerprint: "12:34:56"))
    ) { _, _ in }
}
