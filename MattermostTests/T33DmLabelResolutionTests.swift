import XCTest
@testable import Mattermost

/// A sidebar DM row must read as the other person's name, never as "Direct message" (card
/// t_c0e42801).
///
/// The defect and its mechanism, both pinned here:
///  1. A 1:1 DM channel's `display_name` is empty (its `name` is `<userID>__<userID>`), so a row with
///     no resolved label can only draw "Direct message".
///  2. The label step used to be one unbounded `POST /users/ids` inside an all-or-nothing deadline:
///     when the deadline fired — which it does on a workspace with hundreds of channels — the whole
///     map was discarded and *every* DM row degraded at once.
///
/// Every test below runs the production `DirectLabelResolver` against a scripted transport (no
/// socket, no server); the counts are the card's own falsifier: rows labelled "Direct message" before
/// and after.
@MainActor
final class T33DmLabelResolutionTests: XCTestCase {

    private let me = "uid-me"
    private var transport: ScriptedLabelTransport!

    override func setUp() {
        super.setUp()
        transport = ScriptedLabelTransport()
        UserProfileCache.forgetAll()
    }

    override func tearDown() {
        UserProfileCache.forgetAll()
        transport = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func client() throws -> APIClient {
        try APIClient(serverURL: URL(string: "https://mm.example.com")!,
                      transport: transport,
                      retryPolicy: .none,
                      tokenProvider: { "token" },
                      sleep: { _ in })
    }

    private func person(_ id: String,
                        username: String? = nil,
                        first: String = "",
                        last: String = "",
                        nickname: String = "",
                        deleteAt: Int64 = 0) -> MMUser {
        MMUser(id: id,
               username: username ?? id,
               firstName: first,
               lastName: last,
               nickname: nickname,
               deleteAt: deleteAt)
    }

    private func dm(_ id: String, with other: String) -> MMChannel {
        MMChannel(id: id, name: "\(me)__\(other)", displayName: "", type: "D", teamId: "t1")
    }

    private func selfDM(_ id: String) -> MMChannel {
        MMChannel(id: id, name: "\(me)__\(me)", displayName: "", type: "D", teamId: "t1")
    }

    private func gm(_ id: String) -> MMChannel {
        MMChannel(id: id, name: String(repeating: "a", count: 32), displayName: "", type: "G", teamId: "t1")
    }

    private func channel(_ id: String) -> MMChannel {
        MMChannel(id: id, name: id, displayName: id.capitalized, type: "O", teamId: "t1")
    }

    /// The derivation the list actually draws from: labels in, rows out.
    private func entries(_ channels: [MMChannel], labels: DirectLabelMap) -> [ChannelSidebarEntry] {
        var data = ChannelSidebarData(channels: channels)
        data.directLabels = labels.labels
        data.searchTerms = labels.terms
        return ChannelSidebarDerivation.groups(from: data,
                                               selectedChannelID: nil,
                                               selectedChannelName: nil).flatMap(\.entries)
    }

    private func label(_ entry: ChannelSidebarEntry?) -> String? { entry?.displayName }

    // MARK: - 1. The row gets a name

    func testADirectMessageRowShowsTheOtherPersonsNameAndNeverDirectMessage() async throws {
        let ada = person("uid-ada", username: "ada", first: "Ada", last: "Lovelace")
        let dmChannel = dm("dm-1", with: ada.id)
        transport.profileAnswer = { ids in ids.compactMap { $0 == ada.id ? ada : nil } }

        let labels = await DirectLabelResolver(client: try client(), userID: me)
            .run(for: [dmChannel, channel("town-square")])

        XCTAssertEqual(labels.labels[dmChannel.id], "Ada Lovelace")
        XCTAssertFalse(labels.terms[dmChannel.id, default: []].isEmpty)

        let rows = entries([dmChannel, channel("town-square")], labels: labels)
        XCTAssertEqual(label(rows.first { $0.id == dmChannel.id }), "Ada Lovelace")
        XCTAssertEqual(rows.filter { $0.displayName == "Direct message" }.count, 0)
        // The named channel is untouched by any of this.
        XCTAssertEqual(label(rows.first { $0.id == "town-square" }), "Town-Square")
    }

    func testOneOversizedRequestIsNeverSent() async throws {
        // 250 direct messages is an ordinary workspace's DM list; the server must not be handed one
        // body with 250 ids, and every row must still be named.
        let people = (0..<250).map { person("uid-\($0)", username: "user\($0)") }
        let channels = people.enumerated().map { dm("dm-\($0.offset)", with: $0.element.id) }
        transport.profileAnswer = { ids in ids.compactMap { id in people.first { $0.id == id } } }

        let labels = await DirectLabelResolver(client: try client(), userID: me).run(for: channels)

        XCTAssertEqual(transport.userIDRequests.map(\.count), [100, 100, 50])
        XCTAssertEqual(labels.labels.count, 250)
        let rows = entries(channels, labels: labels)
        XCTAssertEqual(rows.count, 250)
        XCTAssertEqual(rows.filter { $0.displayName == "Direct message" }.count, 0)
    }

    // MARK: - 2. Profiles already in hand need no request

    func testProfilesAlreadyInHandMakeNoRequestAtAll() async throws {
        let ada = person("uid-ada", username: "ada", first: "Ada", last: "Lovelace")
        let cache = UserProfileCache()
        cache.remember([ada])
        let dmChannel = dm("dm-1", with: ada.id)

        let labels = await DirectLabelResolver(client: try client(), userID: me, profiles: cache)
            .run(for: [dmChannel])

        XCTAssertEqual(labels.labels[dmChannel.id], "Ada Lovelace")
        XCTAssertTrue(transport.userIDRequests.isEmpty, "a cached profile must not be fetched again")
        XCTAssertTrue(transport.memberRequests.isEmpty)
    }

    /// The other half of step 1: the channel pane's profile fetch is what fills the cache, so the
    /// sidebar can read it.
    func testTheChannelPaneRemembersItsProfilesForTheSidebar() async throws {
        let ada = person("uid-ada", username: "ada", first: "Ada", last: "Lovelace")
        transport.profileAnswer = { ids in ids.compactMap { $0 == ada.id ? ada : nil } }
        let cache = UserProfileCache()

        let service = SessionChannelService(profiles: cache, resolve: { try? self.client() })
        let fetched = try await service.users(ids: [ada.id])

        XCTAssertEqual(fetched.map(\.id), [ada.id])
        XCTAssertEqual(cache.known(id: ada.id)?.lastName, "Lovelace")

        // …and the sidebar load that follows asks for nothing.
        let labels = await DirectLabelResolver(client: try client(), userID: me, profiles: cache)
            .run(for: [dm("dm-1", with: ada.id)])
        XCTAssertEqual(labels.labels["dm-1"], "Ada Lovelace")
        XCTAssertEqual(transport.userIDRequests.count, 1, "only the pane's own request")
    }

    // MARK: - 3. Incremental: a failure or a deadline costs only what is outstanding

    func testAFailedBatchKeepsTheRowsTheOtherBatchesNamed() async throws {
        // 150 people = two batches. The second one fails outright.
        let people = (0..<150).map { person("uid-\($0)", username: "user\($0)") }
        let channels = people.enumerated().map { dm("dm-\($0.offset)", with: $0.element.id) }
        transport.profileAnswer = { ids in ids.compactMap { id in people.first { $0.id == id } } }
        transport.failingRequests = [1]

        let labels = await DirectLabelResolver(client: try client(), userID: me).run(for: channels)

        let firstBatch = transport.userIDRequests.first ?? []
        XCTAssertEqual(transport.userIDRequests.count, 2)
        XCTAssertEqual(labels.labels.count, firstBatch.count,
                       "the batch that answered must not be thrown away with the one that failed")
        XCTAssertGreaterThan(labels.labels.count, 0)
        XCTAssertLessThan(labels.labels.count, 150)
    }

    func testADeadlineKeepsWhatHasAlreadyLandedInsteadOfDiscardingTheWholeMap() async throws {
        // The defect the user saw: the label work is abandoned mid-flight and every DM row degrades.
        // Here the first batch answers, the second never does — and the rows from the first survive.
        let people = (0..<150).map { person("uid-\($0)", username: "user\($0)") }
        let channels = people.enumerated().map { dm("dm-\($0.offset)", with: $0.element.id) }
        transport.profileAnswer = { ids in ids.compactMap { id in people.first { $0.id == id } } }
        transport.hangingRequests = [1]
        let client = try client()

        let labels = await SessionChannelSidebarService.abandoningLatest(after: 0.4,
                                                                         initial: .empty) { publish in
            await DirectLabelResolver(client: client, userID: self.me,
                                      onProgress: publish).run(for: channels)
        }

        XCTAssertEqual(transport.userIDRequests.count, 2)
        XCTAssertEqual(labels.labels.count, transport.userIDRequests[0].count)
        XCTAssertGreaterThan(labels.labels.count, 0)
        let rows = entries(channels, labels: labels)
        // Exactly the second batch's rows are still unlabelled — not all 150, which is what the
        // all-or-nothing deadline produced.
        XCTAssertEqual(rows.filter { $0.displayName == "Direct message" }.count,
                       transport.userIDRequests[1].count)
    }

    // MARK: - 4. The rows that used to be silently dropped

    func testASelfDirectMessageReadsYouNotDirectMessage() async throws {
        let mine = selfDM("dm-self")

        let labels = await DirectLabelResolver(client: try client(), userID: me).run(for: [mine])

        XCTAssertEqual(labels.labels[mine.id], "You")
        XCTAssertTrue(transport.userIDRequests.isEmpty, "nobody else is in it — nothing to fetch")
        XCTAssertEqual(label(entries([mine], labels: labels).first), "You")
    }

    func testASelfDirectMessageCarriesMyOwnSearchTerms() async throws {
        let mine = selfDM("dm-self")
        let cache = UserProfileCache()
        cache.remember([person(me, username: "robin", first: "Robin", last: "Hood")])

        let labels = await DirectLabelResolver(client: try client(), userID: me, profiles: cache)
            .run(for: [mine])

        XCTAssertEqual(labels.labels[mine.id], "You")
        XCTAssertTrue(labels.terms[mine.id, default: []].contains("robin"))
        XCTAssertTrue(labels.terms[mine.id, default: []].contains("Robin Hood"))
    }

    func testADeactivatedProfileStillNamesItsRow() async throws {
        // A deactivated account is still returned by `/users/ids`; the row must show the name rather
        // than fall through to "Direct message" because the row-dropper filtered it out.
        let gone = person("uid-gone", username: "gone", first: "Grace", last: "Hopper", deleteAt: 1_700_000_000)
        let dmChannel = dm("dm-1", with: gone.id)
        transport.profileAnswer = { ids in ids.compactMap { $0 == gone.id ? gone : nil } }

        let labels = await DirectLabelResolver(client: try client(), userID: me).run(for: [dmChannel])

        XCTAssertEqual(labels.labels[dmChannel.id], "Grace Hopper")
        XCTAssertEqual(label(entries([dmChannel], labels: labels).first), "Grace Hopper")
    }

    func testAProfileTheServerWillNotNameLeavesTheRowHonestAndTheOthersNamed() async throws {
        let ada = person("uid-ada", username: "ada", first: "Ada", last: "Lovelace")
        let ghost = dm("dm-ghost", with: "uid-ghost")
        let known = dm("dm-ada", with: ada.id)
        transport.profileAnswer = { ids in ids.compactMap { $0 == ada.id ? ada : nil } }

        let labels = await DirectLabelResolver(client: try client(), userID: me)
            .run(for: [ghost, known])

        XCTAssertEqual(labels.labels[known.id], "Ada Lovelace")
        XCTAssertNil(labels.labels[ghost.id])
        let rows = entries([ghost, known], labels: labels)
        // One genuinely unresolvable id is allowed to say "Direct message"; the resolvable one is not.
        XCTAssertEqual(rows.filter { $0.displayName == "Direct message" }.count, 1)
    }

    // MARK: - 5. Group messages

    func testAGroupMessageNamesEveryMemberButMe() async throws {
        let group = gm("gm-1")
        let ada = person("uid-ada", username: "ada", first: "Ada", last: "Lovelace")
        let grace = person("uid-grace", username: "grace", first: "Grace", last: "Hopper")
        transport.members = [group.id: [MMChannelMember(channelId: group.id, userId: me),
                                        MMChannelMember(channelId: group.id, userId: ada.id),
                                        MMChannelMember(channelId: group.id, userId: grace.id)]]
        transport.profileAnswer = { ids in
            ids.compactMap { id in [ada, grace].first { $0.id == id } }
        }

        let labels = await DirectLabelResolver(client: try client(), userID: me).run(for: [group])

        XCTAssertEqual(labels.labels[group.id], "Ada Lovelace, Grace Hopper")
        XCTAssertFalse(labels.labels[group.id, default: ""].contains("Robin"))
    }

    // MARK: - 6. The card's own falsifier: a large sidebar has no "Direct message" rows

    func testALargeSidebarDrawsNoDirectMessageRows() async throws {
        // 320 DMs + 20 GMs + public channels: the shape that made the deadline fire. Every row is
        // named; the count of "Direct message" rows is zero.
        let people = (0..<340).map { person("uid-\($0)", username: "user\($0)", first: "User", last: "\($0)") }
        var channels: [MMChannel] = []
        for index in 0..<320 {
            channels.append(dm("dm-\(index)", with: people[index].id))
        }
        for index in 320..<340 {
            let group = gm("gm-\(index)")
            transport.members[group.id] = [MMChannelMember(channelId: group.id, userId: me),
                                           MMChannelMember(channelId: group.id, userId: people[index].id)]
            channels.append(group)
        }
        channels.append(channel("town-square"))
        transport.profileAnswer = { ids in
            let known = Set(ids)
            return people.filter { known.contains($0.id) }
        }

        let labels = await DirectLabelResolver(client: try client(), userID: me).run(for: channels)
        let rows = entries(channels, labels: labels)

        let directRows = rows.filter { $0.kind.isDirect }
        XCTAssertEqual(directRows.count, 340)
        XCTAssertEqual(rows.filter { $0.displayName == "Direct message" }.count, 0)
        XCTAssertEqual(rows.filter { $0.displayName == "Group message" }.count, 0)
        XCTAssertEqual(labels.labels.count, 340)
        // 320 DM partners in three full batches and a remainder; then each group-message batch of 8
        // resolves its own new people. No request is ever larger than the batch cap.
        XCTAssertTrue(transport.userIDRequests.allSatisfy { $0.count <= DirectLabelResolver.profileBatchSize },
                      "an oversized body is the slow step that lost the deadline: \(transport.userIDRequests.map(\.count))")
        XCTAssertEqual(transport.userIDRequests.map(\.count).reduce(0, +), 340)
        XCTAssertEqual(transport.userIDRequests.count, 7)
    }

    // MARK: - 7. The load itself, end to end

    /// The diagnostics line the card asks for: `labels ok (N)` against the number of direct channels.
    func testTheLoadReportsLabelsAgainstTheNumberOfDirectChannels() async throws {
        let ada = person("uid-ada", username: "ada", first: "Ada", last: "Lovelace")
        let dmChannel = dm("dm-1", with: ada.id)
        transport.teamChannels = [dmChannel, channel("town-square")]
        transport.memberships = [MMChannelMember(channelId: "dm-1", userId: me),
                                 MMChannelMember(channelId: "town-square", userId: me)]
        transport.categories = MMSidebarCategories(
            categories: [MMSidebarCategory(id: "dm", userId: me, teamId: "t1", sortOrder: 10,
                                           sorting: "recent", type: "direct_messages",
                                           displayName: "Direct Messages",
                                           channelIds: ["dm-1"])],
            order: ["dm"])
        transport.profileAnswer = { ids in ids.compactMap { $0 == ada.id ? ada : nil } }

        let service = SessionChannelSidebarService {
            guard let client = try? self.client() else { return nil }
            return (client, self.me)
        }
        let data = try await service.load(teamID: "t1")

        XCTAssertEqual(data.directLabels["dm-1"], "Ada Lovelace")
        XCTAssertEqual(SidebarLoadTrace.step, "labels ok (1/1)")
    }

    /// Step 1 at load level: a warm cache means the label step issues no profile request at all.
    func testASecondLoadNamesTheDirectMessagesWithoutAnotherProfileRequest() async throws {
        let ada = person("uid-ada", username: "ada", first: "Ada", last: "Lovelace")
        let dmChannel = dm("dm-1", with: ada.id)
        transport.teamChannels = [dmChannel]
        transport.memberships = [MMChannelMember(channelId: "dm-1", userId: me)]
        transport.categories = MMSidebarCategories(
            categories: [MMSidebarCategory(id: "dm", userId: me, teamId: "t1", sortOrder: 10,
                                           sorting: "recent", type: "direct_messages",
                                           channelIds: ["dm-1"])],
            order: ["dm"])
        transport.profileAnswer = { ids in ids.compactMap { $0 == ada.id ? ada : nil } }

        let cache = UserProfileCache()
        let first = SessionChannelSidebarService(profiles: cache) {
            guard let client = try? self.client() else { return nil }
            return (client, self.me)
        }
        _ = try await first.load(teamID: "t1")
        XCTAssertEqual(transport.userIDRequests.count, 1)
        XCTAssertEqual(cache.known(id: ada.id)?.id, ada.id, "the load remembers what it paid for")

        let second = SessionChannelSidebarService(profiles: cache) {
            guard let client = try? self.client() else { return nil }
            return (client, self.me)
        }
        let data = try await second.load(teamID: "t1")

        XCTAssertEqual(data.directLabels["dm-1"], "Ada Lovelace")
        XCTAssertEqual(transport.userIDRequests.count, 1, "a reload must not ask again")
        XCTAssertEqual(SidebarLoadTrace.step, "labels ok (1/1)")
    }
}

// MARK: - The scripted server

/// A transport that answers the two endpoints this feature uses, from fixtures, and records what it
/// was asked. `send` is called concurrently (the group-member batches run in parallel), so the state
/// is behind a lock and the recorded order is per-endpoint completion order, not call order — the
/// assertions only use counts and bodies.
final class ScriptedLabelTransport: APITransport {

