// t_c407645a — `channel_converted` is decoded and routed, and a conversion this app started does not
// feed its own echo back into the panes.
//
// The card named `channel_converted` and asked for it to be **measured first**. The probe
// (`scripts/tc407_channel_converted_probe.py`, output in `docs/tc407-build-note.md`) measured two
// different wires on the pinned 9.11.19 server:
//
//  * Case A — a **group message converted to a private channel** (the card's scenario): the server
//    sends **`channel_updated`** with the whole converted channel (`data.channel` as a JSON string),
//    plus `sidebar_category_updated`, a system `posted` and (for the converting user) a
//    `channel_member_updated`. It sends **no** `channel_converted` at all.
//  * Case B — a channel's **privacy** converted (`PUT /channels/{id}/privacy`): `channel_converted`
//    with **`data.channel_id` only**, `broadcast.channel_id` empty and the team in
//    `broadcast.team_id`, *and* a `channel_updated` carrying the new record.
//
// So the tests below pin both paths: the decode of the frame the card named (for the releases that
// send it), the decode of the frame 9.11.19 actually sends, and the routing each one drives — plus
// upstream's suppression rule (`EphemeralStore.isConvertingChannel`, which its websocket handlers
// apply to *both* frames: `app/actions/websocket/channel.ts:86,104`).
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0
// (162f2560d0e1df073220f7701d5a67cc17c8abeb), app/actions/websocket/channel.ts.

import XCTest
@testable import Mattermost

