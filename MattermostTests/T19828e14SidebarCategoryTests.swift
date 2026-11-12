import XCTest
@testable import Mattermost

/// t19828e14 — managing the sidebar's categories: move a channel between categories, create one,
/// rename it, reorder it, delete it, and survive an empty category.
///
/// Every test here runs against a fake that behaves like the **pinned server** (Mattermost 9.11.19,
/// measured with `scripts/t19828e14_category_probe.py`):
///
///  * a categories write is the whole array (`PUT /users/{uid}/teams/{tid}/channels/categories`) and
///    the answer is a bare array, not the keyed GET shape;
///  * `POST …/channels/categories` **generates the id itself** — the id in the request is ignored —
///    which is why the create's answer, not the local record, is the category;
///  * `POST …/channels/categories/order` is the only route that reorders (`sort_order` inside the
///    whole-array PUT is ignored);
///  * deleting a category does **not** delete its channels: the server moves them into `channels` /
///    `direct_messages` for their kind, which is what the fake does too.
///
/// The acceptance criteria are pinned where they can actually be false:
///  1. a channel move writes both lists in one request (and offers a target per category, empty ones
///     included);
///  2. create / rename / delete / reorder reach the server and change the drawn sidebar;
///  3. delete returns the channels to their default category and proves it;
///  4. an empty category is still drawn;
///  5. two writes fired together both land (one writer), and a refused write restores the previous
///     arrangement *and says so*.
@MainActor
final class T19828e14SidebarCategoryTests: XCTestCase {

    // MARK: - Fixtures

    private func channel(_ id: String,
                         displayName: String? = nil,
                         type: String = "O") -> MMChannel {
        MMChannel(id: id,
                  name: id,
                  displayName: displayName ?? id.uppercased(),
                  type: type,
                  teamId: "team1",
                  lastPostAt: 0,
                  totalMsgCount: 0,
                  createAt: 1,
                  deleteAt: 0)
    }

    private func member(_ channelID: String) -> MMChannelMember {
        MMChannelMember(channelId: channelID,
                        userId: "me",
                        lastViewedAt: 0,
                        msgCount: 0,
                        mentionCount: 0,
                        manuallyUnread: false,
                        notifyProps: .object(["mark_unread": .string("all")]))
    }

    private func category(_ id: String,
                          type: String,
                          displayName: String = "",
                          sorting: String = "manual",
                          sortOrder: Int = 10,
                          channelIDs: [String] = []) -> MMSidebarCategory {
        MMSidebarCategory(id: id,
                          userId: "me",
                          teamId: "team1",
                          sortOrder: sortOrder,
                          sorting: sorting,
                          type: type,
                          displayName: displayName,
                          channelIds: channelIDs)
    }

    /// `Channels` holding alpha and bravo, `Direct Messages` holding one DM, and a reader-made
    /// `Projects` category holding charlie — the shortest layout in which every rule is observable.
    private func data() -> ChannelSidebarData {
        var data = ChannelSidebarData(channels: [channel("alpha"), channel("bravo"),
                                                 channel("charlie"), channel("dm1", type: "D")],
                                      members: [member("alpha"), member("bravo"),
                                                member("charlie"), member("dm1")])
        data.categories = [
            category("fav", type: "favorites", displayName: "Favorites", sortOrder: 0),
            category("chan", type: "channels", displayName: "Channels", sortOrder: 10,
                     channelIDs: ["alpha", "bravo"]),
            category("dm", type: "direct_messages", displayName: "Direct Messages",
                     sorting: "recent", sortOrder: 20, channelIDs: ["dm1"]),
            category("proj", type: "custom", displayName: "Projects", sortOrder: 30,
                     channelIDs: ["charlie"]),
        ]
        data.categoryOrder = ["fav", "chan", "dm", "proj"]
        return data
    }

    private func loaded(_ server: FakeCategoryServer, teamID: String = "team1") async -> ChannelListViewModel {
        let model = ChannelListViewModel(server: ServerConfig(name: "Example",
                                                              url: URL(string: "https://mm.example")!),
                                         service: server)
        model.setSelection(teamID: teamID, channelID: nil, channelName: nil)
        await model.load()
        return model
    }

