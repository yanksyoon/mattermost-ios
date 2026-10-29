// t_42968927 — the profile popover's two entry points and its permission-gated action set, with no
// network and no UI.
//
// The card: tapping an author's **name or avatar** in a post opened nothing. Two independent causes
// are pinned here:
//
//   1. the tap was gated on the `.profile` *surface*. It is `web` by default (it is not in
//      `SurfaceDefaults.nativeApprovedSurfaces`), so `ChannelView` removed the affordance — while
//      `.channelView` is pane-owning, i.e. the webview is not painting those rows at all. The reader
//      got neither popover. `ProfilePopoverPolicy` is the rule that fixes it, and the truth table is
//      the first test;
//   2. the name was plain text (`PostRowView`). The live UI suite
//      (`MattermostUITests/T429ProfileTapUITests.swift`) taps both; the name's affordance is wired
//      through the same `onShowProfile` callback the avatar uses, so there is one route, not two.
//
// The action set is asserted for exactly the three cases the card names — another member, yourself,
// a deactivated account — plus a bot (an integration is reached through the same DM shortcut).
//
// Behaviour reference: mattermost webapp `components/profile_popover`, mattermost-mobile
// `app/screens/user_profile` (v2.45.0). Licence: Apache-2.0, behaviour reimplemented; see
// docs/THIRD_PARTY_NOTICES.md §18.

import XCTest
@testable import Mattermost

@MainActor
final class T429ProfileTapTests: XCTestCase {

