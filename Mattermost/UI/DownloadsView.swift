import SwiftUI
import UIKit

/// Native port of the desktop renderer `DownloadsDropdown` (parity row design §4d:
/// `DownloadsDropdown/*` -> `DownloadsView` List + `DownloadRowView` with `ProgressView`).
///
/// Desktop structure mirrored here: a header bar ("Downloads" + "Clear All"), a divider, and
/// a list of file rows. Each row is the port of `DownloadsDropdownItemFile`:
/// thumbnail -> SF Symbol by file type, filename, `FileSizeAndStatus` line, a three-dot
/// action menu, and a `ProgressView` progress bar while the download is `progressing`.
///
/// Data comes from the native `DownloadWorker`/`DownloadHistory` journal (T7) — the
/// replacement for the desktop's `downloadsManager` + JSON file. The desktop's App-update row
/// has no iOS analog (App Store owns updates), so every row is a file row.
///
/// Row actions map desktop's popout context menu onto iOS:
///   - Open / "Open in Files" -> `UIDocumentPicker` export (moves the file out of the sandbox)
///   - Share -> `UIActivityViewController`
///   - Retry -> `DownloadWorker.retry(record)` (desktop `retryDownload`)
///   - Cancel -> `DownloadWorker.cancel(id:)`
///   - Delete -> `DownloadHistory.remove(id:)`
struct DownloadsView: View {
    @EnvironmentObject var downloadWorker: DownloadWorker
    @Environment(\.dismiss) private var dismiss

    /// Record currently being exported via the document picker (presented as a sheet).
    @State private var exportingRecord: DownloadRecord?
    /// Record currently being shared via `UIActivityViewController`.
    @State private var sharingRecord: DownloadRecord?

    var body: some View {
        NavigationStack {
            Group {
                if downloadWorker.history.records.isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Files you download appear here.")
                    )
                } else {
                    List {
                        ForEach(downloadWorker.history.records) { record in
                            DownloadRowView(
                                record: record,
                                worker: downloadWorker,
                                onExport: { exportingRecord = record },
                                onShare: { sharingRecord = record }
                            )
                            .accessibilityIdentifier("downloadRow-\(record.filename)")
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Clear All") {
                        downloadWorker.clearFinished()
                    }
                    .disabled(!hasFinishedRows)
                }
            }
            // Open in Files (export picker), sharing, and the row context menu all present
            // native modals (desktop popout context menu / `openDownload` + "Show in folder").
            .sheet(item: $exportingRecord) { record in
                DocumentPickerSheet(record: record, worker: downloadWorker)
            }
            .sheet(item: $sharingRecord) { record in
                ShareSheet(record: record)
            }
        }
        .accessibilityIdentifier("downloadsView")
    }

    /// Desktop disables "Clear All" when nothing can be cleared (its guard: only-rows-are-
    /// update). We clear *finished* rows (keeping in-flight), so the button is disabled when
    /// there is nothing finished to clear.
    private var hasFinishedRows: Bool {
        downloadWorker.history.records.contains { $0.state != .downloading }
    }
}

