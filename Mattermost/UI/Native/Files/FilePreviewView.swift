// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 — `app/screens/pdf_viewer/`
// (native PDF rendering), `app/screens/code/` (plain text/code viewer), and
// `app/components/files/document_file.tsx` (the "no preview" branch).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §15; no
// upstream source copied.
//
// The one-file half of S18: what a non-image attachment opens into when the reader taps it.
//
// Three readers and one refusal, decided by `FileTypeMap`:
//   * `.pdf`   → `PDFKit`'s `PDFView` (a real parser; the page's own text layer, no scripts).
//   * `.text`  → decoded bytes in a `Text` view, capped at `FileTypeMap.textPreviewByteLimit`, with a
//                visible "showing the first N KB" note when it is cut. Never interpreted: a `.js` or
//                `.sh` file is shown as characters, not run.
//   * `.image` → the same downsampled bitmap the gallery draws (defensive: the row sends images to the
//                gallery, but a caller may open one here).
//   * `.unsupported` → a **safe refusenik screen**: icon, name, type, size, why, and Download. No
//                `WKWebView`, no `QuickLook`, no `UIDocumentInteractionController` — there is nowhere in
//                this path that could interpret an HTML, SVG or binary payload. That refusal is what
//                "opens a safe preview, never executes" means here, and it is asserted by a live test
//                (`MattermostUITests/T38AttachmentsUITests`).
//
// Before any reader is handed bytes, `PreviewFetchDecision` bounds the **allocation**: a text or PDF
// file whose own declared size is past `FileTypeMap.previewFetchByteLimit` is refused in place and
// offered for download instead. The 256 KB text cap was previously applied *after* the whole payload
// was in memory, which made a 100 MB log a 100 MB `Data` (T38-AV F5).

import SwiftUI
import PDFKit
import UIKit

/// The decoded content a preview shows. One case per reader, so the view cannot render a PDF as text.
enum AttachmentPreviewPayload {
    case pdf(PDFDocument)
    case text(text: String, truncated: Bool)
    case image(UIImage)
}

/// Bounded, non-interpreting text decoding (unit-tested separately from the view).
enum TextPreview {
    /// Read at most this many bytes. Equals `FileTypeMap.textPreviewByteLimit` so there is one number.
    static let byteLimit = FileTypeMap.textPreviewByteLimit

    /// Decode `data` as text. Returns the decoded string and whether bytes were dropped.
    ///
    /// UTF-8 first (the overwhelmingly common case), then ISO-8859-1 — which accepts *every* byte
    /// value, so a legacy export still reads instead of drawing mojibake. The empty answer is only
    /// reachable if both decoders refuse, which is not possible for a byte string; it exists so the
    /// caller has a defined value and the view can say "not text" rather than crash on an optional.
    static func decode(_ data: Data) -> (text: String, truncated: Bool) {
        let truncated = data.count > byteLimit
        let slice = truncated ? data.prefix(byteLimit) : data
        if let text = String(data: slice, encoding: .utf8) {
            return (text, truncated)
        }
        if let text = String(data: slice, encoding: .isoLatin1) {
            return (text, truncated)
        }
        return ("", truncated)
    }
}

/// What the in-place readers do with a file of a given declared size — decided **before** any bytes are
/// fetched, so a size the client will not hold never becomes an allocation.
///
/// The text and PDF readers need the whole payload (`PDFDocument(data:)`, `TextPreview.decode`), and
/// `metadata.files` already states the size, so the decision is free. Images are not gated here: the
/// gallery downloads the file and downsamples it during decode, which is the path the inline grid and
/// the gallery already bound by pixel count.
enum PreviewFetchDecision: Equatable {
    case fetch
    case tooLarge(limit: Int64)

    static func decide(kind: FilePreviewKind, byteCount: Int64) -> PreviewFetchDecision {
        switch kind {
        case .image, .unsupported:
            return .fetch
        case .pdf, .text:
            // An unknown size (0 from a payload that carried none) is not a refusal: the server's own
            // limit is the only bound left, and refusing would lose a readable file.
            guard byteCount > 0 else { return .fetch }
            return FileTypeMap.mayFetchWholeFile(byteCount: byteCount)
                ? .fetch
                : .tooLarge(limit: Int64(FileTypeMap.previewFetchByteLimit))
        }
    }
}

struct AttachmentPreviewView: View {
    let target: AttachmentPreviewTarget
    let imageStore: ChannelImageStore?
    var downloads: AttachmentDownloads?
    let onClose: () -> Void

    @State private var payload: AttachmentPreviewPayload?
    @State private var failure: String?
    @State private var sizeRefusal: Int64?
    @State private var shareItem: SharePayload?