    private let myID = "user0000000000000000000001"
    private let otherID = "user0000000000000000000002"
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "T429ProfileTapTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeResolver(arguments: [String] = []) -> SurfaceModeResolver {
        SurfaceModeResolver(preferences: AppPreferences(defaults: defaults), arguments: arguments)
    }

    private func profile(id: String = "user0000000000000000000002",
                         roles: String = "system_user",
                         deleteAt: Int64 = 0,
                         isBot: Bool = false) -> MMUserProfile {
        MMUserProfile(id: id, username: "probe", firstName: "Perf", lastName: "Probe",
                      nickname: "", position: "", email: "probe@example.invalid",
                      roles: roles, props: [:],
                      timezone: MMUserTimezone(automaticTimezone: "UTC",
                                               manualTimezone: "", useAutomatic: true),
                      createAt: 1_700_000_000_000, updateAt: 0, deleteAt: deleteAt,
                      lastActivityAt: 1_790_000_000_000, authService: "", isBot: isBot)
    }

    // MARK: - The tap's gate (defect 1)

    /// The whole truth table. The row that matters is `native × web`: that is the shipped default
    /// and the state the reader reported. `.profile` must not be able to remove the tap while the
    /// surface that draws the rows is native — the webview is not painting them, so there is no web
    /// popover to take the tap instead. (The parameter is the **row host** since `t_07216319`; for
    /// this pane that is how `SurfaceDefaults.paneHostSurface` resolved.)
    func testTheAuthorTapFollowsThePaneHostNotTheProfileSurface() {
        XCTAssertTrue(ProfilePopoverPolicy.offersAuthorTap(rowHost: .native, profileSurface: .web),
                      "native row host + web profile card is the reported defect: the tap must exist")
        XCTAssertTrue(ProfilePopoverPolicy.offersAuthorTap(rowHost: .native, profileSurface: .native),
                      "a native card and a native popover agree")
        XCTAssertFalse(ProfilePopoverPolicy.offersAuthorTap(rowHost: .web, profileSurface: .web),
                       "when the webview paints the conversation its own popover answers the tap")
        XCTAssertFalse(ProfilePopoverPolicy.offersAuthorTap(rowHost: .web, profileSurface: .native),
                       "no native row is drawn, so there is nothing to anchor a popover to")
    }

    /// The regression, pinned at the real decision point: the **shipped defaults** (no launch flags,
    /// no stored overrides) resolve `.channelView` native and `.profile` web, and the tap is offered.
    /// A reader launching the app as it ships is in exactly this state.
    func testTheShippedDefaultsOfferTheTapWhileProfileResolvesWeb() {
        let resolver = makeResolver()
        XCTAssertEqual(resolver.resolvedMode(for: SurfaceDefaults.paneHostSurface), .native,
                       "the pane host is native by default since the 2026-10-27 workspace flip")
        XCTAssertEqual(resolver.resolvedMode(for: .profile), .web,
                       "the profile card is not approved, so its surface resolves web")
        XCTAssertTrue(ProfilePopoverPolicy.offersAuthorTap(
                        rowHost: resolver.resolvedMode(for: SurfaceDefaults.paneHostSurface),
                        profileSurface: resolver.resolvedMode(for: .profile)),
                      "this is the exact pair the card reported as broken")
    }

    /// The other side: with the pane itself forced to web (`-surfaceMode shell=web`, the documented
    /// debug path), the webview paints the conversation and the native rows are gone, so no tap.
    func testAWebPaneTakesTheTapOffWithItsRows() {
        let resolver = makeResolver(arguments: ["-surfaceMode", "shell=web"])
        XCTAssertEqual(resolver.resolvedMode(for: SurfaceDefaults.paneHostSurface), .web)
        XCTAssertFalse(ProfilePopoverPolicy.offersAuthorTap(
                        rowHost: resolver.resolvedMode(for: SurfaceDefaults.paneHostSurface),
                        profileSurface: resolver.resolvedMode(for: .profile)))
    }

    // MARK: - Only one popover (defect 2's presentation rule)

    /// A pane has one profile slot: a tap re-aims it, a dismissal empties it, and a new tap after a
    /// dismissal presents again. `.sheet(item:)` reads this state, so "one at a time" is structural.
    func testOnlyOneProfileCanBePresentedAtATime() {
        var state = ProfilePopoverState()
        XCTAssertFalse(state.isPresenting)

        state.present(userID: otherID)
        XCTAssertTrue(state.isPresenting)
        XCTAssertEqual(state.target?.userID, otherID)

        // A second tap while one is open re-aims the same presentation instead of adding another.
        state.present(userID: myID)
        XCTAssertTrue(state.isPresenting)
        XCTAssertEqual(state.target?.userID, myID,
                       "the pane must hold exactly one target, not a stack")

        // Dismissal is what `.sheet(item:)` writes when the sheet goes away: the slot empties.
        state.target = nil
        XCTAssertFalse(state.isPresenting)
        XCTAssertNil(state.target)

        state.present(userID: otherID)
        XCTAssertEqual(state.target?.userID, otherID, "a dismissal does not wedge the slot shut")
    }

    // MARK: - The action set (permission matrix)

    /// (a) Another member: Message, and nothing that belongs to my own account.
    func testTheActionSetForSomebodyElseIsMessageOnly() {
        let set = ProfileActionSet.resolve(profile: profile(id: otherID),
                                           myUserID: myID,
                                           hasCustomStatus: false)
        XCTAssertEqual(set.offered, [.message])
        XCTAssertTrue(set.offers(.message))
        XCTAssertFalse(set.offers(.setStatus))
        XCTAssertFalse(set.offers(.customStatus))
        XCTAssertNil(set.messageUnavailableReason)
    }

    /// (b) Myself: the status entries, never a conversation with myself. `clearCustomStatus` appears
    /// only when there is something to clear.
    func testTheActionSetForMyOwnProfileIsTheStatusEntries() {
        let withoutStatus = ProfileActionSet.resolve(profile: profile(id: myID),
                                                     myUserID: myID,
                                                     hasCustomStatus: false)
        XCTAssertEqual(withoutStatus.offered, [.setStatus, .customStatus])
        XCTAssertFalse(withoutStatus.offers(.message))
        XCTAssertEqual(withoutStatus.messageUnavailableReason, "This is your own profile.")

        let withStatus = ProfileActionSet.resolve(profile: profile(id: myID),
                                                  myUserID: myID,
                                                  hasCustomStatus: true)
        XCTAssertEqual(withStatus.offered, [.setStatus, .customStatus, .clearCustomStatus])
    }

    /// (c) A deactivated account: no rows at all, and the sheet can say why instead of leaving a gap.
    func testTheActionSetForADeactivatedAccountIsEmptyAndSaysWhy() {
        let set = ProfileActionSet.resolve(profile: profile(id: otherID, deleteAt: 1_800_000_000_000),
                                           myUserID: myID,
                                           hasCustomStatus: false)
        XCTAssertTrue(set.offered.isEmpty)
        XCTAssertEqual(set.messageUnavailableReason,
                       "This account has been deactivated, so it cannot be messaged.")
    }

    /// A bot is messageable — that is how an integration is reached (upstream offers it too).
    func testABotIsMessageable() {
        let set = ProfileActionSet.resolve(profile: profile(id: otherID, isBot: true),
                                           myUserID: myID,
                                           hasCustomStatus: false)
        XCTAssertEqual(set.offered, [.message])
        XCTAssertNil(set.messageUnavailableReason)
    }

    /// With no signed-in account resolved yet the sheet offers nothing rather than a button that
    /// would create a DM with an unknown other half.
    func testWithNoResolvedAccountThereIsNoMessageRow() {
        let set = ProfileActionSet.resolve(profile: profile(id: otherID),
                                           myUserID: nil,
                                           hasCustomStatus: false)
        XCTAssertTrue(set.offered.isEmpty)
        XCTAssertNotNil(set.messageUnavailableReason)
    }
}
