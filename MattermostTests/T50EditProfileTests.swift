// T50 — the rules behind the edit-profile surface: what a save sends, what the server's refusals
// mean, and what happens to the picture cache when the picture changes.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0
//   (`app/screens/edit_profile/`, `app/client/rest/users.ts#updateMe`,
//    `app/client/rest/custom_profile_attributes.ts`).
// Licence: Apache-2.0 — behaviour reimplemented; attribution in docs/THIRD_PARTY_NOTICES.md §18.
//
// Every limit and every wire fact asserted here was **measured** on the pinned 9.11.19 fixture with
// `scripts/t50_profile_probe.py`; the numbers are quoted at the assertion that uses them. The parts
// that could not be measured on this host (the custom-attribute routes are 404 on Team Edition) are
// asserted against the documented shapes and the gate is stated in `docs/t50-build-note.md` §4.

import XCTest
import UIKit
@testable import Mattermost

@MainActor
final class T50EditProfileTests: XCTestCase {

    private let myID = "user0000000000000000000001"
    private let serverID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let serverURL = URL(string: "https://mm.example.com")!

    /// Two real 2×2 PNGs, so a decoded picture can be compared as bytes rather than as "not nil".
    private static let pngA = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGPgEpEDIgYIBQAGTgDxOGMygQAAAABJRU5ErkJggg==")!
    private static let pngB = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGM4kWIERAwQCgAorgV5QuEn7gAAAABJRU5ErkJggg==")!

    // MARK: - Fixtures

    private func profile(firstName: String = "Perf",
                         lastName: String = "Probe",
                         nickname: String = "perf",
                         position: String = "Engineer",
                         email: String = "probe@example.com",
                         updateAt: Int64 = 1_790_000_000_000) -> MMUserProfile {
        MMUserProfile(id: myID,
                      username: "perfprobe",
                      firstName: firstName,
                      lastName: lastName,
                      nickname: nickname,
                      position: position,
                      email: email,
                      roles: "system_user",
                      createAt: 1_700_000_000_000,
                      updateAt: updateAt,
                      lastActivityAt: 1_790_000_000_000)
    }

    /// A `ProfileServing` that answers from memory and records every write.
    @MainActor
    final class FakeEditProfileService: ProfileServing {
        var stored: MMUserProfile
        var avatar: Data?
        var fields: [MMCustomProfileAttributeField] = []
        var values: MMCustomProfileAttributeValues
        var fieldsFailure: Error?
        var valuesFailure: Error?
        var updateFailure: Error?
        var uploadFailure: Error?
        var removeFailure: Error?
        var attributesWriteFailure: Error?
        /// The bytes `GET /users/{id}/image` answers after a removal (the server's generated avatar).
        var removalFallback = Data()

        private(set) var updateCalls: [MMProfilePatch] = []
        private(set) var uploads: [(userID: String, data: Data, filename: String, mimeType: String)] = []
        private(set) var removals: [String] = []
        private(set) var attributeWrites: [[String: String]] = []

        init(profile: MMUserProfile) {
            self.stored = profile
            self.values = MMCustomProfileAttributeValues(userID: profile.id)
        }

        func profile(id: String) async throws -> MMUserProfile { stored }
        func profiles(ids: [String]) async throws -> [MMUserProfile] { [stored] }
        func statuses(ids: [String]) async throws -> [MMStatus] { [] }
        func setPresence(_ presence: UserPresence, dndEndTime: Int64?,
                         userID: String) async throws -> MMStatus {
            MMStatus(userId: userID, status: presence.rawValue)
        }
        func setCustomStatus(userID: String, body: CustomStatusBody) async throws {}
        func clearCustomStatus(userID: String) async throws {}
        func directChannel(myUserID: String, otherUserID: String) async throws -> MMChannel {
            MMChannel(id: "dm", type: "D")
        }
        func profileImage(userID: String, lastUpdateAt: Int64) async -> Data? { avatar }

        func updateProfile(userID: String, patch: MMProfilePatch) async throws -> MMUserProfile {
            updateCalls.append(patch)
            if let updateFailure { throw updateFailure }
            if let first = patch.firstName { stored.firstName = first }
            if let last = patch.lastName { stored.lastName = last }
            if let nickname = patch.nickname { stored.nickname = nickname }
            if let position = patch.position { stored.position = position }
            if let email = patch.email { stored.email = email }
            stored.updateAt += 1
            return stored
        }

