// T49 — the terms-of-service gate and the two missing account forms, driven against a **real**
// Mattermost server.
//
// Why live: the card's acceptance is about a running server.
//   1. "sign in → gate appears" — the gate is only real if the server's own `/terms_of_service`
//      answers with a document this user has not accepted; a fixture rendered in the test process
//      would prove nothing about the app;
//   2. "accept → the workspace mounts, and the accept request is observed" — after the tap this
//      suite **reads the server itself** (`GET /api/v4/users/{id}/terms_of_service`) and requires
//      the fixture document id back. A UI that merely hides a screen would fail here;
//   3. "a second run with TOS disabled shows no gate" — run again with the document removed.
//
// The fixture is seeded out of band (Team Edition has no license for the config switch, so the
// document is inserted in Postgres — see `docs/t49-build-note.md` §2). The suite therefore takes
// its expectation from the environment rather than deciding it:
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password>
//     TEST_RUNNER_MM_TOS_STATE=pending        # or `none` for the no-gate run
//
// Every test skips (never fails) when the environment or the server is missing, like every live
// test here. Screenshots are attached so the run leaves visual evidence beside the machine verdict.

import UIKit
import XCTest

final class T49TermsOfServiceUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var expectedState: String!

    /// The fixture document, as inserted by the build note's SQL.
    private let fixtureTermsText = "T49 fixture terms: accept these local test terms before your "
        + "workspace mounts."

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        expectedState = env["MM_TOS_STATE"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty && !expectedState.isEmpty,
                          "Live T49 test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD / _TOS_STATE")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
    }

    // MARK: - 1. Pending terms block the shell, and Accept releases it

    /// The card's headline: a server that requires terms must not let the native shell mount, and
    /// accepting must mount it **because the server recorded the acceptance**, not because the
    /// screen closed.
    func testTheGateBlocksTheWorkspaceUntilTheTermsAreAccepted() throws {
        try XCTSkipUnless(expectedState == "pending",
                          "this run is not the pending-terms fixture (MM_TOS_STATE=\(expectedState ?? ""))")

        // The premise, measured in the test process before the app is launched: this user has not
        // accepted the current document. If this fails, the fixture is stale and the run would be
        // asserting nothing.
        let credential = try login()
        let documentID = try XCTUnwrap(currentDocumentID(token: credential.token),
                                       "the fixture must publish a terms document for this run")
        XCTAssertNil(userAcceptedTermsID(token: credential.token, userID: credential.userID),
                     "the fixture user must start with the terms outstanding")

        let app = launchApp()   // launches and signs in; the gate is what the sign-in must reach
        let gate = element(app, "termsOfServiceGate")
        XCTAssertTrue(gate.waitForExistence(timeout: 60),
                      "a pending acceptance must mount the blocking gate, not the shell:\n\(app.debugDescription)")
        XCTAssertFalse(element(app, "nativeShell").exists,
                       "the workspace must not mount while the terms are outstanding")
        let text = element(app, "termsOfServiceText")
        XCTAssertTrue(text.waitForExistence(timeout: 30), "the gate must show the server's document")
        XCTAssertTrue(text.label.contains(fixtureTermsText),
                      "the gate must render the server's own terms (label: \(text.label))")
        print("T49 gate state: pending, document=\(documentID)")
        attachment(app, named: "t49-gate-pending")

        let accept = app.buttons["termsOfServiceAcceptButton"]
        XCTAssertTrue(accept.waitForExistence(timeout: 20), "the gate must offer Accept")
        accept.tap()

        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 90),
                      "accepting must mount the workspace:\n\(app.debugDescription)")
        XCTAssertFalse(gate.exists, "the gate must be gone once accepted")
        attachment(app, named: "t49-workspace-after-accept")

        // The acceptance, observed on the server rather than inferred from the screen.
        let accepted = userAcceptedTermsID(token: credential.token, userID: credential.userID)
        XCTAssertEqual(accepted, documentID,
                       "POST /users/me/terms_of_service must have been recorded by the server")
        print("T49 accept observed on server: user=\(credential.userID) terms=\(accepted ?? "nil")")
    }

    // MARK: - 2. A server without terms shows no gate

    /// The tolerant half of the card: no document published → the workspace, exactly as before T49.
    /// Run with the fixture document removed (`MM_TOS_STATE=none`).
    func testAServerWithoutTermsShowsNoGate() throws {
        try XCTSkipUnless(expectedState == "none",
                          "this run is not the no-terms fixture (MM_TOS_STATE=\(expectedState ?? ""))")

        let credential = try login()
        XCTAssertNil(currentDocumentID(token: credential.token),
                     "the no-terms fixture must publish no document")

        let app = launchApp()   // launches and signs in; the shell is what the sign-in must reach
        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 90),
                      "a server without terms must mount the workspace directly:\n\(app.debugDescription)")
        // A settle window: the gate must not appear late (the TOS read is an extra round trip after
        // the login). Three seconds is several round trips on this fixture.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(element(app, "termsOfServiceGate").exists,
                       "no document published → no gate, ever")
        attachment(app, named: "t49-no-terms-workspace")
    }

    // MARK: - 3. Sign-up reaches the server and creates an account

    func testSignUpCreatesAnAccountOnTheServer() throws {
        let email = "t49-signup-\(Int(Date().timeIntervalSince1970))@example.com"
        let app = launchApp(signedIn: false)
        XCTAssertTrue(app.textFields["loginIDField"].waitForExistence(timeout: 40),
                      "the sign-in form must mount:\n\(app.debugDescription)")

        let create = app.buttons["createAccountButton"]
        XCTAssertTrue(create.waitForExistence(timeout: 20), "the form must offer account creation")
        create.tap()

        let emailField = app.textFields["signUpEmailField"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 30), "the sign-up form must appear")
        emailField.tap()
        emailField.typeText(email)
        let passwordField = app.secureTextFields["signUpPasswordField"]
        fillSecureField(passwordField, with: "T49-Password-1", app: app)
        let confirm = app.secureTextFields["signUpConfirmPasswordField"]
        fillSecureField(confirm, with: "T49-Password-1", app: app)
        print("T49 sign-up fields: email=\(String(describing: emailField.value)) "
              + "password=\(String(describing: passwordField.value)) "
              + "confirm=\(String(describing: confirm.value))")

        let submit = app.buttons["signUpSubmitButton"]
        print("T49 sign-up submit state: enabled=\(submit.isEnabled) value=\(String(describing: submit.value))")
        XCTAssertTrue(submit.isEnabled,
                      "a valid address and a matching password enable the button (it says: "
                      + "\(String(describing: submit.value)))")
        submit.tap()

        let success = app.staticTexts["signUpSuccessTitle"]
        let failure = element(app, "signUpError")
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !success.exists, !failure.exists {
            Thread.sleep(forTimeInterval: 0.5)
        }
        attachment(app, named: "t49-signup-result")

        XCTAssertTrue(success.exists,
                      "POST /users must create the account and show the verification state "
                      + "(error: \(failure.exists ? failure.label : "none"))")
        // Independent evidence that the request reached the server.
        let credential = try login()
        XCTAssertEqual(try userID(forEmail: email, token: credential.token), email,
                       "the account must exist on the server after the form said it did")
        print("T49 sign-up observed on server: \(email)")
    }

    // MARK: - 4. Forgot password reaches the server (and reports its answer)

    /// This fixture has no SMTP (`SMTPServer=localhost`, nothing listening), so the honest outcome
    /// is the server's own failure — the app must show it rather than a fake "sent" screen, and the
    /// request must still have gone out. Both outcomes are accepted and printed; what is asserted is
    /// that the form reached one of them.
    func testForgotPasswordReportsTheServersAnswer() throws {
        let app = launchApp(signedIn: false)
        XCTAssertTrue(app.textFields["loginIDField"].waitForExistence(timeout: 40))

        let forgot = app.buttons["forgotPasswordButton"]
        XCTAssertTrue(forgot.waitForExistence(timeout: 20), "the form must offer password reset")
        forgot.tap()

        let field = app.textFields["forgotPasswordEmailField"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the reset form must appear")
        field.tap()
        field.typeText(try login().email)
        app.buttons["forgotPasswordSubmitButton"].tap()

        let sent = app.staticTexts["forgotPasswordSentTitle"]
        let failed = element(app, "forgotPasswordError")
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !sent.exists, !failed.exists {
            Thread.sleep(forTimeInterval: 0.5)
        }
        attachment(app, named: "t49-forgot-password-result")

        let outcome = sent.exists ? "sent" : (failed.exists ? "error" : "none")
        print("T49 forgot-password outcome: \(outcome) — \(failed.exists ? failed.label : "")")
        XCTAssertNotEqual(outcome, "none",
                          "the reset form must reach the sent state or the server's honest error")
        if outcome == "error" {
            // Recorded, not hidden: this fixture cannot send mail, and the app must say so.
            XCTAssertFalse(sent.exists, "a failed send must not also claim the mail went out")
        }
    }

    // MARK: - The app

    private enum AfterSignIn { case shell, gate }

    @discardableResult
    private func launchApp(signedIn: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetPersistedState",
                               "-uiTestForgetSession", serverURL.absoluteString,
                               "-uiTestSeedServer", serverURL.absoluteString,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-surfaceMode", "sidebar=native",
                               "-uiTestLogLevel", "error",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        app.launch()
        if signedIn { signIn(app, expecting: expectedState == "pending" ? .gate : .shell) }
        return app
    }

    private func signIn(_ app: XCUIApplication, expecting: AfterSignIn) {
        let field = app.textFields["loginIDField"]
        XCTAssertTrue(field.waitForExistence(timeout: 40),
                      "the native sign-in must mount against \(serverURL.absoluteString):\n"
                      + "\(app.debugDescription)")
        field.tap()
        field.typeText(loginID)
        let secret = app.secureTextFields["loginPasswordField"]
        XCTAssertTrue(secret.exists)
        secret.tap()
        secret.typeText(password)
        let submit = app.buttons["loginSubmitButton"]
        if submit.isHittable {
            submit.tap()
        } else {
            let go = app.keyboards.buttons["Go"]
            if go.waitForExistence(timeout: 5) {
                go.tap()
            } else {
                submit.tap()
            }
        }
        switch expecting {
        case .shell:
            XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 90),
                          "signing in must reach the shell:\n\(app.debugDescription)")
        case .gate:
            let reached = app.descendants(matching: .any).matching(identifier: "termsOfServiceGate")
                .firstMatch.waitForExistence(timeout: 90)
                || element(app, "nativeShell").waitForExistence(timeout: 5)
            XCTAssertTrue(reached, "signing in must reach the gate (or a shell, if the fixture is "
                          + "not pending):\n\(app.debugDescription)")
        }
    }

    // MARK: - The server, from the test process

    private struct Credential { let token: String; let userID: String; let email: String }

    private func ping() throws {
        let (status, _) = api("GET", "api/v4/system/ping")
        try XCTSkipUnless(status == 200, "no Mattermost server at \(serverURL.absoluteString)")
    }

    /// One login, used for both halves: the token (header) and the user (body).
    private func login() throws -> Credential {
        let (status, data, headers) = apiRaw("POST", "api/v4/users/login",
                                             body: ["login_id": loginID!, "password": password!])
        try XCTSkipUnless(status == 200, "the fixture account did not log in (status \(status))")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let user = try XCTUnwrap(json["id"] as? String, "the login answer carried no user id")
        let token = try XCTUnwrap(headers["Token"] ?? headers["token"],
                                  "the login answer carried no Token header")
        let email = (json["email"] as? String) ?? "\(loginID!)@example.com"
        return Credential(token: token, userID: user, email: email)
    }

    private func currentDocumentID(token: String) -> String? {
        let (status, data) = api("GET", "api/v4/terms_of_service", token: token)
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    private func userAcceptedTermsID(token: String, userID: String) -> String? {
        let (status, data) = api("GET", "api/v4/users/\(userID)/terms_of_service", token: token)
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["terms_of_service_id"] as? String
    }

    private func userID(forEmail email: String, token: String) throws -> String? {
        let escaped = email.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "@.-_"))) ?? email
        let (status, data) = api("GET", "api/v4/users/email/\(escaped)", token: token)
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["email"] as? String
    }

    private func api(_ method: String, _ path: String,
                     body: [String: Any]? = nil,
                     token: String? = nil) -> (Int, Data) {
        let (status, data, _) = apiRaw(method, path, body: body, token: token)
        return (status, data)
    }

    private func apiRaw(_ method: String, _ path: String,
                        body: [String: Any]? = nil,
                        token: String? = nil) -> (Int, Data, [String: String]) {
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 20
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        var status = -1
        var payload = Data()
        var headers: [String: String] = [:]
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? -1
            payload = data ?? Data()
            if let http = response as? HTTPURLResponse {
                for (key, value) in http.allHeaderFields {
                    headers[String(describing: key)] = String(describing: value)
                }
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 25)
        return (status, payload, headers)
    }

    // MARK: - Elements

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Fill a `SecureField` through the pasteboard.
    ///
    /// Measured on this simulator: `XCUIElement.typeText` into the sign-up sheet's `SecureField`
    /// lands **one** character (the field reads `•` and the form says "at least 8 characters"),
    /// while the same call on the plain `TextField` above, and on the sign-in form's
    /// `SecureField`, works. A single paste is one insertion into the same control, so the test
    /// still drives the app's own field — it just does not depend on per-key event delivery.
    private func fillSecureField(_ field: XCUIElement, with text: String, app: XCUIApplication) {
        UIPasteboard.general.string = text
        field.tap()
        field.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"]
        if paste.waitForExistence(timeout: 5) {
            paste.tap()
        } else {
            field.typeText(text)
        }
    }

    private func attachment(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
