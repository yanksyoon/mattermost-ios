// T9dd73395 — the rules behind the account menu, with no network and no clock.
//
// Behaviour reference: mattermost/mattermost master @ `987e5712…` (webapp v12.0.1),
// `webapp/channels/src/components/user_account_menu/` + `components/reset_status_modal/`.
// Licence: Apache-2.0 — behaviour reimplemented; attribution in docs/THIRD_PARTY_NOTICES.md §18.
//
// Every server fact these assert is measured on the pinned 9.11.19 server with
// `scripts/t_9dd73395_ooo_probe.py` and `scripts/t_9dd73395_dnd_pref_probe.py`:
//   * `PUT /users/{id}/status {"status":"ooo"}` → **400** (and `"out_of_office"` too): Out of office
//     is the server's own value, set by automatic replies, and the menu can only read/leave it;
//   * `dnd_end_time` is echoed in **seconds**, not milliseconds;
//   * `auto_reset_manual_status` round-trips through `PUT/GET /users/{id}/preferences`, `name` = id.
//
// The mapping the failing-first list names, test by test:
//   (1) control shows the server's status      → testTheControlShowsTheStatusTheServerReports
//   (2) four statuses issue the right PUT      → testEachStatusRowIssuesTheRightWriteAndMovesTheDot
//   (3) custom status round-trip + relaunch    → testACustomStatusRoundTripsSurvivesARelaunchAndClears
//   (4) expired custom status is not "set"     → testAnExpiredCustomStatusIsNotRenderedAsSet
//   (5) OOO asks only while the pref is unset  → testLeavingOutOfOfficeAsksOnlyWhileThePreferenceIsUnset
//   (6) sign out clears session → sign-in      → testSignOutFromTheMenuClearsTheSessionTheCookieAndRevokes
//   (7) a failed PUT keeps the old status      → testAFailedStatusWriteKeepsThePreviousStatusAndSaysSo
// Adversarial controls: (1) fails if the dot reads a local enum (the fake's answer is never the
// model's initial `.unknown`), (4) fails if the expiry check is dropped, (5) fails if the
// confirmation is skipped.

import XCTest
@testable import Mattermost

@MainActor
final class T9dd73395AccountMenuTests: XCTestCase {

    private let myID = "user0000000000000000000001"
    private let serverID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
    private let serverURL = URL(string: "https://mm.example.com")!
    /// One clock for every test, injected — a test that slept to see an expiry would be testing the
    /// runner. Static so it can be the default argument of `model(_:now:)`.
    private static let frozenNow = Date(timeIntervalSince1970: 1_793_000_000)
    private var fixedNow: Date { Self.frozenNow }

    // MARK: - A fake that behaves like the server where it matters

    /// Answers from memory and records every call. The three behaviour-carrying pieces:
    ///
    ///  * a custom-status write lands in `props.customStatus` **as JSON**, exactly where the server
    ///    keeps it (so a "relaunch" model reads it back rather than the fake remembering a Swift
    ///    value);
    ///  * `dnd_end_time` is answered back in the same unit it was given (seconds);
    ///  * a failed preference save is a separate switch from a failed presence write, because the menu
    ///    treats them differently (one raises the alert, one does not).
    @MainActor
    final class FakeAccountService: ProfileServing {
        var profiles: [String: MMUserProfile] = [:]
        var statusesByID: [String: MMStatus] = [:]
        var preferences: [MMPreference] = []

        var profileFailure: Error?
        var presenceFailure: Error?
        var customStatusFailure: Error?
        var clearFailure: Error?
        var preferenceReadFailure: Error?
        var preferenceSaveFailure: Error?

        private(set) var profileRequests: [String] = []
        private(set) var statusRequests: [[String]] = []
        private(set) var presenceWrites: [(presence: UserPresence, dndEndTime: Int64?, userID: String)] = []
        private(set) var customStatusWrites: [CustomStatusBody] = []
        private(set) var clearWrites = 0
        private(set) var preferenceReads = 0
        private(set) var preferenceWrites: [[MMPreference]] = []

        func profile(id: String) async throws -> MMUserProfile {
            profileRequests.append(id)
            if let profileFailure { throw profileFailure }
            guard let profile = profiles[id] else { throw MMError.notFound }
            return profile
        }

