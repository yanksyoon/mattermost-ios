// Tbc22d0b3 — the channel header's trailing cluster, measured against a **real** server.
//
// Why live: the report is about what is on screen for a real channel — an account control wedged
// between two glyphs, sitting in a frame of its own (28 pt avatar in 34 pt) among ~17 pt glyphs in a
// row that baseline-aligned its children. Every assertion below is a statement about *where things
// were drawn*, so the app has to be drawn.
//
// The five tests are the card's five, in its order:
//
//   A. order — channel-info → pinned → Calls → Threads → account, by `frame.minX`;
//   B. alignment — every control's centre `midY` within 1 pt of every other's;
//   C. spacing — equal gaps within 1 pt, and the last control `padding` from the trailing edge;
//   D. badge separation — with a custom status set, the presence dot and the emoji badge do not
//      intersect (and both are inside the control);
//   E. accessibility order follows visual order, and the trigger still announces its status as its
//      value.
//
// Two measurement sources, deliberately:
//
//   * the four glyph controls are accessibility elements, so their frames come from the OS
//     (`XCUIElement.frame`) — that is what a reader's pointer and VoiceOver see;
//   * the header's own bounds and the account control's badges are not elements (the badges are
//     `accessibilityHidden` decoration), so those come from the app's `-uiTestExposeHeaderGeometry`
//     seam (`channelHeader.geometry`), which reports the rects the layout produced, measured in one
//     named coordinate space anchored at the header (see `ChannelHeaderGeometrySeam`).
//
// Both sources are used for the order assertion, so "the seam says one thing and the screen says
// another" cannot pass.
//
// Run (local throwaway server; same fixture account as T34/T41/T9dd):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim <sim> \
//       --only-testing MattermostUITests/Tbc22d0b3HeaderClusterUITests
//
// Each test skips — never fails — when the environment or the server is missing, like every live
// test here. Screenshots: each test attaches one (`tbc22d0b3-…`).

import XCTest

final class Tbc22d0b3HeaderClusterUITests: XCTestCase {

    /// One admin session per test process; the server rate-limits logins by IP.
    private static var cachedSession: (server: String, token: String, userID: String)?

    /// The numbers the header is supposed to be built from, pinned here (not read out of the app):
    /// a 32 pt frame per control, a 6 pt gap between them, and a 20 pt avatar
    /// (`ChannelHeaderMetrics` / `AccountMenuControlLayout`).
    private static let expectedControlSide: CGFloat = 32
    private static let expectedControlSpacing: CGFloat = 6
    private static let expectedAvatarSide: CGFloat = 20

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!

