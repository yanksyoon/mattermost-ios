import Foundation
import XCTest
@testable import Mattermost

/// T44d regression guard for the defect that blocked the live call: `send(data:)` used to be
/// declared **only** in an extension of `protocol SocketTransport`, so `SocketClient.sendBinaryFrame`
/// — which calls it through `SocketTransport?` — statically dispatched to the extension default and
/// threw `binaryFramesUnsupported` for *every* conformer, including `WebSocketTransport` whose real
/// implementation was never reached. The live surface reported exactly that:
/// `offer: binaryFramesUnsupported` (`docs/t44d-build-note.md` §4.1).
///
/// These tests drive `SocketClient` itself (not a manager fake), because a fake that overrides
/// `sendBinaryFrame` wholesale — as the elsewhere-used calls fakes do — cannot see this bug.
final class T44DSocketBinarySendTests: XCTestCase {

    private let socketURL = URL(string: "wss://mm.example.com/api/v4/websocket")!

    /// A transport that implements the binary path for real, recording the frames it receives.
    private final class BinaryCapableTransport: SocketTransport, @unchecked Sendable {
        let events: AsyncStream<SocketTransportEvent>
        private let continuation: AsyncStream<SocketTransportEvent>.Continuation
        private let lock = NSLock()
        private var binaryFrames: [Data] = []
        private var textFrames: [String] = []

        init() {
            let (stream, continuation) = AsyncStream.makeStream(of: SocketTransportEvent.self,
                                                                bufferingPolicy: .bufferingNewest(64))
            self.events = stream
            self.continuation = continuation
        }

        var receivedBinary: [Data] {
            lock.lock(); defer { lock.unlock() }
            return binaryFrames
        }

        var receivedText: [String] {
            lock.lock(); defer { lock.unlock() }
            return textFrames
        }

        func resume() {}

        func send(text: String) async throws {
            lock.lock(); defer { lock.unlock() }
            textFrames.append(text)
        }

        func send(data: Data) async throws {
            lock.lock(); defer { lock.unlock() }
            binaryFrames.append(data)
        }

        func close() {
            continuation.yield(.closed(code: 1000, reason: nil))
            continuation.finish()
        }

        func push(_ event: SocketTransportEvent) {
            continuation.yield(event)
        }
    }

    private struct Harness {
        let client: SocketClient
        let transport: SocketTransport
        let box: EventBox
        let consumer: Task<Void, Never>
    }

    private func makeHarness(transport: SocketTransport) async -> Harness {
        let client = SocketClient(configuration: SocketClient.Configuration(
            url: socketURL,
            token: "tok-socket",
            origin: "https://mm.example.com",
            pingInterval: nil,
            backoff: SocketClient.Backoff(base: 1, factor: 2, maxDelay: 60, jitterRatio: 0)),
            transportFactory: { _, _ in transport },
            clock: TestSocketClock(autoRelease: true),
            random: { 0.5 })
        let stream = await client.subscribe()
        let box = EventBox()
        let consumer = box.consume(stream)
        await client.start()
        return Harness(client: client, transport: transport, box: box, consumer: consumer)
    }

    // MARK: - The fix

    /// The assertion that failed before the protocol requirement existed: the frame must arrive at
    /// the conformer's own `send(data:)`, not at the throwing extension default.
    func testBinaryFrameReachesTheTransportThatImplementsSendData() async throws {
        let transport = BinaryCapableTransport()
        let harness = await makeHarness(transport: transport)
        transport.push(.opened)
        await waitUntil("socket open") { await harness.client.state == .open }

        let frame = Data([0x81, 0xa4, 0x74, 0x65, 0x73, 0x74])  // msgpack-ish bytes; contents are opaque
        // The open path already wrote the auth challenge as *text*; only frames written after this
        // point are the binary send's business.
        let textFramesBefore = transport.receivedText.count
        try await harness.client.sendBinaryFrame(frame)

        XCTAssertEqual(transport.receivedBinary, [frame],
                       "the binary frame must reach the transport's own send(data:)")
        XCTAssertEqual(transport.receivedText.count, textFramesBefore,
                       "a binary frame must never be downgraded to a text frame")
        harness.consumer.cancel()
    }

    /// The default stays a hard failure on purpose: the Calls `sdp` action only exists on the binary
    /// path, so a text-only transport must fail loudly instead of pretending the call started.
    func testTextOnlyTransportStillFailsLoudly() async throws {
        let transport = ScriptedSocketTransport()  // does not implement send(data:)
        let harness = await makeHarness(transport: transport)
        transport.push(.opened)
        await waitUntil("socket open") { await harness.client.state == .open }

        do {
            try await harness.client.sendBinaryFrame(Data([0x00]))
            XCTFail("a transport with no binary path must not silently accept a binary frame")
        } catch let error as SocketTransportError {
            XCTAssertEqual(error, .binaryFramesUnsupported)
        }
        harness.consumer.cancel()
    }

    /// And the pre-existing guard: no open connection is `notConnected`, not a silent drop.
    func testBinaryFrameBeforeTheSocketOpensIsNotConnected() async throws {
        let transport = BinaryCapableTransport()
        let harness = await makeHarness(transport: transport)

        do {
            try await harness.client.sendBinaryFrame(Data([0x01]))
            XCTFail("expected notConnected")
        } catch let error as SocketTransportError {
            XCTAssertEqual(error, .notConnected)
        }
        XCTAssertTrue(transport.receivedBinary.isEmpty)
        harness.consumer.cancel()
    }
}