        func statuses(ids: [String]) async throws -> [MMStatus] {
            statusRequests.append(ids)
            return ids.compactMap { statusesByID[$0] }
        }

        func setPresence(_ presence: UserPresence, dndEndTime: Int64?,
                         userID: String) async throws -> MMStatus {
            presenceWrites.append((presence, dndEndTime, userID))
            if let presenceFailure { throw presenceFailure }
            let answer = MMStatus(userId: userID, status: presence.rawValue,
                                  manual: presence.setsManualFlag,
                                  lastActivityAt: 1_790_000_000_000,
                                  dndEndTime: dndEndTime ?? 0)
            statusesByID[userID] = answer
            return answer
        }

        func setCustomStatus(userID: String, body: CustomStatusBody) async throws {
            customStatusWrites.append(body)
            if let customStatusFailure { throw customStatusFailure }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(ProfileTimestamp.string(from: date))
            }
            let json = (try? encoder.encode(body)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            profiles[userID]?.props["customStatus"] = json
        }

        func clearCustomStatus(userID: String) async throws {
            clearWrites += 1
            if let clearFailure { throw clearFailure }
            profiles[userID]?.props["customStatus"] = ""
        }

        func directChannel(myUserID: String, otherUserID: String) async throws -> MMChannel {
            MMChannel(id: "dm1", name: "a__b", displayName: "", type: "D", teamId: "")
        }

        func preferences(userID: String) async throws -> [MMPreference] {
            preferenceReads += 1
            if let preferenceReadFailure { throw preferenceReadFailure }
            return preferences
        }

        func savePreferences(userID: String, rows: [MMPreference]) async throws {
            preferenceWrites.append(rows)
            if let preferenceSaveFailure { throw preferenceSaveFailure }
            for row in rows {
                preferences.removeAll { $0.category == row.category && $0.name == row.name }
                preferences.append(row)
            }
        }
    }

    // MARK: - Fixtures

    private func profile(id: String? = nil,
                         username: String = "perfprobe",
                         firstName: String = "Perf",
                         lastName: String = "Probe",
                         props: [String: String] = [:]) -> MMUserProfile {
        MMUserProfile(id: id ?? myID, username: username, firstName: firstName, lastName: lastName,
                      nickname: "", position: "Engineer", email: "perfprobe@example.invalid",
                      roles: "system_user", props: props,
                      timezone: nil, createAt: 1_700_000_000_000, updateAt: 1_790_000_000_000,
                      deleteAt: 0, lastActivityAt: 1_790_000_000_000, authService: "", isBot: false)
    }

    private func model(_ service: ProfileServing,
                       now: @escaping () -> Date = { T9dd73395AccountMenuTests.frozenNow }) -> ProfileViewModel {
        ProfileViewModel(serverID: serverID,
                         userID: myID,
                         myUserID: myID,
                         service: service,
                         now: now,
                         calendar: Calendar(identifier: .gregorian))
    }

    /// A custom status the way the server stores it — a JSON string inside `props`.
    private func customStatusProps(emoji: String, text: String,
                                   duration: String = "", expiresAt: String = "0001-01-01T00:00:00Z") -> [String: String] {
        let json = "{\"emoji\":\"\(emoji)\",\"text\":\"\(text)\",\"duration\":\"\(duration)\",\"expires_at\":\"\(expiresAt)\"}"
        return ["customStatus": json]
    }

    // MARK: - (1) The control shows the server's status, not a local enum

    /// The adversarial control this test exists for: "make the dot read a local enum instead of the
    /// server → test (1) must fail". The fake answers `away`, then `offline`; a model that defaulted
    /// to `online` (or kept its first guess) cannot pass both steps.
    func testTheControlShowsTheStatusTheServerReports() async {
        let service = FakeAccountService()
        service.profiles[myID] = profile()
        service.statusesByID[myID] = MMStatus(userId: myID, status: "away", manual: true)
        let model = model(service)

        await model.loadAccountMenu()

        XCTAssertEqual(model.presence, .away, "the dot is GET /users/{id}/status, not a default")
        XCTAssertEqual(model.status?.presence, .away)
        XCTAssertEqual(service.statusRequests, [[myID]])

        // Re-reading picks up a change made on another device (the same read the control's `.task`
        // performs when the model was already warm).
        service.statusesByID[myID] = MMStatus(userId: myID, status: "offline", manual: true)
        await model.load()
        XCTAssertEqual(model.presence, .offline)
    }