        func uploadProfileImage(userID: String, data: Data,
                                filename: String, mimeType: String) async throws {
            uploads.append((userID, data, filename, mimeType))
            if let uploadFailure { throw uploadFailure }
            avatar = data
            stored.updateAt += 1
        }

        func removeProfileImage(userID: String) async throws {
            removals.append(userID)
            if let removeFailure { throw removeFailure }
            avatar = removalFallback
            stored.updateAt += 1
        }

        func customProfileAttributeFields() async throws -> [MMCustomProfileAttributeField] {
            if let fieldsFailure { throw fieldsFailure }
            return fields
        }

        func customProfileAttributeValues(userID: String) async throws -> MMCustomProfileAttributeValues {
            if let valuesFailure { throw valuesFailure }
            return values
        }

        func setCustomProfileAttributeValues(userID: String, values: [String: String]) async throws {
            attributeWrites.append(values)
            if let attributesWriteFailure { throw attributesWriteFailure }
        }
    }

    private func model(_ service: FakeEditProfileService,
                       avatars: AvatarImageStore? = nil) -> EditProfileViewModel {
        EditProfileViewModel(serverID: serverID, userID: myID, service: service, avatars: avatars)
    }

    // MARK: - 1. The draft: dirty-field-only, nil omitted, no-op sends nothing

    func testPatchCarriesOnlyTheFieldsThatChanged() {
        let original = profile()
        var draft = ProfilePatchDraft(profile: original)
        draft.position = "Staff Engineer"

        let patch = draft.patch(comparedTo: original)
        XCTAssertEqual(patch?.position, "Staff Engineer")
        XCTAssertNil(patch?.firstName)
        XCTAssertNil(patch?.lastName)
        XCTAssertNil(patch?.nickname)
        XCTAssertNil(patch?.email)
        XCTAssertNil(patch?.password)
        XCTAssertEqual(patch?.jsonObject().keys.sorted(), ["position"],
                       "only the edited field may reach the wire")
    }

    func testNilFieldsAreOmittedFromTheJSONNotSentAsNull() throws {
        let patch = MMProfilePatch(firstName: "Ada")
        let object = patch.jsonObject()
        XCTAssertEqual(object.keys.sorted(), ["first_name"])
        XCTAssertFalse(object.values.contains { $0 is NSNull },
                       "a nil field must be omitted, never encoded as null (the server reads null as empty)")
    }

    func testUnchangedDraftProducesNoPatch() {
        let original = profile()
        let draft = ProfilePatchDraft(profile: original)
        XCTAssertFalse(draft.isDirty(comparedTo: original))
        XCTAssertNil(draft.patch(comparedTo: original), "a no-op save has no body to send")
    }

    func testNoOpSaveSendsNoRequestAtAll() async {
        let service = FakeEditProfileService(profile: profile())
        let model = model(service)
        await model.load()

        let saved = await model.save()
        XCTAssertTrue(saved, "nothing to save is not a failure")
        XCTAssertTrue(service.updateCalls.isEmpty, "a no-op save must not PUT")
        XCTAssertTrue(service.attributeWrites.isEmpty, "a no-op save must not write attributes")
    }

    func testSaveSendsOnlyTheEditedField() async {
        let service = FakeEditProfileService(profile: profile())
        let model = model(service)
        await model.load()
        model.draft.position = "Principal Engineer"

        XCTAssertTrue(model.canSave)
        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(service.updateCalls.count, 1)
        XCTAssertEqual(service.updateCalls.first?.jsonObject().keys.sorted(), ["position"])
        XCTAssertEqual(model.profile?.position, "Principal Engineer")
    }

    // MARK: - 2. The limits are the server's (measured)

    func testNameLimitsMatchTheServer() {
        let original = profile()
        var first = ProfilePatchDraft(profile: original)
        first.firstName = String(repeating: "x", count: 64)
        XCTAssertNil(first.validation(comparedTo: original),
                     "measured: first_name at 64 characters is accepted by 9.11.19")
        first.firstName = String(repeating: "x", count: 65)
        XCTAssertNotNil(first.validation(comparedTo: original),
                        "measured: 65 answers model.user.is_valid.first_name.app_error")

        var last = ProfilePatchDraft(profile: original)
        last.lastName = String(repeating: "x", count: 64)
        XCTAssertNil(last.validation(comparedTo: original))
        last.lastName = String(repeating: "x", count: 65)
        XCTAssertNotNil(last.validation(comparedTo: original),
                        "measured: 65 answers model.user.is_valid.last_name.app_error")

        var nickname = ProfilePatchDraft(profile: original)
        nickname.nickname = String(repeating: "x", count: 64)
        XCTAssertNil(nickname.validation(comparedTo: original))
        nickname.nickname = String(repeating: "x", count: 65)
        XCTAssertNotNil(nickname.validation(comparedTo: original),
                        "measured: 65 answers model.user.is_valid.nickname.app_error")
    }

