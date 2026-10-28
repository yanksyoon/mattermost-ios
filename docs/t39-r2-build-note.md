# T39-R2 — the live suites can sign in again, and the offset test's anchor is a fixture

Card: `t_c3957991` (T39-R2). Found by T55-AV-R (`t_6059f7ce`, note
`docs/t55-revalidation-build-note.md` §3.4 F-4/F-5). Date: 2026-10-27.

**Audit target**: `origin/main` = `2785c37`, from a worktree of its own
(`~/.hermes/profiles/mmios-ios/cache/scratch/t39r2/wt`). The shared checkout carried T47's and T48's
in-flight files while this ran; none of them was compiled or touched here, and `git status
--porcelain` in the worktree reports exactly the three files below plus one new script.

**Nothing in `Mattermost/` or `MattermostTests/` changed.** This card is the *test harness* and the
*fixture*: the two live suites and the seed that feeds one of their anchors.

---

## 1. What shipped

| file | change |
|---|---|
| `MattermostUITests/T39JumpUITests.swift` | `synchronous` uses a cookie-free `restSession` (T40's, copied — not invented); sign-in skip message carries status + body; the offset test anchors on a fixed, seeded day; the jump test's "newest post" is read from the server instead of being a stale constant; `openSearch` reaches the search tab when the compact shell has pushed a channel over it; the `searchSubmit` tap waits for the element |
| `MattermostUITests/T39SearchUITests.swift` | same `restSession`, same diagnostic skip message, same tab-bar navigation, same wait-before-tap |
| `scripts/t39_offset_anchor_seed.py` | **new**. Seeds `#t39-anchor` with three posts that carry an explicit `create_at` on a fixed day, inside the reader's local day and outside the UTC-day reading of it; idempotent, and it verifies the separation itself |
| `docs/t39-r2-evidence-2026-10-27.log` | the lines below, extracted from the full logs (`build/logs/t39r2/`, gitignored) |

---

## 2. Defect 1 — every test skipped with 401 `session_expired`

Both suites' REST oracle used `URLSession.shared`. Its cookie jar keeps the runner container's
`MMAUTHTOKEN` from any earlier sign-in, and Mattermost answers a *login that carries a dead session*
with `401 api.context.session_expired.app_error` before it looks at the password — so
`authenticate()` fell into its skip branch and all seven tests skipped. T36-R and T40-R already use
a cookie-free ephemeral session for exactly this (`T40ChannelInfoUITests.swift:954-966`); T39 never
adopted it.

**Red/green pair on the same tree** (`docs/t39-r2-evidence-2026-10-27.log` §1, §2):

* `Self.restSession` → `URLSession.shared` in both helpers, nothing else changed: **6 run / 6
  skipped**, each with the 401 and its request id in the skip message — and `qa-test.py` reports
  `RESULT: PASS`, which is the trap: a suite that measured nothing looks green.
* with `Self.restSession`: **6 run / 0 skipped / 0 failed**, in one invocation, from a runner
  container that had already signed in on every earlier run of the session.

The diagnostic message stays: `could not sign in as <login> on the live server (status 401 {…})`. A
skip that cannot say why cost T55-AV-R three runs.

---

## 3. Defect 2 — the anchor was the wall clock, not the fixture

`testOnDateModifierSendsTheTimezoneOffsetInSeconds` asked the server the same `on:` question twice —
offset in **seconds** (what the API reads) and in **minutes** (what T39 shipped) — on *the newest
post's day*, and needed the two answers to differ. T55-AV-R measured `in:t34-showcase on:2026-10-27`
answering **2 posts both ways** (`build/logs/t55/t55-tz-separation.log`): the test then skipped on
its own premise, so green could mean "not measured".

The anchor is now a property of the fixture:

* `scripts/t39_offset_anchor_seed.py` writes three posts into a dedicated `#t39-anchor` with an
  explicit `create_at` (the server honours a client-supplied `create_at` on `POST /posts` for a
  `system_admin` account — measured on 9.11.19: asked `1793423400000`, read back the same), on a
  fixed day (`2026-10-26`), at `create_at` values inside the reader's local day and **outside** the
  window a client sending `offset / 60` would ask for. The band is computed from the offset,
  `|O − O/60|` seconds wide, rather than assumed: a western offset puts it late in the local
  evening, an eastern one just after local midnight.
* the script re-checks the separation through the search API and exits non-zero if the fixture does
  not separate — the fixture cannot silently rot.
* the test re-reads both counts at run time (`in:t39-anchor on:2026-10-26`: **3 at −18000 s, 0 at
  −300**), and if they ever match it skips with a message naming the seed script and the offset to
  re-run it with — a fixture gap, said out loud.

It survives the offsets a runner on this fixture will plausibly have (−18000, −14400, −21600,
−25200, −28800 all separate; UTC and eastern offsets answer 0/0 and must re-seed — measured, §4 of
the evidence).

**Falsifiability**: mutation M3 from T55 (make `SearchGrammar.body` send `timeZoneOffsetSeconds / 60`)
reds this test again — the app shows the empty state where the reader's day has 3 posts
(evidence §5). Reverted with `git checkout --`; the tree is clean.

---

## 4. Two more harness defects met while getting to green (fixed here)

Both are the same class as the ones above: a test that cannot tell "no evidence" from "green".

1. **The compact shell pushes a channel over the tab bar.** `LaunchDestination` opens the team's
   town hall as soon as the channel directory arrives, and `RootView`'s `NavigationStack` is *above*
   the `TabView`, so the pushed channel pane covers it. Measured: a launch that pushed Town Square
   before the first tap had neither `shellSearchButton` (regular layout only) nor a `TabBar`, and the
   test reded with "neither the toolbar nor a tab opens search" while the screen was fine
   (`t39r2-live-a`). `openSearch`/`openSaved`/`launchAndOpenChannel` now pop back with the *Back*
   button first — the same two entry points, reached the way a reader reaches them. This is also a
   **product** observation, not only a test one: see §6 F-1.
2. **The jump test's "newest post" had stopped being the newest.** The constant
   `b4rnbrmcsffe8mshqxf17wktrr` was the newest when T39 was written; later suite runs posted into
   `#t36-threads` and it is now #56 of the newest page ("t37 picker target 1793005481") — a post the
   pane legitimately draws just past the gap separator, so `XCTAssertFalse(post.<newest>.exists)`
   reded a *correct* pane (screenshot `t39jump-2-focused`, `t39r2-jump-diag4`). The assertion now
   takes `newestPage.first` from the server and asks whether that row is inside `channelPostList`'s
   frame — "visible", which is the claim the message always made — instead of "present in the
   accessibility tree", which the newest page's presence makes meaningless. The red direction is
   demonstrable: a row inside the viewport trips it (that is what `t39r2-jump-diag4` shows), and the
   target row's own in-window assertion is untouched.
3. **A bare `.tap()` on an element the app has not snapshotted yet.** `testAMalformedQuery…` reded on
   the rebased tree with `Failed to tap "searchSubmit" … No matches found` and passed alone in 61 s
   (`t39r2-live-f-rebased`, `t39r2-malformed-alone`). The four `searchSubmit` taps now go through a
   `tap(_:in:)` helper that waits for the element — the assertions behind them decide the test, the
   wait only removes a snapshot race.

---

## 5. Verification

Runs with `scripts/qa-test.py --platform ios --sim id=81A7F251…`, derived data
`~/Library/Developer/Xcode/DerivedData/t39r2` (outside the TCC-protected folders), packages cloned
from `…/mmios-t40r/SourcePackages`.

| label | what | result |
|---|---|---|
| `t39r2-live-g-rebased` | **both suites, one invocation, the tree being pushed** (`origin/main` `00cd217` + this commit, i.e. T47's and T48's product code compiled in) | **6 run / 0 skipped / 0 failed**: T39JumpUITests **2/2** (59.1 s, 43.0 s), T39SearchUITests **4/4** (43.7, 46.3, 27.1, 39.2 s) |
| `t39r2-live-e` | both suites, one invocation, on `2785c37` + this card | **6 run / 0 skipped / 0 failed**: T39JumpUITests **2/2** (48.4 s, 43.6 s), T39SearchUITests **4/4** (42.2, 52.6, 43.1, 41.7 s) |
| `t39r2-mutant-cookie` | the same tree with `URLSession.shared` back | 6 run / **6 skipped**, each `status 401 api.context.session_expired` |
| `t39r2-mutant-offset` | `SearchGrammar.body` sends `/60` | `testOnDateModifierSendsTheTimezoneOffsetInSeconds` **red** (screen has no summary: 0 results where the reader's day has 3) |
| `t39r2-anchor-probe` | old anchor vs seeded anchor at −18000 s | old `in:t34-showcase on:2026-10-27` 26 vs 2 *today* (it separated by accident of other cards' posts; T55 measured 2 vs 2 at −25200); seeded `in:t39-anchor on:2026-10-26` 3 vs 0 |
| `t39r2-anchor-offsets` | the seeded day at seven offsets | separates at −18000/−14400/−21600/−25200/−28800; 0/0 at 0 and +3600 (UTC/eastern must re-seed) |

Runs that were red for reasons that are **not** this card are listed with their evidence in §6 of
`docs/t39-r2-evidence-2026-10-27.log`: two runs lost to the simulator's accessibility helper
(`AccessibilityControlsExtension-2026-10-27-204132.ips`, `-205116.ips`), one lost to the app falling
back to the sign-in screen mid-test with no 401 in the server log. The host was running three other
cards' suites throughout (`uptime` load 12 – 273).

---

## 6. Known limits and one finding, stated rather than hidden

* **F-1 (product, carded separately — see the card comment)** On the phone layout a pushed channel
  covers the tab bar, so `Search` / `Saved` / `Recent mentions` are unreachable while a channel is
  open; upstream keeps the tab bar (its `TabView` is outside each tab's stack). The tests now pop
  back, which makes them honest but does not fix the UX. This card did not touch `Mattermost/`.
* The seed's default offset is the *host's*; if the runner's offset differs, pass
  `--tz-offset-seconds`. The test says so when the fixture does not separate.
* `scripts/t39_offset_anchor_seed.py` needs a `system_admin` account (it is the same `perfprobe` the
  other seeds use) **only** because `create_at` is honoured for admins; on a server where that is
  refused the script fails loudly (`the server did not honor create_at`) instead of writing a
  fixture that cannot answer the question.
* The `#t39-anchor` channel is not removed by anything: it is a fixture, like `#t34-showcase`.
