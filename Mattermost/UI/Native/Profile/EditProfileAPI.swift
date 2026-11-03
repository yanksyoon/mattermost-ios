// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 —
//   app/client/rest/users.ts (`updateMe`, `uploadProfileImage`, `removeProfileImage`),
//   app/client/rest/custom_profile_attributes.ts (S39's fields/values).
// Licence: Apache-2.0 — endpoints reimplemented against https://api.mattermost.com and the measured
// behaviour below; no upstream source copied.
//
// ## What was measured on 9.11.19 (`scripts/t50_profile_probe.py`)
//
//  * `PUT /users/{user_id}/patch` is the update route. It answers the whole user. `first_name`,
//    `last_name`, `nickname`, `position` and `email` are the fields this screen writes. A field the
//    body omits is **left alone** (measured: patching only `nickname` kept `position`).
//  * `email` is special: the server requires the current password in the same body
//    (`400 api.context.invalid_body_param.app_error` without it, `401
//    api.user.check_user_password.invalid.app_error` with a wrong one). That 401 is **not** session
//    expiry — see `APIClient.patch(…, sessionExpiryOnUnauthorized:)`.
//  * `POST /users/{user_id}/image` takes one multipart part named **`image`** (measured: a part named
//    `image_file` answers `400 api.user.upload_profile_user.no_file.app_error` — "No file under
//    'image' in request."). It answers `{"status":"OK"}`. The server re-encodes the picture: a 64×64
//    PNG came back as a 128×128 PNG from `GET /users/{id}/image`.
//  * `DELETE /users/{user_id}/image` answers `{"status":"OK"}`. Afterwards `GET /users/{id}/image`
//    answers the server's **generated fallback** — a 128×128 PNG of the account's initial on a
//    colour (measured: 626 bytes, a green tile with "T"). So "no picture" is not a 404 on this
//    route: it is a picture the server draws. The client draws exactly what the server serves, and
//    `docs/t50-build-note.md` §3 states this rather than claiming the app's own initials are what a
//    reader sees for an account with no picture.
//  * The custom-profile-attribute routes are **404 on this fixture** (Team Edition, feature
//    license-gated). The shapes below are the documented ones; the live gate is recorded honestly in
//    the build note instead of being faked here.

import Foundation

extension APIClient {

    // MARK: - The profile write

    /// `PUT /users/{user_id}/patch` — save the fields the draft changed.
    ///
    /// The method is **PUT**, not PATCH (measured: `PATCH …/patch` answers `404
    /// api.context.404.app_error` on 9.11.19; `PUT` answers the user).
    ///
    /// `sessionExpiryOnUnauthorized: false`: a 401 here is the server rejecting the **current
    /// password in this body** (an email change), and it must be a sentence on the form rather than a
    /// sign-out.
    func updateProfile(userID: String, patch: MMProfilePatch) async throws -> MMUserProfile {
        try await put(MMUserProfile.self,
                      path: "/users/\(userID)/patch",
                      body: patch,
                      sessionExpiryOnUnauthorized: false)
    }

    // MARK: - The avatar

    /// `POST /users/{user_id}/image` — the one part the route accepts is named `image`.
    func uploadProfileImage(userID: String,
                            data: Data,
                            filename: String,
                            mimeType: String) async throws {
        _ = try await uploadMultipartResponse(
            path: "/users/\(userID)/image",
            fields: [],
            file: MMMultipart.File(fieldName: "image",
                                   filename: filename,
                                   mimeType: mimeType,
                                   data: data))
    }

    /// `DELETE /users/{user_id}/image` — back to the server's generated fallback.
    func removeProfileImage(userID: String) async throws {
        _ = try await delete(path: "/users/\(userID)/image")
    }

    // MARK: - Custom profile attributes (S39)

    /// `GET /custom_profile_attributes/fields` — the server's schema. Empty when the feature is off;
    /// a 404 is thrown and the screen treats it as "absent" (see `EditProfileViewModel.load`).
    func customProfileAttributeFields() async throws -> [MMCustomProfileAttributeField] {
        try await get([MMCustomProfileAttributeField].self,
                      path: "/custom_profile_attributes/fields",
                      useETag: false)
    }

    /// `GET /users/{user_id}/custom_profile_attributes` — this account's values, keyed by field id.
    func customProfileAttributeValues(userID: String) async throws -> MMCustomProfileAttributeValues {
        try await get(MMCustomProfileAttributeValues.self,
                      path: "/users/\(userID)/custom_profile_attributes",
                      useETag: false)
    }

    /// `PUT /users/{user_id}/custom_profile_attributes` — write values.
    ///
    /// The body is `{"values": {"<field id>": "<value>"}}`, and only the fields that changed are
    /// sent: the endpoint's values map is a patch of its own, so echoing an untouched field is a
    /// rewrite nobody asked for.
    func setCustomProfileAttributeValues(userID: String,
                                         values: [String: String]) async throws {
        _ = try await putForResponse(path: "/users/\(userID)/custom_profile_attributes",
                                     body: MMCustomProfileAttributeValuesBody(values: values))
    }
}

/// The `PUT` body for the values endpoint. A value is a JSON string for the types this build
/// draws (`text`, `select`); the schema's array-shaped types are not rendered here (build note §4).
struct MMCustomProfileAttributeValuesBody: Encodable, Equatable, Sendable {
    var values: [String: String]
}
