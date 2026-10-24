import XCTest

/// T32-R — the sidebar pane's accessibility identifiers, in **every** content state.
///
/// Why this file exists: T32-AV F2 found that with `-surfaceMode sidebar=native` a **one-team**
/// account lost the pane's `nativeSidebar` identifier (the team region's container absorbed it),
/// which is the identifier `MattermostUITests`' shipped T30 assertion looks for — so flipping the
/// `sidebar` surface would have broken a green test. F3 found the empty/failure screens' container
/// identifiers (`teamSidebar.emptyState`, `teamSidebar.errorState`) were never in the tree at all.
///
/// The contract these tests pin, for the pane as a whole:
///   - `nativeSidebar` names the pane's anchor row (the server it belongs to) and resolves in
///     every state, flag on or off;
///   - `nativeTeamSidebar` names the team region and resolves in every state **with the flag on**
///     (and must not exist with the flag off — there is no team region then);
///   - the state screens are addressed by `teamSidebar.rail`, `teamSidebar.empty`/`teamSidebar.retry`
///     and `teamSidebar.error`/`teamSidebar.retry`, which is what the build note and the parity row
///     now name instead of the container identifiers.
///
/// Each test needs one stub instance, because the fixture *is* the state. Ports 8111–8115 and 8443
/// are already taken by the older suites (8111 general, 8112 stalled page, 8113 cookie session,
/// 8114/8115 auth + expired session, 8443 TLS), so the sidebar fixtures use 8116+:
///
///     cd build/uitest-server      # separate shells, left running for the suite
///     python3 mm_stub.py --port 8111                    # one team (also the general stub)
///     python3 mm_stub.py --port 8116 --teams 0          # zero teams → empty state
///     python3 mm_stub.py --port 8118 --teams-delay 8    # teams in flight → loading state
///     python3 mm_stub.py --port 8119 --teams-fail       # 500 → failure state
///     python3 mm_stub.py --port 8117 --teams 2          # two teams → rail
///
/// A test skips (rather than fails) when its stub is not listening, like every other stub-backed
/// test in this suite. The fixtures sign in through the real native form: the stub answers
/// `POST /api/v4/users/login` with a token and then serves `/users/me/teams{,/members,/unread}`.
final class T32SidebarIdentifiersTests: XCTestCase {

    private static let stubOneTeam = "http://127.0.0.1:8111"
    private static let stubTwoTeams = "http://127.0.0.1:8117"
    private static let stubNoTeams = "http://127.0.0.1:8116"
    private static let stubSlowTeams = "http://127.0.0.1:8118"
    private static let stubFailingTeams = "http://127.0.0.1:8119"

    /// The stub's fixture identity, and the password the stub accepts for any non-MFA login.
    private static let login = "stub-user"
    private static let password = "stub-password"

    /// One team, flag on: the F2 regression itself. This is the test that fails on `108377a`.
    func testOneTeamPaneKeepsBothIdentifiersWithTheFlagOn() throws {
        try start(Self.stubOneTeam, needs: "one team")
        let app = launch(Self.stubOneTeam, sidebarNative: true)
        signIn(app, on: Self.stubOneTeam)

        XCTAssertTrue(element(app, "nativeTeamSidebar").waitForExistence(timeout: 40),
                      "the team region must be mounted:\n\(app.debugDescription)")
        XCTAssertTrue(element(app, "nativeSidebar").waitForExistence(timeout: 20),
                      "F2: a one-team account must keep the pane's `nativeSidebar` identifier — "
                      + "this is the assertion MattermostUITests' T30 test depends on:\n"
                      + "\(app.debugDescription)")
        XCTAssertTrue(element(app, "sidebarCurrentTeam").waitForExistence(timeout: 20),
                      "the pane must still show which team is current")
        XCTAssertEqual(element(app, "sidebarCurrentTeam").label, "Stub Team 1")
        XCTAssertFalse(element(app, "teamSidebar.rail").exists,
                       "a one-team account gets no rail chrome (criterion 2a)")
        XCTAssertFalse(element(app, "teamSidebar.empty").exists,
                       "a one-team account is not the empty state")
        attachShot(app, named: "t32r-01-one-team-flag-on")
    }

