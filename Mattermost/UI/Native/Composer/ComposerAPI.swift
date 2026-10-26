// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/client/rest/posts.ts (`createPost` `POST /posts`, `patchPost` `PUT /posts/{id}`,
//        `deletePost` `DELETE /posts/{id}`), app/client/rest/files.ts (`uploadFile` `POST /files`),
//        app/client/rest/users.ts (`autocompleteUsers` `GET /users/autocomplete` with
//        `in_channel_id`/`in_team_id`), app/client/rest/channels.ts (`searchChannels`
//        `GET /teams/{team_id}/channels/search`, `getChannelMembers` `GET /channels/{id}/members`),
//        app/client/rest/emojis.ts (`GET /emoji`, which T34's `ChannelAPI` already owns).
// Licence: Apache-2.0 — endpoints reimplemented against https://api.mattermost.com with attribution
// per docs/THIRD_PARTY_NOTICES.md §12; no upstream source copied.
//
// Every call here goes through `APIClient`, so it inherits: the `/api/v4` prefix, the bearer token
// from the vault, `X-Requested-With`, the typed 401 → re-auth callback, the TLS trust decision shared
// with the webview, and typed `MMError`s. The composer must never build its own request.

import Foundation

extension APIClient {

    // MARK: - Posts (write)

    /// `POST /posts` — create a post (or a reply when `root_id` is set).
    ///
    /// `pending_post_id` is the client's own id for the optimistic row. The server echoes it on the
    /// socket `posted` event, which is how the row is reconciled without guessing by message text (two
    /// people can send the same words).
    ///
    /// No ETag and no retry: a replayed create is a second message. The composer retries only when the
    /// person asks.
    func createPost(_ body: ComposerPostBody) async throws -> MMPost {
        try await post(MMPost.self, path: "/posts", body: body)
    }

    /// `PUT /posts/{id}` — edit a post's message (and, upstream, its file ids).
    func patchPost(_ body: ComposerPostPatch) async throws -> MMPost {
        try await put(MMPost.self, path: "/posts/\(body.id)", body: body)
    }

    /// `DELETE /posts/{id}`. The server answers `{"status":"OK"}`; the tombstone arrives on the socket.
    func deletePost(id: String) async throws {
        _ = try await delete(path: "/posts/\(id)")
    }

    // MARK: - Files

    /// `POST /files` — multipart upload of one file, attributed to a channel.
    ///
    /// The channel field matters: the server checks the uploader's permission against it and the file
    /// is only sendable to that channel. `onProgress` is invoked from the transport's
    /// `didSendBodyData`, not from a timer.
    func uploadFile(_ upload: ComposerUpload,
                    channelID: String,
                    onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> MMFileInfo {
        let response = try await uploadMultipart(
            MMFileUploadResponse.self,
            path: "/files",
            fields: [MMMultipart.Field(name: "channel_id", value: channelID)],
            file: MMMultipart.File(fieldName: "files",
                                   filename: upload.filename,
                                   mimeType: upload.mimeType,
                                   data: upload.data),
            onProgress: onProgress)
        guard let file = response.fileInfos.first else {
            throw MMError.malformedResponse("POST /files returned no file_infos")
        }
        return file
    }

    // MARK: - Autocomplete

    /// `GET /users/autocomplete?name=&in_channel_id=&in_team_id=&limit=` — the `@` list.
    ///
    /// The answer is an **object** — `{"users": [...]}` — not a bare array (measured on 9.11.19: a
    /// bare-array decode made every `@` term produce an empty list, which the live suite caught as
    /// "typing @ asks the server and nothing comes back"). `in_channel_id` is the documented
    /// membership restriction: the server returns people who are in that channel. It is sent whenever
    /// the composer knows the channel, and the client still checks the answer against the channel's
    /// member list when it can read the whole list (see `ComposerMembership`).
    func autocompleteUsers(term: String,
                           inChannel channelID: String?,
                           inTeam teamID: String?,
                           limit: Int = 20) async throws -> [MMUser] {
        var query = [URLQueryItem(name: "name", value: term),
                     URLQueryItem(name: "limit", value: String(max(1, limit)))]
        if let channelID, !channelID.isEmpty {
            query.append(URLQueryItem(name: "in_channel_id", value: channelID))
        }
        if let teamID, !teamID.isEmpty {
            query.append(URLQueryItem(name: "in_team_id", value: teamID))
        }
        let response = try await get(MMAutocompleteUsersResponse.self, path: "/users/autocomplete",
                                     query: query, useETag: false)
        return response.users ?? []
    }

    /// The `GET /users/autocomplete` envelope. `users` is optional so a server that answers `{}` for
    /// a term with no matches decodes to an empty list instead of throwing.
    struct MMAutocompleteUsersResponse: Decodable {
        var users: [MMUser]?
    }

    /// `POST /teams/{team_id}/channels/search {"term":…, "limit":…}` — the `#` list.
    ///
    /// **POST, not GET**: the same path with `?term=` answers 404
    /// `api.context.404.app_error` on 9.11.19 (measured), which made `#` produce nothing at all.
    /// The server returns only channels the caller may see in that team, which is the membership
    /// rule for channels (a private channel the user is not in does not come back).
    func searchChannels(teamID: String, term: String, limit: Int = 20) async throws -> [MMChannel] {
        try await post([MMChannel].self,
                       path: "/teams/\(teamID)/channels/search",
                       body: MMPostTextSearch(term: term, limit: max(1, limit)))
    }

    /// The channel-search request body. Its own type rather than a dictionary so the two documented
    /// fields cannot drift from what is sent.
    struct MMPostTextSearch: Encodable {
        var term: String
        var limit: Int
    }

    /// `GET /channels/{channel_id}/members?page=&per_page=` — one page of the channel's members.
    ///
    /// Used twice by the composer: to check the `@` list against real membership, and (with the
    /// profile fetch) to resolve the author of a mention that arrived without a profile.
    func channelMembers(channelID: String, page: Int, perPage: Int) async throws -> [MMChannelMember] {
        let query = [URLQueryItem(name: "page", value: String(max(0, page))),
                     URLQueryItem(name: "per_page", value: String(min(max(1, perPage), 200)))]
        return try await get([MMChannelMember].self,
                             path: "/channels/\(channelID)/members",
                             query: query,
                             useETag: false)
    }
}
