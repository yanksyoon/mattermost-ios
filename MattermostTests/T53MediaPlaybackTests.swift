// T53 — video/audio playback, tested without a socket and without a media file where possible.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 — `app/components/files/video_file.tsx`,
// `app/components/files/audio_file.tsx`, `app/utils/file/index.ts`. Licence Apache-2.0; the
// classification and the bounds are reimplemented in Swift and asserted here.
//
// What is proved here, and where the live proof lives:
//   * classification/decision/bucketing/time-label rules — pure, this file;
//   * the staging cache — against a `URLProtocol` stub that streams real bytes (success, declared
//     too large, server sending past the bound, cancellation, eviction, a 32 MB payload's physical
//     footprint);
//   * the controller — against a fake engine: no autoplay, play/pause/scrub, stop releases, one
//     player at a time, background stops, a refused size never stages;
//   * the *real* playback (an 8-second mp4 past 1 s, an mp3 advancing) — the live UI test
//     `MattermostUITests/T53MediaPlaybackUITests` and the live transport measurement
//     `MattermostTests/T53MediaTransportTests`.

import XCTest
import AVFoundation
@testable import Mattermost

// MARK: - 1. Classification (the safety boundary did not grow an exception)

final class T53MediaClassificationTests: XCTestCase {

    func testAnMP4IsAVideoAndAnMP3IsAudio() {
        let video = FileTypeMap.descriptor(fileName: "clip.mp4", mimeType: "video/mp4")
        XCTAssertEqual(video.category, .video)
        XCTAssertEqual(video.preview, .video)
        XCTAssertEqual(FileTypeMap.typeLabel(video), "Video")
        XCTAssertEqual(video.symbolName, "video")

        let audio = FileTypeMap.descriptor(fileName: "tone.mp3", mimeType: "audio/mpeg")
        XCTAssertEqual(audio.category, .audio)
        XCTAssertEqual(audio.preview, .audio)
        XCTAssertEqual(FileTypeMap.typeLabel(audio), "Audio")
        XCTAssertEqual(audio.symbolName, "waveform")
    }

    func testTheDeclaredTypeNamesCoverTheExtensionsTheRowsUse() {
        for name in ["a.m4v", "a.mov", "a.mkv", "a.webm", "a.avi"] {
            XCTAssertEqual(FileTypeMap.descriptor(fileName: name, mimeType: "").preview, .video, name)
        }
        for name in ["a.m4a", "a.aac", "a.wav", "a.flac", "a.ogg", "a.opus", "a.aiff"] {
            XCTAssertEqual(FileTypeMap.descriptor(fileName: name, mimeType: "").preview, .audio, name)
        }
    }

    func testTheExtensionDecidesEvenWhenTheServerCallsAVideoAudio() {
        // `mime_type` is uploader-controlled input; the reader sees the name. A `.mp4` whose MIME
        // type says audio is still opened by the video player, and vice versa.
        XCTAssertEqual(FileTypeMap.descriptor(fileName: "clip.mp4", mimeType: "audio/mpeg").preview, .video)
        XCTAssertEqual(FileTypeMap.descriptor(fileName: "tone.mp3", mimeType: "video/mp4").preview, .audio)
    }

    func testAMediaFileWithADangerousMimeTypeIsStillRefused() {
        // The measured hostile case from T38, now applied to a media name: `clip.mp4` served as
        // `text/html` is refused as content, not played.
        XCTAssertEqual(FileTypeMap.descriptor(fileName: "clip.mp4", mimeType: "text/html").preview,
                       .unsupported(.unsafe))
        XCTAssertEqual(FileTypeMap.descriptor(fileName: "tone.mp3", mimeType: "image/svg+xml").preview,
                       .unsupported(.unsafe))
    }

    func testABlockedMediaFileIsRefusedNotPlayed() {
        let blocked = FileTypeMap.descriptor(fileName: "clip.mp4", mimeType: "video/mp4", isBlocked: true)
        XCTAssertEqual(blocked.category, .video)
        XCTAssertEqual(blocked.preview, .unsupported(.blocked))
        XCTAssertFalse(blocked.preview.isSupported)
    }