@MainActor
final class Tc407ChannelConvertedTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var retainedStores: [ServerStore] = []

    override func setUp() {
        super.setUp()
        suiteName = "Tc407ChannelConvertedTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        retainedStores.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    /// The frame measured in probe Case B, verbatim: the payload names the channel and nothing else,
    /// and the envelope's `channel_id` is **empty**.
    private let measuredConversionFrame = #"""
    {"event":"channel_converted","seq":1,
     "data":{"channel_id":"uinxi77o7t86tckc1g5469zr5o"},
     "broadcast":{"omit_users":null,"user_id":"","channel_id":"","team_id":"ocz148uck3r88dcjikj497bosh","connection_id":"","omit_connection_id":""}}
    """#

    private func server(_ name: String = "Example", host: String = "mm.example") -> ServerConfig {
        ServerConfig(name: name, url: URL(string: "https://\(host)")!)
    }

    private func channel(_ id: String,
                         name: String? = nil,
                         displayName: String? = nil,
                         type: String = "G",
                         teamID: String = "",
                         deleteAt: Int64 = 0) -> MMChannel {
        MMChannel(id: id,
                  name: name ?? id,
                  displayName: displayName ?? id,
                  type: type,
                  teamId: teamID,
                  createAt: 1_000,
                  deleteAt: deleteAt)
    }

    private func socketFrame(_ json: String) throws -> MMSocketFrame {
        try JSONDecoder().decode(MMSocketFrame.self, from: Data(json.utf8))
    }

    private func preferences() -> AppPreferences { AppPreferences(defaults: defaults) }

    private func makeNavigation(_ servers: [ServerConfig]) -> NativeNavigation {
        let store = ServerStore(preferences: preferences())
        for server in servers { _ = store.add(server) }
        retainedStores.append(store)
        let resolver = SurfaceModeResolver(preferences: preferences(),
                                           arguments: ["-surfaceMode", "shell=native"])
        let navigation = NativeNavigation(resolver: resolver)
        navigation.serverStore = store
        navigation.viewStore = ViewStore()
        return navigation
    }

    // MARK: - 1. The decode

    /// The measured frame: the id is in `data` because the envelope has none, and the team is in the
    /// envelope. A decode that read `broadcast.channel_id` would drop every real conversion.
    func testChannelConvertedDecodesTheIdFromThePayloadAndTheTeamFromTheEnvelope() throws {
        let frame = try socketFrame(measuredConversionFrame)

        guard case .channelConverted(let converted)? = SocketEvent(frame: frame) else {
            return XCTFail("expected a typed channel_converted event")
        }
        XCTAssertEqual(converted.channelID, "uinxi77o7t86tckc1g5469zr5o")
        XCTAssertEqual(converted.teamID, "ocz148uck3r88dcjikj497bosh",
                       "9.11.19 routes the frame by team; the channel id is only in the payload")
        XCTAssertEqual(converted.channelType, "", "9.11.19 sends no channel_type")
        XCTAssertEqual(SocketEvent(frame: frame)?.name, "channel_converted")
        XCTAssertNil(SocketEvent(frame: frame)?.dedupeKey,
                     "a conversion whose occurrence is the signal must not be de-duplicated away")
    }

    /// A newer server adds `channel_type` (and a proxy may put `team_id` in the payload): both are
    /// taken where present, never required.
    func testChannelConvertedAcceptsTheNewerPayloadShape() throws {
        let frame = try socketFrame(#"""
        {"event":"channel_converted","seq":2,
         "data":{"channel_id":"c1","channel_type":"P","team_id":"t1"},
         "broadcast":{"user_id":"","channel_id":"","team_id":""}}
        """#)

        guard case .channelConverted(let converted)? = SocketEvent(frame: frame) else {
            return XCTFail("expected a typed channel_converted event")
        }
        XCTAssertEqual(converted.channelID, "c1")
        XCTAssertEqual(converted.teamID, "t1")
        XCTAssertEqual(converted.channelType, "P")
    }

    /// A frame that names no channel anywhere is **dropped**, not surfaced as a routable event with an
    /// empty id (an empty id would match no pane, and would still be counted as delivered).
    func testChannelConvertedWithoutAnyChannelIdIsDropped() throws {
        let frame = try socketFrame(#"""
        {"event":"channel_converted","seq":3,
         "data":{},"broadcast":{"user_id":"","channel_id":"","team_id":"t1"}}
        """#)
        XCTAssertNil(SocketEvent(frame: frame))
    }

    /// A proxy that relocates the id into the envelope still routes.
    func testChannelConvertedFallsBackToTheEnvelopeChannelId() throws {
        let frame = try socketFrame(#"""
        {"event":"channel_converted","seq":4,
         "data":{},"broadcast":{"user_id":"","channel_id":"c9","team_id":"t1"}}
        """#)
        guard case .channelConverted(let converted)? = SocketEvent(frame: frame) else {
            return XCTFail("expected a typed channel_converted event")
        }
        XCTAssertEqual(converted.channelID, "c9")
        XCTAssertEqual(converted.teamID, "t1")
    }

    // MARK: - 2. The team scope

    func testScopeAttributesAConversionToTheTeamWhoseChannelItNames() {
        let scope = TeamSocketScope(teamID: "t1", activeChannelID: nil,
                                    channelTeams: ["c1": "t1"])
        let event = SocketEvent.channelConverted(SocketChannelConverted(channelID: "c1", teamID: ""))

        XCTAssertTrue(scope.accepts(event))
    }

    /// The envelope's team is the second route: a conversion **into** the team on screen reaches it
    /// even when the channel→team map still holds the channel's previous listing.
    func testScopeAcceptsAConversionByItsEnvelopeTeamWhenTheMapDoesNotKnowTheChannel() {
        let scope = TeamSocketScope(teamID: "t1", activeChannelID: nil, channelTeams: [:])
        let event = SocketEvent.channelConverted(SocketChannelConverted(channelID: "c-new", teamID: "t1"))

        XCTAssertTrue(scope.accepts(event))
    }

    func testScopeRefusesAConversionOfAnotherTeamsChannel() {
        let scope = TeamSocketScope(teamID: "t1", activeChannelID: nil,
                                    channelTeams: ["c1": "t2"])
        let event = SocketEvent.channelConverted(SocketChannelConverted(channelID: "c1", teamID: "t2"))

        XCTAssertFalse(scope.accepts(event))
    }

    // MARK: - 3. The open pane

    /// What 9.11.19 actually sends for a group-message conversion: the whole converted record. The pane
    /// takes its header from it — no request, and the "Group message" title and `G` type go away.
    func testChannelUpdatedAppliesTheConvertedRecordToTheOpenPanesHeader() async {
        let service = Tc407ChannelService(channel: channel("gm1", displayName: "alice, bob", type: "G"))
        let model = ChannelViewModel(channelID: "gm1", service: service, myUserID: "me")
        await model.load()
        XCTAssertEqual(model.title, "Group message")
        XCTAssertEqual(model.channelType, "G")
        let headerReadsBefore = service.channelReads

        let converted = channel("gm1", name: "t088-live", displayName: "T088 Live", type: "P",
                                teamID: "t1")
        let outcome = model.handle(.channelUpdated(converted))

        XCTAssertEqual(outcome, .patched)
        XCTAssertEqual(model.channelType, "P", "the pane must stop claiming the conversation is a group")
        XCTAssertEqual(model.title, "T088 Live",
                       "the header must name the converted channel, not \"Group message\"")
        XCTAssertEqual(service.channelReads, headerReadsBefore,
                       "the payload carries the record: a refetch would be a request with nothing to learn")
    }

    func testChannelUpdatedForAnotherChannelLeavesTheHeaderAlone() async {
        let service = Tc407ChannelService(channel: channel("gm1", displayName: "alice, bob", type: "G"))
        let model = ChannelViewModel(channelID: "gm1", service: service, myUserID: "me")
        await model.load()

        let outcome = model.handle(.channelUpdated(channel("other", displayName: "Other", type: "P")))

        XCTAssertEqual(outcome, .ignored)
        XCTAssertEqual(model.channelType, "G")
        XCTAssertEqual(model.title, "Group message")
    }

    /// The frame the card named carries **only** the id, so the header has to be re-read (the same read
    /// `refreshHeader()` performs for the local conversion).
    func testChannelConvertedRefetchesTheOpenPanesHeader() async {
        let service = Tc407ChannelService(channel: channel("gm1", displayName: "alice, bob", type: "G"))
        let model = ChannelViewModel(channelID: "gm1", service: service, myUserID: "me")
        await model.load()
        XCTAssertEqual(model.channelType, "G")

        // The server now holds the converted record (what the refetch will answer).
        service.channel = channel("gm1", name: "t088-live", displayName: "T088 Live", type: "P")
        let outcome = model.handle(.channelConverted(SocketChannelConverted(channelID: "gm1")))

        XCTAssertEqual(outcome, .patched)
        let awaited = await model.awaitHeaderRefresh()
        XCTAssertTrue(awaited, "the frame must start a header read")
        XCTAssertEqual(model.channelType, "P")
        XCTAssertEqual(model.title, "T088 Live")
    }

    func testChannelConvertedForAnotherChannelNeitherRefetchesNorChangesAnything() async {
        let service = Tc407ChannelService(channel: channel("gm1", displayName: "alice, bob", type: "G"))
        let model = ChannelViewModel(channelID: "gm1", service: service, myUserID: "me")
        await model.load()
        let readsBefore = service.channelReads

        let outcome = model.handle(.channelConverted(SocketChannelConverted(channelID: "other")))
        let awaited = await model.awaitHeaderRefresh()

        XCTAssertEqual(outcome, .ignored)
        XCTAssertFalse(awaited, "another channel's conversion must not schedule a read")
        XCTAssertEqual(service.channelReads, readsBefore)
    }

    // MARK: - 4. The sidebar row

    /// The card's visible symptom: the row was still drawn as a group message (member names, `person.2`
    /// glyph). The row is derived from the channel record, so the `channel_updated` payload — the frame
    /// 9.11.19 sends — has to replace it.
    func testSidebarRowStopsBeingAGroupMessageWhenTheRecordChanges() async {
        let (model, service) = await sidebarModel()
        XCTAssertEqual(model.entry(id: "gm1")?.kind, .groupMessage)
        XCTAssertEqual(model.entry(id: "gm1")?.displayName, "Alice, Bob")

        let converted = channel("gm1", name: "t088-live", displayName: "T088 Live", type: "P",
                                teamID: "t1")
        let outcome = model.handle(.channelUpdated(converted), myUserID: "me")

        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(model.entry(id: "gm1")?.kind, .privateChannel,
                       "the row must stop being drawn as a group message")
        XCTAssertEqual(model.entry(id: "gm1")?.displayName, "T088 Live")
        XCTAssertEqual(service.requests, 0,
                       "the payload carries the record: replacing the row costs no request")
    }

    /// A conversion that moved the conversation into **another** team: this list is `GET
    /// /users/me/teams/{t}/channels`, and the measured answer for the team it left no longer lists it.
    func testSidebarDropsARecordThatMovedToAnotherTeam() async {
        let (model, _) = await sidebarModel()
        XCTAssertNotNil(model.entry(id: "gm1"))

        let converted = channel("gm1", name: "t088-live", displayName: "T088 Live", type: "P",
                                teamID: "other-team")
        let outcome = model.handle(.channelUpdated(converted), myUserID: "me")

        XCTAssertEqual(outcome, .applied)
        XCTAssertNil(model.entry(id: "gm1"),
                     "a channel of another team is not a row of this team's list")
    }

    /// The frame the card named: only the id, so the cheap refresh (the same endpoint the row is built
    /// from) is what replaces the record.
    func testSidebarChannelConvertedSchedulesTheCheapRefresh() async {
        let (model, service) = await sidebarModel()
        service.convertedChannels = [channel("gm1", name: "t088-live",
                                             displayName: "T088 Live", type: "P", teamID: "t1")]

        let outcome = model.handle(.channelConverted(SocketChannelConverted(channelID: "gm1")),
                                   myUserID: "me")

        XCTAssertEqual(outcome, .refreshNeeded,
                       "the frame names only the channel, so the row's record has to be re-read")
    }

    func testSidebarIgnoresAConversionOfAChannelItDoesNotHold() async {
        let (model, _) = await sidebarModel()

        let outcome = model.handle(.channelConverted(SocketChannelConverted(channelID: "unknown")),
                                   myUserID: "me")

        XCTAssertEqual(outcome, .ignored)
    }

    // MARK: - 5. The suppression rule

    /// Upstream's `EphemeralStore.isConvertingChannel`: while **this app** is converting a channel, the
    /// frame that echoes that write is not delivered (`app/actions/websocket/channel.ts:86` and `:104`),
    /// because the flow that wrote it has already applied the record and a second read of the same
    /// channel would race the flow's own navigation.
    func testTheEchoOfThisAppsOwnConversionIsSuppressed() async throws {
        let harness = try await railHarness()
        harness.navigation.beginChannelConversion("gm1")

        harness.events.emit(.channelUpdated(channel("gm1", type: "P", teamID: "perf")),
                            serverID: harness.server.id)
        harness.events.emit(.hello(SocketHello(connectionID: "c", serverVersion: "9.11.19")),
                            serverID: harness.server.id)
        await awaitSignal("the sentinel event was handled", signal: harness.handled.signal) { $0 == 1 }

        XCTAssertEqual(harness.delivered, 0, "the echo must not reach the panes")
        XCTAssertEqual(harness.coordinator.suppressedConversionEchoCount, 1,
                       "the drop is counted, so \"suppressed\" is not indistinguishable from \"never sent\"")
    }

    /// Both frames the server uses for a conversion are covered — a privacy conversion sends both.
    func testTheSuppressionCoversEveryChannelRecordFrameForTheConvertingChannel() async throws {
        let harness = try await railHarness()
        harness.navigation.beginChannelConversion("gm1")

        harness.events.emit(.channelConverted(SocketChannelConverted(channelID: "gm1", teamID: "perf")),
                            serverID: harness.server.id)
        harness.events.emit(.hello(SocketHello(connectionID: "c", serverVersion: "9.11.19")),
                            serverID: harness.server.id)
        await awaitSignal("the sentinel event was handled", signal: harness.handled.signal) { $0 == 1 }

        XCTAssertEqual(harness.delivered, 0)
        XCTAssertEqual(harness.coordinator.suppressedConversionEchoCount, 1)
    }

    /// The bracket is closed when the write answers (success *or* failure), so the channel's frames are
    /// live again — a second client converting it later must reach the panes.
    func testTheEchoIsDeliveredAgainOnceTheConversionEnds() async throws {
        let harness = try await railHarness()
        harness.navigation.beginChannelConversion("gm1")
        harness.navigation.endChannelConversion("gm1")

        harness.events.emit(.channelUpdated(channel("gm1", type: "P", teamID: "perf")),
                            serverID: harness.server.id)
        harness.events.emit(.hello(SocketHello(connectionID: "c", serverVersion: "9.11.19")),
                            serverID: harness.server.id)
        await awaitSignal("the sentinel event was handled", signal: harness.handled.signal) { $0 == 1 }

        XCTAssertEqual(harness.delivered, 1, "the channel is not being converted any more")
        XCTAssertEqual(harness.coordinator.suppressedConversionEchoCount, 0)
    }

    /// Other channels are not affected by a conversion in flight: the registry is keyed by channel id,
    /// like upstream's ephemeral store.
    func testAConversionInFlightDoesNotSuppressAnotherChannelsRecord() async throws {
        let harness = try await railHarness()
        harness.navigation.beginChannelConversion("gm1")

        harness.events.emit(.channelUpdated(channel("gm2", type: "P", teamID: "perf")),
                            serverID: harness.server.id)
        harness.events.emit(.hello(SocketHello(connectionID: "c", serverVersion: "9.11.19")),
                            serverID: harness.server.id)
        await awaitSignal("the sentinel event was handled", signal: harness.handled.signal) { $0 == 1 }

        XCTAssertEqual(harness.delivered, 1)
        XCTAssertEqual(harness.coordinator.suppressedConversionEchoCount, 0)
    }

    /// The flow brackets the write: the registry holds the channel *during* the request (which is when
    /// the server's echo can arrive — measured: the frame and the HTTP answer landed together) and
    /// releases it on both answers.
    func testTheConversionFlowMarksTheChannelInFlightForTheDurationOfTheWrite() async {
        let tracker = Tc407ConversionTracker()
        let service = Tc407ConversionService()
        service.channelValue = channel("gm1", displayName: "alice, bob", type: "G")
        service.commonTeamValues = [MMTeam(id: "t1", name: "perf", displayName: "Perf")]
        service.onConvert = { tracker.isConvertingChannel("gm1") }
        let model = ConvertGMToChannelViewModel(channel: channel("gm1", displayName: "alice, bob", type: "G"),
                                                isGuest: false,
                                                serverVersion: "9.11.19",
                                                service: service,
                                                conversions: tracker)
        await model.load()
        model.draft.displayName = "T088 Live"
        model.draft.urlName = "t088-live"
        model.draft.urlNameEdited = true
        XCTAssertTrue(model.canSubmit,
                      "phase=\(model.phase) team=\(String(describing: model.draft.teamID))"
                      + " error=\(model.errorMessage ?? "nil")"
                      + " validation=\(model.validationMessage ?? "nil")")

        let converted = await model.convert()

        XCTAssertNotNil(converted, "error=\(model.errorMessage ?? "nil")")
        XCTAssertEqual(service.markedDuringWrite, true,
                       "the echo must be suppressed while the write is in flight")
        XCTAssertFalse(tracker.isConvertingChannel("gm1"),
                       "the bracket closes when the write answers, so the channel is live again")
    }

    /// A refused write releases the bracket too (upstream's `finally`): a conversion that failed must not
    /// silence the channel for the rest of the session.
    func testARefusedConversionAlsoReleasesTheInFlightMark() async {
        let tracker = Tc407ConversionTracker()
        let service = Tc407ConversionService()
        service.channelValue = channel("gm1", displayName: "alice, bob", type: "G")
        service.commonTeamValues = [MMTeam(id: "t1", name: "perf", displayName: "Perf")]
        service.convertError = MMError.client(status: 400,
                                             message: "app.channel.group_message_conversion.incorrect_team")
        let model = ConvertGMToChannelViewModel(channel: channel("gm1", displayName: "alice, bob", type: "G"),
                                                isGuest: false,
                                                serverVersion: "9.11.19",
                                                service: service,
                                                conversions: tracker)
        await model.load()
        model.draft.displayName = "T088 Live"
        model.draft.urlName = "t088-live"
        model.draft.urlNameEdited = true

        let converted = await model.convert()

        XCTAssertNil(converted)
        XCTAssertNotNil(model.errorMessage, "the server's refusal must be reported")
        XCTAssertFalse(tracker.isConvertingChannel("gm1"))
    }

    // MARK: - Harness

    /// The sidebar model under test: one group-message row plus one ordinary channel.
    private func sidebarModel() async -> (ChannelListViewModel, Tc407SidebarService) {
        let service = Tc407SidebarService(data: ChannelSidebarData(
            channels: [channel("gm1", displayName: "alice, bob", type: "G"),
                       channel("c1", name: "town-square", displayName: "Town Square",
                               type: "O", teamID: "t1")],
            members: [],
            categories: [ChannelSidebarDerivation.defaultCategory(.directMessages, userID: "me",
                                                                  teamID: "t1"),
                         ChannelSidebarDerivation.defaultCategory(.channels, userID: "me",
                                                                  teamID: "t1")],
            categoryOrder: [],
            directLabels: ["gm1": "Alice, Bob"]))
        let model = ChannelListViewModel(server: server(), service: service)
        model.setSelection(teamID: "t1", channelID: nil, channelName: nil)
        await model.load()
        return (model, service)
    }

    private struct RailHarness {
        let server: ServerConfig
        let coordinator: TeamSidebarCoordinator
        let events: Tc407TeamEventSource
        let navigation: NativeNavigation
        let handled: SignalCounter
        let deliveredBox: SignalCounter

        var delivered: Int { deliveredBox.count }
    }

    /// A rail whose socket is a scripted stream, with one team's channel listed so the scope admits the
    /// frames for `gm1`/`gm2`.
    private func railHarness() async throws -> RailHarness {
        let server = server()
        let navigation = makeNavigation([server])
        _ = navigation.openChannel(NativeChannelRequest(serverID: server.id, teamID: "perf",
                                                        channelID: "gm1"))
        let events = Tc407TeamEventSource()
        let service = Tc407TeamService()
        let coordinator = TeamSidebarCoordinator(events: events,
                                                 unreadRefreshDelay: 0.01,
                                                 makeService: { _ in service },
                                                 tokenProvider: { _ in "tok-tc407" })
        coordinator.bind(auth: AuthCoordinator(), navigation: navigation, serverStore: nil)
        coordinator.setChannelTeams(["gm1": "perf", "gm2": "perf"], for: server.id)
        let handled = SignalCounter()
        let delivered = SignalCounter()
        coordinator.onServerEvent = { _, _ in handled.bump() }
        // Only a channel-record frame counts as a delivery: the sentinel `.hello` that orders the wait
        // is delivered too, and counting it would make "suppressed" untestable.
        coordinator.onTeamEvent = { _, event in
            if event.conversionEchoChannelID != nil { delivered.bump() }
        }

        await coordinator.activate(server)
        await awaitSignal("the socket subscribed", signal: events.subscribedSignal) { $0 == 1 }
        return RailHarness(server: server, coordinator: coordinator, events: events,
                           navigation: navigation, handled: handled, deliveredBox: delivered)
    }
}

// MARK: - Fakes

/// A tiny stand-in for `NativeNavigation`'s conversion registry: the view model only needs the three
/// calls, and a test wants to read them at the exact moment of the write.
@MainActor
private final class Tc407ConversionTracker: ChannelConversionTracking {
    private var converting: Set<String> = []
    private(set) var began: [String] = []
    private(set) var ended: [String] = []

    func beginChannelConversion(_ channelID: String) {
        began.append(channelID)
        converting.insert(channelID)
    }

    func endChannelConversion(_ channelID: String) {
        ended.append(channelID)
        converting.remove(channelID)
    }

    func isConvertingChannel(_ channelID: String) -> Bool { converting.contains(channelID) }
}

/// The pane's service: one channel record, no posts.
@MainActor
private final class Tc407ChannelService: ChannelServing {
    var channel: MMChannel?
    private(set) var channelReads = 0
    var pageSize: Int = 60

    init(channel: MMChannel?) { self.channel = channel }

    func channel(id: String) async throws -> MMChannel {
        channelReads += 1
        guard let channel else { throw MMError.notFound }
        return channel
    }

    func posts(channelID: String, before: String?, perPage: Int) async throws -> MMPostList {
        MMPostList(order: [], posts: [:])
    }

    func users(ids: [String]) async throws -> [MMUser] { [] }
    func fileData(fileID: String, preferThumbnail: Bool) async throws -> Data { throw MMError.notFound }
    func memberCount(channelID: String) async throws -> Int64? { nil }
}

/// The sidebar's service: it remembers what the "server" holds, counts requests, and answers a refresh
/// with the channels a test has set (the conversion's new record).
@MainActor
private final class Tc407SidebarService: ChannelSidebarServing {
    var data: ChannelSidebarData
    /// What `/users/me/teams/{t}/channels` answers after a conversion.
    var convertedChannels: [MMChannel] = []
    private(set) var requests = 0

    init(data: ChannelSidebarData) { self.data = data }

    func load(teamID: String) async throws -> ChannelSidebarData { data }

    func refresh(teamID: String) async throws -> ChannelSidebarRefresh {
        requests += 1
        let channels = convertedChannels.isEmpty ? data.channels : convertedChannels
        data.replaceCounters(channels: channels, members: data.members)
        return ChannelSidebarRefresh(channels: channels, members: data.members)
    }

    func save(categories: [MMSidebarCategory], teamID: String) async throws -> [MMSidebarCategory] {
        categories
    }

    func setMuted(_ muted: Bool, channelID: String) async throws {}
}

/// The conversion screen's service. It implements the whole `ChannelInfoServing` surface because
/// `ChannelConversionServing` refines it; only the six calls the form makes answer anything.
@MainActor
private final class Tc407ConversionService: ChannelConversionServing {
    var channelValue = MMChannel(id: "gm1", name: "gm", displayName: "alice, bob", type: "G")
    var commonTeamValues: [MMTeam] = []
    var memberValues: [MMChannelMember] = []
    var convertError: Error?
    /// Called inside the write, answering the registry's state at that moment.
    var onConvert: (() -> Bool)?
    private(set) var markedDuringWrite: Bool?

    func channel(id: String) async throws -> MMChannel { channelValue }
    func stats(channelID: String) async throws -> MMChannelStats { MMChannelStats(channelID: channelID) }
    func principal() async throws -> MMPrincipal { MMPrincipal(id: "me", username: "me",
                                                               roles: "system_user") }
    func myMembership(channelID: String) async throws -> MMChannelMember { throw MMError.notFound }
    func myTeamMembership(teamID: String) async throws -> MMTeamMembership {
        MMTeamMembership(userId: "me", teamId: teamID, roles: "team_user")
    }
    func teamMembership(teamID: String, userID: String) async throws -> MMTeamMembership {
        throw MMError.notFound
    }
    func rolePermissions(names: [String]) async throws -> [MMRole] { [] }
    func members(channelID: String, page: Int, perPage: Int) async throws -> [MMChannelMember] {
        memberValues
    }
    func member(channelID: String, userID: String) async throws -> MMChannelMember { throw MMError.notFound }
    func users(ids: [String]) async throws -> [MMUser] { [] }
    func statuses(ids: [String]) async throws -> [MMStatus] { [] }
    func patch(channelID: String, patch: MMChannelPatch) async throws -> MMChannel { throw MMError.notFound }
    func archive(channelID: String) async throws -> MMChannel { throw MMError.notFound }
    func restore(channelID: String) async throws -> MMChannel { throw MMError.notFound }
    func addMember(channelID: String, userID: String) async throws -> MMChannelMember { throw MMError.notFound }
    func removeMember(channelID: String, userID: String) async throws {}
    func closeDirectChannel(userID: String, channelID: String) async throws {}
    func myTeamChannels(teamID: String) async throws -> [MMChannel] { [] }
    func teamPublicChannels(teamID: String, page: Int, perPage: Int) async throws -> [MMChannel] { [] }
    func usersNotInChannel(teamID: String, channelID: String,
                           page: Int, perPage: Int) async throws -> [MMUser] { [] }
    func searchUsersNotInChannel(teamID: String, channelID: String, term: String) async throws -> [MMUser] { [] }
    func commonTeams(channelID: String) async throws -> [MMTeam] { commonTeamValues }
    func serverVersionID() async -> String? { "9.11.19" }

    func convertGroupMessage(channelID: String, teamID: String,
                             displayName: String, name: String) async throws -> MMChannel {
        markedDuringWrite = onConvert?()
        if let convertError { throw convertError }
        return MMChannel(id: channelID, name: name, displayName: displayName,
                         type: "P", teamId: teamID, createAt: 1)
    }
}

/// A scripted socket: one stream per server, events pushed by the test.
@MainActor
private final class Tc407TeamEventSource: TeamEventSourcing {
    private(set) var connectCount = 0
    private(set) var openConnectionCount = 0
    private var continuations: [UUID: AsyncStream<SocketEvent>.Continuation] = [:]
    let subscribedSignal = TestSignal<Int>()

    func events(for server: ServerConfig, token: String) async -> AsyncStream<SocketEvent>? {
        connectCount += 1
        subscribedSignal.send(connectCount)
        let (stream, continuation) = AsyncStream.makeStream(of: SocketEvent.self,
                                                            bufferingPolicy: .bufferingNewest(64))
        if continuations[server.id] == nil { openConnectionCount += 1 }
        continuations[server.id] = continuation
        return stream
    }

    func close(serverID: UUID) async {
        guard let continuation = continuations.removeValue(forKey: serverID) else { return }
        continuation.finish()
        openConnectionCount = max(0, openConnectionCount - 1)
    }

    func emit(_ event: SocketEvent, serverID: UUID) {
        continuations[serverID]?.yield(event)
    }
}

/// The rail's service: one team, nothing to count.
@MainActor
private final class Tc407TeamService: TeamSidebarServing {
    func load() async throws -> TeamSidebarData {
        TeamSidebarData(teams: [MMTeam(id: "perf", name: "perf", displayName: "Perf")],
                        memberships: [MMTeamMembership(userId: "me", teamId: "perf",
                                                       roles: "team_user")],
                        unreads: [],
                        order: ["perf"])
    }

    func unreads() async throws -> [MMTeamUnread] { [] }
    func icon(for teamID: String, lastUpdateAt: Int64) async -> Data? { nil }
}
