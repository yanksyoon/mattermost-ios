// S18 / T53 — video and audio playback for an attachment.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 —
// `app/components/files/video_file.tsx` (an inline video control over the file URL),
// `app/components/files/audio_file.tsx` (a compact row with a progress bar),
// `app/screens/gallery/` (full-screen playback). Licence: Apache-2.0 — behaviour ported with
// attribution per docs/THIRD_PARTY_NOTICES.md §15; no upstream source copied.
//
// **The transport decision.** `GET /api/v4/files/{id}` needs the vault's bearer token, and an
// `AVPlayer` given a URL cannot send one. Putting the token in the URL is forbidden: it lands in
// logs, in crash reports and in AVFoundation's own diagnostics. Two paths were measured on the
// live fixture (`scripts/t53_media_seed.py`, iPhone 16 Pro / iOS 18.3):
//
//   A. `AVURLAsset(url:options:[AVURLAssetHTTPHeaderFieldsKey: ["Authorization": "Bearer …"]])` —
//      `isPlayable=true`, `duration=8.0 s`, played past 4 s (the measurement's own cap).
//   B. download through the client's authenticated request into the app's cache, then play the
//      local file — also played past 4 s, with no credential anywhere near AVFoundation.
//
// This client ships **B**. The numbers are in `docs/t53-build-note.md` §2. A is rejected on reasons
// the measurement cannot settle by itself: the header key is undocumented (it can vanish between
// OS releases), it hands the credential to a framework that owns its own logging, and its loader
// knows nothing about this app's `CertTrust` — with T28's self-signed server the loader is expected
// to refuse, though that case was not exercised here.
//
// Consequences that shape the rest of the file:
//  * staging is bounded **before** any bytes move (`PreviewFetchDecision`: the same
//    `FileTypeMap.previewFetchByteLimit` the PDF/text readers use, checked against the post's own
//    `metadata.files` size), and is bounded again while it runs (the download delegate cancels past
//    the limit) — a 300 MB video is refused, not downloaded;
//  * the file is written to disk by `URLSessionDownloadTask`, so the payload is never one `Data`;
//  * playback reads the local file, which is what gives PiP/full-screen/scrubbing for free from AVKit;
//  * the cache is small and self-pruning (`stagedLimit`/`stagedByteLimit`), and `clear()` empties it
//    on sign-out.

import Foundation
import AVFoundation
import UIKit
import Combine

// MARK: - Presentation-only helpers (pure, unit-tested)

/// Time strings and progress fractions for the two players. Pure so a 90-minute file's label and a
/// one-second file's progress are testable without a player.
enum MediaTime {
    /// "0:08", "4:05", "1:02:03". A negative or non-finite value is "0:00" — a player that has not
    /// loaded yet has no position, and it must not draw "-0:00" or "nan".
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// How far through the file we are, 0...1. A zero/unknown duration is 0, never a division by zero.
    static func fraction(current: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0, current.isFinite else { return 0 }
        return min(1, max(0, current / duration))
    }

    /// The VoiceOver value for a playback position: "2 of 8 seconds" — one integer a UI test can read
    /// without parsing a clock face, and a sentence a reader can follow.
    static func spokenPosition(current: Double, duration: Double) -> String {
        let position = Int(max(0, current.isFinite ? current : 0).rounded(.down))
        let total = Int(max(0, duration.isFinite ? duration : 0).rounded())
        return "\(position) of \(total) seconds"
    }
}

/// Why staging failed. `.tooLarge` carries the same limit the refusal screen states, so the two
/// copies ("too large" before staging and the sheet's refusal) cannot disagree.
enum MediaStageError: Error, Equatable {
    case blocked
    case tooLarge(limit: Int64)
    case cancelled
    case unavailable(String)

    /// The one-line explanation the player shows. Never includes a URL or a credential.
    var message: String {
        switch self {
        case .blocked: return "The server blocked this file."
        case .tooLarge(let limit):
            let size = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
            return "This file is larger than the \(size) this client will stage for playback."
        case .cancelled: return "Playback was stopped."
        case .unavailable(let reason): return reason
        }
    }
}