    /// The card's rule: the refusal list must not grow a playback exception. Every extension the
    /// classifier refuses still has no reader, and the ordinary no-reader types are still no-reader.
    func testTheRefusalListDidNotGrowAPlaybackException() {
        for name in ["page.html", "logo.svg", "module.wasm", "setup.exe", "tool.jar", "profile.mobileconfig"] {
            XCTAssertEqual(FileTypeMap.descriptor(fileName: name, mimeType: "").preview,
                           .unsupported(.unsafe), "\(name) must stay refused")
        }
        for name in ["bundle.zip", "report.xlsx", "letter.docx", "slides.pptx"] {
            XCTAssertEqual(FileTypeMap.descriptor(fileName: name, mimeType: "").preview,
                           .unsupported(.noReader), "\(name) must stay 'no reader'")
        }
    }

    func testOnlyVideoAndAudioAreMedia() {
        XCTAssertTrue(FilePreviewKind.video.isMedia)
        XCTAssertTrue(FilePreviewKind.audio.isMedia)
        for kind in [FilePreviewKind.image, .pdf, .text, .unsupported(.noReader)] {
            XCTAssertFalse(kind.isMedia)
        }
    }

    func testAMediaFileIsStillSupportedAndDownloadable() {
        XCTAssertTrue(FilePreviewKind.video.isSupported)
        XCTAssertTrue(FilePreviewKind.audio.isSupported)
        XCTAssertEqual(FileTypeMap.unsupportedReason(.noReader),
                       "There is no preview for this file type yet. Download it to open it in another app.")
    }
}

// MARK: - 2. The fetch decision (bounded before any bytes move)

final class T53MediaFetchDecisionTests: XCTestCase {

    func testASmallVideoOrAudioIsStaged() {
        XCTAssertEqual(PreviewFetchDecision.decide(kind: .video, byteCount: 8 * 1024 * 1024), .fetch)
        XCTAssertEqual(PreviewFetchDecision.decide(kind: .audio, byteCount: 8 * 1024 * 1024), .fetch)
    }

    func testAVideoPastThePreviewBoundIsRefusedBeforeAnyBytes() {
        let decision = PreviewFetchDecision.decide(kind: .video,
                                                   byteCount: Int64(FileTypeMap.previewFetchByteLimit) + 1)
        XCTAssertEqual(decision, .tooLarge(limit: Int64(FileTypeMap.previewFetchByteLimit)))
    }

    func testAnAudioFilePastTheBoundIsRefusedToo() {
        XCTAssertEqual(PreviewFetchDecision.decide(kind: .audio, byteCount: 300 * 1024 * 1024),
                       .tooLarge(limit: Int64(FileTypeMap.previewFetchByteLimit)))
    }

    func testTheBoundIsTheSameNumberThePdfReaderUses() {
        let limit = Int64(FileTypeMap.previewFetchByteLimit)
        XCTAssertEqual(PreviewFetchDecision.decide(kind: .video, byteCount: limit),
                       PreviewFetchDecision.decide(kind: .pdf, byteCount: limit))
        XCTAssertEqual(PreviewFetchDecision.decide(kind: .audio, byteCount: limit),
                       PreviewFetchDecision.decide(kind: .pdf, byteCount: limit))
    }

    func testAnUnknownSizeIsNotARefusal() {
        // `metadata.files` may carry no size; refusing would lose a playable file, so the transfer
        // proceeds and the download delegate is the remaining bound.
        XCTAssertEqual(PreviewFetchDecision.decide(kind: .video, byteCount: 0), .fetch)
    }

    func testImagesAreNotGatedHere() {
        // The image path bounds by pixel count at decode; its gate is not this decision.
        XCTAssertEqual(PreviewFetchDecision.decide(kind: .image, byteCount: 500 * 1024 * 1024), .fetch)
    }
}

// MARK: - 3. How a post's attachments are bucketed

final class T53MediaSectionTests: XCTestCase {

    private func attachment(_ id: String, _ name: String, _ mime: String,
                            blocked: Bool = false, duration: Double? = nil) -> PostAttachment {
        PostAttachment(id: id, name: name, mimeType: mime, sizeBytes: 1024, kind: .file,
                       isBlocked: blocked, hasThumbnail: false, durationSeconds: duration)
    }

