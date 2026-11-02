# `t_6d420e01` — the surface catalogue is eight switch keys

Card: **`t_6d420e01`**, implementing `docs/t_39ea6115-surface-catalogue-dispositions.md` (the card body
names this file `docs/t_39ea6115-build-note.md`, so the note for the implementation lives under the
decision's id; the title above keeps the implementing card).
Base: local `main` **`c4f199a`** (= live `origin/main` when the run started). No product behaviour was
changed for a user who never passes a debug flag: three *debug switch keys* stopped existing, one
predicate lost a parameter that was already being discarded, and the tests/docs that named them now
name what is true instead.

| # | What the dispositions doc decided | What this card did |
|---|---|---|
| 1 | `.settings` is shell chrome, not a render region | case removed; the shell's `SettingsView` is untouched and still presents in every pane mode |
| 2 | `.plugins` has no host and no switch (it can never legally be `native`) | case removed; S29–S32 stay web by decision, as before |
| 3 | `.profile` is a sub-region of the row that draws a post, not a surface | case removed **and** `ProfilePopoverPolicy.offersAuthorTap(rowHost:profileSurface:)` → `offersAuthorTap(rowHost:)` |
| 4 | a `Surface` case must be a real switch (a production call site **and** a mode that changes a screen) | `SurfaceDefaults.unhostedSurfaces` is now `[]`; gate 11's `UNHOSTED_PIN` is `set()` |
| 5 | retired keys must stop round-tripping | `-surfaceMode settings=native` and a stored `"settings"` row both decode to nothing, pinned by tests |
| 6 | the catalogue is additive: no reuse, no renames | the remaining eight raw strings are byte-identical; nothing was repurposed for the retired names |

Eleven cases → **eight**: `auth`, `sidebar`, `channelView`, `composer`, `search`, `activity`,
`channelInfo`, `calls`.

---

## 1. Why these three, in one sentence each

The rule the doc applies (`§1.1`) is that a key must be a **switch**, not merely a string a call site
reads:

* **`.settings`** — the shell's settings are a native SwiftUI `SettingsView` presented unconditionally
  (`RootView.swift`), and the web app's settings modal has no host of its own. Flipping the key changed
  nothing in either direction.
* **`.plugins`** — S29–S32 are permanently web by decision (`docs/dual-render.md` §1), so `native` was
  not a legal state for the key: a one-state key is a constant, not a switch.
* **`.profile`** — the profile sheet is anchored in the view that draws the post row, so it inherits
  that view's mode; the case was passed to `ProfilePopoverPolicy` and **discarded**, which is exactly
  how the T41 regression survived a truth table that “proved” the tap (gate 11 measures references, not
  effect — its own honest limit, now stated with the retirement as the reason it exists).

`.threads` was retired earlier by the same rule (`t_7ffa9e76`); the catalogue test now covers all four
retirements in one place.

## 2. The code

| file | change |
|---|---|
| `Mattermost/Core/RenderMode.swift` | three cases removed from `Surface` (+ their `title` arms); the doc block above `Surface` now states the switch rule; `SurfaceDefaults.unhostedSurfaces = []` with the reservation note rewritten; `ProfilePopoverPolicy` takes **one** parameter |
| `Mattermost/UI/Native/Channel/ChannelView.swift` | passes only the row host |
| `Mattermost/UI/Native/Thread/ThreadView.swift` | `ProfilePopoverPolicy.offersAuthorTap(rowHost: .native)` — the thread rows are drawn natively, so the host is a fact, not a resolver read |
| `Mattermost/UI/Native/Search/SearchView.swift`, `Search/SavedPinnedViews.swift`, `Activity/MentionsView.swift` | the row host is each list's own surface resolution; comments no longer mention a `.profile` read |
| `scripts/verify-dual-render-gates.sh` | gate 11's `UNHOSTED_PIN = set()` and its header/limit text rewritten for a catalogue with no reservations |

`ProfilePopoverPolicy` before → after:

```swift
// before: the second parameter existed only to pin a discarded answer
static func offersAuthorTap(rowHost: SurfaceRenderMode,
                            profileSurface: SurfaceRenderMode) -> Bool
// after
static func offersAuthorTap(rowHost: SurfaceRenderMode) -> Bool
```

The four-cell truth table became two rows (`native → offered`, `web → not offered`). The `native × web`
cell the old table pinned is now **unrepresentable**, which is the point: there is no flag left that
could remove the tap from a natively drawn row. The live statement ("no such flag exists") is still
made against a running app — `T429ProfileTapUITests` launches on the shipped defaults with no
`-surfaceMode profile=` anywhere.

## 3. Retired keys stop round-tripping

`Surface(rawValue:)` returns `nil` for `settings` / `plugins` / `profile`, so:

* `-surfaceMode settings=native` parses to **no override** (the launcher's parse loop drops an unknown
  key rather than failing the launch);
* a stored `"settings"` row in the persisted override map decodes to **no override** and is skipped by
  the inspector (`Surface.allCases` no longer names it).

Both are pinned in `MattermostTests/SurfaceModeResolverTests.swift`:
`testTheThreeRetiredSurfaceRawValuesDoNotRoundTrip` and `testStaleRowsForTheThreeRetiredKeysAreDropped`.
The catalogue pin is now `testCataloguePinsTheEightContractSurfaces` (renamed from `…TheEleven…`), and
the "everything else stays web" loop is `[.channelInfo]` only — `.search`/`.activity` are deliberately
left out because `t_aa211ff6` flips both to native-by-default in its own commit, and asserting them
`web` here would invert the moment that lands.

## 4. Verification (what was actually run)

All runs on this host, iOS simulator `iPhone 16 Pro` / iOS 18.3 (`81A7F251-8B31-4945-8783-5A264C14B8D5`),
fixture server `http://127.0.0.1:8065` (Mattermost 9.11.19, `scripts/perf_seed.py` account).

| gate | command | result |
|---|---|---|
| whole `MattermostTests` target (iOS) | `qa-test.py --platform ios --only-testing MattermostTests` | **1834 run / 8 skipped / 0 failed**, `TEST SUCCEEDED` (`build/logs/t6d420e01-units-r2.log`) — `main` at `c4f199a` was **1833** (`docs/t_10d3db63-build-note.md`), this card added 2 tests and removed 1 (`T5449ProfileHostPolicyTests.testTheProfileSurfaceIsNeverConsulted`), net +1 |
| whole `MattermostTests` target (Catalyst) | `qa-test.py --platform mac --only-testing MattermostTests` | **1834 run / 9 skipped / 0 failed**, `TEST SUCCEEDED` (`build/logs/t6d420e01-units-catalyst.log`) — the one extra skip is the iOS-only auto-away test, as on every Catalyst run |
| gate 11 + the rest | `bash scripts/verify-dual-render-gates.sh --allow-approved-registry --allow-unhosted-change` | **`RESULT: PASS`**, `all 8 Surface case(s) are consulted, or declared unhosted` (`build/logs/t6d420e01-gate-final.log`) |
| the pin change is load-bearing | copy of the script with the *old* `UNHOSTED_PIN = {'settings', 'plugins'}` | **RED without the flag** (gate 11 fails: the empty literal does not match its pin), **GREEN with `--allow-unhosted-change`** (`build/logs/t6d420e01-pinprobe-nored.log`, `…-red.log`) — i.e. emptying the reservation set is the deliberate act the flag exists for, not a silent edit |
| `T41ProfileUITests` + `T429ProfileTapUITests` | `qa-test.py --only-testing …/T41ProfileUITests --only-testing …/T429ProfileTapUITests` | **11 run / 0 skipped / 0 failed** (`build/logs/t6d420e01-ui-t41-t429.log`); `T429ProfileTapUITests` re-run alone after its header comment was rewritten — **4 run / 0 skipped / 0 failed** (`build/logs/t6d420e01-ui-t429-final.log`) |
| `T45AvatarUITests` | `qa-test.py --only-testing …/T45AvatarUITests` | **red — and red at `HEAD` too, for the fixture's size, not for this card** (`build/logs/t6d420e01-ui-live.log` on this tree, `build/logs/t6d420e01-t45-head-baseline.log` from a detached `c4f199a` worktree): both stop at *“the sidebar must list the chosen channel”* for the same id `46rf536iki8pfqqyc7i11ff8er` |

### 4.1 Why T45 cannot be green on this fixture, stated with numbers

`T45AvatarUITests` picks “the open channel with the fewest posts whose newest author has a picture”
and walks the sidebar to it. This server's probe account is in **352 channels** on team `Perf`, of
which **351** are the T8G probes, drawn as eight custom categories of ~40 rows each. The pick —
`T34 Fold` — is rank **9** alphabetically but sits **below** all eight T8G categories in the rendered
tree, thousands of points down a `LazyVStack`; the test's bounded walk (five swipes each way, as a
person would) never reaches it. Measured by `scripts/t6d420e01_sidebar_probe.py`.