// MARK: - Staging protocol

/// The seam between the player and the transport, so the controller can be tested without a socket.
protocol MediaFileStaging: AnyObject {
    /// The local file for `attachment`, downloading it first when it is not already staged.
    func stagedFile(for attachment: PostAttachment,
                    request: URLRequest) async -> Result<URL, MediaStageError>
    /// Delete every staged file (sign-out, server switch).
    func clear()
}

// MARK: - The cache

/// Staged media files, on disk, bounded and self-pruning.
///
/// One instance per server (the coordinator owns it), because the same file can appear again in
/// another channel and staging it twice would be a second download of the same bytes.
///
/// Threading: the class is not actor-isolated — `URLSessionDelegate` callbacks arrive on a session
/// queue — so the in-flight table is guarded by a lock and the continuations are resumed outside it.
/// The public async API may be called from the main actor; nothing here touches UIKit.
final class MediaFileCache: NSObject, MediaFileStaging, @unchecked Sendable {

    /// How many staged files are kept (oldest by modification date is evicted first).
    static let stagedLimit = 4
    /// …and how many bytes of them. A 32 MB playback bound makes 4 files fit in this comfortably.
    static let stagedByteLimit = 96 * 1024 * 1024

    /// `Caches/media-playback` — never the Documents directory: a staged file is a cache, not a save.
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("media-playback", isDirectory: true)
    }

    private struct Entry {
        let fileID: String
        let destination: URL
        /// The in-progress name. A completed file is only ever visible under `destination`, so
        /// `existingFile` cannot hand a half-written payload to AVFoundation.
        let temporary: URL
        let limit: Int64
        let task: URLSessionDownloadTask
        var exceeded: Bool
        let continuation: CheckedContinuation<Result<URL, MediaStageError>, Never>
    }

    private let directory: URL
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    /// taskIdentifier → the wait it belongs to.
    private var entries: [Int: Entry] = [:]
    /// fileID → live task identifiers (a retry may overlap a cancelled attempt).
    private var tasksByFile: [String: [Int]] = [:]

    private lazy var session: URLSession = {
        URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(directory: URL = MediaFileCache.defaultDirectory(),
         configuration: URLSessionConfiguration = .default) {
        self.directory = directory
        self.configuration = configuration
        super.init()
    }

    // MARK: Staging

    func stagedFile(for attachment: PostAttachment,
                    request: URLRequest) async -> Result<URL, MediaStageError> {
        guard !attachment.isBlocked else { return .failure(.blocked) }
        // The declared size is the post's own metadata, so this refusal costs no bytes: a 300 MB
        // video is refused before a 300 MB (or even 300 KB) transfer starts.
        if attachment.sizeBytes > 0,
           !FileTypeMap.mayFetchWholeFile(byteCount: attachment.sizeBytes) {
            return .failure(.tooLarge(limit: Int64(FileTypeMap.previewFetchByteLimit)))
        }
        if let staged = existingFile(fileID: attachment.id) { return .success(staged) }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(.unavailable("The playback cache could not be created."))
        }

        let destination = directory.appendingPathComponent(Self.filename(for: attachment))
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).part")
        let limit = Int64(FileTypeMap.previewFetchByteLimit)
        let task = session.downloadTask(with: request)
        let identifier = task.taskIdentifier

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                entries[identifier] = Entry(fileID: attachment.id,
                                            destination: destination,
                                            temporary: temporary,
                                            limit: limit,
                                            task: task,
                                            exceeded: false,
                                            continuation: continuation)
                tasksByFile[attachment.id, default: []].append(identifier)
                lock.unlock()
                task.resume()
            }
        } onCancel: { [weak self] in
            self?.cancel(fileID: attachment.id)
        }

        // The cancellation may have arrived before the entry existed; in that case the handler above
        // found no task. This second look closes that window.
        if Task.isCancelled { cancel(fileID: attachment.id) }
        if case .success = result { trim() }
        return result
    }

    /// Cancel every live staging task for one file — the row left the screen, or the sheet closed.
    func cancel(fileID: String) {
        lock.lock()
        let identifiers = tasksByFile[fileID] ?? []
        let tasks = identifiers.compactMap { identifier -> URLSessionDownloadTask? in
            entries[identifier]?.task
        }
        lock.unlock()
        for task in tasks { task.cancel() }
    }

    /// Delete every staged file. Called on sign-out and on a server switch.
    func clear() {
        lock.lock()
        let identifiers = entries.keys
        let tasks = identifiers.compactMap { entries[$0]?.task }
        lock.unlock()
        for task in tasks { task.cancel() }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Diagnostics (tests, and the build note's numbers)

    var stagedFileCount: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { !$0.hasPrefix(".") && !$0.hasSuffix(".part") }.count ?? 0
    }

    static func stagedBytes(at directory: URL) -> Int64 {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.reduce(Int64(0)) { total, name in
            let path = directory.appendingPathComponent(name).path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return total + Int64((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    // MARK: Files

    private func existingFile(fileID: String) -> URL? {
        guard let name = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .first(where: { $0.hasPrefix(fileID + "-") || $0.hasPrefix(fileID + ".") }) else {
            return nil
        }
        let url = directory.appendingPathComponent(name)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        guard (size?.int64Value ?? 0) > 0 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    /// `<fileID>-<sanitised name>`: the id makes a stale same-named upload a different cache entry,
    /// and the sanitised name keeps the extension AVFoundation uses to pick a demuxer.
    static func filename(for attachment: PostAttachment) -> String {
        let base = DownloadWorker.sanitizedFilename(attachment.name)
        return base.isEmpty ? attachment.id : "\(attachment.id)-\(base)"
    }

    /// Keep the newest `stagedLimit` files and stay under `stagedByteLimit`. Oldest by modification
    /// date goes first so a just-played file is the last thing a reader loses.
    private func trim() {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        let files = names.filter { !$0.hasPrefix(".") && !$0.hasSuffix(".part") }
            .compactMap { name -> (URL, Date, Int64)? in
                let url = directory.appendingPathComponent(name)
                let attributes = try? manager.attributesOfItem(atPath: url.path)
                let date = attributes?[.modificationDate] as? Date ?? .distantPast
                let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                return (url, date, size)
            }
            .sorted { $0.1 < $1.1 }
        var total = files.reduce(Int64(0)) { total, file in total + file.2 }
        var remaining = files
        while remaining.count > Self.stagedLimit || total > Int64(Self.stagedByteLimit) {
            guard let oldest = remaining.first else { break }
            try? manager.removeItem(at: oldest.0)
            total -= oldest.2
            remaining.removeFirst()
        }
    }
}

// MARK: - URLSession delegate

extension MediaFileCache: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        lock.lock()
        guard var entry = entries[downloadTask.taskIdentifier] else {
            lock.unlock()
            return
        }
        let overLimit = totalBytesWritten > entry.limit
            || (totalBytesExpectedToWrite > 0 && totalBytesExpectedToWrite > entry.limit)
        if overLimit { entry.exceeded = true }
        entries[downloadTask.taskIdentifier] = entry
        lock.unlock()
        if overLimit { downloadTask.cancel() }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        lock.lock()
        guard let entry = entries[downloadTask.taskIdentifier] else {
            lock.unlock()
            return
        }
        lock.unlock()

        if entry.exceeded {
            try? FileManager.default.removeItem(at: location)
            finish(taskIdentifier: downloadTask.taskIdentifier,
                   result: .failure(.tooLarge(limit: entry.limit)))
            return
        }
        do {
            // Move through a `.part` name so a half-written file is never picked up by
            // `existingFile` — the rename is the "this file is complete" signal.
            try? FileManager.default.removeItem(at: entry.temporary)
            try FileManager.default.moveItem(at: location, to: entry.temporary)
            try? FileManager.default.removeItem(at: entry.destination)
            try FileManager.default.moveItem(at: entry.temporary, to: entry.destination)
            let size = ((try? FileManager.default.attributesOfItem(atPath: entry.destination.path))?[.size]
                        as? NSNumber)?.int64Value ?? 0
            if entry.limit > 0, size > entry.limit {
                try? FileManager.default.removeItem(at: entry.destination)
                finish(taskIdentifier: downloadTask.taskIdentifier,
                       result: .failure(.tooLarge(limit: entry.limit)))
            } else {
                finish(taskIdentifier: downloadTask.taskIdentifier, result: .success(entry.destination))
            }
        } catch {
            try? FileManager.default.removeItem(at: entry.temporary)
            finish(taskIdentifier: downloadTask.taskIdentifier,
                   result: .failure(.unavailable("The file could not be saved for playback.")))
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error else {
            // `didFinishDownloadingTo` already answered. A completion with no download callback and
            // no error is a transport that gave us nothing; report it rather than hang.
            finish(taskIdentifier: task.taskIdentifier,
                   result: .failure(.unavailable("The server returned no file.")))
            return
        }
        lock.lock()
        let exceeded = entries[task.taskIdentifier]?.exceeded ?? false
        let limit = entries[task.taskIdentifier]?.limit ?? Int64(FileTypeMap.previewFetchByteLimit)
        lock.unlock()
        if exceeded {
            finish(taskIdentifier: task.taskIdentifier, result: .failure(.tooLarge(limit: limit)))
        } else if (error as? URLError)?.code == .cancelled {
            finish(taskIdentifier: task.taskIdentifier, result: .failure(.cancelled))
        } else {
            finish(taskIdentifier: task.taskIdentifier,
                   result: .failure(.unavailable("The file could not be downloaded for playback.")))
        }
    }

    /// Resume exactly once, forget the entry, and drop the file id from the live list.
    private func finish(taskIdentifier: Int, result: Result<URL, MediaStageError>) {
        lock.lock()
        guard let entry = entries[taskIdentifier] else {
            lock.unlock()
            return
        }
        entries[taskIdentifier] = nil
        if var ids = tasksByFile[entry.fileID] {
            ids.removeAll { $0 == taskIdentifier }
            tasksByFile[entry.fileID] = ids.isEmpty ? nil : ids
        }
        lock.unlock()
        entry.continuation.resume(returning: result)
    }
}

// MARK: - Engine (the slice of AVFoundation the state machine needs)

/// The part of `AVPlayer` the controller drives and reads.
///
/// Extracted so the controller's lifecycle (one player at a time, no autoplay, stop on dismiss,
/// release on background) is testable without a media file, a simulator clock or a socket. The
/// production engine is `AVMediaEngine`.
@MainActor
protocol MediaPlaybackEngine: AnyObject {
    var currentTime: Double { get }
    var duration: Double { get }
    var isPlaying: Bool { get }
    /// The player the AVKit surface draws, if this engine has one.
    var player: AVPlayer? { get }
    func play()
    func pause()
    func seek(to seconds: Double)
    /// Stop and drop the item. After this the engine must not be used again.
    func release()
}

/// AVFoundation playing a **local** file.
///
/// The URL is the app's own cache (see `MediaFileCache`), never the server: no bearer token is ever
/// handed to AVFoundation, in a URL or a header. `AVPlayerItem(url:)` streams from disk, so the file
/// is never resident as one allocation; the decoded buffers AVFoundation keeps are its own bounded
/// window, not the file.
@MainActor
final class AVMediaEngine: MediaPlaybackEngine {
    private let asset: AVURLAsset
    private let item: AVPlayerItem
    private let avPlayer: AVPlayer

    private init(asset: AVURLAsset, duration: Double) {
        self.asset = asset
        self.item = AVPlayerItem(asset: asset)
        self.avPlayer = AVPlayer(playerItem: item)
        avPlayer.actionAtItemEnd = .pause
        self.duration = duration
    }

    /// Load the asset's own duration **before** playback so the scrubber has a real range from the
    /// first frame instead of growing from 0. A local file answers immediately.
    static func make(url: URL) async -> AVMediaEngine? {
        let asset = AVURLAsset(url: url)
        do {
            let seconds = try await asset.load(.duration).seconds
            return AVMediaEngine(asset: asset, duration: seconds.isFinite && seconds > 0 ? seconds : 0)
        } catch {
            Logger.error("MediaPlayback", "could not open the staged file: \(error.localizedDescription)")
            return nil
        }
    }

    private(set) var duration: Double

    var player: AVPlayer? { avPlayer }

    var currentTime: Double {
        let seconds = avPlayer.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    var isPlaying: Bool { avPlayer.rate > 0 }

    func play() {
        // A finished item must be rewound before it can play again; `play()` on an ended item is a
        // no-op in AVFoundation.
        if duration > 0, currentTime >= duration - 0.05 {
            avPlayer.seek(to: .zero)
        }
        avPlayer.play()
    }

    func pause() { avPlayer.pause() }

    func seek(to seconds: Double) {
        avPlayer.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
                      toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func release() {
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
    }
}

// MARK: - One player at a time, and backgrounding

/// The session category video and audio need: `.playback` so the silent switch does not mute the
/// reader's own request to hear the file, `.moviePlayback` mode so the route/behaviour matches the
/// media. Activation is best-effort — a simulator with no audio route still advances the clock, and a
/// failure to activate must not stop playback from being drawn.
enum MediaAudioSession {
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }
}

/// The single active player.
///
/// Two rules the card names explicitly: **one player at a time** (playing a second attachment stops
/// the first, so two soundtracks can never overlap) and **stop and release on background** (a
/// backgrounded app must not keep a player, its decoder or its item alive). Resigning active — the
/// control centre, a notification banner — only pauses; actually leaving the app stops.
///
/// Observed here rather than in each view because there is exactly one player at a time: losing
/// focus pauses it (the control centre, a notification shade), going to the background releases it
/// (an iPhone does not keep a decoder for an app the reader left), and an audio interruption — a
/// phone call — pauses it so it does not resume uninvited under the call.
@MainActor
final class MediaPlaybackCenter {
    static let shared = MediaPlaybackCenter()

    private weak var active: MediaPlaybackController?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.active?.pause() }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.active?.stop() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor in self?.active?.pause() }
        })
    }

    /// The player currently allowed to make sound. Exposed for tests.
    var activeController: MediaPlaybackController? { active }

    func activate(_ controller: MediaPlaybackController) {
        if active !== controller { active?.stop() }
        active = controller
    }

    func deactivate(_ controller: MediaPlaybackController) {
        if active === controller { active = nil }
    }
}

