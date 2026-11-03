// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 —
//   app/screens/edit_profile/edit_profile.tsx (load the user, save the changed fields, show the
//   server's error), components/user_profile_picture.tsx (upload / remove, with the picture updating
//   in place), custom_profile_attributes/ (S39's fields and values).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §18; no
// upstream source copied. The draft/observable split is this repo's own (`ChannelSettingsViewModel`,
// T40; `ProfileViewModel`, T41).
//
// ## The rules this model keeps
//
//  1. **A no-op save sends nothing.** Both halves (the field patch and the attribute values) are
//     derived before any request; when both are empty the method returns without touching the
//     network. The unit suite counts the service calls to prove it.
//  2. **Only the fields that changed travel.** `ProfilePatchDraft.patch` and
//     `CustomProfileAttributeSection.dirtyValues` are the two derivations; the model never assembles
//     a body itself.
//  3. **The server's sentence is the error, in the form.** `PUT /users/{id}/patch` answers
//     `{"message": "Invalid email."}` for a rejected field, and that sentence is what the form draws
//     under the fields — the T31 login rule (the server owns the rule it enforces). Transport
//     failures fall back to `MMErrorCopy`'s reader-facing sentences.
//  4. **A new picture is invalidated in the store *and* re-read.** `AvatarImageStore.invalidate`
//     drops the decoded picture and the disk file; the form then fetches the bytes the server now
//     serves, so the sheet and every post row agree. Without the invalidation the row keeps the old
//     file for up to a week (`AvatarImageStore.diskTTL`) and the upload looks like it failed.
//  5. **Custom attributes are all-or-nothing.** Fields and values are read together; if either read
//     answers nothing (this fixture: 404 for the whole feature), the section is `.absent` and no form
//     is drawn. A save writes only the values that changed.

import Foundation
import Combine

@MainActor
final class EditProfileViewModel: ObservableObject {

    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    let serverID: UUID
    let userID: String

    private let service: ProfileServing
    /// The pane's per-server picture cache. Cleared for this account after an upload/removal so the
    /// rows redraw without a relaunch. `nil` in a host that has no store (unit tests that only drive
    /// the draft); the model then simply has nothing to invalidate.
    private let avatars: AvatarImageStore?

    @Published private(set) var phase: Phase = .loading
    /// The server's profile as this form last read/updated it. The patch is derived against **this**,
    /// so a socket rename while the form is open cannot make Save send a field nobody touched.
    @Published private(set) var profile: MMUserProfile?
    @Published var draft = ProfilePatchDraft()
    /// The picture the server currently serves (nil while loading, or when the read failed).
    @Published private(set) var avatar: Data?
    /// The custom-attribute section, or `.absent` when the server has no such feature.
    @Published var attributes = CustomProfileAttributeSection.absent
    /// The form's error sentence (the server's own message when it sent one).
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSaving = false
    @Published private(set) var isChangingPicture = false
    /// Set when the server accepted something (the host may close the sheet).
    @Published private(set) var didSave = false

    /// Told to the host after any accepted change — the fields *or* the picture — with the bytes the
    /// server now serves, so an open profile screen can draw the answer without a second read.
    var onSaved: ((MMUserProfile, Data?) -> Void)?

    /// The values the section started with, so the write carries only the fields the reader changed.
    private var originalAttributeValues: [String: String] = [:]

    init(serverID: UUID,
         userID: String,
         service: ProfileServing,
         avatars: AvatarImageStore? = nil) {
        self.serverID = serverID
        self.userID = userID
        self.service = service
        self.avatars = avatars
    }

    // MARK: Derived

    /// The validation sentence, or `nil` when the draft may be sent.
    var validationMessage: String? {
        guard let profile else { return nil }
        return draft.validation(comparedTo: profile)
    }

    /// Whether the attribute values differ from what the section loaded.
    var attributesDirty: Bool {
        !attributes.dirtyValues(comparedTo: originalAttributeValues).isEmpty
    }

