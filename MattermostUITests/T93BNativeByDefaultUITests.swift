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
    private func returnToSidebar(_ app: XCUIApplication) {
        let back = app.buttons["BackButton"]
        if back.waitForExistence(timeout: 5), back.isHittable {
            back.tap()
        }
    }

    /// Waits for the native sidebar to draw real channel rows. Skips when this simulator has no
    /// signed-in server (a fresh container renders the sign-in surface, which is correct behaviour
    /// and not this suite's subject).
    private func waitForNativeSidebar(_ app: XCUIApplication) throws {
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if sidebarRows(app).firstMatch.exists { return }
            if element(app, "nativeAuthSurface").exists || app.textFields["loginIDField"].exists {
                throw XCTSkip("no signed-in server in this simulator's container: seed one with a "
                              + "Debug build and install Release over it (see the class comment)")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTFail("the native sidebar never drew a channel row in 90 s")
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
        if element(app, "nativeChannelPane").waitForExistence(timeout: 10) {
            returnToSidebar(app)
        }
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
        if element(app, "nativeChannelPane").waitForExistence(timeout: 10) {
            returnToSidebar(app)
        }
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
}
