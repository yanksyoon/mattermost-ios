// t_05caa678 — the channel screen's header, channel info and bookmarks bar, against a **real**
// Mattermost server.
//
// Why live: the owner's report is about what is on screen for a real channel on a real server (a
// header that is not drawn, an info control that is gated off, a bar that does not exist), and the
// interesting half of the bookmarks rule is the server's own answer — the pinned 9.11.19 Team
// Edition fixture refuses `GET /channels/{id}/bookmarks` with a 404, so "no bar, nothing else
// touched" is a statement only this server can make.
//
// **The launch arguments matter.** Tests A–D pass **no `-surfaceMode` at all**. That is the point:
// the reported defect was that the surfaces resolved to what a Release build gets, and a test that
// asked for `channelInfo=native` would pass while the shipped app drew nothing (which is exactly
// how T40's flip was missed). The only arguments are the DEBUG seeding seams a UI test needs to sign
// in; surface resolution is left at its default.
//
// The one exception is `testE`, which passes `-surfaceMode channelInfo=web` **on purpose**: it is not
// testing the default, it is re-creating the pre-fix gate (`.channelInfo` was unapproved, so the
// resolver answered `web`) and dumping what that draws.
//
// Run:
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim <sim> \
//       --only-testing MattermostUITests/T05ChannelHeaderUITests
//
// Each test skips — never fails — when the environment or the server is missing, like every live
// test here.
//
// Where the bookmarks rules are asserted:
//   * **offline**, in `MattermostTests/T05ChannelBookmarksTests.swift` — sort order, the 404/empty/
//     failure states, one fetch per appearance, the chip's URL rule;
//   * **live here**, against the real 9.11.19 server — the 404 case, because only that server can
//     answer 404 for the route, and the header/sheet/premise around it;
//   * **live here against a transport fixture** — `testD…`, the 200 case, because no server on this
//     host serves the route: `scripts/t05_bookmarks_proxy.py` answers `GET /channels/{id}/bookmarks`
//     and forwards everything else, so the bar's order, placement and fetch count are read off the
//     screen rather than simulated.
//
// The AX dumps are produced by the run (`dumpAccessibilityTree`), including one taken with the info
// sheet already open, because the card asks for the sheet title in the dump and not only in an
// assertion.

import XCTest

final class T05ChannelHeaderUITests: XCTestCase {

    /// One admin session per test process: the server rate-limits logins by IP.
    private static var cachedSession: (server: String, token: String, userID: String)? = nil

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!
    /// The channel a test created; deleted in `tearDown`.
    private var createdChannelID: String?

