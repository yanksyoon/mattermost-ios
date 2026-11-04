// T50 — editing the reader's own profile, live, against a **real** Mattermost server (S28 + S39).
//
// Why live: every acceptance criterion is a statement about the running system, not about a model —
//   1. a position typed into the form reaches the server (`PUT /api/v4/users/{id}/patch`) and is what
//      a **relaunched** app draws, i.e. the value came back from the server rather than from the
//      shell's own state;
//   2. an uploaded picture changes the bytes the reader's own **post row** draws — the avatar in the
//      timeline, not the edit form's preview;
//   3. removing it returns the server's generated initial avatar, on that same row;
//   4. the custom-profile-attribute section is absent when the server has no such feature — this
//      fixture is Team Edition and answers 404 for the whole route (recorded, not faked).
//
// The two oracles are independent of the app:
//   * the server's own record (`GET /users/{id}` → `position`; `GET /users/{id}/image` → the bytes);
//   * the pixels the app drew in the post row (`XCUIElement.screenshot()` of `post.<id>.avatar`),
//     hashed — a model-only change cannot move that hash.
//
// The wire witness for (1) is optional: point the **app** at `scripts/t47_logging_relay.py`
// (`MM_APP_SERVER=http://127.0.0.1:8066`, `MM_RELAY_LOG=<file>`) and the test asserts the request
// line the app sent. The verdict never depends on the relay — the server's state does.
//
// Run (the fixture account needs a team and one channel — `scripts/t50_profile_probe.py` creates the
// probe account; the test creates its own team/channel/post when the account has none):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=t50probe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<probe password> \
//     python3 scripts/qa-test.py --platform ios --sim <sim> \
//       --only-testing MattermostUITests/T50EditProfileUITests
//
// Skips — never fails — when the environment is missing, like every live test here.

import XCTest
import CryptoKit

final class T50EditProfileUITests: XCTestCase {

    /// The picture the app is handed in place of the system picker (see `EditProfileView`'s
    /// `changePictureControl`): a 256×256 magenta/indigo checkerboard. The upload path exercised by
    /// the test is the product's own — only "which bytes the reader picked" is supplied.
    private static let seededPicturePNG = "iVBORw0KGgoAAAANSUhEUgAAAQAAAAEACAIAAADTED8xAAAEAUlEQVR42u3TQQ3AIBREQUTUCS6qq8fqQw8iCHvZSRAwYf8ba35X3/v8Vx8//8kbBuAXgAH4BWAAfgEYgF8ABuAXgAH4BWAAfgEYgF8ABuAXgAH4BWAAfgEYgF8ABuAXgAH4BWAAfgEYgF8ABuAXgAH4BWAAfgEYgF8ABuAXgAH4BWAAfgEYgF8ABuAXgAH4BeCA+AXggPgF4ID4BeCA+AXggPhDAfgg/ma/APgFYAB+ARiAXwAG4BeAAfgFYAB+ARiAXwAG4BeAAfgFYAB+ARiAXwAG4BeAAfgFYAB+ARiAXwAG4BeAAfgFYAB+ARiAXwAG4BeAAfgFYAB+ARiAXwAG4BeAAfgFYAB+ATggfgE4IH4BOCB+ATggfgE4IP5UAD6Iv9kvAH4BGIBfAAbgF4AB+AVgAH4BGIBfAAbgF4AB+AVgAH4BGIBfAAbgF4AB+AVgAH4BGIBfAAbgF4AB+AVgAH4BGIBfAAbgF4AB+AVgAH4BGIBfAAbgF4AB+AVgAH4BGIBfAA6IXwAOiF8ADohfAA6IXwAOiD8VgA/ib/YLgF8ABuAXgAH4BWAAfgEYgF8ABuAXgAH4BWAAfgEYgF8ABuAXgAH4BWAAfgEYgF8ABuAXgAH4BWAAfgEYgF8ABuAXgAH4BWAAfgEYgF8ABuAXgAH4BWAAfgEYgF8ABuAXgAPiF4AD4heAA+IXgAPiF4AD4k8F4IP4m/0C4BeAAfgFYAB+ARiAXwAG4BeAAfgFYAB+ARiAXwAG4BeAAfgFYAB+ARiAXwAG4BeAAfgFYAB+ARiAXwAG4BeAAfgFYAB+ARiAXwAG4BeAAfgFYAB+ARiAXwAG4BeAAfgF4ID4BeCA+AXggPgF4ID4BeCA+FMB+CD+Zr8A+AVgAH4BGIBfAAbgF4AB+AVgAH4BGIBfAAbgF4AB+AVgAH4BGIBfAAbgF4AB+AVgAH4BGIBfAAbgF4AB+AVgAH4BGIBfAAbgF4AB+AVgAH4BGIBfAAbgF4AB+AVgAH4BOCB+ATggfgE4IH4BOCB+ATgg/lQAPoi/2S8AfgEYgF8ABuAXgAH4BWAAfgEYgF8ABuAXgAH4BWAAfgEYgF8ABuAXgAH4BWAAfgEYgF8ABuAXgAH4BWAAfgEYgF8ABuAXgAH4BWAAfgEYgF8ABuAXgAH4BWAAfgEYgF8ADohfAA6IXwAOiF8ADohfAA6IPxWAD+Jv9guAXwAG4BeAAfgFYAB+ARiAXwAG4BeAAfgFYAB+ARiAXwAG4BeAAfgFYAB+ARiAXwAG4BeAAfgFYAB+ARiAXwAG4BeAAfgFYAB+ARiAXwAG4BeAAfgFYAB+ARiAXwAG4BeAA+IXgAPiF4AD4heAA+IXgAPiD/k3oHCSdmfQwcgAAAAASUVORK5CYII="

