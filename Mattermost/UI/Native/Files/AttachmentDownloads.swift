// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 — `app/actions/remote/file.ts`
// (`downloadFile` → the platform downloader), `app/components/files/file.tsx` (the row's
// download/save affordance and its progress). The transfer itself is **not** reimplemented here: it is
// the shell's one `DownloadWorker` (parity row `downloadsManager` → `DownloadWorker`, T7), so a file
// saved from a post is the same journal row the Downloads screen has always shown.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §15.
//
// Why a coordinator and not the view: the row needs a *stable* answer to "is this file saved?" across
// a scroll, a channel switch and a re-appearance, and the answer lives in `DownloadHistory` (which
// survives a relaunch). One instance per server sits in `ChannelPaneCoordinator`, so two panes cannot
// start two downloads of the same file and a returned row reads the state from the same place the
// Downloads screen does.

import Foundation
import Combine
import UIKit
import SwiftUI

@MainActor
final class AttachmentDownloads: ObservableObject {

    /// fileID → the journal record this coordinator created for it.
    private var recordIDs: [String: UUID] = [:]
    /// fileID → what the row's second line says. Only files this coordinator started appear here; a
    /// download started from the webview is the Downloads screen's business, not a row's.
    @Published private(set) var states: [String: AttachmentDownloadState] = [:]

    private let worker: DownloadWorker
    private let service: ChannelServing
    private var cancellables = Set<AnyCancellable>()

    init(worker: DownloadWorker, service: ChannelServing) {
        self.worker = worker
        self.service = service
        // The journal is the source of truth for progress and completion (`DownloadWorker` writes it
        // from the URLSession delegate), so the row follows it rather than keeping a parallel state
        // machine that could disagree with the Downloads screen.
        worker.history.$records
            .sink { [weak self] records in self?.apply(records) }
            .store(in: &cancellables)
    }

    func state(for fileID: String) -> AttachmentDownloadState {
        states[fileID] ?? .idle
    }

    /// The journal row for a file this coordinator downloaded, once it has landed.
    func record(for fileID: String) -> DownloadRecord? {
        guard let id = recordIDs[fileID] else { return nil }
        return worker.history.find(id: id)
    }

    /// Start the download, or report why it could not start.
    ///
    /// Re-issuing is allowed after a failure: the row's Retry goes through this method, which builds a
    /// **fresh** authenticated request. (The Downloads screen's own Retry re-sends the stored source
    /// URL without a bearer token, so it cannot recover an attachment on its own — stated as a limit in
    /// the build note, because fixing it would mean persisting a credential next to a journal entry.)
    @discardableResult
    func download(_ attachment: PostAttachment) -> DownloadRecord? {
        if attachment.isBlocked {
            states[attachment.id] = .failed("the server blocked this file")
            return nil
        }
        switch state(for: attachment.id) {
        case .downloading: return record(for: attachment.id)
        case .done: return record(for: attachment.id)   // already on disk; do not fetch twice
        case .idle, .failed: break
        }
        do {
            let request = try service.fileDownloadRequest(fileID: attachment.id)
            let record = worker.download(request: request, suggestedFilename: attachment.name)
            recordIDs[attachment.id] = record.id
            states[attachment.id] = .downloading(fraction: nil)
            return record
        } catch {
            states[attachment.id] = .failed(Self.message(for: error))
            return nil
        }
    }

    /// Forget a file's journal binding (a re-upload under the same id, or a row whose download was
    /// deleted from the Downloads screen): the row falls back to "Download".
    func forget(fileID: String) {
        recordIDs[fileID] = nil
        states[fileID] = .idle
    }

    private func apply(_ records: [DownloadRecord]) {
        for (fileID, recordID) in recordIDs {
            guard let record = records.first(where: { $0.id == recordID }) else {
                states[fileID] = .idle
                continue
            }
            states[fileID] = AttachmentDownloadState.from(record.state,
                                                          received: record.receivedBytes,
                                                          total: record.totalBytes)
        }
    }

    private static func message(for error: Error) -> String {
        MMErrorCopy.message(for: error,
                            offline: "you are offline",
                            timeout: "the server did not answer",
                            unauthorized: "your session expired",
                            forbidden: "you may not download this file",
                            notFound: "the file is no longer on the server",
                            rateLimited: "too many requests — try again shortly",
                            fallback: error.localizedDescription)
    }
}

// MARK: - Sharing

/// Turning bytes into something another app can be handed.
///
/// `UIActivityViewController` given a `UIImage` shares an image, not a file — and given `Data` shares
/// nothing useful at all. So a share writes the bytes to a temporary file first, under the *same*
/// sanitised name the download path uses (`DownloadWorker.sanitizedFilename`), so a hostile file name
/// cannot escape the temporary directory.
enum AttachmentShare {

    @MainActor
    static func temporaryFile(named name: String, data: Data) -> URL? {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("attachment-share", isDirectory: true)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(DownloadWorker.sanitizedFilename(name))
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            Logger.error("AttachmentShare", "could not stage \(name): \(error.localizedDescription)")
            return nil
        }
    }
}

/// `UIActivityViewController` as a SwiftUI sheet (the share half of "share/save").
///
/// The item is a file URL, never raw bytes: a URL gives the receiving app a real document with the
/// right name and extension, which is what "save to Files" needs.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onComplete?() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
