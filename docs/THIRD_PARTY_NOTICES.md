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
