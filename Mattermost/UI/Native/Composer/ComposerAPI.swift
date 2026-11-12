// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/client/rest/posts.ts (`createPost` `POST /posts`, `patchPost` `PUT /posts/{id}`,
//        `deletePost` `DELETE /posts/{id}`), app/client/rest/files.ts (`uploadFile` `POST /files`),
//        app/client/rest/users.ts (`autocompleteUsers` `GET /users/autocomplete` with
//        `in_team`/`in_channel` — the pin's own parameter names, see the method's doc), app/client/rest/channels.ts (`searchChannels`
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

    /// `GET /users/autocomplete?name=&in_team=&in_channel=&limit=` — the `@` list.
    ///
    /// **The parameter names are load-bearing, and the ones this file used to send were the wrong
    /// ones** (kanban t_03f2dbfd, measured on 9.11.19):
    ///
    ///  * `in_team` takes the **team id**. With a team *name* the server answers `[]`; with a bogus
    ///    id it answers `[]`, so it really is applied. `in_team_id` is **ignored** (a bogus id still
    ///    answers the team's users), which is why the composer's team scope never applied.
    ///  * `in_channel` is the channel scope, and it **requires `in_team`**: alone it is a `500`
    ///    `api.user.autocomplete_users.missing_team_id.app_error` ("Team id parameter is required to
    ///    autocomplete by channel"). `in_channel_id` is ignored: the answer is team-wide.
    ///
    /// With both correct parameters the envelope carries the split the reader needs:
    /// `{"users": <in channel>, "out_of_channel": <team, not in channel>}`. Newer servers also add
    /// `agents` (AI agents); 9.11.19 does not, which is why every key but `users` is optional.
    func autocompleteUsers(term: String,
                           inChannel channelID: String?,
                           inTeam teamID: String?,
                           limit: Int = 20) async throws -> ComposerUserCandidates {
        var query = [URLQueryItem(name: "name", value: term),
                     URLQueryItem(name: "limit", value: String(max(1, limit)))]
        let team = teamID.flatMap { $0.isEmpty ? nil : $0 }
        let channel = channelID.flatMap { $0.isEmpty ? nil : $0 }
        if let team {
            query.append(URLQueryItem(name: "in_team", value: team))
        }
        // Only with a team: the server refuses a channel scope that has no team beside it.
        if let channel, team != nil {
            query.append(URLQueryItem(name: "in_channel", value: channel))
        }
        let response = try await get(MMAutocompleteUsersResponse.self, path: "/users/autocomplete",
                                     query: query, useETag: false)
        return ComposerUserCandidates(inChannel: response.users ?? [],
                                      outOfChannel: response.outOfChannel,
                                      agents: response.agents)
    }

    /// The `GET /users/autocomplete` envelope.
    ///
    /// `users` is optional so a server that answers `{}` for a term with no matches decodes to an
    /// empty list instead of throwing. `outOfChannel` being **present but empty** is meaningful and
    /// is kept as an optional: it is the server saying it did the split and nobody else matched, as
    /// opposed to a server that never splits at all (see `ComposerUserCandidates.isClassified`).
    struct MMAutocompleteUsersResponse: Decodable {
        var users: [MMUser]?
        var outOfChannel: [MMUser]?
        var agents: [MMUser]?

        enum CodingKeys: String, CodingKey {
            case users, agents
            case outOfChannel = "out_of_channel"
        }
    }

    /// `GET /bots?per_page=200` — the server's bot accounts.
    ///
    /// Used to *label* a mention row ("Bot"), because the user records on 9.11.19 carry no marker:
    /// `feedbackbot`, `playbooks`, `calls` and `system-bot` are all `roles: "system_user"` (measured),
    /// and this list is the server's own answer for which accounts those are. A caller that may not
    /// read it (a non-admin gets `403` — measured) simply labels nothing.
    func bots(perPage: Int = 200) async throws -> [MMBot] {
        try await get([MMBot].self,
                      path: "/bots",
                      query: [URLQueryItem(name: "per_page", value: String(min(max(1, perPage), 200)))],
                      useETag: false)
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

    // MARK: - Slash commands

    /// `GET /commands?team_id={id}` — every command the team can run: the server's built-ins, the
    /// team's custom integrations, and the plugin commands (Playbooks, Calls).
    ///
    /// A bare array, not an envelope (measured on 9.11.19: 33 records for team `perf`). The answer is
    /// per **team**, so it is cached by the caller (`SlashCommandCatalogue`) rather than fetched per
    /// keystroke. A missing `team_id` is a 400 `api.context.invalid_body_param.app_error` on that
    /// server, which is why the caller never asks without one.
    func commands(teamID: String) async throws -> [MMCommand] {
        try await get([MMCommand].self,
                      path: "/commands",
                      query: [URLQueryItem(name: "team_id", value: teamID)],
                      useETag: false)
    }

    /// `POST /commands/execute` — run a slash command in a channel (or a thread, with `root_id`).
    ///
    /// The command string is the whole line the reader typed (`/help`, `/invite @kim`); the server
    /// parses it. `notFoundKeepsServerMessage` is load-bearing: an unknown trigger is a **404 whose
    /// body carries the sentence** upstream shows in
    /// `alertSlashCommandFailed` ("Command with a trigger of 'x' not found…"), and the generic 404
    /// mapping drops it.
    ///
    /// No retry and no ETag: replaying a command is a second execution (`/invite` twice, `/leave`
    /// twice), so the composer offers Retry only when the person asks.
    func executeCommand(_ body: ComposerCommandBody) async throws -> ComposerCommandResponse {
        try await post(ComposerCommandResponse.self,
                       path: "/commands/execute",
                       body: body,
                       notFoundKeepsServerMessage: true)
    }

    /// One boolean out of `GET /config/client?format=old` — the public config the webapp itself
    /// reads, and the only place `FeatureFlagAppsEnabled` is published.
    ///
    /// The answer is a **flat map of name → value** (`ApplicationSettings`, `ServiceSettings`…
    /// flattened into one object) and a flag can arrive as a JSON boolean or as the string `"true"`,
    /// depending on the field. Measured on 9.11.19: `FeatureFlagAppsEnabled` is `true` (boolean) on a
    /// server whose Apps plugin is **not installed** — so this flag says "the framework is switched
    /// on", never "an app command exists".
    func clientConfigFlag(_ name: String) async throws -> Bool {
        let raw = try await get([String: JSONValue].self,
                                path: "/config/client",
                                query: [URLQueryItem(name: "format", value: "old")],
                                requiresAuth: false)
        switch raw[name] {
        case .bool(let flag): return flag
        case .string(let text): return text.lowercased() == "true"
        default: return false
        }
    }

    /// `GET /plugins/com.mattermost.apps/api/v1/bindings` → the labels of the **command**-location
    /// bindings: the only thing that can tell an app command from a slash command.
    ///
    /// Two facts about this route, both measured on 9.11.19 (kanban t_08826621):
    ///
    ///  * it lives under the apps plugin's own `/plugins/…` prefix, still inside `/api/v4`, so it
    ///    goes through this same client (auth, trust, typed errors);
    ///  * with the apps plugin absent it answers **404 `api.context.404.app_error`** — the route is
    ///    not registered at all. That is not an error worth surfacing: no bindings means no app
    ///    commands, which is exactly what `[]` says. `appsPosture` in `ComposerService` turns every
    ///    failure into "no app commands", which is also what upstream does when its bindings fetch
    ///    fails (`AppsManager.handleError` sets `enabled = false`).
    ///
    /// The response is a list of apps, each carrying its own `bindings` array (upstream's
    /// `normalizeBindings` flattens exactly that). It is walked as raw JSON instead of decoded into
    /// fixed types because the Apps protocol is explicitly out of scope here (S34 D2) and a shape
    /// this client does not draw must not be able to throw on the send path.
    func appsCommandLabels(userID: String,
                           channelID: String,
                           teamID: String?) async throws -> [String] {
        var query = [URLQueryItem(name: "channel_id", value: channelID)]
        if !userID.isEmpty { query.append(URLQueryItem(name: "user_id", value: userID)) }
        if let teamID, !teamID.isEmpty { query.append(URLQueryItem(name: "team_id", value: teamID)) }
        let answer = try await get([JSONValue].self,
                                   path: "/plugins/com.mattermost.apps/api/v1/bindings",
                                   query: query,
                                   useETag: false)
        var labels: [String] = []
        func walk(_ value: JSONValue) {
            switch value {
            case .array(let items):
                items.forEach(walk)
            case .object(let object):
                // An app group: `{app_id, bindings: [...]}`. Its own object is not a binding.
                if let nested = object["bindings"] {
                    walk(nested)
                    return
                }
                if let location = object["location"], case .string(let place) = location,
                   place.lowercased() != "command" {
                    return
                }
                if let label = object["label"], case .string(let text) = label, !text.isEmpty {
                    labels.append(text)
                }
            default:
                break
            }
        }
        walk(.array(answer))
        return labels
    }
}
