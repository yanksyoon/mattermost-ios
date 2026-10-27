import XCTest
@testable import Mattermost

/// T32 — the native team sidebar (S07 team selection, S08 team rail).
///
/// The card's three acceptance criteria are the spine of this file:
///  1. switching teams updates the location, drops the previous team's channel and moves the
///     socket's scope, with no duplicate subscription however fast the taps come;
///  2. one team → no rail chrome, zero teams → the empty state, and nothing is claimed before the
///     first answer arrives;
///  3. per-team mention counts are the server's numbers, formatting included (`99+`, dot, hidden
///     while selected).
///
/// Everything is exercised through the same seams the app uses: the real `NativeNavigation` funnel
/// for switches, a fake `TeamSidebarServing` standing in for the server, and a scripted
/// `TeamEventSourcing` standing in for the socket.
@MainActor
final class T32TeamSidebarTests: XCTestCase {

    // MARK: - Fixtures

    private var suiteName: String!
    private var defaults: UserDefaults!
    /// `NativeNavigation.serverStore` is weak: the test owns the store, the navigator points at it.
    private var retainedStores: [ServerStore] = []

    override func setUp() {
        super.setUp()
        suiteName = "T32TeamSidebarTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        retainedStores.removeAll()
        super.tearDown()
    }

    private func preferences() -> AppPreferences { AppPreferences(defaults: defaults) }

    private func server(_ name: String = "Example", host: String = "mm.example") -> ServerConfig {
        ServerConfig(name: name, url: URL(string: "https://\(host)")!)
    }

    private func team(_ id: String,
                      name: String? = nil,
                      displayName: String? = nil,
                      iconUpdatedAt: Int64 = 0,
                      deleteAt: Int64 = 0) -> MMTeam {
        MMTeam(id: id,
               name: name ?? id,
               displayName: displayName ?? id.capitalized,
               lastTeamIconUpdatedAt: iconUpdatedAt,
               deleteAt: deleteAt)
    }

    private func membership(_ teamID: String,
                            userID: String = "me",
                            deleteAt: Int64 = 0) -> MMTeamMembership {
        MMTeamMembership(userId: userID, teamId: teamID, roles: "team_user", deleteAt: deleteAt)
    }

    private func unread(_ teamID: String, mentions: Int = 0, messages: Int = 0) -> MMTeamUnread {
        MMTeamUnread(teamId: teamID, mentionCount: mentions, msgCount: messages)
    }

    private func data(teams: [MMTeam],
                      memberships: [MMTeamMembership] = [],
                      unreads: [MMTeamUnread] = [],
                      order: [String] = [],
                      unreadsFailed: Bool = false) -> TeamSidebarData {
        TeamSidebarData(teams: teams,
                        memberships: memberships,
                        unreads: unreads,
                        order: order,
                        unreadsFailed: unreadsFailed)
    }

    /// A real `NativeNavigation` over a real `ServerStore`, signed in — the funnel a rail tap
    /// actually goes through, not a stand-in for it.
    private func makeNavigation(_ servers: [ServerConfig],
                                mode: String? = "shell=native") -> NativeNavigation {
        let store = ServerStore(preferences: preferences())
        for server in servers { _ = store.add(server) }
        retainedStores.append(store)
        let resolver = SurfaceModeResolver(preferences: preferences(),
                                           arguments: mode.map { ["-surfaceMode", $0] } ?? [])
        let navigation = NativeNavigation(resolver: resolver)
        navigation.serverStore = store
        navigation.viewStore = ViewStore()
        navigation.authGate = T32FixedAuthGate()
        return navigation
    }

    // MARK: - Decode (the server's shapes, including the fields this client ignores)

    func testTeamUnreadDecodesTheServersRowAndIgnoresExtraCounters() throws {
        let json = """
        {"team_id":"t1","msg_count":7,"mention_count":2,"mention_count_root":1,
         "msg_count_root":5,"thread_count":3,"thread_mention_count":1,
         "thread_urgent_mention_count":0}
        """.data(using: .utf8)!
        let row = try JSONDecoder().decode(MMTeamUnread.self, from: json)
        XCTAssertEqual(row.teamId, "t1")
        XCTAssertEqual(row.mentionCount, 2)
        XCTAssertEqual(row.msgCount, 7)
        XCTAssertEqual(row.id, "t1")
    }

    func testTeamUnreadToleratesAMissingCounterInsteadOfFailingTheWholeTeam() throws {
        let json = #"{"team_id":"t1","mention_count":4}"#.data(using: .utf8)!
        let row = try JSONDecoder().decode(MMTeamUnread.self, from: json)
        XCTAssertEqual(row.mentionCount, 4)
        XCTAssertEqual(row.msgCount, 0, "an absent counter is zero, not a decode failure")
    }

