# Build note — the lookup surfaces are native by default (`t_aa211ff6`, card `t_01afff4b`)

Card: **`t_01afff4b`** (`mmios-ios`), implementing §7-A of
`docs/t_aa211ff6-lookup-surface-defaults.md`. Date: 2026-11-02.
Base: `main` = `c70d949` (`t_a7432eab`'s F5′ tip; `t_6d420e01` and `t_a7432eab` both landed before
this run — the ordering `t_aa211ff6` §8 requires).
One commit: `feat(render): the lookup surfaces are native by default — search, saved+pinned and the
mentions inbox (t_aa211ff6)` = **`9ac0b73`** (plus the docs follow-up that records this note).

## 1. What changed, and what did not

| File | Change |
|---|---|
| `Mattermost/Core/RenderMode.swift` | `nativeApprovedSurfaces` five → **seven** (`.search`, `.activity` appended); the approval-ledger doc comment gains their two rows; the `case search` / `case activity` docs say what is true now. **`paneOwningSurfaces` (`[…, .channelView]`) and `paneHostSurface` (`.channelView`) are untouched** (§12.1, gate 6). |
| `MattermostTests/SurfaceModeResolverTests.swift` | exact-set literal 5 → 7 + doc comment naming both sign-offs; the "still web" loop is `.channelInfo` alone; the three tests that used `.search` as *the web-by-default surface* moved to `.channelInfo`; new pin `testTheLookupFlipIsApprovedByAVerdictsAndOwnsNoPane`. |
| `MattermostTests/ViewStoreTests.swift` | the second exact-set literal 5 → 7 (`testReleaseIsReachableOnlyThroughTheApprovedPaneOwner`), and its "approved but own no pane" list gains the two lookups — the release policy must still evict for `.channelView` only. |
| `Mattermost/UI/Native/Search/SearchView.swift`, `Mattermost/UI/Native/Activity/MentionsView.swift` | **header comments only** — the two files' "Until T3x-AV approves the flip the surface resolves `.web`" paragraphs would otherwise assert the pre-flip state. Verified: `git diff -U0` on both files contains no non-comment line. The note strings and their accessibility identifiers (`t_a7432eab`'s F5′) are untouched. |
| `docs/dual-render.md` | §3 tier 4 + the Release sentence; §4's `.search` row (the S26-drafts-is-T51's clause); §5's ledger table (the same two rows as the doc comment); §10's test-map rows; §11's "Native surfaces: seven", the DEBUG-only clause on the lookup gates, and the 2026-10-29 decision bullet rewritten as the post-flip statement. |
| `docs/parity.md` | T39 and T42 rows: "native ✅ … behind the flag" → **native by default since `t_aa211ff6`**, naming the verdict pairs; the two "Gated by `-surfaceMode …=native`" sentences become DEBUG-flag statements. |

Card deviation, stated: it names `SavedPinnedViews.swift`'s header as a third stale-comment site. On
`c70d949` that file's header never claimed a web default (its doc paragraph is about the shared list
body), and `grep -rn 'resolves \`\.web\`' Mattermost/` matched only `SearchView.swift` and
`MentionsView.swift`. Nothing was invented to match the card; the file is unchanged.

Two test sites the card did not list also had to move, both because they asserted the old default:

* `testUnknownPersistedOverrideIsDropped` seeded `"activity": "weirdMode"` and expected `.web` from
  the *dropped* row. It now expects `.activity` to take its approved default (`.native`) — the
  assertion is what proves the row was dropped, so it had to change with the flip.
* `testWebViewInstanceIsStableAcrossSurfaceToggles` toggled `.activity` native → web. After the flip
  the first write is a no-op (`setOverride` drops a row equal to the default), so the pair now uses
  `.channelInfo` and still moves the resolution both ways. The test pins the store, not the mode.

`testNativeByDefaultRequiresApproval`'s "an unapproved surface really is web" pin is `.channelInfo`
(the card says `.threads`, which `t_cdcc1f38` retired; `.channelInfo` is the only unapproved case and
the substitution `t_6d420e01` already made). It was not re-pointed at `.search` or `.activity`.

## 2. Acceptance, measured

Registry and pane ownership (`grep -n` on `Mattermost/Core/RenderMode.swift`):

```
111:    public static let nativeApprovedSurfaces: Set<Surface> = [.auth, .calls, .sidebar, .channelView, .composer, .search, .activity]
145:    public static let paneOwningSurfaces: Set<Surface> = [.channelView]
153:    public static let paneHostSurface: Surface = .channelView
```

**Dual-render gates, with the flag** (`bash scripts/verify-dual-render-gates.sh
--allow-approved-registry`, `build/logs/t01afff4b-gates-allow.log`) — all eleven gates green:

