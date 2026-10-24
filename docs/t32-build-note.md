# T32 — native team sidebar & team switcher (build note)

Status: **implemented, self-verified** (unit + live UI test against a real `mattermost` server).
Not approved: the surface stays behind its own flag until a `T32-AV` card passes
(`docs/dual-render.md` §3).

Upstream behaviour reference (never ported line by line, per `docs/path-b-adr.md` §3):
`mattermost/mattermost-mobile` @ `162f2560d0e1df073220f7701d5a67cc17c8abeb` —
`app/components/team_sidebar/{team_sidebar,team_list,team_item,team_icon}.tsx`,
`app/components/no_teams/no_teams.tsx`, `app/actions/remote/team.ts` (`handleTeamChange`),
`app/client/rest/teams.ts`, `app/constants/preferences.ts` (`TEAMS_ORDER`).

## 1. What shipped

| Surface | File | Contents |
|---|---|---|
| Model + rules | `Mattermost/UI/Native/Sidebar/TeamSwitchViewModel.swift` (473) | `TeamSidebarEntry`, `TeamSidebarBadge`, `TeamSidebarContent`, `TeamSidebarData`, `TeamSidebarServing`, `SessionTeamSidebarService`, `TeamSwitchViewModel`, and the pure `TeamSidebarDerivation` that every rule below lives in |
| Event scope | `Mattermost/UI/Native/Sidebar/TeamSocketScope.swift` (71) | which socket events may reach the team that is on screen |
| Owner | `Mattermost/UI/Native/Sidebar/TeamSidebarCoordinator.swift` (381) | one `TeamSwitchViewModel` + **one socket** per server, the switch funnel, the debounced counter refresh |
| View | `Mattermost/UI/Native/Sidebar/TeamSidebarView.swift` (329) | `NativeTeamSidebarPane`, `TeamSidebarRail`, `TeamIconButton`, `TeamSidebarEmptyState`, `TeamSidebarFailureState` |
| Host | `Mattermost/UI/Native/NativePanePlaceholders.swift` | `NativeChannelSidebarPane` now picks rail-or-placeholder; the Workspace row reads out the current team (`sidebarCurrentTeam`) |
| Wiring | `Mattermost/MattermostApp.swift` | `@StateObject` owner + `environmentObject` + `bind(auth:navigation:serverStore:)` + `authPhaseChanged` on every auth transition |

Transport (already-existing files, additive):

| File | Change |
|---|---|
| `Core/MM/MMEndpoints.swift` | `myTeams()` (`GET /users/me/teams`, ETag), `myTeamMemberships()` (`/users/me/teams/members`, ETag), `teamUnreads()` (`/users/me/teams/unread`, **no** ETag), `teamIconData(teamID:lastUpdateAt:)` (`GET /teams/{id}/image?_=<stamp>`, authenticated) |
| `Core/MM/MMTypes.swift` | `MMTeamUnread`, `MMTeamMembership` (tolerant decoders) |
| `Core/Store/MMStoreModels.swift` | `MMTeam` gains a **tolerant** `init(from:)` — see §8.1 |
| `Core/MM/AuthSession.swift` | `client` is internal (a screen card may not build its own `APIClient`, and a 401 from the rail must land in `AuthCoordinator`) |
| `UI/Native/Auth/AuthCoordinator.swift` | `userID(for:)` — the rail needs the id to filter memberships |

Fixture: `scripts/t32_team_seed.py` (255) — idempotent, local server only: creates team `ops`
("Operations"), an `ops-standup` channel with N mentions of `perfprobe` written by `opsbot`, uploads a
64×64 PNG icon, and writes `teams_order = [perf, ops]`.

## 2. How it is gated

`SurfaceDefaults.paneHostSurface` / `-surfaceMode sidebar=native`. The default is **web**: without the
flag the sidebar is exactly T30's placeholder (`nativeSidebar` list), so every UI test written before
this card keeps passing unchanged. With the flag the pane is
`HStack { rail? ; T30 placeholder list }` — the T30 list stays the pane's content until T33 lands the
channel list, which is also why a loading rail never blanks the sidebar (see §8.3).

## 3. The rules, and where they live

All of these are pure functions on `TeamSidebarDerivation`, so they are unit-tested without a view:

1. **Ordering** — `teams_order` preference first (unknown/duplicate ids dropped), then display name,
   case-insensitive. No preference → alphabetical. (`sorted(_:order:)`)
2. **Membership** — a team is drawn when `/users/me/teams` lists it *and* its membership row belongs
   to this user with `delete_at == 0`. If the membership list is empty (that call failed), the teams
   list is trusted rather than dropping the whole rail. Soft-deleted team (`delete_at > 0`) never draws.
3. **Badges** — mentions beat the dot: `mentionCount > 0` → red pill (capped `99+`, the real number
   stays in `accessibilityValue`), else `msgCount > 0` → dot, else nothing. **The selected team draws
   no badge** (upstream hides it; you are looking at that team already).
4. **Initials** — first two *grapheme clusters* of the display name with whitespace removed, uppercased.
   Deliberately not `substring(0, 2)`: that is UTF-16 based and splits flags/emoji (and keeps a
   trailing space).
5. **Content state** — `idle`/`loading` with no entries → no claim (no "no teams" copy); `loaded` + 0 →
   empty state; `loaded` + 1 → channel pane only, **no rail chrome**; 2+ → rail.

## 4. Selection is not stored in this card

The current team is read from `NativeNavigation.location` — the one value a rail tap, a deep link, a
notification tap and the server switcher all write. `TeamSidebarCoordinator.apply(_:)` pushes it into
the model and into the socket scope on every change (synchronously, `Combine` without a scheduler
hop, so a tap is never observable mid-switch).

A switch goes through the same funnel as everything else: `NativeNavigation.openChannel(
NativeChannelRequest(serverID:teamID:teamName:))`. That call replaces the location wholesale, so the
previous team's channel (`location.channelID`), its display name **and** the compact-layout push stack
cannot survive a team change — which is acceptance criterion 1.

`TeamSidebarCoordinator.activate(_:)` applies the first ordered team as current **only when** nothing
is chosen yet *and* the location is not already a destination (a deep link or a mention tap into the
other team wins).

## 5. One socket per server, and what may reach the screen

