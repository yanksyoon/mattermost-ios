// t_2fa3bbe1 (C2 of t_8f9f5449) — the presentation legality of a profile, with no server and no UI.
//
// Spec of record: `docs/t_8f9f5449-profile-popover-parity.md` §2.2. A profile opened from inside a
// modal is **pushed**, not presented (T40 measured a nested sheet whose confirmation action never ran),
// and the answer belongs to the container: `NativeShellView`'s lookup sheet and `PinnedPostsView` set
// `.environment(\.profilePresentation, .push)`; every other host keeps the default `.sheet`, which is the
// T41/T429 presentation the shipped suites already assert.
//
// Four pins, and why each one is worth having:
//
//   1. **the default is the sheet** — the whole point of the environment is that a host that says
//      nothing keeps T41's presentation. If the default ever flipped to `.push`, every tab and every
//      pane destination would attach a `navigationDestination` outside a `NavigationStack` (which
//      silently does nothing) and the profile would stop opening anywhere. Nothing else in the suite
//      would notice, because the live suites that assert `profileSheet` run in the compact layout.
//   2. **the push resolves the targeted account through the coordinator** — the pushed screen has to
//      draw the *tapped* author, through the same per-(server, user) cache `ProfileSheet` uses, so a
//      push and a sheet for one account share a single warm model (and one socket subscription). This
//      is the only logic `PushedProfileScreen` introduces, and it is why the resolution is a static
//      seam instead of an inlined `coordinator.model(...)` inside `.task`.
//   3. **the destination's identity is the account** — `.navigationDestination(item:)` keys on
//      `Hashable`, and a re-aim at the same account must be the same destination (replace) while a
//      different account must be a different one (a new push), which is what `ProfilePopoverState`'s
//      one-slot machine promises.
//   4. **the conversation route's order** (`t_10d3db63`) — `1d67294` gave the push the sheet's
//      `.call` rule (pop → open the DM → ask the pane to join) and no test had run it: the live
//      pushed-form test presses Add only, because pressing Call starts a real calls session and T44d
//      §4.2 records the `AURemoteIO::Initialize` abort that follows under host load. §4 below runs
//      the three steps with no UI and no audio.
//
// Behaviour reference: mattermost webapp `components/profile_popover` (v9.11.0) presents an anchored
// card, which mobile cannot fit beside a row — T41's decision keeps the full profile screen. Licence:
// Apache-2.0, behaviour reimplemented; see docs/THIRD_PARTY_NOTICES.md §18.

import XCTest
import SwiftUI
@testable import Mattermost

@MainActor
final class T5449ProfilePresentationTests: XCTestCase {

    private let server = ServerConfig(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                                      name: "probe",
                                      url: URL(string: "https://mm.example")!)

    /// A `ProfileServing` that answers nothing: nothing in this file reads a profile, and a model built
    /// here must not need a server (that is the point of pinning the *resolution*, not the load).
    @MainActor
    final class SilentProfileService: ProfileServing {
        func profile(id: String) async throws -> MMUserProfile { throw MMError.notFound }
        func profiles(ids: [String]) async throws -> [MMUserProfile] { [] }
        func statuses(ids: [String]) async throws -> [MMStatus] { [] }
        func setPresence(_ presence: UserPresence, dndEndTime: Int64?,
                         userID: String) async throws -> MMStatus { throw MMError.notFound }
        func setCustomStatus(userID: String, body: CustomStatusBody) async throws { throw MMError.notFound }
        func clearCustomStatus(userID: String) async throws { throw MMError.notFound }
        func directChannel(myUserID: String, otherUserID: String) async throws -> MMChannel {
            throw MMError.notFound
        }
        func profileImage(userID: String, lastUpdateAt: Int64) async -> Data? { nil }
    }

    private func makeCoordinator() -> ProfileCoordinator {
        let coordinator = ProfileCoordinator()
        let service = SilentProfileService()
        coordinator.serviceFactory = { _ in service }
        return coordinator
    }

    // MARK: - 1. The default is the presentation the shipped hosts already draw

