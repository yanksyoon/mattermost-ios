# t9399c0b4 — the live suites that wait on `nativeShell` and then read the sidebar land through `ShellSettle` now

Status: repaired, test-side only. No product file was touched.

Scope: the live UI suites that both sign in with a bare
`element(app, "nativeShell").waitForExistence(…)` **and** then query `channelSidebar.*` /
`teamSidebar.*`. Since `t_295b0a32` a signed-in launch opens a channel and pushes it *over* the
channel list, so `nativeShell` is not in the accessibility tree at all and the sidebar is drawn only
after `Back`. Those suites encoded the pre-`t_295b0a32` landing as a premise.

## 1. The defect, as measured

The premise is only false when the launch's channel list has *loaded*: a launch whose list has not
loaded still draws the list (and its bar) and the suite passes. On this host (iPhone 16 Pro
`4BB9CE43…`, iOS 18.3.1, the real 9.11.19 at `127.0.0.1:8065`) the pushed landing wins that race
every time, which is why `T5449ThreadProfileUITests` was 3/3 red at `the team rail must list #perf`
at `886a087` — with `nativeChannelPane` "Town Square" and `Back` in the nav bar — and red after a
`simctl uninstall` as well, so it was not persisted state
(`build/logs/te73-live-verify1.log`, `…-verify2.log`, `…-verify3.log`; repaired in `f306d2a`, green
1/0/0 in 30.7 s, `build/logs/te73-live-verify5.log`). That shape is now recorded in
`MattermostUITests/ShellSettle.swift`'s header, because a suite written to it is a red suite, not a
slower pass.

## 2. What the repair is

One idea, no new vocabulary: a suite signs in through `ShellSettle.waitForSignedIn` (the target's one
answer to "are we in?" for the channel list, a pushed pane, and the tab bar), and reaches the channel
list through `ShellSettle.revealChannelList` (bounded `Back` taps, returning the pop count so a
failure message says whether the list was ever reached). Suites whose row is far below the fold keep
using `revealSidebarChannel` as before. **No assertion was weakened**: every suite's own identity
check against the server's ids is unchanged, and the pop count is now part of some failure messages.

Where the pop lives inside each suite is deliberate — at the `signIn` helper when that helper is the
only launch path, and at the `openChannel`-style funnel otherwise — so the step is paid once per
launch (the settle window below is a ceiling, not a sleep, but it is not free either).

## 3. Five facts about the landing that the helper itself had wrong

All five were measured during this card, and all five are why a first sweep of
`waitForSignedIn` + `revealChannelList` was not enough:

1. **The push lands a beat after the shell draws.** `T429ProfileTapUITests` showed both shapes in one
   run: one test saw `nativeChannelPane` at t=10.2 s and popped it, the next saw only the list at
   t=10.1 s, answered "already on the list" with 0 pops, and was covered by the pane before its 40 s
   rail wait (`build/logs/t9399-T429ProfileTapUITests.log`). `revealChannelList` therefore gives the
   hand-over a bounded settle window (`settle:`, default 8 s) and pops if it arrives.
2. **`Back` exists but is not hittable while the push animates.**
   `T5449ProfileActionsUITests` had the pane in the tree at t=9.31 s and `Back` not hittable at
   t=9.40 s; returning 0 pops there left the rail query waiting 40 s under a pane that never went
   away (`build/logs/t9399-T5449ProfileActionsUITests.log`). `popOneScreen` now waits the beat out.
3. **A tab bar under a pushed pane is still in the tree.** `T5449ListProfileUITests` failed with "the
   tab bar is on screen but offers no \"Mentions\" tab": `tabBars` and its `Channels` button existed
   at t=11.89 s and the `Mentions` lookup right after found nothing, because the pane had arrived in
   between (`build/logs/t9399-T5449ListProfileUITests.log`). `tapTab`/`revealTabs` now treat a pushed
   pane as "the bar is not on screen", settle for the hand-over first, and pop before tapping.
