// T53 — the transport measurement the card asked for, kept as a re-runnable live test.
//
// The question: `GET /api/v4/files/{id}` needs the vault's bearer token, and `AVPlayer` cannot send
// one. Two paths were candidates:
//
//   A. `AVURLAsset(url:options:[AVURLAssetHTTPHeaderFieldsKey: ["Authorization": "Bearer …"]])` —
//      the undocumented-but-widely-used out-of-band header key.
//   B. stage the file with the client's own authenticated request, then play the local file.
//
// These tests run both against the **live fixture** (`scripts/t53_media_seed.py`, channel
// #t53-media) and record what happened as a test attachment. B is the shipped path (*this* client's
// `MediaFileCache` + `AVMediaEngine`) and is asserted: a `file://` URL, the asset's own duration, and
// a real playback-state transition past one second. A is measured, not shipped — it is asserted only
// to still load, so a future OS that rejects the header key makes this test fail loudly instead of
// leaving `docs/t53-build-note.md` §2 claiming something that is no longer true.
//
// Both skip (never fail) without the live environment; nothing here touches a socket otherwise.
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim "iPhone 16 Pro" \
//       --only-testing MattermostTests/T53MediaTransportTests

import XCTest
import AVFoundation
@testable import Mattermost

@MainActor
final class T53MediaTransportTests: XCTestCase {
    private struct Live {
        let server: URL
        let token: String
        let videoID: String
        let videoName: String
    }

    private static func httpStatus(_ response: URLResponse?) -> Int {
        (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    // MARK: - Live fixture

    private func live() throws -> Live {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        let login = env["MM_AUTH_LOGIN"] ?? ""
        let password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !login.isEmpty && !password.isEmpty,
                          "Live media transport test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        let server = try XCTUnwrap(URL(string: raw))
        let token = try signIn(server: server, login: login, password: password)
        let (videoID, videoName) = try fixtureVideo(server: server, token: token)
        return Live(server: server, token: token, videoID: videoID, videoName: videoName)
    }

    private func signIn(server: URL, login: String, password: String) throws -> String {
        var request = URLRequest(url: server.appendingPathComponent("api/v4/users/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["login_id": login,
                                                                      "password": password])
        let (status, _, headers) = try synchronous(request)
        XCTAssertEqual(status, 200, "the fixture login must answer 200")
        return try XCTUnwrap(headers["token"], "the session token is in the response header")
    }

    private func fixtureVideo(server: URL, token: String) throws -> (id: String, name: String) {
        let channelURL = server.appendingPathComponent("api/v4/teams/name/perf/channels/name/t53-media")
        let channel = try json(try get(channelURL, token: token))
        let channelID = try XCTUnwrap(channel["id"] as? String,
                                      "channel #t53-media is missing — run scripts/t53_media_seed.py")
        var postsURL = server.appendingPathComponent("api/v4/channels/\(channelID)/posts")
        var components = URLComponents(url: postsURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "per_page", value: "60")]
        postsURL = try XCTUnwrap(components?.url)
        let posts = try json(try get(postsURL, token: token))
        let map = try XCTUnwrap(posts["posts"] as? [String: Any])
        let order = try XCTUnwrap(posts["order"] as? [String])
        for postID in order {
            guard let post = map[postID] as? [String: Any],
                  let props = post["props"] as? [String: Any],
                  props["t53_key"] as? String == "t53-media",
                  let fileIDs = post["file_ids"] as? [String] else { continue }
            for fileID in fileIDs {
                let info = try json(try get(server.appendingPathComponent("api/v4/files/\(fileID)/info"),
                                            token: token))
                let name = info["name"] as? String ?? ""
                if name.hasSuffix(".mp4") { return (fileID, name) }
            }
        }
        throw XCTSkip("the T53 fixture post has no mp4 — run scripts/t53_media_seed.py")
    }

    private func get(_ url: URL, token: String) throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        let (status, data, _) = try synchronous(request)
        guard status == 200 else { throw XCTSkip("GET \(url.path) answered \(status)") }
        return data
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A semaphore bridge for the fixture's own HTTP calls (the test target has no async URLSession
    /// helper, and this is setup code, not the system under test).
    private func synchronous(_ request: URLRequest) throws -> (Int, Data, [String: String]) {
        let box = ResponseBox()
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            var headers: [String: String] = [:]
            if let http = response as? HTTPURLResponse {
                for (key, value) in http.allHeaderFields {
                    headers[String(describing: key).lowercased()] = String(describing: value)
                }
            }
            box.status = Self.httpStatus(response)
            box.data = data ?? Data()
            box.headers = headers
            box.error = error
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 60)
        if let error = box.error { throw error }
        return (box.status, box.data, box.headers)
    }