    /// Whether anything would be sent. Save is disabled otherwise.
    var isDirty: Bool {
        guard let profile else { return false }
        return draft.isDirty(comparedTo: profile) || attributesDirty
    }

    var canSave: Bool {
        !isSaving && !isChangingPicture && validationMessage == nil && isDirty
    }

    var showsEmailPasswordField: Bool {
        guard let profile else { return false }
        return draft.emailChanged(comparedTo: profile)
    }

    // MARK: Load

    /// Read the profile, its picture, and (when the server has them) the custom attributes.
    func load() async {
        guard !userID.isEmpty else {
            phase = .failed("This account could not be identified.")
            return
        }
        if profile == nil { phase = .loading }
        errorMessage = nil
        do {
            let loaded = try await service.profile(id: userID)
            guard !loaded.id.isEmpty else {
                phase = .failed("The server answered a profile without an id.")
                return
            }
            profile = loaded
            draft = ProfilePatchDraft(profile: loaded)
            phase = .ready
            // The picture and the attribute section are decoration beside a profile that loaded: a
            // failure leaves the avatar nil (initials) and the section absent, never a failure screen.
            avatar = await service.profileImage(userID: loaded.id, lastUpdateAt: loaded.updateAt)
            await loadAttributes()
        } catch {
            phase = .failed(ProfileViewModel.loadFailureCopy(error))
        }
    }

    /// The two custom-attribute reads. Both must answer for the section to exist.
    func loadAttributes() async {
        async let fieldsRead = try? service.customProfileAttributeFields()
        async let valuesRead = try? service.customProfileAttributeValues(userID: userID)
        guard let fields = await fieldsRead, let values = await valuesRead else {
            attributes = .absent
            originalAttributeValues = [:]
            return
        }
        let section = CustomProfileAttributeSection.make(fields: fields, values: values)
        attributes = section
        originalAttributeValues = section.values
    }

    // MARK: Save

    /// Save the fields (and the attribute values) the reader changed. Returns `true` when the server
    /// accepted everything.
    ///
    /// A no-op save answers `true` without a request: there is nothing to save, and a request that
    /// writes nothing is still a request the server can reject.
    @discardableResult
    func save() async -> Bool {
        guard let profile, !isSaving, !isChangingPicture else { return false }
        if let validation = validationMessage {
            errorMessage = validation
            return false
        }
        let patch = draft.patch(comparedTo: profile)
        let values = attributes.dirtyValues(comparedTo: originalAttributeValues)
        guard patch != nil || !values.isEmpty else { return true }

        isSaving = true
        errorMessage = nil
        var updated = profile
        if let patch {
            do {
                updated = try await service.updateProfile(userID: userID, patch: patch)
            } catch {
                isSaving = false
                errorMessage = Self.sentence(for: error, what: "profile")
                return false
            }
        }
        if !values.isEmpty {
            do {
                try await service.setCustomProfileAttributeValues(userID: userID, values: values)
            } catch {
                isSaving = false
                // The field patch may already have landed: say what failed, and keep the profile the
                // server answered so the next save's patch is derived against the truth.
                self.profile = updated
                self.draft = ProfilePatchDraft(profile: updated)
                errorMessage = Self.sentence(for: error, what: "profile fields")
                return false
            }
            originalAttributeValues.merge(values) { _, new in new }
        }

        self.profile = updated
        self.draft = ProfilePatchDraft(profile: updated)
        isSaving = false
        didSave = true
        onSaved?(updated, avatar)
        return true
    }

    // MARK: The picture

