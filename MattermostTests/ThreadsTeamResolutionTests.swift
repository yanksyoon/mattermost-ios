// The Threads pane must not turn an unresolved team into a URL.
//
// Reported: the Threads list showed "These threads are not available." — the 404 copy in
// `GlobalThreadsViewModel.message(for:)`. Measured against the pinned 9.11.19 server:
//
//   GET /api/v4/users/me/teams/town-square/threads  -> 404   (a team *name* in the id slot)
//   GET /api/v4/users/me/teams//threads             -> 301 -> /users/me/teams/threads -> 404
//
// so the screen was the server refusing a request the shell should never have sent: no team was
// resolved, and "" became a path segment. These tests pin every place that made that possible — the
// model, the coordinator's cache key, the route, the thread write path, and the missing diagnostic —
// plus the healthy case the fix must not break (a real team asks its own path exactly once).

import XCTest
@testable import Mattermost

@MainActor
final class ThreadsTeamResolutionTests: XCTestCase {

    func testAnEmptyTeamIssuesNoRequestAndReportsTheNoTeamState() async {
        let service = FakeThreadService()
        service.loadError = MMError.notFound
        let model = makeModel(teamID: "", service: service)

        await model.load()
        await model.reload()

        XCTAssertEqual(service.threadListRequests.count, 0,
                       "a missing team is not a request: it used to become /users/me/teams//threads")
        XCTAssertEqual(model.phase, .noTeam)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(model.lastFailureDiagnostic, "nothing was asked, so nothing was refused")
        XCTAssertEqual(GlobalThreadsViewModel.noTeamMessage, "Choose a team to see your threads.")
        if case .failed(let message) = model.phase {
            XCTFail("the no-team state must not borrow the 404 copy ('\(message)')")
        }
    }

    func testAThreadsModelWithATeamAsksForItsTeamPathExactlyOnce() async {
        let service = FakeThreadService()
        let model = makeModel(teamID: "town-square", service: service)

        await model.load()
        await model.load()

        XCTAssertEqual(service.threadListRequests.count, 1, "a loaded list is not asked for again")
        guard let request = service.threadListRequests.first else { return XCTFail("no request") }
        XCTAssertEqual("/users/me/teams/\(request.teamID)/threads",
                       "/users/me/teams/town-square/threads")
        XCTAssertEqual(request.before, nil)
    }

    func testA404MapsToTheExistingCopyAndRecordsThePathAndStatus() async {
        let service = FakeThreadService()
        service.loadError = MMError.notFound
        let model = makeModel(teamID: "town-square", service: service)
        let log = LogBox()
        Logger.testSink = { log.append($0) }
        defer { Logger.testSink = nil }

        await model.load()

        XCTAssertEqual(model.phase, .failed("These threads are not available."))
        guard let diagnostic = model.lastFailureDiagnostic else {
            return XCTFail("a 404 from the list must leave a diagnosable line")
        }
        XCTAssertTrue(diagnostic.contains("/users/me/teams/town-square/threads"),
                      "the line must name the request that was refused: \(diagnostic)")
        XCTAssertTrue(diagnostic.contains("status=404"),
                      "the line must name the status: \(diagnostic)")
        XCTAssertTrue(log.lines.contains { $0.contains(diagnostic) },
                      "the line must reach the log, not only the model: \(log.lines)")
    }

    func testNoModelIsCachedUnderAnEmptyTeamKey() {
        let coordinator = ThreadCoordinator()
        coordinator.serviceFactory = { _ in FakeThreadService() }
        let server = ServerConfig(name: "Example", url: URL(string: "https://mm.example")!)

        let fromNil = coordinator.globalModel(for: server, teamID: nil)
        let fromEmpty = coordinator.globalModel(for: server, teamID: "")

        XCTAssertEqual(coordinator.globalModelCount, 0, "a teamless model has nothing to cache")
        XCTAssertFalse(fromNil === fromEmpty, "a placeholder handed back twice is a memoised one")
        XCTAssertEqual(fromNil.teamID, "")
        XCTAssertEqual(fromNil.phase, .noTeam)

        let real = coordinator.globalModel(for: server, teamID: "town-square")
        let again = coordinator.globalModel(for: server, teamID: "town-square")

        XCTAssertEqual(coordinator.globalModelCount, 1)
        XCTAssertTrue(real === again, "one list per (server, team)")
        XCTAssertFalse(real === fromNil, "the real team must not reuse the teamless placeholder")
    }

