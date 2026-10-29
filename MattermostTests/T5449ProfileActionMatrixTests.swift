// T5449 C3 — the profile popover's action matrix, one test per cell.
//
// The card (`docs/t_8f9f5449-profile-popover-parity.md` §4) makes the matrix **normative**, so it is
// pinned here rather than in a screenshot: `ProfileActionSet.resolve(profile:context:)` is pure, and
// every row of the table is a case below. What each test is really protecting:
//
//  * a row is drawn **only** when every term of its gate is proved — "unknown" (`nil`) is *absent*,
//    never "assumed true" (`ChannelInfoCapabilities.none`'s rule);
//  * the one deliberate exception, `callsAvailable`, answers `true` until a probe 404s — so a Call
//    row is not hidden before the first call is ever started;
//  * the order is upstream's DOM order: Message, Add to a channel, Call, then the self rows.

import XCTest
@testable import Mattermost

final class T5449ProfileActionMatrixTests: XCTestCase {

    private let myID = "me000000000000000000000000me"
    private let otherID = "them0000000000000000000000them"

    // MARK: - Fixtures

    private func human(id: String? = nil) -> MMUserProfile {
        MMUserProfile(id: id ?? otherID, username: "buddy")
    }

    private func bot() -> MMUserProfile {
        MMUserProfile(id: otherID, username: "integration", isBot: true)
    }

    private func deactivated() -> MMUserProfile {
        MMUserProfile(id: otherID, username: "gone", deleteAt: 1_700_000_000_000)
    }

    /// A context in which both write rows are proved for somebody else: a team, the account is in it,
    /// and I manage a channel's members there; Calls is native and available, no call is running.
    private func fullyAllowedContext() -> ProfileActionContext {
        var context = ProfileActionContext()
        context.myUserID = myID
        context.callsAvailable = true
        context.callsSurfaceNative = true
        context.hasLiveCallElsewhere = false
        context.hasTeam = true
        context.inCurrentTeam = true
        context.canManageAnyChannelMembers = true
        return context
    }

    // MARK: - The four columns

    func testAnotherHumanIsOfferedMessageThenAddToChannelThenCall() {
        let set = ProfileActionSet.resolve(profile: human(), context: fullyAllowedContext())
        XCTAssertEqual(set.offered, [.message, .addToChannel, .call],
                       "upstream's DOM order: Message, Add to a Channel, Call")
        XCTAssertNil(set.messageUnavailableReason)
        XCTAssertNil(set.addToChannelUnavailableReason)
        XCTAssertNil(set.callUnavailableReason)
        XCTAssertFalse(set.offers(.setStatus), "somebody else's profile never offers my own status")
    }

    func testABotIsOfferedMessageAndAddToChannelButNeverCall() {
        let set = ProfileActionSet.resolve(profile: bot(), context: fullyAllowedContext())
        XCTAssertEqual(set.offered, [.message, .addToChannel],
                       "a bot is a member like any other for the picker, and is never called")
        XCTAssertFalse(set.offers(.call))
        XCTAssertNil(set.callUnavailableReason,
                     "a structural absence carries no sentence: there is nothing the reader could do")
    }

    func testADeactivatedAccountIsOfferedNothing() {
        let set = ProfileActionSet.resolve(profile: deactivated(), context: fullyAllowedContext())
        XCTAssertEqual(set.offered, [])
        XCTAssertNotNil(set.messageUnavailableReason, "the sheet says why Message is missing")
        XCTAssertNil(set.callUnavailableReason)
        XCTAssertNil(set.addToChannelUnavailableReason)
    }

    func testMyOwnProfileIsOfferedTheSelfRowsOnly() {
        var profile = human(id: myID)
        profile.firstName = "Perf"
        let set = ProfileActionSet.resolve(profile: profile, context: fullyAllowedContext())
        XCTAssertEqual(set.offered, [.setStatus, .customStatus])
        XCTAssertEqual(set.messageUnavailableReason, "This is your own profile.")
        XCTAssertNil(set.callUnavailableReason, "my own profile never offers Call")
        XCTAssertNil(set.addToChannelUnavailableReason)
    }

    func testMyOwnProfileWithACustomStatusAlsoOffersClear() {
        var context = fullyAllowedContext()
        context.hasCustomStatus = true
        let set = ProfileActionSet.resolve(profile: human(id: myID), context: context)
        XCTAssertEqual(set.offered, [.setStatus, .customStatus, .clearCustomStatus])
    }

    // MARK: - The nil context

    func testANilContextOffersNothing() {
        // Every optional unknown: no signed-in id, no team, no permission answer, no Calls surface.
        let set = ProfileActionSet.resolve(profile: human(), context: ProfileActionContext.unknown)
        XCTAssertEqual(set.offered, [],
                       "no row may be drawn from an unknown context — not even Message, whose gate "
                       + "needs the signed-in id")
        XCTAssertNotNil(set.messageUnavailableReason)
    }

    func testAnUnknownPermissionAnswerIsAbsentNotAssumed() {
        var context = fullyAllowedContext()
        context.inCurrentTeam = nil
        context.canManageAnyChannelMembers = nil
        let set = ProfileActionSet.resolve(profile: human(), context: context)
        XCTAssertFalse(set.offers(.addToChannel), "unresolved means the row is not drawn yet")
        XCTAssertNil(set.addToChannelUnavailableReason,
                     "\"you may not\" is a claim, and the sheet has not earned it yet")
    }

    // MARK: - Call's gate, term by term

    func testTheCallRowIsAbsentWhenCallsIsNotInstalled() {
        var context = fullyAllowedContext()
        context.callsAvailable = false
        let set = ProfileActionSet.resolve(profile: human(), context: context)
        XCTAssertFalse(set.offers(.call))
        XCTAssertEqual(set.callUnavailableReason, "Calls is not available on this server.")
    }