    func testPositionAndEmailLimitsMatchTheServer() {
        let original = profile()
        var position128 = ProfilePatchDraft(profile: original)
        position128.position = String(repeating: "x", count: 128)
        XCTAssertNil(position128.validation(comparedTo: original),
                     "measured: 128 characters is accepted, 129 answers model.user.is_valid.position.app_error")
        position128.position = String(repeating: "x", count: 129)
        XCTAssertNotNil(position128.validation(comparedTo: original))

        var email128 = ProfilePatchDraft(profile: original)
        email128.email = String(repeating: "x", count: 128)
        email128.currentPassword = "secret"
        XCTAssertNil(email128.validation(comparedTo: original),
                     "measured: 128 characters is accepted, 129 answers model.user.is_valid.email.app_error")
        email128.email = String(repeating: "x", count: 129)
        XCTAssertNotNil(email128.validation(comparedTo: original))
    }

    func testTheClientCountsCharactersLikeTheServer() {
        // Measured: 128 'é' (2 bytes each) in `position` is accepted by 9.11.19 — the server counts
        // characters, so a byte-counting client would refuse a value the server takes.
        let original = profile()
        var draft = ProfilePatchDraft(profile: original)
        draft.position = String(repeating: "é", count: 128)
        XCTAssertNil(draft.validation(comparedTo: original))
    }

    // MARK: - 3. Email: password only when it changed; the server's sentence inline

    func testChangingTheEmailRequiresTheCurrentPassword() {
        let original = profile()
        var draft = ProfilePatchDraft(profile: original)
        draft.email = "new@example.com"
        XCTAssertEqual(draft.validation(comparedTo: original),
                       "Enter your current password to change your email address.",
                       "measured: the server answers 400 invalid_body_param without a password")
        XCTAssertNil(draft.patch(comparedTo: original)?.password)
    }

    func testThePasswordRidesOnlyWithAnEmailChange() {
        let original = profile()
        var draft = ProfilePatchDraft(profile: original)
        draft.currentPassword = "typed-but-unused"
        draft.position = "Engineer II"
        XCTAssertNil(draft.patch(comparedTo: original)?.password,
                     "an unrelated save must not carry the password")

        draft.email = "new@example.com"
        let patch = draft.patch(comparedTo: original)
        XCTAssertEqual(patch?.email, "new@example.com")
        XCTAssertEqual(patch?.password, "typed-but-unused")
        XCTAssertEqual(patch?.jsonObject().keys.sorted(), ["email", "password", "position"])
    }

    func testTheServersRejectionIsShownInline() async {
        let service = FakeEditProfileService(profile: profile())
        let model = model(service)
        await model.load()
        service.updateFailure = MMError.client(status: 400, message: "Invalid email.")
        model.draft.email = "not-an-email"
        model.draft.currentPassword = "secret"

        let saved = await model.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(model.errorMessage, "Invalid email.",
                       "the server's own sentence is what the form draws (the T31 rule)")
    }

    func testAWrongPasswordIsASentenceNotASignOut() async {
        let service = FakeEditProfileService(profile: profile())
        let model = model(service)
        await model.load()
        // Measured 401 body for a wrong current password.
        service.updateFailure = MMError.client(status: 401,
                                               message: "Login failed because of invalid password.")
        model.draft.email = "other@example.com"
        model.draft.currentPassword = "wrong"

        _ = await model.save()
        XCTAssertEqual(model.errorMessage, "Login failed because of invalid password.")
        XCTAssertEqual(model.phase, .ready, "a mistyped password must not take the form (or the session) down")
    }

    // MARK: - 4. The answer the host draws

    func testASaveAppliesTheServersAnswerAndTellsTheHost() async {
        let service = FakeEditProfileService(profile: profile())
        let model = model(service)
        await model.load()
        var handed: (MMUserProfile, Data?)?
        model.onSaved = { handed = ($0, $1) }
        model.draft.firstName = "Ada"

        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(model.profile?.firstName, "Ada")
        XCTAssertEqual(handed?.0.firstName, "Ada")
        XCTAssertEqual(model.draft.firstName, "Ada", "the draft is re-based on the server's answer")
        XCTAssertFalse(model.isDirty)
    }