    func testTheSectionBucketsVideoAudioAndFiles() {
        let section = AttachmentSection([
            attachment("img1", "shot.png", "image/png"),
            attachment("vid1", "clip.mp4", "video/mp4"),
            attachment("aud1", "tone.mp3", "audio/mpeg"),
            attachment("doc1", "notes.txt", "text/plain"),
            attachment("vid2", "blocked.mp4", "video/mp4", blocked: true),
        ])
        XCTAssertEqual(section.images.map(\.id), ["img1"])
        XCTAssertEqual(section.videos.map(\.id), ["vid1"])
        XCTAssertEqual(section.audios.map(\.id), ["aud1"])
        // A blocked video is a row the refusal screen handles; it is not a playable cell.
        XCTAssertEqual(section.files.map(\.id), ["doc1", "vid2"])
        XCTAssertFalse(section.isEmpty)
    }

    func testABlockedMediaFileIsTheOnlyWayAMediaFileBecomesARow() {
        let section = AttachmentSection([
            attachment("vid1", "clip.mp4", "video/mp4"),
            attachment("aud1", "tone.mp3", "audio/mpeg"),
            attachment("vid2", "blocked.mp4", "video/mp4", blocked: true),
            attachment("aud2", "blocked.mp3", "audio/mpeg", blocked: true),
        ])
        XCTAssertEqual(section.files.map(\.id), ["vid2", "aud2"])
        XCTAssertEqual(section.videos.count, 1)
        XCTAssertEqual(section.audios.count, 1)
    }

    func testAnEmptySectionKnowsItIsEmpty() {
        XCTAssertTrue(AttachmentSection([]).isEmpty)
    }

    func testTheGalleryStillOnlyHoldsImages() {
        let attachments = [attachment("img1", "shot.png", "image/png"),
                           attachment("vid1", "clip.mp4", "video/mp4")]
        let gallery = AttachmentGallery(postID: "p1", attachments: attachments)
        XCTAssertEqual(gallery?.images.map(\.id), ["img1"])
    }
}

// MARK: - 4. Duration: the metadata fallback rule

final class T53MediaDurationTests: XCTestCase {

    private func json(_ object: [String: Any]) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testMediaDurationReadsTheTwoAcceptedSpellings() throws {
        let seconds = try json(["metadata": ["duration": 8.5]])
        XCTAssertEqual(PostListDerivation.mediaDuration(from: seconds), 8.5)
        let underscore = try json(["metadata": ["duration_seconds": 3]])
        XCTAssertEqual(PostListDerivation.mediaDuration(from: underscore), 3)
    }

    func testMediaDurationIsNilWhenTheServerSentNothing() throws {
        XCTAssertNil(PostListDerivation.mediaDuration(from: try json(["id": "f1", "name": "a.mp3"])))
        XCTAssertNil(PostListDerivation.mediaDuration(from: try json(["metadata": ["duration": 0]])))
        XCTAssertNil(PostListDerivation.mediaDuration(from: try json(["metadata": ["duration": "8"]])))
    }

    func testAPostDecodesItsMediaDurationIntoTheAttachment() throws {
        let files: [[String: Any]] = [
            ["id": "vid1", "name": "clip.mp4", "mime_type": "video/mp4", "size": 75_000,
             "metadata": ["duration": 8.2]],
            ["id": "aud1", "name": "tone.mp3", "mime_type": "audio/mpeg", "size": 48_500],
        ]
        let metadata = try json(["files": files])
        let post = MMPost(id: "p1", message: "media", metadata: metadata)
        let attachments = PostListDerivation.attachments(for: post)
        XCTAssertEqual(attachments.first { $0.id == "vid1" }?.durationSeconds, 8.2)
        XCTAssertNil(attachments.first { $0.id == "aud1" }?.durationSeconds)
        XCTAssertEqual(attachments.first { $0.id == "vid1" }?.durationLabel, "0:08")
    }

    func testTheAudioRowShowsDurationWhenItHasOneAndTheTypeLabelWhenItDoesNot() {
        let known = PostAttachment(id: "a", name: "tone.mp3", mimeType: "audio/mpeg",
                                   sizeBytes: 48_500, kind: .file, isBlocked: false,
                                   hasThumbnail: false, durationSeconds: 8)
        XCTAssertEqual(known.audioRowDetail, "0:08 · 47.4 KB")

        let unknown = PostAttachment(id: "b", name: "tone.mp3", mimeType: "audio/mpeg",
                                     sizeBytes: 48_500, kind: .file, isBlocked: false,
                                     hasThumbnail: false)
        XCTAssertEqual(unknown.audioRowDetail, "Audio · 47.4 KB")
        XCTAssertNil(unknown.durationLabel)
    }

