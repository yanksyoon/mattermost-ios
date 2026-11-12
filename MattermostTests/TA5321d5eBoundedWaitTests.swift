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

    // MARK: - t_e687bad5 — the throwing sibling, driven by the names the new files use

    /// The skip path, through the exact call name two of the newly bounded gate-pass files use
    /// (`AuthSessionTests.testAdoptingAWebSessionEndToEndThroughThePerServerCookieStore` and
    /// `T31WebSessionHarvestTests.testTheProductionReaderFindsTheSessionInTheServersOwnWebsiteDataStore`).
    ///
    /// Those calls await the real cookie store and *then* a request, so they can throw after WebKit
    /// answers; `requireWebKitAnswerOrThrow` exists to keep the error while still bounding the wait.
    /// A bound that has never been shown to fire is a comment, so the silence is proven here: it
    /// skips, and the skip names the call a reader of the gate log would be looking for.
    func testAThrowingCallThatNeverAnswersSkipsTheCaseAndNamesTheCall() async {
        let started = Date()
        do {
            _ = try await requireWebKitAnswerOrThrow(
                "AuthSession.adoptWebSession(WebKitSessionCookieReader)", timeout: 1.0
            ) { () async -> String in
                await self.neverAnswering()
                return "unreachable"
            }
            XCTFail("a silent call must not let the case pass as if it had asserted")
        } catch let skip as XCTSkip {
            let message = skip.message ?? ""
            XCTAssertTrue(message.contains("AuthSession.adoptWebSession(WebKitSessionCookieReader)"),
                          "the skip must name the await: \(message)")
            XCTAssertTrue(message.contains("WebKit did not answer this test host"),
                          "the skip must say why: \(message)")
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.9,
                                        "the detector must actually wait its window")
        } catch {
            XCTFail("expected an XCTSkip for a silent host, got \(error)")
        }
    }

    /// The other half of the contract: a call that answers **and throws** propagates its own error.
    /// The bound may not turn `adoptWebSession`'s `MMError.unauthorized` into a skip, because a skip
    /// would hide a product assertion behind an environment excuse.
    func testAThrowingCallThatAnswersPropagatesItsOwnError() async {
        do {
            _ = try await requireWebKitAnswerOrThrow(
                "AuthSession.adoptWebSession(WebKitSessionCookieReader)", timeout: 15
            ) { () throws -> String in
                throw MMError.unauthorized(message: "Session expired")
            }
            XCTFail("the call's error must reach the test")
        } catch let skip as XCTSkip {
            XCTFail("an answered call must never skip: \(skip.message ?? "")")
        } catch {
            XCTAssertEqual(error as? MMError, .unauthorized(message: "Session expired"),
                           "the call's own error must propagate unchanged")
        }
    }

    /// …and a throwing call that answers a value returns at its own cost, without being skipped.
    func testAThrowingCallThatAnswersReturnsItsValue() async throws {
        let started = Date()
        let value = try await requireWebKitAnswerOrThrow(
            "AuthCoordinator.restore(WebKitSessionCookieReader)", timeout: 15
        ) {
            "signed-in"
        }
        XCTAssertEqual(value, "signed-in")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3,
                          "the 15 s window is a hang detector, not a latency budget")
    }
}