    func testATeamlessRequestTakesTheShellsTeamWhenOneIsShowing() {
        let coordinator = ThreadCoordinator()
        coordinator.serviceFactory = { _ in FakeThreadService() }
        let (navigation, server, store) = makeNavigation()
        navigation.directory = FixedTeamDirectory(teamID: "shell-team")
        coordinator.bind(auth: nil, navigation: navigation, serverStore: nil, channelPanes: nil)
        _ = store

        let model = coordinator.globalModel(for: server, teamID: nil)

        XCTAssertEqual(model.teamID, "shell-team",
                       "the shell's team is a fact the caller lacked, not a guess")
        XCTAssertEqual(coordinator.globalModelCount, 1)
        XCTAssertTrue(coordinator.globalModel(for: server, teamID: "shell-team") === model,
                      "a completed request must be the same list, so the badge and the pane agree")
    }

    func testAThreadOpenedWithoutATeamTakesTheShellsTeam() {
        let coordinator = ThreadCoordinator()
        coordinator.serviceFactory = { _ in FakeThreadService() }
        let (navigation, server, store) = makeNavigation()
        navigation.directory = FixedTeamDirectory(teamID: "shell-team")
        coordinator.bind(auth: nil, navigation: navigation, serverStore: nil, channelPanes: nil)
        _ = store

        let model = coordinator.model(for: server, rootID: "root-1", channelID: nil)

        XCTAssertEqual(model.teamID, "shell-team",
                       "a thread's follow/read writes must not be built from an empty team either")
    }

    func testAThreadsRouteWithoutATeamTakesTheShellsCurrentTeam() {
        let (navigation, server, store) = makeNavigation()
        navigation.directory = FixedTeamDirectory(teamID: "shell-team")
        _ = store

        let outcome = navigation.openThreads(NativeChannelRequest(serverID: server.id))

        guard case .opened(let location) = outcome else {
            return XCTFail("expected the route to open, got \(outcome)")
        }
        XCTAssertEqual(location.pane, .threads)
        XCTAssertEqual(location.teamID, "shell-team",
                       "a threads route must carry the team the shell is showing")
    }

    func testAThreadsRouteKeepsTheTeamItsCallerNamed() {
        let (navigation, server, store) = makeNavigation()
        navigation.directory = FixedTeamDirectory(teamID: "shell-team")
        _ = store

        let outcome = navigation.openThreads(NativeChannelRequest(serverID: server.id,
                                                                  teamID: "route-team"))

        guard case .opened(let location) = outcome else {
            return XCTFail("expected the route to open, got \(outcome)")
        }
        XCTAssertEqual(location.teamID, "route-team", "the caller's fact wins over the fallback")
    }

    private func makeModel(teamID: String, service: FakeThreadService) -> GlobalThreadsViewModel {
        GlobalThreadsViewModel(teamID: teamID,
                               service: service,
                               myUserID: "me",
                               now: { Date(timeIntervalSince1970: 1_000) })
    }

    private func makeNavigation() -> (navigation: NativeNavigation, server: ServerConfig, store: ServerStore) {
        let suite = "threads-team-resolution-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = ServerStore(preferences: AppPreferences(defaults: defaults))
        let server = ServerConfig(name: "Example", url: URL(string: "https://mm.example")!)
        _ = store.add(server)
        let navigation = NativeNavigation()
        navigation.serverStore = store
        navigation.viewStore = ViewStore()
        navigation.authGate = AlwaysSignedIn()
        return (navigation: navigation, server: server, store: store)
    }
}

@MainActor
private final class FixedTeamDirectory: NativeChannelDirectory {
    private let teamID: String

    init(teamID: String) { self.teamID = teamID }

    func identity(for request: NativeChannelRequest, serverID: UUID) -> NativeChannelIdentity? { nil }

    func currentTeamID(serverID: UUID) -> String? { teamID }
}

@MainActor
private final class AlwaysSignedIn: NativeAuthGate {
    func authState(for server: ServerConfig) -> NativeAuthState { .signedIn }
}

/// Collects the lines `Logger` is about to write (DEBUG-only sink).
private final class LogBox {
    private(set) var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
}
