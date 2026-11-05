// The thread pane's "Open in Channel" — upstream `app/screens/thread_options/options/
// open_in_channel_option.tsx` @ v2.45.0 (162f2560): `showPermalink(serverUrl, '', threadId)` jumps
// from the pane to the **root's** place in its channel.
//
// Three things are asserted here, in the order the sheet decides them:
//
//   1. *who may offer it* — the thread surface's root row, when the host pane can route the jump
//      (`PostOptionsCapabilities.derive`); never a reply, never the channel surface, never a row a
//      host did not wire a closure for (a dead row is the defect class T40-AV names);
//   2. *where it goes* — the root's own `channel_id` and the root's own id, as a
//      `NativeChannelRequest` the shell's one router consumes (`OpenInChannelJump.request`);
//   3. *what the model hands the sheet* — `PostOptionsViewModel.offeredOptions` on both surfaces.
//
// The live half (the channel actually opening on the root after the tap) is
// `MattermostUITests/T36-ThreadsUITests.testOpenInChannelLandsOnTheRootInItsChannel`.

import XCTest
@testable import Mattermost

@MainActor
final class ThreadOpenInChannelTests: XCTestCase {

    private let channelID = "chan0000000000000000000001"
    private let otherChannelID = "chan0000000000000000000002"
    private let teamID = "team0000000000000000000001"
    private let me = "user0000000000000000000001"
    private let other = "user0000000000000000000002"
    private let rootID = "post0000000000000000000001"

    // MARK: - Fixtures

    private func row(id: String = "post0000000000000000000001",
                     rootID: String = "",
                     channel: String? = nil,
                     replyCount: Int = 3,
                     type: String = "",
                     deleteAt: Int64 = 0) -> PostRowModel {
        let post = MMPost(id: id,
                          deleteAt: deleteAt,
                          userId: other,
                          channelId: channel ?? channelID,
                          rootId: rootID,
                          message: "hello",
                          type: type,
                          replyCount: replyCount)
        let users = [post.userId: MMUser(id: post.userId, username: "them", firstName: "Them")]
        return PostListDerivation.row(post: post, users: users, myUserID: me, grouped: false)
    }

    /// The facts a thread-pane root row carries when nothing else is known: another author's post,
    /// nothing loaded from the server yet.
    private func threadFacts(isRoot: Bool = true, hostCanRoute: Bool = true) -> PostOptionFacts {
        var facts = PostOptionFacts()
        facts.viewerID = me
        facts.authorID = other
        facts.isRootPost = isRoot
        facts.message = "hello"
        facts.replyCount = 3
        facts.canReply = true
        facts.canOpenInChannel = hostCanRoute
        facts.surface = .thread
        return facts
    }

    private func actions(hostCanRoute: Bool) -> PostRowActions {
        PostRowActions(canReply: true,
                       canEdit: false,
                       canDelete: false,
                       onReply: {},
                       onEdit: {},
                       onDelete: {},
                       onShowOptions: {},
                       canOpenInChannel: hostCanRoute,
                       onOpenInChannel: {},
                       showsOptions: true)
    }

    private func threadLocation(channel: String? = nil,
                                channelName: String? = nil) -> NativeLocation {
        NativeLocation(serverID: UUID(),
                       serverName: "Local Mattermost",
                       teamID: teamID,
                       teamName: "perf",
                       channelID: channel ?? channelID,
                       channelName: channelName,
                       postID: rootID,
                       pane: .threads)
    }

    // MARK: - 1. Who may offer it

    /// The card's first sentence: the option belongs to the **root row** of the thread pane.
    func testOnlyTheThreadsRootRowOffersOpenInChannel() {
        var facts = threadFacts(isRoot: true)
        XCTAssertTrue(PostOptionsCapabilities.derive(facts).offersOpenInChannel,
                      "the thread's root is what the jump lands on, so the root row offers it")

        facts = threadFacts(isRoot: false)
        XCTAssertFalse(PostOptionsCapabilities.derive(facts).offersOpenInChannel,
                       "a reply's row is not the thread: upstream's thread_options menu is drawn "
                       + "for the thread, not for each reply")
    }

    /// Upstream draws Open in Channel from `thread_options.tsx` only; a channel-timeline row has no
    /// such action (the reader is already in that channel), and a host that cannot route the jump
    /// must not draw a row that does nothing when pressed.
    func testTheRowIsNotOfferedOnTheChannelSurfaceOrWithoutAHostClosure() {
        var facts = threadFacts()
        facts.surface = .channel
        XCTAssertFalse(PostOptionsCapabilities.derive(facts).offersOpenInChannel,
                       "on the channel surface the reader is already where the jump would go")

        facts = threadFacts(hostCanRoute: false)
        XCTAssertFalse(PostOptionsCapabilities.derive(facts).offersOpenInChannel,
                       "no router ⇒ no row: a drawn row with no closure is a dead control")

        // A tombstone is not a place to jump to, and upstream's menu is not drawn for one either.
        facts = threadFacts()
        facts.isDeleted = true
        XCTAssertFalse(PostOptionsCapabilities.derive(facts).offersOpenInChannel)

        var systemFacts = threadFacts()
        systemFacts.isSystem = true
        XCTAssertFalse(PostOptionsCapabilities.derive(systemFacts).offersOpenInChannel)
    }

