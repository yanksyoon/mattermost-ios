// t_07216319 (C1 of t_8f9f5449) — the profile popover's gate is the **row host**, for every host that
// draws a post row, with no network and no UI.
//
// `ProfilePopoverPolicy.offersAuthorTap` renamed its first label `paneHost:` → `rowHost:` because the
// rule was never about the pane: it is about the view that draws the row. `T429ProfileTapTests` pins
// the channel pane's four cells; this file pins the **generalisation** — the same four cells for each
// of the four hosts the programme draws post rows in (channel timeline, thread pane, search results,
// mentions), and the one property that makes the table a regression pin at all: `.profile`'s own
// resolution is never consulted.
//
// Why the thread host is special, and why nothing here reads a resolver for it: `ThreadPostListView`
// draws every row natively and nothing in `Mattermost/` ever consulted `resolvedMode(for: .threads)`
// (finding F1 of `docs/t_8f9f5449-profile-popover-parity.md`; the surface is **retired**, see
// `docs/t_7ffa9e76-threads-surface-retirement.md`). A resolver read there would have answered `web` and
// taken the tap off a native row — so the thread pane passes `.native` as a fact about the view
// (`ThreadPaneContent.offersAuthorProfile`). This file asserts the policy with that fact; it does not
// add or read a `.threads` flag.
//
// Behaviour reference: mattermost webapp `components/profile_popover` (v9.11.0), mattermost-mobile
// `app/components/post` (v2.45.0) — the popover is attached to the row's avatar/name wherever the post
// component is drawn. Licence: Apache-2.0, behaviour reimplemented; see docs/THIRD_PARTY_NOTICES.md §18.

import XCTest
@testable import Mattermost

@MainActor
final class T5449ProfileHostPolicyTests: XCTestCase {

    /// The four hosts that draw post rows in this build. The names are the hosts, not `Surface` cases:
    /// the gate's input is how the host's own surface resolved (or, for the thread pane, the fact that
    /// it draws natively), and this card does not decide the list hosts' resolver reads (C2,
    /// `t_2fa3bbe1`).
    private enum RowHost: String, CaseIterable {
        case channelView
        case thread
        case search
        case activity
    }

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "T5449ProfileHostPolicyTests-\(UUID().uuidString)"
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

    /// The truth table, as data. Four cells — a native row host always offers the tap, a web one never
    /// does — applied to every host below.
    private static let cells: [(rowHost: SurfaceRenderMode,
                                profileSurface: SurfaceRenderMode,
                                offered: Bool,
                                why: String)] = [
        (.native, .web, true,
         "the shipped default pair: the rows are drawn natively, so no web popover can answer the tap"),
        (.native, .native, true,
         "a native row host and a native profile card agree"),
        (.web, .web, false,
         "the webview draws those rows and its own popover answers the tap"),
        (.web, .native, false,
         "no native row exists to anchor a popover to"),
    ]

    // MARK: - The full table, every host

    /// 4 cells × 4 row hosts. This is the acceptance table: `channelView`-native with `.profile` web is
    /// offered (the T429 defect), and so are the thread, search and activity row hosts; each web host
    /// offers nothing, with `.profile` on either value.
    func testEveryRowHostFollowsTheTruthTable() {
        for host in RowHost.allCases {
            for cell in Self.cells {
                XCTAssertEqual(ProfilePopoverPolicy.offersAuthorTap(rowHost: cell.rowHost,
                                                                    profileSurface: cell.profileSurface),
                               cell.offered,
                               "\(host.rawValue) row host (\(cell.rowHost)) × profile \(cell.profileSurface): "
                               + "\(cell.why)")
            }
        }
    }

    /// The three hosts the parent card added on top of the pane's four cells, asserted by name so a
    /// future edit that special-cases one of them fails here rather than silently.
    func testTheThreadSearchAndActivityRowHostsOfferTheTap() {
        for host in [RowHost.thread, .search, .activity] {
            XCTAssertTrue(ProfilePopoverPolicy.offersAuthorTap(rowHost: .native, profileSurface: .web),
                          "\(host.rawValue): a host that draws its own native rows offers the author "
                          + "tap even while `.profile` resolves web")
            XCTAssertFalse(ProfilePopoverPolicy.offersAuthorTap(rowHost: .web, profileSurface: .web),
                           "\(host.rawValue): when the webview draws the rows, its own popover answers")
        }
    }

    /// `.profile` is read and ignored — that is the whole reason it stayed in the signature. For every
    /// host and every row-host mode the answer must not depend on it (this is what keeps
    /// `-surfaceMode profile=native` from being the thing that makes the sheet appear).
    func testTheProfileSurfaceIsNeverConsulted() {
        for host in RowHost.allCases {
            for rowHost in SurfaceRenderMode.allCases {
                XCTAssertEqual(
                    ProfilePopoverPolicy.offersAuthorTap(rowHost: rowHost, profileSurface: .web),
                    ProfilePopoverPolicy.offersAuthorTap(rowHost: rowHost, profileSurface: .native),
                    "\(host.rawValue): the answer must be a function of the row host alone")
            }
        }
    }

    // MARK: - The shipped defaults

    /// The state a reader launches into: the pane host is native (approved 2026-10-27) and `.profile`
    /// resolves web (not approved). The channel timeline is the host that reported the defect, and the
    /// thread pane is the host this card wires — both are offered, and the resolver's `.profile` answer
    /// is what the policy discards.
    func testTheShippedDefaultsOfferTheTapForTheChannelAndThreadHosts() {
        let resolver = makeResolver()
        let profileSurface = resolver.resolvedMode(for: .profile)
        XCTAssertEqual(profileSurface, .web,
                       "the profile card is not in the approval registry, so it resolves web")

        XCTAssertEqual(resolver.resolvedMode(for: SurfaceDefaults.paneHostSurface), .native,
                       "the pane host is native by default")
        XCTAssertTrue(ProfilePopoverPolicy.offersAuthorTap(
                        rowHost: resolver.resolvedMode(for: SurfaceDefaults.paneHostSurface),
                        profileSurface: profileSurface),
                      "the channel timeline offers the tap on the shipped defaults")

        // The thread host passes `.native` as a fact, not as a resolver read (F1 / the retirement doc),
        // so its answer cannot depend on any launch flag: there is no flag left to set.
        XCTAssertTrue(ProfilePopoverPolicy.offersAuthorTap(rowHost: .native,
                                                           profileSurface: profileSurface),
                      "the thread pane draws its rows natively by construction and must offer the tap")
    }

    /// A pane forced to the webview (`-surfaceMode shell=web`, the documented escape hatch) has no
    /// native rows at all, so the tap goes with them — the one direction in which the answer may move.
    func testAWebPaneTakesTheTapOffEvenWithANativeProfileCard() {
        let resolver = makeResolver(arguments: ["-surfaceMode", "shell=web"])
        XCTAssertEqual(resolver.resolvedMode(for: SurfaceDefaults.paneHostSurface), .web)
        XCTAssertFalse(ProfilePopoverPolicy.offersAuthorTap(
                        rowHost: resolver.resolvedMode(for: SurfaceDefaults.paneHostSurface),
                        profileSurface: resolver.resolvedMode(for: .profile)))
    }
}