    // MARK: - (2) Each of the four statuses

    func testEachStatusRowIssuesTheRightWriteAndMovesTheDot() async {
        let service = FakeAccountService()
        service.profiles[myID] = profile()
        service.statusesByID[myID] = MMStatus(userId: myID, status: "online")
        let model = model(service)
        await model.load()

        for presence in UserPresence.selectable {
            await model.setPresence(presence, dndEndTimeSeconds: nil)

            XCTAssertEqual(service.presenceWrites.last?.presence, presence)
            XCTAssertEqual(service.presenceWrites.last?.userID, myID)
            XCTAssertNil(service.presenceWrites.last?.dndEndTime,
                         "\(presence.rawValue) carries no dnd_end_time")
            XCTAssertEqual(model.presence, presence, "the dot follows the row that was pressed")
            XCTAssertTrue(model.accountMenuItems.contains(.status(presence)),
                          "\(presence.rawValue) is one of the menu's four status rows")
        }
        XCTAssertEqual(service.presenceWrites.count, UserPresence.selectable.count)
        XCTAssertEqual(service.presenceWrites.map(\.presence), UserPresence.selectable)
        XCTAssertNil(model.banner)
    }

    func testADoNotDisturbEndTimeIsSentInSeconds() async {
        let service = FakeAccountService()
        service.profiles[myID] = profile()
        service.statusesByID[myID] = MMStatus(userId: myID, status: "online")
        let model = model(service)
        await model.load()

        // 30 minutes, as the DND sub-menu's second row.
        let seconds = AccountMenuRules.DNDChoice.thirtyMinutes.endTimeSeconds(from: fixedNow)
        await model.setPresence(.dnd, dndEndTimeSeconds: seconds)

        XCTAssertEqual(service.presenceWrites.last?.dndEndTime, Int64(fixedNow.timeIntervalSince1970) + 1800)
        XCTAssertLessThan(service.presenceWrites.last?.dndEndTime ?? .max, 100_000_000_000,
                          "a millisecond value would be ~1.79e12 — the server reads this as seconds")
        XCTAssertEqual(model.status?.dndEndTime, fixedNow.addingTimeInterval(1800))
    }

    func testTheDNDSubMenuIsUpstreamsListWithSecondsAndTomorrowAtNine() {
        let choices = AccountMenuRules.DNDChoice.allCases
        XCTAssertEqual(choices.map(\.title),
                       ["Don't clear", "30 mins", "1 hour", "2 hours", "Tomorrow"])
        XCTAssertNil(choices[0].endTimeSeconds(from: fixedNow), "\"Don't clear\" omits dnd_end_time")
        XCTAssertEqual(choices[1].endTimeSeconds(from: fixedNow),
                       Int64(fixedNow.timeIntervalSince1970) + 1800)
        XCTAssertEqual(choices[2].endTimeSeconds(from: fixedNow),
                       Int64(fixedNow.timeIntervalSince1970) + 3600)
        XCTAssertEqual(choices[3].endTimeSeconds(from: fixedNow),
                       Int64(fixedNow.timeIntervalSince1970) + 7200)

        let calendar = Calendar(identifier: .gregorian)
        let tomorrow = try? XCTUnwrap(choices[4].endTimeSeconds(from: fixedNow))
        let date = Date(timeIntervalSince1970: TimeInterval(tomorrow ?? 0))
        XCTAssertEqual(calendar.component(.hour, from: date), 9)
        XCTAssertEqual(calendar.component(.minute, from: date), 0)
        XCTAssertNotEqual(calendar.startOfDay(for: date), calendar.startOfDay(for: fixedNow))
    }

    // MARK: - (3) Custom status round-trip, and a relaunch

