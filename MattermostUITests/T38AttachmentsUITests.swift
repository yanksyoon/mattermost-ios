// T38 — the attachment surface against a **real** Mattermost server, with every expectation read
// back from that server through its own API.
//
// Why live: the card's criticisms are statements about real bytes. "10 images render and open" means
// ten files the server actually stores, decoded by `UIImage`; "a hostile file never executes" means a
// page the server actually serves, refused by a running app. A stub would only prove that this file's
// own fixture agrees with itself.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 — `app/components/files/files.tsx`
// (grid + rows), `app/screens/gallery/` (paging, counter, share/save), `app/screens/pdf_viewer/`,
// `app/screens/code/`. Apache-2.0; no upstream source copied.
//
// Fixture: `scripts/t38_attachment_seed.py` creates channel #t38-files with **two** posts
// (`props.t38_key = t38-images` / `t38-files`). Two, not one, because "attachments per message" is a
// hard server cap of 10 (Mattermost product limits; `POST /posts` answers 400
// `model.post.is_valid.file_ids.app_error` for 16 file ids — measured on the pinned 9.11.19, see
// docs/t38-build-note.md §2). The fourteen-file case itself is covered by the unit suite, which
// decodes a 14-attachment `metadata.files` payload directly
// (`T38AttachmentDecodingTests.testAFourteenFilePostDecodesIntoImagesAndFileRows`).
//
// Run (local throwaway server; credentials are the throwaway dev account in `scripts/perf_seed.py`):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim "iPhone 17 Pro" \
//       --only-testing MattermostUITests/T38AttachmentsUITests
//
// Every test skips (never fails) when the environment or the fixture is missing.

import XCTest

