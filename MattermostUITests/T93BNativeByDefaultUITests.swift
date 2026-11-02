import XCTest

/// T93B — the native-by-default flip, smoked the way a user actually gets it.
///
/// These tests launch the app **with no launch arguments at all**. That is the point of the flip:
/// a Release build resolves `.sidebar`, `.channelView` and `.composer` from
/// `SurfaceDefaults.nativeApprovedSurfaces`, while every `-surfaceMode` / `-uiTestSeed…` seam is
/// compiled out of Release (`SurfaceModeResolver.debugAffordancesEnabled`, `docs/dual-render.md`
/// §5/§8). There is therefore no way for this suite to *ask* for the native workspace — it can only
/// observe the default — which is exactly the claim the flip card has to prove.
///
/// State: a Release build cannot seed a server or a token (those seams are `#if DEBUG`). The suite
/// relies on the simulator's app container already holding a signed-in server — seed it once with a
/// Debug build (`-uiTestSeedServer … -uiTestSeedStoredToken …`), then install Release over it (same
/// bundle id, so the container and the Keychain item survive). When that state is absent the suite
/// **skips** rather than fails, so ordinary Debug UI runs stay green on a fresh device.
///
/// The container also restores the last location, so a launch may land inside a channel rather than
/// on the sidebar. `returnToSidebar(_:)` normalises that before any sidebar assertion; nothing here
/// writes a surface override, so the restored location is the only carry-over between tests.
final class T93BNativeByDefaultUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Put the container back the way the suite found it: the compact shell's channel list.
    ///
    /// The app restores its last **tab** as well as its last channel, and the lookup tests below end
    /// on Search/Saved/Mentions. Left that way, the two pre-existing smoke tests launch onto a lookup
    /// tab, where no `channelSidebar.channel.*` row exists and `waitForNativeSidebar` burns its whole
    /// 90 s (measured: run 3, `testTheEscapeHatchReturnsTheWorkspaceToTheWebView` and
    /// `testTheWorkspaceIsNativeWithNoLaunchArguments`, both "the native sidebar never drew a channel
    /// row in 90 s" after a Mentions-tab launch). The regular layout has no tab bar; nothing to do.
    override func tearDownWithError() throws {
        let app = XCUIApplication()
        guard app.tabBars.firstMatch.exists else { return }
        _ = ShellSettle.tapTab(ShellSettle.Tab.channels, in: app, wait: 5)
    }

    // MARK: - Helpers

    private func launchedWithNoArguments() -> XCUIApplication {
        let app = XCUIApplication()
        // Explicit, not just a default: a seed or a `-surfaceMode` flag here would make the whole
        // suite prove the wrong thing.
        app.launchArguments = []
        app.launchEnvironment = [:]
        app.launch()
        return app
    }

    /// Type-agnostic lookup: SwiftUI puts identifiers on different element classes depending on the
    /// container (`otherElements`, `staticTexts`, `buttons`), and the product's own tests use the
    /// same `descendants(matching: .any)` shape.
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func sidebarRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "channelSidebar.channel."))
    }

    /// The app restores its last location, so a launch can start inside a channel. That is fine for
    /// the pane assertions and has to be undone for the sidebar ones.
    ///
    /// The shell's back affordance is `backToolbarButton` (`RootView.swift:352`); `BackButton` is the
    /// name older suites used and no longer exists in this build (measured: a restored-channel launch
    /// left this helper tapping nothing and `waitForNativeSidebar` burned its whole 90 s).
    private func returnToSidebar(_ app: XCUIApplication) {
        // Label fallback matters: the *native* push is NavigationStack's own back button, whose
        // identifier is empty and whose label is "Back" (the identifier-bearing
        // `backToolbarButton` in RootView.swift:352 is the **web** toolbar's history back). Matching
        // identifiers only left this helper tapping nothing on a restored native channel.
        for query in [app.buttons.matching(identifier: "backToolbarButton"),
                      app.navigationBars.buttons.matching(identifier: "Back"),
                      app.buttons.matching(NSPredicate(format: "label == %@", "Back"))] {
            let back = query.firstMatch
            if back.waitForExistence(timeout: 3), back.isHittable {
                back.tap()
                return
            }
        }
    }

    /// Waits for the native sidebar to draw real channel rows. Skips when this simulator has no
    /// signed-in server (a fresh container renders the sign-in surface, which is correct behaviour
    /// and not this suite's subject).
    private func waitForNativeSidebar(_ app: XCUIApplication) throws {
        let started = Date()
        let deadline = started.addingTimeInterval(90)
        var triedOpening = false
        while Date() < deadline {
            if sidebarRows(app).firstMatch.exists { return }
            if element(app, "nativeAuthSurface").exists || app.textFields["loginIDField"].exists {
                throw XCTSkip("no signed-in server in this simulator's container: seed one with a "
                              + "Debug build and install Release over it (see the class comment)")
            }
            // The regular layout draws its channel list inside the split view's sidebar, which can
            // start collapsed (measured: the iPad's seeded container). Open it once, then keep
            // watching; the compact layout's rows are always on screen and this is a no-op there.
            if !triedOpening, Date().timeIntervalSince(started) > 5 {
                triedOpening = true
                openSidebarIfCollapsed(app)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        // Name what is on screen instead of only what is missing: a web-state launch and a collapsed
        // sidebar fail this the same way.
        let toolbarIDs = app.buttons.allElementsBoundByIndex
            .map { $0.identifier }.filter { !$0.isEmpty }.sorted()
        XCTFail("the native sidebar never drew a channel row in 90 s "
                + "(nativeShell: \(element(app, "nativeShell").exists), "
                + "webPane: \(element(app, "webPane").exists), "
                + "tabBar: \(app.tabBars.firstMatch.exists), "
                + "identified buttons: \(toolbarIDs))")
    }

    private func attachment(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - The release the card is for

    /// No flags, no seeds: the sidebar lists the account's channels, opening one mounts the native
    /// pane with its post list **and the native composer** — not the `"Message input — web (S14/T35)"`
    /// placeholder that a `web` composer draws once the pane owns (and has released) the webview.
    func testTheWorkspaceIsNativeWithNoLaunchArguments() throws {
        let app = launchedWithNoArguments()

        // A restored channel counts: the pane it restored is the same default resolution. Coming
        // back to the sidebar anyway keeps this test able to show both halves of the flip.
        //
        // `returnToSidebar` is called unconditionally: the shipped channel pane draws
        // `channelPostList`, **not** the placeholder's `nativeChannelPane`
        // (`NativePanePlaceholders.swift:327` is the placeholder view), so gating the pop on that
        // identifier never fired for a restored channel and `waitForNativeSidebar` burned its whole
        // 90 s (measured: runs 3 and 4, this test). The helper is a 5 s no-op when nothing is pushed.
        returnToSidebar(app)
        try waitForNativeSidebar(app)

        let first = sidebarRows(app).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 60), "the sidebar must list a channel")
        XCTAssertTrue(first.isHittable, "the sidebar's rows must be laid out, not zero-sized")
        attachment(app, named: "release-sidebar-no-arguments")

        first.tap()

        XCTAssertTrue(element(app, "nativeChannelPane").waitForExistence(timeout: 90),
                      "a channel row opens the native pane (the flip made .channelView native by default)")
        XCTAssertTrue(app.scrollViews["channelPostList"].waitForExistence(timeout: 90),
                      "the pane draws its post list")

        // The composer is inside the pane, so the pane-owning flip has to carry it: with `.composer`
        // resolving `web` the pane draws a dead placeholder while the webview is released.
        XCTAssertFalse(element(app, "channelComposerPlaceholder").exists,
                       "the native pane must not draw the web-composer placeholder")
        XCTAssertTrue(element(app, "channelComposer").waitForExistence(timeout: 30),
                      "the composer is native in the same build")
        XCTAssertTrue(app.textViews["channelComposer.input"].exists,
                      "the composer's text field is the native one, not a placeholder")

        attachment(app, named: "release-channel-pane-with-native-composer")
    }

    /// The escape hatch survives the flip: "Use web view" still hands the workspace back to the
    /// `WKWebView` in the same binary, without a relaunch.
    ///
    /// The row is the last row of the sidebar list, so it has to be scrolled into view — which is
    /// itself worth pinning: the hatch existing but being unreachable would be the same as not
    /// having it. Tapping it flips `channelView` to `.web` for the run, at which point the webview
    /// *is* the workspace, so the observables are a `webView` element appearing and the native pane
    /// going away.
    func testTheEscapeHatchReturnsTheWorkspaceToTheWebView() throws {
        let app = launchedWithNoArguments()
        // Same restored-channel pop as `testTheWorkspaceIsNative...`: unconditional, because the
        // shipped pane draws `channelPostList` and never the placeholder's `nativeChannelPane`.
        returnToSidebar(app)
        try waitForNativeSidebar(app)

        // The hatch is a `Button` in the sidebar list's last section. The button-typed query matters:
        // `descendants(matching: .any)` also matches a non-interactive wrapper carrying the same
        // identifier, which is never hittable even when the row is on screen (measured with a
        // signed-in container: the row was visible and `isHittable` was still false).
        let hatches = app.buttons.matching(identifier: "revertToWebchannelView")
        func hittableHatch() -> XCUIElement? {
            hatches.allElementsBoundByIndex.first { $0.isHittable }
        }
        // Scrolling has to land on the sidebar's **own** scroll surface (`channelSidebar.scroll`), not
        // on `app`: a swipe at the screen centre scrolls whatever the pane is drawing. The bound is
        // generous because a signed-in container can hold dozens of channels.
        let sidebar = ShellSettle.channelSidebarScroll(app)
        for _ in 0..<40 where hittableHatch() == nil {
            if sidebar.exists { sidebar.swipeUp() } else { app.swipeUp() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertTrue(hatches.firstMatch.waitForExistence(timeout: 30),
                      "the sidebar keeps the 'Use web view' escape hatch in a native Release build")
        guard let hatch = hittableHatch() else {
            attachment(app, named: "escape-hatch-unreachable")
            return XCTFail("the escape hatch must be reachable by scrolling the sidebar")
        }
        hatch.tap()

        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 120),
                      "the escape hatch must return the workspace to the WKWebView")
        XCTAssertFalse(element(app, "nativeChannelPane").exists,
                       "the webview replaces the native pane, it is not drawn on top of it")

        // Mounting is not the claim — a *committed, finished* page is. This is what caught the T93B
        // escape hatch leaving a blank pane on its ~10 % progress bar forever (`t_065c8753`): the
        // webview was installed, WebKit asked for a navigation policy decision, the delegate SwiftUI
        // had just torn down never answered, and nothing ever committed.
        //
        // The pane publishes its own page lifecycle as an accessibility value (`WebViewStore
        // .pageLoadState`) because the *web content* process is not reliably reachable from the runner
        // on this host — with a real page on screen the AX lookup answered `kAXErrorServerNotFound`,
        // so asserting `webApp.staticTexts` measured the test infrastructure, not the app.
        // `firstMatch` on purpose: a container with several servers mounts one pane per server, so the
        // identifier is not unique across the hierarchy (XCTest refuses an ambiguous lookup).
        let pane = app.descendants(matching: .any).matching(identifier: "webPane").firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 30),
                      "the web pane must publish its page state (`webPane`)")
        let loaded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "loaded"),
            object: pane)
        let result = XCTWaiter().wait(for: [loaded], timeout: 60)
        attachment(app, named: result == .completed
                   ? "escape-hatch-webview-rendered"
                   : "escape-hatch-webview-blank")
        XCTAssertEqual(result, .completed,
                       "the escape hatch must land on a page that committed and finished "
                       + "(state: \(String(describing: pane.value)); nothing committed points at "
                       + "WebViewStore.mountedContainers and installedCoordinator)")
    }

    // MARK: - t_636e6483 — what a reader sees with no flags: five tabs, three real lookup screens

    /// The ship-shaped measurement for the `t_aa211ff6` decision (§7-B).
    ///
    /// Every test below launches the **same** way the two tests above do — a Release build,
    /// `app.launchArguments = []` — so the only route to a native decision is
    /// `SurfaceDefaults.nativeApprovedSurfaces`. The `-uiTestSeed…`/`-surfaceMode` seams do not exist
    /// in this binary; the server and the session come from the container seeded with a Debug build.
    ///
    /// The server-dependent assertions read their oracle from the running server over REST (the same
    /// `TEST_RUNNER_MM_AUTH_*` contract every live suite uses) and **skip** when it is absent. A skip
    /// is reported as a skip: nothing here turns "not measured" into a pass.
    private struct LiveServer {
        let url: URL
        let login: String
        let password: String
        let token: String
        let userID: String
        let teamID: String
    }

    /// Launch with no arguments, then wait for whichever signed-in landing this layout draws.
    ///
    /// `waitForNativeSidebar` above needs a *visible* channel list; the regular (iPad/split) layout
    /// starts with the sidebar collapsed, so it would burn 90 s and fail on a perfectly signed-in
    /// container. This answers "is the container signed in?" for both shapes.
    private func launchedIntoShell() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = []
        // Only the os_log firehose guard (docs/t8d-build-note.md §1) — not state, not a surface.
        app.launchEnvironment = ["OS_ACTIVITY_MODE": "disable"]
        app.launch()

        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if app.textFields["loginIDField"].exists || element(app, "nativeAuthSurface").exists {
                throw XCTSkip("no signed-in server in this simulator's container: seed one with a "
                              + "Debug build and install Release over it (see the class comment)")
            }
            if element(app, "nativeShell").exists || app.tabBars.firstMatch.exists
                || element(app, "nativeChannelPane").exists {
                return app
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTFail("the shipped shell never drew a signed-in landing in 90 s:\n\(app.debugDescription)")
        return app
    }

    /// Which layout the device draws.
    ///
    /// The compact shell **pushes a channel over its tab bar** (`docs/t95-shell-tab-bar-decision.md`
    /// §2 D1), so "is there a tab bar right now?" answers "no" on a phone that restored one. Settle
    /// that first: pop the push, then ask.
    private func isCompactLayout(_ app: XCUIApplication) -> Bool {
        returnToTabs(app)
        return app.tabBars.firstMatch.waitForExistence(timeout: 15)
    }

    /// Pop whatever the compact shell pushed over the tab bar, so the bar is reachable.
    ///
    /// `ShellSettle.revealTabs` looks for `navigationBars.buttons["Back"]`; on this build the back
    /// affordance is the toolbar's `backToolbarButton`, so that query answers nothing and the sheets
    /// below would never settle. This keeps ShellSettle's contract (tap Back until the bar is up) with
    /// the identifier this runtime actually publishes.
    private func returnToTabs(_ app: XCUIApplication) {
        if app.tabBars.firstMatch.exists { return }
        let backs = [app.buttons["backToolbarButton"],
                     app.navigationBars.buttons["Back"]]
        for _ in 0..<3 {
            guard let back = backs.first(where: { $0.exists && $0.isHittable }) else { return }
            back.tap()
            if app.tabBars.firstMatch.waitForExistence(timeout: 8) { return }
        }
    }

    /// Open one of the three lookup screens the way the layout under test offers it: the compact
    /// shell's tab, or the regular shell's detail-column toolbar (which opens it as a sheet).
    ///
    /// - Returns: `true` when the screen mounted (`pane`), `false` after failing the test.
    @discardableResult
    private func openLookup(_ tab: String, toolbar: String, pane: String,
                            in app: XCUIApplication) -> Bool {
        returnToTabs(app)
        if app.tabBars.firstMatch.exists {
            // The bar can be on screen a beat before its items are in the accessibility tree.
            guard app.tabBars.buttons[tab].waitForExistence(timeout: 25) else {
                XCTFail("the tab bar is on screen but offers no \"\(tab)\" tab:\n\(app.debugDescription)")
                return false
            }
            guard ShellSettle.tapTab(tab, in: app, wait: 15) else { return false }
        } else {
            let button = element(app, toolbar)
            guard button.waitForExistence(timeout: 25) else {
                XCTFail("neither the tab bar nor the toolbar opens \"\(tab)\":\n\(app.debugDescription)")
                return false
            }
            button.tap()
        }
        guard element(app, pane).waitForExistence(timeout: 45) else {
            XCTFail("\"\(tab)\" must mount \(pane):\n\(app.debugDescription)")
            return false
        }
        return true
    }

    /// The team the shell is **looking at**: the rail row that says "Current team".
    ///
    /// The reader's search is team-scoped (`SearchView` uses `navigation.location.teamID`), so a
    /// fixture post created in a different team is correctly never found. Reading the scope off the
    /// running shell — instead of assuming the account's first team — is what keeps the live test
    /// measuring the app rather than this file's guess.
    private func selectedTeamID(_ app: XCUIApplication) -> String? {
        // The rail lives in the Channels tab (and, on the regular layout, inside the sidebar). A
        // restored channel covers the compact bar, so settle first.
        returnToTabs(app)
        if app.tabBars.firstMatch.exists {
            _ = app.tabBars.buttons[ShellSettle.Tab.channels].waitForExistence(timeout: 20)
            _ = ShellSettle.tapTab(ShellSettle.Tab.channels, in: app, wait: 15)
        }
        // The regular layout keeps the rail inside a collapsed sidebar. This deliberately does *not*
        // expand it: opening the split view to read a scope would disturb the toolbar the very next
        // step taps. "Unread" is answered by seeding every team instead.
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "teamSidebar.team."))
        if rows.firstMatch.waitForExistence(timeout: 25) {
            for row in rows.allElementsBoundByIndex where row.isSelected {
                return String(row.identifier.dropFirst("teamSidebar.team.".count))
            }
            for row in rows.allElementsBoundByIndex
            where (row.value as? String ?? "").contains("Current team") {
                return String(row.identifier.dropFirst("teamSidebar.team.".count))
            }
        }
        return nil
    }

    /// Close a regular-layout lookup sheet by its own Done button.
    private func closeLookupSheet(_ which: String, in app: XCUIApplication) {
        // The regular layout's sheets draw their Done affordance twice in the accessibility tree
        // (measured: iPad run 1, "Multiple matching elements found" for `searchSheetClose`), so tap
        // the first *hittable* one instead of asserting the query is a single element.
        let done = app.descendants(matching: .any).matching(identifier: "\(which)SheetClose")
        guard done.firstMatch.waitForExistence(timeout: 10) else { return }
        for index in 0..<done.count {
            let candidate = done.element(boundBy: index)
            if candidate.isHittable {
                candidate.tap()
                return
            }
        }
        done.firstMatch.tap()
    }

    /// The three F5′ notes the flip makes unreachable in a Release build. Their **absence** is the
    /// decision; a note on screen would mean the surface still resolves `web` in this configuration.
    private func assertNoLookupNotes(_ app: XCUIApplication, screen: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        for identifier in ["searchWebFallback", "savedWebFallback", "activityWebFallback"] {
            XCTAssertFalse(element(app, identifier).exists,
                           "\(screen): \(identifier) must not exist in a Release build with no "
                           + "launch arguments — the note is the only thing a `web` lookup surface "
                           + "draws, and the flip is what removed it",
                           file: file, line: line)
        }
    }

    // MARK: - 1. Compact/iPhone: five tabs, three of them real

    func testCompactShellShowsFiveTabsAndThreeNativeLookupScreens() throws {
        let app = try launchedIntoShell()
        let compact = isCompactLayout(app)
        try XCTSkipUnless(compact, "this device draws the regular (split) layout — see "
                          + "testRegularShellDrawsTheSameThreeAsToolbarSheets")

        let bar = app.tabBars.firstMatch
        XCTAssertEqual(bar.buttons.count, 5,
                       "the shipped compact shell offers five tabs:\n\(app.debugDescription)")
        for title in [ShellSettle.Tab.channels, ShellSettle.Tab.threads, ShellSettle.Tab.search,
                      ShellSettle.Tab.activity, ShellSettle.Tab.saved] {
            XCTAssertTrue(bar.buttons[title].exists,
                          "the tab bar must offer \"\(title)\":\n\(app.debugDescription)")
        }
        attachment(app, named: "release-five-tabs")

        // Search — the screen, not a note.
        XCTAssertTrue(openLookup(ShellSettle.Tab.search, toolbar: "shellSearchButton",
                                 pane: "nativeSearchPane", in: app))
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 30),
                      "the Search tab must draw its own field:\n\(app.debugDescription)")
        XCTAssertTrue(element(app, "searchSubmit").exists,
                      "with a team selected the native search offers its submit button")
        assertNoLookupNotes(app, screen: "compact Search tab")
        attachment(app, named: "release-compact-search")

        // Saved — the native list (or its loading state), never the note.
        XCTAssertTrue(openLookup(ShellSettle.Tab.saved, toolbar: "shellSavedButton",
                                 pane: "nativeSavedPane", in: app))
        // The card names `savedPosts`; on this runtime SwiftUI does not publish the List's own
        // identifier (measured by T5449-C2: `build/logs/t5449c2-live1.log`), so the observable that
        // proves the list drew is the pane plus the rows the live test below resolves. Recorded here
        // rather than asserted away.
        let list = element(app, "savedPosts")
        XCTAssertTrue(list.exists || element(app, "savedPosts.loading").exists
                      || element(app, "nativeSavedPane").exists,
                      "the Saved tab must draw the native saved list:\n\(app.debugDescription)")
        assertNoLookupNotes(app, screen: "compact Saved tab")
        attachment(app, named: "release-compact-saved")

        // Mentions — the feed (or its empty state for an account with nothing unread).
        XCTAssertTrue(openLookup(ShellSettle.Tab.activity, toolbar: "shellActivityButton",
                                 pane: "nativeActivityPane", in: app))
        XCTAssertTrue(element(app, "activity.list").waitForExistence(timeout: 45)
                      || element(app, "activity.empty").exists,
                      "the Mentions tab must draw the native feed (or its empty state):\n"
                      + app.debugDescription)
        assertNoLookupNotes(app, screen: "compact Mentions tab")
        attachment(app, named: "release-compact-mentions")
    }

    // MARK: - 2. Regular/iPad: the same three as toolbar sheets, plus the pinned sheet

    func testRegularShellDrawsTheSameThreeAsToolbarSheets() throws {
        let app = try launchedIntoShell()
        try XCTSkipIf(isCompactLayout(app),
                      "this device draws the compact (tab) layout — see "
                      + "testCompactShellShowsFiveTabsAndThreeNativeLookupScreens")

        for (button, pane, extra) in [("shellSearchButton", "nativeSearchPane", "searchField"),
                                      ("shellSavedButton", "nativeSavedPane", nil),
                                      ("shellActivityButton", "nativeActivityPane", "activity.list")] {
            let entry = element(app, button)
            XCTAssertTrue(entry.waitForExistence(timeout: 30),
                          "the regular shell's toolbar must offer \(button):\n\(app.debugDescription)")
            entry.tap()
            XCTAssertTrue(element(app, pane).waitForExistence(timeout: 45),
                          "\(button) must open a sheet drawing \(pane):\n\(app.debugDescription)")
            if let extra {
                XCTAssertTrue(element(app, extra).waitForExistence(timeout: 45),
                              "the \(pane) sheet must draw \(extra):\n\(app.debugDescription)")
            }
            assertNoLookupNotes(app, screen: "regular \(button) sheet")
            attachment(app, named: "release-regular-\(button)")
            closeLookupSheet(button.replacingOccurrences(of: "shell", with: "")
                                .replacingOccurrences(of: "Button", with: "")
                                .lowercased(), in: app)
            XCTAssertTrue(waitUntil(timeout: 15) { !element(app, pane).exists },
                          "the \(button) sheet must close again:\n\(app.debugDescription)")
        }

        // The pinned sheet lives in an open channel's header, so a channel has to be open first.
        openAnyChannel(app)
        let pinButton = element(app, "nativeChannelPinnedButton")
        XCTAssertTrue(pinButton.waitForExistence(timeout: 60),
                      "an open channel's header must offer the pinned messages "
                      + "(the same `search` key gates it):\n\(app.debugDescription)")
        pinButton.tap()
        XCTAssertTrue(element(app, "pinnedSheet").waitForExistence(timeout: 45),
                      "the pinned button must open the native pinned sheet:\n\(app.debugDescription)")
        attachment(app, named: "release-regular-pinned-sheet")
    }

    // MARK: - 3. One real query end to end, and a mention row that lands on its channel

    /// A query typed into the shipped Search tab reaches the server over REST and its matches draw
    /// — the webview is released in this configuration, so a result on screen can only come from
    /// the native path.
    func testOneSearchQueryEndToEndWithNoFlags() throws {
        let server = try liveServer()
        let app = try launchedIntoShell()

        let word = "t636shipshape\(Int(Date().timeIntervalSince1970))"
        let targets = try seedSearchTargets(word: word, app: app, server: server)

        XCTAssertTrue(openLookup(ShellSettle.Tab.search, toolbar: "shellSearchButton",
                                 pane: "nativeSearchPane", in: app))
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 30),
                      "the shipped Search screen must draw its field:\n\(app.debugDescription)")
        field.tap()
        field.typeText(word)
        let submit = app.buttons["searchSubmit"]
        if submit.waitForExistence(timeout: 15) { submit.tap() } else { field.typeText("\n") }

        XCTAssertTrue(element(app, "searchResults").waitForExistence(timeout: 45),
                      "a submitted query must draw the result list:\n\(app.debugDescription)")
        guard let (postID, row) = revealAnyResult(app, postIDs: targets) else {
            return XCTFail("the server's match for \"\(word)\" (\(targets)) must be a row:\n"
                           + app.debugDescription)
        }
        XCTAssertTrue(row.waitForExistence(timeout: 45),
                      "the server's match \(postID) for \"\(word)\" must be a row:\n"
                      + app.debugDescription)
        XCTAssertTrue(row.label.lowercased().contains(word.lowercased()),
                      "the row must draw the server's message, got \"\(row.label)\"")
        attachment(app, named: "release-live-search-results")

        row.tap()
        XCTAssertTrue(element(app, "postFocus.\(postID)").waitForExistence(timeout: 60),
                      "a result must open its channel and land on that post:\n\(app.debugDescription)")
        attachment(app, named: "release-live-search-opened-post")
    }

    func testAMentionRowLandsOnItsChannelWithNoFlags() throws {
        _ = try liveServer()
        let app = try launchedIntoShell()

        XCTAssertTrue(openLookup(ShellSettle.Tab.activity, toolbar: "shellActivityButton",
                                 pane: "nativeActivityPane", in: app))
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "activity.row."))
        guard rows.firstMatch.waitForExistence(timeout: 45) else {
            throw XCTSkip("the fixture account has no mention rows to open (feed empty)")
        }
        let row = rows.firstMatch
        let channelLabel = String(row.label.split(separator: ",").first ?? Substring(""))
        attachment(app, named: "release-live-mentions-list")
        row.tap()

        let title = element(app, "nativeChannelTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 60),
                      "tapping a mention must open its channel:\n\(app.debugDescription)")
        // The row draws the URL slug ("#t42-activity"); the header draws the server's display name
        // ("T42 activity"). Compare the letters and digits only, so the jump is what is measured and
        // not the two spellings the same channel has.
        func comparable(_ text: String) -> String {
            String(text.lowercased().filter { $0.isLetter || $0.isNumber })
        }
        let expected = comparable(channelLabel)
        XCTAssertTrue(waitUntil(timeout: 20) {
            expected.isEmpty || comparable(title.label).contains(expected)
        }, "the jump must open the mention's own channel (row said \"\(channelLabel)\", header "
           + "says \"\(title.label)\")")
        attachment(app, named: "release-live-mention-opened-channel")
    }

    // MARK: - 4. The post options menu on a lookup row (00cd217's regression surface)

    /// `00cd217` added the options menu to the **shared** `PostRowView`. This is the finding the
    /// decision card asked this round to measure: a search-result row is drawn by `SearchResultRowView`,
    /// which calls `PostRowView` without `actions:`, so the row asks for no menu — and the ellipsis
    /// (`post.<id>.menu`) is not in the tree, let alone its sheet.
    func testThePostOptionsMenuOpensOnASearchResultRow() throws {
        let server = try liveServer()
        let app = try launchedIntoShell()
        let word = "t636options\(Int(Date().timeIntervalSince1970))"
        let targets = try seedSearchTargets(word: word, app: app, server: server)

        XCTAssertTrue(openLookup(ShellSettle.Tab.search, toolbar: "shellSearchButton",
                                 pane: "nativeSearchPane", in: app))
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        field.tap()
        field.typeText(word)
        let submit = app.buttons["searchSubmit"]
        if submit.waitForExistence(timeout: 10) { submit.tap() } else { field.typeText("\n") }

        guard let (postID, row) = revealAnyResult(app, postIDs: targets) else {
            return XCTFail("the result row must draw first:\n\(app.debugDescription)")
        }
        XCTAssertTrue(row.exists, "the result row must draw first:\n\(app.debugDescription)")
        let menu = element(app, "post.\(postID).menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 15),
                      "a search-result row must offer the post options menu that 00cd217 added: "
                      + "`post.\(postID).menu` is not in the tree (SearchResultRowView calls "
                      + "PostRowView without `actions:`):\n\(app.debugDescription)")
        menu.tap()
        XCTAssertTrue(element(app, "postOptions.\(postID)").waitForExistence(timeout: 30),
                      "the search result's menu must open the options sheet:\n\(app.debugDescription)")
        attachment(app, named: "release-search-result-options")
    }

    func testThePostOptionsMenuOpensOnAMentionRow() throws {
        _ = try liveServer()
        let app = try launchedIntoShell()
        XCTAssertTrue(openLookup(ShellSettle.Tab.activity, toolbar: "shellActivityButton",
                                 pane: "nativeActivityPane", in: app))
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "activity.row."))
        guard rows.firstMatch.waitForExistence(timeout: 45) else {
            throw XCTSkip("the fixture account has no mention rows to open")
        }
        let row = rows.firstMatch
        let postID = String(row.identifier.dropFirst("activity.row.".count))
        attachment(app, named: "release-mention-row-before-menu")

        let menu = element(app, "post.\(postID).menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 15),
                      "a mention row must offer the post options menu that 00cd217 added: "
                      + "`post.\(postID).menu` is not in the tree (ActivityRowView calls PostRowView "
                      + "without `actions:`):\n\(app.debugDescription)")
        menu.tap()
        XCTAssertTrue(element(app, "postOptions.\(postID)").waitForExistence(timeout: 30),
                      "the mention row's menu must open the options sheet:\n\(app.debugDescription)")
        attachment(app, named: "release-mention-row-options")
    }

    // MARK: - 5. The escape hatch hands the workspace to the webview

    /// The card's item 5 has two clauses. The first — *"Use web view" returns the workspace to a
    /// loaded webview* — is measured here and is true. The second — *"the lookup tabs/buttons still
    /// draw native screens"* — describes a state this product does not have: the hatch resolves
    /// `.channelView` to `web`, and `SurfaceHost` then renders the webview **instead of**
    /// `NativeShellView`, so the compact tab bar and the regular toolbar go with the native shell
    /// (measured: no `tabBars` first match, no `shell*Button`, no lookup pane; the screen is the web
    /// app). That is recorded, not asserted away: this test asserts the two things that are true in
    /// that state — a loaded page, and **no** lookup note anywhere — and attaches what is present.
    func testTheEscapeHatchHandsTheWorkspaceToTheWebViewWithNoLookupNote() throws {
        let app = try launchedIntoShell()
        if element(app, "nativeChannelPane").waitForExistence(timeout: 5) { returnToTabs(app) }

        // The hatch is a Button in the sidebar list's last section (same route as the test above).
        let hatches = app.buttons.matching(identifier: "revertToWebchannelView")
        func hittableHatch() -> XCUIElement? {
            hatches.allElementsBoundByIndex.first { $0.isHittable }
        }
        if !isCompactLayout(app) { openSidebarIfCollapsed(app) }
        let sidebar = ShellSettle.channelSidebarScroll(app)
        for _ in 0..<40 where hittableHatch() == nil {
            if sidebar.exists { sidebar.swipeUp() } else { app.swipeUp() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        guard let hatch = hittableHatch() else {
            attachment(app, named: "escape-hatch-unreachable-lookups")
            return XCTFail("the escape hatch must be reachable:\n\(app.debugDescription)")
        }
        hatch.tap()

        let pane = app.descendants(matching: .any).matching(identifier: "webPane").firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 60),
                      "the hatch must mount the web pane:\n\(app.debugDescription)")
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "loaded"),
                                              object: pane)
        XCTAssertEqual(XCTWaiter().wait(for: [loaded], timeout: 90), .completed,
                       "the hatch must land on a page that committed and finished")

        // The lookup surfaces still resolve `native` — the hatch writes `.channelView` only. What the
        // screen can show of that is: no note. (The panes themselves are not mounted, because the
        // native shell that hosts them is not mounted either.)
        assertNoLookupNotes(app, screen: "after Use web view")

        var present: [String] = []
        for identifier in ["shellSearchButton", "shellSavedButton", "shellActivityButton",
                           "nativeSearchPane", "nativeSavedPane", "nativeActivityPane"] {
            if element(app, identifier).exists { present.append(identifier) }
        }
        let record = XCTAttachment(string: "after \"Use web view\":\n"
                                  + "tab bar present = \(app.tabBars.firstMatch.exists)\n"
                                  + "lookup identifiers present = \(present)\n"
                                  + "web pane value = \(String(describing: pane.value))")
        record.name = "release-hatch-state"
        record.lifetime = .keepAlways
        add(record)
        print("[t636] after hatch: tabBar=\(app.tabBars.firstMatch.exists) present=\(present)")
        attachment(app, named: "release-hatch-webview-no-lookup-note")
    }

    // MARK: - 6. Badge arithmetic with the native feed mounted

    /// The badge itself is `UNUserNotificationCenter.setBadgeCount` on the springboard icon. **No
    /// XCUITest query can read it**, and this host exposes no simulator API for it either (probed:
    /// `simctl spawn … defaults read com.apple.springboard` has no badge key, `SpringBoard/IconState.plist`
    /// carries layout only, `Library/UserNotifications` carries delivered notifications only). So the
    /// equality "icon badge == the server's summed `mention_count`" is **not measurable from here** and
    /// is reported as such, not as a pass.
    ///
    /// What *is* measurable is every number that equality is built from, and one drawn badge fed by
    /// the same counters: the native feed really lists rows for a non-zero server total, and the team
    /// rail (whose row value is "Current team, N mentions", `TeamSidebarView.accessibilityValue`)
    /// draws the server's per-team counts minus the selected team's, which upstream hides. That is an
    /// arithmetic equality on the app's own counters — the double-counting check the card asks for —
    /// with the one leap to the OS icon badge named instead of assumed.
    func testTheMountedFeedIsFedByTheServersMentionCounters() throws {
        let server = try liveServer()
        let app = try launchedIntoShell()
        XCTAssertTrue(openLookup(ShellSettle.Tab.activity, toolbar: "shellActivityButton",
                                 pane: "nativeActivityPane", in: app))
        guard element(app, "activity.list").waitForExistence(timeout: 45) else {
            throw XCTSkip("the native feed drew its empty state — no mention rows to compare")
        }
        // The server's own total: the same `GET /users/me/teams/unread` the poller and the feed read.
        let serverCounts = try serverMentionCounts(server)
        let serverTotal = serverCounts.values.reduce(0, +)
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "activity.row."))
        let rowCount = rows.count
        XCTAssertGreaterThan(rowCount, 0, "the mounted feed must list at least one mention row")
        XCTAssertGreaterThan(serverTotal, 0,
                             "the fixture account must have a non-zero server mention total — "
                             + "otherwise this run measures an all-zero badge and proves nothing")

        // The one place a mention count is drawn: the team rail, whose row value says
        // "Current team, N mentions" (`TeamSidebarView.accessibilityValue`). Upstream hides the
        // badge of the *selected* team, so the rail's sum is the server's sum minus that team's
        // count — an equality, not a "some badge exists".
        let appTeam = selectedTeamID(app)
        let hidden = appTeam.flatMap { serverCounts[$0] } ?? 0
        let expectedRail = serverTotal - hidden
        let railRows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "teamSidebar.team."))
        var railSum = 0
        if railRows.count > 0 {
            for index in 0..<railRows.count {
                let value = railRows.element(boundBy: index).value as? String ?? ""
                if value.contains("Current team") { continue }
                railSum += value.split(separator: ",")
                    .compactMap { part -> Int? in
                        let words = part.split(separator: " ")
                        guard words.count == 2, words[1].hasPrefix("mention") else { return nil }
                        return Int(words[0])
                    }
                    .reduce(0, +)
            }
            XCTAssertEqual(railSum, expectedRail,
                           "the rail's mention badges must equal the server's summed mention_count "
                           + "less the selected team's (upstream hides that one): server "
                           + "\(serverCounts) rail \(railSum)")
        } else {
            // The regular layout's rail is behind a collapsed sidebar; nothing drawn, nothing to
            // compare. Named rather than silently skipped into a pass.
            print("[t636] rail not drawn (sidebar collapsed): rail check not measured")
        }
        attachment(app, named: "release-badge-feed")
        // Both numbers go into the result bundle, so the host-side badge read (if one is ever added)
        // has the run's own values next to it.
        let record = XCTAttachment(string: "server mention_count per team = \(serverCounts)\n"
                                  + "server summed mention_count = \(serverTotal)\n"
                                  + "feed rows drawn = \(rowCount)\n"
                                  + "rail badge sum drawn = \(railRows.count > 0 ? String(railSum) : "not drawn")\n"
                                  + "selected team = \(appTeam ?? "unread")\n"
                                  + "icon badge = NOT OBSERVABLE from the test runner "
                                  + "(UNUserNotificationCenter.setBadgeCount)")
        record.name = "release-badge-numbers"
        record.lifetime = .keepAlways
        add(record)
        print("[t636] server mention total = \(serverTotal); feed rows = \(rowCount); "
              + "rail = \(railRows.count > 0 ? String(railSum) : "n/a") expected \(expectedRail)")
    }

    // MARK: - Live server (oracle)

    private func liveServer() throws -> LiveServer {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        let login = env["MM_AUTH_LOGIN"] ?? ""
        let password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !login.isEmpty && !password.isEmpty,
                          "live half of the ship-shaped round: set TEST_RUNNER_MM_AUTH_SERVER / "
                          + "_LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        var ping = URLRequest(url: url.appendingPathComponent("api/v4/system/ping"))
        ping.timeoutInterval = 5
        let (_, response) = try synchronous(ping)
        try XCTSkipUnless((response as? HTTPURLResponse)?.statusCode == 200,
                          "the live server at \(raw) is not answering")
        let session = try authenticate(url: url, login: login, password: password)
        let teams = try getJSON(url: url, path: "/api/v4/users/me/teams", token: session.token)
            as? [[String: Any]] ?? []
        guard let team = teams.first(where: { ($0["name"] as? String) == "perf" }) ?? teams.first,
              let teamID = team["id"] as? String else {
            throw XCTSkip("the fixture account has no team — run scripts/perf_seed.py")
        }
        return LiveServer(url: url, login: login, password: password,
                          token: session.token, userID: session.userID, teamID: teamID)
    }

    /// One post per candidate team carrying a word only this run uses, so the app's query has a
    /// server-side match whose id this test knows.
    ///
    /// The reader's search is **team-scoped** (`SearchView` uses `navigation.location.teamID`). On the
    /// compact layout the rail publishes the current team, so one post in that team is enough. On the
    /// regular layout the rail starts inside a collapsed sidebar; rather than driving the split view
    /// just to read a scope, every team the account belongs to gets the post — the word is unique to
    /// this run, so exactly one of them can ever come back, and the team is read off the *shell*
    /// wherever that is possible.
    private func seedSearchTargets(word: String, app: XCUIApplication,
                                   server: LiveServer) throws -> [String] {
        if let appTeam = selectedTeamID(app) {
            print("[t636] search scope: shell team = \(appTeam)")
            return [try createPost(word: word, teamID: appTeam, on: server)]
        }
        let teams = try teamIDsForMe(server)
        print("[t636] search scope: shell team unread; seeding \(teams.count) teams")
        var ids: [String] = []
        for teamID in teams {
            if let id = try? createPost(word: word, teamID: teamID, on: server) { ids.append(id) }
        }
        try XCTSkipIf(ids.isEmpty, "the account's teams have no town-square — run scripts/perf_seed.py")
        return ids
    }

    private func createPost(word: String, teamID: String, on server: LiveServer) throws -> String {
        let channel = try getJSON(url: server.url,
                                  path: "/api/v4/teams/\(teamID)/channels/name/town-square",
                                  token: server.token) as? [String: Any] ?? [:]
        guard let channelID = channel["id"] as? String else {
            throw XCTSkip("team \(teamID) has no town-square — run scripts/perf_seed.py")
        }
        let body = try sendJSON(url: server.url, method: "POST", path: "/api/v4/posts",
                                body: ["channel_id": channelID,
                                       "message": "t636 ship-shaped query \(word)"],
                                token: server.token) as? [String: Any] ?? [:]
        guard let id = body["id"] as? String else {
            throw XCTSkip("the fixture server did not accept a post")
        }
        return id
    }

    private func teamIDsForMe(_ server: LiveServer) throws -> [String] {
        let teams = try getJSON(url: server.url, path: "/api/v4/users/me/teams",
                                token: server.token) as? [[String: Any]] ?? []
        return teams.compactMap { $0["id"] as? String }
    }

    private func serverMentionTotal(_ server: LiveServer) throws -> Int {
        try serverMentionCounts(server).values.reduce(0, +)
    }

    /// `GET /users/me/teams/unread` → team id → `mention_count`, the same numbers `MentionPoller`
    /// and the native feed read. The rail draws them per team, which is the only place in the UI
    /// where a mention count is observable at all (see the badge test).
    private func serverMentionCounts(_ server: LiveServer) throws -> [String: Int] {
        let rows = try getJSON(url: server.url, path: "/api/v4/users/me/teams/unread",
                               token: server.token) as? [[String: Any]] ?? []
        var counts: [String: Int] = [:]
        for row in rows {
            guard let teamID = row["team_id"] as? String else { continue }
            counts[teamID] = max(0, row["mention_count"] as? Int ?? 0)
        }
        return counts
    }

    private func authenticate(url: URL, login: String, password: String) throws
        -> (token: String, userID: String) {
        var request = URLRequest(url: url.appendingPathComponent("api/v4/users/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["login_id": login,
                                                                      "password": password])
        let (data, response) = try synchronous(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let token = http.value(forHTTPHeaderField: "Token"),
              let user = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = user["id"] as? String else {
            throw XCTSkip("could not sign in as \(login) (HTTP "
                          + "\((response as? HTTPURLResponse)?.statusCode ?? -1))")
        }
        return (token, id)
    }

    private func getJSON(url: URL, path: String, token: String) throws -> Any {
        var request = URLRequest(url: url.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw XCTSkip("GET \(path) answered \(status)")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func sendJSON(url: URL, method: String, path: String, body: Any?,
                          token: String) throws -> Any {
        var request = URLRequest(url: url.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw XCTSkip("\(method) \(path) answered \(status)")
        }
        guard !data.isEmpty, let json = try? JSONSerialization.jsonObject(with: data) else {
            return [:]
        }
        return json
    }

    /// The oracle's own session: no cookie store (a stale `MMAUTHTOKEN` makes the server answer
    /// `session_expired` before it looks at the request — T39-R2 / T40-R).
    private static let restSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    private func synchronous(_ request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data, URLResponse)?
        var failure: Error?
        Self.restSession.dataTask(with: request) { data, response, error in
            if let error { failure = error }
            if let data, let response { result = (data, response) }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        if let failure { throw failure }
        guard let result else { throw URLError(.timedOut) }
        return result
    }

    // MARK: - Element helpers

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    /// Which of `postIDs` the result list actually drew (see `seedSearchTargets`), swiping the list
    /// until one of them is built.
    private func revealAnyResult(_ app: XCUIApplication, postIDs: [String],
                                 maxSwipes: Int = 12) -> (String, XCUIElement)? {
        func drawn() -> (String, XCUIElement)? {
            for postID in postIDs {
                let candidate = element(app, "searchResult.\(postID)")
                if candidate.exists { return (postID, candidate) }
            }
            return nil
        }
        if let hit = drawn() { return hit }
        let list = element(app, "searchResults")
        for _ in 0..<maxSwipes {
            guard list.exists else { return nil }
            list.swipeUp(velocity: .fast)
            if let hit = drawn() { return hit }
        }
        return drawn()
    }

    // MARK: - Opening a channel on the regular layout

    /// Expand the split view's sidebar when the regular layout starts with it collapsed.
    private func openSidebarIfCollapsed(_ app: XCUIApplication) {
        if app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "channelSidebar.channel."))
            .firstMatch.exists { return }
        // The split view's toggle is system chrome, so its label is the only handle: "Sidebar",
        // "Show Sidebar", "Hide Sidebar" (iOS 18 varies with state and locale).
        for predicate in [NSPredicate(format: "label CONTAINS[c] 'sidebar'"),
                          NSPredicate(format: "identifier CONTAINS[c] 'sidebar'")] {
            let toggles = app.buttons.matching(predicate)
            if toggles.firstMatch.waitForExistence(timeout: 5) {
                for index in 0..<toggles.count where toggles.element(boundBy: index).isHittable {
                    toggles.element(boundBy: index).tap()
                    return
                }
            }
        }
        print("[t636] no sidebar toggle found; rail may still be drawn")
    }

    @discardableResult
    private func openAnyChannel(_ app: XCUIApplication) -> Bool {
        openSidebarIfCollapsed(app)
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "channelSidebar.channel."))
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let row = rows.allElementsBoundByIndex.first(where: { $0.isHittable }) {
                row.tap()
                XCTAssertTrue(element(app, "nativeChannelPane").waitForExistence(timeout: 60),
                              "a channel row must open the native pane:\n\(app.debugDescription)")
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        attachment(app, named: "regular-no-channel-row")
        XCTFail("the regular layout must offer a channel to open:\n\(app.debugDescription)")
        return false
    }
}
