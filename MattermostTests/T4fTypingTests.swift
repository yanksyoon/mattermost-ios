// T4f — the typing indicator: the frame the composer sends, and the row the panes draw.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb),
// `app/components/post_draft/post_input/post_input.tsx:271-279` (the send gate),
// `app/actions/websocket/users.ts:91-127` (the receive path and its per-frame expiry),
// `app/components/post_draft/typing/index.tsx` (the sentence and its three-name cap).
// Licence: Apache-2.0 — see docs/THIRD_PARTY_NOTICES.md §24.
//
// What is pinned here, and why each case exists:
//
//   SEND — the composer announces **at once** on the first keystroke (leading edge, not a trailing
//   debounce), then at most once per the server's `TimeBetweenUserTypingUpdatesMilliseconds`; it says
//   nothing for an empty message, nothing while editing, nothing when the server's switch is off, and
//   nothing before the server's answer is known. A thread reply names its root as `parent_id`.
//
//   RECEIVE — a frame is a heartbeat: the row shows the typist's name, joins two or three names the
//   way upstream does, and disappears `interval` after the **last** frame — with the older frame's
//   timer unable to clear the newer one. Channel and thread frames are addressed apart by `parent_id`.
//
// The measured server behaviour these cases assume (`scripts/t4f_typing_probe.py`, 9.11.19):
// `/config/client` answers the three keys as strings, a `typing` frame carries `broadcast.channel_id`
// + `data.user_id` + `data.parent_id` (`""` for a channel), and the sender is omitted from its own
// broadcast.

import XCTest
@testable import Mattermost

@MainActor
final class T4fTypingTests: XCTestCase {

    private let channelID = "chan-1"
    private let rootID = "root-1"
    private let me = "u1"

    // MARK: - Doubles

