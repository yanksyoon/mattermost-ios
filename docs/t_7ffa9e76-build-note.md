# Build note — `Surface.threads` retired, and dual-render gate 11 (card `t_cdcc1f38`)

Decision of record: `docs/t_7ffa9e76-threads-surface-retirement.md` (card `t_7ffa9e76`, commit
`e1c5412`). Harness contract: `docs/dual-render.md`. This card implements §4 and §6 of that spec; it
re-decides nothing.

Tree: branch `t_cdcc1f38`, fast-forwarded onto `e59e11a` (`main`) before the first build — the C3
slice the steward flagged as missing. Host: MacBook-Pro-6.local, Xcode simulator `iPhone 16 Pro`
runtime `OS=18.3.1`, fixture server `http://127.0.0.1:8065` (9.11.19).

**Commit: `a57fe67`** — the retirement, gate 11, the unit/UI test edits and `docs/dual-render.md` in
one commit (the spec's requirement, so the gate is never red on `main`); this note is the small
follow-up commit that records it.

## 1. What shipped

One commit, as the spec requires (a gate added before the retirement would be red on `main`, a gate
added after would be a promise):

| File | Change |
|---|---|
| `Mattermost/Core/RenderMode.swift` | `case threads` + its `title` arm deleted (catalogue 12 → 11); the enum's doc comment gains the sub-region rule; `paneHostAlias`'s "the 12 surfaces" → "the 11"; **new** `SurfaceDefaults.unhostedSurfaces: Set<Surface> = [.settings, .plugins]` with the reservation/gate documentation. |
| `scripts/verify-dual-render-gates.sh` | section `== 11.` + its header bullet + `--allow-unhosted-change` in the usage line and the flag parser. |
| `MattermostTests/SurfaceModeResolverTests.swift` | 42 `.threads` → `.channelInfo` (`.search` in the two functions that already assert `.channelInfo`); `…TheTwelve…` → `…TheEleven…` with the `.threads` row dropped; an exact-count assertion; two new pins (§1.3). The acceptance grep `grep -rn "\.threads" MattermostTests/SurfaceModeResolverTests.swift` returns **0**. |
| `MattermostUITests/T31WebSessionHarvestUITests.swift` | `"-surfaceMode", "threads=native"` dropped from the launch line (a no-op before, an unknown key after). |
| `docs/dual-render.md` | §2 "11 switch keys" + `unhostedSurfaces` named in the pieces table; §4 count, the `threads` row removed (S13 folded into `channelView` as a **sub-region**), the retirement paragraph now describes the code, a new paragraph on `unhostedSurfaces`; §10 test-map rows (Eleven + the two retired-key pins); §11 bullet rewritten to the measured, landed state; §12.7's two stale counts. |
| `docs/parity.md` | **verified, not edited** — the T36 status cell placed by `t_7ffa9e76` ("there is **no** `threads` switch … the thread pane is a sub-region of the pane host and inherits its mode") reads correctly against the landed code. |

`docs/component-map.md` §5 S13 keeps its row (`### S13 Thread RHS + global threads — native (T36)`) —
the *screen* is unchanged; only the switch key it never owned is gone. Spec §4.5 predicted this; no
edit made.

No gate was added to `ThreadPaneContent`, `GlobalThreadsPaneContent` or `NativeThreadsPaneView`. The
`threads=` spelling is gone from `MattermostUITests/` entirely (`grep -rn "threads=" MattermostUITests/`
→ no output) and `T36-ThreadsUITests.swift` is untouched: its launch line (`shell`, `auth`, `sidebar`,
`composer`, no `threads` flag) is exactly the absence the spec §2.5 calls the point.

### 1.1 The trap, respected

32 production `.threads` hits remain, and **none** of them is a surface:

* `NativeTab.threads` / `location.pane == .threads` (`Core/Native/NativeNavigation.swift`,
  `UI/Native/NativeShellView.swift:222,224,282`, `UI/RootView.swift:196`,
  `UI/Native/Channel/Sidebar/…`, `MattermostTests/NativeNavigationTests.swift`) — the shell's **route**
  enum, untouched;
* `page.threads` / `list.threads` / `ThreadTotals.threads` (`Core/MM/MMThreadTypes.swift:136-149`,
  `UI/Native/Thread/*ViewModel.swift`, `UI/Native/Activity/ActivityService.swift:121`) — the **API**
  payload, untouched.

Three doc comments still spell `resolvedMode(for: .threads)` (`UI/Native/Thread/ThreadView.swift:59`,
`Core/RenderMode.swift:199`, `MattermostTests/T5449ProfileHostPolicyTests.swift:12`). They are
historical statements ("nothing in `Mattermost/` consulted it") and remain true; the comments already
cite the retirement. Gate 11 skips comment lines, so they cannot mask a future read.

### 1.2 Gate 11 — the predicate as landed

Same shape as gate 5: a case is **consulted** when `Mattermost/` (outside `Core/RenderMode.swift`)
contains `resolvedMode(for: .<case>)`, `SurfaceHost(.<case` or `defaultMode(for: .<case>)`, or when the
case **is** `SurfaceDefaults.paneHostSurface`'s value (`.channelView`, whose three call sites read the
constant); otherwise it must be declared in `SurfaceDefaults.unhostedSurfaces`, whose literal is pinned
to `[.settings, .plugins]` unless `--allow-unhosted-change` is passed. The section's own comment states
the honest limit: it measures **references**, not effect, so `.profile` (read and discarded by
`ProfilePopoverPolicy`) passes — that class is `t_9d0b0e11`'s.

