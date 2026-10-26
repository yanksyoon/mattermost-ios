import Foundation
import Combine
import WebKit
import UIKit

/// Native counterpart of the desktop `src/main/downloadsManager.ts`. Parity row:
/// `downloadsManager` -> `DownloadWorker` (`URLSessionDownloadTask` into the app
/// `Documents/Downloads` directory, `WKDownloadDelegate` for webview-initiated files,
/// persistent download journal, and a Share-to-Files export via `UIDocumentPicker`).
/// Status: native, Phase 2.
///
/// Two download entry points converge here so every byte the shell moves is journaled:
///
///  1. **Shell-initiated** — `download(url:)` starts a `URLSessionDownloadTask` on the
///     worker's own `URLSession` (so it can be the session download delegate and observe
///     `didFinishDownloadingTo` / `didWriteData`). Files land in `URL.downloadsDirectory`.
///  2. **Webview-initiated** — the worker's `DownloadFlow` *is* a `WKDownloadDelegate`: when a
///     download is produced for the embedded web app (attachments, <a download> files), its
///     `.delegate` is set to the flow, which decides the Downloads destination and journals the
///     finish/failure.
///
/// Security boundary: like the desktop download manager, this never exposes local filesystem
/// paths to page JS — a `WKDownloadDelegate` only ever receives a destination *we* choose, and
/// `Bridge`/`window.desktop` stays out of the Downloads directory.
///
/// Layering note: `DownloadWorker` itself is Combine's `ObservableObject` so it can be an app
/// `@StateObject` (mounted once, injected app-wide), while the actual protocol implementations
/// (`URLSessionDownloadDelegate` + `WKDownloadDelegate`) live on the nested `DownloadFlow`,
/// an `NSObject` — Combine's `ObservableObject` cannot itself satisfy an `NSObjectProtocol`.
@MainActor
final class DownloadWorker: ObservableObject {

    /// The persistent journal (newest-first) the DownloadsView binds to.
    let history: DownloadHistory

    /// The transfer engine: owns the download `URLSession` and the webview download delegate,
    /// and journals every move into `history`. `lazy` so it can capture `self` (its `owner`
    /// back-reference) only after this worker is fully initialised.
    lazy var flow: DownloadFlow = DownloadFlow(owner: self)

    init(history: DownloadHistory) {
        self.history = history
    }

    /// Begin downloading `url` into the app Downloads directory and journal it. Returns the
    /// in-flight record so callers can observe progress or cancel it by id.
    @discardableResult
    func download(url: URL) -> DownloadRecord {
        flow.startDownload(request: URLRequest(url: url),
                           suggestedFilename: url.lastPathComponent)
    }

    /// Begin downloading an **authenticated** request (T38: a Mattermost attachment) under a
    /// caller-chosen file name.
    ///
    /// Why a `URLRequest` and not a URL: a private file's bytes need the session's bearer token, and
    /// the token lives behind `AuthSession`/`APIClient` — the transfer engine must not learn how to
    /// authenticate any more than a page's JavaScript may. The caller builds the request through the
    /// one authenticated client; this method only transfers and journals it. `suggestedFilename` is
    /// required because a Mattermost file URL ends in the file's *id* (`/api/v4/files/abc123`), which
    /// is not a usable name on disk.
    @discardableResult
    func download(request: URLRequest, suggestedFilename: String) -> DownloadRecord {
        flow.startDownload(request: request, suggestedFilename: suggestedFilename)
    }

    /// Cancel an in-flight download; the task's completion flips the record to `.cancelled`.
    func cancel(id: UUID) {
        flow.cancel(id: id)
    }

    /// The session task transferring a record, so a test can prove the transfer is **running** and
    /// not merely journaled (`URLSessionTask.state`). Nil once it finished or was never started.
    func task(for id: UUID) -> URLSessionDownloadTask? {
        flow.tasksByRecord[id]
    }

    /// Re-issue a failed / cancelled / wait-to-retry download by its journal record.
    @discardableResult
    func retry(_ record: DownloadRecord) -> DownloadRecord? {
        flow.retry(record)
    }

    // MARK: Share / move into the Files app