    /// The same account, flag off: T30's pane is unchanged, and the team region must be absent
    /// (a `sidebar=web` surface has no team region at all — that half of the contract is what keeps
    /// the flag meaningful).
    func testOneTeamPaneFlagOffKeepsThePaneIdentifierAndDropsTheRegion() throws {
        try start(Self.stubOneTeam, needs: "one team")
        let app = launch(Self.stubOneTeam, sidebarNative: false)
        signIn(app, on: Self.stubOneTeam)

        XCTAssertTrue(element(app, "nativeSidebar").waitForExistence(timeout: 40),
                      "without the flag the pane keeps its identifier exactly as T30 shipped it:\n"
                      + "\(app.debugDescription)")
        XCTAssertFalse(element(app, "nativeTeamSidebar").exists,
                       "`sidebar=web` must not mount T32's team region")
        attachShot(app, named: "t32r-02-one-team-flag-off")
    }

    /// Two teams, flag on: the rail is drawn and both identifiers still resolve (the control that
    /// the F2 fix did not change the two-team behaviour T32-AV passed).
    func testTwoTeamRailKeepsBothIdentifiers() throws {
        try start(Self.stubTwoTeams, needs: "two teams")
        let app = launch(Self.stubTwoTeams, sidebarNative: true)
        signIn(app, on: Self.stubTwoTeams)

        XCTAssertTrue(element(app, "teamSidebar.rail").waitForExistence(timeout: 40),
                      "two teams must draw the rail:\n\(app.debugDescription)")
        XCTAssertTrue(element(app, "nativeTeamSidebar").exists)
        XCTAssertTrue(element(app, "nativeSidebar").exists,
                      "the pane's identifier must survive the rail being beside it too")
        attachShot(app, named: "t32r-03-two-team-rail")
    }

    /// Zero teams, flag on: the empty state is reachable, and — F3 — the identifiers that actually
    /// resolve are the ones the docs now name.
    func testZeroTeamsEmptyStateIsReachable() throws {
        try start(Self.stubNoTeams, needs: "zero teams (--teams 0)")
        let app = launch(Self.stubNoTeams, sidebarNative: true)
        signIn(app, on: Self.stubNoTeams)

        XCTAssertTrue(element(app, "teamSidebar.empty").waitForExistence(timeout: 40),
                      "a zero-team account must see the empty state:\n\(app.debugDescription)")
        XCTAssertTrue(element(app, "nativeTeamSidebar").exists,
                      "the region must still be identifiable in the empty state")
        XCTAssertTrue(element(app, "nativeSidebar").exists,
                      "…and so must the pane (F2: every content state)")
        XCTAssertTrue(element(app, "teamSidebar.retry").exists,
                      "the empty state must offer a retry")
        XCTAssertTrue(app.staticTexts["No teams are available to join"].exists,
                      "upstream's zero-team copy")
        XCTAssertFalse(element(app, "teamSidebar.rail").exists, "no rail for zero teams")
        XCTAssertFalse(element(app, "teamSidebar.emptyState").exists,
                       "F3: the container identifiers that never reached the tree are gone — the "
                       + "docs name `teamSidebar.empty` instead")
        attachShot(app, named: "t32r-04-zero-teams-empty-state")
    }

