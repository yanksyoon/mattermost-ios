import Foundation

/// The WebSocket v4 client: connect, authenticate, keep alive, reconnect with backoff, resync,
/// and publish a typed event stream.
///
/// Protocol contract implemented (https://api.mattermost.com, "WebSocket"):
///  - the socket lives at `<server>/api/v4/websocket`; it can be authenticated with an
///    `Authorization` header **or** by sending an `authentication_challenge` action after connect —
///    this client does both, because a self-hosted reverse proxy occasionally strips the upgrade
///    header while the in-band challenge keeps working;
///  - a `hello` event is the first server event of a connection;
///  - `status: "OK"` / `"FAIL"` replies carry `seq_reply`, and a pong is
///    `{"status":"OK","seq_reply":N,"data":{"text":"pong"}}`.
///
/// Everything that makes the client hard to test is injected:
///  - `transportFactory` produces a fresh transport per connection attempt;
///  - `clock` owns every sleep (backoff and heartbeat);
///  - `random` drives jitter, so a test can assert exact delays;
///  - `resync` is a caller-supplied closure invoked **once** per reconnect.
actor SocketClient {

    struct Backoff: Equatable, Sendable {
        var base: TimeInterval = 1
        var factor: Double = 2
        var maxDelay: TimeInterval = 60
        /// ±fraction applied to each delay (0 disables jitter).
        var jitterRatio: Double = 0.2

        func delay(forAttempt attempt: Int, random: Double) -> TimeInterval {
            let exponential = base * pow(factor, Double(max(0, attempt - 1)))
            let capped = min(exponential, maxDelay)
            let offset = capped * jitterRatio * (random * 2 - 1)
            return max(0, capped + offset)
        }
    }

    enum State: Equatable, Sendable {
        case idle
        case connecting
        case open
        case closed
    }

    /// Why a resync was requested. The caller refetches only what the reason implies.
    ///
    /// There is exactly one reason today, on purpose: a heartbeat timeout also recycles the
    /// connection, and the reconnect that follows reports `.reconnected`. Asking for a resync at
    /// the timeout *as well* would refetch twice for one dropout (T28-AV finding F5).
    enum ResyncReason: String, Sendable {
        /// The socket dropped and came back: anything could have changed while it was down.
        case reconnected
    }

    struct Configuration: Sendable {
        var url: URL
        var token: String?
        var preauthSecret: String?
        var origin: String?
        /// `nil` disables the heartbeat (tests that do not exercise it).
        var pingInterval: TimeInterval? = 30
        /// Missed pongs tolerated before the connection is recycled (mobile: 1).
        var maxMissedPongs: Int = 1
        var backoff = Backoff()
        /// How long a connection must stay up before it counts as a *real* session and resets the
        /// backoff ladder. A server that accepts the upgrade and closes immediately never reaches
        /// it, so repeated kills keep escalating instead of hammering at the base delay.
        var stableSessionInterval: TimeInterval = 5

        /// Handshake headers. `origin` matters: the server rejects an upgrade without it.
        /// The bearer token rides here **and** in the in-band `authentication_challenge` frame;
        /// some reverse proxies strip upgrade headers and the challenge keeps those working.
        /// This dictionary is never logged (it is handed straight to the transport factory).
        var headers: [String: String] {
            var headers = ["X-Requested-With": "XMLHttpRequest"]
            if let origin, !origin.isEmpty { headers["Origin"] = origin }
            if let preauthSecret, !preauthSecret.isEmpty {
                headers["X-Mattermost-Preauth-Secret"] = preauthSecret
            }
            if let token, !token.isEmpty {
                headers["Authorization"] = "Bearer \(token)"
            }
            return headers
        }
    }

    private let configuration: Configuration
    private let transportFactory: (URL, [String: String]) -> SocketTransport
    private let clock: SocketClock
    private let resync: (@Sendable (ResyncReason) async -> Void)?
    private let random: () -> Double
    /// Monotonic-ish wall clock used only to measure how long a connection stayed up. Injected so
    /// the open-then-killed ladder is testable without sleeping.
    private let now: @Sendable () -> Date

    private(set) var state: State = .idle
    /// Delays actually slept through, in order — the observable backoff sequence.
    private(set) var retryDelays: [TimeInterval] = []
    /// How many times a reconnect triggered a resync.
    private(set) var resyncCount = 0
    /// Events delivered to subscribers (after duplicate suppression).
    private(set) var deliveredEventCount = 0
    /// Events dropped as duplicates — an event identity that cannot legitimately recur, seen
    /// again after a reconnect (a replayed post revision or hello).
    private(set) var duplicateEventCount = 0

    private var subscribers: [UUID: AsyncStream<SocketEvent>.Continuation] = [:]
    private var runTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var currentTransport: SocketTransport?
    private var stopped = false
    private var hasOpenedOnce = false
    private var serverSequence = 0
    private var responseSequence = 1
    private var missedPongs = 0
    /// Bounded, order-preserving record of delivered event identities for cross-reconnect dedupe.
    private var recentKeys: [String] = []
    private let dedupeWindow = 512

    init(configuration: Configuration,
         transportFactory: @escaping (URL, [String: String]) -> SocketTransport,
         clock: SocketClock = SystemSocketClock(),
         random: @escaping () -> Double = { Double.random(in: 0..<1) },
         now: @escaping @Sendable () -> Date = { Date() },
         resync: (@Sendable (ResyncReason) async -> Void)? = nil) {
        self.configuration = configuration
        self.transportFactory = transportFactory
        self.clock = clock
        self.random = random
        self.now = now
        self.resync = resync
    }

    // MARK: - Lifecycle

    /// Start the connect/receive/reconnect loop. Idempotent.
    func start() {
        guard runTask == nil else { return }
        stopped = false
        runTask = Task { [weak self] in
            await self?.run()
        }
    }

    /// Stop for good: closes the socket, cancels timers, finishes every subscriber stream.
    func stop() {
        stopped = true
        heartbeatTask?.cancel()
        heartbeatTask = nil
        currentTransport?.close()
        currentTransport = nil
        runTask?.cancel()
        runTask = nil
        state = .idle
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    /// A fresh typed event stream. Multiple subscribers are supported (the store and, later,
    /// per-screen observers); oldest events are dropped when a subscriber falls 256 behind.
    func subscribe() -> AsyncStream<SocketEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: SocketEvent.self,
                                                            bufferingPolicy: .bufferingNewest(256))
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    // MARK: - Outbound actions

    func sendTyping(channelID: String, parentID: String? = nil) async {
        var data: [String: Any] = ["channel_id": channelID]
        if let parentID, !parentID.isEmpty { data["parent_id"] = parentID }
        await send(action: "user_typing", data: data)
    }

    func ping() async {
        await send(action: "ping", data: nil)
    }

    private func send(action: String, data: [String: Any]?) async {
        var frame: [String: Any] = ["action": action, "seq": responseSequence]
        responseSequence += 1
        if let data { frame["data"] = data }
        guard JSONSerialization.isValidJSONObject(frame),
              let payload = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: payload, encoding: .utf8) else {
            MMLog.error("MMSocket", "could not encode \(action) frame")
            return
        }
        do {
            try await currentTransport?.send(text: text)
            MMLog.debug("MMSocket", "sent \(action) seq \(frame["seq"] ?? 0)")
        } catch {
            MMLog.debug("MMSocket", "send \(action) failed: \(type(of: error))")
            currentTransport?.close()
        }
    }

    // MARK: - Connect / reconnect loop

    private func run() async {
        var attempt = 0
        while !stopped {
            state = .connecting
            serverSequence = 0
            var openedAt: Date?
            let transport = transportFactory(configuration.url, configuration.headers)
            currentTransport = transport
            transport.resume()

            var connectionEnded = false
            for await event in transport.events {
                switch event {
                case .opened:
                    // Deliberately does NOT reset the ladder here: a server that accepts the
                    // upgrade and closes at once would otherwise be reconnected at the base delay
                    // forever (T28-AV finding F2). The reset happens below, once the connection
                    // has proven it was a real session.
                    openedAt = now()
                    await handleOpen()
                case .text(let text):
                    handle(frameText: text)
                case .closed, .failed:
                    connectionEnded = true
                }
                if connectionEnded || stopped { break }
            }

            stopHeartbeat()
            currentTransport = nil
            if stopped { break }
            state = .closed

            if let openedAt,
               now().timeIntervalSince(openedAt) >= configuration.stableSessionInterval {
                // The connection lived long enough to be a session, not a flap: start over.
                attempt = 0
            }

            attempt += 1
            let delay = configuration.backoff.delay(forAttempt: attempt, random: random())
            retryDelays.append(delay)
            MMLog.info("MMSocket", "connection lost; attempt \(attempt) in "
                + "\(String(format: "%.2f", delay))s")
            await clock.sleep(for: delay)
        }
        state = stopped ? .idle : state
    }

    private func handleOpen() async {
        state = .open
        missedPongs = 0
        serverSequence = 0
        MMLog.debug("MMSocket", "socket open")

        // In-band auth (plus the Authorization header when the factory was given a token); the
        // server ignores a duplicate challenge on a cookie-authenticated socket.
        if let token = configuration.token, !token.isEmpty {
            await send(action: "authentication_challenge", data: ["token": token])
        }

        let isReconnect = hasOpenedOnce
        hasOpenedOnce = true
        if isReconnect {
            resyncCount += 1
            MMLog.info("MMSocket", "reconnected; requesting resync")
            await resync?(.reconnected)
        }
        startHeartbeat()
    }

    // MARK: - Inbound frames

    private func handle(frameText: String) {
        guard let data = frameText.data(using: .utf8),
              let frame = try? JSONDecoder().decode(MMSocketFrame.self, from: data) else {
            MMLog.debug("MMSocket", "dropped unparseable frame")
            return
        }

        if let seqReply = frame.seqReply {
            if frame.status == "FAIL" {
                MMLog.debug("MMSocket", "server rejected action seq \(seqReply): "
                    + "\(frame.errorMessage ?? "no message")")
            } else if frame.data?["text"]?.stringValue == "pong" {
                missedPongs = 0
            }
            return
        }

        guard let event = SocketEvent(frame: frame) else {
            MMLog.debug("MMSocket", "dropped undecodable \(frame.event) event")
            return
        }

        // Sequence gate for *this* connection: seq restarts per connection, so a value at or
        // below the last one we consumed is a replay and is dropped before delivery.
        if let seq = frame.seq {
            if seq <= serverSequence { return }
            serverSequence = seq
        }

        if let key = event.dedupeKey {
            if recentKeys.contains(key) {
                duplicateEventCount += 1
                MMLog.debug("MMSocket", "dropped duplicate \(event.name) (replayed after reconnect)")
                return
            }
            recentKeys.append(key)
            if recentKeys.count > dedupeWindow {
                recentKeys.removeFirst(recentKeys.count - dedupeWindow)
            }
        }

        deliveredEventCount += 1
        for continuation in subscribers.values { continuation.yield(event) }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        guard let interval = configuration.pingInterval,
              heartbeatTask == nil else { return }
        let clock = self.clock
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                await clock.sleep(for: interval)
                if Task.isCancelled { return }
                guard let self else { return }
                let keepGoing = await self.heartbeatTick()
                if !keepGoing { return }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// Returns `false` when the loop should end (the connection was recycled).
    private func heartbeatTick() async -> Bool {
        guard state == .open else { return false }
        if missedPongs >= configuration.maxMissedPongs {
            MMLog.info("MMSocket", "heartbeat timeout; recycling connection")
            // No resync here: recycling closes the transport, the run loop reconnects, and the
            // reconnect reports `.reconnected` once. Resyncing at the timeout too would refetch
            // twice for a single dropout (T28-AV finding F5).
            heartbeatTask?.cancel()
            heartbeatTask = nil
            currentTransport?.close()
            return false
        }
        missedPongs += 1
        await send(action: "ping", data: nil)
        return true
    }
}