    private var attachment: PostAttachment { target.attachment }
    private var kind: FilePreviewKind { attachment.previewKind }
    private var fetchDecision: PreviewFetchDecision {
        PreviewFetchDecision.decide(kind: kind, byteCount: attachment.sizeBytes)
    }
    private var downloadState: AttachmentDownloadState {
        downloads?.state(for: attachment.id) ?? .idle
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attachmentPreview")
        .task(id: attachment.id) { await load() }
        .sheet(item: $shareItem) { payload in
            ActivityView(items: [payload.url])
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("attachmentPreview.close")

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("attachmentPreview.title")
                Text([attachment.typeLabel, attachment.sizeLabel, downloadState.label]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("attachmentPreview.subtitle")
            }
            Spacer(minLength: 0)

            if !attachment.isBlocked {
                if fetchDecision == .fetch {
                    Button { share() } label: {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share file")
                    .accessibilityIdentifier("attachmentPreview.share")
                }

                Button { downloads?.download(attachment) } label: {
                    Image(systemName: downloadState == .done
                          ? "checkmark.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 17))
                }
                .buttonStyle(.plain)
                .disabled(downloadState.isActive)
                .accessibilityLabel("Save to Downloads")
                .accessibilityIdentifier("attachmentPreview.download")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if case .unsupported(let reason) = kind {
            unsupported(reason)
        } else if let sizeRefusal {
            tooLarge(limit: sizeRefusal)
        } else if let failure {
            failureState(failure)
        } else if let payload {
            switch payload {
            case .pdf(let document):
                PDFKitView(document: document)
                    .accessibilityIdentifier("attachmentPreview.pdf")
            case .text(let text, let truncated):
                textView(text, truncated: truncated)
            case .image(let image):
                ZoomableImageView(image: image)
                    .accessibilityIdentifier("attachmentPreview.image")
            }
        } else {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("attachmentPreview.loading")
        }
    }

    /// The refusal. Stated plainly, with the one action that is safe: take the bytes elsewhere.
    private func unsupported(_ reason: FilePreviewKind.UnsupportedReason) -> some View {
        VStack(spacing: 12) {
            Image(systemName: reason == .blocked ? "nosign" : "shield.lefthalf.filled")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(attachment.name)
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text([attachment.typeLabel, attachment.sizeLabel].filter { !$0.isEmpty }
                    .joined(separator: " · "))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(FileTypeMap.unsupportedReason(reason))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            if !attachment.isBlocked, downloads != nil {
                Button {
                    downloads?.download(attachment)
                } label: {
                    Label(downloadState == .done ? "Saved to Downloads" : "Download",
                          systemImage: downloadState == .done
                          ? "checkmark.circle.fill" : "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(downloadState.isActive || downloadState == .done)
                .accessibilityIdentifier("attachmentPreview.unsupported.download")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attachmentPreview.unsupported")
    }

    /// A file whose declared size is past `FileTypeMap.previewFetchByteLimit`. Stated plainly, with the
    /// one action that is both safe and bounded: the download path streams to disk and never holds the
    /// payload in memory, so a 300 MB log is still obtainable — it is just not *previewed* in place.
    private func tooLarge(limit: Int64) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(attachment.name)
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text([attachment.typeLabel, attachment.sizeLabel].filter { !$0.isEmpty }
                    .joined(separator: " · "))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("This file is larger than the "
                 + "\(AttachmentPreviewView.byteLabel(Int(limit))) this client will load into memory "
                 + "for a preview. Download it to open it in another app.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            if downloads != nil {
                Button {
                    downloads?.download(attachment)
                } label: {
                    Label(downloadState == .done ? "Saved to Downloads" : "Download",
                          systemImage: downloadState == .done
                          ? "checkmark.circle.fill" : "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(downloadState.isActive || downloadState == .done)
                .accessibilityIdentifier("attachmentPreview.tooLarge.download")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attachmentPreview.tooLarge")
    }

    private func textView(_ text: String, truncated: Bool) -> some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 6) {
                if text.isEmpty {
                    Text("These bytes are not text this client can show.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else {
                    Text(text)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if truncated {
                    Text("Showing the first \(AttachmentPreviewView.byteLabel(TextPreview.byteLimit)) "
                         + "of \(attachment.sizeLabel).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("attachmentPreview.text.truncated")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("attachmentPreview.text")
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                self.failure = nil
                Task { await load() }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("attachmentPreview.retry")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityIdentifier("attachmentPreview.error")
    }

    // MARK: Loading

    private func load() async {
        guard payload == nil, failure == nil, sizeRefusal == nil else { return }
        switch kind {
        case .unsupported:
            return
        case .image:
            guard let imageStore else { failure = "The image could not be loaded."; return }
            if let image = await imageStore.galleryImage(for: attachment) {
                payload = .image(image)
            } else {
                failure = "The image could not be loaded."
            }
        case .pdf, .text:
            // The size comes from the post's own `metadata.files`, so this refusal costs no bytes:
            // before this guard the readers fetched the whole payload and truncated *after* it was in
            // memory (a 100 MB log was a 100 MB `Data`).
            if case .tooLarge(let limit) = PreviewFetchDecision.decide(kind: kind,
                                                                      byteCount: attachment.sizeBytes) {
                sizeRefusal = limit
                return
            }
            guard let imageStore else { failure = "The file could not be loaded."; return }
            guard let data = await imageStore.originalData(for: attachment) else {
                failure = "The file could not be downloaded from the server."
                return
            }
            if case .pdf = kind {
                guard let document = PDFDocument(data: data) else {
                    failure = "This PDF could not be opened."
                    return
                }
                payload = .pdf(document)
            } else {
                let decoded = TextPreview.decode(data)
                payload = .text(text: decoded.text, truncated: decoded.truncated)
            }
        }
    }

    private func share() {
        guard let imageStore else { return }
        Task {
            guard let data = await imageStore.originalData(for: attachment) else {
                failure = "The file could not be loaded to share."
                return
            }
            guard let url = AttachmentShare.temporaryFile(named: attachment.name, data: data) else {
                failure = "The file could not be staged for sharing."
                return
            }
            shareItem = SharePayload(url: url)
        }
    }

    static func byteLabel(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// `PDFView` in SwiftUI. `autoScales` keeps a page legible without the reader having to pinch first;
/// `pageShadows`/`backgroundColor` are turned down so it reads as part of the sheet.
struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
