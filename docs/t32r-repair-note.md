# T32-R — repair note (T32-AV F1/F2/F3)

Card: **t_369d7024**. Repairs the three findings of the T32-AV review of `108377a`
(`~/.hermes/profiles/mmios-qa/cache/scratch/t32av/T32-AV-verdict.md`, attached to the review card as
`T32-AV-verdict.md`). The `sidebar` surface stays behind `-surfaceMode sidebar=native`; this card does
**not** flip it (the flip is a separate approval commit after the AV re-runs its probes).

---

## 1. What was wrong

### F2 (MEDIUM) — a one-team account lost the pane's `nativeSidebar` identifier

`NativeChannelSidebarPane` hands the pane's `List` to `NativeTeamSidebarPane` when
`sidebar=native`. That wrapper applies `.accessibilityElement(children: .contain)` +
`.accessibilityIdentifier("nativeTeamSidebar")`. When the wrapper's subtree resolves to a **single**
element — the one-team state and the loading state (neither draws a rail) — SwiftUI gives the
wrapper's identifier to that child, i.e. to the pane's `CollectionView`, and the `List`'s own
`nativeSidebar` identifier is gone:

```
CollectionView, identifier: 'nativeTeamSidebar', label: 'Sidebar'      ← was 'nativeSidebar'
  Cell … 'Workspace', 'Local Mattermost', 'Perf', 'No channel selected', 'All threads'
```

Measured on the pre-repair tree (iPad Pro 11-inch M5 / iOS 26.0, one-team throwaway account, only the
flag differing):

```
one team, sidebar=web:    nativeSidebar exists=true   nativeTeamSidebar exists=false
one team, sidebar=native: nativeSidebar exists=false  nativeTeamSidebar exists=true  rows exist=true
```

`nativeSidebar` is the identifier `MattermostUITests.swift`'s T30 test asserts ("the shell's sidebar
hosts the channel list placeholder"), so the flag flip would have broken a green shipped test. The
empty and failure states had **no** pane identifier at all (the state screen replaces the list).

### F3 (LOW) — the empty/failure container identifiers were never in the tree

`teamSidebar.emptyState` / `teamSidebar.errorState` sat on the state screens' `List`s, inside the
identified team region, and never resolved — only the inner `teamSidebar.empty`, `teamSidebar.error`
and `teamSidebar.retry` did. A future test quoting the documented identifier would silently never
match.

### F1 (LOW) — `docs/THIRD_PARTY_NOTICES.md` had no T32 section

Every previous native card has a per-card upstream read set (§5 T28, §6 T29, §7 T30, §8 T31). T32
added none. Per-file Apache-2.0 headers were present, so there was no licence exposure.

---

## 2. What changed

