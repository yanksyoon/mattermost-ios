// t_2fa3bbe1 (C2 of t_8f9f5449) — the presentation legality of a profile, with no server and no UI.
//
// Spec of record: `docs/t_8f9f5449-profile-popover-parity.md` §2.2. A profile opened from inside a
// modal is **pushed**, not presented (T40 measured a nested sheet whose confirmation action never ran),
// and the answer belongs to the container: `NativeShellView`'s lookup sheet and `PinnedPostsView` set
// `.environment(\.profilePresentation, .push)`; every other host keeps the default `.sheet`, which is the
// T41/T429 presentation the shipped suites already assert.
//
// Three pins, and why each one is worth having:
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
}
