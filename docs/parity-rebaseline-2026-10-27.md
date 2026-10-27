# Parity re-baseline — 2026-10-27

Card: **Re-baseline parity against upstream Mattermost and re-plan the board** (`t_8c3ee1e9`).
Base: `origin/main` `2f3218e` (the checkout was fast-forwarded from `f833459`; the tree is clean).
Scope: the native surfaces T32–T45 and `docs/parity.md`, re-read against the upstream inventory
(`docs/native-inventory.md`, `docs/inventory/*`, `docs/component-map.md`, pins `M v2.45.0` =
`162f2560…`, `W v12.0.1` = `987e5712…`).

This document is the **current gap list** and the **next tranche**. `docs/parity.md` remains the
module→native mapping; its per-card rows are history and are not re-edited except where noted in §4.

---

## 1. Headline findings

1. **A release build is still Path A.** `SurfaceDefaults.nativeApprovedSurfaces` is
   `[.auth, .calls]` (`Mattermost/Core/RenderMode.swift:93`) and `paneOwningSurfaces` is `[]`
   (`:105`). `.channelView` is the pane host (`:113`) and resolves `web`, so every release build
   mounts the per-server WKWebView — the native screen cards exist, are tested, and are
   reachable only through DEBUG `-surfaceMode` flags or the DEBUG inspector. The one surface the
   owner has approved since (`.sidebar`) is parked behind the human gate `t_4413b7b2` in
   `t_c93b8337`.