    /// Build an export document-picker for a landed file, so the user can move/copy it out of
    /// the app Downloads directory into the Files app (desktop popout context-menu "Share" /
    /// "Open in Files"). `asCopy: false` (default) *moves* the original rather than duplicating
    /// it, per the UIKit recommendation; the picker reports the new location via
    /// `didPickDocuments(atURLs:)`. Returns nil when the record has no landed file to export.
    func exportPicker(for record: DownloadRecord, asCopy: Bool = false) -> UIDocumentPickerViewController? {
        guard record.state == .done, let target = record.targetURL else {
            Logger.debug("DownloadWorker", "no landed file to export for \(record.id)")
            return nil
        }
        let picker = UIDocumentPickerViewController(forExporting: [target], asCopy: asCopy)
        // Root the picker at Downloads so "the file we just downloaded" is the obvious starting
        // point, mirroring the desktop share sheet opening the downloads folder.
        picker.directoryURL = URL.downloadsDirectory
        picker.allowsMultipleSelection = false
        return picker
    }

    // MARK: Journal passthroughs

    /// Shortcut for `history.remove(id:)` used by the DownloadsView delete affordance.
    func remove(id: UUID) { history.remove(id: id) }
    /// Shortcut for clearing completed/cancelled/failed rows.
    func clearFinished() { history.clearFinished() }

    // MARK: Pure filename & destination helpers (unit-testable)

