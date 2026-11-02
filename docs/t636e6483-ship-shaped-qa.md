# t_636e6483 — ship-shaped QA: what a reader sees on a **Release** build with no flags

Subject: the lookup flip landed by `t_01afff4b` (`9ac0b73`, docs `0bce5d7` = `origin/main` = local
`HEAD`). This round measures the **shipped configuration** — `app.launchArguments = []`, no
`-surfaceMode`, no `-notificationPath`, no inspector, no `-uiTestSeed…` — and nothing else.

| | |
|---|---|
| Build configuration | **Release** (`MattermostReleaseSmoke.xcscheme`, `-configuration Release`) |
| Devices | iPhone 16 Pro `81A7F251-8B31-4945-8783-5A264C14B8D5` (compact) · iPad Pro 11-inch M4 `495B0295-5421-4667-92FD-DA47D89BD6E0` (regular) |
| Runtime | iOS 18.3 simulator, Xcode 26.6 (17F113), host macOS 26.3.1 |
| Server | local Mattermost 9.11.19, `http://127.0.0.1:8065`, container `mm-perf` (fixtures from `scripts/perf_seed.py`) |
| Container | seeded once with a Debug build, Release installed over it (the suite's documented pattern); both containers hold a signed-in `perfprobe` session |
| Suite | `MattermostUITests/T93BNativeByDefaultUITests.swift` — 10 tests, 8 written by this card |

Both runs used the same file, the same binary and the same environment variables
(`TEST_RUNNER_MM_AUTH_SERVER` / `_LOGIN` / `_PASSWORD` only — the suite reads them for its REST
oracle; they are not launch arguments and the app never sees them).

```
xcodebuild test -project Mattermost.xcodeproj -scheme MattermostReleaseSmoke -configuration Release \
  -destination 'platform=iOS Simulator,id=<device>' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/mmios-qa-t636e6483 \
  -clonedSourcePackagesDirPath ~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa/SourcePackages \
  -resultBundlePath .../TestResults/<run>.xcresult \
  -only-testing:MattermostUITests/T93BNativeByDefaultUITests
```

## Verdicts against the card

| # | What the card asks | Verdict | Evidence |
|---|---|---|---|
| 1 | Compact: five tabs, three real lookup screens, no `*WebFallback` note | **PASS** (iPhone) | 5 tab items `Channels/Threads/Search/Mentions/Saved`; Search draws `nativeSearchPane` + `searchField` + `searchSubmit`; Saved draws `nativeSavedPane`; Mentions draws `activity.list`; `searchWebFallback`/`savedWebFallback`/`activityWebFallback` absent on every screen |
| 2 | Regular: the same three as toolbar sheets + `nativeChannelPinnedButton` → `pinnedSheet` | **PASS** (iPad) | `shellSearchButton`/`shellSavedButton`/`shellActivityButton` each open a sheet drawing `nativeSearchPane`/`nativeSavedPane`/`nativeActivityPane`, and close again; an open channel's header offers `nativeChannelPinnedButton`, which opens `pinnedSheet` |
| 3 | One real query end to end, no flags; a mention row lands on its channel | **PASS** | Submitted `t636shipshape…` → REST match drawn as a `searchResult.<id>` row with the server's text → tap → `postFocus.<id>`, i.e. the jump landed on that post; mention row → `nativeChannelTitle` matches the row's channel |
| 4 | Post options menu on a *search result* row and on a *mention* row (`00cd217`) | **FAIL — finding F1** | `post.<id>.menu` is not in the tree on either row; both assertions fire with the real post ids (`post.96x6mk…`, `post.cj764a…`) |
| 5 | "Use web view" returns a loaded webview, no note | **PASS** (first clause) / **not applicable** (second clause) | `webPane` value `loaded`; no lookup note anywhere; but the lookup tabs/buttons are **gone** in that state — see finding F2 |
| 6 | App badge equals the server's summed `mention_count` | **PARTIAL — icon badge not observable, rail arithmetic holds on the compact layout** | Compact: server per-team sum 2 = rail badges 2 (selected team's hidden badge accounted for). Regular: the open lookup sheet covers the rail, so that half is "not measured" (printed, not skipped into a pass). The SpringBoard icon badge is unreadable — see finding F4 |