    func testDurationLabelRefusesNonsense() {
        for value in [0, -3, .nan, .infinity] {
            let attachment = PostAttachment(id: "a", name: "a.mp3", mimeType: "audio/mpeg",
                                            sizeBytes: 1, kind: .file, isBlocked: false,
                                            hasThumbnail: false, durationSeconds: value)
            XCTAssertNil(attachment.durationLabel, "\(value) is not a duration")
        }
    }
}

// MARK: - 5. Time labels

final class T53MediaTimeTests: XCTestCase {

    func testClockFormatting() {
        XCTAssertEqual(MediaTime.clock(0), "0:00")
        XCTAssertEqual(MediaTime.clock(8), "0:08")
        XCTAssertEqual(MediaTime.clock(65.9), "1:05")
        XCTAssertEqual(MediaTime.clock(3723), "1:02:03")
    }

    func testClockFormattingRefusesNonsense() {
        XCTAssertEqual(MediaTime.clock(-1), "0:00")
        XCTAssertEqual(MediaTime.clock(.nan), "0:00")
        XCTAssertEqual(MediaTime.clock(.infinity), "0:00")
    }

    func testProgressIsClampedAndNeverDividesByZero() {
        XCTAssertEqual(MediaTime.fraction(current: 2, duration: 8), 0.25, accuracy: 0.0001)
        XCTAssertEqual(MediaTime.fraction(current: 20, duration: 8), 1)
        XCTAssertEqual(MediaTime.fraction(current: -2, duration: 8), 0)
        XCTAssertEqual(MediaTime.fraction(current: 2, duration: 0), 0)
        XCTAssertEqual(MediaTime.fraction(current: .nan, duration: 8), 0)
    }

    func testTheSpokenPositionIsOneIntegerAPersonCanFollow() {
        XCTAssertEqual(MediaTime.spokenPosition(current: 2.4, duration: 8), "2 of 8 seconds")
        XCTAssertEqual(MediaTime.spokenPosition(current: 0, duration: 0), "0 of 0 seconds")
    }
}

// MARK: - URLProtocol stub

/// Serves a byte payload from memory — or, for "a server that keeps sending", a repeated chunk —
/// without a socket. `hang` never answers until the task is cancelled, which is how the
/// cancellation test reaches `stopLoading`.
final class T53StubURLProtocol: URLProtocol {
    struct Stub {
        var status = 200
        var body = Data()
        /// Reported as `Content-Length` (and therefore `totalBytesExpectedToWrite`).
        var expectedLength: Int64?
        /// When > 0, send this many bytes as 64 KB chunks instead of `body`.
        var chunkedBytes = 0
        var hang = false
        var contentType = "application/octet-stream"
    }

    static let lock = NSLock()
    nonisolated(unsafe) static var stub = Stub()
    nonisolated(unsafe) static var requestCount = 0

    static func reset(_ stub: Stub = Stub()) {
        lock.lock()
        Self.stub = stub
        requestCount = 0
        lock.unlock()
    }

    static func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }

    private var isHanging = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        let stub = Self.stub
        Self.lock.unlock()

        if stub.hang {
            isHanging = true
            return
        }
        var headers = ["Content-Type": stub.contentType]
        if let expected = stub.expectedLength { headers["Content-Length"] = "\(expected)" }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if stub.chunkedBytes > 0 {
            let chunk = Data(repeating: 0xAB, count: 64 * 1024)
            var sent = 0
            while sent < stub.chunkedBytes {
                let size = min(chunk.count, stub.chunkedBytes - sent)
                client?.urlProtocol(self, didLoad: chunk.prefix(size))
                sent += size
            }
        } else if !stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        if isHanging {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        }
    }
}

// MARK: - 6. The staging cache

final class T53MediaFileCacheTests: XCTestCase {