/// `URLSessionWebSocketTask` transport. The session carries `TransportSessionDelegate`, so the
/// `wss` handshake consults the same `CertTrust` bag as REST and the webview.
final class WebSocketTransport: SocketTransport, @unchecked Sendable {

    let events: AsyncStream<SocketTransportEvent>
    private let continuation: AsyncStream<SocketTransportEvent>.Continuation
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private let delegate: TransportSessionDelegate
    private let lock = NSLock()
    private var finished = false

    init(url: URL,
         headers: [String: String],
         serverURL: URL,
         certTrust: CertTrust = CertTrust(),
         onUntrustedCertificate: ((CertificatePrompt) -> Void)? = nil,
         configuration: URLSessionConfiguration = URLSessionTransport.defaultConfiguration()) {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        var socketConfiguration = configuration
        // A WebSocket is long-lived: the default resource timeout would tear down a healthy
        // connection after a minute of quiet.
        socketConfiguration.timeoutIntervalForResource = 60 * 60 * 24 * 7
        let delegate = TransportSessionDelegate(serverURL: serverURL,
                                                certTrust: certTrust,
                                                onUntrustedCertificate: onUntrustedCertificate)
        self.delegate = delegate
        self.session = URLSession(configuration: socketConfiguration, delegate: delegate, delegateQueue: nil)
        self.task = session.webSocketTask(with: request)
        let (stream, continuation) = AsyncStream.makeStream(of: SocketTransportEvent.self,
                                                            bufferingPolicy: .bufferingNewest(256))
        self.events = stream
        self.continuation = continuation

        let weakSelf = WeakTransportBox(self)
        delegate.onWebSocketOpen = { _ in weakSelf.value?.yield(.opened) }
        delegate.onWebSocketClose = { _, code, reason in
            let text = reason.flatMap { String(data: $0, encoding: .utf8) }
            weakSelf.value?.yield(.closed(code: code.rawValue, reason: text))
            weakSelf.value?.finish()
        }
    }

