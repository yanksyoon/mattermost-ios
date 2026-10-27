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

/// A signal a fake records and a test awaits — the replacement for polling a value the test drove
/// itself (kanban t_eccd49eb).
///
/// Two properties matter:
///  * **it remembers** every value, so a test may await an event that already fired. A test that
///    installs an `XCTestExpectation` after the fact can miss one that landed just before; a poll
///    cannot. Recording the value removes that ordering trap from every call site.
///  * **the timeout is a hang detector, not a latency budget**: `wait(until:)` returns as soon as a
///    matching value exists or arrives, so a busy or frozen host cannot make it miss. A broken
///    pipeline reds after 30 s (the default) instead of hanging the suite; 30 s is ~1000x the
///    measured latency of these fakes, which is milliseconds.
final class TestSignal<Value: Sendable>: @unchecked Sendable {

    private final class Waiter: @unchecked Sendable {
        let predicate: @Sendable (Value) -> Bool
        var resume: ((Bool) -> Void)?
        var outcome: Bool?
        init(_ predicate: @escaping @Sendable (Value) -> Bool) { self.predicate = predicate }
    }

    private let lock = NSLock()
    private var values: [Value] = []
    private var waiters: [Waiter] = []

    /// Record one value and wake every waiter whose predicate matches it.
    func send(_ value: Value) {
        lock.lock()
        values.append(value)
        var hits: [Waiter] = []
        waiters.removeAll { waiter in
            guard waiter.predicate(value) else { return false }
            hits.append(waiter)
            return true
        }
        lock.unlock()
        for hit in hits { deliver(hit, true) }
    }

    /// Every value recorded so far, in order (for assertions that want the history).
    var recorded: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    /// Await the first value that matches `predicate`, including one recorded before this call.
    /// Returns false only when the hang detector fired (nothing matched within `timeout`).
    func wait(until predicate: @escaping @Sendable (Value) -> Bool,
              timeout: TimeInterval = 30) async -> Bool {
        lock.lock()
        if values.contains(where: predicate) {
            lock.unlock()
            return true
        }
        let waiter = Waiter(predicate)
        waiters.append(waiter)
        lock.unlock()

        let timer = Task.detached { [weak self] in
            guard timeout.isFinite, timeout > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, self.take(waiter) else { return }   // lost the race: a value arrived
            self.deliver(waiter, false)
        }
        defer { timer.cancel() }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            lock.lock()
            let early = waiter.outcome
            waiter.resume = { continuation.resume(returning: $0) }
            lock.unlock()
            if let early { continuation.resume(returning: early) }
        }
    }

    // MARK: - Internals (exactly one resume per waiter: `send` and the timer race under the lock)

    private func take(_ waiter: Waiter) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let index = waiters.firstIndex(where: { $0 === waiter }) else { return false }
        waiters.remove(at: index)
        return true
    }

    private func deliver(_ waiter: Waiter, _ outcome: Bool) {
        lock.lock()
        let resume = waiter.resume
        if resume == nil { waiter.outcome = outcome }
        lock.unlock()
        resume?(outcome)
    }
}

/// A scripted WebSocket transport. The test decides what the server says and when the socket
/// dies; `sent` records every frame the client wrote (so the authentication challenge and pings
/// are assertable without a server).
final class ScriptedSocketTransport: SocketTransport, @unchecked Sendable {

    /// Every frame the client writes, and the running count — ("the second ping" is then a signal,
    /// not a poll of `sent.count`).
    let sentSignal = TestSignal<String>()
    let sentCountSignal = TestSignal<Int>()
    /// Every close the client asked for, with the running count.
    let closeSignal = TestSignal<Int>()

    let events: AsyncStream<SocketTransportEvent>
    private let continuation: AsyncStream<SocketTransportEvent>.Continuation
    private let lock = NSLock()
    private var frames: [String] = []
    private var closes = 0
    private var finished = false
    private var pongSeq = 1
    private var pongs = 0
    /// Answer every `ping` the client writes with the protocol's pong reply.
    ///
    /// This is the "open and pingable, delivering nothing" shape the delivery watchdog exists for
    /// (`SocketClient.StallWatchdog`): the socket proves it is alive on every heartbeat and carries no
    /// server event. Set it before the client starts.
    var answersPingsWithPong = false