    func testACustomStatusRoundTripsSurvivesARelaunchAndClears() async {
        let service = FakeAccountService()
        service.profiles[myID] = profile()
        service.statusesByID[myID] = MMStatus(userId: myID, status: "online")

        let first = model(service)
        await first.load()
        XCTAssertFalse(first.isCustomStatusSet)

        let draft = CustomStatusDraft(emoji: "coffee", text: "Vacation",
                                      duration: .oneHour, customExpiry: nil)
        let saved = await first.saveCustomStatus(draft)
        XCTAssertTrue(saved)
        XCTAssertTrue(first.isCustomStatusSet, "the pill draws the status the server accepted")
        XCTAssertEqual(service.customStatusWrites.last?.emoji, "coffee")
        XCTAssertEqual(service.customStatusWrites.last?.text, "Vacation")
        XCTAssertEqual(service.customStatusWrites.last?.duration, "one_hour")

        // "Relaunch": a brand-new model over the same server state (the fake stores into `props`, as
        // the server does). Nothing about the status is remembered locally.
        let relaunched = model(service)
        await relaunched.loadAccountMenu()
        XCTAssertTrue(relaunched.isCustomStatusSet, "the status survives a relaunch")
        XCTAssertEqual(relaunched.profile?.customStatus?.text, "Vacation")
        XCTAssertEqual(relaunched.activeCustomStatus?.emoji, "coffee")
        XCTAssertTrue(relaunched.accountMenuItems.contains(.customStatus))
        XCTAssertFalse(relaunched.accountMenuItems.contains(.setCustomStatus))

        let cleared = await relaunched.clearCustomStatus()
        XCTAssertTrue(cleared)
        XCTAssertEqual(service.clearWrites, 1)
        XCTAssertFalse(relaunched.isCustomStatusSet)
        XCTAssertTrue(relaunched.accountMenuItems.contains(.setCustomStatus),
                      "a cleared status offers \"Set a custom status\" again")

        // An emoji-only and a text-only status both save (the card asks for both).
        let emojiOnly = CustomStatusDraft(emoji: "coffee", text: "", duration: .doNotClear)
        XCTAssertTrue(emojiOnly.canSave(at: fixedNow))
        let emojiSaved = await relaunched.saveCustomStatus(emojiOnly)
        XCTAssertTrue(emojiSaved)

        let textOnly = CustomStatusDraft(emoji: "", text: "Focusing", duration: .doNotClear)
        XCTAssertTrue(textOnly.canSave(at: fixedNow))
        let textSaved = await relaunched.saveCustomStatus(textOnly)
        XCTAssertTrue(textSaved)
        XCTAssertEqual(service.customStatusWrites.last?.emoji, "")
        XCTAssertEqual(service.customStatusWrites.last?.text, "Focusing")
    }

    // MARK: - (4) An expired custom status is not set

    /// The adversarial control: "drop the expiry check → test (4) must fail". The server keeps an
    /// expired status in `props` until something clears it, so the only thing that stops this app
    /// drawing it is the rule under test.
    func testAnExpiredCustomStatusIsNotRenderedAsSet() async {
        // Ten days before the frozen clock (`frozenNow` = 2026-10-26T07:33Z); a fixture dated after
        // it would test nothing, which is how the first version of this test was written.
        let expired = "2026-10-16T00:00:00Z"
        let service = FakeAccountService()
        service.profiles[myID] = profile(props: customStatusProps(emoji: "coffee",
                                                                  text: "Back Monday",
                                                                  duration: "date_and_time",
                                                                  expiresAt: expired))
        service.statusesByID[myID] = MMStatus(userId: myID, status: "online")
        let model = model(service)
        await model.loadAccountMenu()

        XCTAssertEqual(model.profile?.customStatus?.text, "Back Monday", "the server still holds it")
        XCTAssertFalse(model.isCustomStatusSet, "an expired custom status is not set")
        XCTAssertNil(model.activeCustomStatus)
        XCTAssertTrue(model.accountMenuItems.contains(.setCustomStatus))
        XCTAssertFalse(model.accountMenuItems.contains(.customStatus),
                       "an expired status must not draw as though it were current")

        // The rule itself, both directions (so a missing `now` in the caller cannot hide here).
        let live = UserCustomStatus(emoji: "coffee", text: "Here",
                                    duration: "date_and_time",
                                    expiresAt: fixedNow.addingTimeInterval(600))
        XCTAssertTrue(AccountMenuRules.isCustomStatusSet(live, now: fixedNow))
        XCTAssertFalse(AccountMenuRules.isCustomStatusSet(live, now: fixedNow.addingTimeInterval(601)))
        XCTAssertFalse(AccountMenuRules.isCustomStatusSet(UserCustomStatus(emoji: "", text: "",
                                                                           duration: "",
                                                                           expiresAt: nil),
                                                          now: fixedNow),
                       "an empty status is not set (upstream's `text.length > 0 || emoji.length > 0`)")
    }