## Findings (a FAIL is a finding, not a revert)

**F1 — the post options menu does not exist on lookup rows. `00cd217` added it to the shared
`PostRowView`, but the two lookup row types call `PostRowView` without `actions:`, so no ellipsis is
built at all.** Measured in a Release build with no flags:

* `testThePostOptionsMenuOpensOnASearchResultRow`: `post.<id>.menu is not in the tree
  (SearchResultRowView calls PostRowView without actions:)`
* `testThePostOptionsMenuOpensOnAMentionRow`: `post.<id>.menu is not in the tree
  (ActivityRowView calls PostRowView without actions:)`

The rows themselves draw (both tests get as far as resolving the server's post id and the row), so
this is the menu, not the row. The card named exactly this surface (§3), and both `-AV` verdicts
predate `00cd217`. Fix belongs to whichever card owns `SearchResultRowView`/`ActivityRowView`; this
card does not revert the flip for it — search, saved, pinned and mentions all work without it, and
the menu is a `T48`-style action surface, not the lookup path.

**F2 — the card's item 5 describes a state the product does not have.** The hatch calls
`forceWebForThisRun(.channelView)`; `SurfaceHost` then renders the webview *instead of*
`NativeShellView`, so the compact tab bar and the regular toolbar go with the shell. Measured after
the hatch: `tabBar=false`, `shellSearchButton`/`shellSavedButton`/`shellActivityButton` absent,
`native{Search,Saved,Activity}Pane` absent, `webPane` = `loaded`, no lookup note
(`release-hatch-state` attachment, `build/logs/t636e6483-iphone-release7.log:618`). The two true
clauses (loaded page, no note) are asserted; "the lookup tabs still draw native screens" is recorded
as not applicable rather than asserted away.

**F3 — `savedPosts` is not published by SwiftUI on this runtime.** The Saved screen draws
(`nativeSavedPane`, and the live search/saved rows resolve), but the `List`'s own identifier never
appears in the accessibility tree. Same observation as T5449-C2 (`build/logs/t5449c2-live1.log`).
The compact Saved assertion therefore requires the pane (or `savedPosts.loading`), which is the
strongest observable available.

**F4 — the OS app-icon badge is not measurable from a UI test or from this host.** Probed:
`simctl spawn … defaults read com.apple.springboard` has no badge key, `SpringBoard/IconState.plist`
carries layout only, `Library/UserNotifications` carries delivered notifications only, and there is
no XCUITest query that reads springboard's icon. What *is* measured instead is the arithmetic the
badge is built from, on the one drawn badge fed by the same counters: `GET /users/me/teams/unread`
returns per-team `mention_count` (sum **2**), the native feed mounts and lists rows (6), and the team
rail draws **2** mention badges — equal to the server's sum minus the selected team's count (0,
because upstream hides the selected team's badge). Run 7 prints
`[t636] server mention total = 2; feed rows = 6; rail = 2 expected 2`. The step from "the app's
counters agree" to "the icon shows 2" is **not measured here** and is not claimed.

## Harness defects this round had to fix (all in the one suite file)

The two pre-existing tests were **not** rewritten; their claims are unchanged. What changed is that
their preconditions became reachable again:

1. `returnToSidebar` looked for `BackButton`. That identifier does not exist. The labelled
   `backToolbarButton` (`RootView.swift:352`) is the **web** toolbar's history back, and a restored
   *native* channel is pushed by `NavigationStack`, whose back button has no identifier at all —
   only the label `Back`. The helper now tries identifier *and* label. Before: two tests burned
   90 s each on "the native sidebar never drew a channel row" (runs 3–5).
2. The `nativeChannelPane` identifier belongs to the **placeholder** pane
   (`NativePanePlaceholders.swift:327`); the shipped channel pane draws `channelPostList`. Gating the
   pop on `nativeChannelPane` never fired for a restored channel.
3. The app restores its last **tab**; lookup tests ending on Search/Mentions left the next launch
   there. `tearDownWithError` now returns the container to the Channels tab (compact only).
4. `closeLookupSheet` assumed a single `*SheetClose` element; the regular layout draws it twice
   ("Multiple matching elements found", iPad run 1). It now taps the first **hittable** one.
5. The regular layout's channel list lives in a collapsible split-view sidebar. `waitForNativeSidebar`
   now opens it once and its failure message names what *is* on screen (`nativeShell`, `webPane`,
   `tabBar`, identified buttons) instead of only what is missing.
6. The live search fixture was created in `server.teamID` while the app's search is **team-scoped**;
   the shell was in team `ops` (`xs9sxp6s8pysmnrakx31godyye`) and the fixture in `perf`, so the
   query could never match. `seedSearchTargets` now posts in the shell's own team (read off the rail)
   and falls back to every team of the account when the layout hides the rail (iPad).

## Runs

| Run | Device | Configuration | Tests | Result | Log / bundle |
|---|---|---|---|---|---|
| iPhone run 7 (final) | iPhone 16 Pro | Release | 10 | **8 passed, 1 skipped, 2 failed** (F1 ×2), 208.7 s, rc 65 | `build/logs/t636e6483-iphone-release7.log`, `…/TestResults/t636e6483-iphone-release7.xcresult` |
| iPad run 2 (final) | iPad Pro 11-inch M4 | Release | 10 | **8 passed, 1 skipped, 2 failed** (F1 ×2), 334.4 s, rc 65 | `build/logs/t636e6483-ipad-release2.log`, `…/TestResults/t636e6483-ipad-release2.xcresult` |

Same file, same binary, same env vars, one difference in behaviour worth naming: on the iPad the app
had no team selected in the shell's rail (the split view's sidebar is collapsed under the open sheet),
so `seedSearchTargets` exercised its documented fallback — `[t636] search scope: shell team unread;
seeding 3 teams` — and the account's three teams each got one throwaway `t636shipshape…` post. The
query then matched its target either way, which is why the iPad's search assertion is still a real
end-to-end measurement and not a fixture guess. The badge equality is iPhone-only for the same
reason: `[t636] rail not drawn (sidebar collapsed): rail check not measured` (`…ipad-release2.log:1092`).

Earlier runs (1–6 on iPhone, 1 on iPad) are kept under `build/logs/t636e6483-*.log`; they are the
diagnosis trail behind the six harness fixes, not the evidence for the verdicts. `rc=65` is
`xcodebuild` reporting the two F1 failures, not a harness error.

Skipped test: `testRegularShellDrawsTheSameThreeAsToolbarSheets` on the iPhone (and its compact twin
on the iPad) — the wrong layout for that device, skipped with that reason in the skip message, per
the card's reporting rule.

## Not measured (and not counted as passes)

* **The OS icon badge** (F4) — unreadable from XCUITest on this host.
* **A real device soak** — no physical device is attached to this host; both runs are simulators.
* **APNs / push-driven badge updates** — no APNs credentials here; `MentionPoller`'s server path is
  what the rail numbers come from.

## Reproduce

```bash
cd /Users/yangsooyoon/Documents/yanks/code/mattermost-ios
# 1. server + fixtures
docker start mm-perf                       # http://127.0.0.1:8065
python3 scripts/perf_seed.py               # if the container is fresh
# 2. seed each simulator's container once (Debug), then install Release over it:
#    the suite skips — never fails — when the container has no signed-in server.
# 3. run
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
TEST_RUNNER_MM_AUTH_LOGIN=… TEST_RUNNER_MM_AUTH_PASSWORD=… \
xcodebuild test -project Mattermost.xcodeproj -scheme MattermostReleaseSmoke \
  -configuration Release -destination 'platform=iOS Simulator,id=81A7F251-8B31-4945-8783-5A264C14B8D5' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/mmios-qa-t636e6483 \
  -clonedSourcePackagesDirPath ~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa/SourcePackages \
  -only-testing:MattermostUITests/T93BNativeByDefaultUITests
```