    /// A settable clock for the composer's throttle.
    final class NowBox: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
    }

    /// Records what the composer asked the socket to say.
    @MainActor
    final class FakeTypingTransport: ComposerTypingTransporting {
        struct Send: Equatable {
            let channelID: String
            let parentID: String?
        }

        var settingsValue: MMTypingSettings? = MMTypingSettings()
        /// When set, `settings()` parks until the test releases it — the "the answer is still in
        /// flight while the reader types" case.
        var gateSettings = false
        private var settingsGate: CheckedContinuation<Void, Never>?
        private(set) var settingsCalls = 0
        private(set) var sends: [Send] = []

        func settings() async -> MMTypingSettings? {
            settingsCalls += 1
            if gateSettings {
                await withCheckedContinuation { settingsGate = $0 }
                gateSettings = false
            }
            return settingsValue
        }

        func sendTyping(channelID: String, parentID: String?) async {
            sends.append(Send(channelID: channelID, parentID: parentID))
        }

        func releaseSettings() {
            settingsGate?.resume()
            settingsGate = nil
        }
    }

    /// The composer's REST surface. Only `createPost` is scripted: nothing else is reached by these
    /// cases, and a call to anything else fails loudly instead of pretending to work.
    @MainActor
    final class FakeComposerService: ComposerServing {
        var created: MMPost?

        func createPost(_ body: ComposerPostBody) async throws -> MMPost {
            guard let created else { throw MMError.offline }
            return created
        }

        func patchPost(id: String, message: String, fileIDs: [String]) async throws -> MMPost {
            throw MMError.offline
        }

        func deletePost(id: String) async throws { throw MMError.offline }

        func upload(_ upload: ComposerUpload,
                    channelID: String,
                    onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> MMFileInfo {
            throw MMError.offline
        }

        func me() async throws -> MMUser { MMUser(id: "u1", username: "me") }

        func executeCommand(_ command: String,
                            channelID: String,
                            teamID: String?,
                            rootID: String?) async throws -> ComposerCommandResponse {
            throw MMError.offline
        }
    }

    /// A clock whose `sleep` parks until the test releases that duration, so an expiry is asserted
    /// without waiting five real seconds.
    final class GatedClock: SocketClock, @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [(seconds: TimeInterval, continuation: CheckedContinuation<Void, Never>)] = []
        private var parked: [TimeInterval] = []

        var parkedDurations: [TimeInterval] {
            lock.lock()
            defer { lock.unlock() }
            return parked
        }

        func sleep(for seconds: TimeInterval) async {
            await withCheckedContinuation { continuation in
                lock.lock()
                parked.append(seconds)
                waiters.append((seconds, continuation))
                lock.unlock()
            }
        }

        func release() {
            lock.lock()
            let pending = waiters
            waiters.removeAll()
            lock.unlock()
            for waiter in pending { waiter.continuation.resume() }
        }

        /// Resume **one** park, oldest first: "the first frame's window ended while a newer one is
        /// still running" is only testable if the two releases are separable.
        func releaseOne() {
            lock.lock()
            let waiter = waiters.isEmpty ? nil : waiters.removeFirst()
            lock.unlock()
            waiter?.continuation.resume()
        }
    }

    /// The channel pane's service: one empty page is enough — these cases drive the socket, not a load.
    @MainActor
    final class FakeChannelService: ChannelServing {
        var people: [MMUser] = []

        func channel(id: String) async throws -> MMChannel { MMChannel(id: id) }

        func posts(channelID: String, before: String?, perPage: Int) async throws -> MMPostList {
            MMPostList(order: [], posts: [:])
        }

        func users(ids: [String]) async throws -> [MMUser] {
            people.filter { ids.contains($0.id) }
        }

        func fileData(fileID: String, preferThumbnail: Bool) async throws -> Data { throw MMError.notFound }
    }

    /// The thread pane's service.
    @MainActor
    final class FakeThreadService: ThreadServing {
        var people: [MMUser] = []

        func thread(postID: String, fromPost: String?, fromCreateAt: Int64?, perPage: Int) async throws -> MMPostList {
            MMPostList(order: [postID],
                       posts: [postID: MMPost(id: postID, createAt: 1, userId: "u2",
                                              channelId: "chan-1", message: "root")])
        }

        func threads(teamID: String, before: String?, perPage: Int, unreadOnly: Bool) async throws -> MMThreadList {
            MMThreadList()
        }

        func followedThread(teamID: String, threadID: String) async throws -> MMThread? { nil }
        func setFollowing(teamID: String, threadID: String, following: Bool) async throws {}
        func markRead(teamID: String, threadID: String, at: Int64) async throws -> MMThread {
            MMThread(id: threadID)
        }
        func markUnread(teamID: String, threadID: String, postID: String) async throws -> MMThread {
            MMThread(id: threadID)
        }
        func post(id: String) async throws -> MMPost {
            MMPost(id: id, createAt: 1, userId: "u2", channelId: "chan-1", message: "root")
        }
        func users(ids: [String]) async throws -> [MMUser] { people.filter { ids.contains($0.id) } }
    }

    // MARK: - Helpers

    private func makeComposer(typing: ComposerTypingTransporting,
                              now: NowBox = NowBox(),
                              service: FakeComposerService? = nil)
        -> ComposerViewModel {
        let service = service ?? FakeComposerService()
        return ComposerViewModel(channelID: channelID,
                                 service: service,
                                 drafts: InMemoryComposerDraftStore(),
                                 myUserID: me,
                                 typing: typing,
                                 now: { now.date },
                          autocompleteDebounce: .zero)
    }

    /// Let the `Task`s the gate spawns run. The composer's frames are deliberately fire-and-forget
    /// (`Task { await transport.sendTyping(...) }`), so a test has to give them a turn — not sleep.
    private func settle(_ iterations: Int = 40) async {
        for _ in 0..<iterations { await Task.yield() }
    }

    /// Wait for a row's text, letting the profile request that `noteTyping` starts land. Bounded, so a
    /// missing frame is a red test rather than a hang.
    ///
    /// It waits past "Someone is typing...": that is the row **before** the name arrives, and a test that
    /// stopped there would pass on the fallback rather than on the resolution it is asserting.
    private func waitForLabel(_ indicator: TypingIndicator, timeout: TimeInterval = 3) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let label = indicator.label, label != "Someone is typing..." { return label }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return indicator.label
    }

    /// Wait until `seconds` sleeps have parked on the gated clock. The expiry runs in a `Task` that the
    /// indicator started, so "it has parked" is asynchronous even though the clock itself is not.
    private func waitForParks(_ clock: GatedClock, count: Int, timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if clock.parkedDurations.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    // MARK: - Send: the first keystroke

    func testTheFirstKeystrokeAnnouncesTypingForTheChannel() async {
        let transport = FakeTypingTransport()
        let model = makeComposer(typing: transport)

        model.textChanged("h", caret: 1)
        await settle()

        XCTAssertEqual(transport.sends, [.init(channelID: channelID, parentID: nil)],
                       "the first keystroke of a message must go out at once — the row is only useful "
                       + "while the words are being written")
    }

    func testAnEmptyMessageNeverAnnounces() async {
        let transport = FakeTypingTransport()
        let model = makeComposer(typing: transport)

        model.textChanged("", caret: 0)
        await settle()

        XCTAssertTrue(transport.sends.isEmpty)
    }

    func testTheWindowIsTheServersInterval() async {
        let transport = FakeTypingTransport()
        transport.settingsValue = MMTypingSettings(isEnabled: true, interval: 30)
        let now = NowBox()
        let model = makeComposer(typing: transport, now: now)

        model.textChanged("h", caret: 1)
        await settle()
        now.advance(10)
        model.textChanged("he", caret: 2)
        await settle()
        XCTAssertEqual(transport.sends.count, 1,
                       "10 s is inside the server's 30 s interval: a second frame would be the flood "
                       + "TimeBetweenUserTypingUpdatesMilliseconds exists to prevent")

        now.advance(25)
        model.textChanged("hey", caret: 3)
        await settle()
        XCTAssertEqual(transport.sends.count, 2)
    }

    func testTheServersSwitchOffSilencesTheComposer() async {
        let transport = FakeTypingTransport()
        transport.settingsValue = MMTypingSettings(isEnabled: false, interval: 5)
        let now = NowBox()
        let model = makeComposer(typing: transport, now: now)

        model.textChanged("hello", caret: 5)
        await settle()
        now.advance(60)
        model.textChanged("hello ", caret: 6)
        await settle()

        XCTAssertTrue(transport.sends.isEmpty,
                      "EnableUserTypingMessages=false must silence the client, however long it types")
        XCTAssertEqual(transport.settingsCalls, 1, "the answer is read once, not per keystroke")
    }

    func testNothingIsAnnouncedBeforeTheServersAnswerArrives() async {
        let transport = FakeTypingTransport()
        transport.gateSettings = true
        let model = makeComposer(typing: transport)

        model.textChanged("h", caret: 1)
        await settle()
        XCTAssertTrue(transport.sends.isEmpty,
                      "assuming 'enabled' before the server answers is the guess the card forbids")

        transport.releaseSettings()
        await settle()
        XCTAssertEqual(transport.sends, [.init(channelID: channelID, parentID: nil)],
                       "the reader was already typing while the answer was in flight: announce as "
                       + "soon as it lands")
    }

    func testAFailedConfigReadLeavesTheComposerSilent() async {
        let transport = FakeTypingTransport()
        transport.settingsValue = nil          // the request failed: no answer at all
        let model = makeComposer(typing: transport)

        model.textChanged("hello", caret: 5)
        await settle()

        XCTAssertTrue(transport.sends.isEmpty,
                      "a composer that could not read /config/client must not assume the server's "
                      + "defaults — that would be the guess the card forbids")

        // And a later keystroke asks again, so a transient failure does not silence the session.
        transport.settingsValue = MMTypingSettings()
        model.textChanged("hello!", caret: 6)
        await settle()
        XCTAssertEqual(transport.sends.count, 1, "the next keystroke retries the read")
        XCTAssertEqual(transport.settingsCalls, 2)
    }

    func testAThreadReplyNamesItsRootAsParentID() async {
        let transport = FakeTypingTransport()
        let model = makeComposer(typing: transport)
        let root = MMPost(id: rootID, createAt: 1, userId: "u2", channelId: channelID, message: "root")

        model.beginReply(to: root, authorLabel: "Terry Buddy")
        model.textChanged("r", caret: 1)
        await settle()

        XCTAssertEqual(transport.sends, [.init(channelID: channelID, parentID: rootID)],
                       "a reply's frame carries the thread root, which is how the thread pane's row "
                       + "finds it and the channel's row ignores it")
    }

    func testAnEditAnnouncesNothing() async {
        let transport = FakeTypingTransport()
        let model = makeComposer(typing: transport)
        let post = MMPost(id: "post-1", createAt: 1, userId: me, channelId: channelID, message: "old")

        await model.beginEditing(post)
        model.textChanged("old, edited", caret: 11)
        await settle()

        XCTAssertTrue(transport.sends.isEmpty,
                      "the edit screen has no typing announcement — upstream wires the typing props "
                      + "from post_draft only")
    }

    // MARK: - Send: send / clear reset the window

    func testASendEndsTheWindowSoTheNextMessageAnnouncesAtOnce() async {
        let transport = FakeTypingTransport()
        let service = FakeComposerService()
        service.created = MMPost(id: "server-1", createAt: 2, userId: me,
                                 channelId: channelID, message: "one")
        let now = NowBox()
        let model = makeComposer(typing: transport, now: now, service: service)

        model.textChanged("one", caret: 3)
        await settle()
        XCTAssertEqual(transport.sends.count, 1)

        await model.send()
        XCTAssertEqual(model.text, "", "the send clears the box")

        // Well inside the interval: without the reset this keystroke would be throttled.
        now.advance(1)
        model.textChanged("two", caret: 3)
        await settle()
        XCTAssertEqual(transport.sends.count, 2,
                       "a message that was sent has stopped being typed: the next one announces at once")
    }

    func testClearingTheMessageEndsTheWindow() async {
        let transport = FakeTypingTransport()
        let now = NowBox()
        let model = makeComposer(typing: transport, now: now)

        model.textChanged("hi", caret: 2)
        await settle()
        model.textChanged("", caret: 0)          // the reader deleted everything
        await settle()
        now.advance(1)
        model.textChanged("h", caret: 1)          // and started again
        await settle()

        XCTAssertEqual(transport.sends.count, 2,
                       "an empty message is not being typed; the next one is a fresh announcement")
    }

    // MARK: - Receive: the sentence

    func testOneTypistIsNamed() {
        let indicator = TypingIndicator(channelID: channelID, parentID: "")
        indicator.receive(userID: "u2", name: "Terry Buddy")
        XCTAssertEqual(indicator.label, "Terry Buddy is typing...")
    }

    func testTwoTypistsJoinTheSentenceInArrivalOrder() {
        let indicator = TypingIndicator(channelID: channelID, parentID: "")
        indicator.receive(userID: "u2", name: "Terry Buddy")
        indicator.receive(userID: "u3", name: "Anne Other")
        XCTAssertEqual(indicator.label, "Terry Buddy and Anne Other are typing...")

        // A repeated frame re-appends the typist, exactly as upstream's `filter` + `push` does.
        indicator.receive(userID: "u2", name: "Terry Buddy")
        XCTAssertEqual(indicator.label, "Anne Other and Terry Buddy are typing...")
    }

    func testThreeNamesAreTheMostThatAreDrawn() {
        let indicator = TypingIndicator(channelID: channelID, parentID: "")
        for (index, name) in ["Ana", "Bo", "Cy", "Di"].enumerated() {
            indicator.receive(userID: "u\(index)", name: name)
        }
        XCTAssertEqual(indicator.label, "Ana, Bo and Cy are typing...",
                       "upstream truncates at three names (splice(3) + pop), so a busy channel does "
                       + "not draw a wall of names")
    }

    func testAnUnnamedTypistIsSomeoneNotABlank() {
        let indicator = TypingIndicator(channelID: channelID, parentID: "")
        indicator.receive(userID: "u9", name: nil)
        XCTAssertEqual(indicator.label, "Someone is typing...",
                       "the frame carries an id only; the name arrives a moment later and "
                       + "`rename` corrects the row in place")
        indicator.rename(userID: "u9", name: "Terry Buddy")
        XCTAssertEqual(indicator.label, "Terry Buddy is typing...")
    }

    func testTheSameAuthorDoesNotAppearTwice() {
        let indicator = TypingIndicator(channelID: channelID, parentID: "")
        indicator.receive(userID: "u2", name: "Terry Buddy")
        indicator.receive(userID: "u2", name: "Terry Buddy")
        XCTAssertEqual(indicator.label, "Terry Buddy is typing...")
    }

    // MARK: - Receive: expiry

    func testTheRowGoesAwayWhenTheServersWindowElapses() async {
        let clock = GatedClock()
        let indicator = TypingIndicator(channelID: channelID, parentID: "", expiry: 5, clock: clock)

        indicator.receive(userID: "u2", name: "Terry Buddy")
        XCTAssertEqual(indicator.label, "Terry Buddy is typing...")
        let parked = await waitForParks(clock, count: 1)
        XCTAssertTrue(parked)
        XCTAssertEqual(clock.parkedDurations, [5], "the window is the server's interval")

        clock.release()
        await settle()
        XCTAssertNil(indicator.label, "no frame for 5 s means the typist stopped")
    }

    func testANewFrameRestartsTheWindowAndTheOldTimerCannotClearIt() async {
        let clock = GatedClock()
        let indicator = TypingIndicator(channelID: channelID, parentID: "", expiry: 5, clock: clock)

        indicator.receive(userID: "u2", name: "Terry Buddy")
        indicator.receive(userID: "u2", name: "Terry Buddy")   // still typing
        let bothParked = await waitForParks(clock, count: 2)
        XCTAssertTrue(bothParked)
        XCTAssertEqual(clock.parkedDurations, [5, 5])

        clock.releaseOne()                                      // the first frame's window ends
        await settle()
        XCTAssertEqual(indicator.label, "Terry Buddy is typing...",
                       "the second frame re-armed the window; the first timer must not clear a "
                       + "typist who is still talking")

        clock.releaseOne()                                      // and the newer window ends
        await settle()
        XCTAssertNil(indicator.label, "with no further frame the typist finally stops")
    }

    // MARK: - Receive: addressing (`parent_id`)

    func testAChannelFrameIsNotAThreadFrame() {
        let channelRow = TypingIndicator(channelID: channelID, parentID: "")
        let threadRow = TypingIndicator(channelID: channelID, parentID: rootID)
        let channelFrame = SocketTyping(channelID: channelID, parentID: "", userID: "u2")
        let threadFrame = SocketTyping(channelID: channelID, parentID: rootID, userID: "u2")

        XCTAssertTrue(channelRow.accepts(channelFrame))
        XCTAssertFalse(channelRow.accepts(threadFrame))
        XCTAssertTrue(threadRow.accepts(threadFrame))
        XCTAssertFalse(threadRow.accepts(channelFrame))
        XCTAssertFalse(threadRow.accepts(SocketTyping(channelID: "other", parentID: rootID, userID: "u2")))
    }

    func testARetargetedThreadRowForgetsTheWrongChannel() {
        let indicator = TypingIndicator(channelID: "", parentID: rootID)
        indicator.receive(userID: "u2", name: "Terry Buddy")
        XCTAssertEqual(indicator.label, "Terry Buddy is typing...")

        indicator.retarget(channelID: channelID)
        XCTAssertNil(indicator.label, "a frame received before the thread knew its channel belonged "
                                      + "to the wrong comparison")
        XCTAssertTrue(indicator.accepts(SocketTyping(channelID: channelID, parentID: rootID, userID: "u2")))
    }

    // MARK: - Receive: the wire shape

    /// The frame a real server sends, copied from `scripts/t4f_typing_probe.py` (9.11.19): the channel
    /// sits in **`broadcast`**, and `data` carries only `parent_id` and `user_id`.
    ///
    /// This case exists because the first live run failed here: decoding `data.channel_id` alone yields
    /// `""`, the scope refuses an unattributable channel, and the row never appears — a silent miss
    /// that looks exactly like "the server never sent anything".
    func testTheServerNamesTheChannelInTheBroadcastNotInData() throws {
        let json = """
        {"event":"typing","seq":1,
         "broadcast":{"omit_users":{"u2":true},"user_id":"","channel_id":"chan-1","team_id":"",
                      "connection_id":"","omit_connection_id":""},
         "data":{"parent_id":"","user_id":"u2"}}
        """
        let frame = try JSONDecoder().decode(MMSocketFrame.self, from: Data(json.utf8))
        guard case .typing(let typing)? = SocketEvent(frame: frame) else {
            return XCTFail("a measured typing frame must decode to .typing")
        }
        XCTAssertEqual(typing.channelID, "chan-1", "the broadcast names the channel")
        XCTAssertEqual(typing.parentID, "")
        XCTAssertEqual(typing.userID, "u2")

        // Upstream also accepts a frame that repeats the channel in `data` (a client re-broadcast);
        // that keeps working, and the parent still names the thread.
        let threaded = """
        {"event":"typing","seq":2,"broadcast":{"channel_id":"chan-1"},
         "data":{"channel_id":"chan-1","parent_id":"root-1","user_id":"u3"}}
        """
        let threadedFrame = try JSONDecoder().decode(MMSocketFrame.self, from: Data(threaded.utf8))
        guard case .typing(let threadTyping)? = SocketEvent(frame: threadedFrame) else {
            return XCTFail("a typed frame with a parent must decode")
        }
        XCTAssertEqual(threadTyping.parentID, "root-1")
        XCTAssertEqual(threadTyping.userID, "u3")
    }

    // MARK: - The panes: a frame reaches the right row

    func testAChannelPaneShowsTheTypistOnItsRow() async {
        let service = FakeChannelService()
        service.people = [MMUser(id: "u2", username: "terry", firstName: "Terry", lastName: "Buddy")]
        let model = ChannelViewModel(channelID: channelID, channelName: "Town Square",
                                     service: service, myUserID: me)

        XCTAssertEqual(model.handle(.typing(SocketTyping(channelID: channelID, parentID: "", userID: "u2"))),
                       .typing)
        let label = await waitForLabel(model.typing)
        XCTAssertEqual(label, "Terry Buddy is typing...",
                       "the pane resolves the frame's id through the same display-name rule its rows "
                       + "use")
    }

    func testAThreadFrameDoesNotDrawInTheChannelPane() {
        let model = ChannelViewModel(channelID: channelID, service: FakeChannelService(), myUserID: me)

        XCTAssertEqual(model.handle(.typing(SocketTyping(channelID: channelID, parentID: rootID,
                                                        userID: "u2"))), .ignored)
        XCTAssertNil(model.typing.label)
    }

    func testAThreadPaneShowsOnlyItsOwnRootsTypists() async {
        let service = FakeThreadService()
        service.people = [MMUser(id: "u2", username: "terry", firstName: "Terry", lastName: "Buddy")]
        let model = ThreadViewModel(rootID: rootID, channelID: channelID, teamID: "team",
                                    service: service, myUserID: me)

        XCTAssertEqual(model.handle(.typing(SocketTyping(channelID: channelID, parentID: "", userID: "u2"))),
                       .ignored, "a channel message's frame is the channel pane's row")
        XCTAssertEqual(model.handle(.typing(SocketTyping(channelID: channelID, parentID: "another-root",
                                                        userID: "u2"))),
                       .ignored, "another thread's frame is somebody else's row")

        XCTAssertEqual(model.handle(.typing(SocketTyping(channelID: channelID, parentID: rootID,
                                                        userID: "u2"))), .typing)
        let label = await waitForLabel(model.typing)
        XCTAssertEqual(label, "Terry Buddy is typing...")
    }
}
