// Deliberately red. Pushed once on card t_6904c92b, to prove two things about the release
// pipeline: a red gate produces no release, and the check-run annotation names the failing
// test and says it *asserted* rather than blaming the runner's WebKit refusals (every
// full-suite log carries those). Removed in the next commit — this file is a control for
// the pipeline, not a test of the product.
//
// The class name sorts first on purpose: the gate pass should red in about a minute instead
// of after 2,400 other cases, so the cost of the control is a build, not a suite.
import XCTest

final class T00CDGateProbeTests: XCTestCase {
    func testTheReleaseGateBlocksARedPush() {
        XCTFail("deliberate red push (t_6904c92b): this commit must publish nothing")
    }
}
