# t_e73f31ce — a thread reply's author name was blank (0×0) because the thread model kept a stub as "known"

Status: fixed. Code + tests in this tree; the live proof is C1's own UI test, tightened.

## 1. The defect, as measured

Found while building `t_07216319` (C1) and recorded in `docs/t_8f9f5449-c1-build-note.md` §5.2, not
fixed there. In the thread pane's exported accessibility tree (iPhone 17 Pro, 9.11.19, live run
`t5449-live1`), the **root** row draws its author name normally and a **reply** row draws nothing:

```
Other,  identifier: 'thread.post.necc65zn67yqprd35ikhcecp5y'
  Button, identifier: 'post.necc65zn67yqprd35ikhcecp5y.avatar', label: ' profile'      ← empty name
  Button, identifier: 'post.necc65zn67yqprd35ikhcecp5y.author', {{58.0, 365.7}, {0.0, 14.0}}   ← 0×0
    StaticText, {{0.0, 0.0}, {0.0, 0.0}}
```

The same tree's root row draws `post.<root>.author` at `{76.3, 18.0}` with label `'Perf Probe'`. So
the data, not the view: the name button was present and wired, its label was the empty string, and
XCTest cannot tap a 0×0 element ("Failed: Not hittable").

Two separate reasons produced the empty string, and both are fixed here:

1. `PostListDerivation.author(for:users:)` returned `displayName(for: user)` for **any** entry in the
   map. A profile with no fields has a `displayName` of `""`, so a stub entry drew `Text("")` — the
   `"Unknown user"` fallback only fired when the entry was *absent*.
2. `ThreadViewModel.loadProfiles` filtered ids with `users[$0] == nil`, so a stub made the id look
   **known** and no `POST /users/ids` was ever sent. The only path that writes a profile into `users`
   without a request is `ThreadViewModel.apply(thread:)`, which stored whatever a `thread_updated`
   frame's `participants` carried — id-only stubs included. (The REST thread answer on this server
   carries `participants: null`, measured with `curl` in C1's note; the socket frame was not captured,
   so "a `thread_updated` frame is the source" was a hypothesis. The repair does not depend on it: a
   stub can now never stand in for a profile whichever path wrote it.)

## 2. The repair

One predicate, three consumers — so "is this person known?" cannot be answered two ways:

- `MMUser.hasProfileDetails` / `.isIdOnlyStub` (`Mattermost/Core/MM/MMTypes.swift`): a profile is
  *known* when it carries a username, first name, last name or nickname. `PostListDerivation
  .participantAuthors` already had this rule inline for the avatar stack; it now calls the shared one.
- `PostListDerivation.author(for:users:)`: an entry that is **not** known falls through to the same
  fallback an absent entry gets — the `username` in the post's `props`, then `"Unknown user"` — so a
  row can never draw `""` again.
- `ThreadViewModel`:
  - `loadProfiles` and `scheduleProfileLoad` (now taking a list of ids) treat a stub as **not known**,
    so the batch request that names the person actually runs;
  - `apply(thread:)` only lets an id-only participant fill a **hole** — it can no longer overwrite a
    real profile — and asks for every participant the map still cannot name;
  - `loadReactionProfiles` uses the same filter.

Nothing in `PostRowView` changed: `thread.post.<id>` on the row container and `post.<id>.*` on the
leaves are the T36-measured contract. No `.threads` surface or flag was added (retired,
`docs/t_7ffa9e76-threads-surface-retirement.md`).

## 3. Tests