| File | Change |
|---|---|
| `Mattermost/UI/Native/NativePanePlaceholders.swift` | new `NativeSidebarAnchorRow` (the pane's server row) carrying `nativeSidebar` as a **leaf**; `sidebarList` draws it and no longer identifies the `List`; the reason is stated at both sites |
| `Mattermost/UI/Native/Sidebar/TeamSidebarView.swift` | the empty and failure screens draw the anchor row too (so `nativeSidebar` resolves there); the dead `teamSidebar.emptyState` / `teamSidebar.errorState` container identifiers are removed, with the resolving identifiers named in a comment |
| `MattermostUITests/T32-SidebarIdentifiersTests.swift` | new: six stub-backed UI tests, one per content state + the `sidebar=web` control |
| `build/uitest-server/mm_stub.py` | `--teams N`, `--teams-delay`, `--teams-fail` and the `/users/me/teams{,/members,/unread}` + `/users/{id}/preferences` endpoints, so every sidebar state is reachable without a real server |
| `scripts/t32r-sidebar-identifiers.sh` | starts the five fixtures, runs the test class, cleans up |
| `docs/THIRD_PARTY_NOTICES.md` | §9 — T32 upstream read set (F1) |
| `docs/parity.md` | T32 row names the identifiers that resolve and the repair |
| `docs/t32-build-note.md` | §8.7 corrected (what "always drawn" did and did not fix), §8.8/§8.9 for the AV findings, §14 the repair + the AV's closures and remaining limits |

### The identifier contract after the repair (build note §14.1)

| State (`sidebar=native`) | `nativeSidebar` | `nativeTeamSidebar` | state screen |
|---|---|---|---|
| loading | ✅ | ✅ | — |
| one team (no rail) | ✅ | ✅ | `sidebarCurrentTeam` |
| rail (2+ teams) | ✅ | ✅ | `teamSidebar.rail`, `teamSidebar.team.<id>` |
| zero teams | ✅ | ✅ | `teamSidebar.empty`, `teamSidebar.retry` |
| load failed | ✅ | ✅ | `teamSidebar.error`, `teamSidebar.retry` |
| `sidebar=web` (any state) | ✅ | absent (correct: no team region) | — |

The fix is structural, not a shim: `nativeSidebar` now sits on a leaf row, and a leaf cannot be
shadowed by any container that wraps it. The anchor row is also the honest answer to "which server
does this pane belong to?" while the team region replaces the channel list.

---

## 3. Evidence (this host, 2026-10-25)

### 3.1 The tests fail on `108377a` and pass after the fix

Baseline is a **detached worktree at `108377a`** with only the new test file and the stub fixtures
copied in (the audited tree is untouched):

```sh
git worktree add <scratch>/base 108377a
cp MattermostUITests/T32-SidebarIdentifiersTests.swift <scratch>/base/MattermostUITests/
cp build/uitest-server/mm_stub.py                       <scratch>/base/build/uitest-server/
cd <scratch>/base && xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=iOS Simulator,id=DC3E9FB7-E4A0-4B24-8DBB-7960A059EC7A' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/t32r-ui-base \
  -only-testing:MattermostUITests/T32SidebarIdentifiersTests
```

`108377a` — `Executed 6 tests, with 4 failures`:

```
testOneTeamPaneKeepsBothIdentifiersWithTheFlagOn                FAIL  "F2: a one-team account must keep the pane's `nativeSidebar` identifier…"
testLoadingStateDrawsThePaneAndKeepsBothIdentifiers             FAIL  "a loading team region must not remove the pane's identifier"
testZeroTeamsEmptyStateIsReachable                              FAIL  "…and so must the pane (F2: every content state)"
testTeamsFailureStateIsReachable                                FAIL  "F2: the failure state must not lose the pane's identifier either"
testOneTeamPaneFlagOffKeepsThePaneIdentifierAndDropsTheRegion   pass  (control: T30's flag-off pane was never broken)
testTwoTeamRailKeepsBothIdentifiers                             pass  (control: the two-team state T32-AV passed)
```

After the repair, same command on the working tree — `Executed 6 tests, with 0 failures …
** TEST SUCCEEDED **` (`~/Library/Developer/Xcode/DerivedData/t32r-ui-ids`).

The `-only-testing` name here is `MattermostUITests/T32SidebarIdentifiersTests`; the four failing
tests are exactly the F2/F3 states, and the two controls are the states the AV had already passed, so
the test file measures the finding and not the whole surface.

### 3.2 The whole UI suite (no regression) and the fixtures' ports

```sh
# every fixture the older suites need, plus this card's five:
#   8111 general (one team)  8112 stalled page  8113 cookie session  8114 auth  8115 expired session
#   8116 zero teams  8117 two teams  8118 slow teams  8119 failing teams  8443 TLS
xcodebuild test … -only-testing:MattermostUITests
# Executed 25 tests, with 4 tests skipped and 0 failures     ← the shipped suite
# Executed 6 tests, with 0 failures                          ← this card's identifier tests
# Executed 31 tests, with 4 tests skipped and 0 failures
# ** TEST SUCCEEDED **
```

Log: `docs/t32r-uisuite-2026-10-25.log`. The four skips are the environment-gated ones the shipped
suite already had (two live-server auth tests, the live rail test, the live SSO test).

Two host lessons recorded here because they cost a run each:

- **Ports.** 8111–8115 and 8443 were already taken (general stub, stalled page, cookie session, the
  two T31 auth fixtures, TLS). This card's fixtures use **8116+** so starting them cannot shadow
  another test's server — the first full-suite attempt did exactly that and failed
  `testRevokedStoredSessionShowsTheSessionExpiredBanner` (`:8115`) and
  `testCertPromptShownForSelfSignedServer` (TLS stub never started).
- **Simulators.** A full-suite run with four other simulators booted (left over from other sessions)
  had the UI-test runner killed and restarted mid-suite; `xcodebuild` then reported
  `** TEST FAILED **` with 0 per-test failures and a short test count. With the spare simulators shut
  down, the same command ran 31/31 with no restarts and `** TEST SUCCEEDED **`.

### 3.3 Mac Catalyst unit suite (DoD)

```sh
xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/t32r-catalyst \
  -only-testing:MattermostTests
# Test Suite 'T32TeamSidebarTests' … Executed 42 tests, with 0 failures
# Test Suite 'MattermostTests.xctest' … Executed 697 tests, with 4 tests skipped and 0 failures
# ** TEST SUCCEEDED **
```

The T32 suite count (42) is unchanged — the repair adds no unit-test surface (the identifiers live in
the accessibility tree, which only a UI test can read) and removes none. The four skips are the same
environmental ones T32-AV recorded (no keychain entitlement on the ad-hoc host, the live-mention opt-in
test, two self-signed fixtures).

### 3.4 Dual-render gates

```sh
bash scripts/verify-dual-render-gates.sh --allow-approved-registry
# RESULT: PASS — dual-render debug affordances cannot reach a Release build.
```

`sidebar` is still **not** in `nativeApprovedSurfaces` (the registry is still `[.auth]`), so the
surface cannot ship native until the flip commit. The sidebar fixtures (four new stub ports,
8116–8119, plus the general stub on 8111) are UI-test fixtures, not a runtime affordance.

### 3.5 The shipped T30 test that F2 would have broken

`MattermostUITests/testNativeShellDeepLinkLandsOnTheChannelInTheNativeStack` ends with
`XCTAssertTrue(element(app, "nativeSidebar").exists, "the shell's sidebar hosts the channel list
placeholder")`. It runs with `sidebar=web` (the shipping default), so the repair had to keep the
flag-off pane byte-for-byte compatible while adding a stub fixture that now *serves teams* on :8111 —
both were re-run: `Executed 2 tests, with 0 failures … ** TEST SUCCEEDED **`
(`testNativeShellDeepLinkLandsOnTheChannelInTheNativeStack`,
`testWebPaneIsUnchangedWithoutTheSurfaceFlag`).

### 3.6 One stale assertion found on the way (fixed)

Re-running the card's own live rail test
(`testRealServerTeamRailShowsBothTeamsAndSwitchesBetweenThem`) against the real server failed, and it
was **the test, not the rail**:

```
XCTAssertTrue failed - ops must carry the server's mention count, got '5 mentions'
```

T32 shipped a hard-coded `contains("2")` for the seeded mention count, but mentions *accumulate* in
the throwaway fixture (T32-AV's own probe posted an @-mention into `ops-standup`, and the rail was
correctly showing the server's 5). The test now reads `/users/me/teams` +
`/users/me/teams/unread` with the fixture credentials and compares the rail's value with the server's
own number, so the assertion tests "badge = server count" instead of "the fixture's history". This is
the only change outside the F1/F2/F3 scope; it is a test-only assertion, and without it the AV's
re-run of the evidence would have produced a red card for a correct rail.


---

## 4. Why the stub fixtures, and what they do not cover

A UI test cannot pin an accessibility identifier from a unit test, and the state under test *is* a
different account shape (0, 1, 2+ teams) or a different server answer (slow, 500). The stub gained
`--teams/--teams-delay/--teams-fail` plus the team endpoints so the states are deterministic offline
and need neither Docker nor a real account:

```sh
python3 build/uitest-server/mm_stub.py --port 8111                   # one team, also the general stub
python3 build/uitest-server/mm_stub.py --port 8116 --teams 0         # zero teams → empty state
python3 build/uitest-server/mm_stub.py --port 8118 --teams-delay 8   # teams in flight → loading
python3 build/uitest-server/mm_stub.py --port 8119 --teams-fail      # 500 → failure state
python3 build/uitest-server/mm_stub.py --port 8117 --teams 2         # rail
bash scripts/t32r-sidebar-identifiers.sh                            # starts all five and runs the class
```

Ports 8111–8115 and 8443 belong to the older suites (general stub, stalled page, cookie session, the
two T31 auth fixtures, TLS); the sidebar fixtures therefore start at 8116 so running them cannot
shadow another test's server.

Not covered here, on purpose:

- **Real-server 0-team / 1-team accounts.** T32-AV closed both against the real server (their AVR2 /
  AVR3) and those results stand; this card adds the *deterministic* regressions for the same states,
  not a second live audit.
- **VoiceOver / Dynamic Type / dark-mode captures.** The identifiers are read from the accessibility
  tree; no second sensory audit was performed. The build note's §11 limits are unchanged.
- **The flag flip.** Still out of scope: `sidebar` stays behind `-surfaceMode sidebar=native` until a
  re-run of the AV probes is green and a separate approval commit lands.