// MARK: - Controller

/// One attachment's player: staging → engine → transport state.
///
/// Nothing autoplays. `prepare()` stages the file and builds a paused player; `play()` is the
/// reader's tap (or the full-screen view resuming after a dismissal). The controller polls its
/// engine four times a second — enough for a smooth scrubber, cheap enough for a list — and is
/// `@MainActor`, so every mutation of what the view draws happens in one place.
@MainActor
final class MediaPlaybackController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case preparing
        case ready
        case playing
        case paused
        case failed(String)

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    let attachment: PostAttachment
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    /// While the reader drags the scrubber the timer must not fight the finger.
    var isScrubbing = false

    private let media: ChannelMedia?
    private let engineFactory: (URL) async -> MediaPlaybackEngine?
    private var engine: MediaPlaybackEngine?
    private var prepareTask: Task<Void, Never>?
    private var timer: Timer?

    var id: String { attachment.id }
    var player: AVPlayer? { engine?.player }
    var isPrepared: Bool {
        switch phase {
        case .ready, .playing, .paused: return true
        default: return false
        }
    }
    var isPlaying: Bool { phase == .playing }

    /// "0:02 / 0:08" — the visible position line.
    var clockLabel: String { "\(MediaTime.clock(currentTime)) / \(MediaTime.clock(duration))" }
    /// "2 of 8 seconds" — the VoiceOver value, and what the live test reads.
    var spokenPosition: String { MediaTime.spokenPosition(current: currentTime, duration: duration) }
    var progress: Double { MediaTime.fraction(current: currentTime, duration: duration) }

    init(attachment: PostAttachment,
         media: ChannelMedia?,
         engineFactory: ((URL) async -> MediaPlaybackEngine?)? = nil) {
        self.attachment = attachment
        self.media = media
        self.engineFactory = engineFactory ?? { url in await AVMediaEngine.make(url: url) }
    }

    // MARK: Lifecycle

    /// Stage the file and build a **paused** player. Safe to call more than once.
    func prepare(autoplay: Bool = false) {
        switch phase {
        case .idle, .failed: break
        default: return
        }
        guard let media else {
            phase = .failed("Playback is not available here.")
            return
        }
        // The refusal costs no bytes: a video past the preview bound is never staged.
        if case .tooLarge = PreviewFetchDecision.decide(kind: attachment.previewKind,
                                                        byteCount: attachment.sizeBytes) {
            phase = .failed(MediaStageError.tooLarge(limit: Int64(FileTypeMap.previewFetchByteLimit)).message)
            return
        }
        phase = .preparing
        prepareTask = Task { [weak self] in
            guard let self else { return }
            let staged = await media.stagedFile(for: self.attachment)
            guard !Task.isCancelled else { return }
            switch staged {
            case .failure(let error):
                self.phase = .failed(error.message)
            case .success(let url):
                guard let engine = await self.engineFactory(url) else {
                    self.phase = .failed("This file could not be opened for playback.")
                    return
                }
                guard !Task.isCancelled else { engine.release(); return }
                self.engine = engine
                self.duration = engine.duration
                self.phase = .ready
                if autoplay { self.play() }
            }
            self.prepareTask = nil
        }
    }

    func play() {
        guard let engine else {
            prepare(autoplay: true)
            return
        }
        MediaAudioSession.activate()
        engine.play()
        phase = .playing
        MediaPlaybackCenter.shared.activate(self)
        startTimer()
    }

    func pause() {
        engine?.pause()
        if phase == .playing { phase = .paused }
        stopTimer()
        currentTime = engine.map { min($0.currentTime, max(duration, 0)) } ?? currentTime
    }

    func togglePlayback() {
        if phase == .playing { pause() } else { play() }
    }

    func seek(to seconds: Double) {
        guard let engine else { return }
        let upper = duration > 0 ? duration : seconds
        let target = min(max(0, seconds), upper)
        engine.seek(to: target)
        currentTime = target
        if phase == .paused || phase == .ready { /* stay paused */ }
    }

    /// Stop, release the engine and drop back to idle. Called by `onDisappear`, by a second player
    /// taking over, and on background.
    func stop() {
        prepareTask?.cancel()
        prepareTask = nil
        stopTimer()
        engine?.release()
        engine = nil
        phase = .idle
        currentTime = 0
        duration = 0
        MediaPlaybackCenter.shared.deactivate(self)
    }

    // MARK: Polling

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// One tick: read the engine, notice the end of the file. Internal so a unit test drives it
    /// deterministically instead of waiting on a real clock.
    func refresh() {
        guard let engine else { return }
        if !isScrubbing {
            currentTime = max(0, engine.currentTime)
        }
        if duration <= 0, engine.duration > 0 { duration = engine.duration }
        if phase == .playing, duration > 0, currentTime >= duration - 0.1, !engine.isPlaying {
            phase = .paused
            stopTimer()
        }
    }
}