    func testTheCallRowIsAbsentWhileCallsRendersWeb() {
        var context = fullyAllowedContext()
        context.callsSurfaceNative = false
        let set = ProfileActionSet.resolve(profile: human(), context: context)
        XCTAssertFalse(set.offers(.call),
                       "while Calls renders web the webview owns it; a native row would be a "
                       + "second answer to the same tap")
        XCTAssertNotNil(set.callUnavailableReason)
    }

    func testTheCallRowIsAbsentWhileACallIsLiveElsewhere() {
        var context = fullyAllowedContext()
        context.hasLiveCallElsewhere = true
        let set = ProfileActionSet.resolve(profile: human(), context: context)
        XCTAssertFalse(set.offers(.call))
        XCTAssertEqual(set.callUnavailableReason, "You are already in a call.")
    }

    /// `callsAvailable` is the card's one stated exception: unknown answers **true**.
    func testCallsAvailableIsTheOneTermThatStartsTrue() {
        XCTAssertTrue(ProfileActionContext().callsAvailable,
                      "an unknown server answers \"available\" until a probe 404s, or nobody could "
                      + "ever start the first call")
        var context = fullyAllowedContext()
        context.callsAvailable = true
        XCTAssertTrue(ProfileActionSet.resolve(profile: human(), context: context).offers(.call))
    }

    // MARK: - Add to a channel's gate, term by term

    func testTheAddRowIsAbsentWithoutATeam() {
        var context = fullyAllowedContext()
        context.hasTeam = false
        let set = ProfileActionSet.resolve(profile: human(), context: context)
        XCTAssertFalse(set.offers(.addToChannel))
        XCTAssertEqual(set.addToChannelUnavailableReason,
                       "Open this profile from a conversation in a team to add somebody to a channel.")
    }

    func testTheAddRowIsAbsentWhenTheAccountIsNotInTheTeam() {
        var context = fullyAllowedContext()
        context.inCurrentTeam = false
        let set = ProfileActionSet.resolve(profile: human(), context: context)
        XCTAssertFalse(set.offers(.addToChannel))
        XCTAssertEqual(set.addToChannelUnavailableReason,
                       "This account is not a member of this team, so it cannot join its channels.")
    }

    func testTheAddRowIsAbsentWhenIManageNoChannelInTheTeam() {
        var context = fullyAllowedContext()
        context.canManageAnyChannelMembers = false
        let set = ProfileActionSet.resolve(profile: human(), context: context)
        XCTAssertFalse(set.offers(.addToChannel))
        XCTAssertEqual(set.addToChannelUnavailableReason,
                       "You do not manage the members of any channel in this team.")
    }

    // MARK: - Exhaustive over the boolean cube

    /// Every combination of the three Call terms the matrix names, so no cell is only implied by the
    /// individual tests above.
    func testEveryCallGateCombination() {
        for available in [false, true] {
            for native in [false, true] {
                for live in [false, true] {
                    var context = fullyAllowedContext()
                    context.callsAvailable = available
                    context.callsSurfaceNative = native
                    context.hasLiveCallElsewhere = live
                    let expected = available && native && !live
                    let set = ProfileActionSet.resolve(profile: human(), context: context)
                    XCTAssertEqual(set.offers(.call), expected,
                                   "callsAvailable=\(available) native=\(native) live=\(live)")
                    XCTAssertEqual(set.callUnavailableReason == nil, expected,
                                   "a missing row always carries its reason, a drawn one none")
                }
            }
        }
    }

    /// Every combination of the two team terms, plus "no team at all".
    func testEveryAddToChannelGateCombination() {
        for hasTeam in [false, true] {
            for inTeam in [nil, false, true] as [Bool?] {
                for canManage in [nil, false, true] as [Bool?] {
                    var context = fullyAllowedContext()
                    context.hasTeam = hasTeam
                    context.inCurrentTeam = inTeam
                    context.canManageAnyChannelMembers = canManage
                    let expected = hasTeam && inTeam == true && canManage == true
                    let set = ProfileActionSet.resolve(profile: human(), context: context)
                    XCTAssertEqual(set.offers(.addToChannel), expected,
                                   "hasTeam=\(hasTeam) inTeam=\(String(describing: inTeam)) "
                                   + "canManage=\(String(describing: canManage))")
                }
            }
        }
    }

    /// The three-state distinction the gate exists for: hidden **and silent** while a term is
    /// unresolved, hidden **with a sentence** once a term is proved against the reader. A `String?`
    /// could not express both, which is why `ProfileRowGate` exists.
    func testAnUnresolvedPermissionIsHiddenAndSilentWhileAProvedOneExplains() {
        var unresolved = fullyAllowedContext()
        unresolved.canManageAnyChannelMembers = nil
        XCTAssertEqual(ProfileActionSet.addToChannelGate(unresolved), .absent(nil))

        var denied = fullyAllowedContext()
        denied.canManageAnyChannelMembers = false
        XCTAssertEqual(ProfileActionSet.addToChannelGate(denied),
                       .absent("You do not manage the members of any channel in this team."))
    }

    /// The self rows and the two write rows are mutually exclusive, in both directions.
    func testTheTwoFamiliesNeverMix() {
        for profile in [human(), bot(), deactivated(), human(id: myID)] {
            let set = ProfileActionSet.resolve(profile: profile, context: fullyAllowedContext())
            let writes = set.offered.contains(.addToChannel) || set.offered.contains(.call)
            let selfRows = set.offered.contains(.setStatus) || set.offered.contains(.customStatus)
            XCTAssertFalse(writes && selfRows, "\(profile.username): \(set.offered)")
            XCTAssertFalse(writes && profile.id == myID)
        }
    }
}
