// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 —
//   app/screens/edit_profile/edit_profile.tsx (the form's field order: picture, first/last name,
//   nickname, position, email; Save; the server's error under the fields),
//   app/screens/edit_profile/components/user_profile_picture.tsx (the picture row and "Remove"),
//   app/screens/edit_profile/components/custom_profile_attributes/ (S39's fields).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §18; no
// upstream source copied. SwiftUI decomposition is this repo's own (docs/component-map.md §1).
//
// ## Why the form is its own view
//
// The draft model is created in `.task` (it needs a profile), and a `@State` holding an
// `ObservableObject` is **not** observed. T40-AV measured the consequence: the Save button kept the
// `.disabled` state it was born with, so a typed purpose was never saved. `EditProfileForm` observes
// the model, so `canSave` is re-derived after every keystroke — the same split as
// `ChannelSettingsView`/`ChannelSettingsForm`.
//
// ## Identifiers an XCUITest can rely on
//
//   editProfile.sheet                 the sheet
//   editProfile.done                  close
//   editProfile.avatar                the picture (its accessibility value is a hash of the bytes)
//   editProfile.changePicture         the PhotosPicker
//   editProfile.removePicture         DELETE /users/{id}/image
//   editProfile.firstName             …
//   editProfile.lastName
//   editProfile.nickname
//   editProfile.position
//   editProfile.email
//   editProfile.password              current password, drawn only when the email changed
//   editProfile.validation            this client's refusal
//   editProfile.error                 the server's rejection sentence
//   editProfile.save
//   editProfile.attribute.<fieldID>   one custom-attribute field
//   editProfile.attributesWithheld    fields this build cannot draw

import SwiftUI
import PhotosUI
import CryptoKit

/// Which account the shell wants the edit form for — a one-field-per-server item so `.sheet(item:)`
/// can key on it (the same shape as `ProfileTarget`).
struct EditProfileTarget: Identifiable, Hashable {
    let server: ServerConfig
    let userID: String
    var id: String { "\(server.id.uuidString)#\(userID)" }
}

/// The sheet the shell presents for the signed-in reader's own profile.
struct EditProfileSheet: View {
    let server: ServerConfig
    let userID: String
    /// Called after any accepted change, with the server's profile and the picture bytes it now
    /// serves. The host (`ProfileScreen`, `SettingsView`) uses it to redraw without a re-read.
    var onSaved: ((MMUserProfile, Data?) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            EditProfileContent(server: server, userID: userID, onSaved: onSaved)
                .navigationTitle("Edit profile")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("editProfile.done")
                    }
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editProfile.sheet")
    }
}

/// The screen itself: the form and its model. Used **pushed** from the reader's own profile (a nested
/// sheet is T40's measured failure mode — the confirmation action never ran) and wrapped by
/// `EditProfileSheet` from Settings.
struct EditProfileContent: View {
    let server: ServerConfig
    let userID: String
    var onSaved: ((MMUserProfile, Data?) -> Void)? = nil

    @EnvironmentObject private var profiles: ProfileCoordinator
    @EnvironmentObject private var panes: ChannelPaneCoordinator
    @State private var model: EditProfileViewModel?

    var body: some View {
        Group {
            if let model {
                EditProfileForm(model: model)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("editProfile.loading")
            }
        }
        .task {
            guard model == nil else { return }
            let resolved = EditProfileViewModel(serverID: server.id,
                                               userID: userID,
                                               // The same service the profile sheet uses — including
                                               // the coordinator's test seam.
                                               service: profiles.profileService(for: server),
                                               // The pane's per-server picture cache: invalidating it
                                               // is what makes the upload visible in every row.
                                               avatars: panes.avatarStore(for: server))
            resolved.onSaved = onSaved
            model = resolved
            await resolved.load()
        }
    }
}

/// The form itself — observes the model so a keystroke re-derives Save (see the file header).
struct EditProfileForm: View {
    @ObservedObject var model: EditProfileViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var pickerItem: PhotosPickerItem?
    @State private var isReadingPicker = false