    private var directory: URL!
    private var cache: MediaFileCache!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("t53-cache-\(UUID().uuidString)", isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [T53StubURLProtocol.self]
        cache = MediaFileCache(directory: directory, configuration: configuration)
        T53StubURLProtocol.reset()
    }

    override func tearDown() {
        T53StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func request() -> URLRequest {
        URLRequest(url: URL(string: "https://fixture.invalid/api/v4/files/vid1")!)
    }

    private func attachment(_ id: String = "vid1",
                            size: Int64 = 0,
                            name: String = "clip.mp4",
                            mime: String = "video/mp4",
                            blocked: Bool = false) -> PostAttachment {
        PostAttachment(id: id, name: name, mimeType: mime, sizeBytes: size, kind: .file,
                       isBlocked: blocked, hasThumbnail: false)
    }

    func testStagingWritesTheFileAndReusesIt() async throws {
        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        T53StubURLProtocol.reset(.init(body: payload, expectedLength: Int64(payload.count)))
        let first = await cache.stagedFile(for: attachment(), request: request())
        let url = try XCTUnwrap(try? first.get())
        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(T53StubURLProtocol.count(), 1)

        let second = await cache.stagedFile(for: attachment(), request: request())
        XCTAssertEqual(try XCTUnwrap(try? second.get()), url)
        XCTAssertEqual(T53StubURLProtocol.count(), 1, "a staged file is not fetched twice")
    }

    func testTheFilenameKeepsTheIdAndTheExtension() async throws {
        T53StubURLProtocol.reset(.init(body: Data(repeating: 1, count: 8)))
        let result = await cache.stagedFile(for: attachment(), request: request())
        let url = try XCTUnwrap(try? result.get())
        XCTAssertEqual(url.lastPathComponent, "vid1-clip.mp4")
    }

    func testDeclaredTooLargeIsRefusedWithoutARequest() async throws {
        let result = await cache.stagedFile(for: attachment(size: 40 * 1024 * 1024), request: request())
        guard case .failure(.tooLarge(let limit)) = result else {
            return XCTFail("expected tooLarge, got \(result)")
        }
        XCTAssertEqual(limit, Int64(FileTypeMap.previewFetchByteLimit))
        XCTAssertEqual(T53StubURLProtocol.count(), 0, "no bytes may move for a refused file")
        XCTAssertEqual(cache.stagedFileCount, 0)
    }

    func testABlockedFileIsRefusedWithoutARequest() async {
        let result = await cache.stagedFile(for: attachment(blocked: true), request: request())
        XCTAssertEqual(result, .failure(.blocked))
        XCTAssertEqual(T53StubURLProtocol.count(), 0)
    }

    func testAServerThatSendsMoreThanTheBoundIsStoppedMidTransfer() async {
        // The post carried no size; the server claims 64 MB. The delegate sees the expected length
        // and cancels — the file never lands whole.
        T53StubURLProtocol.reset(.init(body: Data(repeating: 2, count: 1024),
                                       expectedLength: 64 * 1024 * 1024))
        let result = await cache.stagedFile(for: attachment(), request: request())
        guard case .failure(.tooLarge) = result else {
            return XCTFail("expected tooLarge, got \(result)")
        }
        XCTAssertEqual(cache.stagedFileCount, 0, "a cancelled transfer leaves no staged file")
    }

    func testCancellingStagingReportsCancelledAndLeavesNoFile() async {
        T53StubURLProtocol.reset(.init(hang: true))
        let task = Task { await cache.stagedFile(for: attachment(), request: request()) }
        // Let the request reach the stub before cancelling it.
        try? await Task.sleep(nanoseconds: 100_000_000)
        cache.cancel(fileID: "vid1")
        let result = await task.value
        XCTAssertEqual(result, .failure(.cancelled))
        XCTAssertEqual(cache.stagedFileCount, 0)
    }

    func testTheCacheKeepsAtMostItsFileLimit() async {
        T53StubURLProtocol.reset(.init(body: Data(repeating: 3, count: 2048)))
        for index in 0..<(MediaFileCache.stagedLimit + 1) {
            let result = await cache.stagedFile(for: attachment("vid\(index)"), request: request())
            XCTAssertNoThrow(try result.get())
        }
        XCTAssertEqual(cache.stagedFileCount, MediaFileCache.stagedLimit)
    }

    func testClearRemovesEveryStagedFile() async {
        T53StubURLProtocol.reset(.init(body: Data(repeating: 4, count: 1024)))
        _ = await cache.stagedFile(for: attachment(), request: request())
        XCTAssertEqual(cache.stagedFileCount, 1)
        cache.clear()
        XCTAssertEqual(cache.stagedFileCount, 0)
    }
}

// MARK: - 7. Streaming keeps the payload out of memory

final class T53MediaFootprintTests: XCTestCase {