    func testApplySavedProfileRepaintsWithoutARead() async {
        let service = FakeEditProfileService(profile: profile())
        let model = ProfileViewModel(serverID: serverID, userID: myID, myUserID: myID, service: service)
        await model.load()
        XCTAssertEqual(model.profile?.displayName, "Perf Probe")

        var updated = profile(firstName: "Grace", lastName: "Hopper")
        updated.updateAt += 10
        let picture = Data("new-face".utf8)
        model.applySavedProfile(updated, avatar: picture)

        XCTAssertEqual(model.profile?.displayName, "Grace Hopper")
        XCTAssertEqual(model.avatar, picture)
    }

    // MARK: - 5. The picture cache (memory + disk), and the fallback

    func testUploadInvalidatesTheAvatarStoresMemoryAndDisk() async throws {
        // The store starts holding the old face, in memory and on disk.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("t50-avatars-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var served = Self.pngA
        var loads = 0
        let store = AvatarImageStore(load: { _ in
            loads += 1
            return served
        }, disk: AvatarDiskCache(directory: directory))
        _ = await store.image(for: myID)
        XCTAssertEqual(loads, 1)
        let diskBefore = await AvatarDiskCache(directory: directory).entry(for: myID)?.data
        XCTAssertEqual(diskBefore, Self.pngA, "the old face is on disk")

        let service = FakeEditProfileService(profile: profile())
        let model = model(service, avatars: store)
        await model.load()

        served = Self.pngB
        let uploaded = await model.uploadAvatar(data: Self.pngB,
                                                filename: "avatar.png",
                                                mimeType: "image/png")
        XCTAssertTrue(uploaded)
        XCTAssertEqual(service.uploads.count, 1)
        XCTAssertEqual(service.uploads.first?.filename, "avatar.png")

        // The disk copy is gone (the store re-writes it on the next read), and the next read is a real
        // fetch of the bytes the server now serves — not the week-old file.
        let diskAfterInvalidation = await AvatarDiskCache(directory: directory).entry(for: myID)
        XCTAssertNil(diskAfterInvalidation, "the disk entry must be dropped, or the next launch draws the old face")

        let refreshed = await store.image(for: myID)
        XCTAssertEqual(loads, 2, "the memory cache must be dropped too")
        XCTAssertEqual(refreshed?.pngData(), UIImage(data: Self.pngB)?.pngData())
        let diskAfterFetch = await AvatarDiskCache(directory: directory).entry(for: myID)?.data
        XCTAssertEqual(diskAfterFetch, Self.pngB)
    }

    func testRemoveInvalidatesAndDrawsTheServersGeneratedFallback() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("t50-remove-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var served = Self.pngA
        let store = AvatarImageStore(load: { _ in served }, disk: AvatarDiskCache(directory: directory))
        _ = await store.image(for: myID)

        let service = FakeEditProfileService(profile: profile())
        service.removalFallback = Self.pngB
        let model = model(service, avatars: store)
        await model.load()

        served = Self.pngB
        let removed = await model.removeAvatar()
        XCTAssertTrue(removed)
        XCTAssertEqual(service.removals, [myID])
        XCTAssertEqual(model.avatar, Self.pngB,
                       "measured: GET /users/{id}/image answers the server's generated initial avatar after DELETE")

        // And the rows read the same fallback: the store's old file was dropped, so this is a real
        // fetch of the generated picture, written back for the next launch.
        let rowsPicture = await store.image(for: myID)
        XCTAssertEqual(rowsPicture?.pngData(), UIImage(data: Self.pngB)?.pngData())
        let disk = await AvatarDiskCache(directory: directory).entry(for: myID)?.data
        XCTAssertEqual(disk, Self.pngB,
                       "the rows draw the same fallback the sheet does")
    }

    func testAFailedUploadKeepsTheOldPictureAndSaysWhy() async {
        let service = FakeEditProfileService(profile: profile())
        let model = model(service)
        await model.load()
        let before = model.avatar
        service.uploadFailure = MMError.client(status: 400,
                                               message: "Image limits check failed. Resolution is too high.")

        let uploaded = await model.uploadAvatar(data: Self.pngB, filename: "x.png", mimeType: "image/png")
        XCTAssertFalse(uploaded)
        XCTAssertEqual(model.errorMessage, "Image limits check failed. Resolution is too high.")
        XCTAssertEqual(model.avatar, before, "a rejected upload must not repaint the face")
    }

