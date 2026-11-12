import XCTest

/// TEMPORARY, for card t_a4e133f6 only - delete before landing.
///
/// Blocks the test thread far past the gate pass's execution-time allowance so that a
/// deliberate red gate leg produces the same thing a real hang does: an
/// "exceeded execution time allowance" line in the log, and (with
/// `-collect-test-diagnostics on-failure`) a result bundle whose diagnostics name the
/// wedged frame. Used to prove that the gate pass's bundle reaches the run's
/// `test-xcresult-<leg>` artifact; see docs/t_a4e133f6-build-note.md.
final class TGateHangFixtureTests: XCTestCase {
    func testDeliberateHangNamesThisFrame() throws {
        // A synchronous sleep, not a RunLoop spin: the spindump has to show a frame that
        // names this method, which is the property a real hang needs from the artifact.
        Thread.sleep(forTimeInterval: 900)
        XCTFail("TGateHangFixtureTests: the execution-time allowance did not fire")
    }
}