    private func stored(_ server: FakeCategoryServer, _ id: String) -> MMSidebarCategory? {
        server.storedCategories.first { $0.id == id }
    }

    // MARK: - 1. A channel moves between categories

    func testMoveWritesBothListsInASingleRequest() async {
        let server = FakeCategoryServer(data: data())
        let model = await loaded(server)

        let moved = await model.move(channelID: "alpha", toCategoryID: "proj")
        XCTAssertTrue(moved, "the move must be accepted")
        XCTAssertEqual(server.saves, 1, "one move is one PUT — the whole array, not two half writes")
        XCTAssertEqual(stored(server, "proj")?.channelIds, ["charlie", "alpha"],
                       "the target lists the channel, appended")
        XCTAssertEqual(stored(server, "chan")?.channelIds, ["bravo"],
                       "and the category it left no longer lists it")
        XCTAssertEqual(model.groups.first { $0.id == "proj" }?.entries.map(\.id), ["charlie", "alpha"])
    }

    /// The row moves before the request answers — the optimistic half of requirement 5.
    func testTheRowMovesBeforeTheServerAnswers() async {
        let server = FakeCategoryServer(data: data())
        let model = await loaded(server)
        server.holdSaves = true

        let move = Task { await model.move(channelID: "alpha", toCategoryID: "proj") }
        // Let the write reach the fake, which is holding the answer open.
        while server.saves == 0 { await Task.yield() }
        XCTAssertEqual(model.groups.first { $0.id == "proj" }?.entries.map(\.id), ["charlie", "alpha"],
                       "the row is drawn in the new category while the server is still answering")
        server.releaseSaves()
        _ = await move.value
    }

    func testTheMoveTargetsCoverEveryCategoryButTheRowsOwn() async {
        let server = FakeCategoryServer(data: data())
        let model = await loaded(server)

        let targets = model.moveTargets(channelID: "alpha")
        XCTAssertEqual(targets.map(\.id), ["fav", "dm", "proj"],
                       "every other category is a destination, in the server's drawn order — "
                       + "including Favorites and Direct Messages")
        XCTAssertEqual(targets.map(\.displayName), ["Favorites", "Direct Messages", "Projects"])
        XCTAssertTrue(model.moveTargets(channelID: "charlie").map(\.id).contains("chan"))
        XCTAssertFalse(model.moveTargets(channelID: "charlie").map(\.id).contains("proj"),
                       "the category the row is drawn in is not a destination")
    }

    func testAnEmptyCustomCategoryIsOfferedAsATarget() async {
        var data = data()
        data.categories.append(category("empty", type: "custom", displayName: "Later", sortOrder: 40))
        data.categoryOrder.append("empty")
        let server = FakeCategoryServer(data: data)
        let model = await loaded(server)

        XCTAssertTrue(model.moveTargets(channelID: "alpha").map(\.id).contains("empty"),
                      "an empty category is exactly where a channel is most likely to be moved")
        let moved = await model.move(channelID: "alpha", toCategoryID: "empty")
        XCTAssertTrue(moved)
        XCTAssertEqual(stored(server, "empty")?.channelIds, ["alpha"])
    }

    /// Favourites is additive. Moving *into* it is `setFavorite(true)` by another name.
    func testMovingIntoFavoritesLeavesTheHomingCategoryAlone() async {
        let server = FakeCategoryServer(data: data())
        let model = await loaded(server)

        let moved = await model.move(channelID: "alpha", toCategoryID: "fav")
        XCTAssertTrue(moved)
        XCTAssertEqual(stored(server, "fav")?.channelIds, ["alpha"])
        XCTAssertEqual(stored(server, "chan")?.channelIds, ["alpha", "bravo"],
                       "a favourite keeps its home category — the channel is drawn in both")
    }

