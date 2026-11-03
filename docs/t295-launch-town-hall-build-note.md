# T295 — the launch lands on the town hall again

Card `t_295b0a32`. Owner's requirement (2026-10-27, recorded on the card): **"launch into last opened
channel, or default to town hall."**

## 1. What was wrong

On a native launch of HEAD `2d2b903` with nothing saved, the diagnostics read

```
sidebar=... groups=11 channels=347 err=- launch=entries=347 saved=- -> none
```

and the pane drew "No channel selected on Canonical". The channel list was fully loaded (347
channels), so this was not the empty-list race; the decision itself had no destination.

Cause: `LaunchDestination.request` had lost the town-hall and first-ordinary-channel fallbacks in
T95-A (`bc0bfce`), which followed upstream's cold start (last thread → last channel → `HOME`, with no
town-hall branch) and treated our fallback as a deviation. The owner then reported the result as a
regression: a first launch — or any launch after the saved channel is gone — opened on the directory.

## 2. The fix

`Mattermost/Core/Native/NativeNavigation.swift` — `LaunchDestination` now resolves a chain, and says
which rung answered (`Origin.saved` / `.townHall` / `.firstChannel`) so diagnostics and tests can
tell "restored the saved channel" from "fell back":

1. the saved channel, while this server's channel list still contains it (unchanged from T95-A,
   including "an unloaded list trusts the saved record, the pane is the judge");