```
== 5. the -AV approval registry ==
  ok    nativeApprovedSurfaces is non-empty ([.auth, .calls, .sidebar, .channelView, .composer, .search, .activity]) — allowed by flag
== 6. pane ownership is a subset of the -AV approval registry ==
  ok    paneOwningSurfaces ['channelView'] is a subset of nativeApprovedSurfaces ['activity', 'auth', 'calls', 'channelView', 'composer', 'search', 'sidebar']
…
RESULT: PASS — dual-render debug affordances cannot reach a Release build.
```

**Without the flag** (`build/logs/t01afff4b-gates-noflag.log`): exactly one violation, and gate 6
still passes — the flag's meaning is "this commit *is* the approval", nothing else:

```
== 5. the -AV approval registry ==
  FAIL  nativeApprovedSurfaces is non-empty ([.auth, .calls, .sidebar, .channelView, .composer, .search, .activity]) without -AV evidence in this run; pass --allow-approved-registry when the approval commit is the subject
== 6. pane ownership is a subset of the -AV approval registry ==
  ok    paneOwningSurfaces ['channelView'] is a subset of nativeApprovedSurfaces […]
…
RESULT: FAIL — 1 dual-render gate violation(s).
```

**Unit target, both platforms** (`scripts/qa-test.py`, DEBUG):

| Target | Result | Log |
|---|---|---|
| `MattermostTests` (iOS, iPhone 16 Pro / iOS 18.3.1) | **1835 run / 8 skipped / 0 failed**, `** TEST SUCCEEDED **` | `build/logs/t01afff4b-units.log`, `build/logs/ios-20261102-172254.log` |
| `MattermostTests` (Mac Catalyst) | **1835 run / 9 skipped / 0 failed** | `build/logs/t01afff4b-units-catalyst.log`, `build/logs/mac-20261102-172713.log` |

The `1834` the two parent cards reported is the base; this card adds exactly one test
(`testTheLookupFlipIsApprovedByAVerdictsAndOwnsNoPane`). The one extra Catalyst skip is the iOS-only
auto-away test, as on every Catalyst run.

Note on the simulator: `--sim "name=iPhone 16 Pro"` no longer resolves on this host — two runtimes
carry that device name, so `xcodebuild` refuses the ambiguous destination (first attempt,
`build/logs/ios-20261102-171824.log`: rc=70 after 67 s, no test compiled). Every run in the table
above used `--sim "id=81A7F251-8B31-4945-8783-5A264C14B8D5"`. Recorded because that red came back as
`RESULT: FAIL` for a reason that is not this card.

**The new pins are load-bearing (mutation, not inspection).** Reverting the registry literal to the
five pre-flip entries and running `SurfaceModeResolverTests` + `ViewStoreTests` reds **6 assertions in
5 tests** (`build/logs/t01afff4b-mutant.log`, `build/logs/ios-20261102-172612.log`):

```
SurfaceModeResolverTests.swift:48   testOnlyTheApprovedRegistryDefaultsToNative
SurfaceModeResolverTests.swift:118  testTheLookupFlipIsApprovedByAVerdictsAndOwnsNoPane (.search)
SurfaceModeResolverTests.swift:121  testTheLookupFlipIsApprovedByAVerdictsAndOwnsNoPane (.activity)
SurfaceModeResolverTests.swift:209  testClearAllOverridesResetsEverySurface
SurfaceModeResolverTests.swift:223  testUnknownPersistedOverrideIsDropped
ViewStoreTests.swift:286            testReleaseIsReachableOnlyThroughTheApprovedPaneOwner
```

The literal was restored immediately; the green runs in the table above are post-restore.