Output of the acceptance run (`build/logs/t_cdcc1f38-gates1.log`, exit 0):

```
== 11. every Surface case is consulted, or declared unhosted ==
  ok    unhostedSurfaces is exactly [.settings, .plugins] — the pinned declaration
  ok    .auth         consulted at Mattermost/UI/Native/Auth/LoginView.swift:47
  ok    .sidebar      consulted at Mattermost/UI/Native/NativePanePlaceholders.swift:43
  ok    .channelView  consulted at SurfaceDefaults.paneHostSurface (Mattermost/Core/RenderMode.swift; three call sites read the constant)
  ok    .composer     consulted at Mattermost/UI/Native/Channel/ChannelView.swift:754
  ok    .search       consulted at Mattermost/UI/Native/Channel/ChannelView.swift:1028
  ok    .profile      consulted at Mattermost/UI/Native/Activity/MentionsView.swift:93
  ok    .activity     consulted at Mattermost/UI/Native/Activity/MentionsView.swift:32
  ok    .settings     declared unhosted
  ok    .channelInfo  consulted at Mattermost/UI/Native/Channel/ChannelView.swift:1001
  ok    .calls        consulted at Mattermost/UI/Native/Channel/ChannelView.swift:1041
  ok    .plugins      declared unhosted
  ok    all 11 Surface case(s) are consulted, or declared unhosted

RESULT: PASS — dual-render debug affordances cannot reach a Release build.
```

Gates 1–10 stay green in the same run (36 `ok` lines, 0 `FAIL`). Measured, not asserted — two
mutations on the working tree, each reverted afterwards:

* **an extra declared key** (`unhostedSurfaces = [.settings, .plugins, .search]`): without the flag
  `FAIL unhostedSurfaces is [.settings, .plugins, .search], not the pinned [plugins, settings] …`,
  `RESULT: FAIL — 1 … violation(s)`; with `--allow-unhosted-change`: `RESULT: PASS`, and the line
  reads `allowed by --allow-unhosted-change (pinned set is ['plugins', 'settings'])`;
* **a case nobody consults** (`case zzz` added to the enum): `FAIL .zzz neither consulted nor declared
  unhosted — a catalogue key with no effect …`, `RESULT: FAIL`.

The `unhostedSurfaces` literal is what makes the follow-up visible: `t_6d420e01` retires `.settings`,
`.plugins` and `.profile`, and will have to pass `--allow-unhosted-change` to empty the set.

### 1.3 The unit target