2. a channel named `town-square` / `town-hall` (the sidebar row's id is authoritative);
3. the first ordinary (non-DM) channel in the sidebar;
4. nothing — only when the list has not loaded yet, or the team has no channel at all.

What of T95-A is **kept**:

* a saved channel that is gone (left, archived, deleted) is never opened blindly: it falls **through**
  to step 2 instead of handing the pane a request that would error;
* steps 2–3 require a non-empty `available` (a list that has loaded), so a launch that has not read
  the team's channels yet opens nothing rather than inventing one. The coordinator decides again when
  the directory arrives;
* the compact layout still pushes a channel **over** the tab bar (D1), and `Back` restores it.

`Mattermost/UI/Native/Sidebar/ChannelSidebarCoordinator.swift`:

* the `$groups` sink now hands the decision the value it was given. Combine publishes `@Published` in
  **willSet**, so the old `model.groups` read inside the sink was one publish behind — measured in
  `docs/t95a-gone-channel-build-note.md` §2 as the reason a saved-but-left channel stayed visible.
  Without this, the new fall-through would trust the stale empty list and open the gone channel.
* the candidates are derived from those entries (`townhall=<id> fallback=<id>`), and
  `launch=` now records the rung: `-> town-hall -> opened(...)`.

`docs/t95-shell-tab-bar-decision.md` §3 carries a dated "D2 superseded" note; the suites'
comments (`T39*`, `ShellSettle`) that described the old policy are corrected.

## 3. Evidence — the installed Mac Catalyst build, no launch arguments of its own

Debug Catalyst build from this tree, installed at `/Applications/Mattermost(ios).app` (ad-hoc, same
bundle id `com.mattermost.ios`, so the existing signed-in session and server config carry over; the
previous bundle and the defaults domain were backed up first and restored after the run).

The only argument is the snapshot seam, which needs a Debug build:

```
bash scripts/t295_launch_snapshot.sh "/Applications/Mattermost(ios).app" /tmp/t295-snap --clear-saved
# --clear-saved removes mm.native.lastChannel only: the state the report measured (`saved=-`)
```

The app's own diagnostics (`docs/t295-launch-town-hall-diagnostics.txt`):

```
arguments=/Applications/Mattermost(ios).app/Contents/MacOS/Mattermost -shellSnapshot /tmp/t295-snap
location=NativeLocation(... teamName: Optional("canonical"), channelID: Optional("yryoj7ka6pr4ukbtojimq8ck8c"), channelName: Optional("town-square"), pane: Mattermost.NativePane.channel)
sidebar=team=sqmc4sz45prypmkfctwynm5yjr phase=loaded stage=loaded 0 groups service=labels ok (196/199)
        groups=11 channels=348 err=- launch=entries=348 saved=- townhall=yryoj7ka6pr4ukbtojimq8ck8c
        fallback=s95dzcqhjtyauqmd7f1noju4pa -> town-hall -> opened(NativeLocation(... channelName: Optional("town-square"), pane: channel))
auth=Canonical:signedIn(username: "charlie4284", ...):token=true
channels=yryoj7ka6pr4ukbtojimq8ck8c phase=loaded channel=yryoj7ka6pr4ukbtojimq8ck8c
```

`docs/t295-launch-town-hall.png` is the seam's late window snapshot: the native shell with **# Town
Square** open — header, post list with real posts, the native composer ("Message"), the sidebar's
teams/channels/DMs, and no "No channel selected" pane anywhere.

Note the two numbers the report cared about: `entries=348` (the list was loaded when the decision ran)
and `saved=-` (nothing saved), followed by `-> town-hall`. That is the exact shape of the reported
line, with the missing branch now present.

## 4. Verification

| run | result |
|---|---|
| `MattermostTests/LastChannelLaunchTests` (Catalyst, `t295-units4-mac`) | **14 run, 0 skipped, 0 failed** — saved-wins, gone→town-hall, gone→first, nothing→town-hall, nothing→first, unloaded→nothing, other-server→this-server's town hall, no team→nothing, candidate-missing→next rung, unloaded trust, team completion, both town-hall spellings, store round-trip, per-server isolation |
| `MattermostTests/NativeNavigationTests` (Catalyst, `t295-nav-units`) | **36 run, 2 skipped, 0 failed** — routing/unfunnel behaviour unchanged |
| `MattermostTests/LastChannelLaunchTests` + `NativeNavigationTests`, rebased onto `f947fd6` (`t295-post-rebase`) | **50 run, 2 skipped, 0 failed** — the same tree that is pushed, after the upstream notification commits landed |
| `xcodebuild build-for-testing` (iOS Simulator, `t295-buildfortesting`) | compiles the product **and** the `MattermostUITests` target with the rewritten suites |
| live Catalyst launch (above) | the town hall opens with nothing saved; diagnostics name the rung |

Rewritten falsifiers (policy, not prose):

* `MattermostUITests/T95ShellLayoutUITests.swift` — compact: a reset launch **opens the town hall's
  pane** (and it names the town hall), the push covers the tab bar, `Back` restores it, and tapping
  the row still opens the channel. Regular: the detail column holds the town hall, not
  `nativeEmptyDestination`, and the shell stays on screen.
* `MattermostUITests/T95GoneChannelLaunchUITests.swift` — the old `XCTExpectFailure` wrapper (which
  existed because the left channel used to be opened) is gone; the test now asserts a pane exists,
  never names the left channel, and names the server's town hall.

**Not run, stated rather than implied:** the two live UI suites above were compiled but not executed
on the simulator in this run: the fixture server (`mm-perf`) is up, but this session has no
`MM_AUTH_*` credentials for the `perfprobe` account, and the host was running 5–7 concurrent
`xcodebuild` processes (load average 600+) from other cards. They skip without those credentials by
design, so they cannot have been silently green-washed. On a machine with the fixture credentials:

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=… python3 scripts/qa-test.py --platform ios --sim id=<udid> \
  --only-testing MattermostUITests/T95ShellLayoutUITests
```

## 5. Files

```
Mattermost/Core/Native/NativeNavigation.swift                    policy: resolve() chain, Origin, Candidate
Mattermost/UI/Native/Sidebar/ChannelSidebarCoordinator.swift     arriving groups, candidates, launch= diagnostics
MattermostTests/LastChannelLaunchTests.swift                     the chain, pinned
MattermostUITests/T95ShellLayoutUITests.swift                    compact + regular launch falsifiers
MattermostUITests/T95GoneChannelLaunchUITests.swift              fall-through falsifier (wrapper removed)
MattermostUITests/T39JumpUITests.swift, T39SearchUITests.swift   policy comments corrected
MattermostUITests/ShellSettle.swift                              helper docs corrected
docs/t95-shell-tab-bar-decision.md                               §3: D2 superseded, dated
docs/t295-launch-town-hall-build-note.md                         this note
docs/t295-launch-town-hall.png                                   the shell with # Town Square open
docs/t295-launch-town-hall-diagnostics.txt                       the launch= line and shell state
docs/t295-launch-town-hall-diagnostics-late.txt                  the same, later in the launch
scripts/t295_launch_snapshot.sh                                  re-runnable evidence launcher
```