`SocketTeamEventSource` opens a `SocketClient` per server (a Mattermost socket is per *server*; every
team's events arrive on it) and hands the coordinator an `AsyncStream`. `TeamSidebarCoordinator`
keeps exactly one pump task per server id, so ten rapid taps leave **one** subscription
(`subscriptionCount == 1`, `connectCount == 1` — pinned by a test).

`TeamSocketScope` decides delivery after each switch: an event is delivered only if it belongs to the
selected team (`channelId` of the active channel, or a channel→team learned while browsing). Events in
the previous team's channel are **refused** (`refusedEventCount`), which is the socket half of "no stale
data from the previous team". Reactions name a post, not a channel, so they are refused until the
channel view (T34) resolves the post itself. `onTeamEvent` is the seam T34/T36 consume.

Post activity (`.posted`, `.postEdited`, `.postDeleted`, `.channelViewed`) triggers a **coalesced**
counter refresh (`teamUnreads` only — never the team list) so a burst of ten posts is one request.

## 6. Acceptance criteria → evidence

| Criterion | Evidence |
|---|---|
| Rail lists the server's teams in `teams_order`, badges are the server's numbers | `testRealServerTeamRailShowsBothTeamsAndSwitchesBetweenThem` (live, `docs/t32-shots/t32-01-rail-two-teams.png`): two tiles, `Perf` first although `Operations` sorts first alphabetically, red `2` on Operations, none on the selected team |
| Team switch moves the shell and drops the previous team's channel | `testSwitchingTeamsClearsTheChannelAndThePushStack`, `testTenRapidSwitchesLeaveOneSubscriptionAndTheLastTeamWins`, live shots `t32-02`/`t32-03` |
| No stale data from the previous team (socket) | `testAfterASwitchThePreviousTeamsEventsAreRefused` |
| One team → no rail; zero teams → the empty state; nothing claimed before the first answer | `testZeroTeamsIsTheEmptyStateOnceTheAnswerArrives`, `testExactlyOneTeamGetsNoRailChrome`, `testTwoTeamsGetTheRail` |
| Badge formatting (`99+`, dot, hidden when selected, accessible label) | `testBadge*` (4 tests) |
| The rail survives real-server payloads | `testTeamWithoutAnIconDecodesInsteadOfFailingTheWholeList` (found by §8.1) |

## 7. Evidence runs (this host, 2026-10-25)

```
# unit suite, Mac Catalyst
python3 scripts/qa-test.py --platform mac --label t32-units
→ tests: 697 run, 4 skipped, 0 failed                       RESULT: PASS
  (42 of them are MattermostTests/T32-TeamSidebarTests.swift; the 4 skips are pre-existing
   live-server tests that skip without TEST_RUNNER_MM_AUTH_*)

# the live rail test, iPad Pro 11-inch (M5), iOS 26.0 simulator, real server at 127.0.0.1:8065
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password in scripts/perf_seed.py> \
TEST_RUNNER_MM_AUTH_SHOT_DIR=<abs>/t32-shots \
python3 scripts/qa-test.py --platform ios --sim DC3E9FB7-E4A0-4B24-8DBB-7960A059EC7A \
  --only-testing MattermostUITests/MattermostUITests/testRealServerTeamRailShowsBothTeamsAndSwitchesBetweenThem
→ tests: 1 run, 0 skipped, 0 failed                          RESULT: PASS

# the whole UI suite (regression: nothing earlier changed), same simulator
python3 scripts/qa-test.py --platform ios --sim DC3E9FB7-E4A0-4B24-8DBB-7960A059EC7A \
  --only-testing MattermostUITests --label t32-uisuite
→ tests: 25 run, 4 skipped, 0 failed                          RESULT: PASS
  (the 4 skips are the live-server tests, env-gated; with TEST_RUNNER_MM_AUTH_* set they run,
   and the T32 one passed when it did — the run above)
```

Logs kept beside this note: `docs/t32-units-2026-10-25.log`,
`docs/t32-uisuite-2026-10-25.log`.

Dual-render gates (`bash scripts/verify-dual-render-gates.sh --allow-approved-registry`) →
**RESULT: PASS** (23 checks; 10 gate groups). Without the flag the run fails gate 5 only, which is the
pre-existing `nativeApprovedSurfaces = [.auth]` ledger (T31-R), not this card. The new UI files are
picked up by the `Mattermost/UI/Native` synchronized group — gate 8 counts them with no hand-written
project-file entry.

Commit: `feat(native): team sidebar and team switching (T32)` — one commit on the card. The exact
sha is in the card's hand-off metadata (a note cannot name its own commit's sha without changing it).

What the server itself returned at the time of the run (script, not app):

```
/users/me/teams              -> 200 application/json rows=2
/users/me/teams/members      -> 200 application/json rows=2
/users/me/teams/unread       -> 200 application/json rows=2
/users/me/preferences        -> 200 application/json rows=6
/teams/{id}/image?_=<stamp>  -> 200 image/png bytes=262 png=True
team perf  display 'Perf'       icon_update=0
team ops   display 'Operations' icon_update=1792869870708
unread perf mentions=0 msgs=0
unread ops  mentions=2 msgs=2
teams_order: ['<perf-id>,<ops-id>']
```

Screenshots (iPad, light): `docs/t32-shots/t32-01-rail-two-teams.png`,
`t32-02-switched-to-operations.png`, `t32-03-switched-back-to-perf.png`.

## 8. Defects found while verifying (and the fixes)

1. **Strict `MMTeam` decoding broke on ordinary teams.** The real `/users/me/teams` row **omits**
   `last_team_icon_update` for a team with no icon and sends `group_constrained: null`; the
   synthesized decoder threw `keyNotFound` for the first and a type error for the second, which took
   the whole list — and therefore the rail — down. Fixed with a tolerant `init(from:)` on `MMTeam`
   (same rule `MMPost` already had) + `testTeamWithoutAnIconDecodesInsteadOfFailingTheWholeList`
   built from the captured payload.
2. **The Workspace row showed the URL team name** (`perf`) instead of the display name (`Perf`),
   because `NativeLocation.teamName` is what a deep link carries. Fixed by resolving the display name
   through the rail's entries (`teamTitle(name:id:)`), which is also what made the live assertion
   meaningful.
3. **The selection ring was invisible on an uploaded icon.** The seeded icon is a solid blue 64×64
   PNG and the accent ring was drawn straight onto it. Fixed with a white plate between tile and ring,
   so the ring reads on any icon colour (verified in shot `t32-02`).
