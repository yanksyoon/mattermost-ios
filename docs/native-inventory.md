# Native screen + API inventory (T25)

- **Status:** delivered (T25 input for T25b translation map, T26 dual-render, T28 transport, T31–T45 screen cards)
- **Date:** 2026-10-24
- **Program anchor:** T24 ADR (`docs/path-b-adr.md`) §2.2 sequencing, §4 memory premise (T27), §3 licence boundary
- **Consumer:** `docs/native-inventory.md` one row per user-visible surface and per protocol call.

## 0. Method, sources, evidence index

The inventory is **repo-tree-first** (authoritative screen list from the Apache-2.0 official
client), with **REA (MIT, installed locally for this card, not added to the app)** used only to
confirm which endpoints a live screen actually calls, per operator steering.

Sources and their licence position:

| Source | Position | Used for |
|---|---|---|
| `refs/mattermost-mobile` (Apache-2.0, `mattermost/mattermost-mobile` @ `main`, 86 MB, shallow clone in T25 workspace) | **Safe reference.** Patterns may be reimplemented in Swift. | Screen list (`app/screens/`, 67 top-level modules), route tree (`app/routes/`, expo-router, 133 route files), REST client (`app/client/rest/*.ts`), WebSocket client + event constants (`app/client/websocket/index.ts`, `app/constants/websocket.ts`), per-screen data actions (`app/actions/remote/*.ts`). |
| `mattermost/mattermost` monorepo `webapp/` (Apache-2.0 — verified 2026-10-24; `LICENSE.txt` line 15: "Admin Tools and Configuration Files (… `webapp/` and all subdirectories thereof) under the Apache License v2.0") | **Safe, with attribution.** This supersedes the ADR's AGPL note for the *current* webapp tree. | Component cross-check (`webapp/channels/src/components/`). |
| `mattermost/mattermost-webapp` (legacy repo referenced by the ADR) | **AGPL-3.0 — observe only. Never copied.** | Behaviour observation only. |
| `https://api.mattermost.com` (public REST v4 + WebSocket v4 contract) | **The contract.** Reimplementation target. | Endpoint semantics, query params, pagination. |
| Live server (public mattermost community server, observed 2026-10-24, v12.1.0 enterprise; hostname withheld per repo rule) | **Observation only** (no account on this host; unauthenticated surfaces only). | Login / SSO / sign-up / password reset surfaces; live API calls (below); plugin bundle list. |

Capture artifacts (kept under `docs/inventory/`, hostnames redacted to `{server}` per repo rule):

| Artifact | Contents | Evidence for |
|---|---|---|
| `docs/inventory/rest-endpoints.tsv` | 147 endpoint rows extracted from `refs/mattermost-mobile/app/client/rest/*.ts` doFetch call sites (module, verb, path with placeholders). | §2 rows (each cites a module + path). |
| `docs/inventory/websocket-events.md` | 113 WebSocket v4 event names from `refs/mattermost-mobile/app/constants/websocket.ts`. | §2 WS columns; Appendix A. |
| `docs/inventory/screens.tsv` | 67 top-level screens + route note. | §1. |
| REA browser-scenario captures (raw JSON ev_* and sanitized `docs/inventory/…` summaries) | Playwright headless Chrome scenarios against the live login, sign-up, password-reset pages; network events (method/url/query-param names), console, page errors, DOM/storage/history snapshots, screenshot. | §2 "Live-observed calls" per auth row. |

**Sanitisation rule:** this document and `docs/inventory/` never contain a real workspace
hostname, URL, or token. Protocol calls are written as `{server}/api/v4/...`; observed plugin ids
are generic where a real server's plugin list is incidental. REA raw JSONs with the observed
hostname stay in the T25 workspace (not committed).

**Honest gaps (recorded, not fake-passed):** post-login surfaces (channel view, threads, sidebar
with real data, search, …) could not be *live-observed* on this host — no account exists for the
public server and no self-hosted server is running (Docker daemon down). Their evidence comes
from the Apache-2.0 reference client and the public API contract, which the ADR names as the
authority for inventory; REA confirmed only the unauthenticated screens live. Real-device push,
SSO against a real IdP, and Calls remain unobservable here (see §5).

---

## 1. Screen inventory — one row per user-visible surface

Evidence legend: `M:` = mobile ref path under `refs/mattermost-mobile/`; `R:` = route file under
`app/routes/`; `L:` = live-observed on a public live server (unauthenticated); `W:` = webapp
route/behaviour (observed only). Rows are grouped by the ADR §2.2 build order.