`python3 scripts/qa-test.py --platform ios --sim "name=iPhone 16 Pro,OS=18.3.1"
--only-testing MattermostTests` → `build/logs/t_cdcc1f38-units-final.log`:

```
Executed 1830 tests, with 8 tests skipped and 0 failures (0 unexpected) in 39.357 (40.391) seconds
** TEST SUCCEEDED **
```

(`build/logs/t_cdcc1f38-units-final.log`, on the rebased tip; `t_cdcc1f38-units2.log` is the same run
before the rebase onto `679b05f` — identical counts, 40.4 s.)

1830 = C3's landed 1828 + this card's 2 new pins. (`testRetiredSurfaceRawValueDoesNotRoundTrip`,
`testRetiredPersistedOverrideIsDropped`.) Note the first run of this card, `t_cdcc1f38-units1.log`,
failed to **compile**: the `.threads → .channelInfo` substitution in
`testTheWorkspaceFlipApprovesBothSurfacesAndOnlyThePaneHostOwnsThePane` left an untyped array literal
(`[.search, .profile, …]`) — the removed element had been the only `Surface.`-qualified one. Fixed by
keeping `Surface.search` as the typed first element; the run above is the post-fix one.

## 2. The live suites — measured, and red **before** this card

Both suites are red on this host. Neither red is caused by this change, and that is measured rather
than argued: the same suites were run against a detached worktree of **`e59e11a`** (the parent C3 tip,
no changes of this card) with the same simulator, fixture and credentials. Those two base logs are
copied into this worktree (`build/logs/base-t36.log`, `build/logs/base-t31.log`) so the comparison
survives with the branch — `build/` is gitignored.

| suite | this tree (`t_cdcc1f38`) | base (`e59e11a`) |
|---|---|---|
| `MattermostUITests/T36ThreadsUITests` | 5 run / 0 skipped / **10 failed**, 275.7 s — `build/logs/t_cdcc1f38-t36a.log` | 5 run / 0 skipped / **10 failed**, 278.7 s — `build/logs/base-t36.log` |
| `MattermostUITests/T31WebSessionHarvestUITests` | 2 run / **1 failed**, 72.9 s — `build/logs/t_cdcc1f38-t31.log` | 2 run / **1 failed**, 72.0 s — `build/logs/base-t31.log` |

The failing test names are identical in both runs (T36: all five; T31:
`testAWebviewOnlySessionRendersTheNativeWorkspaceWithoutSigningInAgain`), and so is every assertion
line number.

### 2.1 Why T36 is red — the fixture outgrew the sidebar

Every T36 test stops at its first step, `openChannel`:
`XCTAssertTrue failed - the sidebar must list channel psw97y5zqpfnpembwxraizuije` (line 793).
The channel exists and the account is a member: measured through the API
(`/api/v4/users/me/teams/{id}/channels`, `/channels/members`), `t36-threads` is present at index 11 of
**351** joined channels of team `perf`.

What the native sidebar draws is a lazy window, and its measured content is not the T36 channel. From
the app's accessibility dump inside the failure (`build/logs/t_cdcc1f38-t36a.log` lines 336-352 and
the later dumps): `channelSidebar.scroll` holds an element **5096 pt** tall inside an **874 pt**
viewport, and the 24 distinct drawn rows are all `T8G probe 00xx` channels
(`T8G probe 0071` → `0 080`, `0061` → `0070`, `0051` → `0054`). `psw97y5zqpfnpembwxraizuije` is not
among them, and the test does not scroll the channel sidebar — it waits 40 s for the row and taps it.

