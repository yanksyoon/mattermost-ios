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
///  - `clock` owns every sleep (backoff, heartbeat and the delivery watchdog);
///  - `random` drives jitter, so a test can assert exact delays;
///  - `resync` is a caller-supplied closure invoked **once** per reconnect *and* once per confirmed
///    delivery stall (see `StallWatchdog`), with the reason that made it fire;
///  - `isSurfaceVisible` is the caller's answer to "is anybody looking at data this socket feeds?",
///    which is the only thing that can tell an idle-but-healthy socket from a wedged one.
///
/// ## Two ways a gap happens, one repair
///
/// A WebSocket can lose frames in two ways the client can observe:
///  1. **the connection drops** — the run loop reconnects and `handleOpen` reports `.reconnected`;
///  2. **the connection stays up and stops delivering** — the server still answers the heartbeat
///     (`ping` → pong) and never closes, so nothing is reported at all. That is what the delivery
///     watchdog exists for: absence of server events is the only observable, and only a visible
///     surface makes it a fault.
///
/// Mattermost does not replay what it published while a frame was lost, so both are repaired the same
/// way: the caller refetches. Nothing in this file knows what a refetch means.
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

    /// Why a resync was requested. The caller refetches only what the reason implies — today the two
    /// reasons imply the same repair (a gap is a gap), and the reason exists so a log, a diagnostic and
    /// a future caller can tell a dropout from a stall.
    ///
    /// A heartbeat timeout deliberately reports **nothing** of its own: it recycles the connection and
    /// the reconnect that follows reports `.reconnected`. Asking for a resync at the timeout as well
    /// would refetch twice for one dropout (T28-AV finding F5).
    enum ResyncReason: String, Sendable, Equatable {
        /// The socket dropped and came back: anything could have changed while it was down.
        case reconnected
        /// The socket stayed open and kept answering the heartbeat but delivered no server event for
        /// the watchdog's window while a surface was visible (`StallWatchdog`). Nothing was reported by
        /// the transport because nothing happened to it: the frames simply did not arrive.
        case stalled
    }

    /// The idle-delivery watchdog: how an **open, pingable, silent** socket is noticed.
    ///
    /// A reconnect announces itself. A socket that keeps its TCP/WebSocket connection, still answers
    /// `ping` with a pong, and stops delivering server events announces nothing — `handleOpen` does not
    /// run again, so no resync fires and every frame the server publishes stays invisible. The only
    /// observable left is the *absence* of server events, and it is only a fault while somebody is
    /// looking at a surface that socket feeds. That is what this measures, and why the caller supplies
    /// `isSurfaceVisible`: the socket cannot know what is on screen, and must not guess.
    ///
    /// The numbers, and why:
    ///  * `threshold` **150 s** — five heartbeat intervals. A pong proves the socket is *pingable*, not
    ///    that it is *delivering* (that distinction is the whole card), so the window cannot be shorter
    ///    than the cadence that gives "silence" its meaning. It must also be long enough that an
    ///    ordinary quiet channel is not read as a fault — two minutes with nothing said is normal — and
    ///    short enough that a reader never sits in front of a stale window for more than about three
    ///    minutes (detection is at most `threshold + checkInterval`).
    ///  * `checkInterval` **30 s** — one heartbeat cadence: the same timer granularity the socket already
    ///    pays for, and it bounds detection latency at 3 min.
    ///  * `quietMultiplier` **4** — the wait doubles after each fire that is followed by more silence
    ///    (150 s → 300 s → 600 s, capped at 4× = 10 min) and any delivered server event resets it. A
    ///    socket silent for an hour is *not* more likely to be wedged than one silent for three
    ///    minutes, so an idle-but-visible pane does not pay a full warm-window sweep every 2.5 minutes
    ///    forever: at the cap it is ≤12 small requests per 10 minutes. The cost is a worst-case recovery
    ///    latency of 10 minutes on a wedge that begins after a long quiet spell — stated in
    ///    `docs/t34-socket-stall-watchdog-build-note.md` rather than hidden.
    struct StallWatchdog: Equatable, Sendable {
        var threshold: TimeInterval = 150
        var checkInterval: TimeInterval = 30
        var quietMultiplier: Double = 4
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

        /// The idle-delivery watchdog. `nil` disables it — the default, because a client built without
        /// an `isSurfaceVisible` predicate cannot judge visibility and must not pretend to. The caller
        /// that *can* answer (`SocketTeamEventSource`, from the app) turns it on by passing both.
        var stallWatchdog: StallWatchdog?

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
    /// The caller's answer to "is anybody looking at data this socket feeds right now?". `nil` means
    /// nobody can tell, which is why the watchdog does not start without it.
    private let isSurfaceVisible: (@Sendable () async -> Bool)?
    private let random: () -> Double
    /// Monotonic-ish wall clock used only to measure how long a connection stayed up. Injected so
    /// the open-then-killed ladder is testable without sleeping.
    private let now: @Sendable () -> Date

    private(set) var state: State = .idle
    /// Delays actually slept through, in order — the observable backoff sequence.
    private(set) var retryDelays: [TimeInterval] = []
    /// How many times the client asked for a resync: once per reconnect, plus once per delivery stall
    /// the watchdog confirmed.
    private(set) var resyncCount = 0
    /// The `.stalled` subset of `resyncCount` — how many gaps were found by silence rather than by a
    /// dropped connection. The two are counted apart because they are repaired the same way but mean
    /// different things about the connection.
    private(set) var stallResyncCount = 0
    /// Pong replies the server answered. The heartbeat's liveness proof, and deliberately **not**
    /// delivery: a socket can answer every ping and carry no event, which is the state the watchdog
    /// exists for.
    private(set) var pongCount = 0
    /// Events delivered to subscribers (after duplicate suppression).
    private(set) var deliveredEventCount = 0
    /// Events dropped as duplicates — an event identity that cannot legitimately recur, seen
    /// again after a reconnect (a replayed post revision or hello).
    private(set) var duplicateEventCount = 0

    private var subscribers: [UUID: AsyncStream<SocketEvent>.Continuation] = [:]
    private var runTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var stallWatchdogTask: Task<Void, Never>?
    private var currentTransport: SocketTransport?
    private var stopped = false
    private var hasOpenedOnce = false
    private var serverSequence = 0
    private var responseSequence = 1
    private var missedPongs = 0
    /// When the last **server event** was delivered — never a pong, never a `seq_reply`. The delivery
    /// watchdog's clock.
    private var lastServerEventAt: Date
    /// How much longer than `StallWatchdog.threshold` to wait, after a fire that silence followed.
    private var stallQuietMultiplier: Double = 1
    /// Bounded, order-preserving record of delivered event identities for cross-reconnect dedupe.
    private var recentKeys: [String] = []
    private let dedupeWindow = 512

    init(configuration: Configuration,
         transportFactory: @escaping (URL, [String: String]) -> SocketTransport,
         clock: SocketClock = SystemSocketClock(),
         random: @escaping () -> Double = { Double.random(in: 0..<1) },
         now: @escaping @Sendable () -> Date = { Date() },
         resync: (@Sendable (ResyncReason) async -> Void)? = nil,
         isSurfaceVisible: (@Sendable () async -> Bool)? = nil) {
        self.configuration = configuration
        self.transportFactory = transportFactory
        self.clock = clock
        self.random = random
        self.now = now
        self.resync = resync
        self.isSurfaceVisible = isSurfaceVisible
        self.lastServerEventAt = now()
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
        stallWatchdogTask?.cancel()
        stallWatchdogTask = nil
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

    /// Send one already-encoded **text** frame verbatim.
    ///
    /// Plugin actions build their own envelope (`action` + `seq` + plugin-shaped `data`), which the
    /// socket must not reinterpret. The binary sibling is `sendBinaryFrame(_:)`.
    func sendTextFrame(_ text: String) async throws {
        guard let transport = currentTransport, state == .open else {
            throw SocketTransportError.notConnected
        }
        try await transport.send(text: text)
    }

    /// Send one already-encoded **binary** frame verbatim.
    ///
    /// The one caller today is Calls' `sdp` action, and it is the reason this method exists: the
    /// plugin type-asserts `req.Data["data"]` to `[]byte`, which the core server can only produce
    /// from a MessagePack frame — a JSON text frame is dropped server-side
    /// (`docs/t44-build-note.md` §5.1, measured). The frame's own `seq`/`action` are built by the
    /// caller because they are the caller's protocol, not the socket's.
    ///
    /// Throws when there is no open connection or the transport has no binary path, so a caller can
    /// surface "the call could not be signalled" instead of waiting out the plugin's 10 s timeout.
    func sendBinaryFrame(_ frame: Data) async throws {
        guard let transport = currentTransport, state == .open else {
            throw SocketTransportError.notConnected
        }
        try await transport.send(data: frame)
        MMLog.debug("MMSocket", "sent binary frame (\(frame.count) bytes)")
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
            stopStallWatchdog()
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
        // The watchdog's window starts at the open, not after the refetch: the reconnect's own resync can
        // take a moment, and the silence it repairs must not be counted twice.
        lastServerEventAt = now()
        stallQuietMultiplier = 1
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
        startStallWatchdog()
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
                // Evidence for the log and for tests, and **not** a delivery: the watchdog's clock is
                // deliberately untouched here. A socket that answers pings and carries no event is
                // exactly the state it is looking for.
                pongCount += 1
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
        // A delivered server event is the watchdog's clock: this is the one thing that proves the
        // socket is still *carrying* events (a pong above proved only that it is pingable).
        lastServerEventAt = now()
        stallQuietMultiplier = 1
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

    // MARK: - Delivery watchdog

    /// Start the idle-delivery watchdog for this connection.
    ///
    /// Not started when the caller configured no watchdog *or* supplied no `isSurfaceVisible`: without
    /// an answer to "is anyone looking?", a silent socket is indistinguishable from an idle one, and a
    /// timer that can only guess is worse than none. `SocketTeamEventSource` logs that state when it
    /// builds such a client, because it is the shape that shipped silently once already.
    private func startStallWatchdog() {
        guard let watchdog = configuration.stallWatchdog,
              isSurfaceVisible != nil,
              stallWatchdogTask == nil else { return }
        let clock = self.clock
        stallWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                await clock.sleep(for: watchdog.checkInterval)
                if Task.isCancelled { return }
                guard let self else { return }
                let keepGoing = await self.stallWatchdogTick(watchdog)
                if !keepGoing { return }
            }
        }
    }

    private func stopStallWatchdog() {
        stallWatchdogTask?.cancel()
        stallWatchdogTask = nil
    }

    /// One check. Returns `false` when the loop should end (the connection is gone).
    ///
    /// Three conditions, all required: the connection is open, no server event has been delivered for
    /// the window, and a surface is visible. The visibility check comes **last** and on purpose — it is
    /// an app-level question (a hop), and it only has to be asked when the silence already looks wrong.
    private func stallWatchdogTick(_ watchdog: StallWatchdog) async -> Bool {
        guard state == .open, let isSurfaceVisible else { return false }
        let threshold = watchdog.threshold * stallQuietMultiplier
        guard now().timeIntervalSince(lastServerEventAt) >= threshold else { return true }
        // Nothing on screen: an idle-but-healthy socket is not a fault, and a backgrounded app must not
        // spend a page fetch proving it. Nothing is marked, so the next tick asks again.
        guard await isSurfaceVisible() else { return true }

        // Re-arm *before* asking for the resync: a refetch that fails or is slow must not put the
        // watchdog into a fire-every-tick loop, and a socket that stays silent is re-checked at the
        // doubled wait rather than at the base one.
        lastServerEventAt = now()
        stallQuietMultiplier = min(stallQuietMultiplier * 2, max(1, watchdog.quietMultiplier))
        stallResyncCount += 1
        resyncCount += 1
        MMLog.info("MMSocket", "no server event for \(Int(threshold))s on an open socket "
            + "(\(pongCount) pongs answered); treating it as a delivery gap and requesting a resync")
        await resync?(.stalled)
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

    /// `URLSessionWebSocketTask.send(.data:)` — the frame reaches the server as opcode 0x2, which is
    /// what the core socket's msgpack decoder expects (`web_conn.go` branches on `msgType`).
    func send(data: Data) async throws {
        try await task.send(.data(data))
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