    func testMovingOutOfFavoritesRemovesOnlyTheFavorite() async {
        var data = data()
        data.categories[0].channelIds = ["alpha"]
        let server = FakeCategoryServer(data: data)
        let model = await loaded(server)
        XCTAssertEqual(model.groups.first?.entries.map(\.id), ["alpha"], "drawn under Favorites first")

        let moved = await model.move(channelID: "alpha", toCategoryID: "proj")
        XCTAssertTrue(moved)
        XCTAssertEqual(stored(server, "fav")?.channelIds, [])
        XCTAssertEqual(stored(server, "proj")?.channelIds, ["charlie", "alpha"],
                       "the channel arrives in the target…")
        XCTAssertEqual(stored(server, "chan")?.channelIds, ["alpha", "bravo"],
                       "…and never left its home category, because Favorites never owned it")
    }

    func testAFavoritesTargetIsNotOfferedForAChannelItAlreadyLists() async {
        var data = data()
        data.categories[0].channelIds = ["alpha"]
        let server = FakeCategoryServer(data: data)
        let model = await loaded(server)

        XCTAssertFalse(model.moveTargets(channelID: "alpha").map(\.id).contains("fav"),
                       "Favorites already lists it; the move would change nothing")
        XCTAssertTrue(model.moveTargets(channelID: "charlie").map(\.id).contains("fav"),
                      "and a channel that is not favourite still may be")
    }

    // MARK: - 2. Create / rename / reorder / delete

    func testCreateAdoptsTheIdTheServerAssigned() async {
        let server = FakeCategoryServer(data: data())
        let model = await loaded(server)

        let created = await model.createCategory(named: "  Team Leads  ")
        XCTAssertTrue(created)
        XCTAssertEqual(server.creates, 1)
        XCTAssertEqual(server.storedCategories.last?.displayName, "Team Leads",
                       "the name is trimmed and sent")
        XCTAssertEqual(server.storedCategories.last?.kind, .custom)
        XCTAssertEqual(server.storedCategories.last?.channelIds, [])

        // The server ignored the id in the request; the sidebar must draw the category the server
        // stored, not the placeholder it optimistically inserted.
        let serverID = server.storedCategories.last!.id
        XCTAssertTrue(serverID.hasPrefix("srv-"), "the fake assigned its own id")
        XCTAssertNotNil(model.groups.first { $0.id == serverID },
                        "the drawn sidebar has the server's category")
        XCTAssertTrue(model.groups.contains { $0.kind == .custom && $0.displayName == "Team Leads" })
    }

    func testACreatedCategoryIsDrawnEmptyAndSurvivesARelaunch() async {
        let server = FakeCategoryServer(data: data())
        let model = await loaded(server)
        _ = await model.createCategory(named: "Later")

        let id = server.storedCategories.last!.id
        let drawn = model.groups.first { $0.id == id }
        XCTAssertNotNil(drawn, "an empty category is still a group")
        XCTAssertTrue(drawn?.entries.isEmpty ?? false, "with no rows")

        // A relaunch: a new model, the server's stored layout, nothing in memory.
        let relaunched = await loaded(server)
        XCTAssertEqual(relaunched.groups.first { $0.id == id }?.displayName, "Later",
                       "the empty category is in the layout, not only in the first model's memory")
        XCTAssertEqual(server.storedOrder, ["fav", id, "chan", "dm", "proj"],
                       "and the order array names it, right after Favorites")
    }

    func testABlankNameIsRefusedWithoutARequest() async {
        let server = FakeCategoryServer(data: data())
        let model = await loaded(server)
        let created = await model.createCategory(named: "   ")
        XCTAssertFalse(created)
        XCTAssertEqual(server.creates, 0)
    }

    func testRenamePersistsTheNewName() async {
        let server = FakeCategoryServer(data: data())
        let model = await loaded(server)

        let renamed = await model.renameCategory(id: "proj", to: "Client Work")
        XCTAssertTrue(renamed)
        XCTAssertEqual(stored(server, "proj")?.displayName, "Client Work")
        XCTAssertEqual(model.groups.first { $0.id == "proj" }?.displayName, "Client Work")

        let relaunched = await loaded(server)
        XCTAssertEqual(relaunched.groups.first { $0.id == "proj" }?.displayName, "Client Work")
    }