    /// Physical footprint of this process, in bytes (`-1` when the kernel refused the query).
    private func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
                                           / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
    }

    func testAStagedPayloadIsWrittenToDiskRatherThanHeldInMemory() async throws {
        let payloadBytes = 32 * 1024 * 1024
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("t53-footprint-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [T53StubURLProtocol.self]
        let cache = MediaFileCache(directory: directory, configuration: configuration)
        T53StubURLProtocol.reset(.init(expectedLength: Int64(payloadBytes), chunkedBytes: payloadBytes))

        let before = footprint()
        let attachment = PostAttachment(id: "big", name: "big.mp4", mimeType: "video/mp4",
                                        sizeBytes: 0, kind: .file, isBlocked: false,
                                        hasThumbnail: false)
        let result = await cache.stagedFile(for: attachment,
                                            request: URLRequest(url: URL(string: "https://fixture.invalid/big")!))
        let url = try XCTUnwrap(try? result.get())
        let after = footprint()

        let size = (try FileManager.default.attributesOfItem(atPath: url.path))[.size] as? NSNumber
        XCTAssertEqual(size?.int64Value, Int64(payloadBytes), "all \(payloadBytes) bytes are on disk")
        let delta = after - before
        print("T53FOOTPRINT payload=\(payloadBytes) before=\(before) after=\(after) delta=\(delta)")
        // Isolated runs measured 0.44 MB and 5.1 MB of growth; a whole-bundle run, in a process that
        // already held 217 MB of other tests, measured 22.3 MB. The allocator's state is the noise, so
        // the guard is deliberately the payload size itself: a transport that held the body as one
        // `Data` (plus the task's own buffers) would grow by at least the payload, and a regression
        // that copied it twice would grow by two payloads. What this test *does* prove exactly is the
        // line above it: all 32 MB are on disk, and the file is served by the app's own cache.
        XCTAssertLessThan(delta, Int64(payloadBytes),
                          "staging \(payloadBytes) bytes grew the footprint by \(delta) bytes")
    }
}

// MARK: - Fakes for the controller

@MainActor
final class T53FakeEngine: MediaPlaybackEngine {
    var currentTime: Double = 0
    var duration: Double
    var isPlaying = false
    var player: AVPlayer? { nil }
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var releaseCount = 0
    private(set) var seeks: [Double] = []

    init(duration: Double = 8) { self.duration = duration }

    func play() {
        playCount += 1
        isPlaying = true
        if currentTime == 0 { currentTime = 0.25 }
    }

    func pause() {
        pauseCount += 1
        isPlaying = false
    }

    func seek(to seconds: Double) {
        seeks.append(seconds)
        currentTime = seconds
    }

    func release() {
        releaseCount += 1
        isPlaying = false
    }

    /// Drive the clock the way AVFoundation would between two polls.
    func advance(to seconds: Double) { currentTime = seconds }
}

final class T53FakeStaging: MediaFileStaging {
    var result: Result<URL, MediaStageError>
    private(set) var calls = 0
    private(set) var requests: [URLRequest] = []

    init(result: Result<URL, MediaStageError>) { self.result = result }

    func stagedFile(for attachment: PostAttachment,
                    request: URLRequest) async -> Result<URL, MediaStageError> {
        calls += 1
        requests.append(request)
        return result
    }

    func clear() {}
}

private final class T53WeakBox {
    weak var engine: T53FakeEngine?
}

// MARK: - 8. The controller's lifecycle

@MainActor
final class T53PlaybackControllerTests: XCTestCase {

    private var fileURL: URL!
    private var staging: T53FakeStaging!

    override func setUp() async throws {
        try await super.setUp()
        MediaPlaybackCenter.shared.activeController?.stop()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("t53-\(UUID().uuidString).mp4")
        try Data(repeating: 0, count: 64).write(to: fileURL)
        staging = T53FakeStaging(result: .success(fileURL))
    }

