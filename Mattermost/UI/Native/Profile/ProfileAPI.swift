// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/client/rest/users.ts (`getUser`, `getStatusesByIds`, `getUserStatus`, `updateMe`,
//        `updateCustomStatus`, `unsetCustomStatus`, `getUserProfilePictureUrl`),
//        app/client/rest/channels.ts (`createDirectChannel`).
// Licence: Apache-2.0 — endpoints reimplemented against https://api.mattermost.com with attribution
// per docs/THIRD_PARTY_NOTICES.md §18; no upstream source copied.
//
// Only the endpoints T41 needs that the existing groups do not already cover:
//   * `POST /users/status/ids` already exists (`MMEndpoints.statuses(ids:)`) and is **reused**;
//   * `GET /channels/{id}`, `POST /users/ids` and `/users/me` exist too.
//
// Three shapes worth stating because they are easy to get wrong (all measured — see
// `ProfileModels.swift`'s header):
//
//  1. `PUT /users/{user_id}/status/custom` takes the custom status **flat**, not wrapped in a
//     `custom_status` object. Wrapping it answers `400 invalid_body_param`.
//  2. `DELETE /users/{user_id}/status/custom` answers `{"status":"OK"}` and there is **no**
//     `GET …/status/custom` route on 9.11.19 (404). The status is read back from
//     `user.props.customStatus` instead — which is why the profile always reads the user.
//  3. `POST /channels/direct` answers **201** — on the first call *and* on a repeat call that finds
//     the existing conversation (measured on 9.11.19: 201 both times, same channel id). So "open a
//     conversation" is idempotent and any 2xx must be accepted; a client that required 200 for the
//     existing-channel case would refuse a DM the server had just handed it.

import Foundation

extension APIClient {

    // MARK: - The profile

    /// `GET /users/{user_id}` — the profile, including `roles`, `timezone` and `props`.
    ///
    /// **No ETag.** Everything this screen draws can change while it is open (a custom status from
    /// another device, a role change, a rename), and a `304` replay would pin the screen to what it
    /// said on the first open — the same reasoning as T40's channel reads.
    func userProfile(id: String) async throws -> MMUserProfile {
        try await get(MMUserProfile.self, path: "/users/\(id)", useETag: false)
    }

    /// `POST /users/ids` — the batch profile read.
    ///
    /// Used when a row holds only a user id. Answers the same full objects as the single read
    /// (measured: `roles`, `timezone` and `props` are all present), so the screen can draw a profile
    /// for a user this device has never stored without a second round trip.
    func userProfiles(ids: [String]) async throws -> [MMUserProfile] {
        guard !ids.isEmpty else { return [] }
        return try await post([MMUserProfile].self, path: "/users/ids", body: ids)
    }

    /// `PUT /users/{user_id}/status` — set my own presence.
    ///
    /// `/users/me/status` and `/users/{my_id}/status` are the same handler; the id is sent explicitly
    /// so a caller that only knows its own user id (the coordinator) needs no second lookup.
    func setMyStatus(_ presence: UserPresence, dndEndTime: Int64? = nil,
                     userID: String) async throws -> MMStatus {
        let body = PresenceUpdateBody(userID: userID, presence: presence, dndEndTime: dndEndTime)
        return try await put(MMStatus.self, path: "/users/\(userID)/status", body: body)
    }

    /// `PUT /users/{user_id}/status/custom` — set a custom status (flat body; see the header).
    @discardableResult
    func setCustomStatus(userID: String, body: CustomStatusBody) async throws -> APIResponse {
        try await putForResponse(path: "/users/\(userID)/status/custom", body: body)
    }

    /// `DELETE /users/{user_id}/status/custom` — clear it.
    @discardableResult
    func clearCustomStatus(userID: String) async throws -> APIResponse {
        try await delete(path: "/users/\(userID)/status/custom")
    }

    // MARK: - The DM shortcut

    /// `POST /channels/direct` with the two user ids — the conversation, created or found.
    ///
    /// 201 on creation and 200 on the second call (measured), both answering the channel, so the
    /// caller does not have to care which happened.
    func directChannel(userIDs: [String]) async throws -> MMChannel {
        // The body is a bare JSON array of ids (`["<me>","<them>"]`), not an object, so it is encoded
        // directly: `postForResponse` takes bytes, and `post(_:path:body:)` would work too but its
        // signature reads as "send this object".
        let data = try JSONEncoder().encode(userIDs)
        let response = try await postForResponse(path: "/channels/direct", body: data)
        return try decode(MMChannel.self, from: response)
    }

    // MARK: - The avatar

    /// The authenticated profile image path.
    ///
    /// Behind the session, so it goes through the same `APIClient` as every other call (an
    /// `AsyncImage` cannot send the bearer token). The cache-buster is the user's `update_at`, which
    /// is what the server changes when a picture is replaced.
    func userProfileImagePath(userID: String) -> String { "/users/\(userID)/profile_image" }

    /// The avatar bytes, or `nil` when the account has no picture (measured: `404` for an account
    /// without one — the normal case for a fixture, so it must not read as an error on screen).
    func userProfileImage(userID: String, lastUpdateAt: Int64) async -> Data? {
        var query: [URLQueryItem] = []
        if lastUpdateAt > 0 {
            query.append(URLQueryItem(name: "_", value: String(lastUpdateAt)))
        }
        return try? await getData(path: userProfileImagePath(userID: userID),
                                  query: query,
                                  useETag: true)
    }
}