    /// One session per test process: the server rate-limits `/users/login` per IP.
    private static var cachedSession: (server: String, token: String, userID: String)?

    private var serverURL: URL!
    /// Where the **app** signs in: the server itself, or the logging relay in front of it.
    private var appURL: URL!
    private var relayLogPath: String?
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var baseline: [String: Any] = [:]

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live edit-profile test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        let appRaw = env["MM_APP_SERVER"] ?? raw
        guard let app = URL(string: appRaw), app.host != nil else {
            throw XCTSkip("MM_APP_SERVER is not a URL")
        }
        appURL = app
        relayLogPath = env["MM_RELAY_LOG"]
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
        baseline = try getJSON("/api/v4/users/\(userID!)") as? [String: Any] ?? [:]
        try acceptTermsIfNeeded()
    }

    override func tearDownWithError() throws {
        // The fixture's baseline is what the next run measures from.
        if let position = baseline["position"] as? String {
            _ = try? sendJSON("PUT", "/api/v4/users/\(userID!)/patch",
                              body: ["position": position], allowFailure: true)
        }
    }

    // MARK: - 1. The position: on the wire, and after a relaunch

    func testThePositionReachesTheServerAndSurvivesARelaunch() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let typed = "T50 UI position \(stamp)"
        XCTAssertNotEqual(baseline["position"] as? String, typed, "the premise: the fixture starts elsewhere")

        let app = launchApp()
        openEditProfile(app)

        let field = app.descendants(matching: .any).matching(identifier: "editProfile.position").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30),
                      "the edit form must draw the position field:\n\(app.debugDescription)")
        attach(app, "01-edit-form")
        replaceText(in: field, with: typed)

        // The form must agree there is something to save — a disabled Save is T40-AV's measured bug.
        let save = app.buttons["editProfile.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertTrue(save.isEnabled,
                      "a changed position must enable Save (a draft that observes its own edits):\n\(app.debugDescription)")
        save.tap()

        // The server's record is the verdict.
        let serverPosition = try waitForPosition(timeout: 30)
        XCTAssertEqual(serverPosition, typed, "the typed position must be what the server stores")
        attach(app, "02-saved")

        // The wire witness, when the app went through the relay.
        if let relayLogPath {
            let log = (try? String(contentsOfFile: relayLogPath, encoding: .utf8)) ?? ""
            XCTAssertTrue(log.contains("PUT /api/v4/users/\(userID!)/patch"),
                          "the app itself must issue the patch, not a test helper:\n\(log.suffix(2000))")
        }

        // And it survives a relaunch: a new process reads the profile from the server.
        app.terminate()
        let relaunched = launchApp(keepingState: true)
        openEditProfile(relaunched)
        let fieldAfter = relaunched.descendants(matching: .any)
            .matching(identifier: "editProfile.position").firstMatch
        XCTAssertTrue(fieldAfter.waitForExistence(timeout: 30),
                      "the edit form must open after a relaunch:\n\(relaunched.debugDescription)")
        let value = (fieldAfter.value as? String) ?? ""
        XCTAssertEqual(value, typed,
                       "the position must come back from the server after a relaunch, not from memory")
        attach(relaunched, "03-after-relaunch")

        // The account's own profile entity is the same thing, read back once more.
        let reread = try getJSON("/api/v4/users/\(userID!)") as? [String: Any] ?? [:]
        XCTAssertEqual(reread["position"] as? String, typed)
    }

    // MARK: - 2. The picture: the post row's bytes, then the initial again

    func testThePictureChangesThePostRowAndRemovingItRestoresTheInitial() throws {
        // A channel with one post by the reader: the smallest honest stage for "the row's avatar".
        let fixture = try ensureChannelWithMyPost()
        let channelID = fixture.channelID
        let postID = fixture.postID

        // Start from no picture. The story is "upload changes the row, remove restores the initial",
        // and a previous run leaves a picture behind — with the same seeded bytes, an upload would
        // change nothing and the comparison would be vacuous.
        _ = try? sendJSON("DELETE", "/api/v4/users/\(userID!)/image", body: nil, allowFailure: true)
        let beforeBytes = try imageBytes()

        let app = launchApp()
        openChannel(app, channelID: channelID)
        let avatar = element(app, "post.\(postID).avatar")
        XCTAssertTrue(avatar.waitForExistence(timeout: 60),
                      "the reader's post row must be drawn with its avatar:\n\(app.debugDescription)")
        // Give the picture fetch a moment: the row draws initials until the bytes land.
        Thread.sleep(forTimeInterval: 4)
        let before = digest(of: avatar)
        attach(app, "10-row-before")

        // Settings → Account → Edit profile → Change picture.
        openEditProfile(app)
        let changePicture = app.buttons["editProfile.changePicture"]
        XCTAssertTrue(changePicture.waitForExistence(timeout: 30),
                      "the form must offer a picture picker:\n\(app.debugDescription)")
        changePicture.tap()
        attach(app, "11-picked")

        // The server has the new bytes once the upload lands; poll it rather than sleeping blind.
        let uploaded = try waitForImageChange(from: beforeBytes, timeout: 60)
        if uploaded == beforeBytes {
            let sheetAvatar = element(app, "editProfile.avatar")
            let shown = sheetAvatar.exists ? (sheetAvatar.value as? String ?? "none") : "no avatar element"
            let error = element(app, "editProfile.error")
            let sentence = error.exists ? error.label : "no error shown"
            XCTFail("the upload must change the bytes the server serves; the form drew \(shown), "
                    + "server bytes unchanged (\(beforeBytes.count) B), \(sentence)")
        }
        let uploadedBytes = uploaded

        // Close the form, back to the timeline, and read what the row actually draws.
        closeEditProfile(app)
        showChannel(app, channelID: channelID)
        let avatarAfter = element(app, "post.\(postID).avatar")
        XCTAssertTrue(avatarAfter.waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 4)
        let after = digest(of: avatarAfter)
        attach(app, "12-row-after-upload")
        XCTAssertNotEqual(after, before,
                          "the post row must redraw the uploaded picture — the bytes on screen, not the model")

        // Remove it: the server answers its generated initial avatar, and the row must follow.
        openEditProfile(app)
        let remove = app.buttons["editProfile.removePicture"]
        XCTAssertTrue(remove.waitForExistence(timeout: 30),
                      "the form must offer Remove picture:\n\(app.debugDescription)")
        XCTAssertTrue(remove.isEnabled,
                      "Remove picture must be enabled (a disabled control swallows the tap silently):\n\(app.debugDescription)")
        remove.tap()
        let removedBytes = try waitForImageChange(from: uploadedBytes, timeout: 60)
        if removedBytes == uploadedBytes {
            let error = element(app, "editProfile.error")
            attach(app, "12b-remove-did-not-land")
            XCTFail("DELETE must replace the uploaded picture; the server still serves "
                    + "\(uploadedBytes.count) B, the form says: "
                    + (error.exists ? error.label : "nothing"))
        }
        XCTAssertEqual(removedBytes, beforeBytes,
                       "measured: the server's generated fallback for an account with no picture is the same bytes as before the upload")
        closeEditProfile(app)
        showChannel(app, channelID: channelID)
        let avatarRestored = element(app, "post.\(postID).avatar")
        XCTAssertTrue(avatarRestored.waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 4)
        attach(app, "13-row-after-remove")
        XCTAssertEqual(digest(of: avatarRestored), before,
                       "removing the picture must bring the initial avatar back to the row")
    }

    // MARK: - 3. Custom profile attributes: the gate, stated

    func testTheCustomAttributeSectionIsAbsentWhenTheServerHasNoFeature() throws {
        // Measured on the fixture: the whole route is 404 (Team Edition, license-gated).
        let fieldsStatus = try statusOf(path: "/api/v4/custom_profile_attributes/fields")
        try XCTSkipUnless(fieldsStatus == 404,
                          "this server answers \(fieldsStatus) for custom profile attributes; the gate test is for a server without the feature")

        let app = launchApp()
        openEditProfile(app)
        // The form is a lazy `Form`: its lower rows (the attribute section, Save) do not exist until
        // they are scrolled into view, so "absent" has to be proved after walking the whole thing.
        let position = app.descendants(matching: .any)
            .matching(identifier: "editProfile.position").firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 30),
                      "the form must be up:\n\(app.debugDescription)")
        var reachedSave = false
        for _ in 0..<6 where !reachedSave {
            app.swipeUp()
            reachedSave = app.buttons["editProfile.save"].exists
        }
        XCTAssertTrue(reachedSave,
                      "the form must reach its Save row — otherwise 'no attribute section' is untested, not true:\n\(app.debugDescription)")
        let attributeFields = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "editProfile.attribute."))
        XCTAssertEqual(attributeFields.count, 0,
                       "no fields on the server means no section — not an empty form:\n\(app.debugDescription)")
        XCTAssertFalse(app.staticTexts["Profile fields"].exists,
                       "the section header must be absent too")
        attach(app, "20-no-attribute-section")
    }

    // MARK: - App driving

    private func launchApp(keepingState: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-uiTestSeedServer", appURL.absoluteString,
                         "-uiTestSeedServerName", "Local Mattermost",
                         "-surfaceMode", "shell=native",
                         "-surfaceMode", "auth=native",
                         "-surfaceMode", "sidebar=native",
                         "-surfaceMode", "channel=native",
                         "-surfaceMode", "profile=native",
                         "-uiTestLogLevel", "error",
                         "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if !keepingState {
            arguments = ["-uiTestResetPersistedState",
                         "-uiTestForgetSession", appURL.absoluteString] + arguments
        }
        app.launchArguments = arguments
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        // The system photo picker cannot be driven from XCUITest on this runtime (§ "pickFirstPhoto"),
        // so the bytes the reader "picks" are handed to the app through the DEBUG-only seam. The
        // upload, the cache invalidation and the row redraw are all the product's own path.
        app.launchEnvironment["MM_UITEST_AVATAR_PNG_BASE64"] = Self.seededPicturePNG
        app.launch()
        if !keepingState || app.textFields["loginIDField"].waitForExistence(timeout: 10) {
            signIn(app)
        }
        return app
    }

    private func signIn(_ app: XCUIApplication) {
        let field = app.textFields["loginIDField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "the native sign-in must mount against \(appURL.absoluteString):\n\(app.debugDescription)")
        field.tap()
        field.typeText(loginID)
        let secret = app.secureTextFields["loginPasswordField"]
        XCTAssertTrue(secret.exists)
        secret.tap()
        secret.typeText(password)
        app.buttons["loginSubmitButton"].tap()
        // Not `nativeShell`: since `t_295b0a32` a signed-in launch opens a channel and pushes it
        // **over** the list, so the shell container is absent until `Back` (t_9399c0b4).
        // `ShellSettle.waitForSignedIn` answers for the list, the pushed pane and the tab bar;
        // `openEditProfile` pops a pushed pane through its own `showSidebar`.
        XCTAssertTrue(ShellSettle.waitForSignedIn(app, timeout: 40),
                      "signing in must reach the shell:\n\(app.debugDescription)")
    }

    /// Settings → Account → Edit profile.
    private func openEditProfile(_ app: XCUIApplication) {
        let settings = app.buttons["settingsToolbarButton"]
        if !settings.waitForExistence(timeout: 20) {
            // A pushed pane hides the root toolbar; come back to the sidebar first.
            showSidebar(app)
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 20),
                      "the shell must offer Settings:\n\(app.debugDescription)")
        settings.tap()
        XCTAssertTrue(element(app, "settingsView").waitForExistence(timeout: 15),
                      "Settings must open:\n\(app.debugDescription)")

        let row = app.buttons["Edit profile"]
        XCTAssertTrue(row.waitForExistence(timeout: 15),
                      "Settings → Account must offer Edit profile:\n\(app.debugDescription)")
        row.tap()
        XCTAssertTrue(element(app, "editProfile.sheet").waitForExistence(timeout: 30),
                      "the edit form must open:\n\(app.debugDescription)")
    }

    private func closeEditProfile(_ app: XCUIApplication) {
        // The edit sheet's own Done is identified; a bare "Done" can belong to Settings beneath it.
        let done = app.buttons["editProfile.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 15),
                      "the edit form must offer a way out:\n\(app.debugDescription)")
        done.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !element(app, "editProfile.sheet").exists },
                      "the edit form must close:\n\(app.debugDescription)")
        // And then Settings, if the edit sheet was opened from there.
        let settingsDone = app.navigationBars.buttons
            .matching(NSPredicate(format: "label == %@", "Done")).firstMatch
        if settingsDone.waitForExistence(timeout: 5), settingsDone.isHittable {
            settingsDone.tap()
        }
        _ = waitUntil(timeout: 10) { !element(app, "settingsView").exists }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    private func showSidebar(_ app: XCUIApplication) {
        // `nativeSidebar` is in the tree even under a pushed channel pane (`t9399c0b4`), so it cannot
        // be the early-out test: `ShellSettle.tapTab` settles the landing, pops the pane and taps
        // `Channels` (and answers false on the split layout, where the sidebar is already on show).
        if !ShellSettle.tapTab(ShellSettle.Tab.channels, in: app, wait: 5),
           !element(app, "nativeSidebar").exists {
            let back = app.navigationBars.firstMatch.buttons.element(boundBy: 0)
            if back.exists, back.isHittable { back.tap() }
        }
        XCTAssertTrue(element(app, "nativeSidebar").waitForExistence(timeout: 20),
                      "the shell must be back on the channel sidebar:\n\(app.debugDescription)")
    }

    private func openChannel(_ app: XCUIApplication, channelID: String) {
        showChannel(app, channelID: channelID)
    }

    /// Scroll the sidebar until the channel's row is realised, then open it.
    private func showChannel(_ app: XCUIApplication, channelID: String) {
        showSidebar(app)
        // One implementation of "sweep a lazy list both ways and wait for its surface" —
        // `ShellSettle.revealSidebarChannel`. A local copy swiped `channelSidebar.scroll` before it
        // existed, which is not an assertion failure but a hard query error ("Failed to swipe up
        // \"channelSidebar.scroll\" … No matches found", `t9399c0b4`).
        let reveal = ShellSettle.revealSidebarChannel(app, channelID: channelID)
        let row = reveal.row
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "the sidebar must list \(channelID) (after \(reveal.swipes) swipe(s), "
                      + "\(reveal.rowsDrawn ?? 0) row(s) drawn):\n\(app.debugDescription)")
        row.tap()
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 60),
                      "the channel's post list must mount:\n\(app.debugDescription)")
    }

    /// Replace a text field's contents (tap at the end, delete what is there, type the new value).
    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        let current = (field.value as? String) ?? ""
        if !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
    }

    /// Pick the most recent photo in the system picker `PhotosPicker` presents.
    ///
    /// **Not used by the live test — kept for the record.** Measured on iOS 26.5: the picker is a
    /// separate process (`com.apple.mobileslideshow.photospicker`) whose grid is queryable
    /// (`Image, identifier: 'PXGGridLayout-Info'`), but no tap XCUITest synthesises lands on a tile:
    /// element tap (not hittable), element coordinate, and app-window coordinate were each tried and
    /// each left the sheet up with nothing selected. That is why the test seeds the bytes through
    /// `MM_UITEST_AVATAR_PNG_BASE64` instead (`EditProfileView.changePictureControl`, and
    /// `docs/t50-build-note.md` §8). Restored here so the next person does not have to rediscover it.
    private func pickFirstPhoto(_ app: XCUIApplication) {
        let picker = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow.photospicker")
        let tiles = picker.images.matching(identifier: "PXGGridLayout-Info")

        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline, tiles.count == 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        guard tiles.count > 0 else {
            attach(app, "11c-picker-empty")
            XCTFail("the picker must list the photo library:\n\(picker.debugDescription)")
            return
        }
        let first = tiles.element(boundBy: 0)
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let frame = first.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: frame.midY))
            .tap()
        _ = waitUntil(timeout: 20) { tiles.count == 0 }
    }

    // MARK: - Server

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
              let issued = http.value(forHTTPHeaderField: "Token"),
              let user = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = user["id"] as? String else {
            throw XCTSkip("could not sign in as \(login) on \(serverURL.absoluteString) (HTTP \(status))")
        }
        return (issued, id)
    }

    /// The position the server holds, once it is not the baseline one (or the last read, on timeout).
    private func waitForPosition(timeout: TimeInterval) throws -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: String?
        while Date() < deadline {
            if let user = try? getJSON("/api/v4/users/\(userID!)") as? [String: Any],
               let position = user["position"] as? String {
                last = position
                if position != (baseline["position"] as? String) { return position }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return last
    }

    /// The picture bytes the server serves, once they differ from `previous`.
    @discardableResult
    private func waitForImageChange(from previous: Data, timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var last = previous
        while Date() < deadline {
            if let current = try? imageBytes(), current != previous { return current }
            last = (try? imageBytes()) ?? last
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return last
    }

    private func imageBytes() throws -> Data {
        // Cache-busted: measured on this host, URLSession serves the previous `GET /users/{id}/image`
        // from its own HTTP cache (the server marks the picture cacheable), so an oracle that re-read
        // the same URL saw the OLD bytes after an upload the app had already drawn. A unique query is
        // a different URL to every cache in the stack; `reloadIgnoring…` says the same to this one.
        var request = URLRequest(url: url(for: "/api/v4/users/\(userID!)/image?_=\(Int(Date().timeIntervalSince1970 * 1000))"))
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        try XCTSkipUnless(status == 200, "GET /users/{id}/image answered \(status)")
        return data
    }

    private func statusOf(path: String) throws -> Int {
        var request = URLRequest(url: url(for: path))
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (_, response) = try synchronous(request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// A channel the reader can post in, with at least one post of their own.
    ///
    /// The fixture account was created by `scripts/t50_profile_probe.py`; it owns a team and a channel
    /// there. Any account that has neither gets them (open team creation is on for this fixture).
    private func ensureChannelWithMyPost() throws -> (channelID: String, postID: String) {
        var teams = try getJSON("/api/v4/users/me/teams") as? [[String: Any]] ?? []
        var teamID: String
        if let first = teams.first?["id"] as? String {
            teamID = first
        } else {
            let team = try sendJSON("POST", "/api/v4/teams",
                                    body: ["display_name": "T50 Probe Team", "name": "t50probe",
                                           "type": "O"]) as? [String: Any] ?? [:]
            teamID = team["id"] as? String ?? ""
            teams = []
        }
        guard !teamID.isEmpty else { throw XCTSkip("the fixture account has no team and cannot create one") }

        // A stable channel name: create-or-find, so repeat runs measure the same room.
        var channelID = ""
        var status = try statusOf(path: "/api/v4/teams/\(teamID)/channels/name/t50-avatar")
        if status == 200 {
            let channel = try getJSON("/api/v4/teams/\(teamID)/channels/name/t50-avatar") as? [String: Any] ?? [:]
            channelID = channel["id"] as? String ?? ""
        } else {
            let channel = try sendJSON("POST", "/api/v4/channels",
                                       body: ["team_id": teamID, "name": "t50-avatar",
                                              "display_name": "T50 Avatar", "type": "O"]) as? [String: Any] ?? [:]
            channelID = channel["id"] as? String ?? ""
        }
        guard !channelID.isEmpty else { throw XCTSkip("no channel could be opened for the picture test") }

        // The reader's own post: the row whose avatar this test measures.
        let page = try getJSON("/api/v4/channels/\(channelID)/posts?per_page=30") as? [String: Any] ?? [:]
        let order = page["order"] as? [String] ?? []
        let posts = page["posts"] as? [String: Any] ?? [:]
        for id in order {
            if let post = posts[id] as? [String: Any], (post["user_id"] as? String) == userID,
               ((post["root_id"] as? String) ?? "").isEmpty,
               // A join message is a post by the reader too, but a `system_*` row draws no avatar —
               // measuring "the row's picture" on it would measure the info icon.
               ((post["type"] as? String) ?? "").isEmpty,
               !(((post["message"] as? String) ?? "").isEmpty) {
                return (channelID, id)
            }
        }
        let created = try sendJSON("POST", "/api/v4/posts",
                                   body: ["channel_id": channelID,
                                          "message": "T50 avatar row — the reader's own picture"]) as? [String: Any] ?? [:]
        guard let postID = created["id"] as? String else {
            throw XCTSkip("could not create a post in \(channelID)")
        }
        return (channelID, postID)
    }

    /// T49's gate stands between sign-in and the shell: on this fixture a custom terms document exists,
    /// so an account that has never accepted it never sees the workspace. Fixture prep, not app code —
    /// the gate itself is T49's test's subject.
    private func acceptTermsIfNeeded() throws {
        let document = try getJSON("/api/v4/terms_of_service") as? [String: Any] ?? [:]
        guard let documentID = document["id"] as? String else { return }
        let me = try getJSON("/api/v4/users/\(userID!)") as? [String: Any] ?? [:]
        guard (me["terms_of_service_id"] as? String) != documentID else { return }
        _ = try sendJSON("POST", "/api/v4/users/me/terms_of_service",
                         body: ["termsOfServiceId": documentID, "accepted": true])
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
            throw NSError(domain: "T50Oracle", code: status, userInfo: [
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
        if !allowFailure, !(200...299).contains(status) {
            throw XCTSkip("\(method) \(path) answered \(status)")
        }
        guard !data.isEmpty, let json = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return json
    }

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

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// A hash of the pixels an element draws — the "bytes on screen", not the model behind them.
    private func digest(of element: XCUIElement) -> String {
        let data = element.screenshot().pngRepresentation
        let hash = SHA256.hash(data: data)
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