// MARK: - Poster frames

/// First-frame posters for video rows.
///
/// The server cannot make one: measured on the pinned 9.11.19, `GET /files/{id}/thumbnail` answers
/// **400** for both the mp4 and the mp3 (`scripts/t53_media_seed.py`), and the post's file metadata
/// marks `has_thumbnail` false. So the row draws the first frame of the file the client already
/// stages, decoded through `AVAssetImageGenerator` with `maximumSize` 600 px — one bounded bitmap
/// per row, never the video itself. A file too large to stage draws its labelled plate instead.
@MainActor
final class VideoPosterStore: ObservableObject {
    static let limit = 24
    static let byteLimit = 24 * 1024 * 1024
    nonisolated static let maxPixel: CGFloat = 600

    private let staging: MediaFileStaging
    private let requestBuilder: (String) throws -> URLRequest
    private var posters: [String: UIImage] = [:]
    private var costs: [String: Int] = [:]
    private var order: [String] = []
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init(staging: MediaFileStaging, requestBuilder: @escaping (String) throws -> URLRequest) {
        self.staging = staging
        self.requestBuilder = requestBuilder
    }

    var cachedCount: Int { posters.count }
    var cachedBytes: Int { costs.values.reduce(0, +) }

    func cachedPoster(for attachment: PostAttachment) -> UIImage? {
        guard let image = posters[attachment.id] else { return nil }
        touch(attachment.id)
        return image
    }