    // MARK: - (5) Out of office

    /// The adversarial control: "skip the OOO confirmation → test (5) must fail".
    func testLeavingOutOfOfficeAsksOnlyWhileThePreferenceIsUnset() async {
        let service = FakeAccountService()
        service.profiles[myID] = profile()
        service.statusesByID[myID] = MMStatus(userId: myID, status: "ooo", manual: true)
        let subject = model(service)
        await subject.loadAccountMenu()

        XCTAssertEqual(subject.presence, .outOfOffice, "`ooo` decodes to Out of office")
        XCTAssertEqual(UserPresence(wire: "ooo"), .outOfOffice)
        XCTAssertFalse(UserPresence.outOfOffice.isSettable,
                       "the server refuses a client-set ooo — measured 400")
        XCTAssertTrue(subject.accountMenuItems.contains(.outOfOffice),
                      "Out of office has its own row while it is the current status")

        // Panel 1: no row on the server → unset → ask.
        XCTAssertEqual(subject.autoResetPreference, "")
        XCTAssertTrue(subject.shouldConfirmBeforeStatusChange)

        // Panel 2: the reader answered "don't ask me again" on this or another client.
        service.preferences = [AccountMenuRules.autoResetPreference(userID: myID, dontAskAgain: true)]
        await subject.loadAutoResetPreference()
        XCTAssertEqual(subject.autoResetPreference, "true")
        XCTAssertFalse(subject.shouldConfirmBeforeStatusChange)

        // Panel 3: "false" means ask again — upstream's other checkbox answer.
        service.preferences = [AccountMenuRules.autoResetPreference(userID: myID, dontAskAgain: false)]
        await subject.loadAutoResetPreference()
        XCTAssertTrue(subject.shouldConfirmBeforeStatusChange)

        // Panel 4: a failed read is not an answer → ask (the safe direction).
        let unread = model(FakeAccountServiceFailingPreferences(), now: { self.fixedNow })
        await unread.loadAccountMenu()
        XCTAssertNil(unread.autoResetPreference)
        XCTAssertTrue(AccountMenuRules.shouldConfirmBeforeStatusChange(preferenceValue: unread.autoResetPreference,
                                                                       status: .outOfOffice))

        // Writing the answer: upstream's row, and only adopted once the server accepted it.
        await subject.setAutoResetPreference(dontAskAgain: true)
        XCTAssertEqual(service.preferenceWrites.last?.first?.category, "auto_reset_manual_status")
        XCTAssertEqual(service.preferenceWrites.last?.first?.name, myID)
        XCTAssertEqual(service.preferenceWrites.last?.first?.value, "true")
        XCTAssertEqual(subject.autoResetPreference, "true")
        XCTAssertFalse(subject.shouldConfirmBeforeStatusChange)
    }

    /// A service whose preference read fails — for panel 4 above.
    @MainActor
    final class FakeAccountServiceFailingPreferences: ProfileServing {
        func profile(id: String) async throws -> MMUserProfile {
            MMUserProfile(id: id, username: "perfprobe", firstName: "Perf", lastName: "Probe",
                          nickname: "", position: "", email: "", roles: "system_user",
                          props: [:], timezone: nil, createAt: 0, updateAt: 0, deleteAt: 0,
                          lastActivityAt: 0, authService: "", isBot: false)
        }
        func statuses(ids: [String]) async throws -> [MMStatus] { [] }
        func setPresence(_ presence: UserPresence, dndEndTime: Int64?, userID: String) async throws -> MMStatus {
            MMStatus(userId: userID, status: presence.rawValue)
        }
        func setCustomStatus(userID: String, body: CustomStatusBody) async throws {}
        func clearCustomStatus(userID: String) async throws {}
        func directChannel(myUserID: String, otherUserID: String) async throws -> MMChannel {
            MMChannel(id: "dm1", name: "a__b", displayName: "", type: "D", teamId: "")
        }
        func preferences(userID: String) async throws -> [MMPreference] {
            throw MMError.client(status: 500, message: "preference read failed")
        }
        func savePreferences(userID: String, rows: [MMPreference]) async throws {}
    }