    func testTheDefaultCategoriesCannotBeRenamedOrDeleted() async {
        let server = FakeCategoryServer(data: data())
        let model = await loaded(server)

        for id in ["fav", "chan", "dm"] {
            XCTAssertFalse(model.canEditCategory(id), "\(id) is the server's default")
            let renamed = await model.renameCategory(id: id, to: "Mine")
            let deleted = await model.deleteCategory(id: id)
            XCTAssertFalse(renamed)
            XCTAssertFalse(deleted)
        }
        XCTAssertEqual(server.saves, 0)
        XCTAssertEqual(server.deletes, 0)
    }

    func testReorderWritesTheOrderRouteAndNotTheArray() async {
        let server = FakeCategoryServer(data: data())
        let model = await loaded(server)

        let moved = await model.moveCategory(id: "proj", by: -1)
        XCTAssertTrue(moved)
        XCTAssertEqual(server.orderWrites, 1)
        XCTAssertEqual(server.saves, 0, "the whole-array PUT keeps each sort_order — it cannot reorder")
        XCTAssertEqual(server.storedOrder, ["fav", "chan", "proj", "dm"])
        XCTAssertEqual(model.groups.map(\.id), ["chan", "proj", "dm"],
                       "the drawn order follows, and Favorites stays hidden while empty")

        // Requirement 4: the order lives in the payload, so a **relaunch** draws the same order — a
        // reorder kept only in this model's memory would flip back on the next launch or on another
        // device.
        let relaunched = await loaded(server)
        XCTAssertEqual(relaunched.groups.map(\.id), ["chan", "proj", "dm"],
                       "the reorder is the server's, not this model's memory")
    }

    /// Requirement 4, the half that is server state rather than a local flag: `collapsed` is a field of
    /// the category record, so a fold one launch made is closed on the next one — and on another device
    /// reading the same payload.
    func testCollapseStatePersistsAcrossARelaunch() async {
        let server = FakeCategoryServer(data: data())
        let model = await loaded(server)
        XCTAssertFalse(model.isCollapsed(categoryID: "proj"))

        await model.setCollapsed(true, categoryID: "proj")
        XCTAssertTrue(model.isCollapsed(categoryID: "proj"), "the fold is drawn at once")
        XCTAssertEqual(stored(server, "proj")?.collapsed, true,
                       "and the write carried it: `collapsed` is part of the categories payload")
        XCTAssertEqual(server.saves, 1)

        let relaunched = await loaded(server)
        XCTAssertTrue(relaunched.isCollapsed(categoryID: "proj"),
                      "a launch reads the fold from the server, not from a local flag")
        XCTAssertEqual(relaunched.groups.first { $0.id == "proj" }?.entries.map(\.id), ["charlie"],
                       "and a collapsed category still owns its rows — folding is not emptying")

        // Expanding is the same write in the other direction.
        await relaunched.setCollapsed(false, categoryID: "proj")
        XCTAssertEqual(stored(server, "proj")?.collapsed, false)
        let again = await loaded(server)
        XCTAssertFalse(again.isCollapsed(categoryID: "proj"),
                       "the expand persisted too; it was not a second launch's default")
    }

    func testReorderAtTheEdgeChangesNothing() async {
        let server = FakeCategoryServer(data: data())
        let model = await loaded(server)
        let up = await model.moveCategory(id: "fav", by: -1)
        let down = await model.moveCategory(id: "proj", by: 1)
        XCTAssertFalse(up)
        XCTAssertFalse(down)
        XCTAssertEqual(server.orderWrites, 0)
        XCTAssertEqual(model.groups.map(\.id), ["chan", "dm", "proj"])
    }

    // MARK: - 3. Delete returns the channels to their default category

