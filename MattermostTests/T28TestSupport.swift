import Foundation
import XCTest
@testable import Mattermost

// Shared fakes for the T28 transport tests. Nothing here touches the network, the Keychain or a
// real clock, which is what lets the whole suite run deterministically on Catalyst and Simulator.

/// A scripted `APITransport`. Each `send` consumes the next stub; when the queue is empty the
/// `fallback` stub is used forever (so a retry test can serve "429 then success" without racing).
final class FakeAPITransport: APITransport {

    struct Stub {
        var response: APIResponse?
        var error: APITransportError?

        static func ok(_ response: APIResponse) -> Stub { Stub(response: response, error: nil) }
        static func fail(_ error: APITransportError) -> Stub { Stub(response: nil, error: error) }
    }

    private let lock = NSLock()
    private var stubs: [Stub]
    private var fallback: Stub?
    private(set) var requests: [APIRequest] = []

    init(stubs: [Stub], fallback: Stub? = nil) {
        self.stubs = stubs
        self.fallback = fallback
    }

    /// Convenience: one response repeated forever.
    init(repeating response: APIResponse) {
        self.stubs = []
        self.fallback = .ok(response)
    }

    /// Convenience: one transport error repeated forever.
    init(repeatingError error: APITransportError) {
        self.stubs = []
        self.fallback = .fail(error)
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    var lastRequest: APIRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last
    }

    func send(_ request: APIRequest) async throws -> APIResponse {
        lock.lock()
        requests.append(request)
        let stub: Stub?
        if stubs.isEmpty {
            stub = fallback
        } else {
            stub = stubs.removeFirst()
        }
        lock.unlock()

        guard let stub else {
            throw APITransportError.other("FakeAPITransport ran out of stubs")
        }
        if let error = stub.error { throw error }
        guard let response = stub.response else {
            throw APITransportError.other("FakeAPITransport stub had neither response nor error")
        }
        return response
    }
}

/// A `SecretPersisting` backed by a dictionary, so vault tests never touch the Keychain or the
/// encrypted-file fallback.
final class InMemorySecretStore: SecretPersisting {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    var backendDescription: String { "In-memory" }

    func get(service: String, account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items["\(service)|\(account)"]
    }

    func set(service: String, account: String, value: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        items["\(service)|\(account)"] = value
    }

    func delete(service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items["\(service)|\(account)"] = nil
    }

    func deleteAll(service: String) throws {
        lock.lock()
        defer { lock.unlock() }
        for key in items.keys where key.hasPrefix("\(service)|") { items[key] = nil }
    }
}

/// A scripted WebSocket transport. The test decides what the server says and when the socket
/// dies; `sent` records every frame the client wrote (so the authentication challenge and pings
/// are assertable without a server).
final class ScriptedSocketTransport: SocketTransport, @unchecked Sendable {

    let events: AsyncStream<SocketTransportEvent>
    private let continuation: AsyncStream<SocketTransportEvent>.Continuation
    private let lock = NSLock()
    private var frames: [String] = []
    private var closes = 0
    private var finished = false

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: SocketTransportEvent.self,
                                                            bufferingPolicy: .bufferingNewest(256))
        self.events = stream
        self.continuation = continuation
    }

    var sent: [String] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    var closeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return closes
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func resume() {
        // The test pushes events; there is nothing to open.
    }

    func push(_ event: SocketTransportEvent) {
        lock.lock()
        let done = finished
        lock.unlock()
        guard !done else { return }
        continuation.yield(event)
    }

    /// Convenience for a server event frame (`event` + `seq` + `data`).
    func pushEvent(_ name: String, seq: Int, data: [String: Any]) {
        push(.text(Self.frame(event: name, seq: seq, data: data)))
    }

    func finish() {
        lock.lock()
        let already = finished
        finished = true
        lock.unlock()
        guard !already else { return }
        continuation.finish()
    }

    func send(text: String) async throws {
        lock.lock()
        frames.append(text)
        lock.unlock()
    }

    func close() {
        lock.lock()
        closes += 1
        lock.unlock()
        push(.closed(code: 1000, reason: nil))
        finish()
    }

    static func frame(event: String, seq: Int, data: [String: Any]) -> String {
        let object: [String: Any] = ["event": event, "seq": seq, "data": data, "broadcast": [:]]
        let payload = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return String(decoding: payload, as: UTF8.self)
    }

    static func reply(seq: Int, text: String) -> String {
        let object: [String: Any] = ["status": "OK", "seq_reply": seq, "data": ["text": text]]
        let payload = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return String(decoding: payload, as: UTF8.self)
    }
}