    func testOutOfOfficeCannotBeWrittenFromTheMenu() async {
        let service = FakeAccountService()
        service.profiles[myID] = profile()
        service.statusesByID[myID] = MMStatus(userId: myID, status: "online")
        let model = model(service)
        await model.load()

        await model.setPresence(.outOfOffice, dndEndTimeSeconds: nil)

        XCTAssertTrue(service.presenceWrites.isEmpty,
                      "no PUT: 9.11.19 answers 400 for status=ooo (measured)")
        XCTAssertEqual(model.presence, .online, "the previous status stays on screen")
        XCTAssertNotNil(model.banner, "and the menu says why")
        XCTAssertTrue(model.banner?.contains("automatic replies") ?? false, model.banner ?? "nil")
    }

    func testLeavingOutOfOfficeUsesUpstreamsConfirmationCopy() {
        XCTAssertEqual(AccountMenuRules.confirmTitle(current: .outOfOffice),
                       "Your status is set to \"Out of office\"")
        XCTAssertEqual(AccountMenuRules.confirmMessage(current: .outOfOffice, new: .online),
                       "Would you like to switch your status to \"Online\" and disable automatic replies?")
        XCTAssertEqual(AccountMenuRules.confirmActionTitle(new: .online), "Set status to \"Online\"")
        XCTAssertEqual(AccountMenuRules.confirmCancelTitle(current: .outOfOffice),
                       "Stay \"Out of office\"")
    }

    // MARK: - (6) Sign out from the menu

    /// Requirement 7, through the same seam the menu's row calls: the session, the webview cookie and
    /// the server-side revocation, ending in the phase that makes the shell draw its sign-in surface
    /// (`NativeShellView.showsAuthSurface`).
    func testSignOutFromTheMenuClearsTheSessionTheCookieAndRevokes() async throws {
        let vault = SecureVault(serviceNamespace: "t9dd-signout-\(UUID().uuidString)",
                                secureStore: InMemorySecretStore())
        let cookies = FakeCookieClearing()
        let transport = FakeAPITransport(stubs: [
            .ok(.json(["id": myID, "username": "perfprobe"], headers: ["Token": "tok-live"])),
            .ok(.json([:]))
        ])
        let auth = AuthCoordinator(vault: vault,
                                   certTrust: CertTrust(serviceNamespace: "t9dd-cert-\(UUID().uuidString)",
                                                        secureStore: InMemorySecretStore()),
                                   cookieClearing: cookies) { config, _ in
            let client = try APIClient(serverURL: config.url,
                                       transport: transport,
                                       retryPolicy: .none,
                                       tokenProvider: { vault.getSecret(key: .authToken, serverURL: config.url) },
                                       sleep: { _ in },
                                       random: { 0 })
            return AuthSession(serverID: config.id, serverURL: config.url, vault: vault, client: client)
        }
        let server = ServerConfig(name: "Test Server", url: serverURL)
        _ = try await auth.signIn(server, loginID: "perfprobe", password: "pw")
        XCTAssertEqual(auth.phase(for: server.id), .signedIn(username: "perfprobe", userID: myID))

        await AccountMenuActions.signOut(server: server, auth: auth)

        XCTAssertEqual(auth.phase(for: server.id), .signedOut,
                       "the phase the shell reads to draw the sign-in surface")
        XCTAssertEqual(auth.authState(for: server), .signedOut)
        XCTAssertNil(vault.getSecret(key: .authToken, serverURL: serverURL),
                     "the stored session is cleared")
        XCTAssertEqual(cookies.cleared.count, 1, "the webview's copy of the same login is cleared")
        XCTAssertEqual(transport.requests.last?.url.path, "/api/v4/users/logout",
                       "and the session is revoked on the server")
    }

    // MARK: - (7) A rejected status write