    func testDeleteMovesTheChannelsBackToTheirDefaultsAndDeletesNone() async {
        var data = data()
        // `dm1` is claimed by the custom category alone (the sidebar draws a channel once, in the
        // first category that claims it), so the delete is the only thing that can put it back.
        data.categories[2].channelIds = []
        data.categories[3].channelIds = ["charlie", "dm1"]
        let server = FakeCategoryServer(data: data)
        let model = await loaded(server)
        XCTAssertEqual(model.groups.first { $0.id == "proj" }?.entries.map(\.id), ["charlie", "dm1"])

        let deleted = await model.deleteCategory(id: "proj")
        XCTAssertTrue(deleted)
        XCTAssertEqual(server.deletes, 1)
        XCTAssertNil(stored(server, "proj"), "the category is gone from the server's layout")
        XCTAssertEqual(stored(server, "chan")?.channelIds, ["alpha", "bravo", "charlie"],
                       "a public channel goes back to Channels")
        XCTAssertEqual(stored(server, "dm")?.channelIds, ["dm1"],
                       "a direct message goes back to Direct Messages")
        XCTAssertEqual(server.storedChannels.map(\.id), ["alpha", "bravo", "charlie", "dm1"],
                       "deleting a category deletes no channel")

        let relaunched = await loaded(server)
        XCTAssertEqual(relaunched.groups.first { $0.id == "chan" }?.entries.map(\.id),
                       ["alpha", "bravo", "charlie"])
        XCTAssertEqual(relaunched.groups.first { $0.id == "dm" }?.entries.map(\.id), ["dm1"])
    }

    /// The optimistic half: before the DELETE answers, the channels are already drawn back in their
    /// defaults, so the reader never sees a channel disappear.
    func testDeleteDrawsTheChannelsBackBeforeTheServerAnswers() async {
        var data = data()
        data.categories[3].channelIds = ["charlie"]
        let server = FakeCategoryServer(data: data)
        let model = await loaded(server)
        server.holdDeletes = true

        let deletion = Task { await model.deleteCategory(id: "proj") }
        while server.deletes == 0 { await Task.yield() }
        XCTAssertEqual(model.groups.first { $0.id == "chan" }?.entries.map(\.id),
                       ["alpha", "bravo", "charlie"])
        XCTAssertNil(model.groups.first { $0.id == "proj" })
        server.releaseDeletes()
        _ = await deletion.value
    }

    // MARK: - 4. An empty category is a category

    func testAnEmptyCustomCategoryIsDrawn() async {
        var data = data()
        data.categories[3].channelIds = []
        let server = FakeCategoryServer(data: data)
        let model = await loaded(server)
        let group = model.groups.first { $0.id == "proj" }
        XCTAssertNotNil(group, "a custom category with nothing in it is still drawn")
        XCTAssertEqual(group?.entries, [])
        XCTAssertEqual(group?.displayName, "Projects")
    }

    func testAnEmptyDefaultCategoryIsNotDrawn() async {
        var data = data()
        data.categories[1].channelIds = []
        // alpha and bravo must be out of the channel list too, or the derivation would draw them as
        // unclaimed rows under `Channels` (the fallback that keeps a stale layout usable).
        data.channels = [channel("charlie"), channel("dm1", type: "D")]
        data.members = [member("charlie"), member("dm1")]
        let server = FakeCategoryServer(data: data)
        let model = await loaded(server)
        XCTAssertFalse(model.groups.map(\.id).contains("chan"),
                       "the two server defaults stay hidden while they have nothing to show")
    }

    // MARK: - 5. One writer, and a failure that says so

    func testTwoMovesFiredTogetherBothLand() async {
        let server = FakeCategoryServer(data: data())
        let model = await loaded(server)
        server.holdSaves = true

        let first = Task { await model.move(channelID: "alpha", toCategoryID: "proj") }
        while server.saves == 0 { await Task.yield() }
        let second = Task { await model.move(channelID: "bravo", toCategoryID: "proj") }
        server.releaseSaves()
        let results = await (first.value, second.value)

        XCTAssertEqual(results.0, true)
        XCTAssertEqual(results.1, true)
        XCTAssertEqual(stored(server, "proj")?.channelIds, ["charlie", "alpha", "bravo"],
                       "the second write was built on the first one's answer, not on the layout "
                       + "that existed when it was fired — neither move clobbered the other")
        XCTAssertEqual(stored(server, "chan")?.channelIds, [])
        XCTAssertEqual(server.saves, 2)
    }