    // MARK: - 6. Custom profile attributes: the gate, and what is drawn

    func testTheSectionIsAbsentWhenTheServerHasNoFeature() async {
        let service = FakeEditProfileService(profile: profile())
        service.fieldsFailure = MMError.notFound          // measured: 404 on Team Edition
        service.valuesFailure = MMError.notFound

        let model = model(service)
        await model.load()
        XCTAssertFalse(model.attributes.isPresent, "no fields means no section — not an empty form")
        XCTAssertTrue(model.attributes.fields.isEmpty)
    }

    func testTheSectionIsAbsentWhenTheServerSendsNoFields() async {
        let service = FakeEditProfileService(profile: profile())
        service.fields = []                               // a licensed server with none configured
        let model = model(service)
        await model.load()
        XCTAssertFalse(model.attributes.isPresent)
    }

    func testOnlyRenderableFieldTypesAreDrawnAndTheRestAreNamed() async {
        let service = FakeEditProfileService(profile: profile())
        service.fields = [
            MMCustomProfileAttributeField(id: "f1", name: "Team", type: "text"),
            MMCustomProfileAttributeField(id: "f2", name: "Colour", type: "select",
                                          attrs: .object(["options": .array([.string("Red"),
                                                                             .string("Blue")])])),
            MMCustomProfileAttributeField(id: "f3", name: "Tags", type: "multiselect"),
        ]
        let model = model(service)
        await model.load()

        XCTAssertTrue(model.attributes.isPresent)
        XCTAssertEqual(model.attributes.fields.map(\.id), ["f1", "f2"])
        XCTAssertEqual(model.attributes.withheldCount, 1)
        XCTAssertEqual(model.attributes.withheldNote,
                       "1 profile field uses a type this app cannot edit yet. Edit it in the web app.")
        XCTAssertEqual(model.attributes.fields.first(where: { $0.id == "f2" })?.options, ["Red", "Blue"])
    }

    func testAttributeValuesWriteOnlyTheFieldsThatChanged() async {
        let service = FakeEditProfileService(profile: profile())
        service.fields = [
            MMCustomProfileAttributeField(id: "f1", name: "Team", type: "text"),
            MMCustomProfileAttributeField(id: "f2", name: "Colour", type: "text"),
        ]
        service.values = MMCustomProfileAttributeValues(userID: myID,
                                                        values: ["f1": .string("Platform"),
                                                                 "f2": .string("Red")])
        let model = model(service)
        await model.load()
        XCTAssertEqual(model.attributeValue("f1"), "Platform")

        model.setAttributeValue("Blue", for: "f2")
        XCTAssertTrue(model.canSave, "an attribute change alone is a save")
        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(service.attributeWrites, [["f2": "Blue"]])
        XCTAssertTrue(service.updateCalls.isEmpty, "the field patch was untouched")
    }

    func testADeactivatedFieldIsNotDrawn() {
        let section = CustomProfileAttributeSection.make(
            fields: [MMCustomProfileAttributeField(id: "f1", name: "Team", type: "text", deleteAt: 1),
                     MMCustomProfileAttributeField(id: "f2", name: "Colour", type: "text")],
            values: MMCustomProfileAttributeValues())
        XCTAssertEqual(section.fields.map(\.id), ["f2"])
        XCTAssertEqual(section.withheldCount, 0, "a retired field is not withheld — it is gone")
    }

    // MARK: - 7. `user_updated` keeps the reader's own name current

    func testUserUpdatedRereadsMyOwnProfile() async {
        let service = FakeEditProfileService(profile: profile())
        let model = ProfileViewModel(serverID: serverID, userID: myID, myUserID: myID, service: service)
        await model.load()
        XCTAssertEqual(model.profile?.displayName, "Perf Probe")

        service.stored.firstName = "Grace"
        service.stored.lastName = "Hopper"
        model.handle(.userUpdated(MMUser(id: myID, username: "perfprobe")))

        // The re-read is debounced by 250 ms (`ProfileViewModel.scheduleProfileRefresh`).
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(model.profile?.displayName, "Grace Hopper",
                       "a rename (here or on another device) must reach the open profile")
    }

    // MARK: - 8. The wire (through the real APIClient, against a scripted transport)

    private func client(_ transport: FakeAPITransport) throws -> APIClient {
        try APIClient(serverURL: serverURL,
                      transport: transport,
                      retryPolicy: APIClient.RetryPolicy(maxAttempts: 1),
                      tokenProvider: { "tok" })
    }