    init(answersPingsWithPong: Bool = false) {
        self.answersPingsWithPong = answersPingsWithPong
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
        let count = frames.count
        var reply: String?
        if answersPingsWithPong, text.contains("\"action\":\"ping\"") {
            pongs += 1
            reply = Self.reply(seq: pongSeq, text: "pong")
            pongSeq += 1
        }
        lock.unlock()
        sentSignal.send(text)
        sentCountSignal.send(count)
        // Answered outside the lock (`push` takes it again): the pong travels back through the same
        // event stream a real socket's would.
        if let reply { push(.text(reply)) }
    }

    /// How many pong replies this transport answered — the proof that "pingable" was exercised.
    var pongsAnswered: Int {
        lock.lock()
        defer { lock.unlock() }
        return pongs
    }

    func close() {
        lock.lock()
        closes += 1
        let count = closes
        lock.unlock()
        closeSignal.send(count)
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

    /// Fires with the running count of transports handed out, so "the second connection" is a
    /// signal rather than a poll of `created.count`.
    let createdSignal = TestSignal<Int>()

    init(_ transports: [ScriptedSocketTransport]) {
        self.remaining = transports
    }

    func make(_ url: URL, _ headers: [String: String]) -> SocketTransport {
        lock.lock()
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
        let count = created.count
        lock.unlock()
        createdSignal.send(count)
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
    private var releaseTargets = 0

    /// Every sleep the client asked for, with the running count, plus the delay itself. A test can
    /// therefore await "a 0.5 s backoff was requested" or "the next sleep is parked" without
    /// polling `requestedDelays`.
    let sleepSignal = TestSignal<Int>()
    let delaySignal = TestSignal<TimeInterval>()
    /// Fires with the running count of *parked* sleeps (only when `autoRelease` is false).
    let parkedSignal = TestSignal<Int>()
    private var parkedCount = 0

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
        let delayCount = delays.count
        let shouldWait = !autoRelease
        lock.unlock()
        sleepSignal.send(delayCount)
        delaySignal.send(seconds)
        guard shouldWait else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                waiters.append(continuation)
                parkedCount += 1
                let count = parkedCount
                lock.unlock()
                parkedSignal.send(count)
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

    /// Release exactly one parked sleep, waiting until one is parked.
    ///
    /// This is the signal form of "release one tick": `release()` on its own is a no-op when the
    /// client has not reached its sleep yet, and a test that then waits for the effect burns its
    /// budget (measured as a 4.5 s-freeze red in `testHeartbeatTimeout…`, t_eccd49eb). Waiting for
    /// the park first removes the race; the 30 s is a hang detector.
    func releaseWhenParked(timeout: TimeInterval = 30) async -> Bool {
        lock.lock()
        releaseTargets += 1
        let target = releaseTargets
        lock.unlock()
        let parked = await parkedSignal.wait(until: { $0 >= target }, timeout: timeout)
        guard parked else { return false }
        release()
        return true
    }
}

/// A wall clock a test can move by hand. `SocketClient` measures how long a connection stayed up
/// to decide whether it was a session or a flap; without this the open-then-killed test would have
/// to sleep for real seconds.
final class TestNow: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// The closure `SocketClient(now:)` takes.
    var provider: @Sendable () -> Date {
        { self.now }
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// Collects a socket event stream so a test can assert on an ordered snapshot without racing the
/// consumer.
final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SocketEvent] = []
    private var finished = false

    /// Fires with the running count each time the consumer appends an event; "all 12 arrived" is
    /// then a signal rather than a poll of `count`.
    let appendedSignal = TestSignal<Int>()
    /// Fires once when the stream ends.
    let finishedSignal = TestSignal<Bool>()

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
        storage.append(event)
        let count = storage.count
        lock.unlock()
        appendedSignal.send(count)
    }

    func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
        finishedSignal.send(true)
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

    /// Await a value a fake recorded, with the 30 s hang detector. No clock, no latency budget:
    /// `TestSignal` returns as soon as the value exists, so a busy host cannot make this miss.
    func awaitSignal<Value>(_ what: String,
                            signal: TestSignal<Value>,
                            timeout: TimeInterval = 30,
                            file: StaticString = #filePath, line: UInt = #line,
                            until predicate: @escaping @Sendable (Value) -> Bool = { _ in true }) async {
        let matched = await signal.wait(until: predicate, timeout: timeout)
        XCTAssertTrue(matched, "timed out after \(Int(timeout))s waiting for \(what)",
                      file: file, line: line)
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
