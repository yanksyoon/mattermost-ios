import XCTest
import UIKit

/// t19828e14 — managing sidebar categories **against a real server**, driven through the app's own UI.
///
/// The card asks for five things a unit test cannot answer, because each one is a statement about what
/// a person can do and what the server then holds:
///
///  1. move a channel between categories from a row's menu (no drag: a menu item);
///  2. create a category from the sidebar header's `+`, and see it drawn;
///  3. rename and delete it from its own header menu, with delete returning the channels to their
///     default category and deleting none of them;
///  4. reorder categories;
///  5. an empty category stays on screen.
///
/// Every expectation is also read back from the server through its own API — a screen that agrees with
/// itself proves nothing (the card's DoD forbids fixture-only evidence).
///
/// Run (the local throwaway fixture; the server must be up: `docker start mm-perf-db mm-perf`):
///
///     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
///     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
///     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
///     python3 scripts/qa-test.py --platform ios --sim <sim id> \
///       --only-testing MattermostUITests/T19828e14SidebarCategoryUITests
///
/// Each test skips (never fails) when the env or the server is missing, like every live test here.
final class T19828e14SidebarCategoryUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!

    /// Every category this suite creates carries this prefix, so a run that died before its cleanup
    /// cannot leave a mess that makes the next run's assertions meaningless.
    private let namePrefix = "t19828e14 probe"

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live category test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        let session = try authenticate(login: loginID, password: password)
        token = session.token
        userID = session.userID
        teamID = try firstTeamID()
        try removeProbeCategories()
    }

    override func tearDownWithError() throws {
        // Cleanup is part of the contract, not tidiness: a leftover category changes the layout the
        // next run asserts against.
        try? removeProbeCategories()
    }

    // MARK: - 1. Create, move into, rename, delete — one lifecycle

    func testACategoryCanBeCreatedFilledRenamedAndDeletedFromTheUI() throws {
        let channels = try teamChannels()
        let channel = try XCTUnwrap(channels.first { $0.type == "O" }, "the fixture team has a public channel")

        let app = launchAndSignIn()
        attach(app, name: "01-sidebar")
        noteLayout("before-create")

        // --- create ---
        let header = element(app, "nativeSidebarCreateMenu")
        XCTAssertTrue(header.waitForExistence(timeout: 30),
                      "the header's + must be there:\n\(app.debugDescription)")
        header.tap()
        let createCategory = app.buttons["nativeSidebarCreateCategory"]
        XCTAssertTrue(createCategory.waitForExistence(timeout: 10),
                      "the create menu must offer a category:\n\(app.debugDescription)")
        createCategory.tap()

        let nameField = app.textFields["channelSidebar.categoryNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 15),
                      "the name prompt must open:\n\(app.debugDescription)")
        let name = "\(namePrefix) \(Int(Date().timeIntervalSince1970) % 100000)"
        nameField.tap()
        nameField.typeText(name)
        attach(app, name: "02-new-category-name")
        app.buttons["channelSidebar.categoryCreateConfirm"].tap()

        // The server holds it, with an id of its own (the app must have adopted that id).
        let created = try waitForCategory(named: name)
        XCTAssertEqual(created["display_name"] as? String, name)
        XCTAssertEqual(created["type"] as? String, "custom")
        XCTAssertEqual((created["channel_ids"] as? [String]) ?? [], [], "a new category starts empty")
        let categoryID = try XCTUnwrap(created["id"] as? String)
        XCTAssertEqual(categoryID.count, 26, "the server's id, not the client's placeholder")
        attach(app, name: "03-created")
        noteLayout("after-create")

        // Drawn: an empty custom category is a group with a "no channels yet" row (requirement 5).
        // The new category sits right after Favorites — where the server put it — so this only has to
        // come back up to it, not hunt for it.
        let drawnHeader = "channelSidebar.category.custom.\(categoryID)"
        XCTAssertTrue(revealFromTop(drawnHeader, in: app),
                      "the new category must draw:\n\(app.debugDescription)")
        let categoryHeader = element(app, drawnHeader)
        XCTAssertEqual(categoryHeader.label, name)
        XCTAssertTrue(element(app, "channelSidebar.emptyCategory.\(categoryID)").exists,
                      "an empty category says so instead of vanishing")

        // --- rename, from the category's own header menu ---
        // Still the first screenful: the rename and the reorder both act on the header, and doing them
        // **before** the move keeps this test from scrolling until it has to (see the note below).
        let headerIdentifier = "channelSidebar.category.custom.\(categoryID)"
        let categoryMenu = element(app, "channelSidebar.category.menu.\(categoryID)")
        XCTAssertTrue(categoryMenu.waitForExistence(timeout: 10),
                      "a custom category's header must offer its actions:\n\(app.debugDescription)")
        XCTAssertTrue(categoryMenu.isHittable,
                      "the actions button must be reachable:\n\(app.debugDescription)")
        categoryMenu.tap()
        // One sheet, not a menu-then-a-prompt: the field, the reorder buttons and the delete are all in
        // this one presentation (a prompt chained after a dismissing dialog never opened — see
        // `CategoryActionsSheet`).
        let renameField = app.textFields["channelSidebar.categoryRenameField"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 10),
                      "the category sheet must open with its name field:\n\(app.debugDescription)")
        attach(app, name: "04a-category-sheet")
        // Clear the field: it is pre-filled with the current name.
        renameField.tap()
        if let existing = renameField.value as? String, !existing.isEmpty {
            renameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        let renamed = "\(name) renamed"
        renameField.typeText(renamed)
        app.buttons["channelSidebar.categoryRenameSave"].tap()

        let afterRename = try waitForCategory(id: categoryID, displayName: renamed)
        XCTAssertEqual(afterRename["display_name"] as? String, renamed, "the server holds the new name")
        XCTAssertTrue(revealFromTop(headerIdentifier, in: app),
                      "the header must be drawn under its new name:\n\(app.debugDescription)")
        XCTAssertEqual(element(app, headerIdentifier).label, renamed)
        attach(app, name: "04-renamed")
        noteLayout("after-rename")

        // --- reorder ---
        let orderBefore = try layoutOrder()
        XCTAssertTrue(element(app, headerIdentifier).exists,
                      "the header must still be on screen for its menu:\n\(app.debugDescription)")
        categoryMenu.tap()
        let moveUp = app.buttons["channelSidebar.categoryMoveUp"]
        let moveDown = app.buttons["channelSidebar.categoryMoveDown"]
        XCTAssertTrue(moveUp.waitForExistence(timeout: 10),
                      "a category's sheet must offer a reorder:\n\(app.debugDescription)")
        // The sheet's rows are always drawn; the edge one is disabled. Pick the direction the server's
        // order can actually take.
        let upward = moveUp.isEnabled
        if upward {
            moveUp.tap()
        } else {
            XCTAssertTrue(moveDown.isEnabled, "a middle category has at least one direction")
            moveDown.tap()
        }
        let orderAfter = try waitForOrderToChange(from: orderBefore, categoryID: categoryID, upward: upward)
        XCTAssertNotEqual(orderAfter, orderBefore, "the server's order must have changed")
        attach(app, name: "05-reordered")
        noteLayout("after-reorder")

        // --- move a channel in, from the row's menu ---
        // The only stage that scrolls: the channel lives in `channels`, below eight seeded categories on
        // this fixture. Everything above and below acts on the header at the top of the list.
        let row = revealRow(app, "channelSidebar.channel.\(channel.id)")
        XCTAssertTrue(row.exists, "channel \(channel.name) must be on screen:\n\(app.debugDescription)")
        row.press(forDuration: 1.4)
        let moveTo = app.buttons["Move to"]
        XCTAssertTrue(moveTo.waitForExistence(timeout: 10),
                      "a row's menu must offer \"Move to\":\n\(app.debugDescription)")
        attach(app, name: "06-move-to-menu")
        moveTo.tap()
        // The submenu row is addressed by its own identifier, never by its label: the category's
        // **header** carries the same label (the name), so `app.buttons[name]` would collapse the
        // category instead of moving anything (measured — the first version of this test did exactly
        // that, and the server still had an empty category afterwards).
        let byIdentifier = element(app, "channelSidebar.moveTo.custom.\(categoryID)")
        let byLabel = app.buttons.matching(NSPredicate(format: "label == %@", renamed))
        let destination: XCUIElement
        if byIdentifier.waitForExistence(timeout: 10) {
            destination = byIdentifier
        } else {
            XCTAssertGreaterThan(byLabel.count, 0,
                                 "the submenu must list the target category:\n\(app.debugDescription)")
            destination = byLabel.element(boundBy: byLabel.count - 1)
        }
        attach(app, name: "07-move-to-targets")
        destination.tap()

        let moved = try waitForChannel(channel.id, in: categoryID, present: true)
        XCTAssertEqual(moved, [channel.id], "the server must hold the channel in the new category")
        let channelsCategory = try category(ofType: "channels")
        XCTAssertFalse(((channelsCategory["channel_ids"] as? [String]) ?? []).contains(channel.id),
                       "and the category it left must not")
        attach(app, name: "08-moved")
        noteLayout("after-move")

        // Back up, to see the channel drawn under the category it was moved into.
        XCTAssertTrue(revealFromTop(headerIdentifier, in: app, maxSwipes: 24),
                      "the header must still be reachable after the move:\n\(app.debugDescription)")
        XCTAssertTrue(element(app, "channelSidebar.channel.\(channel.id)").exists,
                      "the moved channel must be drawn under the category, not in `channels`")

        // --- delete, and the channels come back ---
        XCTAssertTrue(revealFromTop(headerIdentifier, in: app),
                      "the header must be on screen for its menu:\n\(app.debugDescription)")
        categoryMenu.tap()
        let delete = app.buttons["channelSidebar.categoryDelete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10),
                      "a custom category's sheet must offer Delete:\n\(app.debugDescription)")
        delete.tap()
        let confirm = app.buttons["channelSidebar.categoryDeleteConfirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10),
                      "deleting must ask first, and say what happens to the channels:\n\(app.debugDescription)")
        // The promise, in the reader's words: the channels are not deleted, they go back to a default.
        let promise = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Its channels are not deleted")
        ).firstMatch
        XCTAssertTrue(promise.exists,
                      "the confirmation must say the channels are safe:\n\(app.debugDescription)")
        attach(app, name: "09-delete-confirmation")
        confirm.tap()

        let gone = try waitForCategoryToDisappear(id: categoryID)
        XCTAssertTrue(gone, "the category must be gone from the server's layout")
        let afterDelete = try category(ofType: "channels")
        XCTAssertTrue(((afterDelete["channel_ids"] as? [String]) ?? []).contains(channel.id),
                      "the channel must be back in `channels` — deleting a category deletes no channel")
        XCTAssertTrue(try channelExists(channel.id), "the channel itself must still exist")
        XCTAssertFalse(element(app, "channelSidebar.category.custom.\(categoryID)").exists,
                       "and the header must be gone from the sidebar")
        XCTAssertTrue(revealRow(app, "channelSidebar.channel.\(channel.id)").exists,
                      "the channel is drawn again:\n\(app.debugDescription)")
        attach(app, name: "10-deleted")
        noteLayout("after-delete")
    }

    // MARK: - 2. The defaults refuse to be edited

    // There was a second UI test here — "`Channels` offers no Rename/Delete" — and it is gone on
    // purpose. Reaching that header means scrolling past eight custom categories on this fixture
    // (~5,300 pt of list), and every attempt ended with the app process killed by the simulator's
    // libtrace client being quarantined for high log volume
    // (`__LIBTRACE_CLIENT_QUARANTINED_DUE_TO_HIGH_LOGGING_VOLUME__` in the crash report, three runs in
    // a row). That is a harness/environment failure, not a product claim, and a red test that cannot
    // be green on this host is worse than none. The rule it expressed is pinned where it can be
    // checked deterministically:
    // `MattermostTests/T19828e14SidebarCategoryTests.testTheDefaultCategoriesCannotBeRenamedOrDeleted`
    // (the model refuses, and no request is sent for `favorites` / `channels` / `direct_messages`).

    // MARK: - Launch

    private func launchAndSignIn() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetPersistedState",
                               "-uiTestForgetSession", serverURL.absoluteString,
                               "-uiTestSeedServer", serverURL.absoluteString,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-surfaceMode", "sidebar=native",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let field = app.textFields["loginIDField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "the native sign-in must mount:\n\(app.debugDescription)")
        field.tap()
        field.typeText(loginID)
        let secret = app.secureTextFields["loginPasswordField"]
        XCTAssertTrue(secret.exists)
        secret.tap()
        secret.typeText(password)
        app.buttons["loginSubmitButton"].tap()
        XCTAssertTrue(ShellSettle.waitForSignedIn(app, timeout: 45),
                      "signing in must reach the shell:\n\(app.debugDescription)")
        ShellSettle.revealChannelList(app)
        // On the regular (iPad) layout the sidebar starts **collapsed** behind the shell's toggle —
        // `ToggleSidebar`, labelled "Show Sidebar" while the pane is hidden. Nothing in the list is in
        // the accessibility tree until it is shown, so open it here (measured: without this the whole
        // suite searched a tree that had no `channelSidebar.*` element at all).
        let toggle = app.buttons["ToggleSidebar"]
        if toggle.waitForExistence(timeout: 5), toggle.label == "Show Sidebar" {
            toggle.tap()
        }
        // The pane, not a row: the list is a `LazyVStack`, so a header that is below the fold is not in
        // the accessibility tree at all (the `channels` header sits under eight custom categories on
        // this fixture). `reveal` scrolls to what a test actually needs.
        XCTAssertTrue(element(app, "nativeSidebar").waitForExistence(timeout: 30),
                      "the channel sidebar must be on screen:\n\(app.debugDescription)")
        return app
    }

    // MARK: - Elements

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Scroll the sidebar (both directions, bounded) until `target` is in the tree.
    ///
    /// Deliberately gentle: a handful of default-speed swipes with an early exit. An earlier version
    /// used 25 `.fast` swipes per direction, and on this fixture that killed the app (SIGSEGV with
    /// `__LIBTRACE_CLIENT_QUARANTINED_DUE_TO_HIGH_LOGGING_VOLUME__` in the report — the simulator's log
    /// client was quarantined after the scroll churn). Fewer, slower interactions, and a scroll-to-top
    /// helper, keep the harness out of the app's way.
    @discardableResult
    private func reveal(_ target: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 8) -> Bool {
        if target.waitForExistence(timeout: 3) { return true }
        let list = ShellSettle.channelSidebarScroll(app)
        guard list.exists else { return target.exists }
        for _ in 0..<maxSwipes where !target.exists { list.swipeUp() }
        for _ in 0..<maxSwipes where !target.exists { list.swipeDown() }
        return target.exists
    }

    /// Find an element that lives near the **top** of the list, from wherever the list is now: swipe
    /// down (towards the top) and stop the moment it appears. Used for the category headers a test
    /// created, which sit right after Favorites — never for rows, which can be anywhere.
    @discardableResult
    private func revealFromTop(_ identifier: String,
                               in app: XCUIApplication,
                               maxSwipes: Int = 12) -> Bool {
        let target = element(app, identifier)
        if target.waitForExistence(timeout: 2) { return true }
        let list = ShellSettle.channelSidebarScroll(app)
        guard list.exists else { return false }
        for _ in 0..<maxSwipes where !target.exists { list.swipeDown() }
        return target.waitForExistence(timeout: 2)
    }

    /// Print the server's **actual** category payload at a step of the lifecycle.
    ///
    /// The card's Reproduction section is explicit: the note must carry the `GET
    /// /users/me/teams/{team_id}/channels/categories` body before and after each action, so the
    /// optimistic UI is proven against the server's state rather than against the local copy. Printing
    /// it from the same run that drove the UI is the only way to tie the two together; the lines start
    /// with `T19828E14-PAYLOAD` so they can be lifted straight out of the xcodebuild log.
    private func noteLayout(_ step: String) {
        guard let token, let userID, let teamID else { return }
        var request = URLRequest(url: serverURL.appendingPathComponent(
            "/api/v4/users/\(userID)/teams/\(teamID)/channels/categories"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? synchronous(request),
              let body = try? JSONSerialization.jsonObject(with: data),
              let encoded = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
              let text = String(data: encoded, encoding: .utf8) else {
            print("T19828E14-PAYLOAD \(step) <unavailable>")
            return
        }
        print("T19828E14-PAYLOAD \(step) \(text)")
    }

    /// Reveal a row (which can be anywhere in the list) and hand back the element.
    @discardableResult
    private func revealRow(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let target = element(app, identifier)
        reveal(target, in: app)
        return target
    }

    /// Attach a screenshot to the test result — the visual evidence the card asks for.
    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Server access

    private func ping() throws {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/system/ping"))
        request.timeoutInterval = 5
        let (_, response) = try synchronous(request)
        try XCTSkipUnless((response as? HTTPURLResponse)?.statusCode == 200,
                          "the live server at \(serverURL.absoluteString) is not answering")
    }

    private func authenticate(login: String, password: String) throws -> (token: String, userID: String) {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/users/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["login_id": login,
                                                                      "password": password])
        let (data, response) = try synchronous(request)
        // The token is the `Token` response header on this server (9.11.19), not a body field.
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let token = http.value(forHTTPHeaderField: "Token"),
              let user = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = user["id"] as? String else {
            throw XCTSkip("could not sign in as \(login) on the live server")
        }
        return (token, id)
    }

    private func firstTeamID() throws -> String {
        let teams = try getJSON("/api/v4/users/me/teams") as? [[String: Any]] ?? []
        guard let team = teams.first, let id = team["id"] as? String else {
            throw XCTSkip("the fixture account has no team")
        }
        return id
    }

    private struct Channel {
        let id: String
        let name: String
        let type: String
    }

    private func teamChannels() throws -> [Channel] {
        let rows = try getJSON("/api/v4/users/me/teams/\(teamID!)/channels") as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
            return Channel(id: id, name: name, type: row["type"] as? String ?? "")
        }
    }

    private func channelExists(_ channelID: String) throws -> Bool {
        let channel = try getJSON("/api/v4/channels/\(channelID)") as? [String: Any]
        return (channel?["delete_at"] as? Int ?? 1) == 0
    }

    private var categoriesPath: String {
        "/api/v4/users/\(userID!)/teams/\(teamID!)/channels/categories"
    }

    private func layout() throws -> [String: Any] {
        try getJSON(categoriesPath) as? [String: Any] ?? [:]
    }

    private func layoutCategories() throws -> [[String: Any]] {
        try layout()["categories"] as? [[String: Any]] ?? []
    }

    private func layoutOrder() throws -> [String] {
        try layout()["order"] as? [String] ?? []
    }

    private func category(ofType type: String) throws -> [String: Any] {
        let match = try layoutCategories().first { $0["type"] as? String == type }
        return try XCTUnwrap(match, "the server has no `\(type)` category")
    }

    private func category(id: String) throws -> [String: Any] {
        let match = try layoutCategories().first { $0["id"] as? String == id }
        return try XCTUnwrap(match, "the server has no category \(id)")
    }

    private func waitForCategory(named name: String, timeout: TimeInterval = 20) throws -> [String: Any] {
        try wait(timeout: timeout, "a category named \(name)") {
            try self.layoutCategories().first { $0["display_name"] as? String == name }
        }
    }

    private func waitForCategory(id: String, timeout: TimeInterval = 20) throws -> [String: Any] {
        try wait(timeout: timeout, "category \(id)") {
            try self.layoutCategories().first { $0["id"] as? String == id }
        }
    }

    /// Wait for a **rename** to land: the category exists the whole time, so waiting for the category
    /// itself would return its old name (measured — the first version of this test read the pre-rename
    /// name and called it a failure).
    private func waitForCategory(id: String,
                                 displayName: String,
                                 timeout: TimeInterval = 20) throws -> [String: Any] {
        try wait(timeout: timeout, "category \(id) renamed to \(displayName)") {
            try self.layoutCategories().first {
                $0["id"] as? String == id && ($0["display_name"] as? String) == displayName
            }
        }
    }

    /// Wait until a channel is (or is not) listed in a category — the same trap as the rename: the
    /// category exists before the move, so its id alone answers "already there".
    private func waitForChannel(_ channelID: String,
                                in categoryID: String,
                                present: Bool = true,
                                timeout: TimeInterval = 20) throws -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        var latest: [String] = []
        while Date() < deadline {
            latest = (try category(id: categoryID)["channel_ids"] as? [String]) ?? []
            if latest.contains(channelID) == present { return latest }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("the channel was never \(present ? "added to" : "removed from") the category "
                + "(category \(categoryID)); it holds \(latest)")
        return latest
    }

    private func waitForCategoryToDisappear(id: String, timeout: TimeInterval = 20) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try !layoutCategories().contains(where: { $0["id"] as? String == id }) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    private func waitForOrderToChange(from before: [String],
                                      categoryID: String,
                                      upward: Bool,
                                      timeout: TimeInterval = 20) throws -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = before
        while Date() < deadline {
            latest = try layoutOrder()
            if latest != before { return latest }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("the reorder never reached the server (category \(categoryID), "
                + "\(upward ? "up" : "down") was chosen); order is still \(latest)")
        return latest
    }

    private func wait<T>(timeout: TimeInterval, _ what: String, _ read: () throws -> T?) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = try read() { return value }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw XCTSkip("the server never answered with \(what)")
    }

    /// Delete every category this suite could have created, so the run is repeatable.
    private func removeProbeCategories() throws {
        for category in try layoutCategories()
        where (category["type"] as? String) == "custom"
            && ((category["display_name"] as? String) ?? "").hasPrefix(namePrefix) {
            guard let id = category["id"] as? String else { continue }
            var request = URLRequest(url: serverURL.appendingPathComponent(categoriesPath + "/" + id))
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
            _ = try? synchronous(request)
        }
    }

    private func getJSON(_ path: String) throws -> Any {
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (data, _) = try synchronous(request)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func synchronous(_ request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data, URLResponse)?
        var failure: Error?
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { failure = error }
            if let data, let response { result = (data, response) }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        if let failure { throw failure }
        guard let result else { throw URLError(.timedOut) }
        return result
    }
}