`MattermostTests/T36ThreadViewModelTests.swift` (+ the fake's new `profileRequests` / `usersError`):

- `testAnIdOnlyParticipantNeverLeavesABlankReplyAuthorAndIsStillAskedFor` — the measured state (the
  first profile fetch failed, so an avatar is drawn with no name) followed by a `thread_updated` whose
  only participant is `MMUser(id:)`. Asserts (a) the row's author is never blank while the map holds
  the stub, and (b) the stub is not "known": a `POST /users/ids` carries that id and the row then
  draws `"Them Person"`.
- `testAFullParticipantProfileIsNotOverwrittenByALaterStub` — a real profile survives a stub-shaped
  frame, and a person already named costs no second request.

`MattermostUITests/T5449ThreadProfileUITests.testTheAuthorOfAThreadReplyOpensTheirProfile` is
tightened: it now requires the reply's `post.<replyID>.author` to have a **non-empty label**, be
**hittable**, and taps **that** element (it used to settle for the avatar, which shares the callback)
before asserting the sheet shows the server's username for the reply's author.

Its **landing premise** was repaired on the re-verification (2026-11-04, §5): since `t_295b0a32` a
signed-in launch opens a channel and pushes it over the list, so `nativeShell` is not in the
accessibility tree and `channelSidebar.*` (the team rail) is only there after `Back`. The test now
waits with `ShellSettle.waitForSignedIn` and pops to the list with `ShellSettle.revealChannelList`
before the quick-switcher route it already had. Nothing was skipped or weakened: the reply's name is
still asserted non-empty, hittable and tapped, and the sheet is still checked against the **server's**
username for that reply's author.

## 4. Evidence

All runs on this tree, iPhone 16 Pro simulator (`id=4BB9CE43…`, iOS 18.3), `scripts/qa-test.py`,
real 9.11.19 at `127.0.0.1:8065`, logs under `build/logs/`.

| gate | command | result |
|---|---|---|
| focused unit tests | `… --only-testing MattermostTests/T36ThreadViewModelTests --only-testing MattermostTests/T36ThreadModelsTests --label te73-units-thread7` | **59 run / 0 skipped / 0 failed** (`build/logs/te73-units-thread7.log`), the two new tests by name |
| **mutation**: the fix reverted (`users[$0] == nil` filter, unconditional `users[post.userId]` read) | the new test alone, `--label te73-mut1` | **FAILS by name** — `XCTAssertEqual failed: ("") is not equal to ("Unknown user")` and `asked for []` (`build/logs/te73-mut1.log`); the fix was restored and the diff re-checked |
| whole unit target | `… --only-testing MattermostTests --label te73-units-whole1` | **2155 run / 10 skipped / 0 failed**, rc=0 (`build/logs/te73-units-whole1.log`) |
| dual-render gates | `bash scripts/verify-dual-render-gates.sh --allow-approved-registry` | `RESULT: PASS — dual-render debug affordances cannot reach a Release build.` |
| C1's live test, tightened | `… --only-testing MattermostUITests/T5449ThreadProfileUITests --label te73-live1` with `TEST_RUNNER_MM_AUTH_SERVER/_LOGIN/_PASSWORD` | **1 run / 0 skipped / 0 failed** (`build/logs/te73-live1.log`, 66.8 s) — the reply's `post.<id>.author` was non-empty, hittable, tapped, and the sheet showed the server's username for that reply's author |

Host note: this run happened while several other workers were building in the same tree (load average
650–870). One earlier attempt died with Xcode's `DVTiPhoneSimulator installApplication…` assertion and
one with "Invalid device state" — both runner/host failures, neither a test result; the card's own
simulator (`te73iPhone16Pro`, 4BB9CE43…) was created to stop sharing a device with them.

The whole-target run also compiled sibling cards' work that was uncommitted in this tree at the time
and has since landed on `main` (byte-identical), so 2155 is the target's size on that base — not a
claim about the 1793 that C1 measured before them.

**Published:** `2a79dc8` on `main`, rebased onto `bd13ca5` and pushed to `origin/main`, verified with
`git ls-remote` (`2a79dc8…` = `refs/heads/main`). The focused pair was re-run on that published tree:
**59 run / 0 skipped / 0 failed** (`build/logs/te73-units-thread8.log`).

## 5. Re-verification at the tip (`886a087`, 2026-11-04)

The card had been reclaimed mid-flight, so this pass **verified** rather than rebuilt: `2a79dc8` (code)
and `365e7ce` (docs) are both ancestors of `HEAD = origin/main = 886a087…` (`git ls-remote` agrees),
and the guards are where the handoff says (`MMUser.hasProfileDetails`,
`ThreadViewModel.loadProfiles` / `apply(thread:)`, `PostListDerivation.author(for:users:)`).

| gate | command | result |
|---|---|---|
| focused pair | `xcodebuild test … -only-testing MattermostTests/T36ThreadViewModelTests -only-testing MattermostTests/T36ThreadModelsTests` | **59 run / 0 skipped / 0 failed** (`build/logs/te73-units-verify2.log`); `testAnIdOnlyParticipantNeverLeavesABlankReplyAuthorAndIsStillAskedFor` and `testAFullParticipantProfileIsNotOverwrittenByALaterStub` both pass by name |
| whole unit target | `xcodebuild test … -only-testing MattermostTests` (qa derived data, `-destination "platform=iOS Simulator,name=iPhone 16 Pro"`) | **2184 run / 10 skipped / 0 failed** (`build/logs/te73-units-verify7.log`) |
| dual-render gates | `bash scripts/verify-dual-render-gates.sh --allow-approved-registry` | `RESULT: PASS — dual-render debug affordances cannot reach a Release build.` |
| the tightened live test | `xcodebuild test … -only-testing MattermostUITests/T5449ThreadProfileUITests` with `TEST_RUNNER_MM_AUTH_SERVER/_LOGIN/_PASSWORD` | **1 run / 0 skipped / 0 failed**, 29.7 s (`build/logs/te73-live-verify4.log`) — after the landing repair below |

Two measured obstacles, both recorded rather than worked around silently:

1. **The whole target SIGTRAPs in `T31HarvestCookieInstallTests` when run from this card's reused
   derived-data directory** — 4/4 attempts (`te73-units-verify1/3/5/6.log`), while the class alone is
   **6 run / 0 failed** (`build/logs/te73-t31-cookie-verify1.log`) and the very same target is green
   from the `mattermost-ios-qa` derived data (`verify7`). The crash report is not an assertion failure
   but a WebKit breakpoint: `EXC_BREAKPOINT (SIGTRAP)` on
   `WKHTTPCookieStore setCookie:` → `WebKit::allDataStores()` →
   `parametersFromEachWebsiteDataStore()` (`~/Library/Logs/DiagnosticReports/Mattermost-2026-11-04-073134.ips`).
   Both simulators tried (`4BB9CE43…`, `81A7F251…`) reproduce it; the class's own file arrived at
   `285ebf0` (07:08) and `2a79dc8` (04:39) precedes it, so this is a host/target interaction that
   post-dates and does not touch this card's code. It reddens a *whole-suite* run on some
   configurations, which is why `verify7`'s green run is quoted as the gate.
2. **The live test's landing premise no longer held at this tip** — 3/3 failures at
   `the team rail must list #perf` (`te73-live-verify1/2/3.log`), with `nativeChannelPane`
   "Town Square" pushed over the list and `Back` in the navigation bar: since `t_295b0a32` a
   signed-in launch opens a channel, so `nativeShell` is not in the tree and `channelSidebar.*` is
   only there after a pop. Repaired in the test, not the product, with the target's own helpers —
   `ShellSettle.waitForSignedIn` and `ShellSettle.revealChannelList` (§3) — and the test then passes
   in 29.7 s, still asserting and tapping `post.<replyID>.author`.

**Published on `origin/main`: `f306d2a`** — the test-premise repair on top of `886a087`, with this
section in it (`git ls-remote` agrees; this paragraph is the only later change, docs-only). Re-run on
that published tree: whole unit target **2184 run / 10 skipped / 0 failed**
(`build/logs/te73-units-verify8.log`, 54.1 s) and `T5449ThreadProfileUITests` **1 run / 0 failed**,
30.7 s (`build/logs/te73-live-verify5.log`).