    private let lock = NSLock()

    /// Answers `POST /users/ids` for a batch of ids.
    var profileAnswer: ([String]) -> [MMUser] = { _ in [] }
    /// Group-channel member lists, by channel id.
    var members: [String: [MMChannelMember]] = [:]
    /// The load's three read answers (only the end-to-end test below needs them).
    var teamChannels: [MMChannel] = []
    var memberships: [MMChannelMember] = []
    var categories = MMSidebarCategories()
    /// `POST /users/ids` batches that fail (0-based index, in arrival order).
    var failingRequests: Set<Int> = []
    /// `POST /users/ids` batches that never answer (the deadline test).
    var hangingRequests: Set<Int> = []

    private(set) var userIDRequests: [[String]] = []
    private(set) var memberRequests: [String] = []

    func send(_ request: APIRequest) async throws -> APIResponse {
        let path = request.url.path

        if path.hasSuffix("/users/ids") {
            let ids = (try? JSONDecoder().decode([String].self, from: request.body ?? Data())) ?? []
            let index = record { () -> Int in
                userIDRequests.append(ids)
                return userIDRequests.count - 1
            }
            if hangingRequests.contains(index) {
                // Long enough that only a deadline can end the test; the abandoned task exits with
                // the test (cancellation ends the sleep early).
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                return APIResponse(statusCode: 500, headers: [:], body: Data())
            }
            if failingRequests.contains(index) {
                return APIResponse(statusCode: 500, headers: [:],
                                   body: Data("{\"status_code\":500}".utf8))
            }
            let body = (try? JSONEncoder().encode(profileAnswer(ids))) ?? Data("[]".utf8)
            return APIResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
        }

        if path.hasSuffix("/members") {
            let channelID = path.components(separatedBy: "/").dropLast().last ?? ""
            record { memberRequests.append(channelID) }
            let body = (try? JSONEncoder().encode(members[channelID] ?? [])) ?? Data("[]".utf8)
            return APIResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
        }

        let read: Data?
        if path.hasSuffix("/categories") {
            read = try? JSONEncoder().encode(categories)
        } else if path.hasSuffix("/channel_members") {
            read = try? JSONEncoder().encode(memberships)
        } else if path.hasSuffix("/channels") {
            read = try? JSONEncoder().encode(teamChannels)
        } else {
            read = nil
        }
        if let read {
            return APIResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: read)
        }

        return APIResponse(statusCode: 404, headers: [:], body: Data())
    }

    private func record<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