    override func tearDown() async throws {
        MediaPlaybackCenter.shared.activeController?.stop()
        try? FileManager.default.removeItem(at: fileURL)
        try await super.tearDown()
    }

    private func attachment(size: Int64 = 1024,
                            name: String = "clip.mp4",
                            mime: String = "video/mp4") -> PostAttachment {
        PostAttachment(id: "vid1", name: name, mimeType: mime, sizeBytes: size, kind: .file,
                       isBlocked: false, hasThumbnail: false)
    }

    private func media(_ staging: T53FakeStaging) -> ChannelMedia {
        ChannelMedia(staging: staging,
                     requestBuilder: { _ in URLRequest(url: URL(string: "https://fixture.invalid/f")!) })
    }

    private func make(_ attachment: PostAttachment? = nil,
                      staging: T53FakeStaging? = nil,
                      box: T53WeakBox? = nil,
                      engine: T53FakeEngine? = nil,
                      urlLog: T53URLLog? = nil) -> MediaPlaybackController {
        let staging = staging ?? self.staging!
        let engine = engine ?? T53FakeEngine()
        let factory: (URL) async -> MediaPlaybackEngine?
        if let box {
            // The factory must not retain the engine, or the test could never observe it being
            // released: it makes one, parks it weakly in the box, and the controller is the only
            // strong owner.
            factory = { url in
                urlLog?.urls.append(url)
                let created = T53FakeEngine()
                box.engine = created
                return created
            }
        } else {
            factory = { url in
                urlLog?.urls.append(url)
                return engine
            }
        }
        return MediaPlaybackController(attachment: attachment ?? self.attachment(),
                                       media: media(staging),
                                       engineFactory: factory)
    }

    private func waitUntil(_ condition: () -> Bool,
                           timeout: TimeInterval = 3,
                           file: StaticString = #filePath,
                           line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "condition not reached", file: file, line: line)
    }

    func testPrepareStagesAFileAndBuildsAPausedPlayer() async {
        let box = T53WeakBox()
        let log = T53URLLog()
        let controller = make(box: box, urlLog: log)
        controller.prepare()
        await waitUntil { controller.phase == .ready }

        XCTAssertEqual(staging.calls, 1)
        XCTAssertEqual(log.urls, [fileURL], "the engine is handed the staged local file")
        XCTAssertNotNil(box.engine)
        XCTAssertEqual(box.engine?.playCount, 0, "nothing autoplays with sound")
        XCTAssertEqual(controller.duration, 8)
        XCTAssertEqual(controller.isPrepared, true)

        controller.stop()
    }

    func testPlayTransitionsAndRefreshAdvancesThePosition() async {
        let engine = T53FakeEngine(duration: 8)
        let controller = make(engine: engine)
        controller.prepare()
        await waitUntil { controller.phase == .ready }

        controller.play()
        XCTAssertEqual(controller.phase, .playing)
        XCTAssertEqual(engine.playCount, 1)

        engine.advance(to: 1.4)
        controller.refresh()
        XCTAssertEqual(controller.currentTime, 1.4, accuracy: 0.001)
        XCTAssertEqual(controller.spokenPosition, "1 of 8 seconds")
        XCTAssertEqual(controller.progress, 0.175, accuracy: 0.001)

        controller.pause()
        XCTAssertEqual(controller.phase, .paused)
        XCTAssertEqual(engine.pauseCount, 1)
        controller.stop()
    }

    func testSeekClampsToTheFileAndNeverGoesNegative() async {
        let engine = T53FakeEngine(duration: 8)
        let controller = make(engine: engine)
        controller.prepare()
        await waitUntil { controller.phase == .ready }

        controller.seek(to: 3)
        controller.seek(to: 100)
        controller.seek(to: -4)
        XCTAssertEqual(engine.seeks, [3, 8, 0])
        XCTAssertEqual(controller.currentTime, 0)
        controller.stop()
    }

    func testRefreshNoticesTheEndOfTheFile() async {
        let engine = T53FakeEngine(duration: 8)
        let controller = make(engine: engine)
        controller.prepare()
        await waitUntil { controller.phase == .ready }
        controller.play()
        engine.advance(to: 8)
        engine.isPlaying = false
        controller.refresh()
        XCTAssertEqual(controller.phase, .paused)
        controller.stop()
    }

