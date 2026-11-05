// kanban t_fbc576a2 — the composer input, **live**: it grows, it stops at the cap, it scrolls, and
// the caret stays on screen.
//
// The unit suite (`MattermostTests/ComposerInputHeightTests`) drives the production
// `ComposerInputTextView` (a real `UITextView`) and pins T1–T7 at the measurement level. What it
// cannot see is the part the card is actually about: the **SwiftUI frame**. A field whose height is
// wrong in the assembled view still measures correctly on its own. So this suite types into the real
// composer, in the real shell, against a real server, and reads back what the field *did*:
//
//     -uiTestExposeComposerInputGeometry   ->  `channelComposer.inputGeometry`
//     accessibilityValue                   ->  "height=… content=… cap=… scrolls=0|1 caret=0|1"
//
// The value comes from `ComposerInputDiagnostics` in `ComposerInputHeight.swift`: the field's own
// measurement, its own `isScrollEnabled`, and the production `isCaretOnScreen` (the caret rectangle
// against the visible bounds). Nothing here re-derives "on screen" from a screenshot.
//
// Cases:
//   T1  one line            -> exactly the minimum, no scroller
//   T3  past the cap        -> exactly the cap, scroller on
//   T5  typing at the end   -> caret inside the visible rect, every keystroke
//   T4  draft restoration   -> a long draft is measured when it comes back, caret visible
//       Dynamic Type        -> the accessibility limits (56/220) re-measure without a relaunch gap
//   T7  window width        -> unit-level only: XCUITest cannot resize a Catalyst window reliably,
//                              and `ComposerInputTextView.layoutSubviews` is the event it would
//                              deliver (see `testANarrowerWidthReMeasuresTheHeight`).
//   T6  Shift+Return        -> unit-level only: the simulator has no hardware modifier. The live
//                              Return policy is untouched by this card and still sends (asserted by
//                              `channelComposer.send`'s presence, not by pressing Return, so this
//                              suite never posts a message).
//
// Run (local throwaway server; credentials come from the environment, never from this file):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim "id=<booted iPhone 16 Pro>" \
//       --only-testing MattermostUITests/ComposerInputHeightUITests
//
// Each test skips (never fails) when the server or the fixture is missing.

import XCTest