    /// A host that sets nothing — every host except the three lookup sheets and the pinned sheet — keeps
    /// T41's sheet. This is the value `EnvironmentValues()` answers before any container sets it.
    func testTheEnvironmentDefaultIsTheSheetEveryOtherHostDraws() {
        var values = EnvironmentValues()
        XCTAssertEqual(values.profilePresentation, .sheet,
                       "the default must stay T41's sheet: a `.push` default would attach "
                       + "`navigationDestination` outside a stack everywhere else and open nothing")

        // And the value is settable, which is the only thing `NativeShellView` / `PinnedPostsView` do.
        values.profilePresentation = .push
        XCTAssertEqual(values.profilePresentation, .push,
                       "a container must be able to declare the push")
    }

    // MARK: - 2. The pushed screen resolves the account it was pushed for

    /// The pushed screen draws `ProfileTarget`'s account, resolved through the coordinator exactly as
    /// `ProfileSheet`'s `.task` does: same cache, so re-aiming at the same account reuses the warm model
    /// instead of reading the profile twice, and two accounts are two models.
    func testThePushResolvesTheTargetedAccountThroughTheCoordinator() {
        let coordinator = makeCoordinator()
        let buddy = ProfileTarget(userID: "user-buddy")
        let somebodyElse = ProfileTarget(userID: "user-other")

        let model = PushedProfileScreen.resolveModel(target: buddy, server: server,
                                                     coordinator: coordinator)
        XCTAssertEqual(model.userID, buddy.userID,
                       "the push must draw the account it was pushed for — not the signed-in account, "
                       + "which is what `myModel(for:)` would have answered")

        let again = PushedProfileScreen.resolveModel(target: buddy, server: server,
                                                    coordinator: coordinator)
        XCTAssertTrue(model === again,
                      "a second push at the same account must reuse the warm model (one profile read, "
                      + "one socket subscription)")

        let other = PushedProfileScreen.resolveModel(target: somebodyElse, server: server,
                                                    coordinator: coordinator)
        XCTAssertFalse(model === other, "a different account is a different model")
        XCTAssertEqual(other.userID, somebodyElse.userID)
        XCTAssertEqual(coordinator.modelCount, 2,
                       "the push allocates through the coordinator's cache and nothing else")
    }

    // MARK: - 3. The destination's identity is the account

    /// `.navigationDestination(item:)` keys the destination on `Hashable`: the same account is the same
    /// destination (a re-aim replaces it), and a different account is a different destination (a new
    /// push). This is also the identity `.sheet(item:)` has always used, so the two presentations agree.
    func testTheDestinationIdentityIsTheAccount() {
        XCTAssertEqual(ProfileTarget(userID: "user-a"), ProfileTarget(userID: "user-a"))
        XCTAssertNotEqual(ProfileTarget(userID: "user-a"), ProfileTarget(userID: "user-b"))
        XCTAssertEqual(ProfileTarget(userID: "user-a").hashValue,
                       ProfileTarget(userID: "user-a").hashValue,
                       "equal targets must hash equally, or a re-aim would push a second copy")

        // The one-slot machine both presentations write into: a second tap re-aims, never stacks.
        var state = ProfilePopoverState()
        state.present(userID: "user-a")
        XCTAssertEqual(state.target?.userID, "user-a")
        XCTAssertTrue(state.isPresenting)
        state.present(userID: "user-b")
        XCTAssertEqual(state.target?.userID, "user-b",
                       "one slot: a second tap re-aims the profile that is open")
        XCTAssertEqual(state, ProfilePopoverState(target: ProfileTarget(userID: "user-b")))
    }

    // MARK: - 4. The conversation route: pop, open, then (only for `.call`) join

    /// Records a route's steps in the order the product performs them. A class so the step closures
    /// can append without capturing a local `var` (and so the record cannot be read while the route is
    /// still writing it).
    @MainActor
    private final class RouteRecorder {
        var steps: [String] = []
        var request: NativeChannelRequest?
    }

    /// A direct conversation as the server draws it: no team, no channel name of its own (`POST
    /// /channels/direct` answers `team_id: ""`), which is also the case that exercises the two
    /// empty-string → `nil` coercions below.
    private var dm: MMChannel { MMChannel(id: "channel-dm", name: "", type: "D", teamId: "") }

