// T41 — the rules behind the profile, presence and custom-status surface, with no network and no clock.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (`app/utils/custom_status.ts`,
// `app/utils/user/index.ts`, `app/actions/remote/user.ts`, `app/screens/user_profile/`).
// Licence: Apache-2.0 — behaviour reimplemented; attribution in docs/THIRD_PARTY_NOTICES.md §18.
//
// Everything here is asserted through the seams the screens actually use:
//   * `MMUserProfile` / `UserCustomStatus` for decoding what the server answers;
//   * `CustomStatusDraft` + `CustomStatusBody` for what a save sends;
//   * `StatusDuration` for the server's duration vocabulary and its expiry arithmetic;
//   * `UserPresence` / `UserStatusSnapshot` for presence;
//   * `AutoAwayRule` for the background/foreground decisions;
//   * `ProfileDateFormat` for every string the screen draws;
//   * `ProfileViewModel` against a fake `ProfileServing` for loads, writes and socket updates.
//
// The measured server facts these are built on are in `ProfileModels.swift`'s header and are
// re-measurable with `scripts/t41_profile_probe.py` against the pinned 9.11.19 server.

import XCTest
@testable import Mattermost

@MainActor
final class T41ProfileTests: XCTestCase {

    private let myID = "user0000000000000000000001"
    private let otherID = "user0000000000000000000002"
    private let serverID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    // MARK: - Fakes

    /// A `ProfileServing` that answers from memory and records every call.
    @MainActor
    final class FakeProfileService: ProfileServing {
        var profiles: [String: MMUserProfile] = [:]
        var statusesByID: [String: MMStatus] = [:]
        var profileFailure: Error?
        var statusFailure: Error?
        var presenceFailure: Error?
        var customStatusFailure: Error?
        var clearFailure: Error?
        var directFailure: Error?
        var directAnswer = MMChannel(id: "dm00000000000000000000001", name: "a__b", displayName: "",
                                     type: "D", teamId: "")
        var avatar: Data?

        private(set) var profileRequests: [String] = []
        private(set) var batchRequests: [[String]] = []
        private(set) var statusRequests: [[String]] = []
        private(set) var presenceWrites: [(presence: UserPresence, dndEndTime: Int64?, userID: String)] = []
        private(set) var customStatusWrites: [(userID: String, body: CustomStatusBody)] = []
        private(set) var clearWrites: [String] = []
        private(set) var directRequests: [(myUserID: String, otherUserID: String)] = []

        func profile(id: String) async throws -> MMUserProfile {
            profileRequests.append(id)
            if let profileFailure { throw profileFailure }
            guard let profile = profiles[id] else { throw MMError.notFound }
            return profile
        }

        func profiles(ids: [String]) async throws -> [MMUserProfile] {
            batchRequests.append(ids)
            return ids.compactMap { profiles[$0] }
        }

        func statuses(ids: [String]) async throws -> [MMStatus] {
            statusRequests.append(ids)
            if let statusFailure { throw statusFailure }
            return ids.compactMap { statusesByID[$0] }
        }

        func setPresence(_ presence: UserPresence, dndEndTime: Int64?,
                         userID: String) async throws -> MMStatus {
            presenceWrites.append((presence, dndEndTime, userID))
            if let presenceFailure { throw presenceFailure }
            return MMStatus(userId: userID, status: presence.rawValue,
                            manual: presence.setsManualFlag,
                            lastActivityAt: 1_790_000_000_000)
        }

        func setCustomStatus(userID: String, body: CustomStatusBody) async throws {
            customStatusWrites.append((userID, body))
            if let customStatusFailure { throw customStatusFailure }
        }

        func clearCustomStatus(userID: String) async throws {
            clearWrites.append(userID)
            if let clearFailure { throw clearFailure }
        }

        func directChannel(myUserID: String, otherUserID: String) async throws -> MMChannel {
            directRequests.append((myUserID, otherUserID))
            if let directFailure { throw directFailure }
            return directAnswer
        }

        func profileImage(userID: String, lastUpdateAt: Int64) async -> Data? { avatar }
    }

    private func profile(id: String = "user0000000000000000000001",
                         username: String = "probe",
                         firstName: String = "Perf",
                         lastName: String = "Probe",
                         roles: String = "system_user",
                         props: [String: String] = [:],
                         nickname: String = "",
                         position: String = "",
                         deleteAt: Int64 = 0,
                         createAt: Int64 = 1_700_000_000_000,
                         lastActivityAt: Int64 = 1_790_000_000_000,
                         isBot: Bool = false) -> MMUserProfile {
        MMUserProfile(id: id, username: username, firstName: firstName, lastName: lastName,
                      nickname: nickname, position: position, email: "probe@example.invalid",
                      roles: roles, props: props,
                      timezone: MMUserTimezone(automaticTimezone: "America/Vancouver",
                                               manualTimezone: "", useAutomatic: true),
                      createAt: createAt, updateAt: 0, deleteAt: deleteAt,
                      lastActivityAt: lastActivityAt, authService: "", isBot: isBot)
    }

    private var fixedNow: Date {
        // 2026-10-26 19:40:00 UTC — the day the fixture server was measured on.
        Date(timeIntervalSince1970: 1_793_043_600)
    }

    private func model(_ service: FakeProfileService,
                       userID: String? = nil,
                       myUserID: String? = nil,
                       now: @escaping () -> Date) -> ProfileViewModel {
        ProfileViewModel(serverID: serverID,
                         userID: userID ?? otherID,
                         myUserID: myUserID ?? myID,
                         service: service,
                         now: now,
                         calendar: Calendar(identifier: .gregorian))
    }