4. **The initials tile could be a flag cut in half** (upstream's `substring(0, 2)` bug). Fixed and
   pinned by `testInitialsDoNotSplitAGraphemeCluster`.
5. **The icon was refetched on every redraw** for teams with no icon. Fixed with a per-team update-stamp
   cache; negative results are cached too, a new stamp re-fetches.
6. **A default argument could not build a main-actor type** (`SocketTeamEventSource()` in a `@MainActor`
   init's default argument). Fixed by building it in the init body; the production service is resolved
   per call anyway because the rail can be created before the session finishes restoring.
7. **A loading rail blanked the sidebar.** The first frame used to replace the pane with a spinner,
   which would have removed `nativeSidebar` from the accessibility tree mid-load and broken earlier UI
   tests. Now the pane's T30 content is always drawn; only a *definitive* empty/failed answer replaces
   it.
8. **T32-R correction to #7 (F2, T32-AV): "always drawn" was necessary but not sufficient.** The
   content was drawn, but T32's own wrapper handed its identifier to the content: with
   `sidebar=native` and a **one-team** account the pane has a single child, so SwiftUI applied
   `NativeTeamSidebarPane`'s `.accessibilityElement(children: .contain)` +
   `.accessibilityIdentifier("nativeTeamSidebar")` to that child (a `CollectionView`) and the
   `List`'s own `nativeSidebar` identifier disappeared — exactly the state (one team, and the
   loading state, which also has no rail) where `MattermostUITests`' shipped T30 assertion looks for
   it. Reproduced A/B by T32-AV (their AVR5) and again here with `docs/t32r-repair-note.md`'s
   fixtures. The empty/failure screens had no pane identifier at all.
9. **The empty/failure screens' container identifiers never reached the tree** (T32-AV F3):
   `teamSidebar.emptyState` / `teamSidebar.errorState` sat on `List`s inside the team region's
   identified container and were never queryable, while the inner `teamSidebar.empty` /
   `teamSidebar.error` / `teamSidebar.retry` were. Removed rather than moved: the docs and the
   parity row now name the identifiers that actually resolve.

The repair for 8 and 9 is §14; the `docs/THIRD_PARTY_NOTICES.md` gap T32-AV raised as F1 is §9 there.

## 9. Tests added

`MattermostTests/T32-TeamSidebarTests.swift` — 42 tests:

- decode: `MMTeamUnread` (full row + missing counter), `MMTeamMembership`, `MMTeam` (with icon / with
  the key omitted), 
- initials ×2, badges ×4 (precedence, selected, cap + AX label, dot),
- ordering ×3 (`teams_order`, alphabetical, unknown/duplicate ids), preference parsing,
- membership ×4 (soft delete, other user's row, empty list fallback, deleted team),
- selection ×2 (by id, by name from a deep link), content state ×4 (0/1/2 teams, failure),
- view model ×7 (publish, no refetch on second appearance, retry after failure, stale counters,
  counter refresh without list refetch, failed counter refresh keeps numbers, **stale load cannot
  overwrite a newer one**, icon fetch rules),
- coordinator ×7 (default team, deep link wins, current team no-op, switch clears channel + stack,
  ten rapid switches → one subscription, no socket without a credential, previous team's events
  refused, post activity refreshes counters, sign-out closes the socket).

`MattermostUITests/MattermostUITests.swift` — +1 live test
(`testRealServerTeamRailShowsBothTeamsAndSwitchesBetweenThem`).

T32-R (repair, §14) — `MattermostUITests/T32-SidebarIdentifiersTests.swift`: 6 stub-backed UI tests,
one per content state plus the `sidebar=web` control, pinning the identifier contract in §14.1
(they fail on `108377a` and pass after the repair). Run them with
`bash scripts/t32r-sidebar-identifiers.sh`.

## 10. Decisions worth knowing

- **`/users/me/teams/unread` is never ETag-replayed.** A `304` there would pin badges to their
  first-frame numbers — exactly the staleness the card forbids. The teams list and memberships *are*
  ETag-conditional (they change rarely).
- **`myTeamMemberships()` filters on the signed-in user id**, not on "the endpoint asked for me": a row
  for somebody else must not vouch for a team (pinned by a test). With no user id known yet the rail
  falls back to `/users/me/teams`, which already means "my teams".
- **Icon bytes go through `APIClient`**, not `AsyncImage`: the endpoint needs `Authorization`, and a
  401 must reach the one re-auth path.
- **The socket is torn down on every auth transition** (`authPhaseChanged`) — a sign-out must not leave
  a socket running on a token that no longer exists.
- **Counters are refreshed, never the team list,** on socket activity.

## 11. Limits — not claimed

- **No channel list yet.** The rail fronts T30's placeholder list; S08's channel list/categories are
  T33. A team switch therefore lands on "No channel selected", not on that team's first channel.
- **No team-list refresh on `team_*` socket events.** A team created/renamed/joined while the app is
  open appears on the next load (the card asks for switch behaviour, not live membership edits).
- **`teams_order` is read, not written.** No drag-reorder in this card.
- **Reactions are refused by the scope** until the channel view resolves a post to its channel (T34).
- **The icon cache is memory-only** and keyed by update stamp; it is not written to disk.
- **No `990`-style badge ceiling difference:** the pill caps at `99+` like upstream, the accessible
  label keeps the true number.
- The live UI test needs the local server and the throwaway fixture account; on a host without them it
  skips rather than fails.

## 12. Files touched

New: `Mattermost/UI/Native/Sidebar/{TeamSwitchViewModel,TeamSocketScope,TeamSidebarCoordinator,TeamSidebarView}.swift`,
`MattermostTests/T32-TeamSidebarTests.swift`, `scripts/t32_team_seed.py`, `docs/t32-shots/`.

Modified: `Mattermost/Core/MM/MMEndpoints.swift`, `Mattermost/Core/MM/MMTypes.swift`,
`Mattermost/Core/MM/AuthSession.swift` (one `private` removed, with the rule stated),
`Mattermost/Core/Store/MMStoreModels.swift` (tolerant `MMTeam` decode),
`Mattermost/UI/Native/Auth/AuthCoordinator.swift` (+`userID(for:)`),
`Mattermost/UI/Native/NativePanePlaceholders.swift`, `Mattermost/MattermostApp.swift`,
`MattermostUITests/MattermostUITests.swift`.

T32-R (repair, §14) — new: `MattermostUITests/T32-SidebarIdentifiersTests.swift`,
`scripts/t32r-sidebar-identifiers.sh`, `docs/t32r-repair-note.md`; modified:
`Mattermost/UI/Native/NativePanePlaceholders.swift` (`NativeSidebarAnchorRow`),
`Mattermost/UI/Native/Sidebar/TeamSidebarView.swift` (empty/failure screens + the identifiers that
resolve), `build/uitest-server/mm_stub.py` (team fixtures), `docs/THIRD_PARTY_NOTICES.md` §9,
`docs/parity.md`, this note.

## 13. Reproduce

```sh
# fixture (idempotent; local throwaway server only)
python3 scripts/t32_team_seed.py --url http://127.0.0.1:8065 --mentions 2

# units
python3 scripts/qa-test.py --platform mac --label t32-units

# live rail test (iPad simulator; needs the fixture account)
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
TEST_RUNNER_MM_AUTH_SHOT_DIR=$PWD/t32-shots \
python3 scripts/qa-test.py --platform ios --sim DC3E9FB7-E4A0-4B24-8DBB-7960A059EC7A \
  --only-testing MattermostUITests/MattermostUITests/testRealServerTeamRailShowsBothTeamsAndSwitchesBetweenThem
```

Note: UI tests cannot run on **Mac Catalyst** on this host — the UI-test target's
`MACOSX_DEPLOYMENT_TARGET` (26.5, inherited from the SDK) is newer than macOS 26.3.1. That is
pre-existing and unrelated to this card; the iOS simulator destination is the supported one.

## 14. T32-R — the T32-AV repair (F1/F2/F3)

T32-AV returned **PASS-WITH-FINDINGS** on `108377a` and did not approve the `sidebar` flip. This
section records what the repair changed and what the audit added; the full evidence, commands and
transcripts are in `docs/t32r-repair-note.md` and the AV's verdict (attached to the review card).

### 14.1 The identifier contract after the repair

The pane exposes **two** stable identifiers, and both now resolve in every content state:

| Identifier | Names | Resolves |
|---|---|---|
| `nativeSidebar` | the pane itself (its anchor row: the server the pane belongs to) | every state, `sidebar=web` and `sidebar=native` |
| `nativeTeamSidebar` | T32's team region | every state with `sidebar=native` (must **not** exist with `sidebar=web`) |

The state screens are addressed by the identifiers that actually resolve:

| State | Identifiers |
|---|---|
| loading | `nativeSidebar`, `nativeTeamSidebar` (the pane content is drawn, never blanked) |
| one team (no rail) | `nativeSidebar`, `nativeTeamSidebar`, `sidebarCurrentTeam` |
| rail (2+ teams) | `nativeSidebar`, `nativeTeamSidebar`, `teamSidebar.rail`, `teamSidebar.team.<id>` |
| zero teams | `nativeSidebar`, `nativeTeamSidebar`, `teamSidebar.empty`, `teamSidebar.retry` |
| load failed | `nativeSidebar`, `nativeTeamSidebar`, `teamSidebar.error`, `teamSidebar.retry` |

`teamSidebar.emptyState` and `teamSidebar.errorState` are **gone**: they sat on `List`s inside the
identified team region and could never reach the accessibility tree (F3). Moving them would only
rename a dead identifier, so the container form was dropped and the table above is the contract.

### 14.2 What changed

- **F2** — `nativeSidebar` moved from the pane's `List` to a leaf row (`NativeSidebarAnchorRow`), and
  that row is now drawn by the team region's empty and failure screens as well. A leaf keeps its
  identifier no matter which container wraps it, so the one-team and loading states stop losing it.
  The empty/failure screens therefore also name their server (`Workspace` section), which is a fact
  the pane always has.
- **F3** — the dead container identifiers were removed; the build note and the parity row now name the
  identifiers that resolve, and `T32-SidebarIdentifiersTests` asserts each state is reachable.
- **F1** — `docs/THIRD_PARTY_NOTICES.md` §9 records T32's upstream read set (the same shape as §5–§8).
- **Tests** — `MattermostUITests/T32-SidebarIdentifiersTests.swift`: six UI tests, one per content
  state plus the flag-off control, run against deterministic stubs
  (`scripts/t32r-sidebar-identifiers.sh` starts them; `build/uitest-server/mm_stub.py` gained
  `--teams/--teams-delay/--teams-fail` and the `/users/me/teams*` endpoints).

### 14.3 What T32-AV closed, and what stays a limit

Closed by the audit (the implementer had listed these as untested, and they now have real-server
evidence — throwaway accounts, not fixtures):

- a **real 0-team account** reaches the empty state with upstream's copy, a retry and the web-view
  escape hatch, and gets no rail (their AVR2);
- a **real 1-team account** gets no rail, the correct current team and the pane's rows (their AVR3) —
  this is the state F2 broke, and it is now pinned by a stub test that fails on `108377a`.

Confirmed by the audit, and still limits rather than defects:

- **"Exactly one WebSocket" is not observable on this host.** The code holds one `SocketClient` and
  one pump task per server id, and the unit test pins `subscriptionCount == 1` / `connectCount == 1`
  for ten rapid switches, but `/proc/net/tcp` inside the server container cannot separate WebSocket
  connections from HTTP keep-alive (and the count grows per launch as `URLSession` pools). What the
  sampling does show: the count went flat across ten switches, i.e. switching opened no new
  connections. Recorded as evidence for the claim, not proof of "exactly one".
- **`channelTeams` has no writer anywhere in the tree** (`grep -rn channelTeams Mattermost/` finds only
  `TeamSocketScope.swift`). With a team selected and no channel open, `TeamSocketScope.accepts()`
  therefore matches only via `activeChannelID`, and on a team root that is `nil` — so *every*
  channel-scoped event is refused (counted in `refusedEventCount`) until T33 fills the directory.
  What that does **not** break: the per-team counter refresh is driven by the post events *before*
  the scope check (`TeamSidebarCoordinator.handle`), which is why the rail's badge did move live in
  T32-AV's AVR1. What it does mean: the refusal path has no live consumer to observe until T34, and
  the scope's `channelTeams` branch (`channelTeams[channelID] == teamID`) is unit-tested only.
- The rest of §11 stands unchanged (no channel list yet, no team-list refresh on `team_*` events,
  `teams_order` read-only, reactions refused, memory-only icon cache).