    /// Requirement 6's hard case — the one a lock-less writer fails.
    ///
    /// The first move is **refused** by the server; the second is fired while the first is still in
    /// flight. The one writer finishes the first write's turn (restore the arrangement, re-read the
    /// server) before it composes the second `PUT`, so the refused change cannot be in it. Without the
    /// lock the second payload is built from the rejected write's **optimistic** array and quietly
    /// commits the very move the reader was told had failed: the stale copy wins over the answer.
    ///
    /// The payloads the fake received are the assertion: `payloads[1]` is the queued write's body.
    func testAQueuedMoveIsBuiltOnTheWritersAnswerNotOnAStaleCopy() async {
        let server = FakeCategoryServer(data: data())
        let model = await loaded(server)
        server.saveError = RefusedWrite()
        server.failSaveOnAttempt = 1        // the first write is refused; the queued one is accepted
        server.holdSaves = true

        let first = Task { await model.move(channelID: "alpha", toCategoryID: "proj") }
        while server.saves == 0 { await Task.yield() }
        let second = Task { await model.move(channelID: "bravo", toCategoryID: "proj") }
        // Give the queued move every chance to reach the writer — the lock, or the mutant's request —
        // before the first answer is let go. On the main actor one yield is enough for a task to run to
        // its first suspension; the loop is slack, not a delay.
        for _ in 0..<20 { await Task.yield() }
        server.releaseSaves()
        let results = await (first.value, second.value)

        XCTAssertFalse(results.0, "the first move was refused")
        XCTAssertTrue(results.1, "the queued move is accepted on its own turn")
        XCTAssertEqual(server.payloads.count, 2)
        let queued = server.payloads[1]
        XCTAssertEqual(queued.first { $0.id == "proj" }?.channelIds, ["charlie", "bravo"],
                       "the queued write is built on the writer's answer — "
                       + "the refused move is not in its payload")
        XCTAssertEqual(queued.first { $0.id == "chan" }?.channelIds, ["alpha"],
                       "and the refused move's channel is back where it started — only the queued "
                       + "move's channel has left `channels`")
        XCTAssertEqual(stored(server, "proj")?.channelIds, ["charlie", "bravo"],
                       "the server holds exactly the queued move, not the refused one as well")
        XCTAssertEqual(model.groups.first { $0.id == "proj" }?.entries.map(\.id), ["charlie", "bravo"])
    }

    func testAFailedMoveRestoresTheArrangementAndSaysWhy() async {
        let server = FakeCategoryServer(data: data())
        let model = await loaded(server)
        server.saveError = RefusedWrite()

        let moved = await model.move(channelID: "alpha", toCategoryID: "proj")
        XCTAssertFalse(moved)
        XCTAssertEqual(model.groups.first { $0.id == "chan" }?.entries.map(\.id), ["alpha", "bravo"],
                       "the row is back where it was")
        XCTAssertEqual(model.groups.first { $0.id == "proj" }?.entries.map(\.id), ["charlie"])
        XCTAssertNotNil(model.actionError, "a refused write is never silent")
        XCTAssertEqual(model.actionError, "Could not move that channel.")
        XCTAssertGreaterThanOrEqual(server.reads, 1,
                                    "a refused write re-reads the layout: the server is the truth")
    }

    /// A refused write is exactly when another device may have edited the layout: the re-read wins.
    func testAFailedWriteAdoptsAConcurrentEditFromTheServer() async {
        let server = FakeCategoryServer(data: data())
        let model = await loaded(server)
        server.saveError = RefusedWrite()
        // Somebody else renamed the category while this client's write was in flight.
        server.storedCategories[3].displayName = "Client Work (renamed on the web)"

        let refused = await model.move(channelID: "alpha", toCategoryID: "proj")
        XCTAssertFalse(refused)
        XCTAssertEqual(model.groups.first { $0.id == "proj" }?.displayName,
                       "Client Work (renamed on the web)",
                       "the re-read's layout is what stays on screen")
        XCTAssertEqual(model.groups.first { $0.id == "chan" }?.entries.map(\.id), ["alpha", "bravo"])
    }