    func testAFailedStatusWriteKeepsThePreviousStatusAndSaysSo() async {
        let service = FakeAccountService()
        service.profiles[myID] = profile()
        service.statusesByID[myID] = MMStatus(userId: myID, status: "online")
        let model = model(service)
        await model.load()
        XCTAssertEqual(model.presence, .online)

        service.presenceFailure = MMError.client(status: 400,
                                                 message: "Invalid or missing status in request body.")
        await model.setPresence(.dnd, dndEndTimeSeconds: Int64(fixedNow.timeIntervalSince1970) + 1800)

        XCTAssertEqual(service.presenceWrites.count, 1, "the write was attempted")
        XCTAssertEqual(model.presence, .online,
                       "a rejected status must not be left on screen as though it landed")
        XCTAssertNil(model.status?.dndEndTime, "nor its end time")
        XCTAssertFalse(model.isWriting)
        XCTAssertNotNil(model.banner)
        XCTAssertTrue(model.banner?.contains("status") ?? false, model.banner ?? "nil")

        // The next attempt is still possible: the lock is released and the banner is cleared.
        service.presenceFailure = nil
        await model.setPresence(.away, dndEndTimeSeconds: nil)
        XCTAssertEqual(model.presence, .away)
        XCTAssertNil(model.banner)
    }

    func testAnOfflineServerDoesNotShowOnline() async {
        let service = FakeAccountService()
        service.profiles[myID] = profile()
        service.profileFailure = MMError.offline
        service.statusesByID[myID] = MMStatus(userId: myID, status: "online")
        let model = model(service)

        await model.loadAccountMenu()

        XCTAssertEqual(model.presence, .unknown,
                       "a status that could not be read is unknown, never a green dot")
        XCTAssertEqual(model.phase, .failed(ProfileViewModel.loadFailureCopy(MMError.offline)))
        XCTAssertNil(model.selectedPresence, "and no status row is ticked")
    }

    // MARK: - The menu's items and order (requirement 2)

    func testTheMenuIsUpstreamsItemsInUpstreamsOrder() {
        XCTAssertEqual(AccountMenuBuilder.items(presence: .online, customStatusSet: false),
                       [.name, .setCustomStatus,
                        .status(.online), .status(.away), .status(.dnd), .status(.offline),
                        .profile, .logout])

        XCTAssertEqual(AccountMenuBuilder.items(presence: .outOfOffice, customStatusSet: true),
                       [.name, .outOfOffice, .customStatus,
                        .status(.online), .status(.away), .status(.dnd), .status(.offline),
                        .profile, .logout])

        // The separator placement upstream draws: each group starts a new section.
        XCTAssertTrue(AccountMenuItem.name.startsGroup)
        XCTAssertTrue(AccountMenuItem.outOfOffice.startsGroup)
        XCTAssertTrue(AccountMenuItem.setCustomStatus.startsGroup)
        XCTAssertTrue(AccountMenuItem.status(.online).startsGroup)
        XCTAssertFalse(AccountMenuItem.status(.away).startsGroup)
        XCTAssertTrue(AccountMenuItem.profile.startsGroup)
        XCTAssertTrue(AccountMenuItem.logout.startsGroup)
    }

    // MARK: - Requirement 8: Do not disturb agrees with the notification path

