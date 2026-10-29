// T44c — the production teardown scheduler, on its own.
//
// `T44CCallsEngineTests.testStopFinishesWhileLibwebrtcCloseIsHeldOpen` injects a scheduler that
// accepts the close and never runs it, so it pins the *contract* between the engine and the seam —
// and nothing about the object production actually uses: making `CallsMediaTeardownQueue.schedule`
// run `work()` inline (the pre-fix wedge, in shipped code) left the whole engine class green
// (kanban t_5bf7a812, finding 1). The three properties that un-wedge a call are pinned here, one
// test each:
//
//  * `schedule` returns before the close it was handed finishes — the engine's executor is never
//    inside libwebrtc's blocking `close()`;
//  * the queue is **concurrent**, so one close that never returns cannot queue a later call's
//    teardown behind it;
//  * a close still running at the deadline is **reported** (`has not returned after …`) — the only
//    visibility there is, since libwebrtc offers no cancellation for a blocking `close()`.
//
// No clock is polled: the deadline is injectable (`CallsMediaTeardownQueue(warnAfter:)`, 10 s in
// production) and every event — including the report — is a `TestSignal` the test awaits.

import Foundation
import XCTest
@testable import Mattermost

final class T44CCallsMediaTeardownQueueTests: XCTestCase {

    // MARK: - schedule is not the caller's thread

    /// Inline (the pre-fix shape, and the mutation in the card's evidence) `schedule` returns only
    /// after the immediate `close()` — measured here as a 2 s close, so "returned in under a
    /// second" is not a latency budget but a statement about *whose thread* ran the work.
    func testScheduleReturnsBeforeTheCloseItWasHandedFinishes() async {
        let queue = CallsMediaTeardownQueue()
        let entered = TestSignal<Bool>()
        let finished = TestSignal<Bool>()
        let closeDuration: TimeInterval = 2

        let returnedAt = Date()
        queue.schedule {
            entered.send(true)
            Thread.sleep(forTimeInterval: closeDuration)
            finished.send(true)
        }
        let elapsed = Date().timeIntervalSince(returnedAt)

        XCTAssertLessThan(elapsed, 1, """
            `schedule` returned after \(String(format: "%.2f", elapsed))s: the close ran on the \
            caller's thread instead of being handed to the teardown queue (an inline close takes \
            \(Int(closeDuration))s)
            """)
        XCTAssertTrue(finished.recorded.isEmpty,
                     "`schedule` returned before the close it was handed finished")

        // ...and the work is not merely skipped: it runs, on the queue, and completes.
        await awaitSignal("the teardown work to start", signal: entered, timeout: 10)
        await awaitSignal("the teardown work to finish", signal: finished, timeout: 10)
    }

    // MARK: - one wedged close does not queue the next call's close

    /// A serial queue looks identical from the outside until two closes overlap: the first is held
    /// past the deadline, and the second must still run while it is held. The report for the held
    /// close is awaited from the log sink, so the "10 s report" is exercised without a 10 s wait.
    func testOneHeldCloseDoesNotHoldUpTheNextCallsClose() async {
        // 1 s keeps the report observable inside a test and still prints as "after 1s".
        let queue = CallsMediaTeardownQueue(warnAfter: 1)
        let logs = LogSignal()
        defer { logs.stop() }

        let firstEntered = TestSignal<Bool>()
        let firstFinished = TestSignal<Bool>()
        let secondRan = TestSignal<Bool>()
        let release = DispatchSemaphore(value: 0)

        queue.schedule {
            firstEntered.send(true)
            // Bounded: if `schedule` runs the work inline (the mutation this test must catch) the
            // run reports red on the missing report below instead of hanging the suite here.
            _ = release.wait(timeout: .now() + 15)
            firstFinished.send(true)
        }
        queue.schedule { secondRan.send(true) }

        await awaitSignal("the first close to start", signal: firstEntered, timeout: 10)

        // Serial queue: this cannot fire until the first close is released below, so the test reds
        // on the hang detector instead of passing.
        await awaitSignal("the second call's close while the first one is still held",
                          signal: secondRan, timeout: 10)

        // The wedge is reported while it is still in flight (1 s deadline; 10 s hang detector).
        await awaitSignal("the \"has not returned\" report for the held close",
                          signal: logs.signal, timeout: 10) { $0.contains("has not returned") }

        release.signal()
        await awaitSignal("the held close to finish once released", signal: firstFinished, timeout: 10)

        let reports = logs.signal.recorded.filter { $0.contains("has not returned") }
        XCTAssertEqual(reports.count, 1, "the held close is reported exactly once")
        let report = reports.first ?? ""
        XCTAssertTrue(report.contains("MMCalls: libwebrtc close() has not returned after 1s"),
                      "the report names the category, the fact and the deadline: \(report)")
        XCTAssertTrue(report.contains("the engine is not blocked by it"),
                      "the report says what the deadline means: \(report)")
    }

    // MARK: - Observing the report

    /// Every line the app would send to `os_log`, forwarded into a `TestSignal` so the wedge report
    /// is awaited like any other event rather than polled for. Restores the previous sink on `stop`,
    /// exactly like `LogCapture` (T31) — the sink is global, so a test that installs one owns it for
    /// its duration.
    private final class LogSignal: @unchecked Sendable {
        let signal = TestSignal<String>()
        private let previous: ((String) -> Void)?

        init() {
            let previous = Logger.testSink
            self.previous = previous
            let signal = self.signal
            Logger.testSink = { line in
                previous?(line)
                signal.send(line)
            }
        }

        func stop() {
            Logger.testSink = previous
        }
    }
}
