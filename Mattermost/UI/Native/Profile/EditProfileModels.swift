// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 —
//   app/screens/edit_profile/edit_profile.tsx (the fields, the validation order, the save),
//   app/screens/edit_profile/components/user_profile_picture.tsx (picture + remove),
//   app/screens/edit_profile/components/custom_profile_attributes/ (S39's attribute fields).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §18; no
// upstream source copied. The draft/patch split is this repo's own (`ChannelPatchDraft`, T40).
//
// ## The rules this file exists to keep
//
//  1. **The patch carries only what the reader changed.** `PUT /users/{id}/patch` treats a field it
//     receives as "set this value", so echoing an unchanged name back would rewrite a field somebody
//     else may have edited between this screen's read and its save, and a nil field is *omitted* by
//     the synthesized encoder — never sent as `null`, which the server reads as "empty".
//  2. **A no-op save sends nothing at all.** `patch(comparedTo:)` answers `nil` when nothing
//     changed; the screen keeps Save disabled and the model returns before touching the network.
//  3. **The limits are the server's, measured — not invented.** On 9.11.19 (`scripts/t50_profile_probe.py`):
//     `first_name`/`last_name`/`nickname` 64 characters (65 answers
//     `model.user.is_valid.{first_name,last_name,nickname}.app_error`), `position` 128
//     (`"Invalid position: must not be longer than 128 characters."`), `email` 128
//     (`model.user.is_valid.email.app_error` at 129). The server counts **characters**, not bytes:
//     128 'é' in `position` is accepted, so this client counts `String.count` too.
//  4. **Email is the one field the server will not write without the current password.** Measured:
//     a patch carrying `email` and no `password` answers
//     `400 api.context.invalid_body_param.app_error` — "Invalid or missing password in request
//     body."; a wrong password answers `401 api.user.check_user_password.invalid.app_error`. So the
//     draft requires the password *only when the email actually changed*, and the 401 is shown
//     inline instead of being read as an expired session (`APIClient.put(…, sessionExpiryOnUnauthorized:)`).
//  5. **Email *format* is the server's rule.** This client checks the length it can prove and lets
//     the server answer "Invalid email." for the shape — the T31 rule: the server's own sentence,
//     shown inline, rather than a second guess at the format that could refuse a valid address.
//
// ## Custom profile attributes (S39) — the gate, stated
//
// The feature is license-gated. This fixture is Team Edition, and on it `GET
// /custom_profile_attributes/fields`, `GET /users/{id}/custom_profile_attributes` and the `PUT` all
// answer `404 api.context.404.app_error` (measured — `scripts/t50_profile_probe.py` §3). The client
// therefore reads fields and values together and draws **no section at all** unless both reads
// answer; that is the card's requirement ("when the server returns nothing, the section is absent —
// not an empty form"), and it is also what an older server or a licence without the feature gets.
//
// Field types this build renders: `text` (a plain field) and `select` (choices from the field's
// `attrs.options`). Anything else — `multiselect`, `boolean`, `date` and future types — is named in
// `docs/t50-build-note.md` §4 and **not drawn**; the section footer says how many fields were
// withheld, so a reader is never silently shown an incomplete profile.

import Foundation

// MARK: - The write body

/// The body `PUT /users/{id}/patch` accepts, with every field optional.
///
/// `nil` means "this request does not touch that field". `Encodable`'s synthesized encoder writes
/// optionals with `encodeIfPresent`, so a nil field never reaches the wire — which is the whole
/// difference between a patch and a replace.
struct MMProfilePatch: Encodable, Equatable, Sendable {
    var firstName: String?
    var lastName: String?
    var nickname: String?
    var position: String?
    var email: String?
    /// The reader's current password. The server requires it **only** when `email` is present
    /// (measured); the draft below adds it exactly then.
    var password: String?

    enum CodingKeys: String, CodingKey {
        case nickname, position, email, password
        case firstName = "first_name"
        case lastName = "last_name"
    }

    init(firstName: String? = nil,
         lastName: String? = nil,
         nickname: String? = nil,
         position: String? = nil,
         email: String? = nil,
         password: String? = nil) {
        self.firstName = firstName
        self.lastName = lastName
        self.nickname = nickname
        self.position = position
        self.email = email
        self.password = password
    }

    /// The body as the wire sees it — used by the unit tests to prove a nil field is absent rather
    /// than `null`.
    func jsonObject() -> [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }
}

// MARK: - The draft

/// The editable fields of the reader's own profile, with the server's own limits.
///
/// Pure: no service, no clock, no view. The screen holds one of these; the view model derives the
/// patch from it; the unit suite drives every cell of the matrix without a server.
struct ProfilePatchDraft: Equatable, Sendable {
    var firstName: String
    var lastName: String
    var nickname: String
    var position: String
    var email: String
    /// Only consulted when the email changed (see `patch(comparedTo:)`).
    var currentPassword: String