    func testUpdateProfileIsAPutToThePatchRoute() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.json([
            "id": myID, "username": "perfprobe", "first_name": "Ada", "last_name": "Lovelace",
            "nickname": "", "position": "Engineer", "email": "probe@example.com", "roles": "",
            "create_at": 1, "update_at": 2, "delete_at": 0, "last_activity_at": 0,
            "auth_service": "", "is_bot": false, "props": [:]
        ]))])
        let api = try client(transport)
        var patch = MMProfilePatch()
        patch.position = "Engineer"

        _ = try await api.updateProfile(userID: myID, patch: patch)

        XCTAssertEqual(transport.lastRequest?.method, .put,
                       "measured: PATCH on /users/{id}/patch is 404; PUT is the route")
        XCTAssertEqual(transport.lastRequest?.url.path, "/api/v4/users/\(myID)/patch")
        let body = try XCTUnwrap(transport.lastRequest?.body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object.keys.sorted(), ["position"])
    }

    func testARejectedPasswordDoesNotFireReauth() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.json([
            "id": "api.user.check_user_password.invalid.app_error",
            "message": "Login failed because of invalid password.",
            "status_code": 401
        ], status: 401))])
        let api = try client(transport)
        var reauth = 0
        api.onUnauthorized = { reauth += 1 }
        var patch = MMProfilePatch()
        patch.email = "new@example.com"
        patch.password = "wrong"

        do {
            _ = try await api.updateProfile(userID: myID, patch: patch)
            XCTFail("expected the server's refusal")
        } catch {
            XCTAssertEqual(error as? MMError,
                           .client(status: 401, message: "Login failed because of invalid password."))
        }
        XCTAssertEqual(reauth, 0, "a wrong current password must not be treated as an expired session")
    }

    func testUploadSendsOneMultipartPartNamedImage() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.json(["status": "OK"]))])
        let api = try client(transport)

        try await api.uploadProfileImage(userID: myID, data: Data("png-bytes".utf8),
                                         filename: "avatar.png", mimeType: "image/png")

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url.path, "/api/v4/users/\(myID)/image")
        XCTAssertEqual(request.headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary="), true)
        let body = String(decoding: try XCTUnwrap(request.body), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"image\""),
                      "measured: a part named image_file answers 400 no_file — the name is image")
        XCTAssertTrue(body.contains("filename=\"avatar.png\""))
        XCTAssertTrue(body.contains("png-bytes"))
    }

    func testRemoveIsADelete() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.json(["status": "OK"]))])
        let api = try client(transport)
        try await api.removeProfileImage(userID: myID)
        XCTAssertEqual(transport.lastRequest?.method, .delete)
        XCTAssertEqual(transport.lastRequest?.url.path, "/api/v4/users/\(myID)/image")
    }

    func testThePictureReadUsesTheImageRouteWithTheUpdateAtBuster() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.status(404))])
        let api = try client(transport)
        _ = await api.userProfileImage(userID: myID, lastUpdateAt: 1_790_000_000_000)
        XCTAssertEqual(transport.lastRequest?.url.path, "/api/v4/users/\(myID)/image",
                       "measured: /profile_image answers 404 for every account on 9.11.19")
        XCTAssertEqual(queryValue(transport.lastRequest, "_"), "1790000000000")
    }

    func testCustomAttributeReadsAndTheValuesWrite() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json([["id": "f1", "name": "Team", "type": "text", "group_id": "", "attrs": [:] as [String: Any],
                        "create_at": 1, "update_at": 2, "delete_at": 0]])),
            .ok(.json(["user_id": myID, "values": ["f1": "Platform"]])),
            .ok(.json(["status": "OK"]))
        ])
        let api = try client(transport)

        let fields = try await api.customProfileAttributeFields()
        XCTAssertEqual(fields.map(\.id), ["f1"])
        XCTAssertEqual(transport.lastRequest?.url.path, "/api/v4/custom_profile_attributes/fields")

        let values = try await api.customProfileAttributeValues(userID: myID)
        XCTAssertEqual(values.stringValues(), ["f1": "Platform"])

        try await api.setCustomProfileAttributeValues(userID: myID, values: ["f1": "Platform"])
        XCTAssertEqual(transport.lastRequest?.method, .put)
        XCTAssertEqual(transport.lastRequest?.url.path, "/api/v4/users/\(myID)/custom_profile_attributes")
        let body = try XCTUnwrap(transport.lastRequest?.body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual((object["values"] as? [String: String]), ["f1": "Platform"])
    }
}