    func testAFailedDeleteRestoresTheCategory() async {
        let server = FakeCategoryServer(data: data())
        let model = await loaded(server)
        server.deleteError = RefusedWrite()

        let refused = await model.deleteCategory(id: "proj")
        XCTAssertFalse(refused)
        XCTAssertEqual(model.groups.first { $0.id == "proj" }?.entries.map(\.id), ["charlie"])
        XCTAssertEqual(stored(server, "proj")?.channelIds, ["charlie"])
        XCTAssertEqual(model.actionError, "Could not delete that category.")
    }

    func testAFailedReorderRestoresTheOrder() async {
        let server = FakeCategoryServer(data: data())
        let model = await loaded(server)
        server.orderError = RefusedWrite()

        let refused = await model.moveCategory(id: "proj", by: -1)
        XCTAssertFalse(refused)
        XCTAssertEqual(model.groups.map(\.id), ["chan", "dm", "proj"])
        XCTAssertEqual(server.storedOrder, ["fav", "chan", "dm", "proj"])
        XCTAssertEqual(model.actionError, "Could not reorder that category.")
    }

    // MARK: - 6. The pieces that make a category a category

    func testANewCategoryIDLooksLikeTheServersAndNeverCollides() {
        let ids = (0..<200).map { _ in ChannelSidebarDerivation.newCategoryID() }
        XCTAssertEqual(Set(ids).count, ids.count)
        for id in ids {
            XCTAssertEqual(id.count, 26)
            XCTAssertTrue(id.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) },
                          "Mattermost ids are 26 lowercase alphanumerics: \(id)")
        }
    }

    func testNewCategorySortsAfterFavorites() {
        let local = ChannelSidebarDerivation.customCategory(displayName: "New",
                                                            userID: "me",
                                                            teamID: "team1",
                                                            existing: [])
        let inserted = ChannelSidebarDerivation.insertingNewCategory(local,
                                                                    into: data().categories,
                                                                    order: data().categoryOrder)
        XCTAssertEqual(inserted.order, ["fav", local.id, "chan", "dm", "proj"],
                       "the server puts a new category at sort_order 10 — right after Favorites")
    }
}

/// A write the server refused. Deliberately **not** a `LocalizedError`, so the sentence a reader sees is
/// the model's own ("Could not move that channel.") — which is the thing under test.
private struct RefusedWrite: Error {}

// MARK: - The fake server

/// A fake that keeps the **server's** state, not the client's: what a write stores is what the next
/// read returns, which is what makes "a relaunch draws it" and "the re-read wins" real assertions.
@MainActor
final class FakeCategoryServer: ChannelSidebarServing {
    var storedCategories: [MMSidebarCategory]
    var storedOrder: [String]
    var storedChannels: [MMChannel]
    var storedMembers: [MMChannelMember]

    var saveError: Error?
    /// Refuse only the numbered save (1-based). `nil` refuses every save, which is what a plain
    /// failure test wants; a pair of writes fired together sets `1` so the **queued** write is accepted
    /// and the payload it composed can be inspected.
    var failSaveOnAttempt: Int?
    var createError: Error?
    var deleteError: Error?
    var orderError: Error?
    var readError: Error?

    /// Hold a write open, so a test can look at the screen before the answer arrives.
    ///
    /// Releasing resumes **every** waiter: a second write queued behind a held one must land in the
    /// same release, or a two-write test would park forever.
    var holdSaves = false {
        didSet {
            guard !holdSaves else { return }
            while !saveGates.isEmpty { saveGates.removeFirst().resume() }
        }
    }
    var holdDeletes = false {
        didSet {
            guard !holdDeletes else { return }
            while !deleteGates.isEmpty { deleteGates.removeFirst().resume() }
        }
    }
    private var saveGates: [CheckedContinuation<Void, Never>] = []
    private var deleteGates: [CheckedContinuation<Void, Never>] = []