    /// Reduce an arbitrary suggested filename to a safe basename: trim surrounding whitespace
    /// and keep only the final path component, so a server-injected `../../x/y` collapses to
    /// `y` and can never escape the Downloads directory. Falls back to `download` when nothing
    /// usable remains.
    static func sanitizedFilename(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.contains("/") { name = Self.rawLastComponent(of: name, separator: "/") }
        if name.contains("\\") { name = Self.rawLastComponent(of: name, separator: "\\") }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "download" }
        return name
    }

    /// The final path component of `value` split on `separator` (a `SubSequence`, -> `String`).
    /// Empty when `value` has no component at all (e.g. `"////"`), so the caller's fallback applies.
    private static func rawLastComponent(of value: String, separator: String) -> String {
        value.split(separator: separator).last.map(String.init) ?? ""
    }

    /// The file names the journal says are taken: every record that already **landed**, minus the one
    /// currently landing. A record exists in the journal from the moment its task starts, so counting
    /// the landing record's own name would name every save `file (2).ext` (measured live before the
    /// repair: the first save of `t38-shot-01.png` landed as `t38-shot-01 (2).png`).
    static func occupiedNames(in records: [DownloadRecord], excluding id: UUID?) -> [String] {
        records
            .filter { $0.id != id && $0.state == .done }
            .compactMap { $0.filename }
    }

    /// Pick a non-colliding file name for `base` against the names already in `existing`:
    /// `report.pdf` -> `report (2).pdf`, `report (3).pdf`, … The first free name is returned
    /// (desktop download-dedup behaviour).
    static func uniqueFilename(_ base: String, existing: [String]) -> String {
        if !existing.contains(base) { return base }
        var stem = base
        var ext = ""
        if let dot = base.lastIndex(of: "."), dot > base.startIndex {
            stem = String(base[..<dot])
            if let last = base.split(separator: ".").last { ext = "." + String(last) }
        }
        var n = 2
        while true {
            let candidate = "\(stem) (\(n))\(ext)"
            if !existing.contains(candidate) { return candidate }
            n += 1
        }
    }

    /// The full `file://` URL a download named `suggestedFilename` should land under in
    /// `directory`, deduplicated against `existingNames`.
    static func resolveDestination(for suggestedFilename: String, in directory: URL,
                                   existingNames: [String]) -> URL {
        let name = Self.uniqueFilename(Self.sanitizedFilename(suggestedFilename),
                                       existing: existingNames)
        return directory.appendingPathComponent(name)
    }

    /// Move a finished download out of the session's temporary file and into `directory`.
    ///
    /// `URLSessionDownloadDelegate` hands over a location the session deletes the moment the delegate
    /// returns, so this is the step that makes "done" mean "on disk". It is a separate, injectable
    /// function so the landing rule (directory creation, de-duplication, replace-if-identical) is
    /// unit-testable without a network.
    static func install(downloadedFileAt location: URL,
                        filename: String,
                        in directory: URL = URL.downloadsDirectory,
                        existingNames: [String]) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = resolveDestination(for: filename, in: directory,
                                             existingNames: existingNames)
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: location, to: destination)
        return destination
    }

    // MARK: DownloadFlow — the NSObject that implements the Foundation/WebKit download protocols

    final class DownloadFlow: NSObject, URLSessionDownloadDelegate, WKDownloadDelegate {
        /// Back-reference to the observable worker that owns the journal and public API.
        weak var owner: DownloadWorker?

        /// A dedicated session with this flow as its download delegate, so shell-initiated
        /// `URLSessionDownloadTask`s report progress/completion without disturbing
        /// `URLSession.shared`. `lazy` because `URLSession(configuration:delegate:self)` uses
        /// `self` as the delegate and can only run after `super.init()`.
        ///
        /// `delegateQueue: .main` is not an optimisation: this flow is main-actor isolated (it is
        /// nested in a `@MainActor` owner and mutates the journal the Downloads screen draws), and
        /// `URLSession` otherwise invokes the delegate on a private background queue — which traps
        /// with "Incorrect actor executor assumption" and kills the app the moment a download starts
        /// (`signal kill`, measured the first time a save actually transferred:
        /// `docs/t38-build-note.md` §5). The work done here is a file move inside the container and a
        /// journal update, both cheap even for a large file.
        lazy var session: URLSession = URLSession(configuration: URLSessionConfiguration.default,
                                                  delegate: self,
                                                  delegateQueue: .main)
        /// Maps an in-flight session download task to its journal record id.
        var activeTasks = Dictionary<URLSessionDownloadTask, UUID>()
        /// Record id → the task transferring it. `activeTasks` answers "which record is this task?";
        /// this answers "is this record's transfer actually running?" — a `URLSessionTask` is born
        /// suspended, so a record whose task was created and never resumed is a row that sits at
        /// "0 B · Progressing" forever (measured: `docs/t38-build-note.md` §5).
        private(set) var tasksByRecord: [UUID: URLSessionDownloadTask] = [:]
        /// Maps an in-flight webview download to its journal record id.
        var activeDownloads = Dictionary<WKDownload, UUID>()

        init(owner: DownloadWorker) {
            self.owner = owner
        }

        // MARK: Shell-initiated downloads

        @discardableResult
        func startDownload(request: URLRequest, suggestedFilename: String) -> DownloadRecord {
            var record = DownloadRecord(
                filename: DownloadWorker.sanitizedFilename(suggestedFilename),
                source: request.url?.absoluteString ?? "")
            owner?.history.add(record)
            record = owner?.history.find(id: record.id) ?? record

            let task = session.downloadTask(with: request)
            activeTasks[task] = record.id
            tasksByRecord[record.id] = task
            Logger.info("DownloadWorker", "started download \(request.url?.absoluteString ?? "")")
            // A `URLSessionTask` is created **suspended**; without this the record sits at
            // "0 B · Progressing" forever and no delegate callback ever fires. Measured on the
            // simulator before the repair: the journal row existed, the Downloads screen drew it,
            // `receivedBytes` stayed 0 and nothing landed (`docs/t38-build-note.md` §5).
            task.resume()
            return record
        }

        func cancel(id: UUID) {
            guard owner?.history.find(id: id)?.state == .downloading else { return }
            for task in activeTasks.keys {
                if activeTasks[task] == id {
                    task.cancel()
                    break
                }
            }
        }

        @discardableResult
        func retry(_ record: DownloadRecord) -> DownloadRecord? {
            guard let source = URL(string: record.source) else {
                Logger.info("DownloadWorker", "no source to retry for \(record.filename)")
                return nil
            }
            var next = record
            next.state = .downloading
            next.receivedBytes = 0
            next.totalBytes = 0
            next.finishedAt = nil
            owner?.history.update(next)

            let request = URLRequest(url: source)
            let task = session.downloadTask(with: request)
            activeTasks[task] = next.id
            tasksByRecord[next.id] = task
            task.resume()
            return next
        }

        // MARK: URLSessionDownloadDelegate (shell-initiated task callbacks)

        func urlSession(_ session: URLSession, downloadTask task: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            guard let id = activeTasks.removeValue(forKey: task),
                  let record = owner?.history.find(id: id) else { return }
            tasksByRecord[id] = nil
            var next = record
            // T38: the download has to actually land. `location` is a temporary file the session
            // deletes as soon as this delegate returns, so a record that says `done` without moving
            // it would be a lie the Downloads screen repeats (and the row's "Saved to Downloads"
            // with it). The move is therefore part of the same step that sets `done`, and a failed
            // move is `.error`, never `.done`.
            do {
                let dest = try DownloadWorker.install(downloadedFileAt: location,
                                                      filename: record.filename,
                                                      existingNames: journalFileNames(excluding: record.id))
                next.destination = dest.absoluteString
                next.state = .done
                // `didWriteData` is not guaranteed even once for a small response, so a landed row
                // would otherwise read "0 B · Downloaded". The file on disk is the truth about how
                // many bytes landed.
                let landedBytes = (try? FileManager.default
                    .attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? nil
                if let landedBytes {
                    next.receivedBytes = landedBytes
                    next.totalBytes = max(next.totalBytes, landedBytes)
                }
                Logger.info("DownloadWorker", "finished \(record.filename) -> \(dest.path)")
            } catch {
                next.state = .error
                Logger.error("DownloadWorker",
                             "could not land \(record.filename): \(error.localizedDescription)")
            }
            next.finishedAt = Date()
            owner?.history.update(next)
        }

        func urlSession(_ session: URLSession, downloadTask task: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard let id = activeTasks[task], let record = owner?.history.find(id: id) else { return }
            var next = record
            next.receivedBytes = totalBytesWritten
            next.totalBytes = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : record.totalBytes
            owner?.history.update(next)
        }

        // MARK: WKDownloadDelegate (webview-initiated downloads)

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            // The downloadable file is written where we decide — never under the webview's
            // control. Deduplicate against the names already in the journal so a re-download of
            // the same filename collides into "file (2).ext" instead of silently overwriting.
            let dest = DownloadWorker.resolveDestination(
                for: suggestedFilename,
                in: URL.downloadsDirectory,
                existingNames: journalFileNames())
            var record = DownloadRecord(
                filename: DownloadWorker.sanitizedFilename(dest.lastPathComponent),
                source: "",
                destination: dest.absoluteString)
            owner?.history.add(record)
            activeDownloads[download] = record.id
            completionHandler(dest)
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let id = activeDownloads.removeValue(forKey: download),
                  let record = owner?.history.find(id: id) else { return }
            var next = record
            next.state = .done
            next.finishedAt = Date()
            owner?.history.update(next)
            Logger.info("DownloadWorker", "webview download finished \(record.filename)")
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            guard let id = activeDownloads.removeValue(forKey: download),
                  let record = owner?.history.find(id: id) else { return }
            var next = record
            next.state = resumeData == nil ? .error : .waitToRetry
            next.finishedAt = Date()
            owner?.history.update(next)
            Logger.error("DownloadWorker", "download failed \(record.filename): \(error.localizedDescription)")
        }

        // MARK: Local helpers

        /// Where a finished task's file should land, deduplicated against the journal so a
        /// second download of the same name doesn't overwrite the first.
        private func landing(for record: DownloadRecord) -> URL {
            DownloadWorker.resolveDestination(for: record.filename, in: URL.downloadsDirectory,
                                             existingNames: journalFileNames(excluding: record.id))
        }

        /// File names already in the journal *and* on disk (used to keep downloads from overwriting
        /// each other). The disk half matters because the journal is capped (`maxRecords`): dropping an
        /// old record must not make its file invisible to de-duplication.
        ///
        /// `excluding` is the record that is landing **right now**: it is already in the journal when
        /// its bytes arrive, so counting its own name would save every download as `file (2).ext`
        /// (measured live: `t38-shot-01 (2).png` for the first save of that file).
        private func journalFileNames(excluding recordID: UUID? = nil) -> [String] {
            let journal = DownloadWorker.occupiedNames(in: owner?.history.records ?? [],
                                                       excluding: recordID)
            let onDisk = (try? FileManager.default
                .contentsOfDirectory(atPath: URL.downloadsDirectory.path)) ?? []
            return journal + onDisk
        }
    }
}