import XCTest
@testable import Mattermost

/// T43's pure logic: the input arbitration (which source may deliver), the switch that selects it, the
/// decision that turns a `posted` post into a banner (or a documented reason not to), the formatting both
/// inputs share, and the one high-water mark the socket path and the T14 poller both read.
///
/// Nothing here touches a network or a notification centre — that is `T43NativeNotificationFeedTests`'
/// job — so a failure in this file is always a rule, never a transport.
@MainActor
final class T43NotificationInputTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "T43NotificationInputTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func preferences() -> AppPreferences { AppPreferences(defaults: defaults) }
    private var serverA: UUID { UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")! }
    private var serverB: UUID { UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")! }

    // MARK: - 1. The arbitration (exactly one source per server)

    /// The shipped answer: with no debug override, a server's input follows its pane. A native pane has
    /// no page to report a mention, so the socket is the input — the whole of `t_ba355551`. Before that
    /// fix this gate answered `.bridge` for the process and the socket refused every posted frame on a
    /// native Release workspace.
    func testANativePaneMakesTheSocketTheInput() {
        let gate = NotificationInputGate()
        XCTAssertEqual(gate.mode(for: serverA), .socket,
                       "no web view is drawing the pane, so the page cannot be the input")
        XCTAssertTrue(gate.acceptsSocket(serverID: serverA))
        XCTAssertTrue(gate.acceptsBridge(serverID: serverA),
                      "before the pump reports itself the bridge keeps the fallback: a mention nobody hears is worse")
    }

    func testAWebPaneMakesThePageTheInput() {
        var gate = NotificationInputGate()
        gate.webPane = [serverA]
        XCTAssertEqual(gate.mode(for: serverA), .bridge)
        XCTAssertFalse(gate.acceptsSocket(serverID: serverA),
                       "the page is the only side that can see which channel is on screen")
        XCTAssertTrue(gate.acceptsBridge(serverID: serverA))
        XCTAssertTrue(gate.acceptsSocket(serverID: serverB),
                      "and the rule is per server: another server's native pane still has its socket")
    }

    func testAForcedOverrideWinsOverThePane() {
        var gate = NotificationInputGate()
        gate.overrideMode = .bridge
        XCTAssertEqual(gate.mode(for: serverA), .bridge)
        XCTAssertFalse(gate.acceptsSocket(serverID: serverA),
                       "the debug override can still hold the socket silent for an experiment")

        gate.overrideMode = .socket
        XCTAssertEqual(gate.mode(for: serverB), .socket)
        XCTAssertTrue(gate.acceptsSocket(serverID: serverB))
    }

    func testSocketModeAcceptsTheSocketForEveryServer() {
        let gate = NotificationInputGate(overrideMode: .socket)
        XCTAssertTrue(gate.acceptsSocket(serverID: serverA))
        XCTAssertTrue(gate.acceptsSocket(serverID: serverB))
    }

    func testSocketModeRefusesTheBridgeOnlyWhileThatServersSocketIsLive() {
        var gate = NotificationInputGate(overrideMode: .socket)
        gate.socketLive = [serverA]
        XCTAssertFalse(gate.acceptsBridge(serverID: serverA),
                       "a live socket is the input for that server, so the page's frame would be the second banner")
        XCTAssertTrue(gate.acceptsBridge(serverID: serverB),
                      "a server whose socket is not up keeps the fallback: a mention nobody hears is worse")
        XCTAssertEqual(gate.bridgeRefusalReason(serverID: serverA),
                       "the native socket is this server's live mention input")
    }

    func testRoutingCountsBothDecisionsAndTracksLiveness() {
        let routing = NotificationInputRouting()
        routing.setOverride(.socket)
        routing.socketStateChanged(serverID: serverA, live: true)
        XCTAssertEqual(routing.liveSocketCount, 1)

        XCTAssertFalse(routing.acceptsBridge(serverID: serverA))
        XCTAssertTrue(routing.acceptsBridge(serverID: serverB))
        XCTAssertEqual(routing.bridgeRefused, 1)
        XCTAssertEqual(routing.bridgeAccepted, 1)

        // A disconnect hands the input back: the bridge is accepted again.
        routing.socketStateChanged(serverID: serverA, live: false)
        XCTAssertTrue(routing.acceptsBridge(serverID: serverA))
        XCTAssertEqual(routing.bridgeAccepted, 2)
    }

    func testRoutingCountsSocketDeliveriesAndDrops() {
        let routing = NotificationInputRouting()
        routing.noteSocketPost(isMention: true)
        routing.noteSocketPost(isMention: false)
        routing.noteSocketDelivery(delivered: true, reason: nil)
        routing.noteSocketDelivery(delivered: false, reason: "your own post")
        XCTAssertEqual(routing.socketPostsSeen, 2)
        XCTAssertEqual(routing.socketMentions, 1)
        XCTAssertEqual(routing.socketDelivered, 1)
        XCTAssertEqual(routing.socketDropped, 1)
        XCTAssertEqual(routing.lastDropReason, "your own post")
    }

    // MARK: - 2. The switch (launch → persisted; no override means "derive it")

    func testWithNoFlagOrStoredRowTheInputIsDerivedFromThePane() {
        let store = NotificationPathStore(preferences: preferences(), arguments: [])
        XCTAssertNil(store.overrideMode,
                     "the shipped answer is not a constant: the gate derives it from the mounted pane")
        XCTAssertFalse(store.isLaunchOverridden)
    }

    func testTheLaunchArgumentForcesTheSocketInput() {
        let store = NotificationPathStore(preferences: preferences(),
                                          arguments: ["-notificationPath", "socket"])
        XCTAssertEqual(store.overrideMode, .socket)
        XCTAssertTrue(store.isLaunchOverridden)
    }

    func testTheLaunchArgumentSpeaksTheDualRenderVocabularyToo() {
        XCTAssertEqual(NotificationPathStore.parseLaunchMode(["-notificationPath", "native"]), .socket)
        XCTAssertEqual(NotificationPathStore.parseLaunchMode(["-notificationPath", "web"]), .bridge)
        XCTAssertEqual(NotificationPathStore.parseLaunchMode(["-notificationPath=native"]), .socket)
        XCTAssertEqual(NotificationPathStore.parseLaunchMode(["-notificationPath=socket"]), .socket)
    }

    func testAnUnknownOrTruncatedLaunchTokenLeavesTheInputDerived() {
        XCTAssertNil(NotificationPathStore.parseLaunchMode(["-notificationPath", "carrier-pigeon"]))
        XCTAssertNil(NotificationPathStore.parseLaunchMode(["-notificationPath"]))
        XCTAssertNil(NotificationPathStore(preferences: preferences(),
                                           arguments: ["-notificationPath", "carrier-pigeon"]).overrideMode)
    }

    #if DEBUG
    func testThePersistedDebugOverrideIsReadBack() {
        let store = NotificationPathStore(preferences: preferences(), arguments: [])
        store.setOverride(.socket)
        let relaunched = NotificationPathStore(preferences: preferences(), arguments: [])
        XCTAssertEqual(relaunched.overrideMode, .socket, "the persisted tier round-trips through AppPreferences")

        store.setOverride(nil)
        XCTAssertNil(preferences().get(String.self, forKey: NotificationPathStore.Keys.mode),
                     "clearing the override removes the row, so a stale choice cannot outlive the experiment")
    }

    func testReleaseSemanticsIgnoreBothDebugTiers() {
        preferences().set(NotificationInputMode.socket.rawValue, forKey: NotificationPathStore.Keys.mode)
        let store = NotificationPathStore.releaseSemantics(preferences: preferences(),
                                                           arguments: ["-notificationPath", "socket"])
        XCTAssertNil(store.overrideMode,
                     "a Release build resolves no override: no stored row, no launch flag — the input "
                     + "follows the pane that is rendering")
    }
    #endif

    // MARK: - 3. The decision (what is a notification)

    private func makeKeys(channelMentions: Bool = true,
                          extraKeys: [String] = []) -> MentionKeys {
        MentionKeys.derive(username: "perfprobe", firstName: "Percy", notifyProps: nil,
                           firstNameMentions: false, channelMentions: channelMentions,
                           extraKeys: extraKeys)
    }

    private func makeReader(desktop: String = "mention", sound: Bool = true,
                            channelMentions: Bool = true) -> MentionReader {
        MentionReader(userID: "me", keys: makeKeys(channelMentions: channelMentions),
                      desktopNotify: desktop, desktopSound: sound)
    }

    private func makePost(message: String, userID: String = "buddy", channelID: String = "ch1",
                          type: String = "", deleteAt: Int64 = 0, id: String = "post1") -> MMPost {
        MMPost(id: id, createAt: 1_700_000_000_000, deleteAt: deleteAt, userId: userID,
               channelId: channelID, message: message, type: type)
    }

    private func makeChannel(type: String = "O", id: String = "ch1",
                             displayName: String = "T43 notify") -> MMChannel {
        MMChannel(id: id, name: "t43-notify", displayName: displayName, type: type, teamId: "team1")
    }

    private func makeMember(desktop: String = "default", ignoreMentions: String = "default",
                            markUnread: String = "all") -> MMChannelMember {
        MMChannelMember(channelId: "ch1", userId: "me", notifyProps: .object([
            "desktop": .string(desktop),
            "ignore_channel_mentions": .string(ignoreMentions),
            "mark_unread": .string(markUnread),
        ]))
    }

    func testAMentionOfTheReaderDelivers() {
        let decision = MentionNotificationPolicy.decision(post: makePost(message: "hey @perfprobe look"),
                                                          reader: makeReader(),
                                                          channel: makeChannel(),
                                                          membership: makeMember())
        XCTAssertEqual(decision, .deliver(silent: false))
    }

    func testTheReadersOwnPostIsNeverTheirOwnNotification() {
        XCTAssertEqual(MentionNotificationPolicy.decision(post: makePost(message: "@perfprobe note to self",
                                                                        userID: "me"),
                                                          reader: makeReader(),
                                                          channel: makeChannel(),
                                                          membership: makeMember()),
                       .drop(.ownPost))
    }

    func testADeletedPostIsNotANotification() {
        XCTAssertEqual(MentionNotificationPolicy.decision(post: makePost(message: "@perfprobe gone",
                                                                        deleteAt: 42),
                                                          reader: makeReader(),
                                                          channel: makeChannel(),
                                                          membership: makeMember()),
                       .drop(.deleted))
    }

    func testASystemPostIsNotANotification() {
        XCTAssertEqual(MentionNotificationPolicy.decision(post: makePost(message: "@perfprobe joined",
                                                                        type: "system_join_channel"),
                                                          reader: makeReader(),
                                                          channel: makeChannel(),
                                                          membership: makeMember()),
                       .drop(.systemPost))
    }

    func testAWholeTokenMatchIsRequired() {
        // `@perf` must not match `@perfprobe`.
        XCTAssertEqual(MentionNotificationPolicy.decision(post: makePost(message: "hi @perf and @perfprobe2"),
                                                          reader: makeReader(),
                                                          channel: makeChannel(),
                                                          membership: makeMember()),
                       .drop(.notAMention))
    }

    func testCaseIsIgnoredForTheUsernameKey() {
        XCTAssertEqual(MentionNotificationPolicy.decision(post: makePost(message: "HEY @PerfProbe"),
                                                          reader: makeReader(),
                                                          channel: makeChannel(),
                                                          membership: makeMember()),
                       .deliver(silent: false))
    }

    func testAnAccountWithChannelMentionsEnabledIsNotifiedByBroadcast() {
        XCTAssertEqual(MentionNotificationPolicy.decision(post: makePost(message: "@channel standup"),
                                                          reader: makeReader(channelMentions: true),
                                                          channel: makeChannel(),
                                                          membership: makeMember()),
                       .deliver(silent: false))
        XCTAssertEqual(MentionNotificationPolicy.decision(post: makePost(message: "@channel standup"),
                                                          reader: makeReader(channelMentions: false),
                                                          channel: makeChannel(),
                                                          membership: makeMember()),
                       .drop(.notAMention),
                       "an account that did not opt into channel mentions is not notified by one")
    }

    func testAccountDesktopOffSuppressesEverything() {
        XCTAssertEqual(MentionNotificationPolicy.decision(post: makePost(message: "@perfprobe hi"),
                                                          reader: makeReader(desktop: "none"),
                                                          channel: makeChannel(),
                                                          membership: makeMember()),
                       .drop(.notificationsDisabled))
    }

    func testTheChannelCanSwitchNotificationsOff() {
        XCTAssertEqual(MentionNotificationPolicy.decision(post: makePost(message: "@perfprobe hi"),
                                                          reader: makeReader(),
                                                          channel: makeChannel(),
                                                          membership: makeMember(desktop: "none")),
                       .drop(.channelNotificationsOff))
    }

    /// T8525 correction, measured on the pinned server: `ignore_channel_mentions: "on"` removes only the
    /// **broadcast** keys from the reader's mention vocabulary (`server/channels/app/mention_keywords.go:74`);
    /// a post that names the reader still moves `mention_count` and therefore still delivers. The old
    /// assertion here dropped the whole channel, which is the defect `t_8525d2c8` fixed.
    func testAChannelThatIgnoresBroadcastMentionsStillDeliversADirectMention() {
        XCTAssertEqual(MentionNotificationPolicy.decision(post: makePost(message: "@channel hi"),
                                                          reader: makeReader(),
                                                          channel: makeChannel(),
                                                          membership: makeMember(ignoreMentions: "on")),
                       .drop(.mentionsIgnored))
        XCTAssertEqual(MentionNotificationPolicy.decision(post: makePost(message: "@perfprobe hi"),
                                                          reader: makeReader(),
                                                          channel: makeChannel(),
                                                          membership: makeMember(ignoreMentions: "on")),
                       .deliver(silent: false))
    }

    func testAMutedChannelStillDeliversARealMention() {
        // Measured on the pinned server: a mention in a muted channel still increments the reader's
        // `mention_count` (0 -> 1). Muting suppresses message notifications, not mentions; the rule is
        // pinned here so a later "cleanup" cannot quietly make muted channels silent.
        XCTAssertEqual(MentionNotificationPolicy.decision(post: makePost(message: "@perfprobe hi"),
                                                          reader: makeReader(),
                                                          channel: makeChannel(),
                                                          membership: makeMember(markUnread: "mention")),
                       .deliver(silent: false))
    }

    func testADirectMessageNotifiesWithoutNamingTheReader() {
        XCTAssertEqual(MentionNotificationPolicy.decision(post: makePost(message: "are you around?"),
                                                          reader: makeReader(),
                                                          channel: makeChannel(type: "D"),
                                                          membership: makeMember()),
                       .deliver(silent: false),
                       "a DM notifies as a message, which is upstream's rule and the measured membership default")
    }

    func testAMutedDirectMessageIsSilent() {
        XCTAssertEqual(MentionNotificationPolicy.decision(post: makePost(message: "are you around?"),
                                                          reader: makeReader(),
                                                          channel: makeChannel(type: "D"),
                                                          membership: makeMember(markUnread: "mention")),
                       .drop(.channelNotificationsOff))
    }

    func testDesktopSoundOffMakesTheBannerSilent() {
        XCTAssertEqual(MentionNotificationPolicy.decision(post: makePost(message: "@perfprobe hi"),
                                                          reader: makeReader(sound: false),
                                                          channel: makeChannel(),
                                                          membership: makeMember()),
                       .deliver(silent: true))
    }

    func testAReaderProfileIsReadTheWayTheServerSendsIt() {
        let profile = ActivityProfile(id: "me", username: "perfprobe", firstName: "Percy",
                                      lastName: "Probe",
                                      notifyProps: .object([
                                        "desktop": .string("mention"),
                                        "desktop_sound": .string("false"),
                                        "channel": .string("true"),
                                        "mention_keys": .string("deploy, oncall"),
                                        "first_name": .string("false"),
                                      ]))
        let reader = MentionReader.make(from: profile)
        XCTAssertEqual(reader.userID, "me")
        XCTAssertEqual(reader.desktopNotify, "mention")
        XCTAssertFalse(reader.desktopSound, "the flag arrives as the string \"false\"")
        XCTAssertTrue(reader.keys.personalKeys.contains { $0.key == "deploy" }, "extra mention keys are read")
        XCTAssertTrue(reader.keys.personalKeys.contains { $0.key == "@perfprobe" })
    }

    // MARK: - 4. Formatting (identical between the two inputs)

    func testTheSocketAndThePollerProduceTheSameBanner() {
        let server = ServerConfig(id: serverA, name: "Local",
                                  url: URL(string: "http://127.0.0.1:8065")!)

        let fromSocket = MentionNotificationFormatting.mention(
            title: MentionNotificationFormatting.title(channelDisplayName: "T43 notify"),
            body: MentionNotificationFormatting.body(message: "@perfprobe you were named",
                                                    username: "t43buddy"),
            channelID: "ch1", teamID: "team1",
            serverURL: server.url.absoluteString, silent: false)

        let fromPoller = MentionPoller.makeMention(
            post: MentionPost(id: "p1", createAt: 1, userId: "u2", channelId: "ch1",
                              message: "@perfprobe you were named"),
            channel: MentionChannelInfo(id: "ch1", name: "t43-notify", displayName: "T43 notify",
                                        teamId: "team1"),
            user: MentionUserInfo(id: "u2", username: "t43buddy"),
            server: server)

        XCTAssertEqual(fromSocket, fromPoller,
                       "one formatter, so the two inputs cannot drift in title, body, ids or silent")
    }

    func testTheTitleFallsBackToTheDesktopDefault() {
        XCTAssertEqual(MentionNotificationFormatting.title(channelDisplayName: nil),
                       "Someone mentioned you")
        XCTAssertEqual(MentionNotificationFormatting.title(channelDisplayName: "   "),
                       "Someone mentioned you")
        XCTAssertEqual(MentionNotificationFormatting.title(channelDisplayName: " T43 notify "),
                       "T43 notify")
    }

    func testTheBodyFallsBackToTheBareMessage() {
        XCTAssertEqual(MentionNotificationFormatting.body(message: "hello", username: nil), "hello")
        XCTAssertEqual(MentionNotificationFormatting.body(message: "hello", username: ""), "hello")
        XCTAssertEqual(MentionNotificationFormatting.body(message: "hello", username: "buddy"),
                       "@buddy: hello")
    }

    // MARK: - 5. The one high-water mark

    func testTheLedgerKeepsThePollersExistingKey() {
        XCTAssertEqual(MentionLedger.stateKey(for: serverA), MentionPoller.stateKey(for: serverA),
                       "an install that already polled keeps its cursor: one key, one state")
        XCTAssertEqual(MentionLedger.stateKey(for: serverA),
                       "mm.mentions.state.\(serverA.uuidString)")
    }

    func testObservingAPostAdvancesTheWatermarkAndTheRing() {
        let ledger = MentionLedger(preferences: preferences())
        ledger.observe(postID: "p1", createAt: 1_000, for: serverA)
        let state = ledger.state(for: serverA)
        XCTAssertEqual(state.watermarkTs, 1_000)
        XCTAssertEqual(state.watermarkPostID, "p1")
        XCTAssertTrue(state.hasNotified("p1"))
        XCTAssertTrue(ledger.hasHandled("p1", for: serverA))
    }

    func testTheWatermarkNeverMovesBackwards() {
        let ledger = MentionLedger(preferences: preferences())
        ledger.observe(postID: "new", createAt: 2_000, for: serverA)
        ledger.observe(postID: "old", createAt: 1_000, for: serverA)
        XCTAssertEqual(ledger.state(for: serverA).watermarkTs, 2_000)
        XCTAssertEqual(ledger.state(for: serverA).watermarkPostID, "new",
                       "a late/out-of-order event is recorded in the ring but must not rewind the cursor")
    }

    func testThePollerRefusesAPostTheSocketAlreadyHandled() {
        let ledger = MentionLedger(preferences: preferences())
        ledger.observe(postID: "p1", createAt: 1_000, for: serverA)

        let alreadyHandled = MentionPost(id: "p1", createAt: 1_000, userId: "u2",
                                         channelId: "ch1", message: "@perfprobe hi")
        let newPost = MentionPost(id: "p2", createAt: 1_001, userId: "u2",
                                  channelId: "ch1", message: "@perfprobe hi again")
        let older = MentionPost(id: "p0", createAt: 999, userId: "u2",
                                channelId: "ch1", message: "@perfprobe older")

        XCTAssertFalse(MentionPoller.isNew(alreadyHandled, relativeTo: ledger.state(for: serverA)),
                       "this is the duplicate the shared state closes: the socket delivered it, the poll must not")
        XCTAssertTrue(MentionPoller.isNew(newPost, relativeTo: ledger.state(for: serverA)))
        XCTAssertFalse(MentionPoller.isNew(older, relativeTo: ledger.state(for: serverA)))
    }

    func testThePollersMergeKeepsASocketEntryItDidNotKnowAbout() {
        let ledger = MentionLedger(preferences: preferences())
        ledger.observe(postID: "socket-post", createAt: 5_000, for: serverA)

        // The poller loaded its state *before* the socket wrote (so it has neither the ring entry nor the
        // newer watermark) and writes after its round trips. A plain save would erase the socket's fact.
        var stale = ServerMentionState()
        stale.watermarkTs = 4_000
        stale.watermarkPostID = "poller-post"
        stale.recordNotified("poller-post")
        stale.channelMentionCounts = ["ch1": 2]
        ledger.merge(stale, for: serverA)

        let merged = ledger.state(for: serverA)
        XCTAssertTrue(merged.hasNotified("socket-post"), "the socket's ring entry survives the poller's write")
        XCTAssertTrue(merged.hasNotified("poller-post"))
        XCTAssertEqual(merged.watermarkTs, 5_000, "the later stamp wins")
        XCTAssertEqual(merged.channelMentionCounts, ["ch1": 2],
                       "only the poller produces a per-channel snapshot, so its snapshot is kept")
    }

    func testTheRingIsBoundedAtThePollersCap() {
        let ledger = MentionLedger(preferences: preferences())
        for index in 0..<(ServerMentionState.maxNotifiedRing + 25) {
            ledger.observe(postID: "p\(index)", createAt: Int64(index), for: serverA)
        }
        let state = ledger.state(for: serverA)
        XCTAssertEqual(state.notifiedPostIDs.count, ServerMentionState.maxNotifiedRing)
        XCTAssertEqual(state.notifiedPostIDs.first, "p\(ServerMentionState.maxNotifiedRing + 24)",
                       "newest first")
        XCTAssertFalse(state.hasNotified("p0"), "the oldest falls out of the ring once it is full")
    }

    // MARK: - A mounted webview makes the page the input (the dual-render rule)

    /// The rule that a live dual-render run forced: while the web app draws the pane it is the *only*
    /// input that can see which channel the reader is on, so it is the input — the socket goes silent
    /// instead of delivering into the worker's conservative `.unknown` suppression. No override is set:
    /// this is the shipped derivation, pane → input.
    func testAMountedWebViewMakesThePageTheInput() {
        let server = UUID()
        let routing = NotificationInputRouting()
        routing.socketStateChanged(serverID: server, live: true)
        XCTAssertTrue(routing.gate.acceptsSocket(serverID: server),
                      "the native pane makes the socket the input with no flag at all")
        XCTAssertFalse(routing.gate.acceptsBridge(serverID: server))

        routing.paneKindChanged(serverID: server, isWeb: true)
        XCTAssertEqual(routing.webPaneCount, 1)
        XCTAssertFalse(routing.gate.acceptsSocket(serverID: server),
                       "the page is the input while it draws the pane")
        XCTAssertTrue(routing.gate.acceptsBridge(serverID: server),
                      "and it must not be refused: nothing else is left to deliver")

        routing.paneKindChanged(serverID: server, isWeb: false)
        XCTAssertEqual(routing.webPaneCount, 0)
        XCTAssertTrue(routing.gate.acceptsSocket(serverID: server),
                      "a native pane hands the input back to the socket")
        XCTAssertFalse(routing.gate.acceptsBridge(serverID: server))
        XCTAssertEqual(routing.liveModeLabel, NotificationInputMode.socket.label,
                       "with one native server the read-out names the socket")
    }

    /// Pane state is per server: a webview on one server must not silence another server's socket.
    func testTheWebPaneRuleIsPerServer() {
        let web = UUID()
        let native = UUID()
        let routing = NotificationInputRouting()
        routing.socketStateChanged(serverID: web, live: true)
        routing.socketStateChanged(serverID: native, live: true)
        routing.paneKindChanged(serverID: web, isWeb: true)

        XCTAssertFalse(routing.gate.acceptsSocket(serverID: web))
        XCTAssertTrue(routing.gate.acceptsSocket(serverID: native))
        XCTAssertFalse(routing.gate.acceptsBridge(serverID: native))
        XCTAssertEqual(routing.liveModeLabel, "Per server",
                       "the read-out says two answers are in force rather than picking one")
    }
}