    private(set) var saves = 0
    /// Every array a write tried to send, in order. `payloads[n]` is the body of write `n+1` — the
    /// thing "one writer" is actually about, because a payload built from a stale copy is invisible on
    /// screen (the optimistic array looks the same) and only shows up here.
    private(set) var payloads: [[MMSidebarCategory]] = []
    private(set) var creates = 0
    private(set) var deletes = 0
    private(set) var orderWrites = 0
    private(set) var reads = 0

    init(data: ChannelSidebarData) {
        storedCategories = data.categories
        storedOrder = data.categoryOrder
        storedChannels = data.channels
        storedMembers = data.members
    }

    func releaseSaves() { holdSaves = false }
    func releaseDeletes() { holdDeletes = false }

    // MARK: ChannelSidebarServing

    func load(teamID: String) async throws -> ChannelSidebarData {
        var data = ChannelSidebarData(channels: storedChannels, members: storedMembers)
        data.categories = storedCategories
        data.categoryOrder = storedOrder
        return data
    }

    func refresh(teamID: String) async throws -> ChannelSidebarRefresh {
        ChannelSidebarRefresh(channels: storedChannels, members: storedMembers)
    }

    func categories(teamID: String) async throws -> MMSidebarCategories {
        reads += 1
        if let readError { throw readError }
        return MMSidebarCategories(categories: storedCategories, order: storedOrder)
    }

    func save(categories: [MMSidebarCategory], teamID: String) async throws -> [MMSidebarCategory] {
        saves += 1
        payloads.append(categories)
        if holdSaves {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                saveGates.append(continuation)
            }
        }
        if let saveError, failSaveOnAttempt.map({ $0 == saves }) ?? true { throw saveError }
        storedCategories = categories
        return categories
    }

    /// The pinned server generates the id; the request's `id` is ignored (measured).
    func createCategory(_ category: MMSidebarCategory, teamID: String) async throws -> MMSidebarCategory {
        creates += 1
        if let createError { throw createError }
        var created = category
        created.id = "srv-" + String(format: "%022d", creates)
        created.sortOrder = 10
        storedCategories.append(created)
        if let favorites = storedOrder.firstIndex(of: "fav") {
            storedOrder.insert(created.id, at: favorites + 1)
        } else {
            storedOrder.insert(created.id, at: 0)
        }
        return created
    }

    /// Deleting a category moves its channels into the default for their kind — the server's own
    /// behaviour, and the promise the confirmation sentence makes.
    func deleteCategory(categoryID: String, teamID: String) async throws {
        deletes += 1
        if holdDeletes {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                deleteGates.append(continuation)
            }
        }
        if let deleteError { throw deleteError }
        guard let index = storedCategories.firstIndex(where: { $0.id == categoryID }) else { return }
        let doomed = storedCategories.remove(at: index)
        storedOrder.removeAll { $0 == categoryID }
        for channelID in doomed.channelIds {
            let isDirect = storedChannels.first { $0.id == channelID }?.type == "D"
            let targetID = isDirect ? "dm" : "chan"
            guard let target = storedCategories.firstIndex(where: { $0.id == targetID }) else { continue }
            if !storedCategories[target].channelIds.contains(channelID) {
                storedCategories[target].channelIds.append(channelID)
            }
        }
    }

    func saveOrder(_ order: [String], teamID: String) async throws -> [String] {
        orderWrites += 1
        if let orderError { throw orderError }
        storedOrder = order
        for (position, id) in order.enumerated() {
            if let index = storedCategories.firstIndex(where: { $0.id == id }) {
                storedCategories[index].sortOrder = position * 10
            }
        }
        return storedCategories.sorted { $0.sortOrder < $1.sortOrder }.map(\.id)
    }

    func setMuted(_ muted: Bool, channelID: String) async throws {
        if let index = storedMembers.firstIndex(where: { $0.channelId == channelID }) {
            storedMembers[index].notifyProps = .object(["mark_unread": .string(muted ? "mention" : "all")])
        }
    }
}