    /// Measured on 9.11.19: 64 characters is accepted, 65 answers
    /// `model.user.is_valid.first_name.app_error`.
    static let maxFirstNameLength = 64
    /// Measured: `model.user.is_valid.last_name.app_error` at 65.
    static let maxLastNameLength = 64
    /// Measured: `model.user.is_valid.nickname.app_error` at 65.
    static let maxNicknameLength = 64
    /// Measured: `model.user.is_valid.position.app_error` at 129 with the sentence
    /// "Invalid position: must not be longer than 128 characters."
    static let maxPositionLength = 128
    /// Measured: `model.user.is_valid.email.app_error` at 129 characters.
    static let maxEmailLength = 128

    init(firstName: String = "",
         lastName: String = "",
         nickname: String = "",
         position: String = "",
         email: String = "",
         currentPassword: String = "") {
        self.firstName = firstName
        self.lastName = lastName
        self.nickname = nickname
        self.position = position
        self.email = email
        self.currentPassword = currentPassword
    }

    /// Start from the profile the server answered (the form's initial state).
    init(profile: MMUserProfile) {
        self.init(firstName: profile.firstName,
                  lastName: profile.lastName,
                  nickname: profile.nickname,
                  position: profile.position,
                  email: profile.email)
    }

    /// The reader-facing sentence for a draft this client can refuse, or `nil` when the draft may be
    /// sent (the server still has the last word — its rejection is shown inline by the view model).
    ///
    /// Order: the name limits first (the fields the form draws first), then the email rules. The
    /// password term is only a term when the email changed, because the server only requires it then.
    func validation(comparedTo profile: MMUserProfile) -> String? {
        if firstName.count > Self.maxFirstNameLength {
            return "A first name must be \(Self.maxFirstNameLength) characters or fewer."
        }
        if lastName.count > Self.maxLastNameLength {
            return "A last name must be \(Self.maxLastNameLength) characters or fewer."
        }
        if nickname.count > Self.maxNicknameLength {
            return "A nickname must be \(Self.maxNicknameLength) characters or fewer."
        }
        if position.count > Self.maxPositionLength {
            return "A position must be \(Self.maxPositionLength) characters or fewer."
        }
        if email.count > Self.maxEmailLength {
            return "An email address must be \(Self.maxEmailLength) characters or fewer."
        }
        if emailChanged(comparedTo: profile), currentPassword.isEmpty {
            // Measured: the server answers 400 "Invalid or missing password in request body." — this
            // client refuses the same request before it leaves the device.
            return "Enter your current password to change your email address."
        }
        return nil
    }

    /// Whether saving would change anything. Save is disabled otherwise.
    func isDirty(comparedTo profile: MMUserProfile) -> Bool {
        firstName != profile.firstName
            || lastName != profile.lastName
            || nickname != profile.nickname
            || position != profile.position
            || email != profile.email
    }

    /// The patch body, or `nil` when nothing changed (in which case **no request is sent**).
    ///
    /// The password rides along only when the email changed: sending it on an unrelated save would
    /// have the server verify a credential nobody asked it to verify, and a stale field there would
    /// turn a position edit into a 401.
    func patch(comparedTo profile: MMUserProfile) -> MMProfilePatch? {
        guard isDirty(comparedTo: profile) else { return nil }
        var patch = MMProfilePatch()
        if firstName != profile.firstName { patch.firstName = firstName }
        if lastName != profile.lastName { patch.lastName = lastName }
        if nickname != profile.nickname { patch.nickname = nickname }
        if position != profile.position { patch.position = position }
        if email != profile.email {
            patch.email = email
            patch.password = currentPassword.isEmpty ? nil : currentPassword
        }
        return patch
    }

    /// Whether the email field differs from the profile's — the condition the password rides on.
    func emailChanged(comparedTo profile: MMUserProfile) -> Bool {
        email != profile.email
    }
}

// MARK: - Custom profile attributes