**Greps** (`docs/dual-render.md` §5, §10 and the card's acceptance):

```
$ grep -rn 'resolves `\.web`' Mattermost/ MattermostTests/     → no match
$ grep -rn 'Until T39\|Until T42' Mattermost/                 → no match
$ grep -rn 'nativeApprovedSurfaces: Set<Surface>' Mattermost/ → seven entries (above)
$ grep -rn 'resolvedMode(for: \.search\|resolvedMode(for: \.activity\|defaultMode(for: …)' MattermostTests/ | grep -v '.native'
                                                              → no match (see below)
```

The one remaining `.web` next to `.activity` in the resolver suite is
`SurfaceModeResolverTests.swift:205  resolver.setOverride(.web, for: .activity)` — a *non-default*
override written so that `clearAllOverrides` has a row to clear; the assertion it supports expects
`.native`. It is the post-flip statement, not a pre-flip leftover.

## 3. Why the flip is legal here (restated from the decision, not re-decided)

`docs/dual-render.md` §5 asks each native-by-default entry for a passed paired `-AV` verdict.
`.search` has T39-AV **FAIL** → T39-R → **T55-AV-R `.search` PASS-WITH-FINDINGS** (+ T39-R2 on the
harness); `.activity` has T42-AV PASS-WITH-FINDINGS + T42-R. Neither validator deferred the flip,
unlike the 2026-10-27 workspace pair — so this commit is an approval commit, not an owner-policy
exception, and `--allow-approved-registry` is the audit signal §5 defines for it.

**One premise does not survive measurement, and it is reported rather than repeated.** §3 of the
decision closes with a `git log` proof that "the validated files are byte-identical on `main`"
(`634afd9..HEAD -- Mattermost/UI/Native/Search Mattermost/UI/Native/Activity` → *no commits*). On this
tree that range is not empty, and it was already not empty at the decision's own base `0922d55`:

```
$ git log --oneline 634afd9..0922d55 -- Mattermost/UI/Native/Search Mattermost/UI/Native/Activity
b0a339a fix(profiles): one bad id cannot cost a page its authors (t_70b41028)
8a81d2f fix(t8e): one row = one accessibility element, and the glyphs stop being VoiceOver stops
00cd217 feat(posts): the post options menu offers what v2.45.0 offers (t_37f27c09)

$ git log --oneline 5f90ea9..0922d55 -- Mattermost/UI/Native/Activity
00cd217 … / 3e1965e T44c … / c52ed17 feat(t43) …
```

(the decision's second command answers three commits, not the one it quotes). `5f90ea9` is not an
ancestor of `634afd9`, so the two ranges were measured off different branches — which is the likely
cause.

**What that means, stated plainly:** T55-AV-R audited `634afd9` (2026-10-27, its own note's §"Audit
target"), and the lookup files have moved since — `8c96531` (T5449-C2, 2026-10-29) re-shaped all
three row types (`searchResult.<id>`, `savedPosts.row.<id>`, `pinnedRows.row.<id>`) from `Button`s
into gesture containers carrying the author tap, `8a81d2f` (T8e) made a row one accessibility element,
`b0a339a` batched author resolution, `00cd217` added the shared post options menu, `81ef63c` dropped
`profileSurface:`, and `b2ccf56`/`53e6d7a` (F5′) rewrote the fallback copy. So "the verdict was issued
on exactly this code" is **not** true for the rows as they stand on `c70d949`.

This card does not re-adjudicate that: the card says do not re-decide, and the decision's own rule is
that a red ship-shaped measurement *is* the `-AV` round the flip must carry. What is recorded here is
the premise's current state so `t_636e6483` — and the architect, if it returns red — works from the
tree and not from the 2026-10-27 snapshot. Two facts bound the exposure, neither of which substitutes
for that measurement: the row re-shape was itself adversarially validated (C2-AV `t_0c520c78`:
units 1796 / 8 skipped / 0 failed, live 4/0/0, regressions 10/0/0 and 11/0/0, gates PASS), and the
QA card's §4 explicitly opens a row's options menu — `00cd217`'s surface — in both lookups.

If the reviewers would rather bind the flip to a fresh paired `-AV` on the current rows, that is a
board decision for the architect; the flip itself remains one literal and one revert.

## 4. What this commit does **not** claim

* **No Release build was run here.** Both verdicts were issued with `-surfaceMode …=native`; the
  shipped configuration (a Release build with `app.launchArguments = []`) is the sibling QA card
  **`t_636e6483`** — `mmios-qa`, "what a reader sees on a Release build with no flags — five tabs,
  three real lookup screens". It is the ship-shaped measurement §7-B defines and this commit is not
  done-done until it is green.
* **No UI suite was run for this card.** The existing live suites still pass their own `-surfaceMode`
  flags (`T39SearchUITests`, `T42ActivityUITests`, `TA7432FallbackCopyUITests` with `search=web` /
  `activity=web` for the DEBUG notes), and `TA7432FallbackCopyUITests` remains the only test of the
  fallback copy — none of them asserts the default configuration.
* **No copy, identifier, release-policy, `paneOwningSurfaces` or debug-tier change.** Each is a
  deliberate non-change (`docs/dual-render.md` §12.1, gate 6).
* **CI covers the units, not the UI.** The push of `9ac0b73` to `origin/main` ran release run
  **41421471596**, all five jobs green: `guard (tip + change scope)`, `test (catalyst)`,
  `test (ios-simulator)`, `tag and publish`, `package Mattermost.app`. CI does not run the XCUITest
  suites (`docs/t_39ea6115-build-note.md` §10), so the live-suite evidence belongs to `t_636e6483`.

## 5. Hotspot

`MattermostTests/SurfaceModeResolverTests.swift` was the third card in sequence on this file
(`t_cdcc1f38` retired `.threads` at `a57fe67`, `t_6d420e01` retired `settings`/`plugins`/`profile` at
`81ef63c`, this flip) and is the suite §8.5 of the dispositions doc called out. `.channelInfo` is now
the only unapproved-surface name in it, so the next flip-shaped card has one substitution, not two.