final class T38AttachmentsUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!
    private var channelID: String!
    private var channelName = "t38-files"

    /// The two fixture posts, read from the channel by their `props.t38_key` marker.
    private var imagesPost: [String: Any] = [:]
    private var filesPost: [String: Any] = [:]
    private var imageFiles: [[String: Any]] = []
    private var otherFiles: [[String: Any]] = []

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live attachment test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        let session = try authenticate(login: loginID, password: password)
        token = session.token
        userID = session.userID
        guard let team = try teamsForMe().first(where: { $0["name"] as? String == "perf" }) else {
            throw XCTSkip("team #perf is missing — run scripts/perf_seed.py")
        }
        teamID = team["id"] as? String
        guard let channel = try channel(named: channelName, in: teamID) else {
            throw XCTSkip("channel #\(channelName) is missing — run scripts/t38_attachment_seed.py")
        }
        channelID = try XCTUnwrap(channel["id"] as? String)
        try loadFixture()
    }

    // MARK: - 1. Ten images: the grid, and the gallery across all of them

    /// The card's first criterion for the image half: a post with ten image attachments draws ten
    /// thumbnails, and tapping one opens a gallery that pages through **all ten** of that post's
    /// images, with the counter naming the server's own set.
    func testATenImagePostDrawsEveryThumbnailAndTheGalleryPagesThroughAllOfThem() throws {
        let postID = try XCTUnwrap(imagesPost["id"] as? String)
        XCTAssertEqual(imageFiles.count, 10, "the fixture must carry ten images")
        let app = launchAndOpenChannel()
        XCTAssertTrue(revealPost(app, postID).exists,
                      "the fixture post must be a row of the channel:\n\(app.debugDescription)")

        // Every one of the ten is drawn as a cell of the grid, in the server's order.
        XCTAssertTrue(element(app, "post.\(postID).attachments").waitForExistence(timeout: 20),
                      "the attachment section must expose post.<id>.attachments:\n\(app.debugDescription)")
        for file in imageFiles {
            let fileID = try XCTUnwrap(file["id"] as? String)
            XCTAssertTrue(element(app, "post.\(postID).attachment.\(fileID)").waitForExistence(timeout: 20),
                          "image \(file["name"] ?? fileID) must be drawn:\n\(app.debugDescription)")
        }
        attach(app, "t38-01-ten-image-grid")

        // Tapping the first opens the gallery at page 1 of 10.
        let firstID = try XCTUnwrap(imageFiles[0]["id"] as? String)
        element(app, "post.\(postID).attachment.\(firstID)").tap()
        XCTAssertTrue(element(app, "attachmentGallery").waitForExistence(timeout: 20),
                      "a tapped image must open the full-screen gallery:\n\(app.debugDescription)")
        XCTAssertEqual(element(app, "attachmentGallery.counter").label, "1 of 10",
                       "the counter names this post's own ten images")
        attach(app, "t38-02-gallery-first-page")

        // Page through to the last one. `TabView(.page)` pages on a horizontal swipe; a wrong gesture
        // shows up as a counter that never moves, which is exactly what this loop asserts.
        let gallery = element(app, "attachmentGallery")
        var page = 1
        var swipes = 0
        while page < 10, swipes < 14 {
            gallery.swipeLeft()
            swipes += 1
            let counter = element(app, "attachmentGallery.counter")
            if counter.exists, let last = Int(counter.label.split(separator: " ").first ?? "0"), last > page {
                page = last
            }
        }
        XCTAssertEqual(page, 10, "the gallery must reach the tenth image (counter read "
                       + "\"\(element(app, "attachmentGallery.counter").label)\")")
        attach(app, "t38-03-gallery-tenth-page")

        element(app, "attachmentGallery.close").tap()
        XCTAssertFalse(element(app, "attachmentGallery").waitForExistence(timeout: 5),
                       "closing returns to the channel, not to a second sheet")
    }

    // MARK: - 2. File rows: type, size, and one safe reader each

    /// The card's second criterion: three files and a PDF render as rows with their type and size, and
    /// tapping each opens the reader that file needs — the text view, PDFKit, or the refusal screen.
    func testTheFileRowsNameTheirTypeAndEachOpensOnlyItsOwnReader() throws {
        let postID = try XCTUnwrap(filesPost["id"] as? String)
        let app = launchAndOpenChannel()
        XCTAssertTrue(revealPost(app, postID).exists,
                      "the fixture post must be a row of the channel:\n\(app.debugDescription)")

        // Every file row is drawn and its accessibility value names the type and the size.
        for file in otherFiles {
            let fileID = try XCTUnwrap(file["id"] as? String)
            let row = element(app, "post.\(postID).attachment.\(fileID)")
            XCTAssertTrue(row.waitForExistence(timeout: 20),
                          "\(file["name"] ?? fileID) must be drawn as a row:\n\(app.debugDescription)")
        }
        let textRow = element(app, "post.\(postID).attachment.\(try fileID(named: "t38-notes.txt"))")
        XCTAssertTrue(textRow.label.contains("t38-notes.txt"),
                      "the row names the server's file name: \(textRow.label)")
        XCTAssertTrue(textRow.label.contains("TXT text"),
                      "the row names the type: \(textRow.label)")
        XCTAssertTrue(textRow.label.contains("B"),
                      "the row names the size: \(textRow.label)")
        let pdfRow = element(app, "post.\(postID).attachment.\(try fileID(named: "t38-report.pdf"))")
        XCTAssertTrue(pdfRow.label.contains("PDF"),
                      "the PDF row says PDF: \(pdfRow.label)")
        attach(app, "t38-04-file-rows")

        // 1. The text file opens in the text reader, showing the server's bytes.
        element(app, "post.\(postID).attachment.\(try fileID(named: "t38-notes.txt"))").tap()
        XCTAssertTrue(element(app, "attachmentPreview.text").waitForExistence(timeout: 25),
                      "a .txt opens the text reader:\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "T38 text attachment")).firstMatch
            .waitForExistence(timeout: 10),
            "the reader must show the file's own bytes:\n\(app.debugDescription)")
        attach(app, "t38-05-text-preview")
        element(app, "attachmentPreview.close").tap()

        // 2. The oversized log is cut at the reader's byte cap and says so.
        element(app, "post.\(postID).attachment.\(try fileID(named: "t38-dump.log"))").tap()
        XCTAssertTrue(element(app, "attachmentPreview.text.truncated").waitForExistence(timeout: 25),
                      "a 400 KB log must be cut at the 256 KB cap and say so:\n\(app.debugDescription)")
        attach(app, "t38-06-text-truncated")
        element(app, "attachmentPreview.close").tap()

        // 3. The PDF opens in PDFKit.
        element(app, "post.\(postID).attachment.\(try fileID(named: "t38-report.pdf"))").tap()
        XCTAssertTrue(element(app, "attachmentPreview.pdf").waitForExistence(timeout: 25),
                      "a PDF opens the PDF reader:\n\(app.debugDescription)")
        attach(app, "t38-07-pdf-preview")
        element(app, "attachmentPreview.close").tap()

        // 4. The zip has no reader: the row is still there, the preview is a plain sentence.
        element(app, "post.\(postID).attachment.\(try fileID(named: "t38-bundle.zip"))").tap()
        XCTAssertTrue(element(app, "attachmentPreview.unsupported").waitForExistence(timeout: 25),
                      "a zip opens the refusal screen:\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "no preview for this file type")).firstMatch.exists,
            "the refusal says there is no reader:\n\(app.debugDescription)")
        attach(app, "t38-08-zip-refused")
        element(app, "attachmentPreview.close").tap()
    }

    // MARK: - 3. Untrusted content never executes

    /// The card's safety criterion. The fixture's `.html` file is a page with a `<script>` that would
    /// retitle the document and print a marker sentence. Opening it must show this client's refusal —
    /// no web view, no rendered page, no marker text anywhere in the tree.
    func testAnHTMLAttachmentIsRefusedAndItsScriptNeverRuns() throws {
        let postID = try XCTUnwrap(filesPost["id"] as? String)
        let htmlID = try fileID(named: "t38-payload.html")
        let app = launchAndOpenChannel()
        XCTAssertTrue(revealPost(app, postID).exists, "the fixture post must be a row")

        element(app, "post.\(postID).attachment.\(htmlID)").tap()
        XCTAssertTrue(element(app, "attachmentPreview.unsupported").waitForExistence(timeout: 25),
                      "an .html attachment must open the refusal screen:\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "not previewed for safety")).firstMatch.exists,
            "the refusal must name safety as the reason:\n\(app.debugDescription)")

        // The page's own content must not be in the tree: its title script sets a marker, and its body
        // carries a sentence a rendered page would show.
        XCTAssertFalse(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "If you can read this")).firstMatch.exists,
            "the page's body must never be rendered:\n\(app.debugDescription)")
        XCTAssertFalse(app.staticTexts["EXECUTED"].exists, "the page's script must never run")
        XCTAssertEqual(app.webViews.count, 0,
                       "there must be no web view on the attachment path at all")
        attach(app, "t38-09-html-refused")
        element(app, "attachmentPreview.close").tap()
    }

    // MARK: - 4. Save reuses the one download path and lands in Downloads

    /// The card's third criterion: saving an image from the gallery is a `DownloadWorker` transfer,
    /// and the Downloads screen shows the same record.
    func testSavingAGalleryImageShowsItInTheDownloadsScreen() throws {
        let postID = try XCTUnwrap(imagesPost["id"] as? String)
        let firstName = try XCTUnwrap(imageFiles[0]["name"] as? String)
        let firstID = try XCTUnwrap(imageFiles[0]["id"] as? String)

        let app = launchAndOpenChannel()
        XCTAssertTrue(revealPost(app, postID).exists, "the images post must be a row")
        element(app, "post.\(postID).attachment.\(firstID)").tap()
        XCTAssertTrue(element(app, "attachmentGallery").waitForExistence(timeout: 20),
                      "the gallery must open before saving")

        element(app, "attachmentGallery.save").tap()
        attach(app, "t38-10-gallery-saved")
        element(app, "attachmentGallery.close").tap()

        // The Downloads screen reads the same `DownloadHistory` journal the row's save wrote to, so a
        // row for the server's own file name is the proof that the save used the one download path.
        app.buttons["downloadsToolbarButton"].tap()
        XCTAssertTrue(element(app, "downloadsView").waitForExistence(timeout: 20),
                      "the Downloads screen must open:\n\(app.debugDescription)")
        let row = element(app, "downloadRow-\(firstName)")
        XCTAssertTrue(row.waitForExistence(timeout: 60),
                      "a file saved from a post must be the journal row Downloads lists "
                      + "(\(firstName)):\n\(app.debugDescription)")

        // The row must reach *Downloaded*, not sit at "0 B · Progressing" — a journal row alone is
        // not a save. The row exposes its size/state as its accessibility value (its label resolves to
        // the thumbnail, "Photo"). Measured before the resume fix: this row existed and never
        // progressed.
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the row must be addressable")
        var status = (row.value as? String) ?? ""
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline, !status.contains("Downloaded") {
            usleep(500_000)
            status = (element(app, "downloadRow-\(firstName)").value as? String) ?? ""
        }
        XCTAssertTrue(status.contains("Downloaded"),
                      "the save must land on disk, the row said: \(status)")
        XCTAssertFalse(status.contains("Progressing"), "the row is no longer in flight: \(status)")
        XCTAssertFalse(status.contains("0 B"),
                       "the row reports the bytes that landed, not the starting zero: \(status)")
        attach(app, "t38-11-downloads-row")
    }

    // MARK: - Fixture

    private func loadFixture() throws {
        let payload = try getJSON("/api/v4/channels/\(channelID!)/posts?per_page=60")
        guard let dict = payload as? [String: Any],
              let posts = dict["posts"] as? [String: Any] else {
            throw XCTSkip("the channel page did not decode")
        }
        var found: [String: [String: Any]] = [:]
        for (_, value) in posts {
            guard let post = value as? [String: Any],
                  let props = post["props"] as? [String: Any],
                  let key = props["t38_key"] as? String else { continue }
            found[key] = post
        }
        guard let images = found["t38-images"], let files = found["t38-files"] else {
            throw XCTSkip("the T38 fixture posts are missing — run scripts/t38_attachment_seed.py")
        }
        imagesPost = images
        filesPost = files
        imageFiles = try metadataFiles(of: images)
        otherFiles = try metadataFiles(of: files)
        try XCTSkipUnless(imageFiles.count == 10, "the images post must carry ten files, has \(imageFiles.count)")
        try XCTSkipUnless(otherFiles.count == 6, "the files post must carry six files, has \(otherFiles.count)")
    }

    /// `metadata.files` of one post, in the server's order.
    private func metadataFiles(of post: [String: Any]) throws -> [[String: Any]] {
        guard let metadata = post["metadata"] as? [String: Any],
              let files = metadata["files"] as? [[String: Any]] else {
            return []
        }
        return files
    }

    private func fileID(named name: String) throws -> String {
        let all = imageFiles + otherFiles
        guard let file = all.first(where: { ($0["name"] as? String) == name }),
              let id = file["id"] as? String else {
            throw XCTSkip("the fixture has no file named \(name)")
        }
        return id
    }

    // MARK: - HTTP (the fixture's own oracle)

    private func ping() throws {
        let url = serverURL.appendingPathComponent("api/v4/system/ping")
        let (_, response) = try synchronous(URLRequest(url: url))
        try XCTSkipUnless((response as? HTTPURLResponse)?.statusCode == 200,
                          "no Mattermost at \(serverURL.absoluteString)")
    }

    private func authenticate(login: String, password: String) throws
        -> (token: String, userID: String, displayName: String) {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/users/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["login_id": login,
                                                                      "password": password])
        let (data, response) = try synchronous(request)
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            throw XCTSkip("could not sign in as \(login): HTTP \(http?.statusCode ?? -1)")
        }
        guard let header = http?.value(forHTTPHeaderField: "Token"),
              let me = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = me["id"] as? String else {
            throw XCTSkip("the login answer carried no token")
        }
        let display = [(me["first_name"] as? String) ?? "", (me["last_name"] as? String) ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " ")
        return (header, id, display.isEmpty ? (me["username"] as? String ?? "") : display)
    }

    private func teamsForMe() throws -> [[String: Any]] {
        try getJSON("/api/v4/users/me/teams") as? [[String: Any]] ?? []
    }

    private func channel(named name: String, in teamID: String) throws -> [String: Any]? {
        var request = URLRequest(url: serverURL.appendingPathComponent(
            "api/v4/teams/\(teamID)/channels/name/\(name)"))
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (data, response) = try synchronous(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func getJSON(_ path: String) throws -> Any {
        // `path` may carry a query string (`?per_page=60`), which `appendingPathComponent` would
        // percent-encode into the path itself — the request then 404s and the fixture "does not
        // decode". A relative URL keeps the query where the server expects it.
        guard let url = URL(string: path, relativeTo: serverURL) else {
            throw XCTSkip("could not build the URL for \(path)")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (data, _) = try synchronous(request)
        return try JSONSerialization.jsonObject(with: data)
    }

    /// An ephemeral session with cookies off: the `Authorization` header is then the only identity a
    /// fixture call can carry, so a fixture read cannot silently belong to the app's session.
    private static let fixtureSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    private func synchronous(_ request: URLRequest) throws -> (Data, URLResponse) {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Self.fixtureSession.dataTask(with: request) { data, response, error in
            box.data = data
            box.response = response
            box.error = error
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 30)
        if let error = box.error { throw error }
        return (box.data ?? Data(), box.response ?? URLResponse())
    }

    /// Mutable box the session callback fills (a URLSession callback is not main-actor isolated).
    private final class ResultBox: @unchecked Sendable {
        var data: Data?
        var response: URLResponse?
        var error: Error?
    }

    // MARK: - App driving

    private func launchArguments(resetState: Bool, forgetSession: Bool) -> [String] {
        var args: [String] = ["-uiTestSeedServer", serverURL.absoluteString,
                              "-uiTestSeedServerName", "Local Mattermost"]
        if resetState { args.insert("-uiTestResetPersistedState", at: 0) }
        if forgetSession { args.append(contentsOf: ["-uiTestForgetSession", serverURL.absoluteString]) }
        // `shell=native` is the alias for the pane host surface (the channel view), which is what
        // draws the post list and therefore the attachments.
        args.append(contentsOf: ["-surfaceMode", "shell=native",
                                 "-surfaceMode", "auth=native",
                                 "-surfaceMode", "sidebar=native",
                                 "-surfaceMode", "composer=native",
                                 "-AppleLanguages", "(en)", "-AppleLocale", "en_US"])
        return args
    }

    private func launchAndOpenChannel() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = launchArguments(resetState: true, forgetSession: true)
        app.launch()
        signIn(app)
        openChannel(app)
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
        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 40),
                      "signing in must reach the shell:\n\(app.debugDescription)")
    }

    private func openChannel(_ app: XCUIApplication) {
        var row = element(app, "channelSidebar.channel.\(channelID!)")
        if !row.waitForExistence(timeout: 20) {
            let team = element(app, "teamSidebar.team.\(teamID!)")
            if team.waitForExistence(timeout: 10) { team.tap() }
            row = element(app, "channelSidebar.channel.\(channelID!)")
        }
        XCTAssertTrue(row.waitForExistence(timeout: 45),
                      "the sidebar must list channel \(channelID ?? ""):\n\(app.debugDescription)")
        row.tap()
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 40),
                      "the channel pane must mount:\n\(app.debugDescription)")
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

    /// A channel row that may be outside the viewport (`LazyVStack`: an off-screen row is not in the
    /// tree at all).
    @discardableResult
    private func revealPost(_ app: XCUIApplication, _ postID: String,
                            maxSwipes: Int = 12) -> XCUIElement {
        let target = element(app, "post.\(postID)")
        guard !target.exists else { return target }
        let list = element(app, "channelPostList")
        var swipes = 0
        while !target.exists, swipes < maxSwipes {
            list.swipeUp(velocity: .fast)
            swipes += 1
        }
        return target
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