This is the same hazard `docs/t_8f9f5449-c3-build-note.md` §3 records for `T44DCallsUITests`
(“the account is in 351 channels, so `revealSidebarRow` never reaches that row”), and it was proved
here rather than assumed: the **baseline run of the unchanged tree** fails identically, so this card is
not the cause. What T45 exists to prove — the running app sends `GET /api/v4/users/{id}/image`
authenticated and puts the bytes on screen — is unchanged by this card (only its comment changed), and
its last green record is `docs/t45-avatars-build-note.md` (1 run / 0 failed) on the smaller fixture that
predates the T8G probes.

## 5. Two things the runs measured that this card did **not** change

Both are recorded because the alternative was a green-looking claim, and both are the kind of thing
that turns into a phantom “regression” on the next card.

### 5.1 `T41ProfileUITests` was order-dependent, and the server is why

The first suite run failed `testMyOwnPresenceFollowsTheSocketImmediately` with the row reading
**“Do not disturb until 11:54 AM”** while the server said `dnd` — the assertion compared the label to
`"Do not disturb"` exactly. The cause is upstream of this card: `testChoosingDoNotDisturbReachesTheServer`
runs first (alphabetically) and chooses DND **through the app**, which writes a `dnd_end_time` about
twenty minutes out; `PUT /users/{id}/status` **never clears that field** on a later write. Measured
with `scripts/t6d420e01_dnd_probe.py`:

