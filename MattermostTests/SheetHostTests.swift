import SwiftUI
import XCTest
@testable import Mattermost

/// T30b — the shared sheet host (`Mattermost/UI/Native/SheetHost.swift`, component map §1).
///
/// The model's whole job is to answer the one question UIKit will not answer for us: *a second sheet
/// was asked for while one is up — what happens?* UIKit drops it silently, so the model has to make
/// the decision explicit, and these tests pin it:
///
///  * the requested sheet appears when nothing is presented,
///  * the *same* sheet asked for twice is not re-presented (a double tap must not reset its state),
///  * a *different* sheet asked for while one is up is queued rather than dropped,
///  * the queue holds the **latest** request, not a stack,
///  * dismissing promotes the queued sheet in the same transition (never "nothing presented, one
///    pending"),
///  * a dismissal scoped to a route that is no longer on screen does nothing — the late-`onDismiss`
///    case that would otherwise close the sheet the user had just opened,
///  * a system dismissal (`.sheet(item:)` writing `nil`) promotes the queue exactly like `dismiss()`.
@MainActor
final class SheetHostTests: XCTestCase {

    // MARK: Fixtures

    private let settings = SheetRoute(id: "settings")
    private let profile = SheetRoute(id: "userProfile:u1", detents: [.medium, .large])
    private let emoji = SheetRoute(id: "emojiPicker:c1", detents: [.medium])

    // MARK: Presenting

    func testPresentingWhileNothingIsUpShowsTheSheet() {
        let host = SheetHostModel()

        XCTAssertTrue(host.present(settings))
        XCTAssertEqual(host.route, settings)
        XCTAssertNil(host.pending)
    }

    func testPresentingTheSheetThatIsAlreadyUpIsANoOp() {
        let host = SheetHostModel()
        host.present(settings)

        // A second tap on the same control: still shown, and nothing is queued behind it.
        XCTAssertTrue(host.present(SheetRoute(id: "settings")))
        XCTAssertEqual(host.route, settings)
        XCTAssertNil(host.pending)
    }

    func testPresentingADifferentSheetWhileOneIsUpQueuesItInsteadOfDroppingIt() {
        let host = SheetHostModel()
        host.present(settings)

        XCTAssertFalse(host.present(profile), "a queued sheet is not on screen yet")
        XCTAssertEqual(host.route, settings, "the sheet that is up must not change")
        XCTAssertEqual(host.pending, profile)
    }

    func testTheQueueHoldsTheLatestRequestNotEveryRequest() {
        let host = SheetHostModel()
        host.present(settings)

        host.present(profile)
        host.present(emoji)

        XCTAssertEqual(host.pending, emoji)
        host.dismiss()
        XCTAssertEqual(host.route, emoji, "the last thing the user asked for is what appears")
        XCTAssertNil(host.pending)
    }

    // MARK: Dismissing

    func testDismissingPromotesTheQueuedSheetInTheSameTransition() {
        let host = SheetHostModel()
        host.present(settings)
        host.present(profile)

        host.dismiss()

        XCTAssertEqual(host.route, profile)
        XCTAssertNil(host.pending)
    }

    func testDismissingWithNothingQueuedLeavesNothingPresented() {
        let host = SheetHostModel()
        host.present(settings)

        host.dismiss()

        XCTAssertNil(host.route)
        XCTAssertNil(host.pending)
    }

    func testDismissingARouteThatIsNoLongerOnScreenDoesNothing() {
        let host = SheetHostModel()
        host.present(settings)
        host.present(profile)
        host.dismiss()                      // settings goes away, profile is now up

        // settings' own onDismiss fires late. It must not close profile.
        host.dismiss(settings.id)

        XCTAssertEqual(host.route, profile)
    }

    func testDismissingTheRouteThatIsOnScreenClosesIt() {
        let host = SheetHostModel()
        host.present(profile)

        host.dismiss(profile.id)

        XCTAssertNil(host.route)
    }

    // MARK: The path SwiftUI itself uses

    func testASystemDismissalPromotesTheQueuedSheet() {
        let host = SheetHostModel()
        host.present(settings)
        host.present(profile)

        // What `.sheet(item:)` writes when the user swipes settings away.
        host.applySheetChange(nil)

        XCTAssertEqual(host.route, profile)
    }

    func testASystemPresentationGoesThroughTheSameRules() {
        let host = SheetHostModel()
        host.present(settings)

        host.applySheetChange(profile)      // not on screen: queued, current unchanged
        XCTAssertEqual(host.route, settings)
        XCTAssertEqual(host.pending, profile)

        host.applySheetChange(profile)      // the queued one is promoted by the model, not SwiftUI
        XCTAssertEqual(host.route, settings, "SwiftUI cannot present two sheets at once")
        XCTAssertEqual(host.pending, profile)
    }

    func testCancelPendingDropsTheQueueWithoutTouchingWhatIsOnScreen() {
        let host = SheetHostModel()
        host.present(settings)
        host.present(profile)

        host.cancelPending()

        XCTAssertEqual(host.route, settings)
        XCTAssertNil(host.pending)
    }

    // MARK: Detents (component map §1: `.sheet(item:)` + `presentationDetents`)

    func testASheetWithNoRequestedDetentsGetsTheSystemDefault() {
        XCTAssertEqual(settings.detents, [], "the route itself asks for nothing")
        XCTAssertEqual(settings.effectiveDetents, [.large])
    }

    func testRequestedDetentsArePassedThrough() {
        XCTAssertEqual(profile.effectiveDetents, [.medium, .large])
        XCTAssertEqual(emoji.effectiveDetents, [.medium])
    }

    // MARK: Identity

    /// Identity is the **id**, not the whole value: the model compares ids, so a request that
    /// differs only in the detents it asks for is the same sheet and must not be queued as a second
    /// one (that would dismiss and re-present it, losing its scroll position).
    func testTwoRoutesWithTheSameIDAreTheSameSheet() {
        let host = SheetHostModel()
        host.present(SheetRoute(id: "settings"))

        XCTAssertTrue(host.present(SheetRoute(id: "settings", detents: [.medium])))

        XCTAssertNil(host.pending, "the same sheet asked for twice must not queue a second one")
        XCTAssertEqual(host.route?.detents, [], "what is on screen is not re-presented")
    }

    /// The value type still compares all its fields — the model deliberately does not use `==` to
    /// decide identity, and this test says so out loud so nobody "simplifies" it into equality.
    func testRouteEqualityComparesDetentsWhilePresentationIdentityDoesNot() {
        XCTAssertNotEqual(SheetRoute(id: "settings"), SheetRoute(id: "settings", detents: [.medium]))
        XCTAssertEqual(SheetRoute(id: "settings").id, SheetRoute(id: "settings", detents: [.medium]).id)
        XCTAssertNotEqual(SheetRoute(id: "settings"), SheetRoute(id: "downloads"))
    }
}