4. **A covered screen's elements are still in the tree.** This is the one that cost the most: the
   channel list's root is kept mounted under the pushed pane, so `nativeSidebar`, its rows and the
   tab bar's buttons answer `exists == true` while the pane is what the screen shows. Three suites'
   `showSidebar` early-returned on exactly that (`if element(app, "nativeSidebar").exists { return }`)
   and then queried a sidebar the reader could not see: `T47CreateChannelUITests` failed at t=8.67 s
   with `nativeSidebar` present, `sidebarCurrentTeam` absent and the dump showing the "Town Square"
   pane (`build/logs/t9399-T47CreateChannelUITests.log`). Presence of a *root* element is therefore
   not a screen test; `ShellSettle.tabBarIsUp` asks for a *button* of the bar and treats a pushed pane
   as "not up", and the suites' `showSidebar` helpers now go through `ShellSettle.tapTab` instead of an
   existence probe.
5. **The inverse guard is just as wrong**: `T48PostOptionsUITests` popped `Back` only when
   `channelPostList` was **absent** — but a pushed pane is exactly what draws the post list, so the pop
   never happened and "the sidebar must offer the quick switcher" failed under the pane
   (`build/logs/t9399-T48PostOptionsUITests.log`). TModalDismiss had the same shape; both now call
   `revealChannelList` unconditionally.

## 4. Verification

Command (one class per run, one log per class, same simulator and derived data as the parent card):

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<the committed throwaway fixture in scripts/perf_seed.py> \
xcodebuild test-without-building -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=iOS Simulator,id=4BB9CE43-7038-47E9-BB07-4D4E82DFF3F1' \
  -derivedDataPath ~/.hermes/profiles/mmios-ios/cache/scratch/te73/dd \
  -only-testing MattermostUITests/<Class>
