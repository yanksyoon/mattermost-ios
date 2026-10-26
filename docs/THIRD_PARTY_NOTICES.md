# THIRD PARTY NOTICES — component sources and licences

- **Status:** part of T25b (official-repo component map). Every file ported into this repo from a
  third-party source must have a row here (or in `docs/component-map.md` §6) and a per-file header
  per §3 of `docs/component-map.md`.
- **Licence verification:** all rows below were verified on **2026-10-24** via
  `gh api repos/<org>/<repo>/license` (GitHub licence detector) **and/or** by reading the
  `LICENSE.txt`/`LICENSE.md`/`package.json` at the pinned tag. "Verified" means the detector and/or
  file text was actually fetched this day, not remembered.

## 1. Pinned source trees (SHAs recorded)

| Repo | Pinned ref | Commit SHA | Why pinned |
|---|---|---|---|
| `mattermost/mattermost-mobile` | `v2.45.0` (released 2026-10-15) | `162f2560d0e1df073220f7701d5a67cc17c8abeb` | Primary client reference for `app/screens/`, `app/components/`, `app/client/`, and the Gekidou iOS layer. |
| `mattermost/mattermost` | `v12.0.1` (released 2026-10-22) | `987e57120dca630dadbcd2638064ab66a02bb81e` | Live web app UI at `webapp/channels/src/components/` (cross-check + markdown/behavioural semantics). |
| `mattermost/mattermost-webapp` | `master` (legacy standalone repo; API badge verified 2026-10-24) | SHA not pinned — not used for porting, legacy reference only | Kept only because the ADR previously cited it; see `docs/path-b-adr.md` §3 correction. |
| `mattermost/mattermost-push-proxy` | `main` | not pinned (no ported files yet) | Reference for the push-proxy simulacrum behaviour (T12). |

## 2. Licence table (verified 2026-10-24)

| Component | Repo / package | Licence | Verification | Used at v2.45.0 mobile pin? |
|---|---|---|---|---|
| Mobile client (screens, components, REST/WS clients, Gekidou) | `mattermost/mattermost-mobile` | Apache-2.0 | `gh api .../license` → Apache-2.0; `LICENSE.txt` head = Apache License 2.0 (fetched) | — (primary source) |
| Web app UI | `mattermost/mattermost` monorepo `webapp/` (incl. `webapp/channels/src/`) | Apache-2.0 | Root `LICENSE.txt` line 15: "Admin Tools and Configuration Files (… server/templates/, server/i18n/, server/public/, webapp/ and all subdirectories thereof) under the Apache License v2.0" (fetched at pin) | — (cross-check only) |
| Legacy webapp | `mattermost/mattermost-webapp` | Apache-2.0 (NOT AGPL as previously claimed) | `gh api .../license` → Apache-2.0; `LICENSE.txt` head fetched: Apache License 2.0 (202 lines) | no |
| Server (Go) | `mattermost/mattermost` `server/`, `enterprise/` | AGPL-3.0 / commercial | Root `LICENSE.txt` policy body; **never ported** | no — out of scope |
| Markdown parser (mobile) | `@mattermost/commonmark@0.31.2-0` (fork of `commonmark.js` at `github.com/mattermost/commonmark.js`) | BSD-2-Clause | npm registry `license` field fetched | yes (drives `app/components/markdown/transform.ts`) |
| Markdown → React renderer (mobile) | `mattermost/commonmark-react-renderer` @ `81b5d27509652bae50b4b510ede777dd3bd923cf` | MIT | `gh api .../license` → MIT | yes |
| Virtualized list (mobile) | `@shopify/flash-list@2.3.1` | MIT | npm registry `license` field fetched | yes (replaces legacy `dynamic-virtualized-list`) |
| Legacy virtualized list | `mattermost/dynamic-virtualized-list` | MIT | `gh api .../license` → MIT | **no** — not a dependency at the v2.45.0 pin; listed for completeness |
| Markdown parser (webapp) | `mattermost/marked` fork @ `c211e4ca4a8182f82cc16738d9fbcd7d026ce011` | MIT | `gh api .../license` → MIT | no (webapp-only) |
| Icon set | `@mattermost/compass-icons@0.1.53` (repo `mattermost/compass-icons`) | MIT | `package.json` `"license": "MIT"` (repo has no LICENSE file; npm field is the licence statement) | yes (icons/fonts; prefer SF Symbols in SwiftUI, compass only where no symbol exists) |
| Networking client | `@mattermost/react-native-network-client@1.11.4` (repo `mattermost/react-native-network-client`) | Apache-2.0 | `gh api .../license` → Apache-2.0 | yes (its URLSession design informs T28; our transport is our own `URLSession` code) |
| Bottom sheets | `@gorhom/bottom-sheet@5.2.13` (dep of mobile pin) | MIT | npm registry | behaviour reference only (SwiftUI `.sheet`/`presentationDetents` replaces it) |
| Push proxy (reference) | `mattermost/mattermost-push-proxy` | Apache-2.0 | `gh api .../license` → Apache-2.0 | reference only (T12 simulacrum) |

> **Correction recorded (2026-10-24):** the card body listed `marked (MIT)` and
> `dynamic-virtualized-list (MIT)` as the supporting libs for the mobile client. Verified truth at
> the pinned mobile tag: the markdown parser is `@mattermost/commonmark` (BSD-2-Clause) rendered by
> `commonmark-react-renderer` (MIT), and the virtualized list is `@shopify/flash-list` (MIT).
> `marked` is used by the **webapp**, and `dynamic-virtualized-list` is not a dependency at the
> pin. The Swift layer must port the commonmark->AST transform semantics, not `marked`'s.

## 3. Attribution text every ported file must carry

Every source file ported (or translated) from any repo above starts with a header like:

```
// Ported from mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// File: app/components/markdown/transform.ts
// Licence: Apache-2.0 (upstream LICENSE.txt) — ported with attribution per docs/THIRD_PARTY_NOTICES.md
```

Rules:

1. The header names the upstream file **path**, the **repo**, the **pinned tag**, and the
   **short SHA** (`docs/component-map.md` §3).
2. The licence named is the one in the table above for that repo/package.
3. Files that are *inspired by* rather than *ported from* a source (behaviour parity, own
   `Codable` shapes) carry a lighter note: `// Behaviour reference: <repo> @ <tag>, <path> — own
   implementation per docs/path-b-adr.md §3`.
4. Bundle-level notices: when the app ships an icon font / resource derived from
   `@mattermost/compass-icons`, add a `NOTICE` entry naming that package + MIT and a copy of the
   MIT text in the app bundle's Licence/Notices screen.
5. Nothing from AGPL/commercial server trees (`server/`, `enterprise/`) may be ported, and no AGPL
   licence text is copied into this repo.

## 4. Server-side note

This repo contains **no Mattermost server code and no AGPL licence text**. The only Mattermost
content are Apache-2.0 client/webapp references cited above, and every ported file carries the
header from §3. The server is accessed exclusively through the public REST v4 + WebSocket v4 API.

## 5. T28 native transport — upstream read set (Apache-2.0, mobile @ `v2.45.0`)

T28 (`Mattermost/Core/MM/`, `docs/t28-build-note.md`) ports **behaviour and structure**, not files:
no upstream `.swift`/`.ts` file is vendored verbatim. Each new source file carries a header naming
the upstream file it derives from; the full read set was:

| Upstream path (`mattermost/mattermost-mobile` @ `162f2560…`) | Used for |
|---|---|
| `ios/Gekidou/Sources/Gekidou/Networking/Network.swift` | `/api/v4` prefixing, bearer + `X-Requested-With` headers, response handling |
| `ios/Gekidou/Sources/Gekidou/Networking/Network+{Posts,Channel,Team,Thread,Users,Category}.swift` | endpoint paths and pagination query shapes |
| `ios/Gekidou/Sources/Gekidou/Networking/Network+Error.swift`, `Network+Delegate.swift` | error typing; TLS challenge hook (replaced by this repo's `CertTrust` model) |
| `ios/Gekidou/Sources/Gekidou/DataTypes/{Post,PostResponse,User}.swift` | tolerant `Codable` shapes |
| `ios/Gekidou/Sources/Gekidou/SessionAttributes/SessionAttributesOutboundHeader.swift` | read only — not sent yet (documented in the build note §3) |
| `app/client/websocket/index.ts` | `authentication_challenge`, hello, 30 s ping/missed-pong, sequence handling, reconnect |
| `app/client/rest/error.ts` | typed error vocabulary |
| `@mattermost/react-native-network-client@1.11.4` (Apache-2.0) | URLSession/WebSocket architecture reference |

Divergences from each of these are listed in `docs/t28-build-note.md` §5.

## 6. T29 native local store — upstream read set and the database library

T29 (`Mattermost/Core/Store/`, `docs/t29-build-note.md`) ports **schema shapes and query
structure**, not files. The storage layer of the mobile client is Apache-2.0 Swift, and was read
at the pin:

| Upstream path (`mattermost/mattermost-mobile` @ `162f2560…`) | Used for |
|---|---|
| `ios/Gekidou/Sources/Gekidou/Storage/Database.swift` | busy timeout (5 s), WAL expectations, one writer |
| `ios/Gekidou/Sources/Gekidou/Storage/Database+Posts.swift` | channel page window, thread window, soft-delete handling |
| `ios/Gekidou/Sources/Gekidou/Storage/Database+Channels.swift` | membership upsert, unread/mention state, `hasMyChannelUrgentMentionCountColumn(_:)` (the late-column evidence behind schema v2) |
| `ios/Gekidou/Sources/Gekidou/Storage/Database+Users.swift`, `Database+Team.swift` | user/team row shapes |
| `ios/Gekidou/Sources/Gekidou/Storage/Database+Preferences.swift` | `(user, category, name) → value` preference table |
| `ios/Gekidou/Sources/Gekidou/Storage/Database+Mentions.swift`, `Database+Thread.swift` | thread reply ordering; the mention/unread queries the sidebar needs |
| `app/database/schema/server/table_schemas/*.ts` | which columns exist per table at the pin |

**Database library added this card:** [`GRDB.swift`](https://github.com/groue/GRDB.swift) (MIT),
`7.11.1` resolved by SwiftPM, declared in `Mattermost.xcodeproj/project.pbxproj` as
`upToNextMajorVersion` from `7.0.0`. Licence verified on 2026-10-24 with
`gh api repos/groue/GRDB.swift/license --jq '.license.spdx_id'` → `MIT`.
No GRDB source is vendored into this repo; it is a package dependency, so the MIT text ships with
the binary in the normal SwiftPM way (recorded here because the app's Licences screen lists it).

## 7. T30 native app shell — upstream read set (Apache-2.0, mobile @ `v2.45.0`)

T30 (`Mattermost/Core/Native/NativeNavigation.swift`, `Mattermost/UI/Native/`,
`docs/t30-build-note.md`) reimplements **navigation structure and deep-link rules** in SwiftUI. No
upstream file is copied: the RN sources are TypeScript and cannot be transpiled into this repo, and
none of their code, strings or styles are reproduced verbatim. They were read at the pin to fix the
shape of the model:

| Upstream path (`mattermost/mattermost-mobile` @ `162f2560d0e1df073220f7701d5a67cc17c8abeb`) | Used for |
|---|---|
| `app/screens/home/channel_list/channel_list.tsx` | the two compositions the shell mirrors: phone = servers rail + team sidebar + channel list; tablet adds the additional view |
| `app/screens/home/channel_list/additional_tablet_view/additional_tablet_view.tsx` | regular-width layout: sidebar beside the channel view, no push |
| `app/screens/home/tab_bar/index.tsx`, `tab_bar.tsx` | which top-level destinations exist, and in what order |
| `app/screens/home/channel_list/servers/` | the servers rail / switcher entry point |
| `app/screens/home/channel_list/categories_list/` | the sidebar list shape (sections, unread affordances) that the channel-list placeholder is shaped after |
| `app/utils/deep_link/index.ts` | `CHANNEL_PATH` = `*serverUrl/:teamName/:path/:identifier`, permalink (`/pl/`) and threads (`/…/threads`) route rules, and what an unparsable link should do |
| `app/constants/deep_linking.ts`, `app/utils/url/path.ts`, `app/utils/url/index.ts` | path/identity helpers behind those rules |
| `app/init/deep_link.ts`, `app/navigation` | when a link is acted on relative to app ready (the queue-until-ready rule `DeepLinkRouter` already had) |

Reimplementation notes that matter for the licence boundary: the Swift model (`NativeLocation`,
`NativeNavigation`) is written from the REST/URL contract, not translated from the RN navigation
state objects; no `compass-icons` glyphs are embedded (SF Symbols are used instead), so no icon
font or NOTICE entry is added by this card.

## 8. T31 native auth & session surface — upstream read set (Apache-2.0, mobile @ `v2.45.0`)

T31 (`Mattermost/UI/Native/Auth/`, `docs/t31-build-note.md`) reimplements the **sign-in, MFA and
session-expiry screens** and the *shape* of the login/logout orchestration in SwiftUI. No upstream
file is copied: the RN sources are TypeScript and cannot be transpiled into this repo, and none of
their code, strings or styles are reproduced verbatim. They were read at the pin to fix the form
rules the acceptance criteria name:

| Upstream path (`mattermost/mattermost-mobile` @ `162f2560d0e1df073220f7701d5a67cc17c8abeb`) | Used for |
|---|---|
| `app/screens/login/form.tsx` | field set (email/username, password), the "submit disabled until both fields have input" rule, the `login_id.toLowerCase()` normalisation before `POST /users/login`, and where the server's rejection sentence is shown |
| `app/screens/login/index.tsx` | screen composition: server name as the heading, the form, the SSO alternative below it |
| `app/screens/login/sso_options.tsx` | SSO as a **second route to the same session** rather than a separate surface |
| `app/screens/mfa/index.tsx`, `mfa/shield.tsx` | the token step: shield glyph, "Enter MFA Token" heading, the explanation, the single numeric field, `Proceed`, and "use a different account" |
| `app/screens/sso/sso.tsx`, `sso_authentication.tsx`, `sso_authentication_with_external_browser.tsx` | the decision to keep the identity provider inside a webview and adopt the resulting session (our `SSOView` hosts the existing `WebViewContainer` and polls that server's cookie store instead of copying their webview component) |
| `app/actions/remote/session.ts` | the phase model our `AuthCoordinator` mirrors: login → (MFA) → session; restore at launch; 401 → re-auth; logout clears the local session |
| `app/queries/servers/system.ts` (`getCurrentUserId`/`getCurrentUser`), `app/store/` session shapes | what "a signed-in server" means locally (id + username kept with the token) |

Reimplementation notes that matter for the licence boundary: the Swift machines
(`AuthCoordinator`, `LoginViewModel`, `MFAViewModel`, `SSOViewModel`) are written against
`https://api.mattermost.com` (`/users/login`, `/users/login/mfa`, `/users/me`, `/users/logout`) and
the existing `AuthSession`/`SecureVault`/`CertTrust` types, not translated from RN reducers; error
copy is either the **server's own message** or a Mattermost sentence re-worded in our own file, and
SF Symbols replace every `compass-icons` glyph, so no icon font or extra NOTICE entry is added.

## 9. T32 native team sidebar — upstream read set (Apache-2.0, mobile @ `v2.45.0`)

T32 (`Mattermost/UI/Native/Sidebar/`, `docs/t32-build-note.md`) reimplements the **team rail, team
switching and the zero-team screen** in SwiftUI, and reads the mobile pin's team-unread and
`teams_order` rules. No upstream file is copied or transpiled: the RN sources are TypeScript, and
none of their code, strings or styles are reproduced verbatim. They were read at the pin
`162f2560d0e1df073220f7701d5a67cc17c8abeb` to fix the rules the acceptance criteria name:

| Upstream path (`mattermost/mattermost-mobile` @ `162f2560d0e1df073220f7701d5a67cc17c8abeb`) | Used for |
|---|---|
| `app/components/team_sidebar/team_sidebar.tsx` | the rail as a fixed-width column beside the channel list, collapsed to 0 width when the user has one team, list growing from the top |
| `app/components/team_sidebar/team_list/team_list.tsx`, `team_list/index.ts` | one scrollable column of items, and `myOrderedTeams` (the `teams_order` preference first, display name after) |
| `app/components/team_sidebar/team_list/team_item/team_item.tsx` | the item: selected ring, badge precedence (mentions → unread dot → none), no badge on the selected team |
| `app/components/team_sidebar/team_list/team_item/team_icon.tsx` | rounded icon tile, display-name initials when there is no uploaded icon, `/teams/{id}/image?_{last_team_icon_update}` |
| `app/actions/remote/team.ts` (`handleTeamChange`) | a tap on the current team is a no-op; otherwise the current team changes and the current channel is cleared |
| `app/client/rest/teams.ts` | `getMyTeams` (`/users/me/teams`), `getMyTeamMembers` (`/users/me/teams/members`), the team-icon URL |
| `app/constants/preferences.ts` (`TEAMS_ORDER`) | the preference category that decides rail order (read only — this card does not write it) |
| `app/screens/select_team/no_teams.tsx` | the zero-team state: its copy and the actions it offers |

Reimplementation notes that matter for the licence boundary: the Swift types
(`TeamSidebarDerivation`, `TeamSwitchViewModel`, `TeamSidebarCoordinator`, `TeamSocketScope`) are
written against `https://api.mattermost.com` (`/users/me/teams`, `/users/me/teams/members`,
`/users/me/teams/unread`, `/users/{id}/preferences`, `/teams/{id}/image`) and this repo's existing
`APIClient`/`AuthSession`/`SocketClient` types, not translated from RN reducers or selectors; the
zero-team copy is one short sentence pair re-worded in our own file, and **SF Symbols replace every
`compass-icons` glyph** (the rail draws no icon-font asset), so no icon font or extra NOTICE entry is
added.

## 10. T33 native channel sidebar — upstream read set (Apache-2.0, mobile @ `v2.45.0`)

T33 (`Mattermost/UI/Native/Sidebar/ChannelSidebar*.swift`, `QuickSwitcherView.swift`,
`docs/t33-build-note.md`) reimplements the **channel list with categories, ordering, unread/mention
state, mute, favourites and the quick switcher** in SwiftUI, and reads the mobile pin's category and
quick-switch rules. No upstream file is copied or transpiled: the RN sources are TypeScript, and none
of their code, strings or styles are reproduced verbatim. They were read at the pin
`162f2560d0e1df073220f7701d5a67cc17c8abeb` to fix the rules the acceptance criteria name:

| Upstream path (`mattermost/mattermost-mobile` @ `162f2560d0e1df073220f7701d5a67cc17c8abeb`) | Used for |
|---|---|
| `app/utils/categories.ts` | `makeCategoryChannelId`, category→channel membership, the unread/mute predicates and the per-category channel sort (manual / recent / alpha) |
| `app/utils/channel/index.ts` | `sortChannels` tie-breaks and the "muted channel sorts last in an alphabetical category" rule |
| `app/actions/remote/category.ts`, `app/client/rest/categories.ts` | the categories API: `GET`/`PUT /users/{uid}/teams/{tid}/channels/categories`, the full-array write that a reorder makes |
| `app/actions/remote/channel.ts` | `getMyChannels` / `getMyChannelMembers` shapes and the `/users/me/channel_members` read |
| `app/actions/websocket/channel.ts` | which socket events touch the list (`posted`, `post_edited`, `post_deleted`, `channel_viewed`, `preferences_changed`, `channel_created`, `channel_deleted`, `channel_member_updated`) and how unread is re-read afterwards |
| `app/components/channel_list_row/`, `app/components/channel_item/` (`channel_item.tsx`, `channel_body.tsx`, `channel_type_icon.tsx`) | row anatomy: type glyph, bold-while-unread name, mute marker, mention badge, selected state |
| `app/components/sidebar/` (mobile `channel_list`) | category headers with collapse/expand and the "one row per channel" rule |
| `app/screens/find_channels/index.tsx`, `app/screens/find_channels/filtered_list/` | the quick switcher: a search field over a filtered result list that navigates on tap |
| `app/constants/preferences.ts` | the preference-category constants this card does **not** write (the server's categories API is the sidebar's storage on a 9.11 server) |

Reimplementation notes that matter for the licence boundary: the Swift types
(`ChannelSidebarDerivation`, `ChannelSidebarEntry`, `ChannelSidebarService`, `ChannelSidebarCoordinator`,
`QuickSwitcherView`) are written against `https://api.mattermost.com` (`/users/me/teams/{tid}/channels`,
`/users/me/channel_members`, `/users/{uid}/teams/{tid}/channels/categories`, `/users/me/preferences`)
and this repo's existing `APIClient`/`SocketClient`/`NativeNavigation` types, not translated from RN
reducers or selectors. **SF Symbols replace every `compass-icons` glyph**, so no icon font or extra
dependency is added.

## 11. T34 native channel view and post list — upstream read set (Apache-2.0, mobile @ `162f2560…`; webapp observed only, AGPL-3.0)

T34 (`Mattermost/UI/Native/Channel/Markdown/*.swift`, `EmojiCatalogue.swift`, `PostListModels.swift`,
`ChannelViewModel.swift`, `ChannelService.swift`, `ChannelAPI.swift`, `ChannelView.swift`,
`ChannelScrollPosition.swift`, `PostRowView.swift`, `docs/t34-build-note.md`) reimplements the **post
list and its rendering** — grouping, day separators, markdown/GFM, code blocks, custom emoji,
reactions, attachments, edited /
deleted / system markers, the "new messages" divider and long-history pagination. The upstream read set
is the one `docs/component-map.md` §4 + S11 already names for this surface; no upstream file is copied
or transpiled. The mobile pin is TypeScript (read for rules only); the webapp is AGPL-3.0 and was
**observed in the running client**, never copied or ported.

| Upstream path (mobile @ `162f2560…` unless marked `W`) | Used for |
|---|---|
| `app/components/markdown/transform.ts`, `app/components/markdown/markdown.tsx` | the parse order and the inline-node vocabulary this client's `MarkdownParser`/`MarkdownModel` follows (mention, channel link, emoji shortcode, link, code span, text) |
| `app/utils/emoji/helpers.ts`, `app/utils/emoji/index.ts`, `W webapp/channels/src/utils/emoji.ts` | shortcode handling: lower-cased lookup, an unknown `:name:` stays literal, and the rule that a server emoji outside the Unicode set is drawn from the server's own image |
| `app/utils/post_list/index.ts`, `W …/packages/mattermost-redux/src/utils/post_list.ts` | the ordering/merge rules the list derivation reproduces (newest-first window, no duplicate id across a page boundary) |
| `app/utils/datetime.ts`, `app/utils/date_utils.ts` | the day-boundary buckets a separator sits on (Today / Yesterday / weekday / date) |
| `app/utils/message_attachment.ts` | attachment display structs from `metadata.files` (file name, size, image vs. file) |
| `app/screens/channel/channel_post_list/channel_post_list.tsx`, `app/screens/channel/channel_post_list/intro/*` | the post list host: opening at the newest message, the "load older" position, and the empty-channel intro's role |
| `app/components/post_list/` — `config.ts`, `date_separator/`, `new_message_line/`, `more_messages/`, `post/body/body.tsx`, `post/body/content/*`, `combined_user_activity/` | row anatomy and the states this card draws: the 5-minute same-author grouping, the edited marker, the unread line's position, the "load more" affordance, and the one-row-per-activity rule for system messages |
| `app/actions/remote/post.ts`, `app/client/rest/posts.ts` | `GET /channels/{id}/posts` (`per_page`, `before`, `since`) and the page's `order`/`posts` shape |
| `app/client/websocket/index.ts` (event shapes) | `posted` / `post_edited` / `post_deleted` → patch the list in place; a replayed `posted` replaces rather than appends |
| `W …/components/channel_view.tsx`, `W …/components/post_view/`, `W …/components/markdown/index.ts`, `W …/components/date_separator*`, `W …/components/combined_system_message/` | **behaviour cross-check only** — what the Path A webview actually renders, observed to confirm the native rows say the same thing. No webapp code, markup, class name or string is reproduced. |

Not ported by this card (component-map S11 names them, another card owns them): `embedded_bindings/`,
`interactive_messages/` (Apps plumbing), `opengraph.ts` (no URL previews), the `intro/*` content beyond
the empty-state sentence, and `pooling`/`windowing` of a `FlatList` (SwiftUI's `LazyVStack` is used
instead).

Reimplementation notes that matter for the licence boundary: the Swift types are written against
`https://api.mattermost.com` (`/channels/{id}/posts`, `/users/ids`, `/channels/{id}/members/me`,
`/emoji`, `/emoji/{id}/image`) and this repo's existing `APIClient`/`SocketClient` types, not
translated from RN components, reducers or selectors. The code highlighter is a hand-written tokeniser
per language — no `highlight.js`/Prism code, table or theme is bundled; the built-in emoji are Unicode
characters and **SF Symbols** replace every `compass-icons` glyph, so no icon font, emoji sprite or
extra dependency is added.

`ChannelScrollPosition.swift` is this repo's own bridge, not a port: upstream keeps the reader's place
with the `maintainVisibleContentPosition` behaviour of its inverted `FlatList`
(`dynamic-virtualized-list`, MIT, named only as the mechanism that behaviour comes from), while this
client measures a row's own `UIView` against the enclosing `UIScrollView`'s viewport and corrects by a
point offset. The behaviour — "the post the reader was looking at stays where it was when an older
page is prepended" — is what was read from
`app/screens/channel/channel_post_list/channel_post_list.tsx` (`onViewableItemsChanged` +
`scrollToIndex`); no upstream scrolling or virtualisation code is reproduced.

## 12. T35 native composer + autocomplete — upstream read set (Apache-2.0, mobile @ `162f2560…`)

T35 (`Mattermost/UI/Native/Composer/*.swift` — `ComposerModels.swift`, `ComposerAPI.swift`,
`ComposerService.swift`, `ComposerDraftStore.swift`, `ComposerViewModel.swift`, `ComposerView.swift` —
`ChannelViewModel`'s pending-row methods, `ChannelView`/`PostRowView`'s row actions, and
`docs/t35-build-note.md`) reimplements the **write surface**: the composer, the markdown toolbar and
preview, `@`/`#`/`:` completion, uploads with progress and cancel, send/edit/delete, and per-channel
drafts. The upstream read set is the one `docs/component-map.md` §S14 names for this surface; no
upstream file is copied or transpiled. The mobile pin is TypeScript (read for rules only); the webapp
is AGPL-3.0 and was **observed in the running client**, never copied or ported. Every new file pins
the upstream it derives from in its own header (mobile `@ v2.45.0`,
`162f2560d0e1df073220f7701d5a67cc17c8abeb`), so this section is the repo-level entry those headers
point at.

| Upstream path (mobile @ `162f2560…` unless marked `W`) | Used for |
|---|---|
| `app/components/post_draft/post_draft.tsx`, `post_draft/draft_input/draft_input.tsx`, `post_draft/post_input/`, `post_draft/send_button/`, `post_draft/send_handler/` | composer anatomy: the input, the send affordance and the rule that send is a separate action from typing; the edit and reply banners reuse the same input rather than a second screen |
| `app/components/post_draft/quick_actions/` | the markdown toolbar's action set (bold, italic, strike, code, code block, link, quote, list) applied to a selection with the caret preserved |
| `app/components/post_draft/uploads/` | the attachment tray: one upload per file, a per-file state the reader can see, cancel, and **no automatic retry** (a replayed multipart body can duplicate an attachment) |
| `app/components/post_draft/draft_handler/`, `app/actions/local/draft.ts` | what a draft *is*: keyed by channel and thread root, empty text removes the row, and it is written before the reader can lose it |
| `app/components/post_draft/archived/`, `read_only/`, `typing/` | read only — the archived/read-only banners and the typing indicator are **not** part of this card (no banner is drawn; typing is a socket feature T34 does not ship either) |
| `app/components/autocomplete/autocomplete.tsx` | one suggestion surface that switches source on the trigger character, and the "the list is a generation, a late answer loses" rule |
| `app/components/autocomplete/at_mention/`, `at_mention_item/`, `at_mention_group/` | the `@` list: `GET /users/autocomplete` with `in_channel_id`/`in_team_id`, an id-keyed membership check, and `@username` inserted with a trailing space |
| `app/components/autocomplete/channel_mention/` | the `#` list: channel search over the loaded team, inserted as Mattermost's own `~name` link syntax even though the trigger is `#` |
| `app/components/autocomplete/emoji_suggestion/` | the `:` list: shortcode prefix match, and an unknown `:name:` stays literal |
| `app/screens/edit_post/` | edit is the same composer in edit mode, not a separate editor; `PUT /posts/{id}` changes the message only |
| `app/actions/remote/post.ts`, `app/client/rest/posts.ts`, `files.ts`, `users.ts`, `channels.ts` (and `teams.ts` for channel search) | the write endpoints and their request shapes: `POST /posts` with `pending_post_id`, `PUT`/`DELETE /posts/{id}`, `POST /files` multipart, `GET /users/autocomplete`, `POST /teams/{id}/channels/search`, `GET /channels/{id}/members` |
| `app/screens/global_drafts/` (`GlobalDraftsView`) | read and **not ported**: the board's T35 scope is per-channel drafts. `docs/parity.md`'s T35 row records the gap ("no global drafts list … the screen is unowned on the board") |
| `app/components/common_post_options/` (edit/delete entries) | which entries a row offers and who may see them (`ComposerRowPermissions`); drawn as an overflow button + `PostOptionsSheet` because a `.contextMenu` long press is unreachable on iOS 26 (`docs/t35-build-note.md` §7.1) |
| `W …/components/advanced_create_comment.tsx`, `W …/components/advanced_create_post.tsx` | **behaviour cross-check only** — what the Path A webview's composer does, watched in the running client to confirm the native one says the same thing |
| `W …/components/draft_actions/`, `W …/components/draft_row.tsx`, `W …/components/drafts_list/` | **behaviour cross-check only** — the drafts *list* the webapp renders; not ported (same gap as `global_drafts/` above) |

**The endpoints whose shapes the server disagreed with** (measured against a real Mattermost 9.11.19,
no app involved; each is pinned by `MattermostTests/T35ComposerAPITests.swift` and by the live suite):

- `GET /users/autocomplete?name=&in_channel_id=&in_team_id=` answers an **object** `{"users":[…]}`, not
  a bare array. A bare-array decode throws, and a `try?` around it turns every `@` term into an empty
  list — the failure mode that looks like "the server has no users".
- Channel search is **POST** `/teams/{id}/channels/search` with `{"term","limit"}`. The `GET` form of
  that path is a 404 `api.context.404.app_error` on 9.11.19, which is why `#` produced nothing.
- `GET /posts/{id}` after a `DELETE` answers **404**, not a post whose `delete_at` is set; the post is
  also gone from the channel window and a `PUT` afterwards is 403. (`scripts/t35_softdelete_oracle.py`
  is the no-app probe.)
- `GET /channels/{id}/members` answers `user_id`s while a suggestion's `value` is a **username**: the
  membership filter has to compare ids, or a correct member list filters every person out.

Not ported by this card (other cards own them): slash commands and their parser
(`app/components/autocomplete/slash_suggestion/app_command_parser/`), scheduled posts, the emoji
**picker** (S17/T37 — `:` completes built-in names plus T34's server catalogue only), burn-on-read
editing, and the webapp's drafts list above.

Reimplementation notes that matter for the licence boundary: the Swift types are written against
`https://api.mattermost.com` (`/posts`, `/posts/{id}`, `/files`, `/users/autocomplete`,
`/teams/{id}/channels/search`, `/channels/{id}/members`) and this repo's existing
`APIClient`/`GRDB`/T29 draft table, not translated from RN components, reducers or selectors. Every
string the reader sees is either the **server's own message** or a Mattermost sentence re-worded in
our own file; **SF Symbols** replace every `compass-icons` glyph (the toolbar draws no icon-font
asset), so no icon font, emoji sprite or extra dependency is added by this card.

## 13. T36 native threads and replies — upstream read set (Apache-2.0, mobile @ `162f2560…`; webapp observed only, AGPL-3.0)

T36 (`Mattermost/Core/MM/MMThreadTypes.swift`, `Mattermost/UI/Native/Thread/*.swift` —
`ThreadModels.swift`, `ThreadAPI.swift`, `ThreadService.swift`, `ThreadViewModel.swift`,
`ThreadCoordinator.swift`, `ThreadView.swift`, `GlobalThreadsModels.swift`,
`GlobalThreadsViewModel.swift`, `GlobalThreadsView.swift` — `Core/MM/SocketEvent.swift`'s three thread
events, `Core/MM/MMErrorCopy.swift`, and the channel side: `PostRowView`'s reply line,
`PostRowModel.participants`, `ChannelViewModel.recordReply`/`applyThread`/`applyReplyActivity`,
`ChannelAPI`'s `collapsedThreadsExtended`, `NativeThreadsPaneView`, `TeamSocketScope`) reimplements the
**thread read/write surface**: the thread RHS (root + reply chain, load earlier, follow bell, reply
composer), the followed-threads list with its All/Unreads tabs and paging, the unread counters, and
the participant avatars + reply count drawn under a root in the channel timeline. The upstream read
set is the one `docs/component-map.md` §S13 names for this surface; no upstream file is copied or
transpiled. The mobile pin is TypeScript (read for rules only); the webapp is AGPL-3.0 and was
**observed in the running client**, never copied or ported. Every new file pins the upstream it
derives from in its own header (mobile `@ v2.45.0`,
`162f2560d0e1df073220f7701d5a67cc17c8abeb`), so this section is the repo-level entry those headers
point at.

| Upstream path (mobile @ `162f2560…` unless marked `W`) | Used for |
|---|---|
| `app/screens/thread/index.tsx`, `app/screens/thread/thread.tsx`, `thread_content.tsx` | the screen's data pass: one root per pane, the read-marking on mount, and the header/post-list/composer composition |
| `app/screens/thread/thread_post_list/thread_post_list.tsx` | root drawn once and first, then replies oldest-first, "load earlier" above the chain, and the `fromPost`/`fromCreateAt` paging pair |
| `app/screens/thread/thread_follow_button/thread_follow.tsx` | the bell as the only follow control, and the rule that the control follows the state it just wrote |
| `app/components/post_list/thread_overview/thread_overview.tsx` | the reply line under a root: participant avatars then "N replies", and that tapping it opens the thread |
| `app/screens/global_threads/global_threads.tsx`, `threads_list/index.tsx`, `threads_list/threads_list.tsx` | the followed list, its two tabs, `onEndReached` paging by the last thread id, and the end-of-list state |
| `app/screens/global_threads/threads_list/thread/thread.tsx`, `threads_list/header/index.tsx`, `threads_list/empty_state.tsx` | the row's copy (root author, stripped one-line preview, reply count) and the All/Unreads header |
| `app/actions/remote/thread.ts` | `fetchThread`, `fetchThreads` (page by page id; following implied by list membership; `totalsOnly` for counters), `markThreadAsRead`/`Unread`, `updateThreadFollowing` |
| `app/actions/websocket/threads.ts` | what `thread_updated` / `thread_follow_changed` / `thread_read_changed` must do to an open pane and to a list that is on screen |
| `app/utils/thread/index.ts` | the activity key a followed list is ordered by (`max(last_reply_at, post.create_at)`), i.e. reading a thread does not reorder it |
| `app/client/rest/threads.ts`, `app/client/rest/posts.ts` | the endpoints and their request shapes: `GET /posts/{id}/thread`, `GET /users/me/teams/{team}/threads`, `GET …/threads/{id}`, `PUT`/`DELETE …/threads/{id}/following`, `PUT …/threads/{id}/read/{ts}`, `POST …/threads/{id}/set_unread/{post_id}` |
| `app/client/rest/posts.ts` (`getPostThread`'s `collapsedThreads`/`collapsedThreadsExtended`) | why the channel page asks for the **extended** participant form: it is what turns the root's id-only participant stubs into profiles the avatar stack can draw (~500 bytes per page, measured) |
| `W …/components/threading/global_threads/` | **behaviour cross-check only** — what the Path A webview's thread RHS shows, watched in the running client to confirm the native pane says the same thing |
| `W …/components/threading/thread_view/` | **behaviour cross-check only** — the webapp's thread panel; not ported |

**The endpoints whose shapes the server disagreed with** (measured against a real Mattermost 9.11.19
with no app involved — `scripts/t36_thread_probe.py`, output in `docs/t36-build-note.md` §2, pinned by
`MattermostTests/T36*Tests.swift` and by the live suite):

- `GET /users/me/teams/{team}/threads/mention_counts` — the path the card names — is **404**
  `api.context.404.app_error` in every form tried. The same facts come from
  `GET /users/me/teams/{team}/threads?totalsOnly=true` (`total_unread_threads`,
  `total_unread_mentions`), which is what the list uses; the dead path is pinned by a test.
- The thread list carries its totals **inline** on a normal page, so no extra round trip is needed.
- A thread object has **no `is_following` field**: list membership *is* following, and
  `GET …/threads/{id}` answers **404** once unfollowed. That 404 is how this client models "not
  followed" instead of inventing a field.
- `GET /posts/{id}/thread` returns the root **inside** `order`/`posts` (drawn once, first), and a
  **deleted reply is omitted** — even with `includeDeleted=true`, which the server ignores. A client
  keeps the tombstone it already had; it can never re-fetch one.
- A thread's own `reply_count` and its root post's `reply_count` can **disagree** (measured 2 vs 0),
  so the reply line takes `max(server thread count, root.reply_count, replies loaded)`.
- `?channel_id=` on the thread list is accepted and **ignored**, and `GET /channels/{id}/threads`
  is 404, so there is no channel-scoped followed list to draw (upstream's `threads_button` opens the
  global one too).

Not ported by this card (other cards own them, or the surface is out of scope): the thread options
menu's "open in channel" entry (the model has mark-unread; the UI draws the bell only), a jump-to-unread
anchor **inside** a long chain (the pane opens at the newest reply), the T29 store (no threads
offline), and scheduled/permalink navigation from a thread row.

Reimplementation notes that matter for the licence boundary: the Swift types are written against
`https://api.mattermost.com` (the thread paths above) and this repo's existing `APIClient`/`MMPost`
transport, not translated from RN components, reducers or selectors. Every string the reader sees is
either the **server's own message** or a Mattermost sentence re-worded in our own file; **SF Symbols**
replace every `compass-icons` glyph (the bell, the reply paperclip, the tab glyphs), so no icon font,
emoji sprite or extra dependency is added by this card.

## 14. T37 native reactions and the emoji picker — upstream read set (Apache-2.0, mobile @ `162f2560…`; webapp observed only, AGPL-3.0)

T37 (`Mattermost/UI/Native/Reactions/` — `ReactionModels.swift`, `ReactionAPI.swift`,
`ReactionCoordinator.swift`, `ReactionBarView.swift`, `ReactionSheetView.swift`;
`Mattermost/UI/Native/Emoji/` — `SystemEmoji.swift`, `EmojiRecents.swift`,
`EmojiPickerModels.swift`, `EmojiPickerView.swift`; the generated
`Mattermost/Resources/emoji.json` (`scripts/t37_emoji_build.py`); and the sides that host it:
`ChannelView.swift`'s `ChannelListSheet`, `PostRowView.swift`'s `PostRowReactionActions` +
`PostOptionsSheet`'s `React`, `ChannelViewModel`/`ThreadViewModel`'s `ReactionTarget` conformance,
`ChannelService`/`ThreadService`'s two writes, `ChannelPaneCoordinator.emojiRecents`, and
`ComposerView`'s toolbar picker) reimplements the **reaction and emoji-picker surface**: the pill row
with counts and the reader's own highlight, tap-to-toggle, the reactor list, the picker
(recents → custom → system categories, with colon-stripping search), and the same picker used to
insert an emoji into the composer. The upstream read set is the one `docs/component-map.md` §S16 and
§S17 name for these surfaces; no upstream file is copied or transpiled. The mobile pin is TypeScript
(read for rules only); the webapp is AGPL-3.0 and was **observed in the running client**, never copied
or ported. Every new file pins the upstream it derives from in its own header (mobile `@ v2.45.0`,
`162f2560d0e1df073220f7701d5a67cc17c8abeb`), so this section is the repo-level entry those headers
point at.

| Upstream path (mobile @ `162f2560…` unless marked `W`) | Used for |
|---|---|
| `app/actions/remote/reactions.ts` | `toggleReaction` → `addReaction`/`removeReaction`, `getIsReactionAlreadyAddedToPost`, the canonical-alias rule (`getEmojiFirstAlias`) applied to every write, and recording a successful react as a recent |
| `app/actions/local/reactions.ts` | `addRecentReaction` and `MAXIMUM_RECENT_EMOJI = 27` — the recents cap this client uses |
| `app/actions/websocket/reactions.ts` | what `reaction_added` / `reaction_removed` must do to an open window, and why an event for the reader's own user must not double-apply |
| `app/screens/reactions/index.tsx`, `reactions.tsx` | the reactor sheet: an emoji bar over the reactor list, with the bar's order held stable while the sheet is open |
| `app/screens/reactions/reactors_list/*` (`index.tsx`, `reactor/reactor.tsx`) | one row per reactor, and fetching only the profiles the client does not already hold |
| `app/components/post_list/post/body/reactions/reaction.tsx`, `reactions.tsx` | the pill itself (emoji + count, `highlight` when the reader reacted, tap = toggle, long press = who reacted) and the trailing `+` affordance |
| `app/screens/emoji_picker/index.tsx` | a bottom sheet whose pick calls back **and closes** |
| `app/screens/emoji_picker/picker/picker.tsx`, `picker/sections/index.tsx`, `picker/filtered/*` | the search bar; sections ordered recent → custom → datasource categories, `recent` omitted when empty; a non-empty term replaces the list with ranked results |
| `app/constants/emoji.ts`, `app/components/emoji_category_bar/*` | the category names and the horizontal category strip |
| `app/utils/emoji/index.ts`, `app/utils/emoji/emoji.json` | the generated shortcode table (the bundled resource is this data, regenerated by our own script) |
| `app/utils/emoji/helpers.ts` | `getEmojiFirstAlias`, `compareEmojis`, `searchEmojis`, `getSkin`/`getEmojis(skinTone:)` |
| `app/components/autocomplete/emoji_suggestion/*` | how the composer's `:` list and the picker agree on the inserted text (`:name:`) |
| `app/client/rest/reactions.ts` | `POST /reactions`, `DELETE /users/{user_id}/posts/{post_id}/reactions/{emoji_name}` |
| `W …/components/emoji_picker/`, `W …/components/reactions/` | **behaviour cross-check only** — what the Path A webview shows for the same tap, watched in the running client; not ported |

**The endpoints whose shapes the server disagreed with** (measured against a real Mattermost 9.11.19
with no app involved — `scripts/t37_reaction_probe.py`, output in `docs/t37-build-note.md` §2, pinned
by `MattermostTests/T37ReactionTests.swift` and by the live suite):

- `POST /posts/{id}/reactions` — the path the card's own Reference line names — is **404**
  `api.context.404.app_error` on 9.11.19. The add is `POST /reactions` with
  `{user_id, post_id, emoji_name}` (201, the reaction object).
- The remove is `DELETE /users/{uid}/posts/{pid}/reactions/{emoji_name}`, and a name like `+1`
  **must** be percent-encoded (`%2B1`) or the path is misread.
- Alias spellings are **separate rows**: adding `thumbsup` and then `+1` leaves two reactions for the
  same picture. Hence one pill per alias group, the write uses the canonical alias, and a remove
  deletes every alias the reader holds in that group — otherwise the pill returns on the next page
  load.
- A remove of a row the server no longer has answers **404**; that is treated as "the desired state
  already holds", not as a failure.
- `POST /users/login` answers the session token in the **`Token` response header** only when the call
  carries `X-Requested-With: XMLHttpRequest` (otherwise it sets `MMAUTHTOKEN` cookies).

Not ported by this card (other cards own them, or the surface is out of scope): the `recent_emojis`
**server preference** (recents are local, keyed per server *and* user, cap 27 — upstream keeps them in
its per-server database, so neither client syncs them across devices), skin-tone variants
(`getSkin`/`getEmojis(skinTone:)`), custom emoji **upload/deletion** (the picker lists what
`GET /emoji` returns), an emoji picker for the webview composer (the native picker is reachable only
when the write surface is native), and reaction **filtering/sorting choices** beyond upstream's
default order. Search ranking uses a deterministic exact → prefix → subsequence tier instead of
upstream's Fuse scores; the exact/prefix ordering rules are the same.