    func testDoNotDisturbSuppressesMentionBannersUntilItsWindowEnds() {
        let reader = MentionReader(userID: "me",
                                   keys: MentionKeys.derive(username: "perfprobe", firstName: "Percy",
                                                            notifyProps: nil, firstNameMentions: false,
                                                            channelMentions: true, extraKeys: []),
                                   desktopNotify: "mention", desktopSound: true)
        let post = MMPost(id: "post1", createAt: 1_700_000_000_000, deleteAt: 0, userId: "buddy",
                          channelId: "ch1", message: "hey @perfprobe look", type: "")
        let channel = MMChannel(id: "ch1", name: "t43-notify", displayName: "T43 notify",
                                type: "O", teamId: "team1")

        func decision(_ status: UserStatusSnapshot?) -> MentionDecision {
            MentionNotificationPolicy.decision(post: post, reader: reader, channel: channel,
                                               membership: nil, myStatus: status, now: fixedNow)
        }

        XCTAssertEqual(decision(nil), .deliver(silent: false), "no status read never suppresses")
        XCTAssertEqual(decision(UserStatusSnapshot(userID: "me", presence: .online)),
                       .deliver(silent: false))
        XCTAssertEqual(decision(UserStatusSnapshot(userID: "me", presence: .away)),
                       .deliver(silent: false), "away still notifies (upstream's copy says so)")
        XCTAssertEqual(decision(UserStatusSnapshot(userID: "me", presence: .dnd)),
                       .drop(.doNotDisturb), "an open-ended DND suppresses")
        XCTAssertEqual(decision(UserStatusSnapshot(userID: "me", presence: .dnd,
                                                   dndEndTime: fixedNow.addingTimeInterval(600))),
                       .drop(.doNotDisturb), "an unexpired window suppresses")
        XCTAssertEqual(decision(UserStatusSnapshot(userID: "me", presence: .dnd,
                                                   dndEndTime: fixedNow.addingTimeInterval(-1))),
                       .deliver(silent: false), "an elapsed window does not")
        XCTAssertTrue(MentionDropReason.doNotDisturb.recordsAsHandled,
                      "a suppressed mention is not delivered later by the poll")

        // The same predicate the coordinator exposes to the feed.
        let snapshot = UserStatusSnapshot(userID: "me", presence: .dnd,
                                          dndEndTime: fixedNow.addingTimeInterval(60))
        XCTAssertTrue(snapshot.suppressesNotifications(at: fixedNow))
        XCTAssertFalse(snapshot.suppressesNotifications(at: fixedNow.addingTimeInterval(61)))
        XCTAssertFalse(UserStatusSnapshot(userID: "me", presence: .outOfOffice)
            .suppressesNotifications(at: fixedNow),
                       "OOO is about automatic replies, not about my own banners")

        // A stale end time cannot suppress: 9.11.19's `updateUserStatus` never clears `dnd_end_time`
        // when the status moves off `dnd` (probe Case 3), so a snapshot like this is what a reader
        // gets after leaving Do not disturb.
        XCTAssertFalse(UserStatusSnapshot(userID: "me", presence: .online,
                                          dndEndTime: fixedNow.addingTimeInterval(3600))
            .suppressesNotifications(at: fixedNow))
        XCTAssertEqual(decision(UserStatusSnapshot(userID: "me", presence: .online,
                                                   dndEndTime: fixedNow.addingTimeInterval(3600))),
                       .deliver(silent: false))
    }

    // MARK: - The wire shape requirement 4 rides on

    /// `PUT /users/{id}/status/custom` answers 400 unless a `duration` comes with a future
    /// `expires_at` (`model.CustomStatus.AreDurationAndExpirationTimeValid`); `scripts/
    /// t_9dd73395_custom_status_probe.py` Case D is that refusal, Case C is the accepted body. This
    /// pins the encoder to the accepted shape so the menu's editor cannot send the refused one.
    func testTheCustomStatusBodyCarriesTheExpiryTheServerRequires() throws {
        let draft = CustomStatusDraft(emoji: "coffee", text: "For an hour",
                                      duration: .oneHour, customExpiry: nil)
        let body = try XCTUnwrap(draft.body(at: fixedNow, calendar: Calendar(identifier: .gregorian)))
        XCTAssertEqual(body.duration, "one_hour")
        XCTAssertEqual(body.expiresAt, fixedNow.addingTimeInterval(3600))

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body))
            as? [String: Any])
        XCTAssertEqual(json["expires_at"] as? String, "2026-10-26T08:33:20.000Z",
                       "RFC3339 in UTC with milliseconds — Go's time.Time accepts the fraction; "
                       + "scripts/t_9dd73395_custom_status_probe.py Case C2 sends exactly this shape")

        // Emoji-only and text-only: no duration, so no `expires_at` key at all (probe Cases A/B —
        // both accepted with `duration: ""`).
        for draft in [CustomStatusDraft(emoji: "coffee", text: "", duration: .doNotClear),
                      CustomStatusDraft(emoji: "", text: "Focusing", duration: .doNotClear)] {
            let body = try XCTUnwrap(draft.body(at: fixedNow))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body))
                as? [String: Any])
            XCTAssertEqual(json["duration"] as? String, "")
            XCTAssertNil(json["expires_at"], "omitted, not empty: an empty string is a 400")
        }
    }
}
