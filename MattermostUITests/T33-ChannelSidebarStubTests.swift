import XCTest

/// T33 — the channel sidebar against the **stub** server (`build/uitest-server/mm_stub.py`).
///
/// Why both this and `T33ChannelSidebarUITests` (which is live): the live suite proves the client
/// agrees with a real Mattermost about unread/mention numbers, category writes and the mute index.
/// This suite proves the things a real server cannot conveniently be made to do on demand —
/// * **the flag gate**, both ways: `sidebar=native` mounts the list, `sidebar=web` leaves T30's
///   placeholder exactly as shipped and exposes none of T33's identifiers;
/// * a deterministic **manual order that is neither alphabetical nor by creation** (`Stub Beta`
///   above `Stub Alpha`), so "follows the server's `channel_ids`" is observable without mutating a
///   fixture before every run;
/// * the **error state** (`--channels-fail`) with its retry.
///
/// The stubs this file needs (started separately, like every stub-backed test in this suite):
///
///     cd build/uitest-server
///     python3 mm_stub.py --port 8120                     # one team + the T33 channel fixtures
///     python3 mm_stub.py --port 8121 --channels-fail     # the list's failure state
///
/// A test skips (rather than fails) when its stub is not listening.
final class T33ChannelSidebarStubTests: XCTestCase {

    private static let stubSidebar = "http://127.0.0.1:8120"
    private static let stubFailingChannels = "http://127.0.0.1:8121"

    private static let login = "stub-user"
    private static let password = "stub-password"

    // The fixture's ids, from `stub_channels()` / `stub_categories()` in the stub.
    private static let alpha = "stubchanalpha00000000000001"
    private static let beta = "stubchanbeta000000000000002"
    private static let muted = "stubchanmuted000000000000003"
    private static let dm = "stubchandm00000000000000004"
    /// The stub DM's channel *name* is `id__<a>__<b>`; that is what the location carries, so it is
    /// what the channel pane's header shows for a DM (the person's name is a T34 concern).
    private static let dmName = "id__stubuser__otheruser"

    func testTheListDrawsTheStubsCategoriesInTheServersOrder() throws {
        try start(Self.stubSidebar, needs: "the sidebar fixture")
        let app = launch(Self.stubSidebar, sidebarNative: true)
        signIn(app, on: Self.stubSidebar)

        XCTAssertTrue(element(app, "channelSidebar.category.channels").waitForExistence(timeout: 40),
                      "the server's `channels` category must draw:\n\(app.debugDescription)")
        XCTAssertTrue(element(app, "channelSidebar.category.direct_messages").exists,
                      "the DM category must draw when it has a channel")

        let betaRow = element(app, "channelSidebar.channel.\(Self.beta)")
        let alphaRow = element(app, "channelSidebar.channel.\(Self.alpha)")
        XCTAssertTrue(betaRow.waitForExistence(timeout: 20), "Stub Beta must be drawn")
        XCTAssertTrue(alphaRow.waitForExistence(timeout: 20), "Stub Alpha must be drawn")
        XCTAssertEqual(betaRow.label, "Stub Beta")
        XCTAssertEqual(alphaRow.label, "Stub Alpha")
        XCTAssertLessThan(betaRow.frame.minY, alphaRow.frame.minY,
                          "the fixture's `channel_ids` order is beta, alpha — alphabetical would be the "
                          + "other way round, so this is the server's order being followed")

        // Stub Alpha: 3 unread messages and 2 mentions → mentions win.
        XCTAssertEqual(alphaRow.value as? String, "2 mentions")

        // The muted channel: 4 unread messages and 1 mention. The message count must not show, the
        // mention must.
        let mutedRow = element(app, "channelSidebar.channel.\(Self.muted)")
        XCTAssertTrue(mutedRow.exists, "a muted channel is still listed")
        let mutedValue = mutedRow.value as? String ?? ""
        XCTAssertTrue(mutedValue.contains("Muted"), "got '\(mutedValue)'")
        XCTAssertTrue(mutedValue.contains("1 mention"),
                      "a muted channel's mention still badges, got '\(mutedValue)'")
        XCTAssertFalse(mutedValue.contains("Unread"),
                       "a muted channel's message count must not emphasise, got '\(mutedValue)'")

        // Stub Beta: read (msg_count == total) → nothing to say.
        XCTAssertEqual(betaRow.value as? String ?? "", "")

        // The aggregate is desktop-exact (T33-AV F2): alpha 3 unread + 2 mentions, the muted channel's
        // 4 unread **and** its 1 mention dropped — the row still badges the mention, the footer does not
        // count it (`getTeamsUnreadStatuses`: "if channel is muted, we skip its count").
        let totals = element(app, "channelSidebar.totals")
        XCTAssertTrue(totals.waitForExistence(timeout: 10))
        XCTAssertEqual(totals.label, "2 mentions, 3 unread messages")
        attachShot(app, named: "t33-stub-01-categories-and-rows")
    }