    /// The pushed **Call** row's tap path, run: pop, open the DM, then ask the pane to join it.
    ///
    /// This is the whole of what `1d67294` added to `PushedProfileScreen` and what no test exercised —
    /// `testThePushedProfileCarriesTheSameWriteRows` asserts the row is drawn and presses only Add,
    /// because pressing Call starts a real call (T44d §4.2's audio hazard). The order is the contract:
    /// a call surface raised while the push is still up is T40's measured nested-presentation failure,
    /// and `CallsCoordinator.requestStart` is a one-shot intent for the channel it names, so asking
    /// before the DM is the shell's location would have it spent by the wrong pane (or dropped).
    func testThePushedCallRoutePopsThenOpensTheDMThenAsksThePaneToJoin() {
        let recorder = RouteRecorder()

        PushedProfileScreen.route(dm,
                                  intent: .call,
                                  serverID: server.id,
                                  dismiss: { recorder.steps.append("dismiss") },
                                  open: { request in
                                      recorder.request = request
                                      recorder.steps.append("open")
                                  },
                                  requestStart: { serverID, channelID in
                                      recorder.steps.append("start \(serverID.uuidString)/\(channelID)")
                                  })

        XCTAssertEqual(recorder.steps,
                       ["dismiss", "open", "start \(server.id.uuidString)/\(dm.id)"],
                       "the Call row must pop first (nothing is presented over a presentation), then "
                       + "make the DM the shell's location, then ask the pane to join **that** channel")
        XCTAssertEqual(recorder.request?.serverID, server.id,
                       "the route must name this profile's server")
        XCTAssertEqual(recorder.request?.channelID, dm.id,
                       "and the direct channel the model created, not the channel the profile came from")
        XCTAssertNil(recorder.request?.teamID,
                     "a DM has no team on the wire (`team_id: \"\"`), so the request must carry nil "
                     + "rather than an empty id")
        XCTAssertNil(recorder.request?.channelName,
                     "a DM has no channel name of its own, so the request must carry nil")
    }

    /// The pushed **Message** row: same route, no join — the pane must not be asked for a call by a
    /// row that only asked to show the conversation.
    func testThePushedMessageRouteOpensTheDMAndNeverAsksForACall() {
        let recorder = RouteRecorder()

        PushedProfileScreen.route(MMChannel(id: "channel-dm", name: "user-a__user-b", type: "D",
                                            teamId: "team-perf"),
                                  intent: .open,
                                  serverID: server.id,
                                  dismiss: { recorder.steps.append("dismiss") },
                                  open: { request in
                                      recorder.request = request
                                      recorder.steps.append("open")
                                  },
                                  requestStart: { serverID, channelID in
                                      recorder.steps.append("start \(serverID.uuidString)/\(channelID)")
                                  })

        XCTAssertEqual(recorder.steps, ["dismiss", "open"],
                       "`.open` must not hand a call intent to the pane")
        XCTAssertEqual(recorder.request?.teamID, "team-perf",
                       "a team-scoped channel name travels with the route, exactly as the sheet's does")
        XCTAssertEqual(recorder.request?.channelName, "user-a__user-b")
    }

    /// A push with no navigation model (a preview, or a host that only draws the screen): there is no
    /// pane to route to, so the only honest action is the pop — and certainly not a call intent.
    func testThePushedRouteWithoutNavigationOnlyPops() {
        let recorder = RouteRecorder()

        PushedProfileScreen.route(dm,
                                  intent: .call,
                                  serverID: server.id,
                                  dismiss: { recorder.steps.append("dismiss") },
                                  open: nil,
                                  requestStart: { serverID, channelID in
                                      recorder.steps.append("start \(serverID.uuidString)/\(channelID)")
                                  })

        XCTAssertEqual(recorder.steps, ["dismiss"],
                       "with no `NativeNavigation` there is nothing to open and nothing to join")
        XCTAssertNil(recorder.request, "no request may be built when there is no pane to open")
    }
}