    func poster(for attachment: PostAttachment) async -> UIImage? {
        guard attachment.previewKind == .video, !attachment.isBlocked else { return nil }
        if let cached = posters[attachment.id] {
            touch(attachment.id)
            return cached
        }
        if let running = inFlight[attachment.id] { return await running.value }

        let staging = self.staging
        let requestBuilder = self.requestBuilder
        let task = Task<UIImage?, Never> {
            do {
                let request = try requestBuilder(attachment.id)
                switch await staging.stagedFile(for: attachment, request: request) {
                case .failure:
                    return nil
                case .success(let url):
                    return await Self.firstFrame(url: url)
                }
            } catch {
                return nil
            }
        }
        inFlight[attachment.id] = task
        let image = await task.value
        inFlight[attachment.id] = nil
        if let image { cache(image, id: attachment.id) }
        return image
    }

    func clear() {
        for (_, task) in inFlight { task.cancel() }
        inFlight.removeAll()
        posters.removeAll()
        costs.removeAll()
        order.removeAll()
    }

    /// The file's first frame, decoded at no more than `maxPixel` on its long edge.
    nonisolated static func firstFrame(url: URL, maxPixel: CGFloat = VideoPosterStore.maxPixel) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        // A keyframe at ~0 is enough for a poster; being loose here avoids decoding the whole GOP.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        do {
            let (cgImage, _) = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600))
            return UIImage(cgImage: cgImage)
        } catch {
            return nil
        }
    }

    private func cache(_ image: UIImage, id: String) {
        posters[id] = image
        costs[id] = ChannelImageStore.cost(of: image)
        order.removeAll { $0 == id }
        order.append(id)
        while posters.count > Self.limit {
            guard let oldest = order.first else { break }
            order.removeFirst()
            costs[oldest] = nil
            posters[oldest] = nil
        }
        while cachedBytes > Self.byteLimit {
            guard let oldest = order.first else { break }
            order.removeFirst()
            costs[oldest] = nil
            posters[oldest] = nil
        }
    }

    private func touch(_ id: String) {
        order.removeAll { $0 == id }
        order.append(id)
    }
}