    private final class ResponseBox: @unchecked Sendable {
        var status = 0
        var data = Data()
        var headers: [String: String] = [:]
        var error: Error?
    }

    private func fileRequest(_ live: Live) throws -> URLRequest {
        var request = URLRequest(url: live.server.appendingPathComponent("api/v4/files/\(live.videoID)"))
        request.setValue("Bearer \(live.token)", forHTTPHeaderField: "Authorization")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        return request
    }

    /// Play `player` for up to `seconds` and return the furthest position it reached.
    private func playedTo(_ player: AVPlayer, seconds: Double) async -> Double {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        var maximum = 0.0
        let steps = Int(seconds / 0.2)
        for _ in 0..<steps {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let position = player.currentTime().seconds
            if position.isFinite { maximum = max(maximum, position) }
            if player.status == .failed { break }
        }
        player.pause()
        return maximum
    }

    // MARK: - B: the shipped path (asserted)

    func testTheShippedTransportStagesALocalFileAndPlaysItPastOneSecond() async throws {
        let live = try live()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("t53-transport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = MediaFileCache(directory: directory)
        let attachment = PostAttachment(id: live.videoID,
                                        name: live.videoName,
                                        mimeType: "video/mp4",
                                        sizeBytes: 0,
                                        kind: .file,
                                        isBlocked: false,
                                        hasThumbnail: false)
        let result = await cache.stagedFile(for: attachment, request: try fileRequest(live))
        let staged: URL
        switch result {
        case .success(let url): staged = url
        case .failure(let error): return XCTFail("staging failed: \(error.message)")
        }

        XCTAssertTrue(staged.isFileURL, "the player must be handed a local file, never a server URL")
        XCTAssertFalse(staged.absoluteString.contains("token"), "no credential in the staged URL")
        let size = (try? FileManager.default.attributesOfItem(atPath: staged.path))?[.size] as? NSNumber
        XCTAssertGreaterThan(size?.int64Value ?? 0, 1024, "the staged file must contain the fixture")

        guard let engine = await AVMediaEngine.make(url: staged) else {
            return XCTFail("AVFoundation could not open the staged file")
        }
        let engineDuration = engine.duration
        XCTAssertEqual(engineDuration, 8.0, accuracy: 0.2, "the fixture clip is 8 seconds")
        let player = try XCTUnwrap(engine.player)
        let reached = await playedTo(player, seconds: 4)
        record("B download-then-play: staged=\(staged.lastPathComponent) bytes=\(size?.int64Value ?? 0) "
               + "duration=\(engineDuration) playedTo=\(reached)")
        XCTAssertGreaterThan(reached, 1.0, "the shipped path must play past one second")
        engine.release()
        let detach = engine.player?.currentItem
        XCTAssertNil(detach, "release must detach the item")
    }

    // MARK: - A: measured, not shipped

    func testTheHeaderCarriedAuthorizationPathStillLoadsAndPlays() async throws {
        let live = try live()
        let url = live.server.appendingPathComponent("api/v4/files/\(live.videoID)")
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(live.token)"],
        ])
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration).seconds
        XCTAssertTrue(playable, "AVURLAsset with the header key must still report playable")
        XCTAssertEqual(duration, 8.0, accuracy: 0.2)

        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        let reached = await playedTo(player, seconds: 4)
        record("A header out-of-band: playable=\(playable) duration=\(duration) playedTo=\(reached) "
               + "error=\(String(describing: item.error))")
        XCTAssertGreaterThan(reached, 1.0,
                             "the header path only stays in the build note as a measurement while it plays")
        player.pause()
    }

    private func record(_ text: String) {
        print("T53MEASURE \(text)")
        let attachment = XCTAttachment(string: text)
        attachment.name = "T53 transport measurement"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