    /// The sidebar sorts by display name; a leading digit keeps the created row at the top.
    private let channelNamePrefix = "0-t05-header-"

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live channel-header test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        if let cached = Self.cachedSession, cached.server == raw {
            token = cached.token
            userID = cached.userID
        } else {
            let session = try authenticate(login: loginID, password: password)
            token = session.token
            userID = session.userID
            Self.cachedSession = (server: raw, token: session.token, userID: session.userID)
        }
        teamID = try firstTeamID()
    }

    override func tearDownWithError() throws {
        if let id = createdChannelID {
            _ = try? sendJSON("DELETE", "/api/v4/channels/\(id)", body: nil, allowFailure: true)
            createdChannelID = nil
        }
    }

    // MARK: - 1. The header and its control are on the default surface

    /// The reported defect: the title's info control was gated on a surface that was never approved
    /// native, so on a default build the only way into channel info was not drawn. This asserts the
    /// whole path with **no surface flag**: the pane mounts, the title is the control, the glyph is
    /// there, and the sheet opens with the server's own channel.
    func testATheHeaderAndItsControlsAreOnTheDefaultSurface() throws {
        let channel = try makeChannel()
        let app = launchApp()
        openChannel(app, channel: channel)

        let title = element(app, "nativeChannelTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 30),
                      "the channel pane must draw its header on the default surface:\n\(app.debugDescription)")
        // T40-AV F4 proved the title is the **display name**; this re-proves it where the report is
        // (a default launch) and with a channel whose name and display name differ.
        XCTAssertTrue(waitUntil(timeout: 20) { title.label == channel.displayName },
                      "the header must show the display name \"\(channel.displayName)\", not the URL "
                      + "slug \"\(channel.name)\"; it says \"\(title.label)\"")
        XCTAssertTrue(element(app, "nativeChannelInfoButton").waitForExistence(timeout: 20),
                      "the channel-info control must be drawn on the default surface — the gate was "
                      + "the reported defect:\n\(app.debugDescription)")

        dumpAccessibilityTree(app, named: "channel-header-default-surface")

        // The whole title is the tap target (upstream's `onTitlePress`), not only the small glyph.
        title.tap()
        XCTAssertTrue(element(app, "channelInfo.sheet").waitForExistence(timeout: 20),
                      "tapping the channel header must open the channel details:\n\(app.debugDescription)")
        let sheetTitle = element(app, "channelInfo.title")
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 20),
                      "the sheet must fill with the channel's overview:\n\(app.debugDescription)")
        XCTAssertTrue(sheetTitle.label.contains(channel.displayName),
                      "the sheet must name the channel: it says \"\(sheetTitle.label)\"")
        XCTAssertTrue(element(app, "channelInfo.action.members").waitForExistence(timeout: 20),
                      "the overview must offer the member list:\n\(app.debugDescription)")
        // Dumped **with the sheet open**: the card's evidence line names the sheet title, so the
        // dump has to contain `channelInfo.title`, not only an assertion about it.
        dumpAccessibilityTree(app, named: "channel-info-sheet-open")
        attach(app, "01-header-and-info")
    }

    // MARK: - 2. Both entries open the same sheet, once

    /// The title tap and the info glyph are the same destination, and neither presents a second
    /// sheet on top of the first: one press, one sheet, and after a dismissal the other entry works.
    func testBTheHeaderTapAndTheGlyphOpenTheSameSheetOnce() throws {
        let channel = try makeChannel()
        let app = launchApp()
        openChannel(app, channel: channel)

        let title = element(app, "nativeChannelTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 30))
        let glyph = element(app, "nativeChannelInfoButton")
        XCTAssertTrue(glyph.waitForExistence(timeout: 20))

        func sheetCount() -> Int {
            app.descendants(matching: .any).matching(identifier: "channelInfo.sheet").count
        }

        // 1. The title.
        title.tap()
        XCTAssertTrue(element(app, "channelInfo.sheet").waitForExistence(timeout: 20),
                      "the header tap must present the info sheet:\n\(app.debugDescription)")
        XCTAssertEqual(sheetCount(), 1, "one presentation, not a stack of them")
        tapControl(app, "channelInfo.done")
        XCTAssertTrue(waitUntil(timeout: 15) { sheetCount() == 0 },
                      "Done must dismiss the sheet:\n\(app.debugDescription)")

        // 2. The glyph — same screen, still one presentation.
        glyph.tap()
        XCTAssertTrue(element(app, "channelInfo.sheet").waitForExistence(timeout: 20),
                      "the info glyph must present the same sheet:\n\(app.debugDescription)")
        XCTAssertEqual(sheetCount(), 1, "one presentation, not a stack of them")
        XCTAssertTrue(element(app, "channelInfo.title").label.contains(channel.displayName),
                      "the second entry must open the same channel's sheet")
        attach(app, "02-both-entries-one-sheet")
    }

    // MARK: - 3. A server without the bookmarks route

    /// The fixture answers 404 for the bookmarks route. The card's rule: that is not an error state.
    /// The bar is absent and takes no height, the header and the post list are untouched, and the
    /// info sheet still draws its overview — nothing on screen pays for a feature the server lacks.
    func testCA404OnBookmarksLeavesTheHeaderAndTheSheetIntact() throws {
        let channel = try makeChannel()
        // The premise, measured rather than assumed: if this server ever grows the route, this test
        // is about nothing and must say so instead of passing for the wrong reason.
        let (status, body) = try rawCall("GET", "/api/v4/channels/\(channel.id)/bookmarks")
        try XCTSkipUnless(status == 404,
                          "this fixture answers \(status) for the bookmarks route (\(body.prefix(120))) — "
                          + "the 404 rule needs a server build without it")

        let app = launchApp()
        openChannel(app, channel: channel)

        let title = element(app, "nativeChannelTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 30))
        XCTAssertTrue(waitUntil(timeout: 20) { element(app, "channelPostList").exists },
                      "the post list must mount:\n\(app.debugDescription)")
        XCTAssertFalse(element(app, "channelBookmarks.bar").exists,
                       "a 404 must draw no bar at all:\n\(app.debugDescription)")
        XCTAssertFalse(element(app, "channelBookmarks.error").exists,
                       "a 404 must not draw an error state")
        XCTAssertFalse(element(app, "channelBookmarks.empty").exists,
                       "a 404 must not draw an empty box")

        // Zero height: the post list begins within the header's own block, not 48pt lower.
        let headerBottom = title.frame.maxY
        let postTop = element(app, "channelPostList").frame.minY
        XCTAssertLessThan(postTop - headerBottom, 48,
                          "the absent bar must take no height (header ends \(headerBottom), "
                          + "the post list starts \(postTop)):\n\(app.debugDescription)")
        XCTAssertTrue(title.isHittable, "the header must stay hittable")
        dumpAccessibilityTree(app, named: "channel-header-bookmarks-404")

        // The sheet is not affected either: overview rows are there, bookmarks are not in it.
        title.tap()
        XCTAssertTrue(element(app, "channelInfo.sheet").waitForExistence(timeout: 20),
                      "the info sheet must still open:\n\(app.debugDescription)")
        XCTAssertTrue(element(app, "channelInfo.title").waitForExistence(timeout: 20),
                      "the sheet's overview must render:\n\(app.debugDescription)")
        XCTAssertTrue(element(app, "channelInfo.action.members").waitForExistence(timeout: 20),
                      "the sheet's members row must render:\n\(app.debugDescription)")
        XCTAssertFalse(element(app, "channelInfo.action.bookmarks").exists,
                       "bookmarks belong to the header's bar, not to channel info (upstream has one place)")
        XCTAssertFalse(element(app, "channelInfo.bookmarks").exists,
                       "the info sheet must not carry a bookmarks section")
        dumpAccessibilityTree(app, named: "channel-info-sheet-404")
        attach(app, "03-bookmarks-404")
    }

    // MARK: - 4. A server that has bookmarks (a transport fixture)

    /// The 200 half of the rule, against a proxy that answers the route the pinned build lacks.
    ///
    /// The fixture's `sort_order`s are 30 / 10 / 20 while its ids and names are in other orders, so
    /// this can only pass by drawing the server's own order. It also asserts the bar's **place**
    /// (under the header, above the post list), one fetch per appearance, and that tapping a chip
    /// does not take the pane (and therefore the bar) away.
    func testDABookmarks200DrawsTheBarInServerOrder() throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["MM_BOOKMARKS_SERVER"], let proxy = URL(string: raw) else {
            throw XCTSkip("set TEST_RUNNER_MM_BOOKMARKS_SERVER to the t05_bookmarks_proxy.py URL "
                          + "(the pinned 9.11.19 fixture has no bookmarks route)")
        }
        let fixture = try fixtureBookmarks(on: proxy)
        // The premise: the fixture's array order is **not** sort order, so the screen cannot pass by
        // drawing what arrived.
        XCTAssertEqual(fixture.map(\.sortOrder), [30, 10, 20],
                       "the fixture's array order must differ from its sort order")
        XCTAssertEqual(fixture.sorted { $0.sortOrder < $1.sortOrder }.map(\.sortOrder), [10, 20, 30])

        let channel = try makeChannel()
        let app = launchApp(at: proxy)
        openChannel(app, channel: channel)

        let bar = element(app, "channelBookmarks.bar")
        XCTAssertTrue(bar.waitForExistence(timeout: 30),
                      "a 200 must draw the bar:\n\(app.debugDescription)")
        dumpAccessibilityTree(app, named: "channel-header-bookmarks-200")

        // The server's order, read off the screen: chips left to right.
        let chips = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "channelBookmark."))
        XCTAssertTrue(waitUntil(timeout: 15) { chips.count == fixture.count },
                      "the bar must draw every bookmark (\(fixture.count)):\n\(app.debugDescription)")
        var drawn: [(id: String, x: CGFloat)] = []
        for index in 0..<chips.count {
            let chip = chips.element(boundBy: index)
            drawn.append((chip.identifier, chip.frame.minX))
        }
        drawn.sort { $0.x < $1.x }
        let expected = fixture.sorted { $0.sortOrder < $1.sortOrder }.map { "channelBookmark.\($0.id)" }
        XCTAssertEqual(drawn.map(\.id), expected,
                       "the bar must draw the server's sort_order, not its array order or the names")

        // Its place: the header above it, the post list below it.
        let title = element(app, "nativeChannelTitle")
        XCTAssertTrue(title.exists)
        let barTop = bar.frame.minY
        let postTop = element(app, "channelPostList").frame.minY
        XCTAssertGreaterThanOrEqual(barTop, title.frame.maxY - 1,
                                    "the bar must sit below the header")
        XCTAssertLessThanOrEqual(barTop, postTop, "the bar must sit above the post list")

        // One fetch for **this** channel's appearance. Counted per channel: the shell opens a channel
        // of its own on launch, and that pane's bar asking for *its* bookmarks is not this one asking
        // twice (the first run of this test read the app-wide total and failed on that other bar).
        let status = try fixtureStatus(on: proxy)
        let perChannel = status["bookmarks_requests_by_channel"] as? [String: Int] ?? [:]
        XCTAssertEqual(perChannel[channel.id], 1,
                       "this pane must ask once for its own channel; counters: \(status)")

        // A chip tap must not take the pane (or its bar) away. The target the chip opens is the
        // unit-tested `url(for:)` rule (http/https only) — this asserts the screen survives the tap,
        // which is the part only a live pane can show.
        let firstID = try XCTUnwrap(fixture.sorted { $0.sortOrder < $1.sortOrder }.first?.id)
        let first = element(app, "channelBookmark.\(firstID)")
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        app.activate()
        XCTAssertTrue(element(app, "channelBookmarks.bar").waitForExistence(timeout: 20),
                      "the bar must survive the tap and the pane staying open:\n\(app.debugDescription)")
        XCTAssertTrue(element(app, "nativeChannelTitle").exists, "the pane must stay where it was")
        attach(app, "04-bookmarks-200")
    }

    // MARK: - 5. The gate that caused the report, forced off

    /// The reported defect's own code path, reproduced from the switch instead of from an old
    /// binary: at `7e269b1` `.channelInfo` was absent from `SurfaceDefaults.nativeApprovedSurfaces`,
    /// so `resolver.resolvedMode(for: .channelInfo)` answered `web` and
    /// `ChannelView.trailingControls` did not draw its `nativeChannelInfoButton`. Forcing that same
    /// answer here re-creates the gate and dumps it — which is the honest way to attach the
    /// pre-fix state: no build of the old tree was kept, and a dump of today's default build cannot
    /// show what the gate does.
    ///
    /// It also pins the other half of the fix: the title tap is **not** surface-gated, so even with
    /// the surface at `web` the pane still reaches channel details (with `.channelView` pane-owning
    /// there is no web client behind the pane to answer that tap).
    func testEForcingTheChannelInfoSurfaceToWebHidesTheGlyphNotTheEntry() throws {
        let channel = try makeChannel()
        let app = launchApp(surfaceModes: ["channelInfo=web"])
        openChannel(app, channel: channel)

        let title = element(app, "nativeChannelTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 30),
                      "the pane must still draw its header with the surface at web:\n\(app.debugDescription)")
        XCTAssertTrue(waitUntil(timeout: 20) { title.label == channel.displayName })
        XCTAssertFalse(element(app, "nativeChannelInfoButton").exists,
                       "with `.channelInfo` at web the glyph must not be drawn — this is the state the "
                       + "owner saw before the flip:\n\(app.debugDescription)")
        dumpAccessibilityTree(app, named: "channel-header-channelInfo-web")

        // The entry that a default build keeps, gate or no gate.
        title.tap()
        XCTAssertTrue(element(app, "channelInfo.sheet").waitForExistence(timeout: 20),
                      "the title tap must not be gated by the `.channelInfo` switch:\n\(app.debugDescription)")
        XCTAssertTrue(element(app, "channelInfo.title").waitForExistence(timeout: 20))
        dumpAccessibilityTree(app, named: "channel-info-sheet-channelInfo-web")
    }

    // MARK: - 6. The subtitle counts the channel's members (t_0f8e0eb2)

    /// The defect: the subtitle was the constant `View info`, so a channel with 40 members looked
    /// exactly like a direct message. Upstream (`app/screens/channel/header/header.tsx:255`) draws
    /// `"{count, plural, one {# member} other {# members}}"` and falls back only when there is no
    /// count.
    ///
    /// The **singular** is the number the server reports for a channel this test just created: one
    /// member, the signed-in account. It is read off the control's accessibility **value** — the
    /// subtitle lives inside an `.ignore` container, and the label is the display name that every
    /// other suite waits on (`nativeChannelTitle`), so the value is the only honest window onto it.
    ///
    /// The count is not a literal in the test: `makeChannel` creates the channel through the API and
    /// the app reads `GET /channels/{id}/stats`, so "1 member" is the server's answer to a question
    /// this test did not pre-answer.
    func testFTheSubtitleIsTheServersMemberCountNotAConstant() throws {
        let channel = try makeChannel()
        let app = launchApp()
        openChannel(app, channel: channel)

        let title = element(app, "nativeChannelTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 30),
                      "the pane must draw its header:\n\(app.debugDescription)")

        // The count arrives a beat after the title (it is a second request); the header shows the
        // `View info` fallback until then, which is upstream's own behaviour.
        XCTAssertTrue(waitUntil(timeout: 30) { (title.value as? String) == "1 member" },
                      "the header subtitle must be the server's member count for a one-member "
                      + "channel; it says \"\(title.value as? String ?? "nil")\".\n\(app.debugDescription)")

        // The AX label is untouched: this is the contract the other 20-odd suites wait on.
        XCTAssertEqual(title.label, channel.displayName,
                       "the subtitle must not change the control's name")
        dumpAccessibilityTree(app, named: "channel-header-member-count-singular")
        attach(app, "06-header-member-count")
    }

    /// The plural half, from the server rather than from a string in the test: a second account is
    /// added to a fresh channel **before** it is opened, so the pane's own load reads the count `2`.
    ///
    /// Skips when the fixture has no second account — the count path needs a real membership row, and
    /// inventing one here would be the kind of fixture the card is trying to stop trusting.
    func testGATwoMemberChannelSaysMembers() throws {
        let buddy = try buddyUserID()
        let channel = try makeChannel()
        _ = try postJSON("/api/v4/channels/\(channel.id)/members", body: ["user_id": buddy])

        // The server's own answer for the channel the test is about to open.
        let stats = try getJSON("/api/v4/channels/\(channel.id)/stats") as? [String: Any] ?? [:]
        XCTAssertEqual(stats["member_count"] as? Int, 2,
                       "the fixture channel must have two members before the header is read")

        let app = launchApp()
        openChannel(app, channel: channel)

        let title = element(app, "nativeChannelTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 30))
        XCTAssertTrue(waitUntil(timeout: 30) { (title.value as? String) == "2 members" },
                      "a two-member channel must say \"2 members\"; the header says "
                      + "\"\(title.value as? String ?? "nil")\".\n\(app.debugDescription)")
        dumpAccessibilityTree(app, named: "channel-header-member-count-plural")
    }

    // MARK: - App driving

    private func launchApp() -> XCUIApplication {
        launchApp(at: serverURL)
    }

    private func launchApp(at url: URL) -> XCUIApplication {
        launchApp(at: url, surfaceModes: [])
    }

    /// - Parameter surfaceModes: `-surfaceMode` pairs. **Empty for every test except `testE`**: the
    ///   reported defect was a default-surface gate, so a test that asked for the native surfaces
    ///   could not have caught it.
    private func launchApp(surfaceModes: [String]) -> XCUIApplication {
        launchApp(at: serverURL, surfaceModes: surfaceModes)
    }

    private func launchApp(at url: URL, surfaceModes: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-uiTestResetPersistedState",
                         "-uiTestForgetSession", url.absoluteString,
                         "-uiTestSeedServer", url.absoluteString,
                         "-uiTestSeedServerName", "Local Mattermost",
                         "-uiTestLogLevel", "error",
                         "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if !surfaceModes.isEmpty {
            arguments.append("-surfaceMode")
            arguments.append(contentsOf: surfaceModes)
        }
        app.launchArguments = arguments
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        app.launch()
        signIn(app)
        return app
    }

    private func signIn(_ app: XCUIApplication) {
        let field = app.textFields["loginIDField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "the native sign-in must mount against \(serverURL.absoluteString):\n\(app.debugDescription)")
        field.tap()
        field.typeText(loginID)
        let secret = app.secureTextFields["loginPasswordField"]
        XCTAssertTrue(secret.exists)
        secret.tap()
        secret.typeText(password)
        app.buttons["loginSubmitButton"].tap()
        let accept = app.buttons["termsOfServiceAcceptButton"]
        if accept.exists || accept.waitForExistence(timeout: 3) { accept.tap() }
        XCTAssertTrue(ShellSettle.waitForSignedIn(app, timeout: 40),
                      "signing in must reach the shell:\n\(app.debugDescription)")
    }

    /// Open a channel through the sidebar's own quick switcher.
    ///
    /// The fixture team holds several hundred channels, so scrolling the sidebar for a row is a
    /// gamble; the switcher is what a reader with a long sidebar uses, and it also proves the route
    /// carries the channel's **id** (the row the pane then opens is the one the server named).
    private func openChannel(_ app: XCUIApplication, channel: Channel) {
        let pops = ShellSettle.revealChannelList(app)
        let teamRow = element(app, "teamSidebar.team.\(teamID!)")
        XCTAssertTrue(teamRow.waitForExistence(timeout: 40),
                      "the rail must list the team (after \(pops) Back tap(s)):\n\(app.debugDescription)")
        if !(teamRow.value as? String ?? "").contains("Selected") { teamRow.tap() }

        tapControl(app, "channelSidebar.quickSwitcher")
        let field = app.textFields["channelSidebar.quickSwitcher.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "the switcher must mount:\n\(app.debugDescription)")
        field.tap()
        field.typeText(channel.name)
        let result = element(app, "channelSidebar.quickSwitcher.result.\(channel.id)")
        XCTAssertTrue(result.waitForExistence(timeout: 20),
                      "the switcher must offer #\(channel.name):\n\(app.debugDescription)")
        result.tap()
        // The pane must be showing **this** channel, not merely *a* channel: the launch restores the
        // last channel open, so "a title exists" passes while the pane still shows the previous one
        // (that is exactly how the first 200-bookmarks run failed — it asserted on the restored,
        // archived channel's pane).
        let title = element(app, "nativeChannelTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 30),
                      "the chosen channel must open in the pane:\n\(app.debugDescription)")
        if !waitUntil(timeout: 25, { title.label == channel.displayName }) {
            // One retry: a switcher row tapped while the keyboard animates can land on the keyboard.
            tapControl(app, "channelSidebar.quickSwitcher")
            if field.waitForExistence(timeout: 10) {
                field.tap()
                field.typeText(channel.name)
                let again = element(app, "channelSidebar.quickSwitcher.result.\(channel.id)")
                if again.waitForExistence(timeout: 15) { again.tap() }
            }
        }
        XCTAssertTrue(waitUntil(timeout: 25, { title.label == channel.displayName }),
                      "the pane must show #\(channel.name) ('\(channel.displayName)'), not "
                      + "'\(title.label)':\n\(app.debugDescription)")
    }

    /// The accessibility tree, printed and attached. The card requires this dump as evidence, so it
    /// is produced by the run rather than described afterwards.
    private func dumpAccessibilityTree(_ app: XCUIApplication, named name: String) {
        let dump = app.debugDescription
        print("===== AX DUMP \(name) BEGIN =====\n\(dump)\n===== AX DUMP \(name) END =====")
        let attachment = XCTAttachment(string: dump)
        attachment.name = "ax-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tapControl(_ app: XCUIApplication, _ identifier: String) {
        let typed = app.buttons.matching(identifier: identifier).firstMatch
        if typed.waitForExistence(timeout: 5), typed.isHittable {
            typed.tap()
            return
        }
        let fallback = element(app, identifier)
        if fallback.waitForExistence(timeout: 5) { fallback.tap() }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    // MARK: - Fixture and oracle

    private struct Channel {
        let id: String
        let name: String
        let displayName: String
    }

    /// One bookmark as the transport fixture serves it.
    private struct FixtureBookmark {
        let id: String
        let displayName: String
        let sortOrder: Int
    }

    /// What the fixture says it serves — the 200 test's oracle, read from the fixture itself so the
    /// test carries no copy of the list.
    private func fixtureBookmarks(on base: URL) throws -> [FixtureBookmark] {
        let rows = try getJSON("/__fixture/bookmarks", from: base) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return FixtureBookmark(id: id,
                                   displayName: row["display_name"] as? String ?? "",
                                   sortOrder: row["sort_order"] as? Int ?? 0)
        }
    }

    private func fixtureStatus(on base: URL) throws -> [String: Any] {
        try getJSON("/__fixture/status", from: base) as? [String: Any] ?? [:]
    }

    /// A channel whose display name is **not** its URL name, so "the header shows the display name"
    /// is a real assertion rather than a coincidence of the two being equal.
    ///
    /// The leading `0` also puts the row at the top of this fixture team's 350-odd sidebar rows.
    private func makeChannel() throws -> Channel {
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let name = channelNamePrefix + suffix
        let displayName = "0 T05 Header " + suffix
        let created = try postJSON("/api/v4/channels",
                                   body: ["team_id": teamID!,
                                          "name": name,
                                          "display_name": displayName,
                                          "type": "O",
                                          "purpose": "t05 header fixture"]) as? [String: Any] ?? [:]
        guard let id = created["id"] as? String else {
            throw XCTSkip("could not create the live test channel \(name)")
        }
        createdChannelID = id
        // One post, so the pane has a real conversation behind its header and the post list is a
        // list rather than an empty state.
        _ = try? postJSON("/api/v4/posts", body: ["channel_id": id, "message": "T05 header fixture"])
        return Channel(id: id, name: name, displayName: displayName)
    }

    /// The fixture's second account (`scripts/t43_notification_seed.py` creates `t43buddy`), by login.
    ///
    /// Used only by the plural case of the header subtitle: a count of two has to be a real
    /// membership row on the server, not a number this test wrote.
    private func buddyUserID() throws -> String {
        let json = (try? getJSON("/api/v4/users/username/t43buddy")) as? [String: Any]
        guard let id = json?["id"] as? String else {
            throw XCTSkip("t05 plural fixture: no `t43buddy` account on this server")
        }
        return id
    }

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
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let token = http.value(forHTTPHeaderField: "Token"),
              let user = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = user["id"] as? String else {
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])??["id"] as? String
            throw XCTSkip("could not sign in as \(login) on \(serverURL.absoluteString)"
                          + " (HTTP \(status), \(reason ?? "no error id"))")
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

    private func url(for path: String, base: URL? = nil) -> URL {
        let origin = base ?? serverURL!
        let halves = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let joined = origin.appendingPathComponent(String(halves[0]))
        guard halves.count == 2, !halves[1].isEmpty,
              var components = URLComponents(url: joined, resolvingAgainstBaseURL: false) else {
            return joined
        }
        components.percentEncodedQuery = String(halves[1])
        return components.url ?? joined
    }

    /// A call whose **status code** is the assertion (the 404 premise).
    private func rawCall(_ method: String, _ path: String) throws -> (Int, String) {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (data, response) = try synchronous(request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0,
                String(decoding: data.prefix(400), as: UTF8.self))
    }

    private func getJSON(_ path: String, from base: URL? = nil) throws -> Any {
        var request = URLRequest(url: url(for: path, base: base ?? serverURL))
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "T05Oracle", code: status, userInfo: [
                NSLocalizedDescriptionKey:
                    "GET \(path) -> HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))"])
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func postJSON(_ path: String, body: Any?) throws -> Any {
        try sendJSON("POST", path, body: body)
    }

    private func sendJSON(_ method: String, _ path: String, body: Any?,
                          allowFailure: Bool = false) throws -> Any {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !allowFailure, !(200...299).contains(status) {
            throw XCTSkip("\(method) \(path) answered \(status) — the fixture is not in the state "
                          + "this test needs")
        }
        guard !data.isEmpty, let json = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return json
    }

    /// The REST oracle's own session — **no cookie store** (a stale `MMAUTHTOKEN` cookie makes the
    /// server answer `session_expired` before it reads the request; measured across this suite family).
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
}