// MARK: - The pane's media environment

/// What a pane needs to play or poster an attachment: the per-server staging cache, the
/// authenticated request builder, and the poster cache built on both.
///
/// Created by `ChannelPaneCoordinator` (one per server), so the same file staged by a poster is the
/// file the player opens — one download, not two.
@MainActor
final class ChannelMedia {
    let staging: MediaFileStaging
    let posters: VideoPosterStore
    private let requestBuilder: (String) throws -> URLRequest

    init(staging: MediaFileStaging,
         requestBuilder: @escaping (String) throws -> URLRequest,
         posters: VideoPosterStore? = nil) {
        self.staging = staging
        self.requestBuilder = requestBuilder
        self.posters = posters ?? VideoPosterStore(staging: staging, requestBuilder: requestBuilder)
    }

    func request(for fileID: String) throws -> URLRequest { try requestBuilder(fileID) }

    /// The local file for an attachment, staging it through the session's authenticated request.
    /// A request that cannot be built (signed out) is reported as a plain message, never a URL.
    func stagedFile(for attachment: PostAttachment) async -> Result<URL, MediaStageError> {
        guard !attachment.isBlocked else { return .failure(.blocked) }
        let request: URLRequest
        do {
            request = try requestBuilder(attachment.id)
        } catch {
            return .failure(.unavailable("This file needs a signed-in session to play."))
        }
        return await staging.stagedFile(for: attachment, request: request)
    }

    /// Stop anything this pane is playing and drop its posters (sign-out, server switch).
    func clear() {
        staging.clear()
        posters.clear()
    }
}
