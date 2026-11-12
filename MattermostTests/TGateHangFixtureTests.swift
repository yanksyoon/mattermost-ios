import XCTest

/// A deliberate hang, so that the gate pass's result bundle can be proven to carry a hang
/// sample (t_a4e133f6).
///
/// On run 43240373846 the gate pass hung for its whole 300 s allowance and wrote
/// `Test-Mattermost-2026.11.12_14-47-40-+0000.xcresult` - the bundle that holds the
/// spindump naming the wedged frame - and that bundle never reached the run's
/// `test-xcresult-ios-simulator` artifact. The workflow now gives each pass its own
/// `-resultBundlePath`, but a change like that is only worth trusting if a red gate leg
/// can be produced on demand and the artifact read back.
///
/// This case is that demand. It does nothing on any normal run: it is skipped unless
/// `MATTERMOST_GATE_HANG_FIXTURE` is "1" in the test process, which the workflow sets only
/// from the `self_test_gate_hang` dispatch input (`.github/workflows/release.yml`). With the
/// flag set it blocks this thread past the pass's execution-time allowance, so XCTest writes
/// the same diagnostic a real hang writes: an "exceeded execution time allowance" line in the
/// log and a result bundle whose hang sample names `testDeliberateHangNamesThisFrame`.
///
/// Usage, on a run that is the tip of `main` (the guard skips the test legs otherwise):
///
///     gh workflow run release.yml --ref main -f self_test_gate_hang=true
///
/// Expected result: both legs red on this case, and
/// `test-xcresult-<leg>` holding `gate-<leg>.xcresult`, which
/// `xcrun xcresulttool export diagnostics` reports a hang for. See
/// `docs/t_a4e133f6-build-note.md` for the proving run.
final class TGateHangFixtureTests: XCTestCase {
    /// The switch, in the two spellings it can arrive in: xcodebuild hands `TEST_RUNNER_`-prefixed
    /// variables to a simulator test runner (the prefix is what makes them cross that boundary and
    /// is stripped on the way), while a macOS/Catalyst test process simply inherits the shell's
    /// environment with the prefix intact. Reading both means the switch cannot silently do
    /// nothing on one leg.
    static let environmentKeys = ["MATTERMOST_GATE_HANG_FIXTURE", "TEST_RUNNER_MATTERMOST_GATE_HANG_FIXTURE"]

    static var isEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environmentKeys.contains { environment[$0] == "1" }
    }

    func testDeliberateHangNamesThisFrame() throws {
        try XCTSkipUnless(
            Self.isEnabled,
            "not a gate-hang self-test run (set TEST_RUNNER_MATTERMOST_GATE_HANG_FIXTURE=1, or "
            + "dispatch release.yml with self_test_gate_hang=true, to make this case hang on purpose)"
        )
        // A synchronous sleep, not a RunLoop spin: the spindump has to show a frame that
        // names this method, which is the property a real hang needs from the artifact.
        Thread.sleep(forTimeInterval: 900)
        XCTFail("TGateHangFixtureTests: the execution-time allowance did not fire")
    }
}