    func testTeamMembershipDecodesSoftDeleteAndRoles() throws {
        let json = #"{"user_id":"u1","team_id":"t1","roles":"team_user team_admin","delete_at":0}"#
            .data(using: .utf8)!
        let row = try JSONDecoder().decode(MMTeamMembership.self, from: json)
        XCTAssertEqual(row.userId, "u1")
        XCTAssertEqual(row.teamId, "t1")
        XCTAssertEqual(row.deleteAt, 0)
        XCTAssertEqual(row.roles, "team_user team_admin")
    }

    func testTeamDecodesTheFieldsTheRailDraws() throws {
        // Captured verbatim from the local server's `/users/me/teams` (a team that *has* an icon).
        let json = """
        {"allow_open_invite":false,"allowed_domains":"","cloud_limits_archived":false,
         "company_name":"","create_at":1792869870337,"delete_at":0,"description":"",
         "display_name":"Operations","email":"perfprobe@example.invalid","group_constrained":null,
         "id":"xs9sxp6s8pysmnrakx31godyye","invite_id":"afstaxuupiypzgh4uzug5zfaoh",
         "last_team_icon_update":1792869870708,"name":"ops","policy_id":null,"scheme_id":null,
         "type":"O","update_at":1792869870708}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MMTeam.self, from: json)
        XCTAssertEqual(decoded.id, "xs9sxp6s8pysmnrakx31godyye")
        XCTAssertEqual(decoded.name, "ops")
        XCTAssertEqual(decoded.displayName, "Operations")
        XCTAssertEqual(decoded.lastTeamIconUpdatedAt, 1792869870708)
        XCTAssertEqual(decoded.deleteAt, 0)
        XCTAssertFalse(decoded.isGroupConstrained, "a null group_constrained is false, not a decode error")
    }

    /// Real-server regression (T32): a team with **no icon** omits `last_team_icon_update`
    /// entirely, and `group_constrained` comes back as `null`. A strict synthesized decode threw on
    /// this, which took the whole team list — and therefore the whole rail — down.
    func testTeamWithoutAnIconDecodesInsteadOfFailingTheWholeList() throws {
        let json = """
        [{"allow_open_invite":false,"allowed_domains":"","cloud_limits_archived":false,
          "company_name":"","create_at":1792821730653,"delete_at":0,"description":"",
          "display_name":"Perf","email":"perfprobe@example.invalid","group_constrained":null,
          "id":"ocz148uck3r88dcjikj497bosh","invite_id":"kg3qb387nbdumbxnq393bzu9kh",
          "name":"perf","policy_id":null,"scheme_id":null,"type":"O","update_at":1792821730653}]
        """.data(using: .utf8)!
        let teams = try JSONDecoder().decode([MMTeam].self, from: json)
        XCTAssertEqual(teams.count, 1)
        XCTAssertEqual(teams[0].name, "perf")
        XCTAssertEqual(teams[0].lastTeamIconUpdatedAt, 0, "no icon update means the initials tile")
        XCTAssertFalse(teams[0].isGroupConstrained)
    }

    // MARK: - Initials (the no-icon fallback)

    func testInitialsAreTheFirstTwoCharactersUppercased() {
        XCTAssertEqual(TeamSidebarDerivation.initials("Operations"), "OP")
        XCTAssertEqual(TeamSidebarDerivation.initials("perf"), "PE")
        XCTAssertEqual(TeamSidebarDerivation.initials("X"), "X")
        XCTAssertEqual(TeamSidebarDerivation.initials("  spaced  "), "SP")
        XCTAssertEqual(TeamSidebarDerivation.initials(""), "")
    }

    /// `String.prefix` counts grapheme clusters; JavaScript's `substring(0, 2)` counts UTF-16 code
    /// units and would cut an emoji or a flag in half. The Swift port must not reproduce that.
    func testInitialsDoNotSplitAGraphemeCluster() {
        XCTAssertEqual(TeamSidebarDerivation.initials("🇯🇵🇰🇷 crew"), "🇯🇵🇰🇷")
        XCTAssertEqual(TeamSidebarDerivation.initials("𝓜𝓜 labs"), "𝓜𝓜")
        XCTAssertEqual(TeamSidebarDerivation.initials("日本語"), "日本")
    }

    // MARK: - Badges

    func testBadgePrefersMentionsThenUnreadThenNothing() {
        XCTAssertEqual(TeamSidebarDerivation.badge(mentionCount: 3, unreadCount: 9, isSelected: false),
                       .count(3))
        XCTAssertEqual(TeamSidebarDerivation.badge(mentionCount: 0, unreadCount: 9, isSelected: false),
                       .dot)
        XCTAssertEqual(TeamSidebarDerivation.badge(mentionCount: 0, unreadCount: 0, isSelected: false),
                       .none)
    }

    func testSelectedTeamDrawsNoBadge() {
        // Upstream hides the badge on the selected item: the user is looking at that team already.
        XCTAssertEqual(TeamSidebarDerivation.badge(mentionCount: 4, unreadCount: 4, isSelected: true),
                       .none)
        let entry = TeamSidebarDerivation.entries(from: data(teams: [team("ops")],
                                                             unreads: [unread("ops", mentions: 4)]),
                                                  userID: nil,
                                                  selectedTeamID: "ops",
                                                  selectedTeamName: nil)[0]
        XCTAssertTrue(entry.isSelected)
        XCTAssertEqual(entry.badge, .none)
        XCTAssertNil(entry.badgeAccessibilityLabel)
    }

    func testBadgeCapsAtNinetyNinePlusButKeepsTheRealNumberInAccessibility() {
        XCTAssertEqual(TeamSidebarBadge.count(99).text, "99")
        XCTAssertEqual(TeamSidebarBadge.count(100).text, "99+")
        XCTAssertEqual(TeamSidebarBadge.count(1_240).text, "99+")
        let entry = TeamSidebarDerivation.entries(from: data(teams: [team("ops")],
                                                             unreads: [unread("ops", mentions: 100)]),
                                                  userID: nil,
                                                  selectedTeamID: nil,
                                                  selectedTeamName: nil)[0]
        XCTAssertEqual(entry.badge.text, "99+")
        XCTAssertEqual(entry.badgeAccessibilityLabel, "more than 99 mentions")
    }

    func testBadgeAccessibilitySaysMentionsAndUnreadInWords() {
        let single = TeamSidebarDerivation.entries(from: data(teams: [team("ops")],
                                                              unreads: [unread("ops", mentions: 1)]),
                                                   userID: nil,
                                                   selectedTeamID: nil,
                                                   selectedTeamName: nil)[0]
        XCTAssertEqual(single.badgeAccessibilityLabel, "1 mention")
        let dot = TeamSidebarDerivation.entries(from: data(teams: [team("ops")],
                                                           unreads: [unread("ops", messages: 6)]),
                                                userID: nil,
                                                selectedTeamID: nil,
                                                selectedTeamName: nil)[0]
        XCTAssertEqual(dot.badge, .dot)
        XCTAssertEqual(dot.badgeAccessibilityLabel, "Unread messages")
    }

    // MARK: - Ordering

    func testTeamsOrderPreferenceComesFirstThenAlphabeticalDisplayName() {
        let teams = [team("b", name: "zeta", displayName: "Zeta"),
                     team("a", name: "alpha", displayName: "Alpha"),
                     team("c", name: "ops", displayName: "Operations")]
        let ordered = TeamSidebarDerivation.sorted(teams, order: ["c"]).map(\.id)
        XCTAssertEqual(ordered, ["c", "a", "b"])
    }

    func testWithoutAPreferenceTheRailIsAlphabeticalAndCaseInsensitive() {
        let teams = [team("1", name: "beta", displayName: "beta"),
                     team("2", name: "Alpha", displayName: "Alpha"),
                     team("3", name: "ops", displayName: "operations")]
        XCTAssertEqual(TeamSidebarDerivation.sorted(teams, order: []).map(\.id), ["2", "1", "3"])
    }

    func testUnknownAndDuplicateIdsInThePreferenceAreIgnored() {
        let teams = [team("a", displayName: "Alpha"), team("b", displayName: "Beta")]
        XCTAssertEqual(TeamSidebarDerivation.sorted(teams, order: ["ghost", "b", "b"]).map(\.id),
                       ["b", "a"])
    }

    func testTeamsOrderPreferenceIsReadFromTheFirstNonEmptyRow() {
        let preferences = [
            MMPreference(category: "teams_order", name: "teams_order", value: ""),
            MMPreference(category: "teams_order", name: "teams_order", value: "b, a ,"),
            MMPreference(category: "other", name: "teams_order", value: "zzz"),
        ]
        XCTAssertEqual(TeamSidebarDerivation.order(from: preferences), ["b", "a"])
        XCTAssertEqual(TeamSidebarDerivation.order(from: []), [])
    }

    // MARK: - Membership filtering

    func testASoftDeletedMembershipRemovesTheTeam() {
        let entries = TeamSidebarDerivation.entries(
            from: data(teams: [team("kept"), team("left")],
                       memberships: [membership("kept"), membership("left", deleteAt: 1_700_000)]),
            userID: "me", selectedTeamID: nil, selectedTeamName: nil)
        XCTAssertEqual(entries.map(\.id), ["kept"])
    }

    func testAMembershipRowForAnotherUserAddsNothingAndRemovesNothing() {
        let entries = TeamSidebarDerivation.entries(
            from: data(teams: [team("mine"), team("not-mine")],
                       memberships: [membership("mine"),
                                     membership("someone-elses", userID: "other")]),
            userID: "me", selectedTeamID: nil, selectedTeamName: nil)
        XCTAssertEqual(entries.map(\.id), ["mine"],
                       "a membership row for somebody else must not vouch for a team this user is not in")
    }

    func testAnEmptyMembershipListFallsBackToTheTeamsEndpoint() {
        // `/users/me/teams` already means "my teams"; if only the memberships call failed, dropping
        // the rail would be a worse answer than drawing it.
        let entries = TeamSidebarDerivation.entries(
            from: data(teams: [team("a"), team("b")]),
            userID: "me", selectedTeamID: nil, selectedTeamName: nil)
        XCTAssertEqual(entries.map(\.id), ["a", "b"])
    }

    func testDeletedTeamIsNotDrawn() {
        let entries = TeamSidebarDerivation.entries(
            from: data(teams: [team("live"), team("gone", deleteAt: 42)]),
            userID: nil, selectedTeamID: nil, selectedTeamName: nil)
        XCTAssertEqual(entries.map(\.id), ["live"])
    }

    // MARK: - Selection

    func testSelectionByTeamIdMarksExactlyOneEntry() {
        let entries = TeamSidebarDerivation.entries(
            from: data(teams: [team("a"), team("b")]),
            userID: nil, selectedTeamID: "b", selectedTeamName: nil)
        XCTAssertEqual(entries.filter(\.isSelected).map(\.id), ["b"])
    }

    func testSelectionByTeamNameCatchesADeepLink() {
        // `mattermost://host/ops/channels/town-square` names the team, not its id.
        let entries = TeamSidebarDerivation.entries(
            from: data(teams: [team("id-1", name: "ops"), team("id-2", name: "perf")]),
            userID: nil, selectedTeamID: nil, selectedTeamName: "ops")
        XCTAssertEqual(entries.filter(\.isSelected).map(\.id), ["id-1"])
    }

    // MARK: - Content states

    func testZeroTeamsIsTheEmptyStateOnceTheAnswerArrives() {
        XCTAssertEqual(TeamSidebarDerivation.content(phase: .idle, entries: []), .loading,
                       "nothing may be claimed before the first answer")
        XCTAssertEqual(TeamSidebarDerivation.content(phase: .loading, entries: []), .loading)
        XCTAssertEqual(TeamSidebarDerivation.content(phase: .loaded, entries: []), .empty)
    }

    func testExactlyOneTeamGetsNoRailChrome() {
        let entries = TeamSidebarDerivation.entries(from: data(teams: [team("solo")]),
                                                    userID: nil,
                                                    selectedTeamID: nil,
                                                    selectedTeamName: nil)
        XCTAssertEqual(TeamSidebarDerivation.content(phase: .loaded, entries: entries),
                       .single(entries[0]))
    }

    func testTwoTeamsGetTheRail() {
        let entries = TeamSidebarDerivation.entries(from: data(teams: [team("a"), team("b")]),
                                                    userID: nil,
                                                    selectedTeamID: nil,
                                                    selectedTeamName: nil)
        guard case .rail(let rail) = TeamSidebarDerivation.content(phase: .loaded, entries: entries) else {
            return XCTFail("two teams must render as a rail")
        }
        XCTAssertEqual(rail.count, 2)
    }

    func testAFailedLoadWithNothingLoadedIsTheFailureState() {
        XCTAssertEqual(TeamSidebarDerivation.content(phase: .failed("The server took too long to respond."),
                                                     entries: []),
                       .failed("The server took too long to respond."))
    }

    // MARK: - View model

    func testLoadPublishesTheServersTeamsWithSelectionAndBadges() async {
        let service = FakeTeamSidebarService()
        service.nextData = data(teams: [team("perf", name: "perf", displayName: "Perf"),
                                        team("ops", name: "ops", displayName: "Operations")],
                                unreads: [unread("ops", mentions: 2), unread("perf", messages: 1)],
                                order: ["perf", "ops"])
        let model = TeamSwitchViewModel(server: server(), service: service)
        model.setSelection(teamID: "perf", teamName: "perf")

        await model.load()

        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.entries.map(\.id), ["perf", "ops"])
        XCTAssertEqual(model.entries[0].isSelected, true)
        XCTAssertEqual(model.entries[0].badge, .none, "the selected team hides its badge")
        XCTAssertEqual(model.entries[1].badge, .count(2))
        XCTAssertEqual(service.loadCount, 1)
    }

    func testASecondAppearanceDoesNotRefetchTheRail() async {
        let service = FakeTeamSidebarService()
        let model = TeamSwitchViewModel(server: server(), service: service)
        await model.load()
        await model.load()
        XCTAssertEqual(service.loadCount, 1)
        await model.reload()
        XCTAssertEqual(service.loadCount, 2, "an explicit reload must refetch")
    }

    func testAFailedLoadShowsTheErrorAndARetryCanSucceed() async {
        let service = FakeTeamSidebarService()
        service.nextError = MMError.timeout
        let model = TeamSwitchViewModel(server: server(), service: service)
        await model.load()

        guard case .failed(let message) = model.content else {
            return XCTFail("expected a failure state, got \(model.content)")
        }
        XCTAssertEqual(message, MMError.timeout.errorDescription)

        service.nextError = nil
        service.nextData = data(teams: [team("a"), team("b")])
        await model.reload()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.entries.count, 2)
    }

    func testUnreadCountersThatFailedToLoadAreLabelledRatherThanDrawnAsZero() async {
        let service = FakeTeamSidebarService()
        service.nextData = data(teams: [team("ops")], unreadsFailed: true)
        let model = TeamSwitchViewModel(server: server(), service: service)
        await model.load()
        XCTAssertTrue(model.countsAreStale)
        XCTAssertEqual(model.entries[0].badge, .none, "no counter is not the same as zero mentions")
    }

    func testRefreshUnreadsUpdatesBadgesWithoutRefetchingTheTeamList() async {
        let service = FakeTeamSidebarService()
        service.nextData = data(teams: [team("perf"), team("ops")],
                                unreads: [unread("ops", mentions: 1)])
        let model = TeamSwitchViewModel(server: server(), service: service)
        model.setSelection(teamID: "perf", teamName: "perf")
        await model.load()
        XCTAssertEqual(model.entries.first { $0.id == "ops" }?.badge, .count(1))

        service.nextUnreads = [unread("ops", mentions: 5)]
        await model.refreshUnreads()

        XCTAssertEqual(model.entries.first { $0.id == "ops" }?.badge, .count(5))
        XCTAssertEqual(service.loadCount, 1, "a counter refresh must not refetch the team list")
        XCTAssertFalse(model.countsAreStale)
    }

    func testAFailedCounterRefreshKeepsTheLastNumbersAndSaysTheyAreStale() async {
        let service = FakeTeamSidebarService()
        service.nextData = data(teams: [team("perf"), team("ops")],
                                unreads: [unread("ops", mentions: 2)])
        let model = TeamSwitchViewModel(server: server(), service: service)
        model.setSelection(teamID: "perf", teamName: "perf")
        await model.load()

        service.nextUnreadsError = MMError.offline
        await model.refreshUnreads()

        XCTAssertTrue(model.countsAreStale)
        XCTAssertEqual(model.entries.first { $0.id == "ops" }?.badge, .count(2),
                       "a failed refresh must not turn a real badge into 'no mentions'")
    }

    func testASlowLoadCannotOverwriteANewerOne() async {
        let service = FakeTeamSidebarService()
        let gate = T32LoadGate()
        service.behaviours = [.gated(gate, data(teams: [team("old-1"), team("old-2")])),
                              .immediate(data(teams: [team("new")]))]
        let model = TeamSwitchViewModel(server: server(), service: service)

        let slow = Task { await model.load(ifNeeded: true) }
        await awaitSignal("the slow load started", signal: service.loadSignal) { $0 == 1 }
        let fast = Task { await model.reload() }
        // The reload's own completion is the signal: the task finishes when the newer answer has been
        // applied, so there is nothing to poll (kanban t_00fb623c).
        await fast.value
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.entries.count, 1)

        gate.open()
        await slow.value

        XCTAssertEqual(model.entries.map(\.id), ["new"],
                       "a load that resolves after a newer one must be discarded, not applied")
    }

    func testIconIsOnlyFetchedForATeamThatHasAnIcon() async {
        let service = FakeTeamSidebarService()
        service.nextData = data(teams: [team("plain"), team("icon", iconUpdatedAt: 77)])
        let model = TeamSwitchViewModel(server: server(), service: service)
        await model.load()

        let plain = model.entries.first { $0.id == "plain" }!
        let icon = model.entries.first { $0.id == "icon" }!
        _ = await model.icon(for: plain)
        XCTAssertTrue(service.iconRequests.isEmpty,
                      "no icon update means the initials fallback, no request")

        _ = await model.icon(for: icon)
        _ = await model.icon(for: icon)
        XCTAssertEqual(service.iconRequests.count, 1, "the icon is fetched once per update stamp")

        service.nextData = data(teams: [team("icon", iconUpdatedAt: 78)])
        await model.reload()
        _ = await model.icon(for: model.entries[0])
        XCTAssertEqual(service.iconRequests.count, 2, "a new icon update stamp is a new icon")
    }

    // MARK: - Coordinator: switching

    private func makeCoordinator(_ service: FakeTeamSidebarService,
                                 events: FakeTeamEventSource,
                                 token: String? = "tok-t32",
                                 navigation: NativeNavigation) -> TeamSidebarCoordinator {
        let coordinator = TeamSidebarCoordinator(events: events,
                                                 unreadRefreshDelay: 0.01,
                                                 makeService: { _ in service },
                                                 tokenProvider: { _ in token })
        coordinator.bind(auth: AuthCoordinator(), navigation: navigation, serverStore: nil)
        return coordinator
    }

    private func twoTeamService() -> FakeTeamSidebarService {
        let service = FakeTeamSidebarService()
        service.nextData = data(teams: [team("perf", name: "perf", displayName: "Perf"),
                                        team("ops", name: "ops", displayName: "Operations")],
                                memberships: [membership("perf"), membership("ops")],
                                unreads: [unread("perf"), unread("ops", mentions: 2)],
                                order: ["perf", "ops"])
        return service
    }

    func testTheFirstTeamBecomesCurrentWhenNothingIsSelected() async {
        let server = server()
        let navigation = makeNavigation([server])
        _ = navigation.activate(serverID: server.id)
        let service = twoTeamService()
        let coordinator = makeCoordinator(service, events: FakeTeamEventSource(), navigation: navigation)

        await coordinator.activate(server)

        XCTAssertEqual(navigation.location.teamID, "perf",
                       "with no team chosen, the rail's first ordered team is current")
        XCTAssertEqual(coordinator.model(for: server).entries.first { $0.isSelected }?.id, "perf")
    }

    func testTheDefaultTeamDoesNotOverrideADestinationALinkOpened() async {
        let server = server()
        let navigation = makeNavigation([server])
        _ = navigation.openChannel(NativeChannelRequest(serverID: server.id,
                                                        teamID: "ops",
                                                        channelID: "ops-town"))
        let service = twoTeamService()
        let coordinator = makeCoordinator(service, events: FakeTeamEventSource(), navigation: navigation)

        await coordinator.activate(server)

        XCTAssertEqual(navigation.location.teamID, "ops")
        XCTAssertEqual(navigation.location.channelID, "ops-town",
                       "a deep link is a destination, not something to replace with a default team")
    }

    func testSelectingTheCurrentTeamIsANoOp() async {
        let server = server()
        let navigation = makeNavigation([server])
        _ = navigation.activate(serverID: server.id)
        let service = twoTeamService()
        let coordinator = makeCoordinator(service, events: FakeTeamEventSource(), navigation: navigation)
        await coordinator.activate(server)
        let perf = coordinator.model(for: server).entries.first { $0.id == "perf" }!

        let outcome = coordinator.select(perf, on: server)

        XCTAssertEqual(outcome, .alreadyCurrent)
        XCTAssertEqual(navigation.location.teamID, "perf")
    }

    /// Acceptance criterion 1: "switching teams updates channels … with no stale data from the
    /// previous team." A switched team must drop the channel the old team had open.
    func testSwitchingTeamsClearsTheChannelAndThePushStack() async {
        let server = server()
        let navigation = makeNavigation([server])
        _ = navigation.openChannel(NativeChannelRequest(serverID: server.id,
                                                        teamID: "perf",
                                                        channelID: "perf-feed",
                                                        channelName: "perf-feed"))
        XCTAssertEqual(navigation.path.count, 1, "the channel is pushed on a compact layout")
        let service = twoTeamService()
        let coordinator = makeCoordinator(service, events: FakeTeamEventSource(), navigation: navigation)
        await coordinator.activate(server)
        let ops = coordinator.model(for: server).entries.first { $0.id == "ops" }!

        let outcome = coordinator.select(ops, on: server)

        XCTAssertEqual(outcome, .switched(teamID: "ops", teamName: "ops"))
        XCTAssertEqual(navigation.location.teamID, "ops")
        XCTAssertNil(navigation.location.channelID, "the previous team's channel must not survive")
        XCTAssertNil(navigation.location.channelName)
        XCTAssertTrue(navigation.path.isEmpty, "and it must not be left pushed on the stack")
        XCTAssertEqual(coordinator.scope(for: server.id)?.teamID, "ops",
                       "the socket scope follows the switch")
    }

    /// Acceptance criterion 1, the socket half: ten rapid switches must leave **one** subscription,
    /// and the scope must end on the last team tapped (the AV probe for this card is exactly this).
    func testTenRapidSwitchesLeaveOneSubscriptionAndTheLastTeamWins() async {
        let server = server()
        let navigation = makeNavigation([server])
        _ = navigation.activate(serverID: server.id)
        let service = twoTeamService()
        let events = FakeTeamEventSource()
        let coordinator = makeCoordinator(service, events: events, navigation: navigation)
        await coordinator.activate(server)
        let model = coordinator.model(for: server)

        for index in 0..<10 {
            // Alternates ops/perf; index 9 (the last tap) is odd → perf.
            let target = model.entries.first { $0.id == (index.isMultiple(of: 2) ? "ops" : "perf") }!
            _ = coordinator.select(target, on: server)
        }

        XCTAssertEqual(navigation.location.teamID, "perf")
        XCTAssertEqual(coordinator.scope(for: server.id)?.teamID, "perf")
        XCTAssertEqual(coordinator.subscriptionCount, 1, "ten switches, one socket")
        await awaitSignal("the single subscription is opened", signal: events.subscribedSignal) { $0 == 1 }
        XCTAssertEqual(events.connectCount, 1, "the connection is opened once per server, not per switch")
    }

    // MARK: - Coordinator: the socket

    func testNoSocketIsOpenedWithoutACredential() async {
        let server = server()
        let navigation = makeNavigation([server])
        _ = navigation.activate(serverID: server.id)
        let service = twoTeamService()
        let events = FakeTeamEventSource()
        let coordinator = makeCoordinator(service, events: events, token: nil, navigation: navigation)

        await coordinator.activate(server)

        XCTAssertEqual(coordinator.subscriptionCount, 0)
        XCTAssertEqual(events.connectCount, 0)
        XCTAssertEqual(coordinator.model(for: server).entries.count, 2, "the rail still loads")
    }

    /// The event scope: after a switch, the previous team's posts are refused, and a post in the
    /// team that is on screen is delivered.
    func testAfterASwitchThePreviousTeamsEventsAreRefused() async {
        let server = server()
        let navigation = makeNavigation([server])
        _ = navigation.activate(serverID: server.id)
        let service = twoTeamService()
        let events = FakeTeamEventSource()
        let coordinator = makeCoordinator(service, events: events, navigation: navigation)
        var delivered: [String] = []
        coordinator.onTeamEvent = { _, event in
            if case .posted(let post) = event { delivered.append(post.channelId) }
        }
        // Every event the pump consumed, in order — the signal form of
        // `deliveredEventCount + refusedEventCount` (a poll of two counters).
        let consumed = SignalCounter()
        coordinator.onServerEvent = { _, _ in consumed.bump() }
        await coordinator.activate(server)
        await awaitSignal("the socket subscribed", signal: events.subscribedSignal) { $0 == 1 }

        // Perf's channel is open, then the user switches to Operations and opens its channel.
        _ = navigation.openChannel(NativeChannelRequest(serverID: server.id,
                                                        teamID: "perf",
                                                        channelID: "perf-feed"))
        _ = coordinator.select(coordinator.model(for: server).entries.first { $0.id == "ops" }!,
                               on: server)
        _ = navigation.openChannel(NativeChannelRequest(serverID: server.id,
                                                        teamID: "ops",
                                                        channelID: "ops-town"))

        events.emit(.posted(post(channelID: "perf-feed", id: "p1")), serverID: server.id)
        events.emit(.posted(post(channelID: "ops-town", id: "p2")), serverID: server.id)

        await awaitSignal("both events are handled", signal: consumed.signal) { $0 == 2 }
        XCTAssertEqual(delivered, ["ops-town"],
                       "the previous team's post must not reach the surface that is on screen")
        XCTAssertEqual(coordinator.refusedEventCount, 1)
    }

    func testPostActivityRefreshesTheTeamsCounters() async {
        let server = server()
        let navigation = makeNavigation([server])
        _ = navigation.activate(serverID: server.id)
        let service = twoTeamService()
        let events = FakeTeamEventSource()
        let coordinator = makeCoordinator(service, events: events, navigation: navigation)
        await coordinator.activate(server)
        await awaitSignal("the socket subscribed", signal: events.subscribedSignal) { $0 == 1 }
        XCTAssertEqual(service.unreadCount, 0)

        service.nextUnreads = [unread("perf"), unread("ops", mentions: 3)]
        // The rail's model, before the debounced refetch: the badge is mirrored, so the assertion below
        // reads the value the view would render instead of polling `model.entries` (kanban t_00fb623c).
        let model = coordinator.model(for: server)
        let badges = TestSignal<[String: Int?]>()
        let mirror = mirrorPublished(model.$entries, into: badges) { entries in
            Dictionary(uniqueKeysWithValues: entries.map { entry -> (String, Int?) in
                if case .count(let count) = entry.badge { return (entry.id, count) }
                return (entry.id, nil)
            })
        }
        defer { mirror.cancel() }

        events.emit(.posted(post(channelID: "anywhere", id: "p9")), serverID: server.id)

        await awaitSignal("the counters are refetched", signal: service.unreadSignal) { $0 == 1 }
        await awaitSignal("the badge reflects the server", signal: badges) { $0["ops"] == 3 }
        XCTAssertEqual(badges.recorded.last?["ops"], 3,
                       "the rail shows the server's count, not a local increment")
    }

    func testSignOutClosesTheSocketAndForgetsTheRail() async {
        let server = server()
        let navigation = makeNavigation([server])
        _ = navigation.activate(serverID: server.id)
        let service = twoTeamService()
        let events = FakeTeamEventSource()
        let coordinator = makeCoordinator(service, events: events, navigation: navigation)
        await coordinator.activate(server)
        await awaitSignal("the socket subscribed", signal: events.subscribedSignal) { $0 == 1 }
        XCTAssertEqual(events.openConnectionCount, 1)

        await coordinator.deactivate(server.id)

        XCTAssertEqual(coordinator.subscriptionCount, 0)
        XCTAssertEqual(events.openConnectionCount, 0, "a sign-out must not leave the socket running")
    }

    // MARK: - Small helpers

    private func post(channelID: String, id: String) -> MMPost {
        MMPost(id: id, channelId: channelID)
    }
}

// MARK: - Doubles

@MainActor
private final class T32FixedAuthGate: NativeAuthGate {
    func authState(for server: ServerConfig) -> NativeAuthState { .signedIn }
}

/// Lets a test hold one load open while a second one completes (the stale-write test).
@MainActor
private final class T32LoadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class FakeTeamSidebarService: TeamSidebarServing {
    enum Behaviour {
        case immediate(TeamSidebarData)
        case gated(T32LoadGate, TeamSidebarData)
        case failing(Error)
    }

    var behaviours: [Behaviour] = []
    var nextData = TeamSidebarData()
    var nextError: Error?
    var nextUnreads: [MMTeamUnread] = []
    var nextUnreadsError: Error?

    private(set) var loadCount = 0
    private(set) var unreadCount = 0
    private(set) var iconRequests: [(String, Int64)] = []
    /// The service's own call counts as signals, so a test awaits "the load started" or "the counters
    /// were refetched" instead of polling `loadCount`/`unreadCount` (kanban t_00fb623c).
    let loadSignal = TestSignal<Int>()
    let unreadSignal = TestSignal<Int>()

    func load() async throws -> TeamSidebarData {
        loadCount += 1
        loadSignal.send(loadCount)
        if !behaviours.isEmpty {
            switch behaviours.removeFirst() {
            case .immediate(let data):
                return data
            case .gated(let gate, let data):
                await gate.wait()
                return data
            case .failing(let error):
                throw error
            }
        }
        if let nextError { throw nextError }
        return nextData
    }

    func unreads() async throws -> [MMTeamUnread] {
        unreadCount += 1
        unreadSignal.send(unreadCount)
        if let nextUnreadsError { throw nextUnreadsError }
        return nextUnreads.isEmpty ? nextData.unreads : nextUnreads
    }

    func icon(for teamID: String, lastUpdateAt: Int64) async -> Data? {
        iconRequests.append((teamID, lastUpdateAt))
        return nil
    }
}

/// A scripted socket: one stream per server, events pushed by the test.
@MainActor
private final class FakeTeamEventSource: TeamEventSourcing {
    private(set) var connectCount = 0
    private(set) var openConnectionCount = 0
    private(set) var isSubscribed = false
    private var continuations: [UUID: AsyncStream<SocketEvent>.Continuation] = [:]
    /// The subscription as a signal: fires with the running count of `events(for:token:)` calls.
    let subscribedSignal = TestSignal<Int>()

    func events(for server: ServerConfig, token: String) async -> AsyncStream<SocketEvent>? {
        connectCount += 1
        subscribedSignal.send(connectCount)
        let (stream, continuation) = AsyncStream.makeStream(of: SocketEvent.self,
                                                            bufferingPolicy: .bufferingNewest(64))
        if continuations[server.id] == nil { openConnectionCount += 1 }
        continuations[server.id] = continuation
        isSubscribed = true
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