    var body: some View {
        Form {
            switch model.phase {
            case .loading:
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Reading your profile…")
                    }
                }
            case .failed(let message):
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("editProfile.error")
                    Button("Try again") {
                        Task { await model.load() }
                    }
                }
            case .ready:
                pictureSection
                nameSection
                emailSection
                attributesSection
                saveSection
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await load(item) }
        }
    }

    // MARK: Picture

    /// "Change picture" — the system picker, or (in a live UI test) the bytes it was handed.
    ///
    /// **Why the seam exists.** `PhotosPicker` presents Apple's picker in its own process
    /// (`com.apple.mobileslideshow.photospicker` on iOS 26). Its grid is queryable, but a tap
    /// synthesised by XCUITest — by element, by the picker's own coordinate, or by the app's — never
    /// lands on a tile: measured four times on this host, the sheet stays up and nothing is selected.
    /// So a live test cannot press the system picker to prove *this app's* upload path, and the path
    /// it would otherwise skip is the one the card is about: `POST /users/{id}/image`, the cache
    /// invalidation, and the row that redraws.
    ///
    /// The seam is DEBUG-only and needs an environment variable the product never sets:
    /// `MM_UITEST_AVATAR_PNG_BASE64`. When it is present, the same button uploads those bytes instead
    /// of opening the picker; everything downstream — the multipart write, the store invalidation,
    /// the re-read, every row's redraw — is the product path. Nothing here is compiled into Release.
    @ViewBuilder
    private var changePictureControl: some View {
        if let seeded = Self.seededTestPicture {
            Button {
                Task {
                    await model.uploadAvatar(data: seeded, filename: "t50-avatar.png",
                                             mimeType: "image/png")
                }
            } label: {
                Label("Change picture", systemImage: "photo")
            }
            .accessibilityIdentifier("editProfile.changePicture")
        } else {
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Label("Change picture", systemImage: "photo")
            }
            .accessibilityIdentifier("editProfile.changePicture")
        }
    }

    /// The picture a live UI test seeds, or `nil` in every shipping build.
    static var seededTestPicture: Data? {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["MM_UITEST_AVATAR_PNG_BASE64"],
              let data = Data(base64Encoded: raw), !data.isEmpty else { return nil }
        return data
        #else
        return nil
        #endif
    }

    private var pictureSection: some View {
        Section {
            HStack(spacing: 14) {
                ProfileAvatarView(initials: model.profile?.initials ?? "",
                                  hue: ProfileAvatarView.hue(for: model.userID),
                                  image: model.avatar,
                                  size: 64)
                    // The value is a digest of the bytes on screen, so a test can tell "the picture
                    // the server serves changed" from "the model changed" (`docs/t50-build-note.md`
                    // §5). It is a hash, not the bytes: accessibility text is not a data channel.
                    .accessibilityIdentifier("editProfile.avatar")
                    .accessibilityValue(Self.digest(of: model.avatar))
                changePictureControl
                Spacer(minLength: 0)
            }
            .disabled(model.isChangingPicture || model.isSaving)
            // Measured on iOS 26.5: as two buttons inside one Form row, the destructive one draws
            // and reports enabled/hittable but its action never runs — three taps (element, label,
            // coordinate) produced no request and no error. Its own row is what makes it fire.
            Button(role: .destructive) {
                Task { await model.removeAvatar() }
            } label: {
                Label("Remove picture", systemImage: "trash")
            }
            .accessibilityIdentifier("editProfile.removePicture")
            .disabled(model.isChangingPicture || model.isSaving)
            if model.isChangingPicture || isReadingPicker {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Saving your picture…").font(.caption)
                }
                .accessibilityIdentifier("editProfile.pictureProgress")
            }
        } header: {
            Text("Picture")
        } footer: {
            Text("Your picture is shown beside your messages. Removing it returns the picture your "
                 + "server generates from your initial.")
                .font(.caption)
        }
    }

    // MARK: Names

    private var nameSection: some View {
        Section {
            field("First name", text: Binding(get: { model.draft.firstName },
                                              set: { model.draft.firstName = $0 }),
                  identifier: "editProfile.firstName")
            field("Last name", text: Binding(get: { model.draft.lastName },
                                             set: { model.draft.lastName = $0 }),
                  identifier: "editProfile.lastName")
            field("Nickname", text: Binding(get: { model.draft.nickname },
                                            set: { model.draft.nickname = $0 }),
                  identifier: "editProfile.nickname")
            field("Position", text: Binding(get: { model.draft.position },
                                            set: { model.draft.position = $0 }),
                  identifier: "editProfile.position")
            if let validation = model.validationMessage {
                Text(validation)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("editProfile.validation")
            }
        } header: {
            Text("Name")
        } footer: {
            Text("Your first and last name are shown to everyone; if both are empty, your username "
                 + "is shown instead. Position and nickname are optional.")
                .font(.caption)
        }
    }

    private func field(_ title: String, text: Binding<String>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .accessibilityIdentifier(identifier)
        }
    }

    // MARK: Email

    private var emailSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Email").font(.caption).foregroundStyle(.secondary)
                TextField("Email", text: Binding(get: { model.draft.email },
                                                 set: { model.draft.email = $0 }))
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("editProfile.email")
            }
            if model.showsEmailPasswordField {
                // Measured: the server refuses an email change without the current password, so the
                // field appears exactly when the email differs — never on an unrelated save.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current password").font(.caption).foregroundStyle(.secondary)
                    SecureField("Current password",
                                text: Binding(get: { model.draft.currentPassword },
                                              set: { model.draft.currentPassword = $0 }))
                        .accessibilityIdentifier("editProfile.password")
                }
            }
        } header: {
            Text("Email")
        } footer: {
            Text(model.showsEmailPasswordField
                 ? "Changing your email needs your current password. The server validates the address."
                 : "Your email is used for notifications and password reset.")
                .font(.caption)
        }
    }

    // MARK: Custom profile attributes (S39)

    @ViewBuilder
    private var attributesSection: some View {
        if model.attributes.isPresent {
            Section {
                ForEach(model.attributes.fields) { field in
                    attributeField(field)
                }
                if let note = model.attributes.withheldNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("editProfile.attributesWithheld")
                }
            } header: {
                Text("Profile fields")
            }
        }
    }

    @ViewBuilder
    private func attributeField(_ field: MMCustomProfileAttributeField) -> some View {
        if field.type.lowercased() == "select" {
            Picker(field.name, selection: Binding(get: { model.attributeValue(field.id) },
                                                  set: { model.setAttributeValue($0, for: field.id) })) {
                Text("Not set").tag("")
                ForEach(field.options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .accessibilityIdentifier("editProfile.attribute.\(field.id)")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(field.name).font(.caption).foregroundStyle(.secondary)
                TextField(field.name, text: Binding(get: { model.attributeValue(field.id) },
                                                     set: { model.setAttributeValue($0, for: field.id) }))
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("editProfile.attribute.\(field.id)")
            }
        }
    }

    // MARK: Save

    private var saveSection: some View {
        Section {
            Button {
                Task {
                    if await model.save() { dismiss() }
                }
            } label: {
                HStack {
                    Text("Save")
                    Spacer()
                    if model.isSaving { ProgressView() }
                }
            }
            .disabled(!model.canSave)
            .accessibilityIdentifier("editProfile.save")
            if let error = model.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("editProfile.error")
            }
        }
    }

    // MARK: Picker

    /// Read the picked image and upload it.
    ///
    /// `loadTransferable(type: Data.self)` is the only way to the bytes a `PhotosPickerItem` carries;
    /// the filename and MIME type are best-effort (the picker does not hand them over for a `Data`
    /// transfer), and the server re-encodes the picture anyway (measured: a 64×64 PNG comes back as
    /// 128×128).
    private func load(_ item: PhotosPickerItem) async {
        isReadingPicker = true
        defer {
            isReadingPicker = false
            pickerItem = nil
        }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let type = item.supportedContentTypes.first
        let mimeType = type?.preferredMIMEType ?? "image/png"
        let filename = "avatar." + (type?.preferredFilenameExtension ?? "png")
        await model.uploadAvatar(data: data, filename: filename, mimeType: mimeType)
    }

    /// The first 8 bytes of the picture's SHA-256, or `none` — a stable, non-reversible label for
    /// "which picture is on screen".
    static func digest(of data: Data?) -> String {
        guard let data, !data.isEmpty else { return "none" }
        let hash = SHA256.hash(data: data)
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