```

Results, one row per audited suite (latest run of each, all against the tree committed after this
card; `n/s/f` = tests run / skipped / failed):

| suite | n/s/f | what it says |
|---|---|---|
| `T5449ThreadProfileUITests` | 1/0/0 | green in 30 s — the suite the parent card repaired, still green |
| `T5449ListProfileUITests` | 5/1/0 | green; the iPad-only lookup-sheet test skips on a phone |
| `T5449ProfileActionsUITests` | 3/0/0 | green (3/3 red before this card: 2 landing, 1 tab-bar) |
| `T41ProfileUITests` | 7/0/0 | green |
| `T429ProfileTapUITests` | 4/0/0 | green; this is the suite that showed both landing shapes in one run |
| `T40ChannelInfoUITests` | 9/0/1 | 8 green; `…BrowsingAndJoiningAPublicChannel…` reaches the browser sheet and the sheet does not list the public channel it is not in (2 assertion failures, `build/logs/t9399-T40ChannelInfoUITests.log`). The member (non-admin) test now signs in: it needed the server's terms-of-service step, which the helper now accepts |
| `T52ChannelInfoUITests` | 3/0/0 | green |
| `T35-ComposerUITests` | 3/0/0 | green |
| `T37-ReactionsUITests` | 3/0/0 | green |
| `T38AttachmentsUITests` | 4/0/0 | green |
| `T39SearchUITests` | 4/0/1 | 3 green; `…UnsaveFromTheSavedTab…` mounts the Saved pane and the `savedPosts` list never appears (the new assertion names it instead of dying in a swipe query) |
| `T47CreateChannelUITests` | 2/0/0 | green (was 0/2: covered-root early-out) |
| `T47CreateChannelAVUITests` | 6/3/0 | green |
| `T48PostOptionsUITests` | 6/0/1 | 5 green; `…MissingOptionsAndCopyLink…` ends with the app **terminated** mid-test ("Checking for crash reports corresponding to unexpected termination") right after `postOptions.followThread` was not offered — a crash, not the landing |
| `T48PostOptionsAVUITests` | 2/2/0 | green (both skip on a phone) |
| `T51GlobalDraftsUITests` | 2/0/0 | green (was 1/2: presence probe on a covered root) |
| `T53MediaPlaybackUITests` | 2/0/0 | green |
| `T635RestoredPaneUITests` | 2/0/0 | green (was 0/2: the rail-tap "fallback" pushed the pane it was trying to leave) |
| `TModalDismissUITests` | 2/0/0 | green (was 0/2: inverse `channelPostList` guard) |
| `T70AuthorNamesUITests` | 3/0/0 | green |
| `T45AvatarUITests` | 2/0/0 | green |
| `T50EditProfileUITests` | 3/0/1 | 2 green; `…ThePictureChangesThePostRow…` ends on the shell's **team rail with no channel list** and `nativeSidebar` never appears (166 s). The landing premise is fixed in this suite; what is left is a shell-navigation gap after the settings sheet closes, measured in `build/logs/t9399-T50EditProfileUITests.log` |
| `T34-ChannelPostListUITests` | 7/0/0 | green |
| `T54MentionBannerUITests` | 4/0/0 | green |
| `T46WebFallbackUITests` | 5/0/2 | 3 green incl. boards; the two plugin-route tests (`/playbooks`, system console) never mount the fallback webview and one run found the app dead afterwards — the landing/sidebar steps pass |
| `T33-ChannelSidebarUITests` | 10/0/0 | green (the sidebar suite proper) |
| `T38HeavyScrollProbeUITests` | 1/0/0 | green (probe; was failing at the row tap) |
| `MattermostUITests` (legacy class) | not run | the legacy class is a 100+ test stub-server suite; the live test in it that this card touched (`testRealServerTeamRailShowsBothTeamsAndSwitchesBetweenThem`) was repaired with the same two calls but is not re-run here — see §6 |
| `T33-ChannelSidebarStubTests` | not run | needs the stub servers (`scripts/mm_stub.py`); repaired the same way (sign-in + list), unverified on this host |

The whole unit target was run on a second simulator (iPhone 16 Pro `81A7F251…`) with
`-only-testing MattermostTests`: **0 assertion failures**; the only red was
`T31HarvestCookieInstallTests.testARealStoreKeepsTheInstalledCookieAndTheProductionReaderFindsIt`,
which kills the app host mid-suite (`Restarting after unexpected exit, crash, or test timeout`) and
passes alone in 1.0 s (`build/logs/t9399-cookie-retry.log`). `scripts/verify-dual-render-gates.sh
--allow-approved-registry` passes (`build/logs/t9399-dual-render.log`).

## 5. What this card did not do

- It did not run the legacy `MattermostUITests` class (100+ tests against the stub servers) — only the
  live rail test in it was edited, and running that class is its own multi-hour job.
- It did not run `T33-ChannelSidebarStubTests` (stub servers not started on this host).
- The four remaining reds above are **not** the landing premise: each suite now reaches the channel
  list and its rows (the pop/swipe counts are in the failure messages), and each fails on something
  else. They are named here rather than papered over.


## 6. Files changed

Test-side only (`git diff --stat` is the authority; listed here for the reviewer's index):

- `MattermostUITests/ShellSettle.swift` — header paragraph (the pre-`t_295b0a32` shape is a red
  suite), the settle window in `revealChannelList`, `popOneScreen`, `tabBarIsUp`, `waitForLandingToSettle`
  and the `tapTab`/`revealTabs` use of them.
- `T429ProfileTapUITests`, `T5449ListProfileUITests`, `T5449ProfileActionsUITests`, `T41ProfileUITests`,
  `T40ChannelInfoUITests`, `T52ChannelInfoUITests`, `T35-ComposerUITests`, `T37-ReactionsUITests`,
  `T38AttachmentsUITests`, `T39SearchUITests`, `T47CreateChannelUITests`, `T47CreateChannelAVUITests`,
  `T48PostOptionsUITests`, `T51GlobalDraftsUITests`, `T53MediaPlaybackUITests`,
  `T635RestoredPaneUITests`, `TModalDismissUITests`, `T70AuthorNamesUITests`, `T45AvatarUITests`,
  `T50EditProfileUITests`, `T34-ChannelPostListUITests`, `T54MentionBannerUITests`,
  `T46WebFallbackUITests`, `T48PostOptionsAVUITests`, `T33-ChannelSidebarUITests`,
  `T33-ChannelSidebarStubTests`, `T38HeavyScrollProbeUITests`, `MattermostUITests.swift` — sign in
  through `waitForSignedIn`; reach the list through `revealChannelList` before the first
  `channelSidebar.*`/`teamSidebar.*` query.
- `T93BNativeByDefaultUITests` — audited, **no change needed**: it already answers the landing itself
  (`launchedIntoShell` polls `nativeShell`, `nativeChannelPane` and the tab bar; `returnToSidebar` pops
  unconditionally before every sidebar read).