/// Hands out scripted transports in order and keeps the created ones so a test can push into the
/// connection the client is using right now.
final class ScriptedTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [ScriptedSocketTransport]
    private(set) var created: [ScriptedSocketTransport] = []
    private var urls: [URL] = []
    private var headers: [[String: String]] = []

    init(_ transports: [ScriptedSocketTransport]) {
        self.remaining = transports
    }

    func make(_ url: URL, _ headers: [String: String]) -> SocketTransport {
        lock.lock()
        defer { lock.unlock() }
        urls.append(url)
        self.headers.append(headers)
        let transport: ScriptedSocketTransport
        if remaining.isEmpty {
            // Never run out silently: a fresh transport keeps the test from hanging on nil.
            transport = ScriptedSocketTransport()
        } else {
            transport = remaining.removeFirst()
        }
        created.append(transport)
        return transport
    }

    var madeURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }

    var madeHeaders: [[String: String]] {
        lock.lock()
        defer { lock.unlock() }
        return headers
    }
}

/// A clock whose sleeps either return immediately (recording the delays) or block until the test
/// releases them — both with cancellation safety, so `stop()` never leaves a task suspended.
final class TestSocketClock: SocketClock, @unchecked Sendable {
    private let lock = NSLock()
    private var delays: [TimeInterval] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let autoRelease: Bool

    init(autoRelease: Bool) {
        self.autoRelease = autoRelease
    }

    var requestedDelays: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return delays
    }

    func sleep(for seconds: TimeInterval) async {
        lock.lock()
        delays.append(seconds)
        let shouldWait = !autoRelease
        lock.unlock()
        guard shouldWait else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                waiters.append(continuation)
                lock.unlock()
            }
        } onCancel: {
            self.release()
        }
    }

    /// Release one blocked sleep (no-op when nothing is waiting).
    func release() {
        lock.lock()
        let waiter = waiters.isEmpty ? nil : waiters.removeFirst()
        lock.unlock()
        waiter?.resume()
    }
}

/// Collects a socket event stream so a test can assert on an ordered snapshot without racing the
/// consumer.
final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SocketEvent] = []
    private var finished = false

    var events: [SocketEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var count: Int { events.count }
    var streamFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func append(_ event: SocketEvent) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(event)
    }

    func markFinished() {
        lock.lock()
        defer { lock.unlock() }
        finished = true
    }

    /// Starts a task that drains `stream` into this box. Cancel the returned task to stop.
    func consume(_ stream: AsyncStream<SocketEvent>) -> Task<Void, Never> {
        Task { [weak self] in
            for await event in stream {
                self?.append(event)
            }
            self?.markFinished()
        }
    }
}

// MARK: - Small assertion helpers

extension APIResponse {
    static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> APIResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return APIResponse(statusCode: status, headers: headers, body: body)
    }

    static func text(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> APIResponse {
        APIResponse(statusCode: status, headers: headers, body: Data(text.utf8))
    }

    static func status(_ status: Int, headers: [String: String] = [:]) -> APIResponse {
        APIResponse(statusCode: status, headers: headers, body: Data())
    }
}

extension XCTestCase {
    /// Poll until `condition` holds (bounded). Used instead of `sleep` so tests stay fast and do
    /// not fail on a slow CI host unless the condition genuinely never becomes true. The closure is
    /// `async` so a test can await actor state.
    func waitUntil(_ description: String,
                   timeout: TimeInterval = 5,
                   file: StaticString = #filePath,
                   line: UInt = #line,
                   _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
    }

    /// Filters JSON-decoded objects for a query item by name.
    func queryValue(_ request: APIRequest?, _ name: String) -> String? {
        guard let url = request?.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first { $0.name == name }?.value
    }
}
