import Foundation
import WebKit
import XCTest
@testable import Mattermost

// t_a5321d5e — the hang detector that bounds a WebKit `await`.
//
// Why these controls exist: the T31 cookie case (`T31-AuthTests
// .testClearingTheAuthCookieRemovesOnlyThisServersSessionCookie`) was rewritten to await every WebKit
// call through `withWebKitAnswer` after run 43240373846 hung it for the whole 300 s allowance. A
// bounded wait that has never been shown to fire is just a comment, so the two things that matter
// are proven here without WebKit:
//
//   1. an answer that arrives is returned **at its own cost** — the detector is not a latency
//      budget, and a fast call is not delayed to the window;
//   2. a call that never comes back is reported after the window, naming the call, instead of
//      hanging the case; and reached through `requireWebKitAnswer` it is a **skip**, not a failure
//      (a host without WebKit is not a product statement — the rule CertTrustTests keeps for a host
//      without a Keychain entitlement).
//
// The real-store half — that the T31 case still asserts its claim whenever WebKit answers — is the
// T31 case itself, in the gate selection.

@MainActor
final class TA5321d5eBoundedWaitTests: XCTestCase {

    /// A closure that never returns: the shape of a WebKit `await` whose XPC peer never starts.
    /// Deliberately not resumed — that is the whole point, and it leaks one task in this process.
    private func neverAnswering() async {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    }

    func testAnAnswerThatArrivesIsReturnedAtItsOwnCostNotAtTheDetector() async {
        let started = Date()
        let outcome = await withWebKitAnswer("setCookie(answered in 0.2s)", timeout: 15) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            return "kept"
        }
        let elapsed = Date().timeIntervalSince(started)

        guard case .answered(let value) = outcome else {
            return XCTFail("a call that answered in 0.2 s was reported as \(outcome)")
        }
        XCTAssertEqual(value, "kept")
        XCTAssertLessThan(elapsed, 3, "the 15 s window is a hang detector, not a latency budget")
    }

    func testACallThatNeverComesBackIsReportedAfterTheWindowInsteadOfHanging() async {
        let started = Date()
        let outcome = await withWebKitAnswer("setCookie(never answers)", timeout: 1.0) {
            await self.neverAnswering()
        }
        let elapsed = Date().timeIntervalSince(started)

        guard case .silent(let after) = outcome else {
            return XCTFail("a call that never answered was reported as \(outcome)")
        }
        XCTAssertEqual(after, 1.0)
        XCTAssertGreaterThanOrEqual(elapsed, 0.9, "the detector must actually wait its window")
        XCTAssertLessThan(elapsed, 5, "and must return when the window closes, not hang with the call")
    }

    func testARequiredCallThatNeverAnswersSkipsTheCaseAndNamesTheCall() async {
        do {
            _ = try await requireWebKitAnswer("WebKitSessionCookieClearing.clearAuthCookie", timeout: 1.0) {
                await self.neverAnswering()
            }
            XCTFail("a silent call must not let the case pass as if it had asserted")
        } catch let skip as XCTSkip {
            let message = skip.message ?? ""
            XCTAssertTrue(message.contains("clearAuthCookie"),
                          "the skip must name the await: \(message)")
            XCTAssertTrue(message.contains("WebKit did not answer this test host"),
                          "the skip must say why: \(message)")
        } catch {
            XCTFail("expected an XCTSkip for a silent host, got \(error)")
        }
    }

    /// The negative control for the skip: a call that *does* answer must not be skipped, whatever the
    /// window, so the skip cannot become the normal path.
    func testARequiredCallThatAnswersIsNotSkipped() async throws {
        let value = try await requireWebKitAnswer("setCookie(answers)", timeout: 15) { "landed" }
        XCTAssertEqual(value, "landed")
    }
}