    /// The teams call fails: the failure state is reachable and the pane keeps both identifiers
    /// (this is also the state a `sidebar=native` default would show against a stub that has no
    /// teams endpoint, so it must not lose `nativeSidebar`).
    func testTeamsFailureStateIsReachable() throws {
        try start(Self.stubFailingTeams, needs: "failing teams (--teams-fail)")
        let app = launch(Self.stubFailingTeams, sidebarNative: true)
        signIn(app, on: Self.stubFailingTeams)

        XCTAssertTrue(element(app, "teamSidebar.error").waitForExistence(timeout: 40),
                      "a failed teams call must say so:\n\(app.debugDescription)")
        XCTAssertTrue(element(app, "nativeTeamSidebar").exists)
        XCTAssertTrue(element(app, "nativeSidebar").exists,
                      "F2: the failure state must not lose the pane's identifier either")
        XCTAssertTrue(element(app, "teamSidebar.retry").exists)
        XCTAssertFalse(element(app, "teamSidebar.errorState").exists,
                       "F3: the container identifiers that never reached the tree are gone")
        attachShot(app, named: "t32r-05-failed-teams")
    }

    /// Loading: the teams answer is in flight for 8 s. The pane must never be blanked while it
    /// waits (build note §8.7) and both identifiers must already resolve.
    func testLoadingStateDrawsThePaneAndKeepsBothIdentifiers() throws {
        try start(Self.stubSlowTeams, needs: "slow teams (--teams-delay)")
        let app = launch(Self.stubSlowTeams, sidebarNative: true)
        signIn(app, on: Self.stubSlowTeams)

        XCTAssertTrue(element(app, "nativeTeamSidebar").waitForExistence(timeout: 30),
                      "the pane must mount before the teams answer arrives:\n\(app.debugDescription)")
        // Still in flight: no rail, no empty state, no failure — just the pane and its content.
        XCTAssertFalse(element(app, "teamSidebar.rail").exists)
        XCTAssertFalse(element(app, "teamSidebar.empty").exists)
        XCTAssertFalse(element(app, "teamSidebar.error").exists)
        XCTAssertTrue(element(app, "nativeSidebar").exists,
                      "a loading team region must not remove the pane's identifier")
        XCTAssertTrue(element(app, "nativeSidebarAllThreads").exists,
                      "…and the pane's own rows must still be on screen (not blanked)")
        attachShot(app, named: "t32r-06-loading")

        // …and the answer lands: the load was real, not skipped.
        XCTAssertTrue(element(app, "sidebarCurrentTeam").waitForExistence(timeout: 30),
                      "the teams answer must land after the delay")
        XCTAssertEqual(element(app, "sidebarCurrentTeam").label, "Stub Team 1")
    }

    // MARK: - Launch + sign-in

    private func launch(_ server: String, sidebarNative: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-uiTestResetPersistedState",
                    "-uiTestForgetSession", server,
                    "-uiTestSeedServer", server,
                    "-uiTestSeedServerName", "Local Mattermost Test",
                    "-surfaceMode", "shell=native",
                    "-surfaceMode", "auth=native",
                    "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if sidebarNative { args += ["-surfaceMode", "sidebar=native"] }
        app.launchArguments = args
        app.launch()
        return app
    }

    /// The production sign-in form, driven the way a person drives it (the stub accepts any login).
    private func signIn(_ app: XCUIApplication, on server: String) {
        let field = app.textFields["loginIDField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "the native sign-in must mount for \(server):\n\(app.debugDescription)")
        field.tap()
        field.typeText(Self.login)
        let secret = app.secureTextFields["loginPasswordField"]
        XCTAssertTrue(secret.exists)
        secret.tap()
        secret.typeText(Self.password)
        app.buttons["loginSubmitButton"].tap()
    }

    // MARK: - Helpers

    /// Any element type: SwiftUI puts these identifiers on labels, buttons, cells and collections
    /// depending on the container, so a type-specific query would silently never match.
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func attachShot(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Skip (don't fail) when the fixture stub for this state is not running, and say which command
    /// starts it.
    private func start(_ url: String, needs description: String) throws {
        let ping = URL(string: url + "/api/v4/system/ping")!
        var request = URLRequest(url: ping)
        request.timeoutInterval = 3
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 5)
        try XCTSkipUnless(ok, "stub for \(description) is not running on \(url)")
    }
}