    deinit {
        session.invalidateAndCancel()
    }

    func resume() {
        task.resume()
        receiveNext()
    }

    private func receiveNext() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                self.yield(.text(text))
                self.receiveNext()
            case .success(.data(let data)):
                self.yield(.text(String(decoding: data, as: UTF8.self)))
                self.receiveNext()
            case .failure(let error):
                let nsError = error as NSError
                // `NSURLErrorNetworkConnectionLost` / socket cancellation are ordinary closes.
                if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                    self.yield(.closed(code: 1000, reason: nil))
                } else {
                    self.yield(.failed(nsError.localizedDescription))
                }
                self.finish()
            }
        }
    }

    func send(text: String) async throws {
        try await task.send(.string(text))
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        finish()
    }

    private func yield(_ event: SocketTransportEvent) {
        lock.lock()
        let closed = finished
        lock.unlock()
        guard !closed else { return }
        continuation.yield(event)
    }

    private func finish() {
        lock.lock()
        let already = finished
        finished = true
        lock.unlock()
        guard !already else { return }
        continuation.finish()
    }
}

/// Holds the transport weakly for the delegate callbacks (`URLSession` retains the delegate, so a
/// strong capture here would form a cycle transport → session → delegate → transport).
private final class WeakTransportBox {
    weak var value: WebSocketTransport?
    init(_ value: WebSocketTransport) { self.value = value }
}