/// One field of the server's custom-profile-attribute schema.
///
/// Shape from `GET /api/v4/custom_profile_attributes/fields` (Mattermost 10.x): an array of objects
/// with `id`, `group_id`, `name`, `type` and an open `attrs` bag. **Not measured on this host**: the
/// fixture is Team Edition and answers 404 for the whole feature (see the header), so the decoder is
/// tolerant to the point that a missing key cannot fail a section that is optional anyway.
struct MMCustomProfileAttributeField: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var groupID: String
    var name: String
    var type: String
    /// `attrs.options` is where a `select` field's choices live. Kept untyped because Mattermost
    /// has shipped both `["one", "two"]` and `[{"name": "one"}]` for it.
    var attrs: JSONValue?
    var createAt: Int64
    var updateAt: Int64
    var deleteAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, name, type, attrs
        case groupID = "group_id"
        case createAt = "create_at"
        case updateAt = "update_at"
        case deleteAt = "delete_at"
    }

    init(id: String, groupID: String = "", name: String, type: String,
         attrs: JSONValue? = nil, createAt: Int64 = 0, updateAt: Int64 = 0, deleteAt: Int64 = 0) {
        self.id = id
        self.groupID = groupID
        self.name = name
        self.type = type
        self.attrs = attrs
        self.createAt = createAt
        self.updateAt = updateAt
        self.deleteAt = deleteAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        groupID = try values.decodeIfPresent(String.self, forKey: .groupID) ?? ""
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try values.decodeIfPresent(String.self, forKey: .type) ?? ""
        attrs = try values.decodeIfPresent(JSONValue.self, forKey: .attrs)
        createAt = try values.decodeIfPresent(Int64.self, forKey: .createAt) ?? 0
        updateAt = try values.decodeIfPresent(Int64.self, forKey: .updateAt) ?? 0
        deleteAt = try values.decodeIfPresent(Int64.self, forKey: .deleteAt) ?? 0
    }

    /// The choices of a `select` field, when the server described them.
    var options: [String] {
        guard case .object(let bag)? = attrs, case .array(let list)? = bag["options"] else {
            return []
        }
        return list.compactMap { value in
            switch value {
            case .string(let text): return text
            case .object(let object):
                if case .string(let name)? = object["name"] { return name }
                return nil
            default: return nil
            }
        }
    }

    /// The types this build can draw. Everything else is named in the section footer rather than
    /// dropped silently, and in `docs/t50-build-note.md` §4.
    static let renderableTypes: Set<String> = ["text", "select"]

    var isRenderable: Bool {
        !id.isEmpty && !name.isEmpty && Self.renderableTypes.contains(type.lowercased())
    }
}

/// `GET /users/{id}/custom_profile_attributes` — the reader's values, keyed by field id.
struct MMCustomProfileAttributeValues: Codable, Equatable, Sendable {
    var userID: String
    var values: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case values
        case userID = "user_id"
    }

    init(userID: String = "", values: [String: JSONValue] = [:]) {
        self.userID = userID
        self.values = values
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userID = try container.decodeIfPresent(String.self, forKey: .userID) ?? ""
        values = try container.decodeIfPresent([String: JSONValue].self, forKey: .values) ?? [:]
    }

    /// The values as the form holds them: a string per field. An array (a `multiselect` written by
    /// another client) joins with commas so it is at least visible; the field itself is not drawn by
    /// this build, so it cannot be edited or silently rewritten.
    func stringValues() -> [String: String] {
        values.reduce(into: [:]) { result, pair in
            switch pair.value {
            case .string(let text): result[pair.key] = text
            case .number(let number):
                result[pair.key] = number.rounded() == number ? String(Int64(number)) : String(number)
            case .bool(let flag): result[pair.key] = flag ? "true" : "false"
            case .array(let list):
                result[pair.key] = list.compactMap { value -> String? in
                    if case .string(let text) = value { return text }
                    return nil
                }.joined(separator: ", ")
            case .object, .null: break
            }
        }
    }
}

/// The section's own state: the fields this build can draw, plus a count it must mention but cannot
/// draw.
struct CustomProfileAttributeSection: Equatable, Sendable {
    var fields: [MMCustomProfileAttributeField]
    /// Fields the server sent that this build cannot render (`multiselect`, anything unknown).
    var withheldCount: Int
    var values: [String: String]

    /// No section at all — the feature is off, the server is older, or a read failed.
    static let absent = CustomProfileAttributeSection(fields: [], withheldCount: 0, values: [:])

    var isPresent: Bool { !fields.isEmpty }

    /// What the footer says about fields that were not drawn. `nil` when everything was drawn.
    var withheldNote: String? {
        guard withheldCount > 0 else { return nil }
        return withheldCount == 1
            ? "1 profile field uses a type this app cannot edit yet. Edit it in the web app."
            : "\(withheldCount) profile fields use types this app cannot edit yet. Edit them in the web app."
    }

    /// Build the section from the two reads, or `.absent` when either answered nothing.
    ///
    /// A field whose id or name is missing is withheld (it cannot be keyed or labelled), and a
    /// deactivated field (`delete_at != 0`) is not drawn: the server has retired it.
    static func make(fields: [MMCustomProfileAttributeField],
                     values: MMCustomProfileAttributeValues) -> CustomProfileAttributeSection {
        let live = fields.filter { $0.deleteAt == 0 && !($0.id.isEmpty || $0.name.isEmpty) }
        let drawable = live.filter(\.isRenderable)
        guard !drawable.isEmpty else {
            // Nothing this build can draw: absent, not an empty form — the card's rule.
            return .absent
        }
        return CustomProfileAttributeSection(fields: drawable,
                                             withheldCount: live.count - drawable.count,
                                             values: values.stringValues())
    }

    /// The `PUT` body's values: only the fields this section draws, and only the ones that changed.
    func dirtyValues(comparedTo original: [String: String]) -> [String: String] {
        var changed: [String: String] = [:]
        for field in fields {
            let current = values[field.id] ?? ""
            let previous = original[field.id] ?? ""
            if current != previous { changed[field.id] = current }
        }
        return changed
    }
}