final class ComposerInputHeightUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID = ""
    private var password = ""
    private var token = ""
    private var teamID = ""
    private var channelID = ""

    /// An always-present channel on the `perf` fixture team; the composer is what is under test, not
    /// the list, so the town hall is the cheapest stable target.
    private let channelName = "town-square"

    /// A cookie-free session: `URLSession.shared` carries a stale `MMAUTHTOKEN` in its cookie jar on
    /// this host, which makes `POST /users/login` answer 401 (measured in T95's suite).
    private lazy var api: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live composer-height test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        let session = try authenticate(login: loginID, password: password)
        token = session.token
        let teams = try teamsForMe()
        guard let team = teams.first(where: { $0.name == "perf" }) else {
            throw XCTSkip("team #perf is missing — run scripts/perf_seed.py")
        }
        teamID = team.id
        channelID = try channel(named: channelName, in: teamID)
    }

    // MARK: - T1

    func testAOneLineComposerIsTheMinimumHeightAndDoesNotScroll() {
        let app = launch()
        signIn(app)
        let input = openComposer(app)
        input.tap()
        input.typeText("hello")

        let geometry = waitForGeometry(app) { $0.height == 34 && !$0.scrolls }
        XCTAssertEqual(geometry?.cap, 88,
                       "an iPhone is upstream's phone class: `isTablet ? 150 : 88`")
        XCTAssertEqual(geometry?.height, 34, "one line is the field's floor, was \(String(describing: geometry))")
        XCTAssertEqual(geometry?.scrolls, false, "a one-line field must not scroll")
        XCTAssertTrue(geometry?.caret == true, "the caret must be on screen: \(String(describing: geometry))")
        XCTAssertTrue(app.buttons["channelComposer.send"].exists,
                      "the send button's identifier must be unchanged")
        XCTAssertTrue(app.textViews["channelComposer.input"].exists,
                      "the input's identifier must be unchanged")
    }

    // MARK: - T3 + T5 (the everyday defect: typing at the end of a capped message)

    func testALongMessageStopsAtTheCapScrollsAndKeepsTheCaretVisible() {
        let app = launch()
        signIn(app)
        let input = openComposer(app)
        input.tap()
        // No newlines: Return sends (the card keeps that policy), so a long *wrapping* paragraph is
        // how a reader produces the same rendered line count without posting anything.
        let paragraph = longParagraph(lines: 40)
        type(paragraph, into: input)
        // `hasSuffix` rather than equality: a draft the reader left here survives a relaunch, and a
        // `MM_KEEP_STATE` run starts on top of one. What matters is that every key of the paragraph
        // landed at the end of the field.
        XCTAssertTrue((input.value as? String)?.hasSuffix(paragraph) == true,
                      "the whole paragraph must have landed at the end of the field")

        let atCap = waitForGeometry(app) { $0.scrolls && $0.height == $0.cap }
        XCTAssertEqual(atCap?.height, atCap?.cap,
                       "past the cap the field is drawn at exactly the cap, was \(String(describing: atCap))")
        XCTAssertGreaterThan(atCap?.content ?? 0, atCap?.cap ?? .greatestFiniteMagnitude,
                             "…while its text is taller than the cap")
        XCTAssertEqual(atCap?.scrolls, true, "the field must scroll internally past the cap")
        XCTAssertTrue(atCap?.caret == true,
                      "typing at the end of a capped message must leave the caret visible: "
                      + "\(String(describing: atCap))")

        // The claim is per keystroke, not once: type a few more characters *at the end* and re-read.
        for _ in 0..<3 {
            input.typeText("x")
            let after = waitForGeometry(app) { $0.caret && $0.scrolls }
            XCTAssertTrue(after?.caret == true,
                          "every further character must keep the caret on screen: "
                          + "\(String(describing: after))")
            XCTAssertEqual(after?.height, after?.cap, "the field stays at the cap")
        }
    }

    // MARK: - Draft restoration (requirement 4)

    func testALongRestoredDraftIsMeasuredAndItsCaretIsVisible() {
        let app = launch()
        signIn(app)
        let input = openComposer(app)
        input.tap()
        let paragraph = longParagraph(lines: 40)
        type(paragraph, into: input)
        XCTAssertEqual(waitForGeometry(app) { $0.scrolls }?.scrolls, true,
                       "precondition: the typed draft is past the cap")

        // Let the draft write (it is per keystroke) land, then relaunch the way a reader would: no
        // reset, no forgotten session — the draft has to come back from disk.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        app.terminate()
        let relaunched = launch(reset: false, forgetSession: false)
        XCTAssertTrue(ShellSettle.waitForSignedIn(relaunched, timeout: 60),
                      "the relaunch must come back signed in")
        let restored = openComposer(relaunched)
        XCTAssertEqual(restored.value as? String, paragraph,
                       "the draft must be restored verbatim")

        let geometry = waitForGeometry(relaunched) { $0.scrolls && $0.height == $0.cap }
        XCTAssertEqual(geometry?.height, geometry?.cap,
                       "a restored long draft must be measured, not left at the previous height: "
                       + "\(String(describing: geometry))")
        XCTAssertEqual(geometry?.scrolls, true, "…and it must scroll")
        XCTAssertTrue(geometry?.caret == true,
                      "the restored caret must be visible: \(String(describing: geometry))")
    }

    // MARK: - Dynamic Type (requirement 4)

    func testAccessibilityTextSizesUseTheAccessibilityLimits() throws {
        // AX1 rather than AX5: the sign-in form has to stay reachable for the fixture account, and
        // every accessibility size maps to the same 56/220 pair, which is what this case is about.
        let app = launch(dynamicType: "UICTContentSizeCategoryAccessibilityM")
        signIn(app)
        let input = openComposer(app)
        input.tap()
        input.typeText("hello")

        // The simulator does not always honour the override; a run without it must not be read as a
        // pass, so this is an explicit skip rather than a relaxed assertion.
        let first = waitForGeometry(app) { _ in true }
        try XCTSkipUnless(first?.cap == 220,
                          "the simulator did not apply -UIPreferredContentSizeCategoryName "
                          + "(cap=\(first?.cap ?? -1)); unit test `testChangingTheLimitsReMeasuresTheSameText` "
                          + "covers the same production path")

        let geometry = waitForGeometry(app) { $0.cap == 220 }
        XCTAssertEqual(geometry?.height, 56, "an AX one-liner sits on the accessibility floor: "
                       + "\(String(describing: geometry))")
        XCTAssertEqual(geometry?.scrolls, false)
        XCTAssertTrue(geometry?.caret == true)
    }

    // MARK: - Launching

    /// Surfaces are forced native, geometry is exposed, and the launch is **already signed in** with
    /// the fixture's real session token (`-uiTestSeedStoredToken`) and pointed at the fixture channel
    /// by a real deep link (`-uiTestOpenDeepLink`, the app's own seam — T4g uses the same pair).
    ///
    /// The sign-in form is deliberately not driven here: this suite is about the composer, and at an
    /// accessibility text size the login form's own layout is a different card's problem — a failure
    /// there would report as "the composer is broken".
    ///
    /// The draft test's second launch keeps both the session and the draft database (`reset: false`,
    /// `forgetSession: false`) and re-opens the same channel by deep link.
    private func launch(reset: Bool = true, forgetSession: Bool = true,
                        dynamicType: String? = nil) -> XCUIApplication {
        // A Release build ignores the Debug-only seeding seams (`-uiTestSeedServer`,
        // `-uiTestSeedStoredToken`), so a *reset* Release launch is a genuine first run: onboarding,
        // then the add-server form, then sign-in. `MM_KEEP_STATE=1` (set by the Release run) keeps the
        // server and session the Debug suite already established on this simulator instead, which is
        // the same state a returning reader's launch has.
        let keepsState = ProcessInfo.processInfo.environment["MM_KEEP_STATE"] == "1"
        let reset = reset && !keepsState
        let forgetSession = forgetSession && !keepsState
        let app = XCUIApplication()
        var arguments: [String] = []
        if reset { arguments.append("-uiTestResetPersistedState") }
        if forgetSession {
            arguments.append(contentsOf: ["-uiTestForgetSession", serverURL.absoluteString])
        }
        arguments.append(contentsOf: ["-uiTestSeedServer", serverURL.absoluteString,
                                      "-uiTestSeedServerName", "Local Mattermost",
                                      "-uiTestSeedStoredToken", token,
                                      // The channel **id**, not its name: a name-only link has to be
                                      // resolved through the shell's channel list first, and at an
                                      // accessibility text size the pane sat on "Resolving this
                                      // channel…" for the whole launch (measured in this suite). The
                                      // id form is upstream's own (`/channels/<26-char id>`).
                                      "-uiTestOpenDeepLink",
                                      "\(serverURL.absoluteString)/perf/channels/\(channelID)",
                                      "-uiTestExposeComposerInputGeometry"])
        if let dynamicType {
            arguments.append(contentsOf: ["-UIPreferredContentSizeCategoryName", dynamicType])
        }
        arguments.append(contentsOf: ["-surfaceMode", "shell=native",
                                      "-surfaceMode", "auth=native",
                                      "-surfaceMode", "sidebar=native",
                                      "-surfaceMode", "composer=native",
                                      "-AppleLanguages", "(en)", "-AppleLocale", "en_US"])
        app.launchArguments = arguments
        app.launch()
        return app
    }

    /// The seeded session has to reach the shell before anything is queried.
    ///
    /// Both seams it relies on (`-uiTestSeedStoredToken`, `-uiTestOpenDeepLink`) are Debug-only, so a
    /// **Release** run of this suite lands on the sign-in form instead and types the same fixture
    /// credentials. That is the only difference between the two configurations; the composer, the
    /// measurement and the seam are the same code.
    private func signIn(_ app: XCUIApplication) {
        // A Release launch that was reset starts on the onboarding carousel before the server form;
        // a Debug launch skips it because the seeded token is already in the vault. Both steps are
        // conditional: the `addServerToolbarButton` is part of the shell's chrome and exists even
        // when a server is seeded, so tapping it unconditionally would open (and leave up) the
        // add-server sheet over the composer.
        let getStarted = app.buttons["getStartedWelcomeScreen"]
        if getStarted.waitForExistence(timeout: 3) {
            getStarted.tap()
        }
        // `-uiTestSeedServer` is Debug-only too, so a Release launch has to add the fixture server
        // through the real form. `Save` runs the production URL probe: this is the shipping path.
        if app.textFields["Server URL"].waitForExistence(timeout: 3) {
            let urlField = app.textFields["Server URL"]
            urlField.tap()
            urlField.typeText(serverURL.absoluteString)
            app.buttons["Save"].tap()
        }
        let field = app.textFields["loginIDField"]
        if field.waitForExistence(timeout: 30) {
            field.tap()
            field.typeText(loginID)
            let secret = app.secureTextFields["loginPasswordField"]
            XCTAssertTrue(secret.waitForExistence(timeout: 10),
                          "the sign-in form must offer its password field:\n\(app.debugDescription)")
            secret.tap()
            secret.typeText(password)
            app.buttons["loginSubmitButton"].tap()
            ShellSettle.revealChannelList(app)
        }
        XCTAssertTrue(ShellSettle.waitForSignedIn(app, timeout: 60),
                      "the session must reach the shell:\n\(app.debugDescription)")
    }

    /// Reach the fixture channel and return its input, failing with the tree when the input is not
    /// there.
    ///
    /// A signed-in launch already opens a channel (the saved one, else the team's town hall), so the
    /// composer is usually on screen without any navigation — give it that chance first. At an
    /// accessibility text size the sidebar's rows sit off-screen and a `Back` tap from the pane can
    /// land on the **server list** instead of the channel list, which is a state no assertion here can
    /// recover from; this method therefore never navigates unless the composer really is absent.
    @discardableResult
    private func openComposer(_ app: XCUIApplication) -> XCUIElement {
        let input = inputElement(app)
        if input.waitForExistence(timeout: 45) { return input }

        ShellSettle.revealChannelList(app)
        let reveal = ShellSettle.revealSidebarChannel(app, channelID: channelID)
        let row = reveal.row
        if row.waitForExistence(timeout: 60) {
            row.tap()
        }
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 60),
                      "the channel pane must mount:\n\(app.debugDescription)")
        XCTAssertTrue(input.waitForExistence(timeout: 40),
                      "the composer input must mount:\n\(app.debugDescription)")
        return input
    }

    /// The composer's text input. A `UITextView` bridge, so it is a `.textView` — with a fallback to
    /// any element, because SwiftUI's representable wrapping has changed type between OS versions.
    private func inputElement(_ app: XCUIApplication) -> XCUIElement {
        let textView = app.textViews["channelComposer.input"]
        if textView.exists { return textView }
        return element(app, "channelComposer.input")
    }

    /// Type in chunks so a long paragraph does not have to be one synthesized event; the field
    /// re-measures on each edit anyway, which is what is being proved.
    private func type(_ text: String, into input: XCUIElement) {
        let chunkSize = 240
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            input.typeText(String(text[index..<end]))
            index = end
        }
    }

    /// A paragraph that wraps to roughly `lines` lines in a phone-width composer. Words only, no
    /// newlines (Return sends) and no trigger characters (`@ # : /` would open the autocomplete).
    private func longParagraph(lines: Int) -> String {
        let sentence = "the quick brown fox jumps over the lazy dog "
        // ~4.2 lines per 240 characters at a 402 pt `body` field; a little over is fine — the test
        // only cares that the text is past the cap.
        let repeats = max(1, Int(Double(lines) * 240 / 4.2 / Double(sentence.count)))
        return String(repeating: sentence, count: repeats)
    }

    // MARK: - The geometry seam

    private struct Geometry: CustomStringConvertible {
        var height: Double = 0
        var content: Double = 0
        var cap: Double = 0
        var scrolls = false
        var caret = false
        /// The seam's whole string, so a failure carries `offset`, `sel`, `len` and the caret rect
        /// instead of leaving the reader to re-derive them from a screenshot.
        var raw = ""

        var description: String { raw.isEmpty ? String(format: "height=%.1f content=%.1f cap=%.1f", height, content, cap) : raw }
    }

    private func readGeometry(_ app: XCUIApplication) -> Geometry? {
        let seam = element(app, "channelComposer.inputGeometry")
        guard seam.exists else { return nil }
        let raw = (seam.value as? String) ?? seam.label
        func number(_ key: String) -> Double? {
            guard let range = raw.range(of: "\(key)=") else { return nil }
            let rest = raw[range.upperBound...]
            let token = rest.prefix { $0.isNumber || $0 == "." || $0 == "-" }
            return Double(token)
        }
        guard let height = number("height"), let content = number("content"), let cap = number("cap")
        else { return nil }
        return Geometry(height: height, content: content, cap: cap,
                        scrolls: raw.contains("scrolls=1"), caret: raw.contains("caret=1"),
                        raw: raw)
    }

    /// Poll the seam until the predicate holds, returning the last reading either way (so the caller
    /// can put the real numbers in the failure message).
    private func waitForGeometry(_ app: XCUIApplication, timeout: TimeInterval = 60,
                                 matching predicate: (Geometry) -> Bool) -> Geometry? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: Geometry?
        while Date() < deadline {
            if let geometry = readGeometry(app) {
                last = geometry
                if predicate(geometry) { return geometry }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return last
    }

    // MARK: - Server access (the test is its own API client)

    private struct Team { let id: String; let name: String }

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
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let token = http.value(forHTTPHeaderField: "Token"),
              let user = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = user["id"] as? String else {
            throw XCTSkip("could not sign in as \(login) on the live server")
        }
        return (token, id)
    }

    private func teamsForMe() throws -> [Team] {
        let rows = try getJSON("/api/v4/users/me/teams") as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
            return Team(id: id, name: name)
        }
    }

    private func channel(named name: String, in team: String) throws -> String {
        let row = try getJSON("/api/v4/teams/\(team)/channels/name/\(name)") as? [String: Any]
        guard let id = row?["id"] as? String else {
            throw XCTSkip("channel #\(name) is missing on the live server")
        }
        return id
    }

    private func getJSON(_ pathWithQuery: String) throws -> Any {
        let parts = pathWithQuery.split(separator: "?", maxSplits: 1,
                                        omittingEmptySubsequences: false)
        var components = URLComponents(url: serverURL.appendingPathComponent(String(parts[0])),
                                       resolvingAgainstBaseURL: false)
        if parts.count > 1 { components?.query = String(parts[1]) }
        let url = try XCTUnwrap(components?.url)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try synchronous(request)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func synchronous(_ request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data, URLResponse)?
        var failure: Error?
        api.dataTask(with: request) { data, response, error in
            if let error { failure = error }
            if let data, let response { result = (data, response) }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        if let failure { throw failure }
        guard let result else { throw URLError(.timedOut) }
        return result
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