/// One file row — port of desktop `DownloadsDropdownItemFile`. Lays out an SF-Symbol
/// thumbnail (port of `Thumbnail` + `getIconClassName`), the filename, the
/// `FileSizeAndStatus` line, a `ProgressView` while progressing, and a `Menu` as the
/// three-dot context affordance.
struct DownloadRowView: View {
    let record: DownloadRecord
    @ObservedObject var worker: DownloadWorker
    /// Presented by the parent (the "Open in Files" document picker).
    let onExport: () -> Void
    /// Presented by the parent (the share sheet).
    let onShare: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: DownloadFormatting.iconName(for: record.filename))
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(record.filename)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(DownloadFormatting.fileSizeAndStatus(record))
                        .font(.caption)
                        .foregroundStyle(record.state == .done ? Color.secondary : Color.orange)
                }
                if record.state == .downloading {
                    ProgressView(value: DownloadFormatting.progress(record), total: 1)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("downloadProgress-\(record.filename)")
                }
            }

            Spacer()

            Menu {
                switch record.state {
                case .done:
                    Button(action: onExport) {
                        Label("Open in Files", systemImage: "folder")
                    }
                    Button(action: onShare) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                case .downloading:
                    Button(role: .destructive) {
                        worker.cancel(id: record.id)
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                case .waitToRetry, .error, .cancelled:
                    Button {
                        _ = worker.retry(record)
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                }
                if record.state != .downloading {
                    Button(role: .destructive) {
                        worker.remove(id: record.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Actions for \(record.filename)")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Formatting helpers (ports of desktop renderer/utils.ts + pretty-bytes)

/// Port of the desktop `renderer/utils.ts` download formatting + the `pretty-bytes` package
/// behavior it uses. Pure and unit-tested (`DownloadFormattingTests`).
enum DownloadFormatting {

    /// SF Symbol per filename (port of `Thumbnail` + `getIconClassName` icon selection).
    static func iconName(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff": return "photo"
        case "mp4", "mov", "avi", "mkv", "webm", "m4v": return "film"
        case "mp3", "wav", "m4a", "aac", "flac", "ogg": return "music.note"
        case "zip", "rar", "7z", "tar", "gz", "bz2": return "archivebox"
        case "doc", "docx", "pages": return "doc.text"
        case "xls", "xlsx", "numbers": return "tablecells"
        case "ppt", "pptx", "key": return "chart.bar.doc.horizontal"
        case "txt", "md", "rtf", "csv", "log": return "doc.plaintext"
        default: return "doc"
        }
    }

    /// `pretty-bytes` (npm) behavior the desktop uses for `totalBytes` — SI units (1000-based,
    /// like `pretty-bytes` defaults), `0 B` for zero, at most two significant decimals above B
    /// with trailing zeros trimmed (`1.50 MB` -> `1.5 MB`, `1.00 MB` -> `1 MB`).
    static func prettyBytes(_ byteCount: Int64) -> String {
        let units = ["B", "kB", "MB", "GB", "TB"]
        let value = Double(byteCount)
        // pretty-bytes prints negative values with sign then absolute magnitude.
        let sign = value < 0 ? "-" : ""
        let magnitude = abs(value)
        guard magnitude >= 1000 else { return "\(byteCount) B" }
        var exp = 0
        var scaled = magnitude
        while scaled >= 1000 && exp < units.count - 1 {
            scaled /= 1000
            exp += 1
        }
        // Two significant decimals after the point, trailing zeros trimmed.
        let formatted = String(format: "%.2f", scaled)
        var trimmed = formatted
        if formatted.contains(".") {
            trimmed = formatted.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            if trimmed.hasSuffix(".") { trimmed.removeLast() }
        }
        return "\(sign)\(trimmed) \(units[exp])"
    }

    /// Port of desktop `getFileSizeOrBytesProgress`: "12.3 MB" for a terminal item,
    /// "4.2 MB / 10 MB" style progressive bytes while downloading.
    static func fileSizeOrBytesProgress(_ record: DownloadRecord) -> String {
        let total = prettyBytes(record.totalBytes)
        if record.state == .downloading && record.receivedBytes > 0 && record.totalBytes > 0 {
            let received = prettyBytes(record.receivedBytes)
            return "\(received) of \(total)"
        }
        return total
    }

    /// Port of desktop `getDownloadingFileStatus`: `completed` -> "Downloaded",
    /// `deleted` -> "Deleted", everything else -> "Cancelled". Our states map:
    /// done -> Downloaded, cancelled -> Cancelled, error/waitToRetry -> Cancelled
    /// (desktop also shows "Cancelled" for its terminal interrupted states).
    static func fileStatus(_ record: DownloadRecord) -> String {
        switch record.state {
        case .done: return "Downloaded"
        case .downloading: return "Progressing"
        case .cancelled, .error, .waitToRetry: return "Cancelled"
        }
    }

    /// Combined `FileSizeAndStatus` line: "12.3 MB • Downloaded" (terminal) or
    /// "4.2 MB of 10 MB • Progressing" (in-flight, desktop shows ETA — we omit the ETA clock
    /// since the desktop's `prettyETA` math needs the item's addedAt timestamp and bandwidth
    /// estimate; the state label is the stable surface).
    static func fileSizeAndStatus(_ record: DownloadRecord) -> String {
        return "\(fileSizeOrBytesProgress(record)) • \(fileStatus(record))"
    }

    /// Download progress in 0...1 (desktop `item.progress` is 0-100; ours is fractional).
    static func progress(_ record: DownloadRecord) -> Double {
        guard record.totalBytes > 0 else { return 0 }
        return min(max(Double(record.receivedBytes) / Double(record.totalBytes), 0), 1)
    }
}

// MARK: - Sheet wrappers (UIKit bridging for Open-in-Files / Share)

/// Sheet wrapper over `DownloadWorker.exportPicker` (the `UIDocumentPickerViewController`).
struct DocumentPickerSheet: UIViewControllerRepresentable {
    let record: DownloadRecord
    @ObservedObject var worker: DownloadWorker
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        guard let picker = worker.exportPicker(for: record, asCopy: false) else {
            // Nothing landed (e.g. state changed underneath us); dismiss the sheet.
            DispatchQueue.main.async { dismiss() }
            return UIDocumentPickerViewController(forExporting: [URL(fileURLWithPath: "/")])
        }
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}

/// Sheet wrapper over `UIActivityViewController` for sharing a landed file.
struct ShareSheet: UIViewControllerRepresentable {
    let record: DownloadRecord
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let url = record.targetURL ?? URL(fileURLWithPath: "/")
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // Collapse the sheet when the share UI finishes.
        controller.completionWithItemsHandler = { _, _, _, _ in
            dismiss()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    DownloadsView()
        .environmentObject(DownloadWorker(history: DownloadHistory()))
}
