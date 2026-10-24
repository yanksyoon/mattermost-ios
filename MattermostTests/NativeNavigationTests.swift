import XCTest
import UserNotifications
import WebKit
@testable import Mattermost

/// T30 — the native shell's navigation model.
///
/// The claim this card makes is structural, so the tests are structural too: **one** funnel
/// (`NativeNavigation.open`) that a deep link, a notification tap and a manual tap all go through,
/// producing one comparable `NativeLocation`. If those three diverge, the shell's "same place" claim
/// is false even when each individual path looks right — hence
/// `testDeepLinkMentionAndManualSelectionConvergeOnTheSameLocation`, which compares the three
/// results with `==` rather than comparing visible behaviour.
@MainActor
final class NativeNavigationTests: XCTestCase {

    // MARK: Fixtures

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "NativeNavigationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func preferences() -> AppPreferences {
        AppPreferences(defaults: defaults)
    }

    private func makeServerStore(_ servers: [ServerConfig]) -> ServerStore {
        let store = ServerStore(preferences: preferences())
        for server in servers { _ = store.add(server) }
        return store
    }

    private func server(_ name: String = "Example", host: String = "mm.example") -> ServerConfig {
        ServerConfig(name: name, url: URL(string: "https://\(host)")!)
    }

    /// A resolver pinned to the pane surface's renderer through the documented `-surfaceMode` launch
    /// tier (the same flag the card's acceptance criterion uses).
    private func resolver(_ spec: String?) -> SurfaceModeResolver {
        let args = spec.map { ["-surfaceMode", $0] } ?? []
        return SurfaceModeResolver(preferences: preferences(), arguments: args)
    }

    private func makeNavigation(serverStore: ServerStore,
                                viewStore: ViewStore? = nil,
                                mode: String? = "shell=native",
                                gate: NativeAuthGate? = nil,
                                directory: NativeChannelDirectory? = nil) -> NativeNavigation {
        let navigation = NativeNavigation(resolver: resolver(mode))
        navigation.serverStore = serverStore
        navigation.viewStore = viewStore ?? ViewStore()
        navigation.authGate = gate ?? FixedAuthGate(.signedIn)
        navigation.directory = directory
        return navigation
    }

    // MARK: Deep-link path parsing (upstream `app/utils/deep_link/index.ts` shapes)

    func testChannelPathParsesTeamAndChannelName() {
        guard case .channel(let request)? = NativeNavigation.target(
            forPath: "/acme/channels/general", serverURL: URL(string: "https://mm.example")) else {
            return XCTFail("expected a channel target")
        }
        XCTAssertEqual(request.teamName, "acme")
        XCTAssertEqual(request.channelName, "general")
        XCTAssertNil(request.channelID)
        XCTAssertEqual(request.serverHost, "mm.example")
    }

    func testChannelPathTreatsA26CharSegmentAsAnID() {
        let id = "abcdefghij0123456789klmnop".lowercased()
        XCTAssertEqual(id.count, 26)
        guard case .channel(let request)? = NativeNavigation.target(
            forPath: "/acme/channels/\(id)", serverURL: nil) else {
            return XCTFail("expected a channel target")
        }
        XCTAssertEqual(request.channelID, id, "an id-shaped segment is an id, not a name (upstream isValidId)")
        XCTAssertNil(request.channelName)
    }

    func testChannelPathCarriesThePostID() {
        guard case .channel(let request)? = NativeNavigation.target(
            forPath: "/acme/channels/general/post42", serverURL: nil) else {
            return XCTFail("expected a channel target")
        }
        XCTAssertEqual(request.channelName, "general")
        XCTAssertEqual(request.postID, "post42")
    }

    func testPermalinkPathKeepsThePostAndNoChannel() {
        guard case .channel(let request)? = NativeNavigation.target(
            forPath: "/acme/pl/post42", serverURL: nil) else {
            return XCTFail("expected a channel target")
        }
        XCTAssertEqual(request.postID, "post42")
        XCTAssertNil(request.channelName, "a permalink does not name its channel")
    }

    func testDirectMessagePathStripsTheAt() {
        guard case .channel(let request)? = NativeNavigation.target(
            forPath: "/acme/messages/@bob", serverURL: nil) else {
            return XCTFail("expected a channel target")
        }
        XCTAssertEqual(request.channelName, "bob")
    }

    func testThreadsPathIsAThreadsTarget() {
        guard case .threads(let request)? = NativeNavigation.target(
            forPath: "/acme/threads", serverURL: nil) else {
            return XCTFail("expected a threads target")
        }
        XCTAssertEqual(request.teamName, "acme")
    }

    func testTeamRootAndRootAreHomeTargets() {
        guard case .home(_, let host)? = NativeNavigation.target(
            forPath: "/acme", serverURL: URL(string: "https://mm.example")) else {
            return XCTFail("expected a home target")
        }
        XCTAssertEqual(host, "mm.example")

        guard case .home? = NativeNavigation.target(forPath: "/", serverURL: nil) else {
            return XCTFail("expected a home target")
        }
    }

    func testUnknownSectionIsNotGuessed() {
        XCTAssertNil(NativeNavigation.target(forPath: "/acme/whatever/x", serverURL: nil))
    }

    // MARK: The funnel — deep link

    func testDeepLinkSwitchesServerAndOpensTheChannel() {
        let first = server("First", host: "one.example")
        let second = server("Second", host: "two.example")
        let store = makeServerStore([first, second])
        store.switchTo(id: first.id)
        let viewStore = ViewStore()
        viewStore.setPrimary(first.id)
        let navigation = makeNavigation(serverStore: store, viewStore: viewStore)

        let outcome = navigation.handle("mattermost://two.example/acme/channels/general")

        guard case .opened(let location) = outcome else {
            return XCTFail("expected .opened, got \(outcome)")
        }
        XCTAssertEqual(location.serverID, second.id, "the link's host picks the server")
        XCTAssertEqual(location.serverName, "Second")
        XCTAssertEqual(location.teamName, "acme")
        XCTAssertEqual(location.channelName, "general")
        XCTAssertEqual(store.activeServerID, second.id, "the shell switches server as part of routing")
        XCTAssertEqual(viewStore.primaryServerID, second.id)
    }

    func testDeepLinkToAnUnknownHostAsksToAddTheServer() {
        let store = makeServerStore([server()])
        let navigation = makeNavigation(serverStore: store)

        let outcome = navigation.handle("mattermost://other.example/acme/channels/general")

        XCTAssertEqual(outcome, .needsServerAdd(serverURL: URL(string: "https://other.example")))
        XCTAssertEqual(navigation.location.serverID, nil, "an unknown host must not move the shell")
    }

    func testUnparseableDeepLinkIsReported() {
        let store = makeServerStore([server()])
        let navigation = makeNavigation(serverStore: store)
        guard case .unsupported = navigation.handle("mattermost://mm.example/acme/nope/x") else {
            return XCTFail("an unrecognised path must be reported, not guessed")
        }
    }

    // MARK: The funnel — notification tap

    func testMentionTapOpensTheChannelByID() {
        let serverConfig = server()
        let store = makeServerStore([serverConfig])
        let navigation = makeNavigation(serverStore: store)

        let outcome = navigation.routeMention(serverID: serverConfig.id, channelID: "c1", teamID: "t1")

        guard case .opened(let location) = outcome else {
            return XCTFail("expected .opened, got \(outcome)")
        }
        XCTAssertEqual(location.serverID, serverConfig.id)
        XCTAssertEqual(location.channelID, "c1")
        XCTAssertEqual(location.teamID, "t1")
    }

    // MARK: Convergence — the acceptance criterion that matters

    /// A deep link (names), a mention tap (ids) and a manual sidebar tap (both) must land on the
    /// **same** `NativeLocation` for the same channel. The directory is what makes that possible:
    /// it is the seam S08 (T32/T33) fills, and here it is fed by the test instead of by the store.
    func testDeepLinkMentionAndManualSelectionConvergeOnTheSameLocation() {
        let serverConfig = server()
        let store = makeServerStore([serverConfig])
        let directory = FakeDirectory(identities: [
            "general": NativeChannelIdentity(teamID: "t1", teamName: "acme",
                                             channelID: "c1", channelName: "general"),
            "c1": NativeChannelIdentity(teamID: "t1", teamName: "acme",
                                        channelID: "c1", channelName: "general"),
        ])
        let navigation = makeNavigation(serverStore: store, directory: directory)

        guard case .opened(let fromDeepLink) = navigation.handle(
            "mattermost://mm.example/acme/channels/general") else {
            return XCTFail("deep link did not open")
        }
        guard case .opened(let fromMention) = navigation.routeMention(
            serverID: serverConfig.id, channelID: "c1", teamID: "t1") else {
            return XCTFail("mention tap did not open")
        }
        guard case .opened(let fromManual) = navigation.openChannel(
            NativeChannelRequest(serverID: serverConfig.id,
                                 teamID: "t1", teamName: "acme",
                                 channelID: "c1", channelName: "general")) else {
            return XCTFail("manual selection did not open")
        }

        XCTAssertEqual(fromDeepLink, fromMention, "deep link and mention tap must land in one place")
        XCTAssertEqual(fromMention, fromManual, "mention tap and manual selection must land in one place")
        XCTAssertEqual(fromDeepLink, navigation.location)
        XCTAssertEqual(fromDeepLink.channelID, "c1")
        XCTAssertEqual(fromDeepLink.channelName, "general", "the name is filled in from the id")
    }

    /// Without a directory the shell keeps exactly the keys it was given — it must not invent a
    /// name or an id from the other half.
    func testResolutionWithoutADirectoryKeepsTheKeysTheCallerHad() {
        let store = makeServerStore([server()])
        let navigation = makeNavigation(serverStore: store)

        guard case .opened(let location) = navigation.handle(
            "mattermost://mm.example/acme/channels/general") else {
            return XCTFail("deep link did not open")
        }
        XCTAssertEqual(location.channelName, "general")
        XCTAssertNil(location.channelID)
        XCTAssertNil(location.teamID)
    }

    // MARK: Auth surface

    func testSignedOutServerShowsTheAuthSurfaceInsteadOfAChannel() {
        let serverConfig = server()
        let store = makeServerStore([serverConfig])
        let navigation = makeNavigation(serverStore: store, gate: FixedAuthGate(.signedOut))

        let outcome = navigation.handle("mattermost://mm.example/acme/channels/general")

        guard case .needsAuth(let location) = outcome else {
            return XCTFail("expected .needsAuth, got \(outcome)")
        }
        XCTAssertEqual(location.serverID, serverConfig.id, "the shell still switches to the linked server")
        XCTAssertFalse(location.hasChannel, "no channel may be opened behind a sign-in wall")
        XCTAssertEqual(navigation.authState, .signedOut)
    }

    func testRefreshAuthStateReflectsASignIn() {
        let serverConfig = server()
        let store = makeServerStore([serverConfig])
        let gate = FixedAuthGate(.signedOut)
        let navigation = makeNavigation(serverStore: store, gate: gate)
        _ = navigation.openHome(serverID: serverConfig.id)
        XCTAssertEqual(navigation.authState, .signedOut)

        gate.state = .signedIn
        navigation.refreshAuthState()
        XCTAssertEqual(navigation.authState, .signedIn)
    }

    // MARK: Push path (the compact layout's stack)

    func testChannelOpensAsOnePush() {
        let serverConfig = server()
        let store = makeServerStore([serverConfig])
        let navigation = makeNavigation(serverStore: store)

        _ = navigation.openChannel(NativeChannelRequest(serverID: serverConfig.id, teamName: "acme", channelName: "general"))
        XCTAssertEqual(navigation.path.count, 1)
        XCTAssertEqual(navigation.path.last?.channelName, "general")

        // Re-opening the same channel must not stack a duplicate.
        _ = navigation.openChannel(NativeChannelRequest(serverID: serverConfig.id, teamName: "acme", channelName: "general"))
        XCTAssertEqual(navigation.path.count, 1)
    }

    func testThreadPushesOnTopOfItsChannel() {
        let serverConfig = server()
        let store = makeServerStore([serverConfig])
        let navigation = makeNavigation(serverStore: store)
        let request = NativeChannelRequest(serverID: serverConfig.id, teamName: "acme", channelName: "general")

        _ = navigation.openChannel(request)
        _ = navigation.openThreads(request)

        XCTAssertEqual(navigation.path.count, 2, "a thread sits on top of its channel so Back returns to it")
        XCTAssertEqual(navigation.path.first?.pane, .channel)
        XCTAssertEqual(navigation.path.last?.pane, .threads)
        XCTAssertEqual(navigation.location.pane, .threads)
    }

    func testOpeningTheWorkspaceRootPopsTheStack() {
        let serverConfig = server()
        let store = makeServerStore([serverConfig])
        let navigation = makeNavigation(serverStore: store)

        _ = navigation.openChannel(NativeChannelRequest(serverID: serverConfig.id, channelName: "general"))
        XCTAssertEqual(navigation.path.count, 1)

        _ = navigation.openHome()
        XCTAssertTrue(navigation.path.isEmpty)
        XCTAssertFalse(navigation.location.hasChannel)
    }

    /// Tab selection is a user action, never a routing result: a deep link into a channel must not
    /// move the tab bar under the user (compact layout pushes over the current tab).
    func testRoutingDoesNotChangeTheSelectedTab() {
        let serverConfig = server()
        let store = makeServerStore([serverConfig])
        let navigation = makeNavigation(serverStore: store)
        navigation.select(tab: .threads)

        _ = navigation.handle("mattermost://mm.example/acme/channels/general")

        XCTAssertEqual(navigation.tab, .threads)
    }

    // MARK: Multi-server

    /// Re-activating the server that is already current must **not** reset the location. This is the
    /// cold-launch race in one assertion: `RootView.startUp()` runs on appearance, and a deep link
    /// (or a notification tap) delivered first must not be undone by it. The UI test
    /// `testNativeShellDeepLinkLandsOnTheChannelInTheNativeStack` failed exactly this way before the
    /// guard existed, so the behaviour is pinned here as well as end-to-end.
    func testActivatingTheAlreadyCurrentServerKeepsTheLocation() {
        let serverConfig = server()
        let store = makeServerStore([serverConfig])
        let navigation = makeNavigation(serverStore: store)

        _ = navigation.openChannel(NativeChannelRequest(serverID: serverConfig.id,
                                                        teamName: "acme", channelName: "general"))
        navigation.activate(serverID: serverConfig.id)

        XCTAssertEqual(navigation.location.channelName, "general",
                       "an appearance pass must not pop a channel that routing already opened")
        XCTAssertEqual(navigation.path.count, 1)
    }

    func testSwitchingServersRemembersWhereEachOneWas() {
        let first = server("First", host: "one.example")
        let second = server("Second", host: "two.example")
        let store = makeServerStore([first, second])
        let navigation = makeNavigation(serverStore: store)

        _ = navigation.openChannel(NativeChannelRequest(serverID: first.id, teamName: "acme", channelName: "general"))
        XCTAssertEqual(navigation.location.serverID, first.id)

        // The switcher moves to the second server: its own (empty) location, not the first's.
        navigation.activate(serverID: second.id)
        XCTAssertEqual(navigation.location.serverID, second.id)
        XCTAssertFalse(navigation.location.hasChannel)

        // …and back: the first server's channel is still where the user left it.
        navigation.activate(serverID: first.id)
        XCTAssertEqual(navigation.location.serverID, first.id)
        XCTAssertEqual(navigation.location.channelName, "general")
    }

    // MARK: The dual-render gate

    func testAcceptsNativeRoutingFollowsThePaneSurface() {
        let store = makeServerStore([server()])
        XCTAssertTrue(makeNavigation(serverStore: store, mode: "shell=native").acceptsNativeRouting)
        XCTAssertTrue(makeNavigation(serverStore: store, mode: "channelView=native").acceptsNativeRouting)
        XCTAssertFalse(makeNavigation(serverStore: store, mode: "channelView=web").acceptsNativeRouting)
        XCTAssertFalse(makeNavigation(serverStore: store, mode: nil).acceptsNativeRouting,
                       "the shipping default is the webview")
    }

    // MARK: Seams — the routers actually divert

    func testDeepLinkRouterDivertsIntoTheNativeShellAndSkipsTheSPA() {
        let serverConfig = server()
        let store = makeServerStore([serverConfig])
        let viewStore = ViewStore()
        let navigation = makeNavigation(serverStore: store, viewStore: viewStore)
        let bridge = RecordingBridge()
        viewStore.ensureStore(for: serverConfig).bridge.delegate = bridge

        let router = DeepLinkRouter()
        router.serverStore = store
        router.viewStore = viewStore
        router.nativeNavigation = navigation
        router.ready()

        let outcome = router.handle("mattermost://mm.example/acme/channels/general")

        XCTAssertEqual(outcome, .routed)
        XCTAssertEqual(navigation.location.channelName, "general")
        XCTAssertTrue(bridge.pushedPaths.isEmpty,
                      "the native shell must not also drive the webview's history")
    }

    /// The same router, same link, pane resolving `web`: today's behaviour, bit for bit (the SPA
    /// push the pre-T30 tests assert).
    func testDeepLinkRouterKeepsTheWebPathWhenThePaneIsWeb() {
        let serverConfig = server()
        let store = makeServerStore([serverConfig])
        let viewStore = ViewStore()
        let navigation = makeNavigation(serverStore: store, viewStore: viewStore, mode: nil)
        let bridge = RecordingBridge()
        viewStore.ensureStore(for: serverConfig).bridge.delegate = bridge

        let router = DeepLinkRouter()
        router.serverStore = store
        router.viewStore = viewStore
        router.nativeNavigation = navigation
        router.ready()

        let outcome = router.handle("mattermost://mm.example/acme/channels/general")

        XCTAssertEqual(outcome, .routed)
        XCTAssertEqual(bridge.pushedPaths, ["/acme/channels/general"],
                       "with the webview pane the link still goes into the SPA router")
        XCTAssertFalse(navigation.location.hasChannel)
    }

    func testNotificationTapDivertsIntoTheNativeShell() {
        let serverConfig = server()
        let store = makeServerStore([serverConfig])
        let viewStore = ViewStore()
        let navigation = makeNavigation(serverStore: store, viewStore: viewStore)
        let bridge = RecordingBridge()
        viewStore.ensureStore(for: serverConfig).bridge.delegate = bridge
        let worker = NotificationWorker(scheduling: SilentScheduling(), preferences: preferences())
        worker.serverStore = store
        worker.viewStore = viewStore
        worker.nativeNavigation = navigation
        worker.reactAppInitialized(serverID: serverConfig.id)

        worker.routeToChannel(serverID: serverConfig.id, channelID: "c1", teamID: "t1")

        XCTAssertEqual(navigation.location.channelID, "c1")
        XCTAssertEqual(store.activeServerID, serverConfig.id)
        XCTAssertTrue(bridge.pushedPaths.isEmpty,
                      "the tapped mention must not also push a SPA path")
    }

    func testNotificationTapKeepsTheSPAPathWhenThePaneIsWeb() {
        let serverConfig = server()
        let store = makeServerStore([serverConfig])
        let viewStore = ViewStore()
        let navigation = makeNavigation(serverStore: store, viewStore: viewStore, mode: nil)
        let bridge = RecordingBridge()
        viewStore.ensureStore(for: serverConfig).bridge.delegate = bridge
        let worker = NotificationWorker(scheduling: SilentScheduling(), preferences: preferences())
        worker.serverStore = store
        worker.viewStore = viewStore
        worker.nativeNavigation = navigation
        worker.reactAppInitialized(serverID: serverConfig.id)

        worker.routeToChannel(serverID: serverConfig.id, channelID: "c1", teamID: "t1")

        XCTAssertEqual(bridge.pushedPaths, ["/channels/c1"])
    }
}