| # | Surface | What the user sees/does | Evidence |
|---|---|---|---|
| S01 | Login (email/password, ldap, guest) | Sign-in form: email-or-username + password; error states (password reset hint, FIPS notice); "don't have an account" / forgot-password links; desktop-app interstitial first. | M: `app/screens/login`, `R:(unauthenticated)/login.tsx`; L: `{server}/login` (form: `loginId` + `password-input`, links to signup, reset, SSO); bare-host interstitial "View in Desktop App / View in Browser" observed. |
| S02 | MFA (TOTP / email auth) | After password, second-factor challenge (6-digit code, or email link), switch-method. | M: `app/screens/mfa`, `R:(modals)/(add-server)/mfa.ts`, `R:(unauthenticated)/mfa.tsx`. |
| S03 | SSO (SAML/OAuth) | Redirect to IdP and back; code exchange; "we're connecting you" interstitial. | M: `app/screens/sso`, `R:(unauthenticated)/sso.tsx`; L: login page's "Microsoft" button -> `{server}/login/sso/saml`. |
| S04 | Sign-up + forgot/reset password | Create account (email + password), email verification; request/reset password. | M: `app/screens/forgot_password`, `app/screens/onboarding`; R: `(unauthenticated)/forgot_password.tsx`, `(modals)/(add-server)/forgot_password.ts`; L: `{server}/signup_user_complete` (email + password, 14-72 char policy) and `{server}/reset_password` (email-only form). |
| S05 | Server add/edit/select + diagnostics | Add/remove/edit server URLs; URL validation probe; pick active server; server-specific settings (in `Settings`). | M: `app/screens/server`, `app/screens/edit_server`; R: `(modals)/(add-server)/server.ts`, `(authenticated)/account.tsx`; **already native in this repo**: `Core/ServerFormView.swift` + `ServerURLValidator` (T5) probes `{server}/api/v4/system/ping` + `{server}/api/v4/config/client?format=old`. |
| S06 | Terms of service gate | Post-login TOS acknowledge screen. | M: `app/screens/terms_of_service`, R: `(bottom_sheet)/terms_of_service.tsx`. |
| S07 | Team selection | Pick team after login (multi-team servers); no-team empty state. | M: `app/screens/select_team`, R: `(authenticated)/select_team.tsx`; W: webapp `/select_team` (observed pattern). |
| S08 | Channel sidebar (list + categories + unread + mute + DM/GM) | Left rail: Favorites/Channels/Direct Messages categories, unread dots, mention badges, muted channels, public/private/DM/GM badges, collapse, re-order, create-new-menu. | M: `app/screens/home` (sub-tabs `channel_list`, `recent_mentions`, `saved_messages`, `search`, `account`), `app/components/team_sidebar`, `app/components/channel_list_row`, `app/actions/remote/category.ts`, `app/actions/remote/channel.ts`; R: `(authenticated)/(home)/channel_list.tsx`, `(authenticated)/(home)/index.tsx`; W: webapp left-hand sidebar behaviour. |
| S09 | Find / browse channels | Search channels; browse public channels of a team; join. | M: `app/screens/find_channels`, `app/screens/browse_channels`; R: `(modals)/find_channels.tsx`, `(modals)/(browse_channels)/index.tsx`. |
| S10 | Create / edit / convert channel | Create public/private channel; edit name/header/purpose; convert GM->private channel. | M: `app/screens/create_or_edit_channel`, `app/screens/channel_configuration`, `app/screens/convert_gm_to_channel`; R: `(modals)/create_or_edit_channel.tsx`, `(modals)/(channel_info)/channel_configuration.tsx`. |
| S11 | Channel view (post list) | Read posts: markdown + GFM, images, files, embedded media, per-post actions, pagination (newer/older), jump-to-newest, unread marker, auto-load archive, system messages, thread teasers. | M: `app/screens/channel`, `app/components/post_list`, `app/components/markdown`, `app/actions/remote/post.ts`; R: `(authenticated)/channel.tsx`. **Core native target (T34).** |
| S12 | Thread link / permalink | Open a link to a specific post/channel/team (in-app, and from deep links/push). | M: `app/screens/permalink`, `app/actions/remote/permalink.ts`, `app/routes/+native-intent.ts`; R: `(authenticated)/permalink.tsx`. |
| S13 | Thread RHS + global threads | Reply panel beside channel (or push on phone): replies, follow/unfollow, mark read/unread, thread list ("Threads" tab), followed-thread inbox. | M: `app/screens/thread`, `app/screens/thread_options`, `app/screens/global_threads`; R: `(authenticated)/thread.tsx`, `(bottom_sheet)/thread_options.tsx`, `(authenticated)/global_threads.tsx`. **Native target (T36).** |
| S14 | Composer (send / edit / draft) | Message input: send, edit, reply, draft persistence, scheduled posts, markdown toolbar, slash commands, send-as, attachments upload. | M: `app/components/post_draft`, `app/screens/edit_post`, `app/screens/global_drafts`, `app/screens/draft_scheduled_post_options`, `app/screens/reschedule_draft`, `app/actions/remote/post.ts`; R: `(modals)/edit_post.tsx`, `(authenticated)/global_drafts.tsx`. **Native target (T35).** |
| S15 | Autocomplete (users / channels / emojis / commands / slash) | `@` user, `#` channel, `:` emoji, `/` command suggestion overlays while typing. | M: `app/components/autocomplete`, `app/components/emoji`; used from `post_draft`. Federated into T35. |
| S16 | Reactions | Add/remove emoji reactions on posts; reaction summary popover with avatars. | M: `app/screens/reactions`, `app/components/common_post_options`, `app/actions/remote/reactions.ts`; R: `(bottom_sheet)/reactions.tsx`. |
| S17 | Emoji picker + custom emoji | Grid picker; frequently-used row; custom emoji list/upload; emoji search. | M: `app/screens/emoji_picker`, `app/components/emoji_category_bar`, `app/actions/remote/custom_emoji.ts`; R: `(bottom_sheet)/emoji_picker.tsx`. |
| S18 | File/image viewer + gallery | Photo/video gallery swipe; PDF viewer; code/table/latex renderers; share/open-external; download to files. | M: `app/screens/gallery`, `app/screens/pdf_viewer`, `app/screens/code`, `app/screens/table`, `app/screens/latex`, `app/components/files`; R: `(bottom_sheet)/gallery.tsx`, `(modals)/pdf_viewer.tsx`. |
| S19 | Search (global + in-channel) | Search bar; results with filters (in:, from:, before:…); jump to result; recent searches. | M: `app/screens/search`, `app/actions/remote/search.ts`, `app/components/search`; R: `(authenticated)/(home)/search.tsx`. |
| S20 | Saved messages ("Saved") | Flagged posts list; unflag. | M: `app/screens/home` (tab `saved_messages`); R: `(authenticated)/(home)/saved_messages.tsx`; driven by `preferences` (flag = `grouped_saved_post_<id>=true`). |
| S21 | Pinned messages | Channel pinned-post list; pin/unpin from post menu. | M: `app/screens/pinned_messages`; R: `(modals)/(channel_info)/pinned_messages.tsx`; pinned list via `GET /channels/{id}/pinned`. |
| S22 | Channel info + add members | Channel header tap -> channel info: name/header/purpose, notifications, files, members, settings, leave/archive; add members UI. | M: `app/screens/channel_info`, `app/screens/channel_add_members`, `app/screens/channel_notification_preferences`, `app/screens/channel_share`, `app/screens/channel_bookmark`; R: `(modals)/(channel_info)/index.tsx` + subroutes. |
| S23 | Members / member list + manage | Member list with search, roles (admin/member), remove; invite to team/channel; GM management. | M: `app/screens/manage_channel_members`, `app/screens/invite`, `app/screens/join_team`, `app/screens/create_direct_message`; R: `(modals)/(channel_info)/manage_channel_members.tsx`, `(modals)/invite.tsx`. |
| S24 | Profile popover + status + custom status | Tap avatar: profile sheet (bio, roles, channels in common, custom status set/clear, "set custom status" with duration). | M: `app/screens/user_profile`, `app/screens/custom_status`, `app/screens/custom_status_clear_after`; R: `(bottom_sheet)/user_profile.tsx`, `(modals)/(custom_status)/index.tsx`. **Native target (T41).** |
| S25 | Activity / mentions inbox + in-app notification | Mentions tab, unread tab, toast/snack-bar in-app notification on new mention; notification settings. | M: `app/screens/mentions`, `app/screens/in_app_notification`, `app/screens/snack_bar`, `app/actions/remote/notifications.ts`; R: `(authenticated)/(home)/mentions.tsx`. |
| S26 | Drafts + scheduled posts | Global drafts list; scheduled post pickers (date/time/recurrence) with reschedule/delete. | M: `app/screens/global_drafts`, `app/screens/draft_scheduled_post_options`, `app/screens/scheduled_post_options`, `app/screens/reschedule_draft`; R: `(bottom_sheet)/draft_scheduled_post_options.tsx`, `(modals)/reschedule_draft.tsx`. |
| S27 | User settings (display / notifications / general) | Settings tree: display (theme/clock/timezone/CRT), notifications (mention/email/push/calls/auto-responder), advanced, about, component library. | M: `app/screens/settings` (+ `settings_*` subdirs: `settings_display*`, `settings_notification*`, `settings_advanced`, `about`, `report_problem`); R: `(modals)/(settings)/*`. **This repo's native `SettingsView` already exists (T11) — keep native.** |
| S28 | Edit profile | Edit name/username/email/roles, profile picture, custom attributes. | M: `app/screens/edit_profile`, `app/actions/remote/user.ts`; R: `(modals)/edit_profile.tsx`. |
| S29 | System Console (admin) | Server-global admin UI. | W: webapp `/admin` (observed pattern); M: **absent from the mobile client by design** — supports "webview-only" disposition. |
| S30 | Plugin screens (generic) | Any server plugin's opaque web UI (e.g. Jira, Todo, MS Teams sync, Google Meet/Calendar, badges, dataminr, connect4 all observed on the live server's login page script list). | L: live plugin bundle list (10+ plugin bundles on one page); M: apps framework `app/screens/apps_form`, `app/screens/dialog_router`, `app/screens/integration_selector`; plugins fetched via `{server}/api/v4/plugins/webapp` (live-observed). |
| S31 | Boards | Kanban board plugin surface. | M: `app/products/boards` (plugin client); disposition webview-only. |
| S32 | Playbooks | Runbook/playbook plugin surface incl. channel-info playbook entries. | M: `app/products/playbooks`; routes `playbook_*.tsx` under `(authenticated)` and `(modals)/(channel_info)/playbook_*`; disposition webview-only. |
| S33 | Calls (voice/video/screen share) | VoIP in channel header; participants sheet; screen-share via Broadcast Extension. | M: `app/products/calls`, `app/screens/... /call.tsx` route, `(bottom_sheet)/call_participants.tsx`; WS `custom_<calls>` events; disposition webview-only, last/optional (ADR §2.3, T44/T16). |
| S34 | Apps framework (slash `/`, binded buttons, modals, dialogs) | Plugin Apps: command suggestions, interactive dialogs, selectors. | M: `app/screens/dialog_router`, `app/screens/apps_form`, `app/screens/integration_selector`, `app/routes/(modals)/apps_form.tsx`; REST `{server}/plugins/com.mattermost.apps/api/v1/*` (bindings, call); WS `custom_com.mattermost.apps_refresh_bindings`. |
| S35 | Notifications (local + push) | Permission prompt; mention/unread local notifications; badge; deep link to channel; push path (T43). | M: `app/screens/in_app_notification`; **already native here**: `Core/NotificationWorker.swift` (T8), `Core/SessionStore.swift` badge (T8); push proxy simulacrum `PushProxy/` (T12); real APNs blocked on this host (see §5). |
| S36 | Deep links / share extension / native intents | `mattermost://` deep links, share-sheet target. | M: `app/routes/+native-intent.ts`, `app/routes/+native-intent.test.ts`; **already native here**: `Core/DeepLinkRouter.swift` (T4). Share extension: `share_extension/` at the mobile repo root. |
| S37 | Onboarding / welcome + join team | First-run welcome pager; invite links; join team via open invitation. | M: `app/screens/onboarding`, `app/screens/join_team`; **already native here**: `UI/WelcomeView.swift` (T10). |
| S38 | Post options (long-press menu) | Copy/edit/delete/reactions/pin/flag/mark unread/translate/reply-in-thread; burn-on-read variants. | M: `app/screens/post_options`, `app/components/common_post_options`, `app/actions/remote/post.auxiliary.ts`; R: `(bottom_sheet)/post_options.tsx`. |
| S39 | Custom profile attributes / property fields | Per-org profile fields editing/reading. | M: `app/screens/edit_profile` (custom attributes), `app/actions/remote/custom_profile.ts`; REST `custom_profile_attributes.ts`; WS `custom_profile_attributes_*`. |
| S40 | Scheduled posts (separate from drafts) | Post composer "send later" plus scheduled-post management in a channel. | M: `app/screens/scheduled_post_options`, `app/screens/reschedule_draft`, `app/actions/remote/scheduled_post.ts`; REST `scheduled_post.ts`; WS `scheduled_post_*`. |