    /// Upload a picture the reader picked. Returns `true` when the server accepted it.
    ///
    /// The write is the whole operation: invalidate the store, re-read the profile (the server bumps
    /// `update_at`, which is the cache-buster the picture read carries), and fetch the bytes it now
    /// serves. What the sheet draws afterwards is what every row will draw.
    @discardableResult
    func uploadAvatar(data: Data, filename: String, mimeType: String) async -> Bool {
        guard !isChangingPicture, !isSaving, !data.isEmpty else { return false }
        isChangingPicture = true
        errorMessage = nil
        do {
            try await service.uploadProfileImage(userID: userID, data: data,
                                                 filename: filename, mimeType: mimeType)
        } catch {
            isChangingPicture = false
            errorMessage = Self.pictureSentence(for: error)
            return false
        }
        await refreshAfterPictureChange()
        isChangingPicture = false
        didSave = true
        if let profile { onSaved?(profile, avatar) }
        return true
    }

    /// Remove the picture. The server then serves its own generated fallback, and that is what the
    /// form and the rows draw — see `docs/t50-build-note.md` §3.
    @discardableResult
    func removeAvatar() async -> Bool {
        guard !isChangingPicture, !isSaving else { return false }
        isChangingPicture = true
        errorMessage = nil
        do {
            try await service.removeProfileImage(userID: userID)
        } catch {
            isChangingPicture = false
            errorMessage = Self.pictureSentence(for: error)
            return false
        }
        await refreshAfterPictureChange()
        isChangingPicture = false
        didSave = true
        if let profile { onSaved?(profile, avatar) }
        return true
    }

    /// Invalidate the shared cache, then make this form's own picture the server's answer.
    private func refreshAfterPictureChange() async {
        await avatars?.invalidate(userID)
        if let fresh = try? await service.profile(id: userID), fresh.id == userID {
            profile = fresh
            draft = ProfilePatchDraft(profile: fresh)
            avatar = await service.profileImage(userID: userID, lastUpdateAt: fresh.updateAt)
        } else {
            avatar = await service.profileImage(userID: userID,
                                                lastUpdateAt: profile?.updateAt ?? 0)
        }
    }

    // MARK: Attribute editing

    /// One field's value, as the form's binding writes it.
    func attributeValue(_ fieldID: String) -> String {
        attributes.values[fieldID] ?? ""
    }

    func setAttributeValue(_ value: String, for fieldID: String) {
        attributes.values[fieldID] = value
    }

    func clearError() { errorMessage = nil }

    // MARK: Error copy

    /// The server's own rejection sentence when it sent one (the T31 rule), otherwise the transport
    /// copy.
    static func sentence(for error: Error, what: String = "profile") -> String {
        if let message = serverMessage(error) { return message }
        return MMErrorCopy.message(
            for: error,
            offline: "You appear to be offline, so your \(what) was not saved.",
            timeout: "The server took too long to answer, so your \(what) was not saved.",
            unauthorized: "Your session has expired. Sign in again to change your \(what).",
            forbidden: "You do not have permission to change your \(what).",
            notFound: "That account no longer exists on this server.",
            rateLimited: "The server is busy. Your \(what) was not saved.",
            fallback: "Your \(what) was not saved."
        )
    }

    static func pictureSentence(for error: Error) -> String {
        if let message = serverMessage(error) { return message }
        return MMErrorCopy.message(
            for: error,
            offline: "You appear to be offline, so the picture was not saved.",
            timeout: "The server took too long to answer, so the picture was not saved.",
            unauthorized: "Your session has expired. Sign in again to change your picture.",
            forbidden: "You do not have permission to change this picture.",
            notFound: "That account no longer exists on this server.",
            rateLimited: "The server is busy. The picture was not saved.",
            fallback: "The picture was not saved."
        )
    }

    /// The server's `message` from a 4xx/5xx, when there is one and it is not a generic wrapper.
    ///
    /// For a 401 from the email patch this is the server's own "Login failed because of invalid
    /// password." — which is precisely the sentence the form has to show under the password field.
    private static func serverMessage(_ error: Error) -> String? {
        guard let error = error as? MMError else { return nil }
        switch error {
        case .client(_, let message), .server(_, let message), .unauthorized(let message):
            guard let message, !message.isEmpty else { return nil }
            return message
        default:
            return nil
        }
    }
}