    /// The row's position: `thread_options.tsx` draws reply, follow, open-in-channel, mark unread,
    /// save, copy link. On a thread surface this build's follow row lives in the pane's header (the
    /// bell), so the neighbours that remain are reply above and mark unread below.
    func testTheRowSitsBetweenReplyAndMarkUnread() {
        let offered = PostOptionsCapabilities.derive(threadFacts()).offeredOptions
        let open = offered.firstIndex(of: .openInChannel)
        XCTAssertNotNil(open, "the root row must offer it: \(offered)")
        XCTAssertGreaterThan(open ?? 0, offered.firstIndex(of: .reply) ?? Int.max,
                            "upstream draws it after Reply: \(offered)")
        if let unread = offered.firstIndex(of: .markUnread), let open {
            XCTAssertLessThan(open, unread, "…and before Mark as Unread: \(offered)")
        }
    }

    // MARK: - 2. Where it goes

    /// The jump resolves to the root's **channel** and to the **root** — the two facts the channel
    /// pane needs to open the conversation and focus the post (`ChannelPaneContent.focusPostID`).
    func testTheJumpResolvesToTheRootsChannelAndTheRootItself() {
        let root = row(id: rootID, rootID: "")
        let request = OpenInChannelJump.request(for: root, from: threadLocation())
        XCTAssertEqual(request?.channelID, channelID, "the root post carries its channel's id")
        XCTAssertEqual(request?.postID, rootID, "the jump lands on the root, not on the pane")
        XCTAssertEqual(request?.teamID, teamID)
        XCTAssertEqual(request?.teamName, "perf")
        XCTAssertNotNil(request?.serverID)
    }

    /// A thread opened from a permalink carries no channel in its route — the jump must still work,
    /// because the channel comes from the post. A route that names a *different* channel must not
    /// leak its name into the request: the title would name the wrong conversation.
    func testTheRouteIsUsedForIdsAndOnlyItsOwnChannelNameIsReused() {
        let root = row(id: rootID, rootID: "", channel: otherChannelID)

        let nameless = OpenInChannelJump.request(for: root, from: threadLocation(channel: nil,
                                                                                 channelName: nil))
        XCTAssertEqual(nameless?.channelID, otherChannelID, "the post's channel wins over the route")
        XCTAssertNil(nameless?.channelName, "a permalink route has no name to lend")

        let sameChannel = OpenInChannelJump.request(for: root,
                                                    from: threadLocation(channel: otherChannelID,
                                                                         channelName: "dev"))
        XCTAssertEqual(sameChannel?.channelName, "dev", "the route names this channel: keep its name")

        let otherChannel = OpenInChannelJump.request(for: root,
                                                     from: threadLocation(channel: channelID,
                                                                          channelName: "ops"))
        XCTAssertNil(otherChannel?.channelName,
                     "the route names a conversation this post is not in — its name is not this one")
    }

    func testAReplyOrAChannellessRootHasNothingToOpen() {
        let reply = row(id: "post0000000000000000000009", rootID: rootID)
        XCTAssertNil(OpenInChannelJump.request(for: reply, from: threadLocation()),
                     "the option is the thread's; a reply is not a destination")

        let channelless = row(id: rootID, rootID: "", channel: "")
        XCTAssertNil(OpenInChannelJump.request(for: channelless, from: threadLocation()),
                     "no channel id ⇒ no request: the pane is not asked to open nothing")
    }

    // MARK: - 3. What the sheet is handed

    /// The view model's half: the offered list is the derivation's, fed with the host's closure bit.
    func testTheViewModelOffersItForTheThreadRootOnly() {
        let options = PostOptionsViewModel(channelID: channelID,
                                           serverURL: "http://127.0.0.1:8065",
                                           myUserID: me,
                                           service: T48PostOptionsTests.FakePostOptionsService())
        let root = row(id: rootID, rootID: "")

        XCTAssertTrue(options.offeredOptions(for: root,
                                             actions: actions(hostCanRoute: true),
                                             surface: .thread).contains(.openInChannel))
        XCTAssertFalse(options.offeredOptions(for: root,
                                              actions: actions(hostCanRoute: false),
                                              surface: .thread).contains(.openInChannel))
        XCTAssertFalse(options.offeredOptions(for: root,
                                              actions: actions(hostCanRoute: true),
                                              surface: .channel).contains(.openInChannel))

        let reply = row(id: "post0000000000000000000009", rootID: rootID)
        XCTAssertFalse(options.offeredOptions(for: reply,
                                              actions: actions(hostCanRoute: true),
                                              surface: .thread).contains(.openInChannel))
    }

    /// A host that never wires the closure cannot reach the write path either: the sheet refuses
    /// loudly instead of pretending the jump happened (T40-AV F1/F2's rule).
    func testPerformingItWithoutAHostClosureRefusesLoudly() async {
        let options = PostOptionsViewModel(channelID: channelID,
                                           serverURL: "http://127.0.0.1:8065",
                                           myUserID: me,
                                           service: T48PostOptionsTests.FakePostOptionsService())
        let outcome = await options.perform(.openInChannel, row: row(id: rootID, rootID: ""))
        XCTAssertEqual(outcome, .failed("This action is not available in this window."))
    }
}
