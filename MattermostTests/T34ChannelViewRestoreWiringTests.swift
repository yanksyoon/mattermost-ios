// T34 — the **wiring**: the list turns a pending anchor into a restore, in a real scroll view.
//
// `T34ScrollRestorePathTests` pins the loop; this file pins its caller, which is the half QA's
// finding was about (task t_a4d02070): `testLoadingOlderPostsDoesNotMoveTheAnchoredPost` passes on
// this host with the `restoreReader` call deleted (`docs/t34qa-build-note.md` §8, mutation A),
// because iOS 18+ anchoring keeps the anchored row where it is on its own. A green live run therefore
// says "the list does not jump", not "the restore ran".
//
// So this test hosts the **real** `ChannelPostListView` in a window, posts an anchor through the
// public seam the view observes (`ChannelViewModel.requestScrollRestore`), and asserts the two things
// only a wired restore produces:
//
//   1. the anchor is **consumed** (`pendingScrollRestore` back to nil) — nothing else in the app clears
//      it, and while it is set the list deliberately refuses to page (`pollReaderPosition`);
//   2. a `ScrollRestoreReport` naming that post is published, with at least one frame spent
//      looking.
//
// Delete the restore call and both fail. This runs in-process in ~2 s instead of an 80 s simulator
// UI run, which is why it can be the fast pin while the live suite stays the user-visible oracle.

import XCTest
import SwiftUI
@testable import Mattermost

@MainActor
final class T34ChannelViewRestoreWiringTests: XCTestCase {

    private var window: UIWindow?

    func testTheListTurnsAPendingAnchorIntoARestoreAndConsumesIt() async throws {
        defer { unmount() }
        let service = FakeChannelService()
        service.firstPage = MMPostList(
            order: ["c", "b", "a"],
            posts: ["c": post("c", 3_000), "b": post("b", 2_000), "a": post("a", 1_000)])
        let model = ChannelViewModel(channelID: "ch", channelName: "Town Square", service: service)
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.loadedCount, 3)

        mount(model)
        try await settle(seconds: 1.0)          // rows lay out, ScrollViewResolver attaches

        let anchorID = try XCTUnwrap(model.loadedPostIDs.first, "the window holds no posts")
        XCTAssertNil(model.pendingScrollRestore)
        XCTAssertNil(model.lastScrollRestore)

        model.requestScrollRestore(.init(postID: anchorID, offsetFromTop: 12))
        XCTAssertEqual(model.pendingScrollRestore?.postID, anchorID,
                       "the anchor is a request until the view acts on it")

        let consumed = await waitUntil(timeout: 10) { model.pendingScrollRestore == nil }
        XCTAssertTrue(consumed,
                      "the list never consumed the pending anchor: no restore ran "
                      + "(last report: \(model.lastScrollRestore?.summary ?? "none")). "
                      + "Restore wiring in ChannelPostListView.restoreReader / .onChange(pendingScrollRestore)")

        let report = try XCTUnwrap(model.lastScrollRestore,
                                   "no ScrollRestoreReport was published — the restore did not run")
        XCTAssertEqual(report.postID, anchorID, "the restore aimed at the anchored post")
        XCTAssertGreaterThan(report.frames, 0, "the restore spent at least one frame")
        XCTAssertGreaterThan(report.measurements, 0,
                             "the restore measured the anchored row (report: \(report.summary))")
        XCTAssertNotEqual(report.outcome, .rowNeverLaidOut, report.summary)
    }

    /// The anchor is a one-shot: a second request after the first was consumed restores again, and the
    /// report is replaced. (Without consumption the loop would re-run for every render.)
    func testASecondRequestRestoresAgainAfterTheFirstWasConsumed() async throws {
        defer { unmount() }
        let service = FakeChannelService()
        service.firstPage = MMPostList(
            order: ["b", "a"],
            posts: ["b": post("b", 2_000), "a": post("a", 1_000)])
        let model = ChannelViewModel(channelID: "ch", channelName: "Town Square", service: service)
        await model.load()

        mount(model)
        try await settle(seconds: 1.0)

        let anchorID = try XCTUnwrap(model.loadedPostIDs.first)
        model.requestScrollRestore(.init(postID: anchorID, offsetFromTop: 0))
        let firstConsumed = await waitUntil(timeout: 10) { model.pendingScrollRestore == nil }
        XCTAssertTrue(firstConsumed, "the first restore never ran")
        let first = try XCTUnwrap(model.lastScrollRestore)

        model.requestScrollRestore(.init(postID: anchorID, offsetFromTop: 24))
        let secondConsumed = await waitUntil(timeout: 10) {
            model.pendingScrollRestore == nil && model.lastScrollRestore != first
        }
        XCTAssertTrue(secondConsumed, "the second restore never ran")
        XCTAssertEqual(model.lastScrollRestore?.recordedOffsetFromTop, 24)
    }

    // MARK: - Hosting

    /// Put the real list on screen. A `UIHostingController` alone does not lay a `ScrollView` out; the
    /// view needs a window with a size, which is also what gives `ScrollViewResolver` a `UIScrollView`
    /// to find.
    private func mount(_ model: ChannelViewModel) {
        let root = ChannelPostListView(model: model, imageStore: nil, emoji: nil)
        let host = UIHostingController(rootView: root)
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let window = scene.map { UIWindow(windowScene: $0) }
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        self.window = window
    }

    private func settle(seconds: TimeInterval) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1_000)))
    }

    private func unmount() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }

    private func waitUntil(timeout: TimeInterval,
                           _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    // MARK: - Fixtures

    private func post(_ id: String, _ millis: Int64) -> MMPost {
        MMPost(id: id, createAt: millis, userId: "u1", channelId: "ch", message: "message \(id)")
    }

    @MainActor
    private final class FakeChannelService: ChannelServing {
        var firstPage = MMPostList()

        func channel(id: String) async throws -> MMChannel {
            MMChannel(id: id, name: "town-square", displayName: "Town Square", type: "O", teamId: "t")
        }

        func posts(channelID: String, before: String?, perPage: Int) async throws -> MMPostList {
            before == nil ? firstPage : MMPostList()
        }

        func users(ids: [String]) async throws -> [MMUser] { [] }

        func fileData(fileID: String, preferThumbnail: Bool) async throws -> Data {
            throw MMError.notFound
        }
    }
}