```
start                              : ('away', 0, False)
dnd + end=+20min                   : ('dnd', 1793591930810, True)
online, field omitted              : ('online', 1793591930810, False)
online, end=0                      : ('online', 1793591930810, False)
online, end=null                   : ('online', 1793591930810, False)
```

So the DND test cannot restore the fixture, the row honestly renders the clock it was given, and the
socket test — whose subject is “did `status_change` land inside one two-minute poll interval” — now
asserts `label.hasPrefix("Do not disturb")`. In isolation the test passed with the old assertion too
(`build/logs/t6d420e01-ui-socket-solo.log`, 1 run / 0 failed), which is exactly why the suite run, not
the solo run, is the one that counts.

### 5.2 The T45 sidebar depth (above)

Already tracked as **`t_c941e3d3`** (assignee `mmios-qa`; `docs/t_7ffa9e76-build-note.md:211` names it as
“the live-fixture sidebar drift: 351 joined channels push the …”, with the repair being a fixture or a
shared scroll helper). This card does not touch it; T45 is listed red here so the next card does not read
this run as a T45 regression.

## 6. Files

```
 Mattermost/Core/RenderMode.swift                     | 112 ++++++-------
 Mattermost/UI/Native/Activity/MentionsView.swift     |  13 +-
 Mattermost/UI/Native/Channel/ChannelView.swift       |  14 +-
 Mattermost/UI/Native/Search/SavedPinnedViews.swift   |   8 +-
 Mattermost/UI/Native/Search/SearchView.swift         |  15 +-
 Mattermost/UI/Native/Thread/ThreadView.swift         |  15 +-
 MattermostTests/SurfaceModeResolverTests.swift       | 118 +++++++----
 MattermostTests/T429ProfileTapTests.swift            |  49 ++---
 MattermostTests/T5449ProfileHostPolicyTests.swift    |  83 +++-----
 MattermostUITests/T41ProfileUITests.swift            |  10 +-
 MattermostUITests/T429ProfileTapUITests.swift        |   4 +-
 MattermostUITests/T45AvatarUITests.swift             |   8 +-
 MattermostUITests/T5449ListProfileUITests.swift      |   5 +-
 MattermostUITests/T5449ThreadProfileUITests.swift    |   5 +-
 docs/dual-render.md                                  |  86 +++++----
 docs/parity.md                                       |   2 +-
 scripts/verify-dual-render-gates.sh                  |  27 ++--
 new: scripts/t6d420e01_dnd_probe.py                  (the §5.1 measurement, cited by the test)
 new: scripts/t6d420e01_sidebar_probe.py              (the §4.1 measurement)
```

UI-test launch lines lost `-surfaceMode profile=native`: `T41ProfileUITests`,
`T45AvatarUITests`, `T429ProfileTapUITests`, `T5449ListProfileUITests`, `T5449ThreadProfileUITests`.
Every one of them strips their own switch — the tap on a native row must be offered with **no** flag,
or the test would be passing because of a key that no longer exists.

Docs: `docs/dual-render.md` (eight switch keys, the switch-vs-sub-region rule, the mapping table without
`profile`/`settings` rows, the retired-cases paragraph, the release-condition row “7 of the 8 surfaces
have no pane host today”) and the T41 row of `docs/parity.md` (“**Not gated:** the sheet belongs to the
view that draws the row… no `profile=` launch flag exists any more”).

## 7. Honest limits

* The `T45AvatarUITests` gap above is **not** parity work: the behaviour it asserts was green when the
  fixture was small, is unchanged by this card, and cannot be re-measured on this server until the 351
  T8G channels are archived or a second fixture account is used.
* Nothing here was exercised in CI: local `xcodebuild test` only. The card does not change
  `.github/`, so the `guard` job's change-scope rule is unaffected.
* Retiring the keys means a user who had persisted `"profile"`/`"settings"`/`"plugins"` rows silently
  loses them — which is the intended behaviour (the rows were inert) and is why they are *not* reused
  for any new region.

## 8. Landed

| what | where |
|---|---|
| `refactor(dual-render): the catalogue is eight switch keys …` | `81ef63c` on `main` (`origin/main`) |
| `docs(core): launchSurface counts the eight surface raw values, not twelve` | `61ba0d0` on `main` — the one stale count the grep for “11”/“12” found outside the docs (`Core/SurfaceModeResolver.swift:287`) |
| CI, `release` workflow on the final code tip `61ba0d0` | GitHub Actions run **41386810410** — **all jobs green**: `guard (tip + change scope)`, `test (catalyst)`, `test (ios-simulator)` (which runs `MattermostTests` only), `tag and publish`, `package Mattermost.app` |
| earlier run on `81ef63c` | run **41386689983**, also all green — the two tips differ by that one comment line |

This section was written by the docs commits that follow those two (one records the run, the next moves
this note to the path the card body names), so their own runs are not part of the record above; the
tested code tip is `61ba0d0`.

