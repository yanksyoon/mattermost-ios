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