So the suite's own assumption ("the fixture channel is above the fold") was true when it last ran green
(2026-10-25, `docs/t36-build-note.md` §7) and is false now that ~350 probe channels exist on this server.
The same class already blocks `T44DCallsUITests` (C3's `t_dc0ea74d` records the identical sidebar stop).

**This card does not "fix" it**, for two reasons: the card's acceptance asks for the suite **unchanged**
(and a scroll-the-sidebar step is a change), and the honest repair is a fixture/test-harness decision —
either a clean login account whose sidebar holds the suite's channel, or a scroll helper shared by the
live suites. That is filed as a follow-up card for `mmios-qa` (see §5) with these logs.

The T36 assertions about the *thread pane* are therefore **not exercised on this host in this run** —
stated, not glossed. Nothing about the retirement can change them: the suite's launch line never had a
`threads` flag, and `ThreadPaneContent` gained no gate.

### 2.2 Why T31 is red — pre-existing, same on base

`testAWebviewOnlySessionRendersTheNativeWorkspaceWithoutSigningInAgain` fails at its first assertion
(line 84): `nativeShell` never appears within 60 s on a launch whose only credential is the seeded
webview cookie. The control test (`…StillAsksForSignIn`) passes in both runs, so the app is up and the
launch path is exercised; only the cookie-harvest launch does not reach the shell. Identical on
`e59e11a`, so it is not this card's — and this card's one edit to that file (removing the `threads=native`
pair) cannot reach it: `SurfaceModeResolver.parseLaunchOverrides` consumes `-surfaceMode` + value pairs
and drops an unknown surface on its own, which `testUnknownSurfaceIsRejected` already pins. It is part
of the follow-up card, not silently dropped.

## 3. Docs kept in step

`docs/dual-render.md`:

* §2 pieces table: "the 11 switch keys", `unhostedSurfaces` named.
* §4: "The 11 switch keys …"; the `threads` row is **gone**; S13 folded into the `channelView` row as
  a sub-region; the retirement paragraph now describes the landed code and states the no-gate contract
  for the three thread views; a new paragraph states what an unconsulted case must do (declare itself
  in `unhostedSurfaces`, pinned literal, `--allow-unhosted-change`). The retired-surface amendment
  itself (spec §7) was already in this paragraph from `t_7ffa9e76` and is unchanged.
* §10: catalogue test renamed to `…Eleven…`, plus a row for the two retired-key pins.
* §11: the four-inert-cases bullet rewritten to the landed state — the case is gone, the pane keeps
  drawing, `.settings`/`.plugins` are declared today and retired by `t_6d420e01`, gate 11 is live and
  its limit (references, not effect) is stated.
* §12.7: the two remaining stale catalogue counts ("11 of the 12 surfaces", "the 12 surfaces are
  regions of one web app") corrected to the 11-case catalogue.

`docs/parity.md` T36: verified unchanged and correct (§1).

## 4. Honest limits of this card

* **T36's live evidence is not refreshed.** The suite is unchanged and red on this host before and
  after (base run in §2). The retirement removes nothing the suite asserts — the case was never read —
  but a reviewer should read "T36 4/4 green" as 2026-10-25 evidence, not as a run from this card.
  The spec's own local discrepancy stands: the file declares **five** `func test…` (l. 93, 194, 263,
  299, 401) while the recorded green run is 4/4.
* **T31's harvest test is red on base too**, so "unaffected" here means "byte-identical result to
  `e59e11a`", not "green".
* Gate 11's limit is real: `.profile` passes while `ProfilePopoverPolicy` discards the value. That is
  by design (`t_9d0b0e11` owns the fix).
* The gate and the retirement had to land together; this commit is that unit. A cherry-pick of the
  retirement alone leaves gate 11 red on the enum it no longer has, and a cherry-pick of the gate alone
  is red on `main` — both are stated in the section comment.

## 5. Follow-ups filed

* `t_c941e3d3` (assignee `mmios-qa`) — the live-fixture sidebar drift: 351 joined channels push the
  suites' own channels out of the drawn window, reddening T36 (5/5), T31 (1/2) and T44D (2/2) on
  `e59e11a` itself. Carries both base logs and the drawn-row measurement.

Already open and untouched here: `t_6d420e01` (retire `.settings`/`.plugins`/`.profile`, empty
`unhostedSurfaces`, `--allow-unhosted-change`), `t_9d0b0e11` (the read-and-discarded class),
`t_dc0ea74d` (the pushed-profile host).

## 6. How to run

```
bash scripts/verify-dual-render-gates.sh --allow-approved-registry

python3 scripts/qa-test.py --platform ios --sim "name=iPhone 16 Pro,OS=18.3.1" \
  --only-testing MattermostTests

TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<scripts/perf_seed.py> \
  python3 scripts/qa-test.py --platform ios --sim "name=iPhone 16 Pro,OS=18.3.1" \
  --only-testing MattermostUITests/T36ThreadsUITests
```

`--sim` must pin the runtime (`name=iPhone 16 Pro,OS=18.3.1`); a bare name resolves against the latest
runtime, where this device does not exist. `build/logs/` is gitignored — the log names above are the
runs this note cites.

## 7. Independent re-verification (resumed run, 2026-10-30 13:20–14:05)

The session that wrote §1–§6 was reclaimed by the dispatcher before it could record anything on the
board, so this section states what a **second** session re-measured on the landed tip
`79e1c9d` (== `origin/main`), and what it deliberately did **not** re-run.

| Check | Result | Evidence |
|---|---|---|
| `bash scripts/verify-dual-render-gates.sh --allow-approved-registry` | **PASS**; §11 green at **11** cases, first line `unhostedSurfaces is exactly [.settings, .plugins] — the pinned declaration`, exactly the §1.2 output | run live on `79e1c9d` |
| whole unit target | **1830 run / 8 skipped / 0 failed** in 41.1 s — reproduces §1.3 exactly | `build/logs/verify-units.log` |
| CI on the commit that carries the code | run **41092380080** (head `7346847`, the push containing `a57fe67`): `test (ios-simulator)` **success**, `test (catalyst)` **success** | `gh run view 41092380080` |
| `grep -rn "\.threads" MattermostTests/SurfaceModeResolverTests.swift` | **0** | live grep |
| `grep -rn "threads=" MattermostUITests/` | no output | live grep |
| `MattermostUITests/T36-ThreadsUITests.swift` launch line | `shell`, `auth`, `sidebar`, `composer` — no `threads` flag; file untouched since `02d9815` | `grep -n surfaceMode`, `git log -- "…/T36-ThreadsUITests.swift"` |
| fixture facts behind §2.1 | re-measured through the API by this session: `perfprobe` is in **351** channels of team `perf`, `t36-threads` at **index 11**; its only three members are `opsbot` (345 channels), `perfprobe` (351) and `t36reply` (**3**) | scratch probe `probe_t36_fixture.py` / `probe_t36_members.py` |

Two things this re-verification adds to the record rather than restates:

1. **CI's test legs ran on the implementation commit, not on the tip.** The push that landed `a57fe67`
   also carried `7346847`, so the tip of that push was still test-worthy and run **41092380080** ran
   both legs green. The follow-up docs-only push (`79e1c9d`) is a separate run (**41092429696**) whose
   test legs are **skipped by design** (`scripts/ci_plan.py`, docs-only). A reader who looks only at
   the newest run sees `test … skipped` and might read that as untested code: it is not — the code's
   run is 41092380080.
2. **T36 cannot be made green by swapping the login.** §2.1 leaves the fixture repair to
   `t_c941e3d3`; the member table above closes the obvious cheap alternative — the one account with a
   three-channel sidebar (`t36reply`) is hard-coded as the suite's **second** author
   (`T36-ThreadsUITests.swift:41`), so logging in as it would collapse the two-author premise the
   follow/read tests rest on. The repair is a fixture or a shared scroll helper, i.e. `t_c941e3d3`'s.

**Not re-run in this session, stated plainly:** `T36ThreadsUITests` and `T31WebSessionHarvestUITests`
were not launched again (host load averaged 42 on 10 cores with two other cards' live suites on the
same simulator, the condition C1's note records as runner-crash territory; a crashed runner would add
a log that says nothing about the product). The two pairs of logs §2 cites were re-read line by line:
both T36 logs stop at `T36-ThreadsUITests.swift:793` ten times with the same message, both T31 logs
fail the same single test — so the base-vs-branch equality §2 asserts is intact, and the T36 red is
still the fixture's, not this card's.