    func testTheQuickSwitcherFindsADirectMessageByTheOtherPersonsName() throws {
        try start(Self.stubSidebar, needs: "the sidebar fixture")
        let app = launch(Self.stubSidebar, sidebarNative: true)
        signIn(app, on: Self.stubSidebar)

        let opener = element(app, "channelSidebar.quickSwitcher")
        XCTAssertTrue(opener.waitForExistence(timeout: 40))
        // Wait for the load itself: the switcher button exists while the list is still empty, and an
        // empty list legitimately finds nothing.
        XCTAssertTrue(element(app, "channelSidebar.category.direct_messages").waitForExistence(timeout: 30),
                      "the DM category must be loaded before the switcher is asked to find one:\n"
                      + "\(app.debugDescription)")
        opener.tap()
        let field = app.textFields["channelSidebar.quickSwitcher.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        // The DM's channel name is `id__stubuser__otheruser`; the person is `otheruser`. A switcher
        // that only searched channel names could never find it.
        field.typeText("otheruser")
        let result = element(app, "channelSidebar.quickSwitcher.result.\(Self.dm)")
        XCTAssertTrue(result.waitForExistence(timeout: 15),
                      "a DM must be found by the other person's username:\n\(app.debugDescription)")
        XCTAssertEqual(result.label, "Direct message", "the stub's DM carries no `directLabels`")
        attachShot(app, named: "t33-stub-02-dm-by-username")

        // Choosing it: the switcher is a gesture, so it must close, and the route it took must be
        // the shell's own funnel — the channel pane for that DM's id, not the empty destination.
        result.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !field.exists },
                      "choosing a result must close the switcher:\n\(app.debugDescription)")
        XCTAssertTrue(element(app, "nativeChannelPane").waitForExistence(timeout: 10),
                      "the chosen DM must open in the channel pane:\n\(app.debugDescription)")
        XCTAssertFalse(element(app, "nativeEmptyDestination").exists,
                       "the pane must have left the empty destination")
        XCTAssertEqual(app.staticTexts["nativeChannelTitle"].label, Self.dmName,
                       "the pane must be showing the channel the switcher chose")
    }

    /// The gate, both ways. With `sidebar=native` the list is mounted; with `sidebar=web` T30's
    /// placeholder is exactly what it was and **none** of T33's identifiers exist.
    func testTheFlagDecidesWhetherTheNativeListIsMounted() throws {
        try start(Self.stubSidebar, needs: "the sidebar fixture")

        let native = launch(Self.stubSidebar, sidebarNative: true)
        signIn(native, on: Self.stubSidebar)
        XCTAssertTrue(element(native, "channelSidebar.category.channels").waitForExistence(timeout: 40),
                      "with the flag on the native list must mount:\n\(native.debugDescription)")
        native.terminate()

        let web = launch(Self.stubSidebar, sidebarNative: false)
        signIn(web, on: Self.stubSidebar)
        XCTAssertTrue(element(web, "nativeSidebar").waitForExistence(timeout: 40),
                      "the pane itself must still mount without the flag:\n\(web.debugDescription)")
        XCTAssertFalse(element(web, "channelSidebar.category.channels").exists,
                       "`sidebar=web` must not mount T33's list")
        XCTAssertFalse(element(web, "channelSidebar.quickSwitcher").exists,
                       "`sidebar=web` must not mount the quick switcher")
        XCTAssertFalse(element(web, "channelSidebar.channel.\(Self.alpha)").exists,
                       "no channel rows without the flag")
        attachShot(web, named: "t33-stub-03-flag-off-placeholder")
    }

    /// A failed channel read is an error state with a retry — not an empty list and not a spinner.
    func testAFailedChannelReadShowsTheErrorAndARetry() throws {
        try start(Self.stubFailingChannels, needs: "the failing-channels fixture")
        let app = launch(Self.stubFailingChannels, sidebarNative: true)
        signIn(app, on: Self.stubFailingChannels)

        XCTAssertTrue(element(app, "channelSidebar.error").waitForExistence(timeout: 40),
                      "a 500 from the channel list must be reported:\n\(app.debugDescription)")
        XCTAssertTrue(element(app, "channelSidebar.retry").exists, "the error state must offer a retry")
        XCTAssertFalse(element(app, "channelSidebar.empty").exists,
                       "a failure is not an empty list")
        attachShot(app, named: "t33-stub-04-error-state")
    }

    // MARK: - Launch, sign-in, element lookup (the same seams as T32's identifier tests)

    private func launch(_ stub: String, sidebarNative: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetPersistedState",
                               "-uiTestForgetSession", stub,
                               "-uiTestSeedServer", stub,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-surfaceMode", sidebarNative ? "sidebar=native" : "sidebar=web",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    private func signIn(_ app: XCUIApplication, on stub: String) {
        let field = app.textFields["loginIDField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "the native sign-in must mount against \(stub):\n\(app.debugDescription)")
        field.tap()
        field.typeText(Self.login)
        let secret = app.secureTextFields["loginPasswordField"]
        XCTAssertTrue(secret.exists)
        secret.tap()
        secret.typeText(Self.password)
        app.buttons["loginSubmitButton"].tap()
        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 40),
                      "signing in must reach the shell:\n\(app.debugDescription)")
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    private func attachShot(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Skip (not fail) when the stub instance this test needs is not listening.
    private func start(_ stub: String, needs what: String) throws {
        guard let url = URL(string: stub + "/api/v4/system/ping") else {
            throw XCTSkip("bad stub URL \(stub)")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            reachable = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 5)
        try XCTSkipUnless(reachable, "start \(what): python3 mm_stub.py --port \(stub.split(separator: ":").last ?? "")")
    }
}
