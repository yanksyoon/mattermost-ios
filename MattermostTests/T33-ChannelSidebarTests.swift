import XCTest
@testable import Mattermost

/// T33 — the native channel sidebar (S08: list, categories, unread/mention, mute, favourites, quick
/// switcher).
///
/// The card's acceptance criteria are the spine of this file, and each one is pinned at the level
/// where it can actually be false:
///  1. **Ordering and grouping match the server's sidebar categories, and a reorder persists** —
///     `ChannelSidebarDerivation` + `ChannelListViewModel.move`/`setFavorite` with a fake server that
///     remembers what it was sent, then a *second* model (a relaunch) reading it back.
///  2. **Unread/mention bold state is live** — the badge/bold rules, `channel_viewed` clearing
///     locally, and the `posted` → refresh path through the coordinator.
///  3. **Muted channels show no bold/count and leave the totals** — the mute rule (upstream's
///     `mark_unread == "mention"`) and `ChannelSidebarTotals`.
///  4. **The quick switcher fuzzy-matches names and DMs** — ranking tiers, `#`/`@` prefixes, DM
///     usernames.
@MainActor
final class T33ChannelSidebarTests: XCTestCase {

    // MARK: - Fixtures

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var retainedStores: [ServerStore] = []

    override func setUp() {
        super.setUp()
        suiteName = "T33ChannelSidebarTests-\(UUID().uuidString)"
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

    private func channel(_ id: String,
                         name: String? = nil,
                         displayName: String? = nil,
                         type: String = "O",
                         teamID: String = "team1",
                         totalMsgCount: Int64 = 0,
                         lastPostAt: Int64 = 0,
                         createAt: Int64 = 1,
                         deleteAt: Int64 = 0) -> MMChannel {
        MMChannel(id: id,
                  name: name ?? id,
                  displayName: displayName ?? id.capitalized,
                  type: type,
                  teamId: teamID,
                  lastPostAt: lastPostAt,
                  totalMsgCount: totalMsgCount,
                  createAt: createAt,
                  deleteAt: deleteAt)
    }

    private func member(_ channelID: String,
                        msgCount: Int64 = 0,
                        mentions: Int64 = 0,
                        muted: Bool = false,
                        manuallyUnread: Bool = false) -> MMChannelMember {
        MMChannelMember(channelId: channelID,
                        userId: "me",
                        lastViewedAt: 0,
                        msgCount: msgCount,
                        mentionCount: mentions,
                        manuallyUnread: manuallyUnread,
                        notifyProps: .object(["mark_unread": .string(muted ? "mention" : "all")]))
    }

    private func category(_ id: String,
                          type: String,
                          displayName: String = "",
                          sorting: String = "",
                          sortOrder: Int = 10,
                          channelIDs: [String] = [],
                          muted: Bool = false,
                          collapsed: Bool = false) -> MMSidebarCategory {
        MMSidebarCategory(id: id,
                          userId: "me",
                          teamId: "team1",
                          sortOrder: sortOrder,
                          sorting: sorting,
                          type: type,
                          displayName: displayName,
                          muted: muted,
                          collapsed: collapsed,
                          channelIds: channelIDs)
    }

    /// A three-category sidebar: favourites (empty), `channels` (two channels, manual order),
    /// `direct_messages` (one DM, recent).
    private func standardData() -> ChannelSidebarData {
        let alpha = channel("c1", name: "alpha", displayName: "Alpha", totalMsgCount: 5)
        let bravo = channel("c2", name: "bravo", displayName: "Bravo", totalMsgCount: 2)
        let dm = channel("d1", name: "id__me__them", displayName: "", type: "D")
        var data = ChannelSidebarData(channels: [alpha, bravo, dm],
                                      members: [member("c1", msgCount: 2),
                                                member("c2", msgCount: 2),
                                                member("d1")])
        data.categories = [
            category("fav", type: "favorites", displayName: "Favorites", sortOrder: 0),
            category("chan", type: "channels", displayName: "Channels", sorting: "manual",
                     sortOrder: 10, channelIDs: ["c1", "c2"]),
            category("dm", type: "direct_messages", displayName: "Direct Messages",
                     sorting: "recent", sortOrder: 20, channelIDs: ["d1"]),
        ]
        data.categoryOrder = ["fav", "chan", "dm"]
        data.directLabels = ["d1": "Ada Lovelace"]
        data.searchTerms = ["d1": ["ada", "Ada Lovelace"]]
        return data
    }

    private func groups(_ data: ChannelSidebarData,
                        selectedChannelID: String? = nil) -> [ChannelSidebarGroup] {
        ChannelSidebarDerivation.groups(from: data,
                                        selectedChannelID: selectedChannelID,
                                        selectedChannelName: nil)
    }

    // MARK: - 1. Decode

    func testCategoryDecodesTheServersShape() throws {
        let json = """
        {"id":"channels_uid_team","user_id":"uid","team_id":"team","sort_order":10,
         "sorting":"manual","type":"channels","display_name":"Channels","muted":false,
         "collapsed":true,"channel_ids":["a","b"]}
        """
        let decoded = try JSONDecoder().decode(MMSidebarCategory.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.id, "channels_uid_team")
        XCTAssertEqual(decoded.sortOrder, 10)
        XCTAssertEqual(decoded.sorting, "manual")
        XCTAssertEqual(decoded.kind, .channels)
        XCTAssertEqual(decoded.channelIds, ["a", "b"])
        XCTAssertTrue(decoded.collapsed)
        XCTAssertEqual(decoded.sidebarIdentifier, "channelSidebar.category.channels")
    }

    func testCategoriesResponseDecodesOrder() throws {
        let json = """
        {"categories":[{"id":"a","type":"favorites"},{"id":"b","type":"custom","display_name":"Projects"}],
         "order":["a","b"]}
        """
        let decoded = try JSONDecoder().decode(MMSidebarCategories.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.order, ["a", "b"])
        XCTAssertEqual(decoded.categories.map(\.kind), [.favorites, .custom])
        XCTAssertEqual(decoded.categories[1].sidebarIdentifier, "channelSidebar.category.custom.b")
    }

    func testCategoryToleratesAnOlderServersMissingFields() throws {
        let decoded = try JSONDecoder().decode(MMSidebarCategory.self,
                                               from: Data(#"{"id":"x","type":"custom"}"#.utf8))
        XCTAssertEqual(decoded.sortOrder, 0)
        XCTAssertEqual(decoded.sorting, "")
        XCTAssertFalse(decoded.muted)
        XCTAssertEqual(decoded.channelIds, [])
    }

    /// Regression: `/users/me/channel_members` omits `manually_unread`/`scheme_*`, and the
    /// synthesised decoder made the whole membership call fail — silently zeroing every badge.
    func testChannelMemberDecodesTheUsersMeChannelMembersShape() throws {
        let json = """
        {"channel_id":"cid","user_id":"uid","roles":"channel_user","last_viewed_at":0,
         "msg_count":0,"mention_count":5,"notify_props":{"mark_unread":"mention"},
         "last_update_at":1792869870388}
        """
        let decoded = try JSONDecoder().decode(MMChannelMember.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.channelId, "cid")
        XCTAssertEqual(decoded.mentionCount, 5)
        XCTAssertFalse(decoded.manuallyUnread)
        XCTAssertTrue(ChannelSidebarDerivation.isMuted(decoded))
    }

    func testChannelTypeLettersMapToTheFourKinds() {
        XCTAssertEqual(ChannelSidebarDerivation.kind(of: channel("a", type: "O")), .publicChannel)
        XCTAssertEqual(ChannelSidebarDerivation.kind(of: channel("a", type: "P")), .privateChannel)
        XCTAssertEqual(ChannelSidebarDerivation.kind(of: channel("a", type: "D")), .directMessage)
        XCTAssertEqual(ChannelSidebarDerivation.kind(of: channel("a", type: "G")), .groupMessage)
        XCTAssertNil(ChannelSidebarDerivation.kind(of: channel("a", type: "Z")))
    }

    func testAnUnknownChannelTypeIsStillDrawn() {
        let data = ChannelSidebarData(channels: [channel("x", name: "plug", displayName: "Plugin", type: "Z")])
        let entries = ChannelSidebarDerivation.entries(from: data,
                                                      selectedChannelID: nil,
                                                      selectedChannelName: nil)
        XCTAssertEqual(entries.count, 1, "a channel this build does not understand must not vanish")
        XCTAssertEqual(entries[0].kind, .publicChannel)
    }

    // MARK: - 2. Unread / mention / mute rules

    func testUnreadMessagesAreTheDeltaAndNeverNegative() {
        let chan = channel("a", totalMsgCount: 5)
        XCTAssertEqual(ChannelSidebarDerivation.unreadMessages(channel: chan,
                                                              member: member("a", msgCount: 2)), 3)
        XCTAssertEqual(ChannelSidebarDerivation.unreadMessages(channel: chan,
                                                              member: member("a", msgCount: 9)), 0)
        XCTAssertEqual(ChannelSidebarDerivation.unreadMessages(channel: chan, member: nil), 0)
    }

    func testUnreadMessagesShowBoldAndADot() {
        let entry = ChannelSidebarEntry.fixture(mentions: 0, unread: 3, muted: false)
        XCTAssertTrue(entry.showsUnreadEmphasis)
        XCTAssertEqual(entry.badge, .dot)
        XCTAssertTrue(entry.accessibilityValue.contains("Unread"))
    }

    func testMentionsWinOverUnreadAndFormatTheBadge() {
        let entry = ChannelSidebarEntry.fixture(mentions: 2, unread: 9)
        XCTAssertTrue(entry.showsUnreadEmphasis)
        XCTAssertEqual(entry.badge, .count(2))
        XCTAssertEqual(entry.badgeText, "2")
        XCTAssertTrue(entry.accessibilityValue.contains("2 mentions"))
    }

    func testTheBadgeCapsAtNinetyNinePlusButKeepsTheRealNumber() {
        let entry = ChannelSidebarEntry.fixture(mentions: 120, unread: 0)
        XCTAssertEqual(entry.badgeText, "99+")
        XCTAssertTrue(entry.accessibilityValue.contains("more than 99 mentions"))
    }

    /// Criterion 3: a muted channel has **no** unread state for ordinary traffic.
    func testAMutedChannelShowsNoBoldAndNoBadgeForUnreadMessages() {
        let entry = ChannelSidebarEntry.fixture(mentions: 0, unread: 7, muted: true)
        XCTAssertFalse(entry.showsUnreadEmphasis)
        XCTAssertEqual(entry.badge, ChannelSidebarBadge.none)
        XCTAssertTrue(entry.accessibilityValue.contains("Muted"))
        XCTAssertFalse(entry.accessibilityValue.contains("Unread"))
    }

    /// The one refinement of criterion 3's wording: `mark_unread = "mention"` is the definition of
    /// mute, so an *explicit mention* is exactly the traffic a muted channel still surfaces —
    /// mobile's `isUnreadChannel` and the web app's `calculateUnreadCount` both say so, and the
    /// browser next to the app shows it too.
    func testAMutedChannelStillSurfacesAnExplicitMention() {
        let entry = ChannelSidebarEntry.fixture(mentions: 1, unread: 7, muted: true)
        XCTAssertTrue(entry.showsUnreadEmphasis)
        XCTAssertEqual(entry.badge, .count(1))
    }

    func testKeepAsUnreadEmphasisesANonMutedChannel() {
        let entry = ChannelSidebarEntry.fixture(mentions: 0, unread: 0, manuallyUnread: true)
        XCTAssertTrue(entry.showsUnreadEmphasis)
        XCTAssertTrue(entry.accessibilityValue.contains("Kept unread"))
    }

    func testMuteIsMarkUnreadMentionAndNothingElse() {
        XCTAssertTrue(ChannelSidebarDerivation.isMuted(member("a", muted: true)))
        XCTAssertFalse(ChannelSidebarDerivation.isMuted(member("a", muted: false)))
        XCTAssertFalse(ChannelSidebarDerivation.isMuted(nil))
        XCTAssertFalse(ChannelSidebarDerivation.isMuted(
            MMChannelMember(channelId: "a", userId: "me", notifyProps: .object(["desktop": .string("none")]))),
            "a channel is muted by `mark_unread`, not by its desktop/push settings")
        XCTAssertEqual(ChannelSidebarDerivation.markUnread(forMuted: true), "mention")
        XCTAssertEqual(ChannelSidebarDerivation.markUnread(forMuted: false), "all")
    }

    /// Criterion 3, second half: the totals exclude a muted channel **entirely** — messages *and*
    /// mentions — exactly as desktop's `getTeamsUnreadStatuses` does ("if channel is muted, we skip its
    /// count"). T33-AV F2 measured the previous "keep the mentions" rule against that criterion; the
    /// row still badges an explicit mention, the footer does not count it.
    func testTotalsExcludeAMutedChannelsMessagesAndMentionsLikeDesktop() {
        var data = ChannelSidebarData(
            channels: [channel("a", totalMsgCount: 4), channel("b", totalMsgCount: 9), channel("c")],
            members: [member("a", msgCount: 1, mentions: 2),
                      member("b", msgCount: 1, mentions: 5, muted: true),
                      member("c", msgCount: 0)])
        data.categories = [category("chan", type: "channels", sorting: "alpha", channelIDs: ["a", "b", "c"])]
        data.categoryOrder = ["chan"]
        let result = groups(data)
        let totals = ChannelSidebarDerivation.totals(result)
        XCTAssertEqual(totals.messages, 3, "only the non-muted channel's 3 unread messages count")
        XCTAssertEqual(totals.mentions, 2, "a muted channel's mentions leave the total (desktop rule)")
        XCTAssertEqual(totals.unreadChannels, 1, "the muted channel is not an unread channel")
        XCTAssertEqual(totals.accessibilityLabel, "2 mentions, 3 unread messages")
        // The *row* is unchanged by the totals rule: a mention through the mute still badges.
        let mutedRow = result.flatMap(\.entries).first { $0.id == "b" }
        XCTAssertEqual(mutedRow?.badge, .count(5))
        XCTAssertEqual(mutedRow?.showsUnreadEmphasis, true)
    }

    func testAnEmptySidebarHasNoTotalsSentence() {
        XCTAssertNil(ChannelSidebarTotals().accessibilityLabel)
        XCTAssertTrue(ChannelSidebarTotals().isEmpty)
    }

    // MARK: - 3. Grouping

    func testGroupsFollowTheServersOrderAndOwnTheirChannels() {
        let result = groups(standardData())
        XCTAssertEqual(result.map(\.id), ["chan", "dm"], "an empty favourites category is not drawn")
        XCTAssertEqual(result[0].entries.map(\.id), ["c1", "c2"])
        XCTAssertEqual(result[0].displayName, "Channels")
        XCTAssertEqual(result[1].entries.map(\.id), ["d1"])
        XCTAssertEqual(result[1].entries[0].displayName, "Ada Lovelace")
    }

    func testTheOrderArrayDecidesTheDrawnOrderAndUnknownCategoriesAreAppended() {
        var data = standardData()
        data.categoryOrder = ["dm"] // `chan` is not listed: it must still be drawn, after
        let result = groups(data)
        XCTAssertEqual(result.map(\.id), ["dm", "chan"])
    }

    func testACustomCategoryComesBeforeTheDefaultsAndShowsItsChannels() {
        var data = standardData()
        let custom = category("proj", type: "custom", displayName: "Projects", sorting: "alpha",
                              sortOrder: 5, channelIDs: ["c2"])
        data.categories = [data.categories[0], custom] + data.categories[1...]
        data.categoryOrder = ["fav", "proj", "chan", "dm"]
        let result = groups(data)
        XCTAssertEqual(result.map(\.id), ["proj", "chan", "dm"])
        XCTAssertEqual(result[0].entries.map(\.id), ["c2"])
        XCTAssertTrue(result[0].entries[0].isFavorite == false)
        // …and the channel it claims is not drawn twice.
        XCTAssertEqual(result[1].entries.map(\.id), ["c1"], "a claimed channel is not appended again")
    }

    func testAChannelNoCategoryClaimsIsAppendedToTheDefaultForItsKind() {
        var data = standardData()
        data.channels.append(channel("c3", name: "charlie", displayName: "Charlie"))
        let result = groups(data)
        XCTAssertEqual(result[0].entries.map(\.id), ["c1", "c2", "c3"],
                       "an unlisted channel of the team joins the channels category")
        let dm = channel("d2", name: "id__me__you", displayName: "", type: "D")
        data.channels.append(dm)
        XCTAssertEqual(groups(data)[1].entries.map(\.id), ["d1", "d2"])
    }

    func testWithoutCategoriesTheTwoDefaultsAreSynthesised() {
        var data = standardData()
        data.categories = []
        data.categoryOrder = []
        let result = groups(data)
        XCTAssertEqual(result.map(\.kind), [.channels, .directMessages])
        XCTAssertEqual(result[0].entries.map(\.id), ["c1", "c2"])
        XCTAssertEqual(result[1].entries.map(\.id), ["d1"])
    }

    func testAnArchivedChannelIsHiddenExceptTheOneOnScreen() {
        var data = standardData()
        data.channels[0].deleteAt = 1
        XCTAssertEqual(groups(data)[0].entries.map(\.id), ["c2"])
        XCTAssertEqual(groups(data, selectedChannelID: "c1")[0].entries.map(\.id), ["c1", "c2"],
                       "hiding the conversation on screen is worse than showing an archived one")
    }

    func testSelectionMarksExactlyOneRowAndSupportsAName() {
        var data = standardData()
        data.categories[1].channelIds = ["c1", "c2"]
        let byID = ChannelSidebarDerivation.groups(from: data,
                                                  selectedChannelID: "c2",
                                                  selectedChannelName: nil)
        XCTAssertEqual(byID[0].entries.filter(\.isSelected).map(\.id), ["c2"])
        let byName = ChannelSidebarDerivation.groups(from: data,
                                                    selectedChannelID: nil,
                                                    selectedChannelName: "alpha")
        XCTAssertEqual(byName[0].entries.filter(\.isSelected).map(\.id), ["c1"])
    }

    // MARK: - 4. Sorting

    func testManualSortingUsesTheCategoryChannelIds() {
        var data = standardData()
        data.categories[1].channelIds = ["c2", "c1"]
        XCTAssertEqual(groups(data)[0].entries.map(\.id), ["c2", "c1"])
    }

    func testAlphaSortingPutsMutedChannelsLastThenAlphabetically() {
        var data = ChannelSidebarData(
            channels: [channel("a", displayName: "Zulu"), channel("b", displayName: "Alpha"),
                       channel("c", displayName: "Muted-but-first")],
            members: [member("a"), member("b"), member("c", muted: true)])
        data.categories = [category("chan", type: "channels", sorting: "alpha",
                                    channelIDs: ["a", "b", "c"])]
        data.categoryOrder = ["chan"]
        XCTAssertEqual(groups(data)[0].entries.map(\.id), ["b", "a", "c"])
    }

    func testAlphaSortingIsNumberAware() {
        var data = ChannelSidebarData(channels: [channel("a", displayName: "ops-10"),
                                                 channel("b", displayName: "ops-2")])
        data.categories = [category("chan", type: "channels", sorting: "alpha",
                                    channelIDs: ["a", "b"])]
        data.categoryOrder = ["chan"]
        XCTAssertEqual(groups(data)[0].entries.map(\.id), ["b", "a"])
    }

    func testRecentSortingUsesTheNewerOfLastPostAndCreation() {
        var data = ChannelSidebarData(channels: [channel("old", displayName: "Old", lastPostAt: 100),
                                                 channel("new", displayName: "New", lastPostAt: 900),
                                                 channel("fresh", displayName: "Fresh",
                                                         lastPostAt: 0, createAt: 500)])
        data.categories = [category("dm", type: "direct_messages", sorting: "recent",
                                    channelIDs: ["old", "new", "fresh"])]
        data.categoryOrder = ["dm"]
        XCTAssertEqual(groups(data)[0].entries.map(\.id), ["new", "fresh", "old"])
    }

    // MARK: - 5. Favourites

    func testFavouritesComeFromTheFavoritesCategory() {
        var data = standardData()
        data.categories[0].channelIds = ["c2"]
        let entries = ChannelSidebarDerivation.entries(from: data,
                                                      selectedChannelID: nil,
                                                      selectedChannelName: nil)
        XCTAssertEqual(entries.filter(\.isFavorite).map(\.id), ["c2"])
    }

    func testFavouritesFallBackToTheLegacyPreferenceOnlyWithoutACategory() {
        var data = standardData()
        data.categories = []
        data.preferences = [
            MMPreference(userId: "me", category: "favorite_channel", name: "c1", value: "true"),
            MMPreference(userId: "me", category: "favorite_channel", name: "c2", value: "false"),
        ]
        XCTAssertEqual(ChannelSidebarDerivation.favoriteIDs(from: data), ["c1"])
        // A categories answer that exists wins over a stale preference.
        data.categories = [category("fav", type: "favorites", channelIDs: [])]
        XCTAssertEqual(ChannelSidebarDerivation.favoriteIDs(from: data), [])
    }

    // MARK: - 6. Quick switcher

    func testSearchRanksExactThenPrefixThenWordStartThenSubstringThenSubsequence() async {
        var data = ChannelSidebarData()
        data.channels = [channel("1", name: "standup", displayName: "Standup"),
                         channel("2", name: "ops-standup", displayName: "Ops Standup"),
                         channel("3", name: "understand", displayName: "Understand"),
                         channel("4", name: "sandpit", displayName: "Sandpit")]
        data.categories = [category("chan", type: "channels", sorting: "alpha",
                                    channelIDs: ["1", "2", "3", "4"])]
        data.categoryOrder = ["chan"]
        let model = await loadedModel(data)
        let ids = model.searchResults(for: "standup").map(\.id)
        XCTAssertEqual(ids.prefix(2).map { $0 }, ["1", "2"], "exact, then word-start; got \(ids)")

        let substring = model.searchResults(for: "stand").map(\.id)
        XCTAssertTrue(substring.contains("3"), "a substring match is still a match, got \(substring)")
        XCTAssertEqual(substring.prefix(2).map { $0 }, ["1", "2"],
                       "a prefix/word-start beats a match in the middle; got \(substring)")

        // Subsequence: s-t-d-p appears in order inside "standup".
        let sub = model.searchResults(for: "stdp").map(\.id)
        XCTAssertTrue(sub.contains("1"), "a subsequence must find standup, got \(sub)")
    }

    func testSearchAcceptsAChannelHashAndADirectMessageHandle() async {
        let model = await loadedModel(standardData())
        XCTAssertEqual(model.searchResults(for: "#bravo").first?.id, "c2")
        XCTAssertEqual(model.searchResults(for: "@ada").first?.id, "d1",
                       "a DM is found by the person's username, not by its id__id channel name")
        XCTAssertEqual(model.searchResults(for: "lovelace").first?.id, "d1")
    }

    func testAnEmptyQueryListsEverythingAndNoMatchIsEmpty() async {
        let model = await loadedModel(standardData())
        XCTAssertEqual(model.searchResults(for: "").count, 3)
        XCTAssertTrue(model.searchResults(for: "zzzzz").isEmpty)
    }

    /// A model with its fake server already loaded (the search terms and the groups are derived
    /// from the load, exactly as in the app).
    private func loadedModel(_ data: ChannelSidebarData) async -> ChannelListViewModel {
        let model = ChannelListViewModel(server: server(),
                                         service: FakeChannelSidebarService(data: data))
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()
        return model
    }

    // MARK: - 7. The view model against a fake server

    func testLoadPublishesGroupsTotalsAndSelection() async {
        let fake = FakeChannelSidebarService(data: standardData())
        let model = ChannelListViewModel(server: server(), service: fake)
        model.setSelection(teamID: "team1", channelID: "c2", channelName: "bravo")
        await model.load()

        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(fake.loadTeamIDs, ["team1"])
        XCTAssertEqual(model.groups.map(\.id), ["chan", "dm"])
        XCTAssertEqual(model.totals.messages, 3)
        XCTAssertTrue(model.entry(id: "c2")?.isSelected == true)
        XCTAssertFalse(model.groupingIsApproximate)
        XCTAssertTrue(model.canWriteLayout)
    }

    func testASecondAppearanceDoesNotRefetchAndATeamSwitchDoes() async {
        let fake = FakeChannelSidebarService(data: standardData())
        let model = ChannelListViewModel(server: server(), service: fake)
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()
        await model.load()
        XCTAssertEqual(fake.loadTeamIDs.count, 1, "a re-mount must not refetch the sidebar")

        fake.data = ChannelSidebarData(channels: [channel("x", name: "x", displayName: "X")])
        model.setSelection(teamID: "team2", channelID: nil, channelName: nil)
        await model.load()
        XCTAssertEqual(fake.loadTeamIDs, ["team1", "team2"])
        XCTAssertEqual(model.teamID, "team2")
    }

    func testAFailedLoadShowsTheErrorAndARetryCanSucceed() async {
        let fake = FakeChannelSidebarService(data: standardData())
        fake.loadError = URLError(.notConnectedToInternet)
        let model = ChannelListViewModel(server: server(), service: fake)
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()
        guard case .failed = model.phase else { return XCTFail("expected a failure, got \(model.phase)") }

        fake.loadError = nil
        await model.reload()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.groups.count, 2)
    }

    func testAMissingCategoriesAnswerDrawsDefaultsAndRefusesWrites() async {
        var data = standardData()
        data.categories = []
        data.categoryOrder = []
        data.categoriesFailed = true
        let model = ChannelListViewModel(server: server(),
                                         service: FakeChannelSidebarService(data: data))
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()

        XCTAssertEqual(model.groups.map(\.kind), [.channels, .directMessages])
        XCTAssertTrue(model.groupingIsApproximate)
        XCTAssertFalse(model.canWriteLayout)
        let moved = await model.move(channelID: "c1", inCategory: "channels_", by: 1)
        XCTAssertFalse(moved, "a synthesised layout must not be written back over the user's")
    }

    // MARK: - 8. Reorder persistence (criterion 1)

    func testMovingAChannelPersistsManualOrderToTheServer() async {
        let fake = FakeChannelSidebarService(data: standardData())
        let model = ChannelListViewModel(server: server(), service: fake)
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()

        let moved = await model.move(channelID: "c2", inCategory: "chan", by: -1)
        XCTAssertTrue(moved)
        XCTAssertEqual(model.groups[0].entries.map(\.id), ["c2", "c1"])
        XCTAssertEqual(fake.savedCategories.count, 1)
        let saved = fake.savedCategories[0].first { $0.id == "chan" }
        XCTAssertEqual(saved?.channelIds, ["c2", "c1"])
        XCTAssertEqual(saved?.sorting, "manual", "a move means manual sorting, as on drag-and-drop")
        XCTAssertNil(model.actionError)
    }

    /// **The relaunch**: a second model (a fresh launch) over a server that kept what the first one
    /// wrote draws the same order. This is the acceptance criterion "a reorder persists across
    /// relaunch" at the client boundary; the live UI test proves the same against a real server.
    func testAReorderSurvivesARelaunch() async {
        let fake = FakeChannelSidebarService(data: standardData())
        let first = ChannelListViewModel(server: server(), service: fake)
        first.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await first.load()
        _ = await first.move(channelID: "c2", inCategory: "chan", by: -1)
        XCTAssertEqual(first.groups[0].entries.map(\.id), ["c2", "c1"])

        // "Relaunch": a new service seeded from the server's stored answer, and a new model.
        var relaunched = standardData()
        relaunched.categories = fake.storedCategories ?? relaunched.categories
        let second = ChannelListViewModel(server: server(),
                                          service: FakeChannelSidebarService(data: relaunched))
        second.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await second.load()
        XCTAssertEqual(second.groups[0].entries.map(\.id), ["c2", "c1"])
        XCTAssertEqual(second.groups[0].category.sorting, "manual")
    }

    func testAFailedReorderPutsTheLayoutBackAndSaysWhy() async {
        let fake = FakeChannelSidebarService(data: standardData())
        let model = ChannelListViewModel(server: server(), service: fake)
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()

        fake.saveError = URLError(.timedOut)
        let moved = await model.move(channelID: "c2", inCategory: "chan", by: -1)
        XCTAssertFalse(moved)
        XCTAssertEqual(model.groups[0].entries.map(\.id), ["c1", "c2"], "the optimistic move is undone")
        XCTAssertNotNil(model.actionError)
    }

    func testMovingBeyondTheEndsIsANoOp() async {
        let fake = FakeChannelSidebarService(data: standardData())
        let model = ChannelListViewModel(server: server(), service: fake)
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()
        let up = await model.move(channelID: "c1", inCategory: "chan", by: -1)
        let down = await model.move(channelID: "c2", inCategory: "chan", by: 1)
        XCTAssertFalse(up)
        XCTAssertFalse(down)
        XCTAssertTrue(fake.savedCategories.isEmpty)
    }

    func testFavouritingAddsToTheFavoritesCategoryAndPersists() async {
        let fake = FakeChannelSidebarService(data: standardData())
        let model = ChannelListViewModel(server: server(), service: fake)
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()

        let added = await model.setFavorite(true, channelID: "c2")
        XCTAssertTrue(added)
        let favorites = fake.savedCategories.last?.first { $0.kind == .favorites }
        XCTAssertEqual(favorites?.channelIds, ["c2"])
        XCTAssertEqual(model.groups.map(\.id), ["fav", "chan", "dm"], "the favourites section appears")
        XCTAssertTrue(model.entry(id: "c2")?.isFavorite == true)

        let removed = await model.setFavorite(false, channelID: "c2")
        XCTAssertTrue(removed)
        XCTAssertEqual(fake.savedCategories.last?.first { $0.kind == .favorites }?.channelIds, [])
        XCTAssertEqual(model.groups.map(\.id), ["chan", "dm"])
    }

    // MARK: - 9. Mute through the model

    func testMutingAChannelCallsTheServerAndDropsItFromTheTotals() async {
        let fake = FakeChannelSidebarService(data: standardData())
        let model = ChannelListViewModel(server: server(), service: fake)
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()
        XCTAssertEqual(model.totals.messages, 3)

        let muted = await model.setMuted(true, channelID: "c1")
        XCTAssertTrue(muted)
        XCTAssertEqual(fake.muteCalls.map { "\($0.0):\($0.1)" }, ["true:c1"])
        XCTAssertTrue(model.entry(id: "c1")?.isMuted == true)
        XCTAssertEqual(model.totals.messages, 0, "the muted channel's 3 unread messages leave the total")
        XCTAssertEqual(model.entry(id: "c1")?.badge, ChannelSidebarBadge.none)

        let unmuted = await model.setMuted(false, channelID: "c1")
        XCTAssertTrue(unmuted)
        XCTAssertEqual(fake.muteCalls.last?.0, false)
        XCTAssertEqual(model.totals.messages, 3)
    }

    func testAFailedMutePutsTheRowBack() async {
        let fake = FakeChannelSidebarService(data: standardData())
        let model = ChannelListViewModel(server: server(), service: fake)
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()
        fake.muteError = URLError(.cannotConnectToHost)
        let muted = await model.setMuted(true, channelID: "c1")
        XCTAssertFalse(muted)
        XCTAssertFalse(model.entry(id: "c1")?.isMuted ?? true)
        XCTAssertNotNil(model.actionError)
    }

    // MARK: - 10. Live unread state (criterion 2)

    func testChannelViewedByThisUserClearsTheCounterLocally() async {
        let fake = FakeChannelSidebarService(data: standardData())
        let model = ChannelListViewModel(server: server(), service: fake)
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()
        XCTAssertEqual(model.entry(id: "c1")?.unreadCount, 3)

        let outcome = model.handle(.channelViewed(SocketChannelViewed(channelID: "c1", userID: "me")),
                                   myUserID: "me")
        XCTAssertEqual(outcome, .counters)
        XCTAssertEqual(model.entry(id: "c1")?.unreadCount, 0)
        XCTAssertEqual(model.entry(id: "c1")?.badge, ChannelSidebarBadge.none)
    }

    func testAnotherUsersViewDoesNotClearMyCounter() async {
        let fake = FakeChannelSidebarService(data: standardData())
        let model = ChannelListViewModel(server: server(), service: fake)
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()
        let outcome = model.handle(.channelViewed(SocketChannelViewed(channelID: "c1", userID: "them")),
                                   myUserID: "me")
        XCTAssertEqual(outcome, .ignored)
        XCTAssertEqual(model.entry(id: "c1")?.unreadCount, 3)
    }

    /// The **view** call's event (T33-AV2 F1): a read by another client of *this* user names every
    /// channel whose cursor moved, and each row this list holds is read. A channel the list does not
    /// hold is skipped, not inserted — "read" is no reason to add a row.
    func testAReadFromAnotherClientClearsEveryRowItNames() async {
        let fake = FakeChannelSidebarService(data: standardData())
        let model = ChannelListViewModel(server: server(), service: fake)
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()
        XCTAssertEqual(model.entry(id: "c1")?.unreadCount, 3)
        XCTAssertFalse(model.totals.messages == 0, "the fixture must start unread, or this proves nothing")

        let outcome = model.handle(.multipleChannelsViewed(SocketMultipleChannelsViewed(
            userID: "me",
            channelTimes: ["c1": 1_700_000_000_000, "not-loaded": 1_700_000_000_000])),
            myUserID: "me")

        XCTAssertEqual(outcome, .counters)
        XCTAssertEqual(model.entry(id: "c1")?.unreadCount, 0)
        XCTAssertEqual(model.entry(id: "c1")?.badge, ChannelSidebarBadge.none)
        XCTAssertEqual(model.totals.messages, 0, "the view also moves the footer, like `channel_viewed`")
    }

    /// The frame is addressed to one user; another user's read must not clear mine.
    func testAnotherUsersMultipleViewDoesNotClearMyRows() async {
        let fake = FakeChannelSidebarService(data: standardData())
        let model = ChannelListViewModel(server: server(), service: fake)
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()

        let outcome = model.handle(.multipleChannelsViewed(SocketMultipleChannelsViewed(
            userID: "them", channelTimes: ["c1": 1_700_000_000_000])), myUserID: "me")

        XCTAssertEqual(outcome, .ignored)
        XCTAssertEqual(model.entry(id: "c1")?.unreadCount, 3)
    }

    /// A frame that names only channels this list does not hold changes nothing (and is not a refresh —
    /// there is nothing to fetch: the frame *is* the new state).
    func testAMultipleViewOfUnknownChannelsIsIgnored() async {
        let fake = FakeChannelSidebarService(data: standardData())
        let model = ChannelListViewModel(server: server(), service: fake)
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()

        let outcome = model.handle(.multipleChannelsViewed(SocketMultipleChannelsViewed(
            userID: "me", channelTimes: ["not-loaded": 1])), myUserID: "me")

        XCTAssertEqual(outcome, .ignored)
        XCTAssertEqual(model.entry(id: "c1")?.unreadCount, 3)
    }

    func testPostedAsksForARefreshAndTheRefreshMovesTheBadge() async {
        let fake = FakeChannelSidebarService(data: standardData())
        fake.refreshResult = ChannelSidebarRefresh(
            channels: [channel("c1", name: "alpha", displayName: "Alpha", totalMsgCount: 9),
                       channel("c2", name: "bravo", displayName: "Bravo", totalMsgCount: 2),
                       channel("d1", name: "id__me__them", displayName: "", type: "D")],
            members: [member("c1", msgCount: 2, mentions: 4), member("c2", msgCount: 2), member("d1")])
        let model = ChannelListViewModel(server: server(), service: fake)
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()
        XCTAssertEqual(model.entry(id: "c1")?.badge, .dot)

        let post = MMPost.fixture(channelID: "c1")
        XCTAssertEqual(model.handle(.posted(post), myUserID: "me"), .refreshNeeded)
        await model.refreshCounters()
        XCTAssertEqual(model.entry(id: "c1")?.badge, .count(4))
        XCTAssertEqual(model.totals.mentions, 4)
    }

    func testAFailedCounterRefreshKeepsTheLastNumbersAndLabelsThemStale() async {
        let fake = FakeChannelSidebarService(data: standardData())
        let model = ChannelListViewModel(server: server(), service: fake)
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()
        fake.refreshError = URLError(.timedOut)
        await model.refreshCounters()
        XCTAssertTrue(model.countsAreStale)
        XCTAssertEqual(model.entry(id: "c1")?.unreadCount, 3, "the numbers are kept, not zeroed")
    }

    // MARK: - 11. The coordinator

    func testOneModelPerServerAndNoSocketOfItsOwn() async {
        let fake = FakeChannelSidebarService(data: standardData())
        let coordinator = ChannelSidebarCoordinator(makeService: { _ in fake })
        let config = server()
        let a = coordinator.model(for: config)
        let b = coordinator.model(for: config)
        XCTAssertTrue(a === b)
        XCTAssertEqual(coordinator.modelCount, 1)
        // The coordinator never asks for an event stream: the rail's socket feeds it.
        XCTAssertEqual(coordinator.eventCount, 0)
    }

    func testTheCoordinatorLoadsTheTeamTheShellIsOnAndDebouncesSocketActivity() async throws {
        let fake = FakeChannelSidebarService(data: standardData())
        fake.refreshResult = ChannelSidebarRefresh(
            channels: standardData().channels,
            members: [member("c1", msgCount: 2, mentions: 1), member("c2", msgCount: 2), member("d1")])
        let coordinator = ChannelSidebarCoordinator(refreshDelay: 0.05, makeService: { _ in fake })
        let config = server()
        let store = ServerStore(preferences: preferences())
        _ = store.add(config)
        retainedStores.append(store)
        let navigation = NativeNavigation(resolver: SurfaceModeResolver(preferences: preferences(),
                                                                       arguments: ["-surfaceMode", "sidebar=native"]))
        navigation.serverStore = store
        #if DEBUG
        // The funnel refuses a route for a signed-out server; this gate is T30's test seam.
        navigation.authGate = AssumedSignedInAuthGate()
        #endif
        _ = navigation.openChannel(NativeChannelRequest(serverID: config.id,
                                                        teamID: "team1",
                                                        teamName: "acme",
                                                        channelID: "c1",
                                                        channelName: "alpha"))
        coordinator.bind(auth: AuthCoordinator(), navigation: navigation, serverStore: store, teams: nil)
        await coordinator.activate(config)

        XCTAssertEqual(fake.loadTeamIDs, ["team1"])
        XCTAssertEqual(coordinator.loadedTeam(for: config.id), "team1")
        let model = coordinator.model(for: config)
        XCTAssertTrue(model.entry(id: "c1")?.isSelected == true)

        // Three posts in a row are one refresh, not three (the debounce).
        for _ in 0..<3 {
            await coordinator.handle(.posted(MMPost.fixture(channelID: "c1")), serverID: config.id)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fake.refreshCount, 1)
        XCTAssertEqual(coordinator.counterRefreshCount, 1)
        XCTAssertEqual(model.entry(id: "c1")?.badge, .count(1))
    }

    /// T30's `NativeChannelDirectory` seam, now implemented: a deep link's channel **name** and a
    /// mention tap's channel **id** converge on the same identity.
    func testTheDirectoryResolvesAChannelNameToItsIDAndBack() async {
        let fake = FakeChannelSidebarService(data: standardData())
        let coordinator = ChannelSidebarCoordinator(makeService: { _ in fake })
        let config = server()
        let store = ServerStore(preferences: preferences())
        _ = store.add(config)
        retainedStores.append(store)
        let navigation = NativeNavigation(resolver: SurfaceModeResolver(preferences: preferences(),
                                                                       arguments: ["-surfaceMode", "sidebar=native"]))
        navigation.serverStore = store
        #if DEBUG
        navigation.authGate = AssumedSignedInAuthGate()
        #endif
        _ = navigation.openChannel(NativeChannelRequest(serverID: config.id,
                                                        teamID: "team1",
                                                        teamName: "acme",
                                                        channelName: "alpha"))
        coordinator.bind(auth: AuthCoordinator(), navigation: navigation, serverStore: store, teams: nil)
        await coordinator.activate(config)

        let byName = coordinator.identity(
            for: NativeChannelRequest(teamID: "team1", channelName: "alpha"),
            serverID: config.id)
        XCTAssertEqual(byName?.channelID, "c1")
        XCTAssertEqual(byName?.channelName, "alpha")

        let byID = coordinator.identity(
            for: NativeChannelRequest(teamID: "team1", channelID: "c2"),
            serverID: config.id)
        XCTAssertEqual(byID?.channelName, "bravo")

        let unknown = coordinator.identity(
            for: NativeChannelRequest(teamID: "team1", channelName: "does-not-exist"),
            serverID: config.id)
        XCTAssertNil(unknown?.channelID, "an unknown name is not guessed into an id")
    }

    // MARK: - 12. T33-R repairs (the T33-AV findings)

    /// F1's unit half: the write's answer is a **bare array**, and the GET's keyed `{order,
    /// categories}` shape does not decode it. This is the exact payload the pinned 9.11.19 server
    /// answered with (T33-R §2).
    func testTheCategoriesWriteAnswerIsTheBareArrayTheServerSends() throws {
        let json = """
        [{"id":"channels_uid_team","user_id":"uid","team_id":"team","sort_order":10,
          "sorting":"manual","type":"channels","display_name":"Channels","muted":false,
          "collapsed":true,"channel_ids":["c2","c1"]},
         {"id":"direct_messages_uid_team","user_id":"uid","team_id":"team","sort_order":20,
          "sorting":"recent","type":"direct_messages","display_name":"Direct Messages","muted":false,
          "collapsed":false,"channel_ids":[]}]
        """
        let decoded = try JSONDecoder().decode([MMSidebarCategory].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.map(\.id), ["channels_uid_team", "direct_messages_uid_team"])
        XCTAssertEqual(decoded.first?.channelIds, ["c2", "c1"])
        XCTAssertEqual(decoded.first?.collapsed, true)
        // The old code decoded this body with the GET shape; that is the throw that rolled a
        // successful write back (T33-AV F1). Pinned so the two shapes cannot be confused again.
        XCTAssertThrowsError(try JSONDecoder().decode(MMSidebarCategories.self, from: Data(json.utf8)))
    }

    /// The drawn order after a write: kept from what the sidebar already had, extended only by a
    /// category the answer introduced.
    func testTheCategoryOrderSurvivesAnArrayAnswerAndTakesANewCategory() {
        let saved = [category("chan", type: "channels", sorting: "manual", channelIDs: ["c2", "c1"]),
                     category("fav", type: "favorites", sortOrder: 0),
                     category("new", type: "custom", displayName: "Projects", sortOrder: 5)]
        XCTAssertEqual(ChannelSidebarDerivation.order(afterSaved: saved, previous: ["fav", "chan"]),
                       ["fav", "chan", "new"],
                       "the existing drawn order is kept; the new category is appended in the server's order")
        XCTAssertEqual(ChannelSidebarDerivation.order(afterSaved: [category("chan", type: "channels")],
                                                      previous: ["fav", "chan"]),
                       ["chan"],
                       "a category the answer dropped leaves the order")
    }

    /// A move is applied on the server and the server's own array is what the list rebases on — never
    /// a rollback of a write the server accepted.
    func testAMoveRebasesOnTheServersAnswerInsteadOfRollingBack() async {
        let fake = FakeChannelSidebarService(data: standardData())
        // The server normalises: it keeps a hidden channel at the end and says so in its answer.
        fake.saveAnswer = { categories in
            var answered = categories
            if let index = answered.firstIndex(where: { $0.id == "chan" }) {
                answered[index].channelIds = ["c2", "c1", "hidden"]
            }
            return answered
        }
        let model = ChannelListViewModel(server: server(), service: fake)
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()

        let moved = await model.move(channelID: "c2", inCategory: "chan", by: -1)
        XCTAssertTrue(moved)
        XCTAssertNil(model.actionError, "the server accepted the write, so nothing may be reported as failed")
        XCTAssertEqual(model.groups[0].entries.map(\.id), ["c2", "c1"])
        XCTAssertEqual(fake.savedCategories.count, 1)
    }

    func testACollapseReachesTheServerAndSurvivesItsAnswer() async {
        let fake = FakeChannelSidebarService(data: standardData())
        let model = ChannelListViewModel(server: server(), service: fake)
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()

        await model.setCollapsed(true, categoryID: "chan")
        XCTAssertTrue(model.isCollapsed(categoryID: "chan"))
        XCTAssertEqual(fake.savedCategories.last?.first { $0.id == "chan" }?.collapsed, true,
                       "the collapse must be written, not only drawn")
        XCTAssertNil(model.actionError)
    }

    func testAFailedCollapsePutsTheCategoryBackAndSaysWhy() async {
        let fake = FakeChannelSidebarService(data: standardData())
        let model = ChannelListViewModel(server: server(), service: fake)
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()

        fake.saveError = URLError(.timedOut)
        await model.setCollapsed(true, categoryID: "chan")
        XCTAssertFalse(model.isCollapsed(categoryID: "chan"), "the local state must not outlive a failed write")
        XCTAssertNotNil(model.actionError)
    }

    /// F3: the layout another client wrote arrives as `sidebar_category_updated` and is applied from
    /// the payload — no request, no relaunch.
    func testACategoryUpdateFromAnotherClientReachesTheOpenList() async {
        let fake = FakeChannelSidebarService(data: standardData())
        let model = ChannelListViewModel(server: server(), service: fake)
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()
        XCTAssertEqual(model.groups[0].entries.map(\.id), ["c1", "c2"])

        var categories = standardData().categories
        let index = try! XCTUnwrap(categories.firstIndex { $0.id == "chan" })
        categories[index].channelIds = ["c2", "c1"]
        categories[index].collapsed = true

        let outcome = model.handle(.sidebarCategoryUpdated(
            SocketSidebarCategoryUpdate(teamID: "team1", categories: categories)), myUserID: "me")
        XCTAssertEqual(outcome, .layoutChanged)
        XCTAssertEqual(model.groups[0].entries.map(\.id), ["c2", "c1"],
                       "an external reorder must reach the open list without a relaunch")
        XCTAssertTrue(model.isCollapsed(categoryID: "chan"))
        XCTAssertEqual(fake.loadTeamIDs.count, 1, "the event carried the layout; nothing to fetch")

        // A layout for another team is not this list's business.
        let other = model.handle(.sidebarCategoryUpdated(
            SocketSidebarCategoryUpdate(teamID: "team2", categories: categories)), myUserID: "me")
        XCTAssertEqual(other, .ignored)
    }

    func testPostUnreadAppliesTheServersOwnCounters() async {
        let fake = FakeChannelSidebarService(data: standardData())
        let model = ChannelListViewModel(server: server(), service: fake)
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()
        XCTAssertEqual(model.entry(id: "c1")?.unreadCount, 3)

        let outcome = model.handle(.postUnread(SocketPostUnread(channelID: "c1",
                                                                teamID: "team1",
                                                                msgCount: 5,
                                                                mentionCount: 2,
                                                                lastViewedAt: 9)),
                                   myUserID: "me")
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(model.entry(id: "c1")?.unreadCount, 0, "msg_count is the server's cursor")
        XCTAssertEqual(model.entry(id: "c1")?.badge, .count(2))
        XCTAssertEqual(fake.refreshCount, 0, "the event's numbers are the server's; no request")
    }

    func testAnotherClientsMuteArrivesInMyMembershipRow() async {
        let fake = FakeChannelSidebarService(data: standardData())
        let model = ChannelListViewModel(server: server(), service: fake)
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()
        XCTAssertEqual(model.totals.messages, 3)

        let mine = model.handle(.channelMemberUpdated(
            SocketChannelMemberUpdate(member: member("c1", msgCount: 2, muted: true))),
                                myUserID: "me")
        XCTAssertEqual(mine, .applied)
        XCTAssertTrue(model.entry(id: "c1")?.isMuted == true)
        XCTAssertEqual(model.totals.messages, 0, "the muted channel leaves the totals")

        let theirs = model.handle(.channelMemberUpdated(
            SocketChannelMemberUpdate(member: MMChannelMember(
                channelId: "c2", userId: "them",
                notifyProps: .object(["mark_unread": .string("mention")])))),
                                  myUserID: "me")
        XCTAssertEqual(theirs, .ignored, "somebody else's mute says nothing about my badges")
        XCTAssertFalse(model.entry(id: "c2")?.isMuted ?? true)
    }

    func testChannelCreatedAsksForAFullReloadAndDeletedForACounterRefresh() async {
        let fake = FakeChannelSidebarService(data: standardData())
        let model = ChannelListViewModel(server: server(), service: fake)
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()

        XCTAssertEqual(model.handle(.channelCreated(SocketChannelEvent(channelID: "c9", teamID: "team1")),
                                    myUserID: "me"), .reloadNeeded,
                       "a new channel cannot appear from a counter refresh alone")
        XCTAssertEqual(model.handle(.channelDeleted(SocketChannelEvent(channelID: "c1", teamID: "team1")),
                                    myUserID: "me"), .refreshNeeded,
                       "the channel list read drops an archived channel")
    }

    /// The coordinator's half of `channel_created`: one **full** reload behind the debounce.
    func testAChannelCreatedEventReloadsTheListOncePerDebounce() async throws {
        let fake = FakeChannelSidebarService(data: standardData())
        let coordinator = ChannelSidebarCoordinator(refreshDelay: 0.05, makeService: { _ in fake })
        let config = server()
        let store = ServerStore(preferences: preferences())
        _ = store.add(config)
        retainedStores.append(store)
        let navigation = NativeNavigation(resolver: SurfaceModeResolver(preferences: preferences(),
                                                                       arguments: ["-surfaceMode", "sidebar=native"]))
        navigation.serverStore = store
        #if DEBUG
        navigation.authGate = AssumedSignedInAuthGate()
        #endif
        _ = navigation.openChannel(NativeChannelRequest(serverID: config.id,
                                                        teamID: "team1",
                                                        channelName: "alpha"))
        coordinator.bind(auth: AuthCoordinator(), navigation: navigation, serverStore: store, teams: nil)
        await coordinator.activate(config)
        XCTAssertEqual(fake.loadTeamIDs, ["team1"])

        for _ in 0..<2 {
            await coordinator.handle(.channelCreated(SocketChannelEvent(channelID: "c9", teamID: "team1")),
                                     serverID: config.id)
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(fake.loadTeamIDs, ["team1", "team1"], "two events are one reload")
        XCTAssertEqual(coordinator.reloadCount, 1)
        XCTAssertEqual(coordinator.counterRefreshCount, 0)
    }

    // MARK: - 13. The new socket events decode (measured on the pinned server)

    func testSidebarCategoryUpdatedDecodesTheStringPayload() throws {
        let frame = try socketFrame("""
        {"event":"sidebar_category_updated","seq":1,
         "data":{"updatedCategories":"[{\\"id\\":\\"channels_u_t\\",\\"user_id\\":\\"u\\",\\"team_id\\":\\"t\\",\\"sort_order\\":10,\\"sorting\\":\\"manual\\",\\"type\\":\\"channels\\",\\"display_name\\":\\"Channels\\",\\"muted\\":false,\\"collapsed\\":false,\\"channel_ids\\":[\\"c2\\",\\"c1\\"]}]"},
         "broadcast":{"user_id":"u","channel_id":"","team_id":"t"}}
        """)
        guard case .sidebarCategoryUpdated(let update)? = SocketEvent(frame: frame) else {
            return XCTFail("expected a typed sidebar_category_updated event")
        }
        XCTAssertEqual(update.teamID, "t")
        XCTAssertEqual(update.categories.first?.channelIds, ["c2", "c1"])
    }

    func testPostUnreadDecodesItsChannelFromTheEnvelope() throws {
        let frame = try socketFrame("""
        {"event":"post_unread","seq":2,
         "data":{"msg_count":12,"mention_count":2,"mention_count_root":0,
                 "urgent_mention_count":0,"last_viewed_at":99,"post_id":"p1"},
         "broadcast":{"user_id":"me","channel_id":"c1","team_id":"team1"}}
        """)
        guard case .postUnread(let unread)? = SocketEvent(frame: frame) else {
            return XCTFail("expected a typed post_unread event — its channel is only in `broadcast`")
        }
        XCTAssertEqual(unread.channelID, "c1")
        XCTAssertEqual(unread.msgCount, 12)
        XCTAssertEqual(unread.mentionCount, 2)
        XCTAssertEqual(unread.lastViewedAt, 99)
        XCTAssertEqual(SocketEvent(frame: frame)?.name, "post_unread")
    }

    /// The **view** call's frame, verbatim from the pinned 9.11.19 server (`docs/t33r2-build-note.md`
    /// §2): `data.channel_times` is a `{channel_id: last_viewed_at}` map, and the envelope names
    /// **no** channel and **no** team — only the user whose read cursor moved (T33-AV2 F1).
    func testMultipleChannelsViewedDecodesTheChannelTimesMap() throws {
        let frame = try socketFrame("""
        {"event":"multiple_channels_viewed","seq":2,
         "data":{"channel_times":{"re4jed6wti8e8g9jt8aza9ewye":1792961099716}},
         "broadcast":{"user_id":"me","channel_id":"","team_id":""}}
        """)
        guard case .multipleChannelsViewed(let viewed)? = SocketEvent(frame: frame) else {
            return XCTFail("expected a typed multiple_channels_viewed event")
        }
        XCTAssertEqual(viewed.userID, "me", "the envelope's user_id is the only routing fact")
        XCTAssertEqual(viewed.channelIDs, ["re4jed6wti8e8g9jt8aza9ewye"])
        XCTAssertEqual(viewed.channelTimes["re4jed6wti8e8g9jt8aza9ewye"], 1_792_961_099_716)
        XCTAssertEqual(SocketEvent(frame: frame)?.name, "multiple_channels_viewed")
        XCTAssertNil(SocketEvent(frame: frame)?.dedupeKey,
                     "the same user can view the same channel twice — the occurrence is the signal")
    }

    /// A frame without `channel_times` says nothing to apply, so it is dropped rather than typed with
    /// an empty map (which would look like "somebody read nothing").
    func testAMultipleChannelsViewedFrameWithoutTimesIsDropped() throws {
        let frame = try socketFrame("""
        {"event":"multiple_channels_viewed","seq":2,"data":{},
         "broadcast":{"user_id":"me","channel_id":"","team_id":""}}
        """)
        XCTAssertNil(SocketEvent(frame: frame), "no `channel_times` → nothing to apply")
    }

    func testChannelMemberUpdatedDecodesTheRow() throws {
        let frame = try socketFrame("""
        {"event":"channel_member_updated","seq":3,
         "data":{"channelMember":"{\\"channel_id\\":\\"c1\\",\\"user_id\\":\\"me\\",\\"msg_count\\":2,\\"mention_count\\":1,\\"last_viewed_at\\":5,\\"notify_props\\":{\\"mark_unread\\":\\"mention\\"}}"},
         "broadcast":{"user_id":"me","channel_id":"","team_id":""}}
        """)
        guard case .channelMemberUpdated(let update)? = SocketEvent(frame: frame) else {
            return XCTFail("expected a typed channel_member_updated event")
        }
        XCTAssertEqual(update.channelID, "c1")
        XCTAssertEqual(update.userID, "me")
        XCTAssertEqual(update.member.notifyProps?["mark_unread"]?.stringValue, "mention")
        XCTAssertTrue(ChannelSidebarDerivation.isMuted(update.member))
    }

    func testChannelCreatedAndDeletedDecodeTheirIds() throws {
        let created = try socketFrame("""
        {"event":"channel_created","seq":4,"data":{"channel_id":"c9","team_id":"t"},
         "broadcast":{"user_id":"me","channel_id":"","team_id":""}}
        """)
        guard case .channelCreated(let new)? = SocketEvent(frame: created) else {
            return XCTFail("expected a typed channel_created event")
        }
        XCTAssertEqual(new.channelID, "c9")
        XCTAssertEqual(new.teamID, "t")

        let deleted = try socketFrame("""
        {"event":"channel_deleted","seq":5,"data":{"channel_id":"c9","delete_at":123},
         "broadcast":{"user_id":"","channel_id":"","team_id":"t"}}
        """)
        guard case .channelDeleted(let gone)? = SocketEvent(frame: deleted) else {
            return XCTFail("expected a typed channel_deleted event")
        }
        XCTAssertEqual(gone.channelID, "c9")
        XCTAssertEqual(gone.teamID, "t", "the team is only in the envelope")
        XCTAssertEqual(gone.deleteAt, 123)
    }

    /// The scope must let the new events through for the team on screen and refuse another team's.
    func testTheScopeAttributesTheNewEventsToTheActiveTeam() {
        let scope = TeamSocketScope(teamID: "team1", activeChannelID: "c1",
                                    channelTeams: ["c2": "team1", "x1": "team2"])
        XCTAssertTrue(scope.accepts(.postUnread(SocketPostUnread(channelID: "c2", teamID: "team1",
                                                                msgCount: 1, mentionCount: 0,
                                                                lastViewedAt: 0))))
        XCTAssertFalse(scope.accepts(.postUnread(SocketPostUnread(channelID: "x1", teamID: "team2",
                                                                 msgCount: 1, mentionCount: 0,
                                                                 lastViewedAt: 0))))
        XCTAssertTrue(scope.accepts(.channelMemberUpdated(
            SocketChannelMemberUpdate(member: memberForScope(channelID: "c2")))))
        XCTAssertFalse(scope.accepts(.channelMemberUpdated(
            SocketChannelMemberUpdate(member: memberForScope(channelID: "x1")))))
        XCTAssertTrue(scope.accepts(.channelCreated(SocketChannelEvent(channelID: "c9", teamID: "team1"))))
        XCTAssertFalse(scope.accepts(.channelCreated(SocketChannelEvent(channelID: "c9", teamID: "team2"))))
        XCTAssertTrue(scope.accepts(.channelDeleted(SocketChannelEvent(channelID: "c2", teamID: "team1"))))
        XCTAssertTrue(scope.accepts(.sidebarCategoryUpdated(
            SocketSidebarCategoryUpdate(teamID: "team1", categories: []))))
        XCTAssertFalse(scope.accepts(.sidebarCategoryUpdated(
            SocketSidebarCategoryUpdate(teamID: "team2", categories: []))))
        // The view call's event: no channel/team in the envelope, so it is accepted when **any** of the
        // channels it names is in the team on screen (a view never spans the teams of one user in
        // practice, but the rule must not depend on that).
        XCTAssertTrue(scope.accepts(.multipleChannelsViewed(
            SocketMultipleChannelsViewed(userID: "me", channelTimes: ["c2": 1]))))
        XCTAssertTrue(scope.accepts(.multipleChannelsViewed(
            SocketMultipleChannelsViewed(userID: "me", channelTimes: ["x1": 1, "c2": 1]))))
        XCTAssertFalse(scope.accepts(.multipleChannelsViewed(
            SocketMultipleChannelsViewed(userID: "me", channelTimes: ["x1": 1]))))
    }

    /// F5: a counter refresh whose membership call failed keeps the last numbers and says they are
    /// stale — the shape production actually produces (`membersFailed` + an empty list).
    func testAPartialCounterRefreshKeepsTheNumbersAndMarksThemStale() async {
        let fake = FakeChannelSidebarService(data: standardData())
        let model = ChannelListViewModel(server: server(), service: fake)
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()

        fake.refreshResult = ChannelSidebarRefresh(channels: standardData().channels,
                                                   members: [],
                                                   membersFailed: true)
        await model.refreshCounters()
        XCTAssertTrue(model.countsAreStale)
        XCTAssertEqual(model.entry(id: "c1")?.unreadCount, 3, "the numbers are kept, not zeroed")
        XCTAssertEqual(model.totals.messages, 3)
    }

    /// The same defect one layer down: even without the flag, an empty membership answer for a team
    /// that has channels is not "everything is read".
    func testAnEmptyMembersAnswerIsNotTreatedAsEverythingRead() async {
        let fake = FakeChannelSidebarService(data: standardData())
        let model = ChannelListViewModel(server: server(), service: fake)
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()

        fake.refreshResult = ChannelSidebarRefresh(channels: standardData().channels, members: [])
        await model.refreshCounters()
        XCTAssertTrue(model.countsAreStale)
        XCTAssertEqual(model.entry(id: "c1")?.unreadCount, 3)
    }

    func testSignOutForgetsTheModelAndTheChannelTeamMap() async {
        let fake = FakeChannelSidebarService(data: standardData())
        let coordinator = ChannelSidebarCoordinator(makeService: { _ in fake })
        let config = server()
        _ = coordinator.model(for: config)
        await coordinator.deactivate(config.id)
        XCTAssertEqual(coordinator.modelCount, 0)
        XCTAssertNil(coordinator.loadedTeam(for: config.id))
    }
}

// MARK: - Fixtures / doubles

private extension ChannelSidebarEntry {
    static func fixture(mentions: Int,
                        unread: Int,
                        muted: Bool = false,
                        manuallyUnread: Bool = false) -> ChannelSidebarEntry {
        ChannelSidebarEntry(id: "cid",
                            name: "cid",
                            displayName: "Cid",
                            kind: .publicChannel,
                            unreadCount: unread,
                            mentionCount: mentions,
                            isMuted: muted,
                            manuallyUnread: manuallyUnread,
                            isFavorite: false,
                            isSelected: false,
                            lastPostAt: 0,
                            createdAt: 0,
                            searchTerms: [])
    }
}

extension MMPost {
    static func fixture(channelID: String) -> MMPost {
        MMPost(id: "p\(UUID().uuidString.prefix(8))",
               userId: "them",
               channelId: channelID,
               message: "hello")
    }
}

/// Decode a WebSocket v4 frame from its JSON text — the shape the server actually sends.
private func socketFrame(_ json: String) throws -> MMSocketFrame {
    try JSONDecoder().decode(MMSocketFrame.self, from: Data(json.utf8))
}

private func memberForScope(channelID: String) -> MMChannelMember {
    MMChannelMember(channelId: channelID, userId: "me")
}

@MainActor
final class FakeChannelSidebarService: ChannelSidebarServing {
    var data: ChannelSidebarData
    var refreshResult: ChannelSidebarRefresh?
    var loadError: Error?
    var refreshError: Error?
    var saveError: Error?
    var muteError: Error?
    /// A hook that lets a test pretend the server normalises a categories write before answering.
    var saveAnswer: (([MMSidebarCategory]) -> [MMSidebarCategory])?

    private(set) var loadTeamIDs: [String] = []
    private(set) var savedCategories: [[MMSidebarCategory]] = []
    private(set) var muteCalls: [(Bool, String)] = []
    private(set) var refreshCount = 0
    /// What the fake "server" kept: the last category layout it accepted.
    private(set) var storedCategories: [MMSidebarCategory]?

    init(data: ChannelSidebarData) {
        self.data = data
    }

    func load(teamID: String) async throws -> ChannelSidebarData {
        loadTeamIDs.append(teamID)
        if let loadError { throw loadError }
        return data
    }

    func refresh(teamID: String) async throws -> ChannelSidebarRefresh {
        refreshCount += 1
        if let refreshError { throw refreshError }
        if let refreshResult {
            data.replaceCounters(channels: refreshResult.channels, members: refreshResult.members)
            return refreshResult
        }
        return ChannelSidebarRefresh(channels: data.channels, members: data.members)
    }

    func save(categories: [MMSidebarCategory], teamID: String) async throws -> [MMSidebarCategory] {
        if let saveError { throw saveError }
        savedCategories.append(categories)
        let answered = saveAnswer?(categories) ?? categories
        storedCategories = answered
        // The production answer: a bare array, exactly the shape the server sends back (T33-AV F1).
        return answered
    }

    func setMuted(_ muted: Bool, channelID: String) async throws {
        if let muteError { throw muteError }
        muteCalls.append((muted, channelID))
        if let index = data.members.firstIndex(where: { $0.channelId == channelID }) {
            data.members[index].notifyProps = .object(["mark_unread": .string(muted ? "mention" : "all")])
        }
    }
}