### Webapp-route cross-check (W column)
The live server's SPA refused to enumerate its lazy chunk routes without a login. What was
observable unauthenticated: `/`, `/login`, `/login/sso/saml`, `/signup_user_complete`,
`/reset_password`, and the desktop-app interstitial redirect (`/landing#/login` observed in the
REA capture's navigation history). Post-login webapp routes (`/:team/channels/:channel`,
`/:team/search`, `/admin/…`, boards/playbooks/calls plugin routes) are known behaviours from
observation and the mobile ref; they are recorded here as W where needed, never copied from the
AGPL tree.

---

## 2. Protocol inventory — REST v4 endpoints + WebSocket v4 events per surface

Conventions: every path is relative to `{server}/api/v4` unless prefixed `/plugins/`; `?{params}`
means a query string (pagination `page`, `per_page`, cursors `before`, `after`, `since`,
`last_delete_at`, filters like `include_deleted`, `exclude_default_channels` — see
`docs/inventory/rest-endpoints.tsv` for the full extracted set). WS events are the event names in
`docs/inventory/websocket-events.md` (113 total). "Live-observed" means captured by the REA
browser scenario on the live server (unauthenticated).

| # | Surface | REST endpoints (module: path) | WS events reacted to |
|---|---|---|---|
| S01 | Login | `users: POST /users/login` (also `POST /users/login/type` for ldap/guest variants) — **live-observed** boot calls on the login page: `general: GET {server}/api/v4/config/client?format=old`, `GET {server}/api/v4/license/client`, `plugins: GET /plugins/webapp`, `GET /brand/image?t=0`, `GET /cloud/check-cws-connection`, `properties: GET /properties/groups/access_control/system/fields?target_type=system` | `hello` (on connect), `license_changed`, `config_changed` |
| S02 | MFA | `users: POST /users/mfa` (verify/regenerate); token flows ride the session header (T28) | — |
| S03 | SSO | `users: POST /users/login/sso/code-exchange`; OAuth/SAML entry via webapp route `{server}/login/sso/saml` (live-observed) | `hello` |
| S04 | Sign-up / reset | `users: POST /users` (create), `users: POST /users/password/reset/send`; `tos: GET /users/{user_id}/terms_of_service` + `POST /users/{user_id}/terms_of_service` | — |
| S05 | Server add/edit/select | `general: GET {server}/api/v4/system/ping` (documented; already used by this repo's `Core/ServerAPI.swift`), `general: GET {server}/api/v4/config/client?format=old` (live-observed), `general: GET {server}/api/v4/license/client?format=old` | — |
| S06 | TOS gate | `tos: GET /terms_of_service` (server default), `users: POST /users/{user_id}/terms_of_service` | — |
| S07 | Team selection | `teams: GET /users/{user_id}/teams`, `teams: GET /users/{user_id}/teams/members`, `teams: POST /teams/members` (join), `teams: GET /teams/{team_id}/members/{user_id}` | `added_to_team`, `leave_team`, `update_team`, `delete_team`, `restore_team`, `user_role_updated`, `role_updated` |
| S08 | Channel sidebar | `categories: GET/PUT /users/{user_id}/teams/{team_id}/channels/categories`, `GET …/categories/order`, `GET …/categories/{category_id}`; `channels: GET /users/{user_id}/channels?{params}` (with `last_delete_at` incremental), `GET /users/{user_id}/teams/{team_id}/channels?{params}`, `POST /channels/members/me/view`; `users: GET /users/status?{params}` (bulk status), `users: POST /users/status/ids`; `preferences` for muted/dnd: `GET/PUT /users/{user_id}/preferences` | `sidebar_category_created/updated/deleted`, `sidebar_category_order_updated`, `channel_created/updated/deleted/restored`, `direct_added`, `group_added`, `channel_viewed`, `multiple_channels_viewed`, `channel_member_updated`, `channel_converted`, `post_unread`, `preference_changed`, `preferences_changed`, `status_change`, `user_added`, `user_removed` |
| S09 | Find / browse channels | `channels: GET /teams/{team_id}/channels/autocomplete?{params}`, `GET /teams/{team_id}/channels/search_autocomplete?{params}`, `POST /teams/{team_id}/channels/search`, `POST /channels/search?{params}`, `GET /users/{user_id}/teams/{team_id}/channels/order` (implied ordering), `POST /channels/members` (join via browse) | `channel_created`, `channel_deleted`, `user_added` |
| S10 | Create/edit/convert channel | `channels: POST /channels`, `POST /channels/direct`, `POST /channels/group`, `PUT /channels/{channel_id}`, `PUT /channels/{channel_id}/patch`, `PUT /channels/{channel_id}/privacy`, `POST /channels/{channel_id}/convert_to_channel?team-id={team_id}`, `DELETE /channels/{channel_id}` | `channel_created`, `channel_updated`, `channel_converted`, `channel_deleted`, `direct_added`, `group_added` |
| S11 | Channel view | `posts: GET /channels/{channel_id}/posts?{params}` (paging: `page/per_page` or `before/after/since`), `GET /posts/{post_id}`, `GET /posts/{post_id}/thread?{params}` (teaser), `POST /posts/{post_id}/set_unread`, `posts: POST /posts/{post_id}/pin|unpin`, `DELETE /posts/{post_id}`; `files: GET /posts/{post_id}/files/info`, `GET /files/{file_id}/info`; `preferences: GET /users/{user_id}/preferences` (flags/theme); `channels: GET /channels/{channel_id}` refresh | `posted`, `post_edited`, `post_deleted`, `post_unread`, `ephemeral_message`, `typing`, `stop_typing`, `increase_post_visibility_by_one`, `user_added`, `user_removed`, `channel_viewed`, `thread_updated`, `thread_follow_changed`, `thread_read_changed`, `reaction_added/removed`, `preference_changed`, `status_change`, `post_acknowledgement_added/removed` |
| S12 | Permalink/thread link | `posts: GET /posts/{post_id}`, `GET /posts/{post_id}/thread?{params}`, `channels: GET /teams/name/{team_name}/channels/name/{channel_name}` (URL->ids), `general: GET /redirect_location?{params}` | `posted`, `post_deleted` (link expiry) |
| S13 | Threads | `threads: GET /users/{user_id}/teams/{team_id}/threads?{params}` (params `since,before,after,page_size,unread,totalsOnly,deleted`), `GET /users/{user_id}/teams/{team_id}/threads/{thread_id}?{params}`, `PUT …/threads/{thread_id}` (mark read with timestamp), `PUT …/threads/{thread_id}/set_unread` (postId), `PUT …/threads/{thread_id}/follow` (state bool), `PUT /users/{user_id}/teams/{team_id}/threads/read`; `posts: GET /posts/{post_id}/thread?{params}` for the reply panel | `posted`, `thread_updated`, `thread_follow_changed`, `thread_read_changed`, `post_edited`, `post_deleted`, `reaction_added/removed` |
| S14 | Composer | `posts: POST /posts` (send), `PUT /posts/{post_id}/patch` (edit), `DELETE /posts/{post_id}` (delete), `POST /posts/{post_id}/set_unread`; `files: POST /files` (upload, multipart) + `GET /files/{file_id}/link|info`; `commands: POST /commands/execute`, `GET /teams/{team_id}/commands/autocomplete_suggestions?{params}`; `ephemeral_mode` hooks for burn-on-read (`POST {server}/ephemeral_mode/*`) if enabled | `posted` (echo/self-post), `post_edited`, `post_deleted`, `ephemeral_message` (command output), `typing` (outbound only) |
| S15 | Autocomplete | `users: GET /users/autocomplete?{params}` (name), `channels: GET /teams/{team_id}/channels/autocomplete?{params}`, `emojis: GET /emoji/autocomplete?{params}`, `emojis: GET /emoji/name/{emoji_name}`, `integrations: GET /teams/{team_id}/commands/autocomplete?{params}`, `users: POST /users/usernames` (bulk @-match), `channels: POST /users/{user_id}/teams/{team_id}/channels/members` (DM candidates via `users: POST /users/ids`) | `emoji_added` (custom emoji cache refresh) |
| S16 | Reactions | `posts: POST /reactions`, `posts: DELETE /users/{user_id}/posts/{post_id}/reactions/{emoji_name}`, `GET /posts/{post_id}/reactions` | `reaction_added`, `reaction_removed` |
| S17 | Emoji picker + custom | `emojis: GET /emoji?{params}`, `GET /emoji/{emoji_id}`, `GET /emoji/{emoji_id}/image`, `GET /emoji/name/{emoji_name}`, `POST /emoji/search`; custom emoji create/upload rides `emojis: POST /emoji` + `GET /emoji/{id}/image`; `preferences: PUT /users/{user_id}/preferences` (recent emoji) | `emoji_added` |
| S18 | Files/gallery | `files: GET /files/{file_id}/link`, `GET /files/{file_id}/info`; `posts: GET /posts/{post_id}/files/info`; public links via `{server}/api/v4/files/…` with session; downloads by signed URL (post metadata `file_ids` + `/files/{id}` binary) | `file_download_rejected`, `show_toast` (file access control) |
| S19 | Search | `posts: GET /teams/{team_id}/posts/search?{params}` (or `/posts/search`), `files: GET /teams/{team_id}/files/search?{params}`, `users: POST /users/search`, `channels: POST /teams/{team_id}/channels/search`; flagged: `posts: GET /users/{user_id}/posts/flagged?{params}` | `posted`, `post_edited`, `post_deleted` (result invalidation) |
| S20 | Saved messages | `posts: GET /users/{user_id}/posts/flagged?{params}`; `preferences: POST /users/{user_id}/preferences/delete` + `PUT /users/{user_id}/preferences` (flag set/clear `grouped_saved_post_<id>`) | `preference_changed`, `preferences_changed`, `preferences_deleted`, `post_deleted` (stale flag) |
| S21 | Pinned messages | `posts: GET /channels/{channel_id}/pinned`; `posts: POST /posts/{post_id}/pin` / `unpin` | `post_edited` (pinned flag), `channel_updated` |
| S22 | Channel info | `channels: GET /channels/{channel_id}`, `GET /channels/{channel_id}/stats`, `GET /channels/{channel_id}/member_counts_by_group?include_timezones=…`, `GET /channels/{channel_id}/timezones`, `GET /channels/{channel_id}/common_teams`; `users: GET /users/{user_id}/teams/{team_id}/channels/order`; bookmarks: `channel_bookmark: GET/POST/PUT/DELETE /channels/{channel_id}/bookmarks…` | `channel_updated`, `channel_member_updated`, `memberrole_updated`, `channel_bookmark_created/updated/sorted/deleted`, `user_added/removed` |
| S23 | Members | `channels: GET /channels/{channel_id}/members?{params}` (`page,per_page`), `POST /channels/{channel_id}/members`, `POST /channels/{channel_id}/members/ids`, `DELETE /channels/{channel_id}/members/{user_id}`, `PUT /channels/{channel_id}/members/{user_id}/scheme_roles`(in TSV: `…/schemeRoles`); `teams: POST /teams/{team_id}/members/batch?graceful=true`, `POST /teams/{team_id}/invite/email?graceful=true`, `POST /teams/{team_id}/invite-guests/email?{params}`; `users: POST /users/ids?{params}`, `POST /users/search` | `user_added`, `user_removed`, `memberrole_updated`, `channel_member_updated`, `group_member_add/delete` (group sync) |
| S24 | Profile/status/custom status | `users: GET /users/{user_id}`, `GET /users/{user_id}/status`, `POST /users/status/ids`, `PUT /users/{user_id}/status` (online/away/dnd/offline), `PUT /users/me/status/custom`, `DELETE /users/me/status/custom`, `POST /users/me/status/custom/recent/delete`; custom profile: `custom_profile_attributes: GET /custom_profile_attributes/fields`, `GET /users/{user_id}/custom_profile_attributes` | `status_change`, `user_updated`, `user_role_updated`, `custom_profile_attributes_*` |
| S25 | Mentions inbox | No dedicated endpoint — unread/mention state derives from `posted`/`post_unread` WS events + local store (mobile ref: mentions tab reads the local DB); settings `preferences` control mention keys (`notify_props`); in-app notification is local. | `posted` (mention filter), `post_unread`, `channel_viewed`, `preference_changed`, `status_change` |
| S26 | Drafts + scheduled | Drafts are **local-only** (mobile ref: SQLite `draft` table); scheduled posts: `scheduled_post: GET /posts/scheduled/team/{team_id}?{params}`, `POST /posts/schedule`, `DELETE /posts/schedule/{schedule_id}`; channel list shows scheduled posts via `GET /posts/scheduled/team/{team_id}` | `scheduled_post_created/updated/deleted` |
| S27 | Settings | `preferences: GET/PUT /users/{user_id}/preferences`, `POST /users/{user_id}/preferences/delete`; `users: PUT /users/{user_id}/patch` (profile), `PUT /users/sessions/device` (push token binding, T43); `general: GET /data_retention/policy`, `GET {server}/api/v4/config/client?format=old` (feature flags); theme: preferences `theme` | `preference_changed`, `preferences_changed`, `preferences_deleted`, `user_updated`, `config_changed`, `license_changed`, `custom_profile_attributes_*` |
| S28 | Edit profile | `users: PUT /users/{user_id}`, `PUT /users/{user_id}/patch`, `POST /users/{user_id}/image`, `DELETE /users/{user_id}/image` | `user_updated` |
| S29 | System Console | None (webview-only). | `config_changed`, `license_changed`, `role_updated` (admin-side events even if console itself is webview) |
| S30 | Plugin screens | `plugins: GET /plugins/webapp` (enabled-plugin registry, live-observed); each plugin's own `{server}/plugins/<id>/api/v1/*` endpoints (live-observed e.g. google-meet config/status, todo lists, gitlab/github connected, mattermost-ai ai_bots); Apps framework: `apps: GET/POST {server}/plugins/com.mattermost.apps/api/v1/bindings|call` | any `custom_*` (prefix tolerated); `plugin_enabled`, `plugin_disabled`, `plugin_statuses_changed`, `custom_com.mattermost.apps_refresh_bindings` |
| S31 | Boards | Webview-only; plugin REST behind the webview. | `custom_` boards events (tolerate, don't model) |
| S32 | Playbooks | Webview-only; plugin REST behind the webview. | `custom_` playbooks events (tolerate) |
| S33 | Calls | Webview-only; Calls plugin REST behind the webview (room, channels enable/disable). | `custom_<calls-plugin>_*` (added/updated when webview present; native never models them) |
| S34 | Apps framework | `apps: GET /plugins/com.mattermost.apps/api/v1/bindings?{params}`, `POST /plugins/com.mattermost.apps/api/v1/call`; dialogs: `integrations: POST {server}/actions/dialogs/submit`, `POST {server}/actions/dialogs/lookup` | `custom_com.mattermost.apps_refresh_bindings`, `open_dialog` |
| S35 | Notifications | Local: derive from `posted` with mention; remote: APNs via Mattermost Push Proxy (T12 simulacrum; real proxy + APNs blocked on this host); `users: PUT /users/sessions/device` registers token against the session. | `posted` (mention filter), `post_unread`, `status_change` (suppression), `_` prefix tolerated |
| S36 | Deep links/share | `general: GET /redirect_location?{params}`; `channels: GET /teams/name/{team_name}/channels/name/{channel_name}`; route resolution local (already native in `Core/DeepLinkRouter.swift`). | `posted` (warm-up cache) |
| S37 | Onboarding/join team | `teams: POST /teams/members` (join via invite link), `teams: GET /teams/{team_id}`; invites: `channels: POST /channels/{channel_id}/members/ids`, `teams: POST /teams/{team_id}/members/ids` | `added_to_team`, `user_added` |
| S38 | Post options | All of S11's post endpoints plus: `posts: DELETE /posts/{post_id}/burn` (burn-on-read), `POST /posts/{post_id}/ack` (acknowledgements), `POST /users/{user_id}/posts/{post_id}/ack`; translate: `posts: GET/POST` translation (server-side `translations` feature, WS `post_translation_updated`); apps: `apps: call` | `post_acknowledgement_added/removed`, `post_translation_updated`, `post_revealed`, `post_burned`, `burn_on_read_all_revealed` |
| S39 | Custom profile attrs | `custom_profile_attributes: GET /custom_profile_attributes/fields`, `GET /users/{user_id}/custom_profile_attributes`, `PATCH /custom_profile_attributes/values` | `custom_profile_attributes_values_updated`, `custom_profile_attributes_field_created/updated/deleted` |
| S40 | Scheduled posts | `scheduled_post: GET /posts/scheduled/team/{team_id}?{params}`, `PUT /posts/schedule/{schedule_id}`, `DELETE /posts/schedule/{schedule_id}` | `scheduled_post_created/updated/deleted` |

Pagination/cursor conventions to implement once in T28 and reuse everywhere: list endpoints take
`page`/`per_page` (server default `per_page=60`, max `200`), timestamp cursors `since` /
`last_delete_at` for incremental sync (mobile ref: channel list + categories are fetched with
`last_delete_at`; posts with `before/after` or `since`), and `include_deleted` /
`exclude_default_channels` / `include_total_count` flags where present. WebSocket v4: connect to
`{server}/api/v4/websocket` with the auth token, expect `hello` first, `ping`/`pong` keepalive,
and a monotonically increasing `seq` for missed-event recovery (reliable-websocket support gated
by server version/probe — ADR §5).

---

## 3. Difficulty + risk per surface and recommended build order

Legend: S/M/L = effort for a solo Swift engineer implementing the native surface against
REST/WS v4 (S ~0.5–2d, M ~2–5d, L ~1–3w); risk = technical/feature risk (data reconciliation,
rendering, realtime, platform-sensitive).

| # | Surface | Diff | Risk | Rationale |
|---|---|---|---|---|
| S05 | Server add/edit/select | S | low | Already native in this repo (T5); extend with categories/preferences fetch. |
| S01–S04 | Login/MFA/SSO/signup | M | medium | Session + CSRF headers (T28), MFA challenge, SSO redirect-loop handling; token in Keychain (already `SecureVault`). |
| S07 | Team selection | S | low | `GET /users/{id}/teams` + join; small. |
| S08 | Channel sidebar | M | medium | Category CRUD/order, unread/mention badge math, mute, DM/GM, incremental sync (`last_delete_at`); WS reconciliation is the hard part. |
| S09–S10 | Find/create channels | M | low | Search autocomplete endpoints + create/edit forms; straightforward CRUD. |
| S11 | Channel view | **L** | **high** | Markdown/GFM renderer, attachments, pagination, threaded teasers, system messages, unread jumps; WS insert/update/delete ordering; biggest single surface (ADR T34). |
| S12 | Permalink | S | low | Resolve ids, deep-link routing already native. |
| S13 | Threads | M–L | medium | Follow/read state, list pagination, RHS push; WS `thread_*` reconciliation. |
| S14 | Composer | **L** | **high** | Markdown input, uploads (multipart), commands, drafts persistence, edit/mark-format; keyboard handling. |
| S15 | Autocomplete | M | medium | Multi-source async fetch race, custom emoji cache, slash command registry. |
| S16–S17 | Reactions/emoji | M | low | WS add/remove, picker grid + custom emoji; server allows arbitrary emoji names — validate. |
| S18 | Files/gallery | M | medium | Signed URLs/session downloads, image caching, PDF/code/latex renderers; download reuse `DownloadWorker` (T7). |
| S19–S21 | Search/saved/pinned | M | medium | Search query DSL mapping, flagged preference writes, pinned per channel; result navigation. |
| S22–S23 | Channel info/members | M | medium | Member paging + management, stats, bookmark CRUD, invite flows. |
| S24 | Profile/status | S | low | Status PUT/DELETE, custom status timer, presence via WS; tiny — build early (ADR T41). |
| S25 | Mentions inbox | M | medium | Local aggregation of WS `posted`/`post_unread`; correctness = mention filter parity. |
| S26/S40 | Drafts/scheduled | M | low | Local SQLite (T29) + scheduled post REST; recurrence pickers. |
| S27–S28 | Settings/profile edit | M | low | Many sub-screens; preferences CRUD; settings already native here (T11). |
| S35 | Notifications | M | high | Local mention notifications work (T8); remote push blocked on host (APNs/proxy); badge accuracy. |
| S36 | Deep links | S | low | Already native (T4). |
| S37 | Onboarding/join | S | low | Already native (T10); add invite/join-team. |
| S38 | Post options | M | low | Menu composition + per-action endpoints; reuses S11/S16. |
| S39 | Custom profile attrs | S | low | Feature-gated by server; direct CRUD. |
| S29–S33 | Console/plugins/Boards/Playbooks/Calls | n/a | n/a | Webview-only by decision (ADR §2.3) — no native estimate. |

**Recommended build order (supersedes ADR §2.2 ordering only where evidence refines it):**

0. T28 transport (auth session, REST client with CSRF+bearer, WS client with seq/reconnect) — prerequisite for everything native.
1. S05 + S01–S04 (auth & server) — front-loaded by flow, small; gives a usable entry.
2. S07 + S08 sidebar — daily navigation (ADR group 1).
3. S11 channel view — daily reading (ADR group 2, **L/high risk — start early**).
4. S14 composer (+ S15 autocomplete) — daily sending (ADR group 3).
5. S13 threads — heavy daily read (ADR group 4).
6. S16/S17 reactions+emoji, S24 profile/status, S12 permalink — cheap wins (ADR groups 5, 9).
7. S18 files/gallery, S19–S21 search/saved/pinned (ADR groups 6–7).
8. S22–S23 channel info/members, S25 mentions, S26/S40 drafts/scheduled, S27–S28 settings (ADR groups 8, 10, 12).
9. S35 notifications/push (ADR group 11) — hardware-gated.
10. S29–S33 stay webview-only forever; S34 Apps framework rides whichever surface hosts it.

---

## 4. Fallback decision per surface

Per ADR §6.6 every row carries a fallback: `native` (target), `webview` (T46 escape hatch,
default until native ships), or `dropped` (never native). "webview (until native)" means the row
renders in the T26 dual-render switch until its T-number lands.

| # | Surface | Decision | Notes |
|---|---|---|---|
| S01–S04 | Login/MFA/SSO/signup | **native** (T31); webview until T31 | SSO redirect itself can hand off to a webview/T46 if the IdP flow proves fragile, but the challenge screens stay native. |
| S05 | Server add/edit/select | **native** (already) | Never regresses to webview (ADR §6.5). |
| S06 | TOS gate | **native** (T31) | Tiny — fold into auth surface. |
| S07 | Team selection | **native** (T32) | |
| S08 | Sidebar | **native** (T32/T33) | |
| S09–S10 | Find/create channels | **native** (T33) | |
| S11 | Channel view | **native** (T34) | If markdown parity is not met by release, T34 ships with T46 fallback for exotic rendering (latex/table) as an interim. |
| S12–S13 | Permalink/threads | **native** (T36) | |
| S14–S15 | Composer/autocomplete | **native** (T35) | |
| S16–S17 | Reactions/emoji | **native** (T37) | |
| S18 | Files/gallery | **native** (T38) | PDF/code/latex renderers may stay webview (T46) if native renderer is not acceptable. |
| S19–S21 | Search/saved/pinned | **native** (T39) | |
| S22–S23 | Channel info/members | **native** (T40) | |
| S24 | Profile/status | **native** (T41) | |
| S25 | Mentions inbox | **native** (T42) | |
| S26/S40 | Drafts/scheduled | **native** (T35/T36) | |
| S27–S28 | Settings/profile edit | **native** (already + T41) | ADR §6.5. |
| S29 | System Console | **webview (T46) always** | ADR §2.3. |
| S30 | Plugin screens | **webview (T46) always** | Unknown plugin UIs can't be native; ADR §2.3. |
| S31 | Boards | **webview (T46) always** | ADR §2.3. |
| S32 | Playbooks | **webview (T46) always** | ADR §2.3. |
| S33 | Calls | **webview (T46) always, may cut for v1** | ADR §2.3, T44/T16. |
| S34 | Apps framework | **hybrid**: native dialogs/selectors where feasible, webview fallback | Follows host surface's decision; Apps `call` opens wherever. |
| S35 | Notifications | **native** (T43) | Local paths native; remote push needs proxy+APNs (blocked@host). |
| S36 | Deep links | **native** (already) | |
| S37 | Onboarding/join | **native** (already + T31) | |
| S38 | Post options | **native** (T34/T37) | |
| S39 | Custom profile attrs | **native** (T41), feature-gated by server (ADR §5) | |

---

## 5. Fixtures plan — stub vs live

The repo already has: `build/uitest-server/mm_stub.py` (serves `/api/v4/system/ping`,
`/api/v4/config/client?format=old`, a fake login HTML, a downloadable file; HTTP :8111 and
self-signed TLS :8443) and the opt-in live gate `TEST_RUNNER_MM_LIVE_URL` /
`TEST_RUNNER_MM_LIVE_TOKEN` (see `MattermostTests/MentionPollerTests.swift` §MARK live fetch)
plus `TEST_RUNNER_MM_LIVE_SSO_URL` (`MattermostUITests/MattermostUITests.swift`).

| # | Surface | Fixture strategy |
|---|---|---|
| S01–S04 | Login/MFA/SSO/signup | **Stub**: extend `mm_stub.py` with `POST /users/login` (token + CSRF), `POST /users/mfa` (fixed TOTP), a fake SSO redirect loop-back, `POST /users` signup, `POST /users/password/reset/send`. **Live**: `TEST_RUNNER_MM_LIVE_URL` + `TEST_RUNNER_MM_LIVE_TOKEN` for the real session handshake; `TEST_RUNNER_MM_LIVE_SSO_URL` for the SSO round-trip (needs a real IdP — blocked@host). |
| S05 | Server add/edit | Stub only (already covered by UI tests). |
| S06 | TOS gate | Stub: `GET /terms_of_service` fixture + config flag. |
| S07–S08 | Team/sidebar | Stub: seed teams/categories/channels via fixtures; WS event injection for unread/mute/category events. **Live**: `TEST_RUNNER_MM_LIVE_URL` with a team — real category/order endpoints. |
| S09–S10 | Find/create channels | Stub: autocomplete/search fixtures + channel CRUD. |
| S11–S13 | Channel view/threads | **Mostly live-server** (markdown/pagination/attachment realism needs a real server): `TEST_RUNNER_MM_LIVE_URL`; stub covers empty-channel + seeded posts for XCUITest determinism. |
| S14–S15 | Composer/autocomplete | Stub: post create/patch fixtures, autocomplete fixtures (users/emoji/commands). Live for real markdown round-trip. |
| S16–S17 | Reactions/emoji | Stub: reaction add/remove + emoji fixtures (incl. custom). |
| S18 | Files/gallery | Stub: `POST /files` + `GET /files/{id}/info` binary fixtures (existing `hello.txt` pattern). Live for signed-URL behaviour. |
| S19–S21 | Search/saved/pinned | Stub: search endpoints + preferences flag fixtures. Live for DSL semantics (`in:`/`from:`/paging). |
| S22–S24 | Channel info/members/profile | Stub: members/stats/status fixtures. Live for real member paging + status presence. |
| S25 | Mentions inbox | Stub: WS `posted` mention events; live for mention-filter parity. |
| S26/S40 | Drafts/scheduled | Stub: `POST /posts/schedule` etc.; drafts local-only (SQLite fixture). |
| S27–S28 | Settings/profile | Stub: preferences CRUD (already native UI tests). |
| S29–S33 | Console/plugins/Boards/Playbooks/Calls | **Live-only, webview**: `TEST_RUNNER_MM_LIVE_URL` must be a server with those plugins installed; stub cannot fake plugin UIs. Blocks: a real account with admin (console) + plugin access. |
| S34 | Apps framework | Stub: bindings/call fixtures for command + dialog flows. |
| S35 | Notifications | Stub: local mention → `UNNotificationRequest` (unit tests exist, T8). Remote push **cannot be fixture'd on this host** (needs APNs `.p8` + Push Proxy + DiagnosticId — T12 runbook). |
| S36–S39 | Deep links/onboarding/options/attrs | Stub: deep-link unit tests exist (T4); options/attrs fixtures. |

Rule of thumb baked into the cards: **deterministic surfaces get stub fixtures; any surface whose
correctness depends on real server behaviour (markdown, search DSL, realtime reconcile, SSO,
plugins) gets a live gated test** and is skipped (`XCTSkipUnless`) without the gate, never
fake-passed.

---

## 6. T25-AV reconciliation — every card-body surface present

Checklist for the adversarial validator: every surface named in the card body must appear above
(explicit mapping to rows).

| Card body item | Row(s) |
|---|---|
| login | S01 |
| MFA | S02 |
| SSO | S03 |
| team selection | S07 |
| channel sidebar public/private | S08 |
| channel sidebar DM/GM | S08 |
| categories | S08 |
| unread | S08 |
| mute | S08 |
| channel view | S11 |
| thread RHS | S13 |
| composer | S14 |
| autocomplete | S15 |
| reactions | S16 |
| emoji picker | S17 |
| custom emoji | S17 |
| file/image viewer | S18 |
| search | S19 |
| saved | S20 |
| pinned | S21 |
| channel info | S22 |
| membership | S22/S23 |
| members/member list | S23 |
| profile popover | S24 |
| status | S24 |
| custom status | S24 |
| activity/mentions inbox | S25 |
| drafts | S26 |
| user settings | S27 |
| admin/System Console | S29 |
| plugin screens | S30 |
| Boards | S31 |
| Playbooks | S32 |
| Calls | S33 |
| (bonus) sign-up/forgot password | S04 |
| (bonus) server add/edit/select | S05 |
| (bonus) TOS gate | S06 |
| (bonus) deep links | S36 |
| (bonus) onboarding | S37 |
| (bonus) Apps framework | S34 |
| (bonus) scheduled posts | S26/S40 |
| (bonus) custom profile attributes | S39 |

---

## 7. Licensing boundary — update to ADR §3 (verified 2026-10-24)

- `mattermost/mattermost-mobile` — **Apache-2.0** (LICENSE.txt "Apache License v2.0"). Safe
  reference for screens/APIs; patterns reimplementable in Swift. Evidence paths used throughout
  §1–§2.
- `mattermost/mattermost` monorepo — `LICENSE.txt` line 15 licenses **`webapp/` and all
  subdirectories (incl. `webapp/channels/src/components/`) under Apache-2.0**. **Update for the
  ADR:** the current webapp tree is Apache-2.0, not AGPL. Rows citing the webapp component tree
  (cross-check only) are safe with attribution.
- `mattermost/mattermost-webapp` (legacy repo named in the ADR) — **AGPL-3.0, observe only,
  never copy**. Do not cite file paths from it; this inventory does not.
- Server API (`https://api.mattermost.com`) — public contract; reimplementation target.

Reviewer check (mirrors T25-AV): every row's evidence string is a `docs/inventory/…` extract, an
`api.mattermost.com`-style path, or a `refs/mattermost-mobile/…` path — no AGPL file paths, no
verbatim webapp code.

---

## Appendix A — WebSocket v4 dictionary

`docs/inventory/websocket-events.md` (113 events). Connection: `{server}/api/v4/websocket`
(`refs/mattermost-mobile/app/client/websocket/index.ts`). Event shape: `{"event": <name>,
"data": {...}, "seq": n, "broadcast": {"channel_id", "team_id", "user_id"}, "received_at": ms}`
(public contract).

## Appendix B — REST endpoint dictionary

`docs/inventory/rest-endpoints.tsv` (147 rows; module — verb — path). Extraction script
(`inventory/extract_rest.py`) and raw call-site list in the T25 workspace, not committed with
the live hostname.

## Appendix C — Live observations (host redacted)

- Login page boot calls: `GET /api/v4/config/client?format=old`, `GET /api/v4/license/client`,
  `GET /api/v4/plugins/webapp`, `GET /brand/image?t=0`, `GET /cloud/check-cws-connection`,
  `GET /properties/groups/access_control/system/fields?target_type=system` (REA capture of the
  login screen, 288 events retained).
- Sign-up page: same boot calls + `POST`-shaped fixtures absent (no account created).
- Password reset page: same boot calls.
- Plugin list observed on one login page load: msteams-sync, calls, metrics, badges, gcal,
  jira, dataminr, connect4, ms-embedded + todo/github/gitlab/google-meet/ai reminders — evidence
  plugin surfaces are numerous and server-specific (webview-only disposition).
- Server banner: v12.1.0 enterprise, FIPS password policy (14-char minimum) surfaced in the
  login/signup copy — feature gating must tolerate older servers (ADR §5).
- REA ran headless Playwright/Chrome 156 against the live server, launched from local macOS
  26.3.1, node 24.22.1; `rea-agents@6.7.0` installed under the T25 scratch workspace only.