2. **Five surfaces are repaired but never re-validated.** T36, T37, T38, T39 and T40 each failed
   their `-AV`, each got a repair, and none got a second verdict. All five mount inside the pane
   (threads, reactions, attachments, the search/pinned entry and the channel-info sheet), which is
   exactly why `.channelView` cannot be approved yet. This is a QA debt, not a code debt — hence
   `t_6059f7ce` (this tranche's only `mmios-qa` card).
3. **The client cannot start a conversation.** There is no channel creation path at all: no
   `POST /channels` anywhere in `Mattermost/`, no create menu, no create form. Editing an existing
   channel works (`ChannelSettingsView`), browsing/joining works (`BrowseChannelsViewModel`), so the
   gap is specific and fixable → `t_2739ca53` (T47).
4. **The post menu is three items.** Reply / edit / delete only. Copy text, copy link, save,
   pin, mark unread and follow-thread are upstream's own long-press menu items and none is offered
   → `t_37f27c09` (T48). Most of the transport already exists and is tested.
5. **Six whole surfaces are simply absent**: terms-of-service gate (S06), sign-up + forgot
   password (S04), edit profile + custom profile attributes (S28/S39), global drafts + scheduled
   posts (S26/S40), the Apps framework incl. slash commands (S34), and the share extension (S36).
   Two of the six (TOS, scheduled posts) are correctness problems, not conveniences: a TOS-required
   server lets the native shell in with the acceptance outstanding, and a draft is unreachable
   unless the reader reopens that exact channel.

The three gaps the card named as known are disposed of as follows: **avatars** closed
(`t_7c7112ce`, `docs/t45-avatars-build-note.md`); **unread threads** closed (`t_4dfdf856`,
`docs/t4d-build-note.md`); **modals that do not dismiss** still open and already carded
(`t_ddf85143`).

---

## 2. Method, and what this card did not do

The audit is **tree-first**: the native inventory (S01–S40) is the checklist, the pinned mobile and
webapp trees are the behaviour reference, and every status below cites either a native file path or
a grep that returns nothing. Absence is stated as absence of code, not as "unverified".

Runs: `git fetch` + `git merge --ff-only origin/main` (→ `2f3218e`), a symbol/path audit of
`Mattermost/` (feature names, endpoint paths, the PBX target list), and a read of the
registry, the pane host, the shell's layout, the sheet host, the channel-info screen and the file
viewer. **No UI run and no new live test was performed by this card** — it is a re-plan, and every
"missing" claim is a code-level fact that a worker will re-measure before building (each card says
so). Test status cited below is the cited card's own evidence, not a re-run.

Limits that stay: the fixture is Mattermost 9.11.19 on `127.0.0.1:8065`; enterprise-gated features
(scheduled posts, custom profile attributes, some bookmark/translation behaviour) may refuse there.
Each card is told to record the refusal rather than fake the feature.

---

## 3. Surface-by-surface status (S01–S40)

Legend: **native** = implemented and tested behind its surface flag; **partial** = the named
sub-surface is missing; **webview** = deliberate (ADR §2.3); **absent** = no code.

| # | Surface | Status | Native evidence / what is missing |
|---|---|---|---|
| S01 | Login | native | `UI/Native/Auth/LoginView.swift`, `LoginViewModel`, `AuthCoordinator` (T31, `.auth` native-by-default) |
| S02 | MFA | native | `MFAView`/`MFAViewModel` (T31) |
| S03 | SSO | native + by-design webview hand-off | `SSOView`/`SSOViewModel`; the IdP runs in `WebViewContainer` and the session is adopted (T31) |
| S04 | Sign-up / forgot / reset password | **absent** | no `forgot`, `reset_password` or sign-up form anywhere; inventory S04 → `t_aec46149` (T49) |
| S05 | Server add/edit/select | native | T5 `ServerFormView` + `ServerURLValidator` |
| S06 | Terms-of-service gate | **absent** | `grep terms_of_service` → nothing; native auth lets a TOS-required server reach the workspace → `t_aec46149` (T49) |
| S07 | Team selection | native | `TeamSidebarView`/`TeamSwitchViewModel`, no-team state; join-team missing (see S23) |
| S08 | Channel sidebar | native (flag) | `ChannelSidebarView` + `ChannelSidebarModels/Service/Coordinator` (T32/T33), categories, mute, favourites, quick switcher; **no create menu** (→ T47), no drag-reorder, no category CRUD |
| S09 | Find / browse channels | partial | `BrowseChannelsView` + quick switcher exist; the create entry point and the unified find-channels dialog do not → `t_2739ca53` (T47) |
| S10 | Create / edit / convert channel | partial | edit + archive native (`ChannelSettingsView`); **create absent** (→ T47); GM→private-channel conversion absent |
| S11 | Channel view | native (flag) | T34 markdown/list/paging/reactions/attachments; LaTeX is deliberately not rendered (`MarkdownView.swift:4`); video/audio attachments have no reader (→ T53) |
| S12 | Permalink | native | `NativeNavigation` parses `/pl/{id}` and `/channels/{name}/{id}` and resolves post→channel; a tapped search/saved/pinned row lands on the post (`ChannelView` jump path) |
| S13 | Threads RHS + global threads | native (flag) | T36 thread pane (follow, read/unread, composer), global list, and T4d's unread count in the rail; re-validation pending (`t_6059f7ce`) |
| S14 | Composer | partial | T35 send/edit/delete/drafts/uploads/markdown toolbar; **no slash commands** (`commands/execute` has no hit), **no send-later** (→ T51) |
| S15 | Autocomplete | partial | `@`/`#`/`:` completion native; `/` command suggestions absent (rides S34) |
| S16 | Reactions | native (flag) | T37 pills/reactor sheet; a shortcode outside the bundled table renders literal `:name:` — carded `t_580df874` |
| S17 | Emoji picker + custom emoji | partial | picker, search, recents, custom cells native; creating/deleting a custom emoji is absent |
| S18 | Files / gallery / previews | partial | T38 images, PDF, text, refusal list, gallery, save/share; **video and audio refused as "no native reader"** → `t_bfbbcbed` (T53) |
| S19 | Search | native (flag) | T39 grammar/highlighting/paging/recents; search covers posts only — no file search, no user search |
| S20 | Saved messages | native (flag) | T39 `SavedPinnedViews` over `posts/flagged` |
| S21 | Pinned messages | native (flag) | T39 pinned sheet, reachable from the channel header, pin/unpin writes |
| S22 | Channel info + add members | partial | T40 header/stats/members/add/browse/settings/leave/archive; **missing notifications, files, bookmarks, pinned row, shared channels** → `t_8c85e851` (T52) |
| S23 | Members / manage | partial | member list with search + remove; add members; DM shortcut from a profile; **missing role change, email invites, join team, create GM** |
| S24 | Profile / presence / custom status | native (flag) | T41 profile sheet + status setter + custom status; faces via T45 `AvatarImageStore` |
| S25 | Mentions inbox + in-app notification | partial | T42 mentions feed/filters/mark-read; **no in-app banner for a foreground mention** → `t_1c20f743` (T54) |
| S26 | Drafts + scheduled posts | partial | drafts persist (`ComposerDraftStore`, GRDB); **no drafts list, no scheduled posts** → `t_e1ac98d8` (T51) |
| S27 | User settings | partial | shell `SettingsView` (T11) + notification-input section (T43); the mobile settings tree (display, notification prefs, advanced, about) is not ported |
| S28 | Edit profile | **absent** | no name/position/email editor, no avatar upload → `t_44721717` (T50) |
| S29 | System Console | webview | T46 escape hatch |
| S30 | Plugin screens | webview | T46 |
| S31 | Boards | webview | T46 |
| S32 | Playbooks | webview | T46 |
| S33 | Calls | native surface, media unproven | `UI/Native/Calls/` + `Core/Calls/CallsEngine` (WebRTC, voice track); camera deliberately absent; the fixture's SFU ICE candidates were unreachable from this host (`docs/t44-build-note.md`), so media stays unverified and the webview remains the fallback |
| S34 | Apps framework | **absent** | no bindings/call/dialog code; slash commands missing (see S14/S15) |
| S35 | Notifications (local + push) | local native / push blocked | T8 + T43; real APNs + Push Proxy blocked on this host (`t_05e6d64e`, `t_b07bd72f`) |
| S36 | Deep links / share extension | partial | deep links native (T4/T30); **no share-extension target** (pbxproj has 3 targets: app, tests, UI tests) |
| S37 | Onboarding / join team | partial | welcome pager + first-run gate native (T10); **join team via invite absent** |
| S38 | Post options | partial | reply/edit/delete only; the rest of upstream's menu absent → `t_37f27c09` (T48) |
| S39 | Custom profile attributes | **absent** | no `custom_profile_attributes` code; rides `t_44721717` (T50) |
| S40 | Scheduled posts | **absent** | no `posts/schedule` code → `t_e1ac98d8` (T51) |

---

## 4. Cross-cutting gaps

**4.1 Registry / release path.** The native client is a DEBUG feature until the registry moves.
`.auth` and `.calls` are approved. `.sidebar` was approved by the owner on 2026-10-27 and is held in
`t_c93b8337` behind the human gate `t_4413b7b2` (the gate asks A: sidebar + channelView, B: inert
rows only). `.channelView` is explicitly *not* approved and `paneOwningSurfaces` must stay empty
until the surfaces it hosts hold verdicts. Nothing in this re-baseline changes that decision; §5 of
`t_c93b8337` already carries the measured screenshots.

**4.2 Re-validation debt.** T36/T37/T38/T39/T40 repairs are on `main` with no second verdict; see
`t_6059f7ce`. This is the cheapest path to a `.channelView` decision and it is the only QA card in
the tranche.

**4.3 Doc drift in `docs/parity.md`.** T45 (avatars) and T4d (unread threads) landed without rows;
the Path B section still says the approval registry "is still empty". Corrected in this commit by a
blockquote pointer above the Path B table, a T45 row with its evidence, and a note on that pointer
that the registry has since grown. T4d does not need its own row — it refines T36's pane and T33's
rail, and `docs/t4d-build-note.md` is its evidence.

**4.4 Test-infrastructure debt.** The clock-poll sweep (t_00fb623c, t_eccd49eb) is closed, but the
board still carries a resync follow-up (`t_e0077228`) and a modal-dismiss defect
(`t_ddf85143`) that no parity table shows — both are user-visible, not just test hygiene.

**4.5 Accessibility.** T45 (accessibility/Dynamic Type/VoiceOver) is scheduled behind the flip
(`t_4f60b3af`, with `t_7de91bcf` as its validator). It is not re-scoped here.

**4.6 Not gaps, by decision.** System Console, plugin screens, Boards, Playbooks stay webview
forever (ADR §2.3) and are handled by T46 (`t_a7a9f2ff`, validator `t_c0096b03`). Calls stays
webview until the media path can be measured on a reachable SFU; the T44 probe and its measured
corrections are the starting point if that is ever revisited.

---

## 5. Already carded — do not duplicate

| Card | Covers |
|---|---|
| `t_c93b8337` (+ gate `t_4413b7b2`) | `.sidebar` native-by-default flip |
| `t_4f60b3af` / `t_7de91bcf` | T45 accessibility pass + its validator |
| `t_a7a9f2ff` / `t_c0096b03` | T46 webview escape hatch + its validator |
| `t_ddf85143` | modals that do not dismiss (post options Cancel, many Done/Cancel) |
| `t_580df874` | unknown reaction shortcodes render literal text |
| `t_e0077228` | T34-R5b thread/mention resync on a socket gap |
| `t_05e6d64e` / `t_b07bd72f` | Push Proxy + APNs (blocked on hardware/account) |
| `t_5f4e955e` | Apple Developer Program + push hosting (human gate) |
| `t_d43d3180` | Sentry/diagnostics + release rollout |

---

## 6. The next tranche

Ordered by what a reader loses today. Every card: parity reference is the pinned mobile file named
in its body; pure logic before UI; a live fixture test wherever correctness depends on the server;
`docs/tNN-build-note.md`; whole-`MattermostTests` green; staged by explicit pathspec (the shared
tree carries other cards' work); pushed and `git ls-remote`-verified.

| Card | Title | Why now |
|---|---|---|
| `t_2739ca53` (T47) | Create a channel + the sidebar create menu (S10 create, S09) | The native client cannot start a conversation |
| `t_37f27c09` (T48) | Post options menu: copy text/link, save, pin, mark unread (S38) | Daily read/write, transport already exists |
| `t_aec46149` (T49) | TOS gate + sign-up / forgot password (S06, S04) | A TOS server currently lets the shell in unaccepted |
| `t_44721717` (T50) | Edit profile + avatar upload + custom attributes (S28, S39) | The reader cannot change their own name or picture |
| `t_6059f7ce` (T55-AV-R) | Re-validate the five repaired surfaces (`mmios-qa`) | Unblocks any `.channelView` decision |
| `t_e1ac98d8` (T51) | Global drafts list + scheduled posts (S26, S40) | Drafts are otherwise unreachable |
| `t_8c85e851` (T52) | Channel info completeness: notifications, files, bookmarks, pinned (S22) | Named as missing by T40's own file comment |
| `t_bfbbcbed` (T53) | Video + audio playback in the file viewer (S18) | Both are refused as "no native reader" |
| `t_1c20f743` (T54) | In-app mention banner (S25) | A foreground mention in another channel is invisible |

Each card's body carries its own acceptance criteria; the invariants they share are: **one ordered
derivation** for anything the UI offers (so "offers nothing it cannot perform" is assertable), **the
live suite reads server state, not UI echoes** (T40-AV F1/F2), **no token in a URL or a log**
(`scripts/t28-token-grep.sh`), and **no registry flip without a paired `-AV`**.

Deliberately **not** in this tranche: role management and email invites (S23), join team (S37),
custom emoji management (S17), file/user search (S19), Apps framework (S34), share extension (S36).
They are real gaps recorded above; cutting them keeps this tranche shippable. They are the natural
tranche after it.

---

## 7. What remains unverified here (honest gaps)

- No live UI run was made for any of the nine cards' claims; their bodies require the worker to
  measure before building, and each says what to do if the fixture refuses (record, do not fake).
- Scheduled posts, custom profile attributes and bookmarks may be enterprise-gated on 9.11.19; the
  cards are written to split, not to pretend.
- Calls media cannot be verified on this host (SFU ICE unreachable, `docs/t44-build-note.md`); the
  surface stays webview-fallback until a reachable SFU exists.
- Real APNs / Push Proxy remain blocked (account + hosting), unchanged by this re-baseline.
- The 9.11.19 fixture is the only server measured; older-server tolerance is each card's own
  explicit rule (decode-tolerant models, no string sniffing).