    /// Foundation writes a **narrow no-break space** before AM/PM (U+202F) on current OS versions.
    /// These assertions are about the clock time, not that character, so it is folded to a plain
    /// space rather than baked into every expectation.
    private func foldSpaces(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    // MARK: - Decoding the profile

    func testAProfileDecodesRolesTimezonePropsAndTheCustomStatus() throws {
        let json = """
        {"id":"\(otherID)","username":"avone72453","first_name":"Ada","last_name":"Vone",
         "nickname":"addy","position":"Analyst","email":"ada@example.invalid",
         "roles":"system_admin system_user","props":{"customStatus":"{\\"emoji\\":\\"coffee\\",\\"text\\":\\"Working remotely\\",\\"duration\\":\\"one_hour\\",\\"expires_at\\":\\"2026-10-26T21:15:00.712Z\\"}"},
         "timezone":{"automaticTimezone":"America/Vancouver","manualTimezone":"","useAutomaticTimezone":"true"},
         "create_at":1700000000000,"update_at":0,"delete_at":0,"last_activity_at":null,"is_bot":null}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(MMUserProfile.self, from: json)
        XCTAssertEqual(decoded.id, otherID)
        XCTAssertEqual(decoded.displayName, "Ada Vone")
        XCTAssertEqual(decoded.position, "Analyst")
        XCTAssertEqual(decoded.roleNames, ["system_admin", "system_user"])
        XCTAssertTrue(decoded.isSystemAdmin)
        XCTAssertFalse(decoded.isBot, "`is_bot: null` decodes to false, not to a decode failure")
        XCTAssertEqual(decoded.lastActivityAt, 0, "`null` last_activity_at decodes to 0")
        // `useAutomaticTimezone` is the *string* "true" on the wire (measured).
        XCTAssertTrue(decoded.timezone?.useAutomatic == true)
        XCTAssertEqual(decoded.localTimeZoneID, "America/Vancouver")

        let status = try XCTUnwrap(decoded.customStatus)
        XCTAssertEqual(status.emoji, "coffee")
        XCTAssertEqual(status.text, "Working remotely")
        XCTAssertEqual(status.duration, "one_hour")
        XCTAssertEqual(status.knownDuration, .oneHour)
        XCTAssertNotNil(status.expiresAt)
    }

    func testAManualTimezoneWinsWhenTheUserHasOverriddenTheAutomaticOne() {
        let manual = MMUserTimezone(automaticTimezone: "America/Vancouver",
                                    manualTimezone: "Europe/Berlin",
                                    useAutomatic: false)
        XCTAssertEqual(manual.effectiveZoneID, "Europe/Berlin")
        let automatic = MMUserTimezone(automaticTimezone: "America/Vancouver",
                                       manualTimezone: "Europe/Berlin",
                                       useAutomatic: true)
        XCTAssertEqual(automatic.effectiveZoneID, "America/Vancouver")
        XCTAssertNil(MMUserTimezone().effectiveZoneID, "no zone at all is nil, not the device's zone")
    }

    func testTheDisplayNameChainIsFullNameThenUsernameAndTheNicknameIsNotASubstitute() {
        XCTAssertEqual(profile(firstName: "Ada", lastName: "Vone").displayName, "Ada Vone")
        XCTAssertEqual(profile(firstName: "Ada", lastName: "").displayName, "Ada")
        XCTAssertEqual(profile(username: "probe", firstName: "", lastName: "").displayName, "probe")
        XCTAssertEqual(profile(nickname: "addy").displayName, "Perf Probe")
        XCTAssertTrue(profile().hasFullName)
        XCTAssertFalse(profile(firstName: "", lastName: "").hasFullName)
    }

    func testInitialsFallBackFromNamesToTheUsername() {
        XCTAssertEqual(profile(firstName: "Ada", lastName: "Vone").initials, "AV")
        XCTAssertEqual(profile(firstName: "Ada", lastName: "").initials, "A")
        XCTAssertEqual(profile(username: "probe", firstName: "", lastName: "").initials, "PR")
    }

    func testTheRoleBadgesAreOrderedAndIncludeGuestAndBot() {
        XCTAssertEqual(profile(roles: "system_user").roleLabels, [])
        XCTAssertEqual(profile(roles: "system_admin system_user").roleLabels, [.systemAdmin])
        XCTAssertEqual(profile(roles: "system_guest system_user").roleLabels, [.guest])
        XCTAssertEqual(profile(roles: "system_admin system_guest system_user", isBot: true).roleLabels,
                       [.systemAdmin, .guest, .bot])
    }

    func testADeactivatedAccountIsRecognisedByItsDeleteAt() {
        XCTAssertFalse(profile().isDeactivated)
        XCTAssertTrue(profile(deleteAt: 1).isDeactivated)
    }

    func testAnEmptyOrUnparseableStoredCustomStatusReadsAsNoStatus() {
        XCTAssertNil(profile(props: [:]).customStatus)
        XCTAssertNil(profile(props: ["customStatus": ""]).customStatus,
                     "the server clears a status by storing an empty string")
        XCTAssertNil(profile(props: ["customStatus": "not json"]).customStatus)
        XCTAssertNil(profile(props: ["customStatus": "{\"emoji\":\"\",\"text\":\"\"}"]).customStatus)
    }

    // MARK: - Custom status expiry

    func testAStatusWithTheZeroTimeExpiryNeverExpires() {
        // The server's "no expiry" is the Go zero time, which is a real date in the year 1.
        let status = UserCustomStatus(emoji: "coffee", text: "here", duration: "",
                                      expiresAt: ProfileTimestamp.date(fromServer: "0001-01-01T00:00:00Z"))
        XCTAssertNotNil(status.expiresAt)
        XCTAssertFalse(status.isExpired(at: fixedNow))
        XCTAssertTrue(status.isActive(at: fixedNow))
    }

    func testAStatusWithAFutureExpiryIsActiveAndAPastOneIsNot() {
        let future = UserCustomStatus(emoji: "coffee", text: "here", duration: "one_hour",
                                      expiresAt: fixedNow.addingTimeInterval(600))
        XCTAssertTrue(future.isActive(at: fixedNow))
        let past = UserCustomStatus(emoji: "coffee", text: "here", duration: "one_hour",
                                    expiresAt: fixedNow.addingTimeInterval(-1))
        XCTAssertTrue(past.isExpired(at: fixedNow))
        XCTAssertFalse(past.isActive(at: fixedNow))
    }

    func testAnEmptyCustomStatusIsNeverActive() {
        XCTAssertTrue(UserCustomStatus().isEmpty)
        XCTAssertFalse(UserCustomStatus().isActive(at: fixedNow))
        XCTAssertTrue(UserCustomStatus(emoji: "coffee").isActive(at: fixedNow),
                      "an emoji alone is a status")
    }

    // MARK: - The duration vocabulary

    func testTheDurationWireValuesAreExactlyTheServersVocabulary() {
        // Measured on 9.11.19: anything else (including the obvious "30m"/"1h") is a 400.
        XCTAssertEqual(StatusDuration.allCases.map(\.wireValue),
                       ["", "thirty_minutes", "one_hour", "four_hours", "today", "this_week", "date_and_time"])
        XCTAssertEqual(StatusDuration(wireValue: "one_hour"), .oneHour)
        XCTAssertNil(StatusDuration(wireValue: "1h"))
        XCTAssertNil(StatusDuration(wireValue: "99y"))
    }

    func testFixedDurationsExpireAfterTheirWindow() {
        let calendar = Calendar(identifier: .gregorian)
        XCTAssertEqual(StatusDuration.thirtyMinutes.expiry(from: fixedNow, calendar: calendar),
                       fixedNow.addingTimeInterval(1800))
        XCTAssertEqual(StatusDuration.oneHour.expiry(from: fixedNow, calendar: calendar),
                       fixedNow.addingTimeInterval(3600))
        XCTAssertEqual(StatusDuration.fourHours.expiry(from: fixedNow, calendar: calendar),
                       fixedNow.addingTimeInterval(14_400))
        XCTAssertNil(StatusDuration.doNotClear.expiry(from: fixedNow, calendar: calendar))
        XCTAssertNil(StatusDuration.dateAndTime.expiry(from: fixedNow, calendar: calendar),
                     "date_and_time takes the reader's own date")
    }

    func testTodayAndThisWeekEndAtTheEndOfTheirPeriod() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = try XCTUnwrap(StatusDuration.today.expiry(from: fixedNow, calendar: calendar))
        XCTAssertEqual(calendar.component(.day, from: today),
                       calendar.component(.day, from: fixedNow))
        XCTAssertLessThan(today.timeIntervalSince(fixedNow), 86_400)
        XCTAssertGreaterThan(today.timeIntervalSince(fixedNow), 0)

        let week = try XCTUnwrap(StatusDuration.thisWeek.expiry(from: fixedNow, calendar: calendar))
        XCTAssertGreaterThan(week, today)
        XCTAssertGreaterThan(week.timeIntervalSince(fixedNow), 0)
    }

    func testADoNotDisturbEndTimeIsSentInMilliseconds() {
        let millis = StatusDuration.thirtyMinutes.dndEndTimeMillis(from: fixedNow)
        XCTAssertEqual(millis, Int64((fixedNow.timeIntervalSince1970 + 1800) * 1000))
        XCTAssertNil(StatusDuration.doNotClear.dndEndTimeMillis(from: fixedNow))
    }

    // MARK: - The draft and the body it sends

    func testAnEmptyDraftIsRefusedWithACopyThatSaysWhatIsMissing() {
        let draft = CustomStatusDraft()
        XCTAssertNotNil(draft.validationMessage(at: fixedNow))
        XCTAssertFalse(draft.canSave(at: fixedNow))
        XCTAssertNil(draft.body(at: fixedNow))
    }

    func testTextLongerThanTheServersLimitIsRefusedRatherThanTruncatedSilently() {
        let draft = CustomStatusDraft(text: String(repeating: "a", count: CustomStatusDraft.textLimit + 1))
        XCTAssertNotNil(draft.validationMessage(at: fixedNow))
        let atLimit = CustomStatusDraft(text: String(repeating: "a", count: CustomStatusDraft.textLimit))
        XCTAssertNil(atLimit.validationMessage(at: fixedNow))
        // The limit is counted in *runes*, not bytes: 100 emoji are 100 characters to the server.
        let emoji = CustomStatusDraft(text: String(repeating: "🚀", count: 100))
        XCTAssertNil(emoji.validationMessage(at: fixedNow))
    }

    func testDontClearWithAFutureExpiryIsRefusedBecauseTheServerAnswers400() {
        // Measured: duration "" + a future expires_at fails both branches of the server's validity
        // check, and answers `invalid_body_param`.
        let draft = CustomStatusDraft(emoji: "coffee", duration: .doNotClear,
                                      customExpiry: fixedNow.addingTimeInterval(600))
        XCTAssertNotNil(draft.validationMessage(at: fixedNow))
        XCTAssertNil(draft.body(at: fixedNow))
    }

    func testDateAndTimeNeedsAFutureDate() {
        XCTAssertNotNil(CustomStatusDraft(emoji: "coffee", duration: .dateAndTime)
            .validationMessage(at: fixedNow))
        XCTAssertNotNil(CustomStatusDraft(emoji: "coffee", duration: .dateAndTime,
                                          customExpiry: fixedNow.addingTimeInterval(-60))
            .validationMessage(at: fixedNow))
        XCTAssertNil(CustomStatusDraft(emoji: "coffee", duration: .dateAndTime,
                                       customExpiry: fixedNow.addingTimeInterval(60))
            .validationMessage(at: fixedNow))
    }

    func testTheBodyOmitsTheExpiryWhenTheStatusDoesNotClear() throws {
        let body = try XCTUnwrap(CustomStatusDraft(emoji: "coffee", text: "  here  ")
            .body(at: fixedNow))
        XCTAssertEqual(body.emoji, "coffee")
        XCTAssertEqual(body.text, "here", "the text is trimmed, not sent with the reader's spaces")
        XCTAssertEqual(body.duration, "")
        XCTAssertNil(body.expiresAt)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertNil(json["expires_at"], "the key is omitted, not sent as \"\" (measured 400)")
        XCTAssertEqual(json["duration"] as? String, "")
    }

    func testAFixedDurationAlwaysCarriesAFutureExpiryInRFC3339WithMilliseconds() throws {
        let body = try XCTUnwrap(CustomStatusDraft(emoji: "coffee", duration: .oneHour)
            .body(at: fixedNow))
        let expiry = try XCTUnwrap(body.expiresAt)
        XCTAssertEqual(expiry.timeIntervalSince1970, fixedNow.timeIntervalSince1970 + 3600, accuracy: 1)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertEqual(json["duration"] as? String, "one_hour")
        let raw = try XCTUnwrap(json["expires_at"] as? String)
        XCTAssertTrue(raw.hasSuffix("Z"), "UTC: \(raw)")
        XCTAssertTrue(raw.contains("."), "milliseconds, the shape the server itself answers with: \(raw)")
    }

    func testTodayIsSentWithTheEndOfDayExpiry() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let body = try XCTUnwrap(CustomStatusDraft(text: "off today", duration: .today)
            .body(at: fixedNow, calendar: calendar))
        let expiry = try XCTUnwrap(body.expiresAt)
        XCTAssertGreaterThan(expiry, fixedNow)
        XCTAssertEqual(body.duration, "today")
    }

    func testTheDraftSeededFromAStoredStatusKeepsItsDuration() {
        let status = UserCustomStatus(emoji: "palm_tree", text: "Out", duration: "four_hours",
                                      expiresAt: fixedNow.addingTimeInterval(600))
        let draft = CustomStatusDraft(status: status)
        XCTAssertEqual(draft.emoji, "palm_tree")
        XCTAssertEqual(draft.text, "Out")
        XCTAssertEqual(draft.duration, .fourHours)
        XCTAssertNil(draft.customExpiry)
    }

    func testAnUnknownStoredDurationSeedsDontClearRatherThanCrashing() {
        let status = UserCustomStatus(emoji: "coffee", text: "hi", duration: "next_century")
        XCTAssertEqual(CustomStatusDraft(status: status).duration, .doNotClear)
    }

    // MARK: - Presence

    func testPresenceDecodesOnlyTheServersFourValuesAndEverythingElseIsUnknown() {
        XCTAssertEqual(UserPresence(wire: "online"), .online)
        XCTAssertEqual(UserPresence(wire: "away"), .away)
        XCTAssertEqual(UserPresence(wire: "dnd"), .dnd)
        XCTAssertEqual(UserPresence(wire: "offline"), .offline)
        XCTAssertEqual(UserPresence(wire: "bogus"), .unknown)
        XCTAssertEqual(UserPresence(wire: nil), .unknown)
        XCTAssertEqual(UserPresence.selectable, [.online, .away, .dnd, .offline])
        XCTAssertEqual(UserPresence.unknown.title, "Status unknown",
                       "an unread status is never drawn as offline")
    }

    func testASocketStatusChangeKeepsTheManualFlagAndTheActivityTheReadSupplied() {
        let snapshot = UserStatusSnapshot(userID: otherID, presence: .online, manual: false,
                                          lastActivityAt: fixedNow, dndEndTime: nil)
        let patched = snapshot.applying(socketStatus: "away")
        XCTAssertEqual(patched.presence, .away)
        XCTAssertFalse(patched.manual, "the frame carries no `manual`, so the read's value stands")
        XCTAssertEqual(patched.lastActivityAt, fixedNow)
    }

    func testThePresenceBodySendsTheUserIDTheStatusAndTheDNDEndTimeOnlyWhenThereIsOne() throws {
        let plain = PresenceUpdateBody(userID: myID, presence: .away)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        XCTAssertEqual(json["user_id"] as? String, myID)
        XCTAssertEqual(json["status"] as? String, "away")
        XCTAssertNil(json["dnd_end_time"])

        let dnd = PresenceUpdateBody(userID: myID, presence: .dnd, dndEndTime: 1_793_053_200_000)
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(dnd)) as? [String: Any])
        XCTAssertEqual(json["dnd_end_time"] as? Int64, 1_793_053_200_000)
        XCTAssertEqual(json["status"] as? String, "dnd")
    }

    // MARK: - Auto-away

    func testBackgroundingAgesOnlyAServerDerivedOnlineStatus() {
        XCTAssertEqual(AutoAwayRule.onBackground(current: UserStatusSnapshot(userID: myID, presence: .online,
                                                                            manual: false)),
                       .setAway)
        XCTAssertEqual(AutoAwayRule.onBackground(current: UserStatusSnapshot(userID: myID, presence: .online,
                                                                            manual: true)),
                       .none, "a deliberate online is still a choice the reader made")
        XCTAssertEqual(AutoAwayRule.onBackground(current: UserStatusSnapshot(userID: myID, presence: .dnd)),
                       .none)
        XCTAssertEqual(AutoAwayRule.onBackground(current: UserStatusSnapshot(userID: myID, presence: .away)),
                       .none)
        XCTAssertEqual(AutoAwayRule.onBackground(current: UserStatusSnapshot(userID: myID, presence: .offline)),
                       .none)
        XCTAssertEqual(AutoAwayRule.onBackground(current: nil), .none)
    }

    /// The server echoes this client's own auto-away write back as `status_change`. Adopting that
    /// echo as the restore preference told the return "you already are what you wanted", so the
    /// reader stayed away — measured by the live auto-away test, not guessed.
    func testTheEchoOfMyOwnAutoAwayWriteDoesNotBecomeMyPreference() {
        XCTAssertFalse(AutoAwayRule.adoptsSocketStatus(.away, owningAutoAway: true),
                       "our own echo must not become the status a return restores")
        XCTAssertTrue(AutoAwayRule.adoptsSocketStatus(.away, owningAutoAway: false),
                      "an away written while this app did not auto-away is somebody's choice")
        XCTAssertTrue(AutoAwayRule.adoptsSocketStatus(.dnd, owningAutoAway: true),
                      "a dnd during auto-away came from another client, not from us")
        // And the pairing that matters: the echo is ignored, our own write is recognised, so the
        // return restores instead of finding the preference already satisfied.
        let own = UserStatusSnapshot(userID: myID, presence: .away, manual: true)
        let preferred = UserPresence.online
        XCTAssertEqual(AutoAwayRule.onForeground(current: own, preferred: preferred,
                                                 didAutoAway: true, ownWrite: own),
                       .restore(preferred))
    }

    func testForegroundingRestoresOnlyWhatThisClientChanged() {
        let away = UserStatusSnapshot(userID: myID, presence: .away, manual: false)
        XCTAssertEqual(AutoAwayRule.onForeground(current: away, preferred: .online, didAutoAway: true),
                       .restore(.online))
        XCTAssertEqual(AutoAwayRule.onForeground(current: away, preferred: .online, didAutoAway: false),
                       .none, "nothing was changed, so nothing is restored")
        XCTAssertEqual(AutoAwayRule.onForeground(current: UserStatusSnapshot(userID: myID, presence: .dnd,
                                                                            manual: true),
                                                 preferred: .online,
                                                 didAutoAway: true),
                       .none, "a dnd set from another device while away must survive the return")
        XCTAssertEqual(AutoAwayRule.onForeground(current: UserStatusSnapshot(userID: myID, presence: .online),
                                                 preferred: .online,
                                                 didAutoAway: true),
                       .none, "already back to the preferred status")
        XCTAssertEqual(AutoAwayRule.onForeground(current: away, preferred: .away, didAutoAway: true),
                       .none)
    }

    /// The live auto-away test's finding, pinned: this client's own auto-away write comes back
    /// `manual: true` (measured), so without `ownWrite` the RESTORE was refused and the reader stayed
    /// `away` after coming back to the app. The server's answer to our own write is the one manual
    /// status we may undo; anybody else's is not.
    func testTheClientsOwnAwayWriteIsTheOneManualStatusTheReturnMayUndo() {
        let ourWrite = UserStatusSnapshot(userID: myID, presence: .away, manual: true)
        XCTAssertEqual(AutoAwayRule.onForeground(current: ourWrite, preferred: .online,
                                                 didAutoAway: true, ownWrite: ourWrite),
                       .restore(.online),
                       "our own manual away is ours to put back")

        let somebodyElsesAway = UserStatusSnapshot(userID: myID, presence: .away, manual: true)
        let ourDnd = UserStatusSnapshot(userID: myID, presence: .dnd, manual: true)
        XCTAssertEqual(AutoAwayRule.onForeground(current: UserStatusSnapshot(userID: myID,
                                                                            presence: .dnd,
                                                                            manual: true),
                                                 preferred: .online,
                                                 didAutoAway: true,
                                                 ownWrite: ourWrite),
                       .none, "a dnd somebody else set is theirs")
        XCTAssertEqual(AutoAwayRule.onForeground(current: somebodyElsesAway, preferred: .online,
                                                 didAutoAway: true, ownWrite: ourDnd),
                       .none, "our write was a dnd; the away on the server is not it")
        XCTAssertEqual(AutoAwayRule.onForeground(current: ourWrite, preferred: .online,
                                                 didAutoAway: true, ownWrite: nil),
                       .none, "with no record of our own write, the conservative answer stands")
    }

    // MARK: - The DM shortcut

    func testMessagingIsOfferedForSomebodyElseAndNeverForMyOwnProfile() {
        XCTAssertTrue(DMShortcut.canMessage(profile: profile(id: otherID), myUserID: myID))
        XCTAssertFalse(DMShortcut.canMessage(profile: profile(id: myID), myUserID: myID))
        XCTAssertFalse(DMShortcut.canMessage(profile: profile(), myUserID: nil))
        XCTAssertFalse(DMShortcut.canMessage(profile: profile(id: otherID, deleteAt: 1), myUserID: myID))
        XCTAssertTrue(DMShortcut.canMessage(profile: profile(id: otherID, isBot: true), myUserID: myID),
                      "a bot is messageable — that is how an integration is reached")
        XCTAssertEqual(DMShortcut.unavailableReason(profile: profile(id: myID), myUserID: myID),
                       "This is your own profile.")
        XCTAssertNotNil(DMShortcut.unavailableReason(profile: profile(id: otherID, deleteAt: 1),
                                                     myUserID: myID))
    }

    // MARK: - Formatting

    func testTheLocalTimeLineNamesTheOtherZoneAndSaysSoWhenItCannot() {
        let locale = Locale(identifier: "en_US_POSIX")
        let time = ProfileDateFormat.localTime(zoneID: "UTC", at: fixedNow, locale: locale)
        XCTAssertEqual(foldSpaces(time), "7:40 PM")
        let sentence = ProfileDateFormat.localTimeSentence(zoneID: "UTC", at: fixedNow, locale: locale)
        XCTAssertTrue(sentence.contains("local time"), sentence)
        XCTAssertEqual(ProfileDateFormat.localTimeSentence(zoneID: nil, at: fixedNow, locale: locale),
                       "Local time unknown")
        XCTAssertEqual(ProfileDateFormat.localTimeSentence(zoneID: "Not/AZone", at: fixedNow,
                                                           locale: locale),
                       "Local time unknown")
    }

    func testTheRelativeActivityTextUsesFixedUnits() {
        XCTAssertEqual(ProfileDateFormat.relativeText(from: fixedNow.addingTimeInterval(-10), to: fixedNow),
                       "just now")
        XCTAssertEqual(ProfileDateFormat.relativeText(from: fixedNow.addingTimeInterval(-60), to: fixedNow),
                       "1 minute ago")
        XCTAssertEqual(ProfileDateFormat.relativeText(from: fixedNow.addingTimeInterval(-7200), to: fixedNow),
                       "2 hours ago")
        XCTAssertEqual(ProfileDateFormat.relativeText(from: fixedNow.addingTimeInterval(-172_800), to: fixedNow),
                       "2 days ago")
        XCTAssertEqual(ProfileDateFormat.relativeText(from: fixedNow.addingTimeInterval(-3_000_000), to: fixedNow),
                       "more than a month ago")
    }

    func testLastActiveIsActiveNowForAnOnlineAccountAndUnknownWithoutATimestamp() {
        XCTAssertEqual(ProfileDateFormat.lastActive(presence: .online, lastActivity: nil, now: fixedNow),
                       "Active now")
        XCTAssertEqual(ProfileDateFormat.lastActive(presence: .offline, lastActivity: nil, now: fixedNow),
                       "Last active unknown")
        XCTAssertEqual(ProfileDateFormat.lastActive(presence: .away,
                                                    lastActivity: fixedNow.addingTimeInterval(-300),
                                                    now: fixedNow),
                       "Last active 5 minutes ago")
    }

    func testJoinedSaysWhenTheAccountWasCreated() {
        let joined = ProfileDateFormat.joined(ms: 1_700_000_000_000,
                                             timeZone: TimeZone(identifier: "UTC")!,
                                             locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertEqual(joined, "Joined November 14, 2023")
        XCTAssertNil(ProfileDateFormat.joined(ms: 0))
    }

    func testACustomStatusLineComposesTextAndTheClearTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let todayEnd = StatusDuration.today.expiry(from: fixedNow, calendar: calendar)!
        let status = UserCustomStatus(emoji: "coffee", text: "Working remotely", duration: "today",
                                      expiresAt: todayEnd)
        let text = ProfileDateFormat.customStatusText(status, now: fixedNow,
                                                      timeZone: TimeZone(identifier: "UTC")!,
                                                      locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertEqual(text?.hasPrefix("Working remotely · until "), true, text ?? "nil")
        // The zero time never renders as an expiry.
        let noExpiry = UserCustomStatus(emoji: "coffee", text: "here", duration: "",
                                        expiresAt: ProfileTimestamp.date(fromServer: "0001-01-01T00:00:00Z"))
        XCTAssertEqual(ProfileDateFormat.customStatusText(noExpiry, now: fixedNow), "here")
        // An emoji with no text has no line of its own.
        let emojiOnly = UserCustomStatus(emoji: "coffee", text: "", duration: "")
        XCTAssertNil(ProfileDateFormat.customStatusText(emojiOnly, now: fixedNow))
        // An expired status draws nothing.
        let expired = UserCustomStatus(emoji: "coffee", text: "gone", duration: "one_hour",
                                       expiresAt: fixedNow.addingTimeInterval(-60))
        XCTAssertNil(ProfileDateFormat.customStatusText(expired, now: fixedNow))
    }

    func testDoNotDisturbNamesItsEndTimeWhenTheServerSentOne() {
        let snapshot = UserStatusSnapshot(userID: myID, presence: .dnd,
                                          dndEndTime: fixedNow.addingTimeInterval(3600))
        let sentence = ProfileDateFormat.dndSentence(snapshot, now: fixedNow,
                                                     timeZone: TimeZone(identifier: "UTC")!,
                                                     locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertEqual(foldSpaces(sentence), "Do not disturb until 8:40 PM")
        XCTAssertNil(ProfileDateFormat.dndSentence(UserStatusSnapshot(userID: myID, presence: .dnd),
                                                   now: fixedNow),
                     "no end time means no end-time sentence")
    }

    // MARK: - The view model: loading

    func testLoadReadsTheProfileAndThePresenceAndSaysWhetherItIsMe() async {
        let service = FakeProfileService()
        service.profiles[otherID] = profile(id: otherID, username: "other")
        service.statusesByID[otherID] = MMStatus(userId: otherID, status: "away", manual: true)

        let model = model(service, userID: otherID, myUserID: myID, now: { self.fixedNow })
        await model.load()

        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.profile?.username, "other")
        XCTAssertEqual(model.presence, .away)
        XCTAssertTrue(model.status?.manual == true)
        XCTAssertFalse(model.isMe)
        XCTAssertEqual(service.profileRequests, [otherID])
        XCTAssertEqual(service.statusRequests, [[otherID]])
    }

    func testAFailedLoadIsAnErrorWithNoInventedProfile() async {
        let service = FakeProfileService()
        service.profileFailure = MMError.offline

        let model = model(service, now: { self.fixedNow })
        await model.load()

        XCTAssertNil(model.profile, "a profile is fetched or it is not drawn — never assembled from an id")
        guard case .failed(let message) = model.phase else {
            return XCTFail("expected a failure state, got \(model.phase)")
        }
        XCTAssertTrue(message.contains("offline"), message)
        XCTAssertEqual(model.presence, .unknown)
    }

    func testAFailedRefreshKeepsTheProfileOnScreenAndNamesTheFailure() async {
        let service = FakeProfileService()
        service.profiles[otherID] = profile(id: otherID)
        service.statusesByID[otherID] = MMStatus(userId: otherID, status: "online")
        let model = model(service, now: { self.fixedNow })
        await model.load()
        XCTAssertEqual(model.phase, .loaded)

        service.profileFailure = MMError.timeout
        await model.load(force: true)

        XCTAssertEqual(model.phase, .loaded, "the profile that is already drawn is not blanked")
        XCTAssertNotNil(model.profile)
        XCTAssertNotNil(model.banner)
    }

    /// Measured by T41-AV (F2): reopening a **warm** profile used to issue no read at all, so a
    /// change made while the sheet was closed stayed invisible until the poll fired (15 s in
    /// production; the AV probe measured 60 s with the poll pushed out). The sheet's `.task` runs
    /// `load()`, so a `load()` on a `.loaded` model must read presence once — and only presence:
    /// the profile is already the server's answer, and re-reading it would blink a screen that is
    /// correct.
    func testReopeningAWarmProfileReadsPresenceOnceWithoutReReadingTheProfile() async {
        let service = FakeProfileService()
        service.profiles[otherID] = profile(id: otherID)
        service.statusesByID[otherID] = MMStatus(userId: otherID, status: "online")
        let model = model(service, userID: otherID, now: { self.fixedNow })
        await model.load()
        XCTAssertEqual(service.statusRequests, [[otherID]])
        XCTAssertEqual(service.profileRequests, [otherID])

        // The sheet closes; the colleague goes away while it is shut.
        service.statusesByID[otherID] = MMStatus(userId: otherID, status: "away", manual: true,
                                                 lastActivityAt: 1_790_000_100_000)

        // Opening it again runs `load()` on this same, cached model.
        await model.load()

        XCTAssertEqual(service.statusRequests, [[otherID], [otherID]],
                       "a reopen reads presence once — the row on screen is the server's, not the cache")
        XCTAssertEqual(model.presence, .away, "the reopened sheet shows the status the server holds now")
        XCTAssertEqual(model.status?.manual, true)
        XCTAssertEqual(service.profileRequests, [otherID],
                       "the profile is unchanged, so it is not re-read (no blink)")
        XCTAssertEqual(model.phase, .loaded)
    }

    func testAnEmptyUserIDFailsWithoutARequest() async {
        let service = FakeProfileService()
        let model = model(service, userID: "", now: { self.fixedNow })
        await model.load()
        XCTAssertTrue(service.profileRequests.isEmpty)
        guard case .failed = model.phase else { return XCTFail("expected a failure") }
    }

    // MARK: - The view model: presence refresh (the batched read a socket cannot replace)

    /// Measured, and it is why the loop exists: the server addresses `status_change` to the account
    /// that changed, so a colleague's presence only ever arrives through the batched read.
    func testTheOpenProfileReReadsPresenceFromTheBatchAndDropsAnUnchangedAnswer() async {
        let service = FakeProfileService()
        service.profiles[otherID] = profile(id: otherID)
        service.statusesByID[otherID] = MMStatus(userId: otherID, status: "online")
        let model = model(service, userID: otherID, now: { self.fixedNow })
        await model.load()
        XCTAssertEqual(model.presence, .online)
        let readsAfterLoad = service.statusRequests.count

        // Nothing changed on the server: no state change, and the read still happened.
        await model.refreshPresence()
        XCTAssertEqual(service.statusRequests.count, readsAfterLoad + 1)
        XCTAssertEqual(model.presence, .online)

        // The colleague goes do-not-disturb elsewhere.
        service.statusesByID[otherID] = MMStatus(userId: otherID, status: "dnd", manual: true,
                                                 lastActivityAt: 1_790_000_100_000)
        await model.refreshPresence()
        XCTAssertEqual(model.presence, .dnd)
        XCTAssertEqual(model.status?.manual, true)
    }

    /// A refresh must not run before the profile is drawn (nothing to patch), and a failed poll must
    /// leave the row and the screen alone — a background read is not a reader-visible action.
    func testAPresenceRefreshIsSkippedBeforeTheProfileLoadsAndAFailedPollIsSilent() async {
        let service = FakeProfileService()
        let model = model(service, userID: otherID, now: { self.fixedNow })
        await model.refreshPresence()
        XCTAssertTrue(service.statusRequests.isEmpty, "an idle model has nothing to refresh")

        service.profiles[otherID] = profile(id: otherID)
        service.statusesByID[otherID] = MMStatus(userId: otherID, status: "online")
        await model.load()
        service.statusFailure = MMError.offline
        await model.refreshPresence()
        XCTAssertEqual(model.presence, .online, "a failed poll leaves the row alone")
        XCTAssertNil(model.banner, "a background poll must not put a banner over the profile")
    }

    /// The loop stops when its task is cancelled — that is what closes the requests when the sheet
    /// goes away, and it is the only reason a poll is acceptable at all.
    func testThePresenceLoopStopsWhenItsTaskIsCancelled() async {
        let service = FakeProfileService()
        service.profiles[otherID] = profile(id: otherID)
        service.statusesByID[otherID] = MMStatus(userId: otherID, status: "online")
        let model = model(service, userID: otherID, now: { self.fixedNow })
        await model.load()
        let readsAfterLoad = service.statusRequests.count

        let task = Task { await model.runPresenceUpdates(interval: 0.05) }
        // Let at least two periods elapse, then stop.
        try? await Task.sleep(nanoseconds: 220_000_000)
        task.cancel()
        await task.value
        let readsWhenCancelled = service.statusRequests.count
        XCTAssertGreaterThanOrEqual(readsWhenCancelled - readsAfterLoad, 2,
                                    "the loop polls while it runs")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(service.statusRequests.count, readsWhenCancelled,
                       "a cancelled loop issues no further reads")
    }

    /// The do-not-disturb end time is on the wire (`dnd_end_time`, epoch ms) and has to survive the
    /// decode, or the screen can only say "Do not disturb" for a status that ends at 4:15.
    func testThePresenceSnapshotKeepsTheDoNotDisturbEndTime() throws {
        let end = Int64(fixedNow.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let row = try JSONDecoder().decode(MMStatus.self, from: Data("""
        {"user_id":"\(myID)","status":"dnd","manual":true,
         "last_activity_at":1790000000000,"dnd_end_time":\(end)}
        """.utf8))
        let snapshot = ProfileViewModel.snapshot(from: row)
        XCTAssertEqual(snapshot.presence, .dnd)
        XCTAssertEqual(snapshot.dndEndTime, Date(timeIntervalSince1970: Double(end) / 1000))
        let sentence = ProfileDateFormat.dndSentence(snapshot, now: fixedNow,
                                                     timeZone: TimeZone(identifier: "UTC")!,
                                                     locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertNotNil(sentence, "an end time means the screen can say when it ends")
        XCTAssertTrue(sentence?.hasPrefix("Do not disturb until") ?? false, sentence ?? "nil")

        let noEnd = try JSONDecoder().decode(MMStatus.self, from: Data("""
        {"user_id":"\(otherID)","status":"away","manual":true,"last_activity_at":0,"dnd_end_time":0}
        """.utf8))
        XCTAssertNil(ProfileViewModel.snapshot(from: noEnd).dndEndTime,
                     "0 is the server's \"no end time\", not the epoch")
    }

    // MARK: - The view model: presence writes

    func testSettingMyPresenceWritesTheServerStatusAndRemembersTheAnswer() async {
        let service = FakeProfileService()
        service.profiles[myID] = profile(id: myID, firstName: "Perf")
        service.statusesByID[myID] = MMStatus(userId: myID, status: "offline")
        let model = model(service, userID: myID, myUserID: myID, now: { self.fixedNow })
        await model.load()
        XCTAssertTrue(model.isMe)

        var reported: [UserStatusSnapshot] = []
        model.onMyStatusChanged = { _, snapshot in reported.append(snapshot) }

        await model.setPresence(.dnd, dndDuration: .thirtyMinutes)

        XCTAssertEqual(service.presenceWrites.count, 1)
        XCTAssertEqual(service.presenceWrites.first?.presence, .dnd)
        XCTAssertEqual(service.presenceWrites.first?.userID, myID)
        XCTAssertEqual(service.presenceWrites.first?.dndEndTime,
                       StatusDuration.thirtyMinutes.dndEndTimeMillis(from: fixedNow))
        XCTAssertEqual(model.presence, .dnd)
        XCTAssertTrue(model.status?.manual == true, "the server's answer is used, not the guess")
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first?.presence, .dnd)
    }

    func testAFailedPresenceWriteRollsBackAndNamesTheFailure() async {
        let service = FakeProfileService()
        service.profiles[myID] = profile(id: myID)
        service.statusesByID[myID] = MMStatus(userId: myID, status: "online")
        let model = model(service, userID: myID, myUserID: myID, now: { self.fixedNow })
        await model.load()
        XCTAssertEqual(model.presence, .online)

        service.presenceFailure = MMError.forbidden(message: nil)
        await model.setPresence(.dnd)

        XCTAssertEqual(model.presence, .online, "a rejected status is not left on screen as if it stuck")
        XCTAssertNotNil(model.banner)
    }

    func testPresenceCannotBeSetOnSomebodyElsesProfile() async {
        let service = FakeProfileService()
        service.profiles[otherID] = profile(id: otherID)
        let model = model(service, userID: otherID, myUserID: myID, now: { self.fixedNow })
        await model.load()
        await model.setPresence(.dnd)
        XCTAssertTrue(service.presenceWrites.isEmpty)
        XCTAssertNotNil(model.banner)
    }

    // MARK: - The view model: custom status writes

    func testSavingACustomStatusSendsTheBodyAndDrawsItOptimistically() async throws {
        let service = FakeProfileService()
        service.profiles[myID] = profile(id: myID)
        service.statusesByID[myID] = MMStatus(userId: myID, status: "online")
        let model = model(service, userID: myID, myUserID: myID, now: { self.fixedNow })
        await model.load()

        let accepted = await model.saveCustomStatus(CustomStatusDraft(emoji: "coffee",
                                                                     text: "Heads down",
                                                                     duration: .oneHour))
        XCTAssertTrue(accepted)
        XCTAssertEqual(service.customStatusWrites.count, 1)
        XCTAssertEqual(service.customStatusWrites.first?.body.duration, "one_hour")
        XCTAssertEqual(service.customStatusWrites.first?.body.text, "Heads down")
        let stored = try XCTUnwrap(model.profile?.customStatus)
        XCTAssertEqual(stored.emoji, "coffee")
        XCTAssertEqual(stored.text, "Heads down")
        XCTAssertEqual(stored.duration, "one_hour")
        XCTAssertNotNil(model.activeCustomStatus)
    }

    func testAnInvalidDraftIsRefusedLocallyWithoutARequest() async {
        let service = FakeProfileService()
        service.profiles[myID] = profile(id: myID)
        let model = model(service, userID: myID, myUserID: myID, now: { self.fixedNow })
        await model.load()

        let accepted = await model.saveCustomStatus(CustomStatusDraft())
        XCTAssertFalse(accepted)
        XCTAssertTrue(service.customStatusWrites.isEmpty,
                      "the server would answer 400; the client refuses first")
        XCTAssertNotNil(model.banner)
    }

    func testAFailedCustomStatusWriteRestoresThePreviousStatus() async throws {
        let service = FakeProfileService()
        service.profiles[myID] = profile(id: myID, props: [
            "customStatus": "{\"emoji\":\"book\",\"text\":\"Old\",\"duration\":\"\",\"expires_at\":\"0001-01-01T00:00:00Z\"}"
        ])
        service.statusesByID[myID] = MMStatus(userId: myID, status: "online")
        let model = model(service, userID: myID, myUserID: myID, now: { self.fixedNow })
        await model.load()
        XCTAssertEqual(model.profile?.customStatus?.text, "Old")

        service.customStatusFailure = MMError.server(status: 400, message: "Invalid")
        let accepted = await model.saveCustomStatus(CustomStatusDraft(emoji: "coffee", text: "New"))

        XCTAssertFalse(accepted)
        XCTAssertEqual(try XCTUnwrap(model.profile?.customStatus).text, "Old")
        XCTAssertNotNil(model.banner)
    }

    func testClearingTheCustomStatusRemovesItAndRollsBackOnFailure() async {
        let service = FakeProfileService()
        service.profiles[myID] = profile(id: myID, props: [
            "customStatus": "{\"emoji\":\"book\",\"text\":\"Old\",\"duration\":\"\",\"expires_at\":\"0001-01-01T00:00:00Z\"}"
        ])
        service.statusesByID[myID] = MMStatus(userId: myID, status: "online")
        let model = model(service, userID: myID, myUserID: myID, now: { self.fixedNow })
        await model.load()

        service.clearFailure = MMError.offline
        let failed = await model.clearCustomStatus()
        XCTAssertFalse(failed)
        XCTAssertEqual(model.profile?.customStatus?.text, "Old")

        service.clearFailure = nil
        let cleared = await model.clearCustomStatus()
        XCTAssertTrue(cleared)
        XCTAssertNil(model.profile?.customStatus)
        XCTAssertEqual(service.clearWrites, [myID, myID],
                       "the refused attempt and the accepted one are both recorded")
    }

    func testAnExpiredCustomStatusIsNotDrawnEvenThoughItIsStillStored() async {
        let service = FakeProfileService()
        var clock = fixedNow
        service.profiles[myID] = profile(id: myID, props: [
            "customStatus": "{\"emoji\":\"coffee\",\"text\":\"Lunch\",\"duration\":\"twenty_minutes\",\"expires_at\":\"2026-10-26T19:45:00.000Z\"}"
        ])
        service.statusesByID[myID] = MMStatus(userId: myID, status: "online")
        let model = model(service, userID: myID, myUserID: myID, now: { clock })
        await model.load()
        XCTAssertNotNil(model.activeCustomStatus)

        clock = fixedNow.addingTimeInterval(3600)
        XCTAssertNil(model.activeCustomStatus, "the client stops drawing it when it has expired")
    }

    // MARK: - The view model: the DM shortcut

    func testSendMessageCreatesTheConversationAndPublishesIt() async {
        let service = FakeProfileService()
        service.profiles[otherID] = profile(id: otherID, username: "other")
        service.statusesByID[otherID] = MMStatus(userId: otherID, status: "online")
        let model = model(service, userID: otherID, myUserID: myID, now: { self.fixedNow })
        await model.load()
        XCTAssertTrue(model.canMessage)

        await model.openConversation()

        XCTAssertEqual(service.directRequests.count, 1)
        XCTAssertEqual(service.directRequests.first?.myUserID, myID)
        XCTAssertEqual(service.directRequests.first?.otherUserID, otherID)
        XCTAssertEqual(model.conversation?.id, "dm00000000000000000000001")
        XCTAssertNil(model.conversationFailure)
        model.consumeConversation()
        XCTAssertNil(model.conversation)
    }

    func testSendMessageIsNotAttemptedForMyOwnProfile() async {
        let service = FakeProfileService()
        service.profiles[myID] = profile(id: myID)
        service.statusesByID[myID] = MMStatus(userId: myID, status: "online")
        let model = model(service, userID: myID, myUserID: myID, now: { self.fixedNow })
        await model.load()
        XCTAssertFalse(model.canMessage)
        await model.openConversation()
        XCTAssertTrue(service.directRequests.isEmpty)
        XCTAssertNotNil(model.conversationFailure)
    }

    func testAFailedConversationWriteIsNamed() async {
        let service = FakeProfileService()
        service.profiles[otherID] = profile(id: otherID)
        service.statusesByID[otherID] = MMStatus(userId: otherID, status: "online")
        service.directFailure = MMError.forbidden(message: nil)
        let model = model(service, userID: otherID, myUserID: myID, now: { self.fixedNow })
        await model.load()
        await model.openConversation()
        XCTAssertNil(model.conversation)
        XCTAssertEqual(model.conversationFailure, "You do not have permission to message this account.")
    }

    func testAnAnswerThatIsNotADirectChannelIsRefused() async {
        let service = FakeProfileService()
        service.profiles[otherID] = profile(id: otherID)
        service.statusesByID[otherID] = MMStatus(userId: otherID, status: "online")
        service.directAnswer = MMChannel(id: "chan1", name: "town-square", type: "O", teamId: "t1")
        let model = model(service, userID: otherID, myUserID: myID, now: { self.fixedNow })
        await model.load()
        await model.openConversation()
        XCTAssertNil(model.conversation)
        XCTAssertNotNil(model.conversationFailure)
    }

    // MARK: - The view model: the socket

    func testAStatusChangePatchesThePresenceInPlace() async {
        let service = FakeProfileService()
        service.profiles[otherID] = profile(id: otherID)
        service.statusesByID[otherID] = MMStatus(userId: otherID, status: "online", manual: false)
        let model = model(service, userID: otherID, myUserID: myID, now: { self.fixedNow })
        await model.load()
        XCTAssertEqual(model.presence, .online)

        model.handle(.statusChange(SocketStatusChange(userID: otherID, status: "dnd")))

        XCTAssertEqual(model.presence, .dnd)
        XCTAssertEqual(service.profileRequests.count, 1, "a presence change is not a profile re-read")
    }

    func testAStatusChangeForAnotherUserIsIgnored() async {
        let service = FakeProfileService()
        service.profiles[otherID] = profile(id: otherID)
        service.statusesByID[otherID] = MMStatus(userId: otherID, status: "online")
        let model = model(service, userID: otherID, myUserID: myID, now: { self.fixedNow })
        await model.load()
        model.handle(.statusChange(SocketStatusChange(userID: myID, status: "dnd")))
        XCTAssertEqual(model.presence, .online)
    }

    func testAUserUpdatedEventForThisAccountReReadsTheProfile() async throws {
        let service = FakeProfileService()
        service.profiles[otherID] = profile(id: otherID, props: [:])
        service.statusesByID[otherID] = MMStatus(userId: otherID, status: "online")
        let model = model(service, userID: otherID, myUserID: myID, now: { self.fixedNow })
        await model.load()
        XCTAssertEqual(service.profileRequests.count, 1)

        // Another client sets a custom status: the server publishes `user_updated` and the profile is
        // re-read, because the event's own payload has no `props`.
        service.profiles[otherID] = profile(id: otherID, props: [
            "customStatus": "{\"emoji\":\"coffee\",\"text\":\"From another client\",\"duration\":\"\",\"expires_at\":\"0001-01-01T00:00:00Z\"}"
        ])
        model.handle(.userUpdated(MMUser(id: otherID, username: "other")))

        let deadline = Date().addingTimeInterval(3)
        while model.profile?.customStatus == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(model.profile?.customStatus?.text, "From another client")
        XCTAssertEqual(service.profileRequests.count, 2)
    }

    func testAUserUpdatedEventForSomebodyElseDoesNotReRead() async throws {
        let service = FakeProfileService()
        service.profiles[otherID] = profile(id: otherID)
        service.statusesByID[otherID] = MMStatus(userId: otherID, status: "online")
        let model = model(service, userID: otherID, myUserID: myID, now: { self.fixedNow })
        await model.load()
        model.handle(.userUpdated(MMUser(id: myID, username: "me")))
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(service.profileRequests.count, 1)
    }

    // MARK: - The coordinator

    func testTheCoordinatorCachesProfilesPerAccountAndBoundsTheCache() {
        let coordinator = ProfileCoordinator()
        let server = ServerConfig(name: "probe", url: URL(string: "https://mm.example")!)
        let service = FakeProfileService()
        coordinator.serviceFactory = { _ in service }

        let first = coordinator.model(for: server, userID: otherID)
        let again = coordinator.model(for: server, userID: otherID)
        XCTAssertTrue(first === again, "one model per account, so a re-open does not re-read")

        for index in 0..<(ProfileCoordinator.warmProfileLimit + 3) {
            _ = coordinator.model(for: server, userID: "extra\(index)")
        }
        XCTAssertLessThanOrEqual(coordinator.modelCount, ProfileCoordinator.warmProfileLimit)
    }

    func testASocketStatusChangeWithNoProfileOpenCreatesNoModel() {
        let coordinator = ProfileCoordinator()
        let service = FakeProfileService()
        coordinator.serviceFactory = { _ in service }
        let server = ServerConfig(name: "probe", url: URL(string: "https://mm.example")!)
        // No auth is bound, so the coordinator cannot tell whose frame this is; the event alone must
        // not invent a model, and must not crash.
        coordinator.handle(.statusChange(SocketStatusChange(userID: myID, status: "away")),
                           serverID: server.id)
        XCTAssertEqual(coordinator.modelCount, 0)
        XCTAssertEqual(coordinator.autoAwayCount, 0)
    }

    func testDeactivateDropsEverythingForAServer() {
        let coordinator = ProfileCoordinator()
        coordinator.serviceFactory = { _ in FakeProfileService() }
        let server = ServerConfig(name: "probe", url: URL(string: "https://mm.example")!)
        _ = coordinator.model(for: server, userID: otherID)
        XCTAssertEqual(coordinator.modelCount, 1)
        coordinator.authPhaseChanged(server.id)
        XCTAssertEqual(coordinator.modelCount, 0)
    }
}