// MARK: - Test doubles

@MainActor
private final class FixedAuthGate: NativeAuthGate {
    var state: NativeAuthState
    init(_ state: NativeAuthState) { self.state = state }
    func authState(for server: ServerConfig) -> NativeAuthState { state }
}

@MainActor
private final class FakeDirectory: NativeChannelDirectory {
    private let identities: [String: NativeChannelIdentity]
    init(identities: [String: NativeChannelIdentity]) { self.identities = identities }
    func identity(for request: NativeChannelRequest, serverID: UUID) -> NativeChannelIdentity? {
        if let id = request.channelID, let identity = identities[id] { return identity }
        if let name = request.channelName, let identity = identities[name] { return identity }
        return nil
    }
}

@MainActor
private final class RecordingBridge: JsBridge {
    weak var webView: WKWebView?
    var pushedPaths: [String] = []
    func handleNotifyMention(_ payload: MentionNotification) {}
    func handleUnreadsAndMentions(_ isUnread: Bool, mentionCount: Int) {}
    func handleSessionExpired(_ isExpired: Bool) {}
    func handleReactAppInitialized() {}
    func handleRequestBrowserHistoryStatus(_ completion: @escaping (BrowserHistoryStatus) -> Void) {
        completion(BrowserHistoryStatus(canGoBack: false, canGoForward: false))
    }
    func pushBrowserHistory(path: String) { pushedPaths.append(path) }
    func navigateHistory(byOffset offset: Int) {}
}

/// A scheduling seam that never touches `UNUserNotificationCenter`.
@MainActor
private final class SilentScheduling: NotificationScheduling {
    var delegate: UNUserNotificationCenterDelegate?
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { false }
    func authorizationStatus() async -> UNAuthorizationStatus { .denied }
    func add(_ request: UNNotificationRequest) async throws {}
}