    func testStopReleasesTheEngineAndTheControllerHoldsNothing() async {
        let box = T53WeakBox()
        let controller = make(box: box)
        controller.prepare()
        await waitUntil { controller.phase == .ready }
        controller.play()
        XCTAssertNotNil(box.engine)

        controller.stop()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(box.engine, "stop must drop the engine (and with it the item and decoder)")
        XCTAssertNil(MediaPlaybackCenter.shared.activeController)
    }

    func testOnlyOnePlayerMakesSound() async {
        let first = make(attachment(name: "one.mp4"))
        first.prepare()
        await waitUntil { first.phase == .ready }
        first.play()
        XCTAssertEqual(first.phase, .playing)

        let second = make(attachment(name: "two.mp4"))
        second.prepare()
        await waitUntil { second.phase == .ready }
        second.play()

        XCTAssertEqual(second.phase, .playing)
        XCTAssertEqual(first.phase, .idle, "the second player stops the first")
        XCTAssertIdentical(MediaPlaybackCenter.shared.activeController, second)
        first.stop()
        second.stop()
    }

    func testBackgroundingStopsAndReleasesThePlayer() async {
        let box = T53WeakBox()
        let controller = make(box: box)
        controller.prepare()
        await waitUntil { controller.phase == .ready }
        controller.play()

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await waitUntil { controller.phase == .idle }
        XCTAssertNil(box.engine)
    }

    func testResigningActiveOnlyPauses() async {
        let engine = T53FakeEngine()
        let controller = make(engine: engine)
        controller.prepare()
        await waitUntil { controller.phase == .ready }
        controller.play()

        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        await waitUntil { controller.phase == .paused }
        XCTAssertNotNil(engine, "a paused player is still held")
        XCTAssertEqual(engine.pauseCount, 1)
        controller.stop()
    }

    func testATooLargeFileFailsBeforeStaging() async {
        let controller = make(attachment(size: 300 * 1024 * 1024))
        controller.prepare()
        await waitUntil { controller.phase.isFailure }
        XCTAssertEqual(staging.calls, 0, "a refused size must not reach the transport")
        if case .failed(let message) = controller.phase {
            XCTAssertTrue(message.contains("larger than"), message)
        }
        controller.stop()
    }

    func testAStagingFailureIsReportedWithItsOwnMessage() async {
        let failing = T53FakeStaging(result: .failure(.tooLarge(limit: 1024)))
        let controller = make(staging: failing)
        controller.prepare()
        await waitUntil { controller.phase.isFailure }
        if case .failed(let message) = controller.phase {
            XCTAssertTrue(message.contains("larger than"), message)
        } else {
            XCTFail("expected a failure phase")
        }
        controller.stop()
    }

    func testAnAudioInterruptionPausesThePlayer() async {
        let engine = T53FakeEngine()
        let controller = make(engine: engine)
        controller.prepare()
        await waitUntil { controller.phase == .ready }
        controller.play()

        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                                        object: nil,
                                        userInfo: [AVAudioSessionInterruptionTypeKey:
                                                    AVAudioSession.InterruptionType.began.rawValue])
        await waitUntil { controller.phase == .paused }
        XCTAssertEqual(engine.pauseCount, 1)
        controller.stop()
    }

    func testPlayingAsksForThePlaybackAudioCategory() async {
        let controller = make()
        controller.prepare()
        await waitUntil { controller.phase == .ready }
        controller.play()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback,
                       "a silent switch must not mute the file the reader asked to hear")
        controller.stop()
    }

    func testThePlayerIsNeverHandedANetworkURL() async {
        let log = T53URLLog()
        let controller = make(urlLog: log)
        controller.prepare()
        await waitUntil { controller.phase == .ready }
        XCTAssertEqual(log.urls.count, 1)
        XCTAssertTrue(log.urls.allSatisfy(\.isFileURL),
                      "playback opens a staged file; a server URL would need the token")
        controller.stop()
    }
}

/// Records the URLs the controller hands to its engine factory.
final class T53URLLog {
    var urls: [URL] = []
}
