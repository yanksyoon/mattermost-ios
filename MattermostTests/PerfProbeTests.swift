import XCTest
@testable import Mattermost

/// Unit tests for the T27 measurement seam's argument parsing (`PerfProbe.requested`).
///
/// These pin the two properties the harness depends on and that a reviewer cannot see from a
/// passing run:
///  - **inert by default** — a normal launch (no `-perfProbe`) never constructs a probe, so a
///    shipped Debug build does not measure anything by accident;
///  - **credentials never ride in argv** — `ps` shows every argument to every local user, so the
///    login id and password are read from the environment only, and an argument that looks like a
///    credential is ignored rather than honoured.
///
/// The probe itself is compiled under `#if DEBUG || PERF_PROBE`; the unit bundle builds in Debug,
/// so it is present here and compiled out of a Release binary (checked by the harness's Release
/// build, not by these tests).
@MainActor
final class PerfProbeTests: XCTestCase {

    func testInertWithoutTheProbeFlag() {
        XCTAssertNil(PerfProbe.requested(arguments: ["/path/Mattermost", "-uiTestResetPersistedState"],
                                         environment: [:]))
        XCTAssertNil(PerfProbe.requested(arguments: [], environment: [:]))
    }

    /// A flag at the end of argv with no value must not crash or produce a half-configured probe.
    func testTrailingFlagWithoutValueIsIgnored() {
        XCTAssertNil(PerfProbe.requested(arguments: ["Mattermost", "-perfProbe"], environment: [:]))
    }

    func testParsesEveryFlagTheHarnessPasses() {
        let arguments = [
            "Mattermost",
            "-perfProbe", "/tmp/run-dir",
            "-perfProbeMode", "native",
            "-perfProbeServer", "http://127.0.0.1:8065",
            "-perfProbeChannel", "perf-feed",
            "-perfProbeScrollSteps", "7",
            "-perfProbeBudget", "123",
        ]
        guard let config = PerfProbe.requested(arguments: arguments,
                                               environment: ["MM_PERF_LOGIN": "user@example.com",
                                                             "MM_PERF_PASSWORD": "hunter2"]) else {
            return XCTFail("a fully specified -perfProbe launch must parse")
        }
        XCTAssertEqual(config.directory.path, "/tmp/run-dir")
        XCTAssertEqual(config.mode, .native)
        XCTAssertEqual(config.serverURL?.absoluteString, "http://127.0.0.1:8065")
        XCTAssertEqual(config.channelName, "perf-feed")
        XCTAssertEqual(config.scrollSteps, 7)
        XCTAssertEqual(config.budget, 123, accuracy: 0.001)
        XCTAssertEqual(config.loginID, "user@example.com")
        XCTAssertEqual(config.password, "hunter2")
    }

    func testOnlyTheDirectoryIsRequired() {
        guard let config = PerfProbe.requested(arguments: ["Mattermost", "-perfProbe", "/tmp/x"],
                                               environment: [:]) else {
            return XCTFail("the directory is the only required argument")
        }
        XCTAssertEqual(config.mode, .web, "the default arm must be today's Path A: the webview")
        XCTAssertNil(config.serverURL, "shell mode is the 'no server at all' arm")
        XCTAssertEqual(config.channelName, "perf-feed")
        XCTAssertEqual(config.scrollSteps, 12)
        XCTAssertEqual(config.budget, 240, accuracy: 0.001)
        XCTAssertNil(config.loginID)
        XCTAssertNil(config.password)
    }

    /// `ps` exposes argv to every local user. A credential-looking argument must never become one.
    func testCredentialsAreNeverReadFromArguments() {
        let arguments = ["Mattermost", "-perfProbe", "/tmp/x",
                         "-perfProbeLogin", "leaked@example.com",
                         "-perfProbePassword", "leaked"]
        guard let config = PerfProbe.requested(arguments: arguments, environment: [:]) else {
            return XCTFail("probe must still parse")
        }
        XCTAssertNil(config.loginID, "login must come from MM_PERF_LOGIN, never from argv")
        XCTAssertNil(config.password, "password must come from MM_PERF_PASSWORD, never from argv")
    }

    /// A typo'd arm degrades to the web arm instead of measuring something unnamed.
    func testUnknownModeFallsBackToWeb() {
        let arguments = ["Mattermost", "-perfProbe", "/tmp/x", "-perfProbeMode", "nativ"]
        XCTAssertEqual(PerfProbe.requested(arguments: arguments, environment: [:])?.mode, .web)
    }

    func testAllThreeArmsParse() {
        for raw in ["web", "native", "shell"] {
            let arguments = ["Mattermost", "-perfProbe", "/tmp/x", "-perfProbeMode", raw]
            XCTAssertEqual(PerfProbe.requested(arguments: arguments, environment: [:])?.mode,
                           PerfProbe.Mode(rawValue: raw), "arm \(raw) must round-trip")
        }
    }

    func testTildeIsExpandedInTheRunDirectory() {
        guard let config = PerfProbe.requested(arguments: ["Mattermost", "-perfProbe", "~/perf-run"],
                                               environment: [:]) else {
            return XCTFail("probe must parse")
        }
        XCTAssertFalse(config.directory.path.hasPrefix("~"),
                       "the sampler and the app must agree on one absolute path")
        XCTAssertTrue(config.directory.path.hasSuffix("/perf-run"))
    }

    /// The non-numeric flags fall back rather than crashing the app on a typo.
    func testNonNumericNumbersFallBackToDefaults() {
        let arguments = ["Mattermost", "-perfProbe", "/tmp/x",
                         "-perfProbeScrollSteps", "twelve", "-perfProbeBudget", "soon"]
        guard let config = PerfProbe.requested(arguments: arguments, environment: [:]) else {
            return XCTFail("probe must parse")
        }
        XCTAssertEqual(config.scrollSteps, 12)
        XCTAssertEqual(config.budget, 240, accuracy: 0.001)
    }
}