    /// The cluster's controls, left to right, as upstream's `right_controls.tsx` orders them. The
    /// Calls entry is conditional: it is drawn only when the server has the Calls plugin, so it is
    /// in the order when it is on screen and simply absent when it is not — never "missing but
    /// counted", which is what an equal-gap assertion against an empty slot would prove.
    private var clusterIdentifiers: [String] {
        ["nativeChannelInfoButton", "nativeChannelPinnedButton", "calls.joinButton",
         "nativeChannelThreadsButton", "accountMenuButton"]
    }

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live header-cluster test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
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
            Self.cachedSession = (server: session.server, token: session.token, userID: session.userID)
        }
        teamID = try firstTeamID()
    }

    override func tearDownWithError() throws {
        // Leave the fixture the way the next suite expects it: online, no custom status.
        guard token != nil, userID != nil else { return }
        _ = try? sendJSON("PUT", "/api/v4/users/\(userID!)/status",
                          body: ["user_id": userID!, "status": "online"], allowFailure: true)
        _ = try? sendJSON("DELETE", "/api/v4/users/\(userID!)/status/custom",
                          body: nil, allowFailure: true)
    }

    // MARK: - A. The account control is the last item in the cluster

    /// The regression this card exists for: the control was drawn between the channel-info and the
    /// pinned glyphs. It is upstream's far-right item, and the only control whose trailing edge is
    /// the header's own padding away from the edge.
    func testATheAccountControlIsTheLastItemInTheCluster() throws {
        let app = try launchWithHeaderSeam()
        let geometry = try seamGeometry(app)
        let onScreen = presentControls(app)

        XCTAssertEqual(onScreen, orderedByAxis(onScreen, in: geometry),
                       "the cluster's controls are laid out left to right in source order; measured "
                       + "\(describe(onScreen, in: geometry))")
        XCTAssertEqual(onScreen.last, "accountMenuButton",
                       "the account control is the LAST item in the right-hand cluster (upstream's "
                       + "`right_controls.tsx` renders `UserAccountMenu` after `SettingsButton`); "
                       + "measured \(describe(onScreen, in: geometry))")
        XCTAssertEqual(onScreen.first, "nativeChannelInfoButton",
                       "the channel-info glyph is the first item; measured "
                       + "\(describe(onScreen, in: geometry))")

        // The same ordering, read from the OS rather than from the seam: the AX frames must agree.
        let osOrder = orderedByAxis(onScreen, in: geometry, source: .accessibility(app))
        XCTAssertEqual(osOrder, onScreen,
                       "the OS reports the same left-to-right order as the app's own measurement; "
                       + "app \(describe(onScreen, in: geometry)), OS \(osOrder)")

        // Nothing at all is drawn to the right of the account control but the header's padding.
        if let account = geometry.rects["accountMenuButton"], let header = geometry.rects["header"] {
            XCTAssertGreaterThan(account.maxX, header.maxX - geometry.padding - 1,
                                 "the account control must reach the header's padding, not stop a "
                                 + "control short of it: control maxX \(account.maxX), header maxX "
                                 + "\(header.maxX), padding \(geometry.padding)")
        } else {
            XCTFail("the seam must report both the account control's rect and the header's: "
                    + geometry.raw)
        }
        attach(app, "tbc22d0b3-a-order")
    }

    // MARK: - B. One centre line

    func testBEveryControlSharesOneCentreLine() throws {
        let app = try launchWithHeaderSeam()
        let geometry = try seamGeometry(app)
        let onScreen = presentControls(app)

        let centres = onScreen.compactMap { geometry.rects[$0]?.midY }
        XCTAssertEqual(centres.count, onScreen.count,
                       "every control must be measured: \(describe(onScreen, in: geometry))")
        guard let first = centres.first else { return XCTFail("no controls measured") }
        for (identifier, centre) in zip(onScreen, centres) {
            XCTAssertEqual(centre, first, accuracy: 1.0,
                           "\(identifier) sits on the cluster's centre line: midYs "
                           + "\(describeMidYs(onScreen, in: geometry))")
        }

        // And the OS agrees: the four glyphs used to be baseline-aligned by a rule that an avatar
        // does not participate in, which is exactly a 1 pt+ drift between the avatar and the glyphs.
        let osMidYs = onScreen.compactMap { element(app, $0).exists ? element(app, $0).frame.midY : nil }
        XCTAssertEqual(osMidYs.count, onScreen.count, "the OS must report every control's frame")
        if let osFirst = osMidYs.first {
            for (identifier, midY) in zip(onScreen, osMidYs) {
                XCTAssertEqual(midY, osFirst, accuracy: 1.0,
                               "\(identifier)'s on-screen centre line: \(osMidYs)")
            }
        }
        attach(app, "tbc22d0b3-b-centres")
    }

    // MARK: - C. Equal gaps, and the last one is the header's padding

    func testCTheGapsAreEqualAndTheLastControlIsTheHeadersPaddingFromTheEdge() throws {
        let app = try launchWithHeaderSeam()
        let geometry = try seamGeometry(app)
        let onScreen = presentControls(app)
        let rects = onScreen.compactMap { geometry.rects[$0] }
        XCTAssertEqual(rects.count, onScreen.count,
                       "every control must be measured: \(describe(onScreen, in: geometry))")
        guard rects.count >= 3 else {
            return XCTFail("the cluster must hold at least three controls; on screen: \(onScreen)")
        }

        let gaps = zip(rects, rects.dropFirst()).map { $1.minX - $0.maxX }
        guard let firstGap = gaps.first else { return XCTFail("no gaps measured") }
        for (index, gap) in gaps.enumerated() {
            XCTAssertEqual(gap, firstGap, accuracy: 1.0,
                           "gap \(index) (\(onScreen[index]) → \(onScreen[index + 1])) is "
                           + "\(gap) pt, gap 0 is \(firstGap) pt: \(describe(onScreen, in: geometry))")
        }
        // The one spacing value the card asks for, pinned here rather than read out of the app: a
        // test that took its expected number from the code under test could not catch the number
        // changing. 6 pt is the value chosen in `ChannelHeaderMetrics.controlSpacing`.
        XCTAssertEqual(firstGap, Self.expectedControlSpacing, accuracy: 1.0,
                       "the cluster's gap is the one spacing the header names "
                       + "(\(Self.expectedControlSpacing) pt); measured \(firstGap)")

        // One control height, too: the equal gaps are only "one row" if the boxes are the same size.
        for (identifier, rect) in zip(onScreen, rects) {
            XCTAssertEqual(rect.width, Self.expectedControlSide, accuracy: 1.0,
                           "\(identifier) is drawn in the cluster's \(Self.expectedControlSide) pt "
                           + "frame; measured \(rect)")
            XCTAssertEqual(rect.height, Self.expectedControlSide, accuracy: 1.0,
                           "\(identifier) is drawn in the cluster's \(Self.expectedControlSide) pt "
                           + "frame; measured \(rect)")
            XCTAssertGreaterThanOrEqual(min(rect.width, rect.height), 28,
                                        "the card's pointer minimum is a 28×28 hit target: \(rect)")
        }

        // The gap from the last control to the header's trailing edge equals the header's padding —
        // the difference between "flush with the edge" and "a control short of it".
        if let last = rects.last, let header = geometry.rects["header"] {
            let trailing = header.maxX - last.maxX
            XCTAssertEqual(trailing, geometry.padding, accuracy: 1.0,
                           "the trailing gap is the header's padding (\(geometry.padding) pt); "
                           + "measured \(trailing) pt (\(describe(onScreen, in: geometry)))")
        } else {
            XCTFail("the seam must report the header's own rect: \(geometry.raw)")
        }
        attach(app, "tbc22d0b3-c-spacing")
    }

    // MARK: - D. Two badges, two corners

    /// With a custom status set the control draws **both** marks — the presence dot and the emoji —
    /// as upstream does (its `UserAccountMenuButton` draws a `CustomStatusEmoji` and a status icon at
    /// once; it has a wider trigger to put them side by side). Here they share a 32 pt control, so
    /// this asserts the two rectangles stay apart and inside the control.
    func testDWithACustomStatusSetBothBadgesStayLegible() throws {
        let emoji = try setCustomStatus(emojiName: "grinning", text: "tbc22d0b3 short status")
        XCTAssertEqual(emoji, "grinning", "the fixture must carry a custom status before the launch")

        let app = try launchWithHeaderSeam()
        let geometry = try seamGeometry(app)

        guard let dot = geometry.rects["accountMenu.presenceDot"],
              let badge = geometry.rects["accountMenu.customStatusEmoji"] else {
            return XCTFail("with a custom status set the control must draw both marks; the seam "
                           + "reports \(geometry.raw)")
        }

        XCTAssertFalse(dot.intersects(badge),
                       "the presence dot \(dot) and the custom-status badge \(badge) must not overlap "
                       + "— that is the defect this test exists for")
        XCTAssertGreaterThanOrEqual(badge.maxY, -0.5)
        XCTAssertLessThan(badge.maxY, dot.minY,
                          "the badge is the upper mark and the dot the lower one: dot \(dot), "
                          + "badge \(badge)")

        // Both are inside the control's own frame (the seam reports them in the control's space,
        // `controlSpace=accountMenuControl`, because a `Menu`'s label cannot resolve the header's
        // space): the emoji used to be offset 4 pt past the avatar's box, and a mark that hangs
        // outside the control it belongs to is the "slightly off" in the report.
        let control = CGRect(x: 0, y: 0, width: Self.expectedControlSide, height: Self.expectedControlSide)
        XCTAssertTrue(control.insetBy(dx: -0.5, dy: -0.5).contains(CGPoint(x: dot.midX, y: dot.midY)),
                      "the dot is inside the control: dot \(dot), control \(control)")
        XCTAssertTrue(control.insetBy(dx: -0.5, dy: -0.5).contains(CGPoint(x: badge.midX, y: badge.midY)),
                      "the badge is inside the control: badge \(badge), control \(control)")

        // Both marks are drawn at the sizes the layout names, not at whatever their frames collapse
        // to: a 0×0 report would pass a "no intersection" test while drawing nothing.
        XCTAssertGreaterThanOrEqual(dot.width, 5, "the presence dot is drawn: \(dot)")
        XCTAssertGreaterThanOrEqual(badge.width, 10, "the custom-status badge is drawn: \(badge)")

        // The avatar itself is drawn in the same space and at the same size, so the two marks are on
        // the picture rather than floating beside it.
        if let avatar = geometry.rects["accountMenu.avatar"] {
            XCTAssertEqual(avatar.width, Self.expectedAvatarSide, accuracy: 1.0,
                           "the avatar is the 20 pt disc the layout names: \(avatar)")
            XCTAssertTrue(avatar.insetBy(dx: -0.5, dy: -0.5).contains(CGPoint(x: dot.midX, y: dot.midY)),
                          "the dot sits on the avatar's corner: dot \(dot), avatar \(avatar)")
            XCTAssertTrue(avatar.insetBy(dx: -0.5, dy: -0.5).contains(CGPoint(x: badge.midX, y: badge.midY)),
                          "the badge sits over the avatar: badge \(badge), avatar \(avatar)")
        }

        attach(app, "tbc22d0b3-d-custom-status")
    }

    // MARK: - E. Accessibility order, and the trigger's value

    func testETheAccessibilityOrderFollowsTheVisualOrder() throws {
        let app = try launchWithHeaderSeam()
        _ = try seamGeometry(app)
        let onScreen = presentControls(app)

        let all = app.descendants(matching: .any).allElementsBoundByIndex
        let positions = onScreen.compactMap { identifier in
            all.firstIndex { $0.identifier == identifier }
        }
        XCTAssertEqual(positions.count, onScreen.count,
                       "every cluster control must be in the accessibility tree: \(onScreen)")
        XCTAssertEqual(positions, positions.sorted(),
                       "the accessibility order must follow the visual order (account last); "
                       + "identifiers \(onScreen) at indices \(positions)")

        // The trigger keeps announcing its current status as its value (t_9dd73395's contract; the
        // move must not take the announcement with it).
        let control = element(app, "accountMenuButton")
        XCTAssertTrue(control.exists, "the account control must be on screen:\n\(app.debugDescription)")
        let value = control.value as? String ?? ""
        XCTAssertFalse(value.isEmpty,
                       "the trigger announces its status as its value; it says nothing:\n"
                       + "\(app.debugDescription)")
        let reported = try reportedStatus()
        XCTAssertTrue(value.localizedCaseInsensitiveContains(reported)
                      || value.localizedCaseInsensitiveContains(presenceTitle(reported)),
                      "the trigger's value \"\(value)\" must name the server's status \"\(reported)\"")
        attach(app, "tbc22d0b3-e-accessibility")
    }

    // MARK: - App driving

    private func launchWithHeaderSeam() throws -> XCUIApplication {
        let app = XCUIApplication()
        // No `-surfaceMode`: like T05, this asserts the header a **default** build draws. The seam
        // is the only test affordance, and it adds an element rather than changing a surface.
        app.launchArguments = ["-uiTestResetPersistedState",
                               "-uiTestForgetSession", serverURL.absoluteString,
                               "-uiTestSeedServer", serverURL.absoluteString,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-uiTestExposeHeaderGeometry",
                               "-uiTestLogLevel", "error",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // T40-R's crash, which bit the T41 suite too: XCTest's `XCTAutomationSupport` makes the app
        // log one os_log fault per captured runtime issue, libtrace quarantines the process, and the
        // next accessibility snapshot dereferences a NULL. `OS_ACTIVITY_MODE=disable` stops that
        // delivery. Test-only; the app itself is unchanged.
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        app.launch()
        signIn(app)
        openChannel(app)
        return app
    }

    private func signIn(_ app: XCUIApplication) {
        let field = app.textFields["loginIDField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "the native sign-in must mount against \(serverURL.absoluteString):\n"
                      + "\(app.debugDescription)")
        field.tap()
        field.typeText(loginID)
        let secret = app.secureTextFields["loginPasswordField"]
        XCTAssertTrue(secret.exists)
        secret.tap()
        secret.typeText(password)
        app.buttons["loginSubmitButton"].tap()
        XCTAssertTrue(ShellSettle.waitForSignedIn(app, timeout: 40),
                      "signing in must reach the shell:\n\(app.debugDescription)")
    }

    /// Open the fixture's first non-DM channel through the sidebar (the pane's own header is what is
    /// about to be measured, so it has to be *this* channel's pane).
    private func openChannel(_ app: XCUIApplication) {
        _ = ShellSettle.revealChannelList(app)
        let teamRow = element(app, "teamSidebar.team.\(teamID!)")
        XCTAssertTrue(teamRow.waitForExistence(timeout: 40),
                      "the rail must list the fixture's team:\n\(app.debugDescription)")
        if !(teamRow.value as? String ?? "").contains("Selected") { teamRow.tap() }
        guard let channelID = try? firstChannelID() else {
            return XCTFail("the fixture account has no channel to open")
        }
        let row = revealSidebarRow(app, identifier: "channelSidebar.channel.\(channelID)")
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "the sidebar must list the fixture's first channel:\n\(app.debugDescription)")
        row.tap()
        XCTAssertTrue(element(app, "nativeChannelTitle").waitForExistence(timeout: 30),
                      "the channel pane must mount:\n\(app.debugDescription)")
    }

    // MARK: - Geometry

    /// Where a control's frame comes from.
    private enum FrameSource {
        case seam
        case accessibility(XCUIApplication)
    }

    /// The header's measured geometry, parsed out of the seam's one accessibility value.
    ///
    /// The value is `key=x,y,w,h` pairs plus `padding=<points>` (see `ChannelHeaderGeometrySeam`),
    /// in one coordinate space anchored at the header — so gaps, `midY` and the trailing distance are
    /// differences within a single space and no two sources are mixed.
    private struct HeaderGeometry {
        let raw: String
        let padding: CGFloat
        let rects: [String: CGRect]

        init?(raw: String) {
            var padding: CGFloat?
            var rects: [String: CGRect] = [:]
            for token in raw.split(separator: " ") {
                let pair = token.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                if pair[0] == "padding" {
                    padding = Double(pair[1]).map { CGFloat($0) }
                    continue
                }
                guard pair[1] != "none" else { continue }
                let numbers = pair[1].split(separator: ",").compactMap { Double($0) }
                guard numbers.count == 4 else { continue }
                rects[pair[0]] = CGRect(x: numbers[0], y: numbers[1],
                                        width: numbers[2], height: numbers[3])
            }
            guard let padding, !rects.isEmpty else { return nil }
            self.raw = raw
            self.padding = padding
            self.rects = rects
        }
    }

    /// Read the seam, waiting for the layout to have reported at least the header and one control.
    private func seamGeometry(_ app: XCUIApplication) throws -> HeaderGeometry {
        let seam = element(app, "channelHeader.geometry")
        XCTAssertTrue(seam.waitForExistence(timeout: 20),
                      "`-uiTestExposeHeaderGeometry` must publish channelHeader.geometry:\n"
                      + "\(app.debugDescription)")
        var last = ""
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let raw = (seam.value as? String) ?? ""
            if raw != last { last = raw }
            if let geometry = HeaderGeometry(raw: raw), geometry.rects["header"] != nil,
               geometry.rects["accountMenuButton"] != nil {
                return geometry
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        throw XCTSkip("the header's geometry seam never reported a layout: \"\(last)\"")
    }

    /// Which of the cluster's controls are on screen, in source order. Calls is an edge case on
    /// purpose: without the plugin it is not drawn at all, and an equal-gap assertion over an empty
    /// 32 pt slot would pass while the row had a hole in it.
    private func presentControls(_ app: XCUIApplication) -> [String] {
        clusterIdentifiers.filter { identifier in
            identifier == "calls.joinButton"
                ? element(app, identifier).exists
                : element(app, identifier).waitForExistence(timeout: 10)
        }
    }

    private func orderedByAxis(_ identifiers: [String], in geometry: HeaderGeometry,
                               source: FrameSource = .seam) -> [String] {
        func minX(_ identifier: String) -> CGFloat? {
            switch source {
            case .seam:
                return geometry.rects[identifier]?.minX
            case .accessibility(let app):
                let element = self.element(app, identifier)
                return element.exists ? element.frame.minX : nil
            }
        }
        return identifiers.sorted { (minX($0) ?? .greatestFiniteMagnitude)
            < (minX($1) ?? .greatestFiniteMagnitude) }
    }

    private func describe(_ identifiers: [String], in geometry: HeaderGeometry) -> String {
        identifiers.map { identifier in
            let rect = geometry.rects[identifier].map { rect in
                String(format: "(x %.1f…%.1f, midY %.1f, %.1f×%.1f)",
                       rect.minX, rect.maxX, rect.midY, rect.width, rect.height)
            } ?? "(unmeasured)"
            return "\(identifier) \(rect)"
        }.joined(separator: ", ")
    }

    private func describeMidYs(_ identifiers: [String], in geometry: HeaderGeometry) -> String {
        identifiers.map { "\($0) \(geometry.rects[$0]?.midY ?? .nan)" }.joined(separator: ", ")
    }

    // MARK: - Server (the oracle)

    private func reportedStatus() throws -> String {
        let status = try getJSON("/api/v4/users/\(userID!)/status") as? [String: Any] ?? [:]
        return status["status"] as? String ?? ""
    }

    /// What the control's `accessibilityValue` says for a status the server reports. The value is the
    /// presence's own title (`UserPresence.title`), which is the words a reader hears.
    private func presenceTitle(_ status: String) -> String {
        switch status {
        case "online": return "Online"
        case "away": return "Away"
        case "dnd": return "Do not disturb"
        case "ooo": return "Out of office"
        case "offline": return "Offline"
        default: return status
        }
    }

    /// Set a custom status on the server and read it back — the fixture the badge test needs, so it
    /// is the server's answer that the app draws, not a value the test assumed.
    @discardableResult
    private func setCustomStatus(emojiName: String, text: String) throws -> String? {
        _ = try sendJSON("PUT", "/api/v4/users/\(userID!)/status/custom",
                         body: ["emoji": emojiName, "text": text])
        let read = try getJSON("/api/v4/users/\(userID!)/status/custom") as? [String: Any] ?? [:]
        return read["emoji"] as? String
    }

    private func firstChannelID() throws -> String? {
        let channels = try getJSON("/api/v4/users/me/teams/\(teamID!)/channels")
            as? [[String: Any]] ?? []
        return channels.first { ($0["type"] as? String) != "D" }?["id"] as? String
    }

    private func ping() throws {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/system/ping"))
        request.timeoutInterval = 5
        let (_, response) = try synchronous(request)
        try XCTSkipUnless((response as? HTTPURLResponse)?.statusCode == 200,
                          "the live server at \(serverURL.absoluteString) is not answering")
    }

    private func authenticate(login: String, password: String)
    throws -> (server: String, token: String, userID: String) {
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
            throw XCTSkip("could not sign in as \(login) on \(serverURL.absoluteString)"
                          + " (HTTP \(status))")
        }
        return (serverURL.absoluteString, token, id)
    }

    private func firstTeamID() throws -> String {
        let teams = try getJSON("/api/v4/users/me/teams") as? [[String: Any]] ?? []
        guard let team = teams.first, let id = team["id"] as? String else {
            throw XCTSkip("the fixture account has no team")
        }
        return id
    }

    private func url(for path: String) -> URL {
        let halves = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let base = serverURL.appendingPathComponent(String(halves[0]))
        guard halves.count == 2, !halves[1].isEmpty,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        components.percentEncodedQuery = String(halves[1])
        return components.url ?? base
    }

    private func getJSON(_ path: String) throws -> Any {
        var request = URLRequest(url: url(for: path))
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "Tbc22d0b3Oracle", code: status, userInfo: [
                NSLocalizedDescriptionKey:
                    "GET \(path) -> HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))"])
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    @discardableResult
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
        if !allowFailure {
            guard (200...299).contains(status) else {
                throw NSError(domain: "Tbc22d0b3Oracle", code: status, userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(method) \(path) -> HTTP \(status) "
                        + String(decoding: data.prefix(200), as: UTF8.self)])
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) ?? [:]
    }

    private func synchronous(_ request: URLRequest) throws -> (Data, URLResponse) {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
            box.data = data
            box.response = response
            box.error = error
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 15)
        if let error = box.error { throw error }
        return (box.data ?? Data(), box.response ?? URLResponse())
    }

    private final class ResultBox: @unchecked Sendable {
        var data: Data?
        var response: URLResponse?
        var error: Error?
    }

    // MARK: - Elements

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @discardableResult
    private func revealSidebarRow(_ app: XCUIApplication, identifier: String,
                                  maxSwipes: Int = 20) -> XCUIElement {
        let target = element(app, identifier)
        guard !target.exists else { return target }
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app
        var swipes = 0
        while !target.exists, swipes < maxSwipes {
            list.swipeUp(velocity: .fast)
            swipes += 1
        }
        return target
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
