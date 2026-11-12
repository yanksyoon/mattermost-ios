# Releasing

Every push to `main` publishes a GitHub Release. The **position** the version moves is
derived from the commits in that push, using Conventional Commits:

```
feat: ...            -> MINOR   v0.70.0 -> v0.71.0
<type>!: ...         -> MINOR   v0.70.0 -> v0.71.0   (breaking; 0.x has no stable contract)
fix: ...             -> PATCH   v0.70.0 -> v0.70.1
docs|test|build|ci|chore|Merge|anything else
                     -> PATCH   v0.70.0 -> v0.70.1   (still a release, still a tag)
```

The tag ladder is the only source of truth: `scripts/release_version.py` reads tags and
commit subjects, never a version file, so the number cannot drift from what was released.
The rule is enforced from the history, not from a human's memory, and every answer is
strictly greater than the highest tag — monotonic by construction, asserted by
`--self-test` (19 cases plus a monotonicity sweep).

### Why this rule, and what it costs

The previous rule bumped the minor position on *every* push (`v0.1.4 -> v0.2.0 -> v0.3.0`,
patch reset to 0). Measured on 2026-11-09 with `git for-each-ref refs/tags`: **74 release
tags between v0.1.0 (2026-10-23) and v0.70.0 (2026-11-04) — 12 days, about six a day**, so
`v0.71` and `v0.72` named two pushes an hour apart and the number said nothing about what
changed. The commit history, meanwhile, is already typed honestly: of 422 commit subjects on
`main`, 411 carry a Conventional-Commits type — 167 `docs`, 82 `fix`, 72 `feat`, 47 `test`,
13 `build`, 10 `Merge`, 9 `chore`, and a handful of others.

Two options were on the table:

| rule | what it buys | what it costs |
|---|---|---|
| (a) minor on every push (the old one) | nothing to remember; any push is a "feature" | the number is a push counter; `v0.71` and `v0.72` can be an hour apart, and a bug fix is announced as a feature |
| (b) Conventional-Commits semver (this one) | `feat` vs `fix` is visible in the tag and in `gh release list` | **only as honest as the commit subjects**: a fix typed as `docs:` reaches users as a patch bump |

(b) is chosen because the ladder is read by people deciding whether to download, and a
push counter does not help them; and because a mistyped subject still releases (never
skips), it only under-sells the change. A release is still cut for **every** push, so the
"push means a download" property survives: a documentation-only push produces a patch
release, which is also why the release body says the test legs were skipped rather than
claiming they were green.

### Two ways the ladder can go wrong, and the guard for each

* **A duplicate:** a re-run of the same SHA, or a duplicate webhook delivery, could cut a
  second release. `release_version.py` answers `SKIP` when `HEAD` already carries a `v*`
  tag, and the release step treats `SKIP` as "already published" (annotation + exit 0). It
  still exports `published=true`, so the **package** job may rebuild and re-upload the same
  tag's asset (`gh release upload --clobber`); the **verdict** job reads
  `reason=already-published` first and says `SKIP ... Nothing was published`, never
  `PUBLISHED`, because a re-run cut nothing.
* **An out-of-order tag:** a queued run for an older commit could start after a newer run
  released, compute the *next* number and attach it below the ladder. The release job asks
  the remote whether `HEAD` is the tip of `main` before it computes anything; if not, it
  SKIPs with the reason (annotation, exit 0).

Both are proved by `scripts/release_publish_selftest.sh` (S3 re-run, S5 superseded), and
both were proved against the real repository on 2026-11-09 (see **Evidence** at the end).

## Mechanics

`.github/workflows/release.yml` runs on every push to `main`: **guard**, then **parity**,
then **test**, then **release**, then **package**, then **verdict**. `needs: guard`
gates the two macOS jobs, and a red suite produces no tag, no release and no notes. The
`verdict` job runs whatever happened and writes the one sentence that says why this run
did or did not publish.

### Every skip says why, on the run

A reader must never see a grey "tag and publish — skipped" box and have to guess. Three
places carry the reason, and they are all on the run page, not buried in a log:

* the **guard** annotates its decision (`::notice::guard: ...` or `::notice::SKIP: this
  push is superseded ...`) and appends it to the run summary;
* the **test** job's red path annotates the first failing test (see **Three passes, and why
  they are three**) and appends the same line to the summary;
* the **release** job annotates every non-publishing outcome — `SKIP: <sha> is not the tip
  of main ...`, `SKIP: already published: <tag> at <sha> - nothing to do`, `REFUSED` for a
  pre-release tag — and exports `reason` so the **verdict** job can print one of:

  | verdict | meaning |
  |---|---|
  | `PUBLISHED <tag>` | tag, notes and (usually) the app asset are on the release |
  | `PUBLISHED ... WITHOUT the app asset` | the release exists but `package` did not finish — read that job before telling anyone to download |
  | `SKIP: already published` | a re-run or duplicate delivery of a commit that already has its release; nothing was cut |
  | `SKIP: superseded` | a newer commit landed while this run queued; the tip run releases |
  | `BLOCKED: the test gate is red` | no tag, no release; the test job names the test |
  | `BLOCKED: the release stage failed` | read its annotation; `published=false`, so nothing was packaged |

  The verdict job records the outcome; it never changes it.


### Stage 0 — guard (ubuntu-latest, seconds)

The first job is not a test, it is a decision: is this push worth two macOS test legs
and a macOS build? `scripts/ci_plan.py` takes three facts — the pushed `HEAD`, the
current tip of `main` (asked of the remote with `git ls-remote`, never a stale
remote-tracking ref) and the list of paths the push touched — and emits `is_tip`,
`docs_only` and `run_tests` as job outputs. It also writes a summary block to the run
page, so a green run with skipped jobs says why in one line.

That check used to live inside the *release* job, which is why a superseded push ran
everything and only then exited 0: run `40339556034` spent ~8 macOS minutes on a commit
that had already been superseded and was cancelled by hand, and `40341709601` was
cancelled while still queued. A cancelled run renders red, indistinguishable from a
failure — which is how a working pipeline came to look broken (board card
`t_4ae44452`, gaps G1–G4). Now a superseded run is one Linux job that ends in about
ten seconds with `is_tip=false`, every other job `skipped`, and a green check.

What the guard does **not** buy, stated so nobody relies on it: it decides at *run*
time. A run that was the tip when it started and is superseded while its macOS legs
are still queued finishes them, and the release job's own tip check then refuses to
publish. Removing that last case would need `cancel-in-progress: true`, which would
also cancel a publish that is already in flight; the setting stays `false` on purpose,
because a missed tag is cheap to re-cut and a half-made release is not. A tip check
that cannot reach the remote fails the job — "I cannot tell" is never "yes, run".

### Docs-only pushes (the G2 policy)

**Policy: a push whose every changed path is documentation skips the test legs and
still releases.** A `.md` file, or anything under `docs/`, cannot change a binary, so
two macOS test legs for it buy nothing. The release and the package job still run,
because the rule here is a release per push and a release whose only downloads are
GitHub's source archives is not what a reader came for.

The definition is deliberately narrow: documentation is a path under `docs/` or ending
in `.md`. A change to `.github/workflows/**` or `scripts/**` is never documentation,
even when the file is mostly prose, because those files *are* the pipeline. The rule
lives once, in `scripts/ci_plan.py`, proven by `--self-test` (13 cases) and run by the
guard job itself — there is no second copy of the glob in the workflow. When the
changed-file list cannot be determined at all (dispatch, force-push, first push) the
answer is "test everything"; unknown is never "nothing to do".

### Reproducing the two-push demonstration

```bash
printf '\n' >> docs/releasing.md && git add docs/releasing.md
git commit -qm "docs: demo A" && git push -q origin main
printf '\n' >> docs/releasing.md && git add docs/releasing.md
git commit -qm "docs: demo B" && git push -q origin main
```

Run A's guard asks the remote for the tip of `main` (`git ls-remote`), sees run B's
commit, and ends in seconds with `is_tip=false`: every macOS job is `skipped` and the
run is **green**, not cancelled. Run B is the tip with `docs_only=true`, so its guard
answers `run_tests=false` and only the release and package jobs do work — the release is
still cut and the app is still attached to it.

On such a run the two skipped test legs render as `test (${{ matrix.name }})`: GitHub
does not expand the matrix in the name of a job that never started. A leg that ran always
shows its name (`test (ios-simulator)`, `test (catalyst)`), so this is a rendering quirk,
not a broken template — check the guard's `reason` line for the actual decision.

### Stage 1 — test (macos-26, matrix: `ios-simulator` + `catalyst`)

The runner image ships **Xcode 26.6 (17F113)**, the same build the app is developed
against, so CI runs the real toolchain rather than a stand-in.

1. Prints the toolchain, so a future break is diagnosable from the log alone.
2. Self-tests the gate scripts — `release_version.py`, `release_notes.py`,
   `ci_simulator.py`, `verify-pushed.py` — and then
   `release_publish_selftest.sh`, which replays the shipped *Publish the release* step
   itself (see **Self-testing** below).
3. Resolves SPM dependencies (GRDB).
4. Runs the suite in **three passes** (table below), with `-test-timeouts-enabled YES` so a
   hung harness reports instead of eating the job's timeout. Signing differs by leg and is
   load-bearing: the **Catalyst** leg uses `CODE_SIGNING_ALLOWED=NO` (the macOS Keychain
   does not demand an application-identifier, so signing can be switched off), while the
   **simulator** leg signs ad-hoc (`CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO
   CODE_SIGN_IDENTITY=-`) because switching signing off strips the entitlements blob and
   every Keychain call then fails with `-34018`.
5. Decides each pass through `scripts/test_verdict.sh` — one shared implementation, so the
   three passes cannot annotate differently. On a red log it emits **one** `::error::`
   line, which is the check-run annotation a reader sees on the run page:
   * a **product assertion** — `test (catalyst): <Class.test> failed its assertions, not a
     hang - <the assertion line>`. The assertion is quoted, so the reader does not open the
     job to learn what broke.
   * a **hang** with WebKit's services refused — `WebKit cannot start in this test host -
     <Class.test> hung (timed out after 30s ...) ... Environment, not product`.
   * a hang with no WebKit refusal — the test name and the allowance/hang text, no excuse
     attached.
   * no name anywhere (a build or destination failure) — the generic
     `TEST SUCCEEDED not found in the <leg> log`.

   The environment is blamed only on the two facts together: the named test **hung**, and
   WebKit refused its helper services. Every full-suite log carries WebKit refusal lines (33
   of them in run `42617348657`), so an assertion is never filed as runner noise — that was
   the defect this rule replaced (t_6904c92b). `scripts/test_annotation_selftest.sh` replays
   the shipped script against log fixtures on every source push, including one where WebKit
   noise and a real assertion appear in the same log, plus the negative control that restores
   the old rule and must mis-file it (see **Self-testing** below).

The UI bundle is excluded on purpose: `MattermostUITests` drives a **live Mattermost
server** at `127.0.0.1:8065`, which CI does not provide. Those runs stay local and are
what a card's own gate covers.

### Three passes, and why they are three

The hosted `macos-26` runner is an `Apple Virtual Machine 1` with **3 vCPUs**. The test host
is the app itself, and WebKit's helper services cannot be started from that host — every
attempt is refused:

```
Could not signal service com.apple.WebKit.WebContent: 113: Could not find specified service
[DisplayConfigurationFetch] WebContent[13750] Failed to load a display context,
  even though we are not a headless app.
```

This is **not** a missing window server: probe `42614060467` printed `WindowServer: 163`,
`gui domain: yes`, `cpus: 3` on the runner. Three measurements decided the split (all
2026-11-09, Xcode 26.6 / 17F113):

| measurement | result |
| --- | --- |
| the whole gate scope on a 10-vCPU Mac (local `xcodebuild test`, same skips) | 2462 tests, **0 failures, 88.5 s** |
| the same scope on the 3-vCPU runner, Catalyst (run `42617348657`, job `probe (catalyst / logic)`) | 2462 tests, **10 failures, 352 s** — the failures are `T44CCallsMediaTeardownQueueTests` (both cases) and `T49LoggerConcurrencyTests` |
| the same scope on the 3-vCPU runner, iOS Simulator (run `42617348657`, job `probe (ios-simulator / logic)`) | 2462 tests, **10 failures, 572.9 s** — **the same three cases**, at 151.5 s, 20.2 s and 60.0 s |
| those classes alone on the same runner (run `42614060467`, job `probe (isolated)`) | **all green** — 1.07 s, 2.02 s, 0.21 s, `xcodebuild exit: 0` |

So the three cases are not flaky and not hung: they are timing detectors (30 s / 60 s hang
windows, per `T28TestSupport`'s contract) that a 3-vCPU VM cannot honour while 2,400 other
cases and WebKit's refused child processes compete for its threads. The suite therefore runs
in three passes on every leg, and **nothing is skipped** — every class runs exactly once per
leg, and every pass is a gate:

| pass | step | what it runs | a failure means |
| --- | --- | --- | --- |
| **gate** | `Unit tests` | everything except the four platform-service classes, the two timing-sensitive classes, and `MattermostUITests` | a **red leg**: an assertion or a hang blocks the tag and the release |
| **timing** | `Timing-sensitive tests (own process, required)` | `T44CCallsMediaTeardownQueueTests`, `T49LoggerConcurrencyTests` | a **red leg**. These get their own process so the detectors measure the queue, not the runner's load |
| **platform** | `Platform-service tests (reported, not certified here)` | `T31HarvestCookieInstallTests`, `T35PasteTests`, `T46WebFallbackTests`, `T56SelectionTests` | an **assertion** is a red leg, exactly like the gate; a **hang** is reported by name as *did not complete on this runner* (`::warning::`, job summary) and certifies nothing |

`scripts/classify_platform_tests.sh` makes the platform decision in one place and has a
self-test (green / hung / asserted / unknown, including "an assertion outranks a hang in the
same log"). The gate and timing passes both go through `scripts/test_verdict.sh`.

One more thin test surfaced on the first real run of this gate (run `42623940630`, 13:51Z,
2026-11-09): `T41ProfileTests.testThePresenceLoopStopsWhenItsTaskIsCancelled` slept 220 ms
and then required that two polls had happened — one poll in 220 ms on the loaded simulator,
so a working loop red the leg. That is a host measurement, not a loop property: it now waits
for the second poll with a 10 s hang detector and stops as soon as it lands (the
`TestSignal` contract this repo already uses, T28TestSupport). It was **not** moved into the
timing pass, because the fix belongs in the test, not in the split.

The same rule, one class over (run `43240373846`, 14:54Z, 2026-11-12): the gate pass's only case
that drives a real `WKWebsiteDataStore` — the SSO class's
`testClearingTheAuthCookieRemovesOnlyThisServersSessionCookie` — hung for the whole 300 s
allowance and red the required simulator leg with *"the test may have hung"* and no
classification, while the same case takes **0.385 s** on a Mac and passed on the neighbouring
run 202. Its first cookie write never came back: on a healthy host that one call is 306 ms of the
case's 341 ms because it is what starts WebKit's Networking service, and the failing run never
logged that start at all (see `docs/t_a5321d5e-build-note.md` §3). It **stays in the gate pass**,
and every WebKit `await` in it now goes through `requireWebKitAnswer` (a hang detector,
`T28TestSupport`): an answer is waited for at its own cost — the bounded case measures 0.371 s —
and a call that never comes back **skips** the case naming it, with a message starting
"WebKit did not answer this test host: `httpCookieStore.setCookie(MMAUTHTOKEN)` never completed in
60s". The number quoted there is the window that call was given: 60 s for the write that starts a
fresh store's WebKit service, 15 s for every call after it (see **Two windows, after a measurement**
below). A skip, not a failed assertion, is the established answer to a host missing a service
(`CertTrustTests` and the Keychain entitlement, `T53MediaTransportTests` and its fixtures); the
assertion set is unchanged, and nothing about the claim moved into another pass. If the silence
ever becomes the norm rather than an exception, moving the case into the platform pass is the
documented escalation.

The same bound, applied pass-wide (card `t_e687bad5`): the other four gate-pass classes that drive a
real cookie store — `T249bc296WebKitCookieIsolationTests` (four cases), `AuthSessionTests` (two),
`T31WebSessionHarvestTests` (one) and `ViewStoreTests` (one) — now await every WebKit call through the
same helpers and name each one (`httpCookieStore.setCookie(MMAUTHTOKEN)`, `httpCookieStore.allCookies`,
`httpCookieStore.getAllCookies`, `WebSessionCookieInstaller.install(…)`,
`WebKitSessionCookieReader.authToken`, `WebKitCookieSessionProvider.sessionData`,
`WebKitSessionCookieClearing.clearAuthCookie`). The two calls that can throw *after* WebKit answers
(`AuthSession.adoptWebSession`, `AuthCoordinator.restore`) go through `requireWebKitAnswerOrThrow`,
which rethrows the call's own error and skips only when nothing came back — so bounding a wait never
converts a product assertion into an environment excuse. Cleanup wipes stay best effort. No assertion
changed and no class moved; the per-call names and the controls are in
`docs/t_e687bad5-build-note.md`. The window those calls were given was revisited next — the call that
starts a fresh store's WebKit service now gets its own, wider detector (below).

### Two windows, after a measurement (card `t_efd0a2ad`)

The 15 s window was chosen to bound a wait, not as a claim about WebKit's cost, and one run showed the
two are not the same thing. Run `43304994377` (green) has the harvest case's cold write answering at
**13.991 s** — 1.0 s under the window — and the SSO case skipping at 15.012 s. Whether those were
"slow but alive" or "dead" could not be told apart from a case total, so the next push logged every
bounded call (`WEBKITBOUND …`, one line per call that took ≥ 1 s or never answered) and raised the
window to 120 s, far from the real cost. Run `43315247724`, leg `test (ios-simulator)`, per call:

| call | elapsed |
| --- | --- |
| `T249bc296…` seed `install(MMAUTHTOKEN,MMCSRF)` (one case) | silent past 120 s → skipped, naming the call |
| `T249bc296…` seed `install(MMUSERID,MMCSRF,MMAUTHTOKEN)` (the **next** case) | **38.330 s** — case passed at 40.231 s |
| `T31WebSessionHarvestTests` seed write | 0.008 s (13.991 s on the run above) |
| `AuthSessionTests` seed writes ×2 | 1.501 s, 1.398 s |
| `T31SSOViewModelTests`, `ViewStoreTests` writes | 0.107 s, 0.818 s |
| every call after a store's first write | 0.001–1.672 s |

The same leg's probe (four fresh stores, first write / second write / read / wipe through the same
helper) went silent for 120 s on its first three calls, then answered `removeData` in 0.715 s and every
following store in 0.015–0.088 s. So the silence is a store whose WebKit service never starts, and the
slow-but-alive mode is separate and real. On the same 3-vCPU runner under **Catalyst** the same calls
never exceeded **0.240 s** — this is the simulator's WebKit service boot, not CPU starvation.

Three modes, then, not one: fast (milliseconds), slow but alive (**4–38 s**) and never (**>120 s**). A
15 s window cuts through the middle of the second mode: 38.330 s is 23 s beyond what the window would
have waited, so that case would have been **skipped although it passes** — coverage traded for a bounded
wait, on a plain green run. The choice (recorded in `MattermostTests/T28TestSupport.swift` as
`WebKitAnswerWindow`) is **two windows**:

| window | where | value |
| --- | --- | --- |
| `.ambient` | every call after that store's WebKit service is up | **15 s** (unchanged) |
| `.coldStore` | the one call that starts it for a fresh per-server store — the first write in each real-store case | **60 s** |

60 s is **1.57×** the slowest *answered* cold write measured (38.330 s), 4.3× the 13.991 s one, and still
5× better than the 300 s allowance a skip replaces; a call that never comes back skips either way, now
naming itself after 60 s instead of 15. Controls pin both ends (`TA5321d5eBoundedWaitTests`: ambient
stays 15 s; cold stays 60 s, above 38.330 s and at or under 300/5) and re-prove the detector property on
the wide window (a 1 s answer inside 60 s still returns in ~1 s). One `WEBKITBOUND` line is written for
any call that took ≥ 1 s or never answered, so the margin is visible on every gate log instead of only in
this table. Nothing moved between passes and no assertion changed; the full distribution and the
before/after logs are in `docs/t_efd0a2ad-build-note.md`.

### Where a hung gate's stack lives: one result bundle per pass

With `-collect-test-diagnostics on-failure`, XCTest writes the stack of a test that has
exceeded its allowance — a spindump whose frames name the method the case was inside. That
stack only reaches the run if the bundle it lives in is uploaded, and until t_a4e133f6 it
sometimes was not: all three passes shared `-derivedDataPath "$RUNNER_TEMP/dd"` and let
xcodebuild name their bundles under `dd/Logs/Test`, and that directory is a bounded store,
not a record — writing a third bundle into one derived data removes the oldest (measured;
`docs/t_a4e133f6-build-note.md` §2). On run `43240373846` the gate pass hung and wrote
`Test-Mattermost-2026.11.12_14-47-40-+0000.xcresult`, the log named it, and by the time the
upload step ran `test-xcresult-ios-simulator` (`13956831755`) held only the *timing* and
*platform* bundles. A hang in the gate pass was undiagnosable from the run.

Each pass now names its own bundle outside that store:

| pass | `-resultBundlePath` |
| --- | --- |
| gate | `$RUNNER_TEMP/gate-<leg>.xcresult` |
| timing | `$RUNNER_TEMP/timing-<leg>.xcresult` |
| platform | `$RUNNER_TEMP/platform-<leg>.xcresult` |

and `Upload test diagnostics` uploads all three under `test-xcresult-<leg>` (a pass that never
ran leaves no file, so the step keeps `if-no-files-found: warn`). Nothing else about the passes,
`scripts/test_verdict.sh` or `scripts/classify_platform_tests.sh` changed.

The claim is re-provable on demand, without waiting for a real hang: `TGateHangFixtureTests`
blocks past the allowance when `TEST_RUNNER_MATTERMOST_GATE_HANG_FIXTURE=1`, and the
`self_test_gate_hang` dispatch input is the only thing that sets it. Dispatch it on `main`:

```
gh workflow run release.yml --ref main -f self_test_gate_hang=true
```

Both legs go red on purpose, and `test-xcresult-<leg>` must contain `gate-<leg>.xcresult` whose
activities name the allowance and whose spindump attachment names
`testDeliberateHangNamesThisFrame`. On every push the variable is `0`, so that case skips and
the gate stays a gate — this is the one case in the suite that skips by design, and it is why
"nothing is skipped" above means "no class is routed away from its pass".

### What the split costs, measured

One source push is **46.5 min of wall clock** end to end (run `42629436355`): catalyst
gate 5 m 05 s + timing 32 s + platform 21 s (7 m 23 s), simulator gate 23 m 31 s + timing
3 m 30 s + platform 3 m 33 s (32 m 08 s), publish 16 s, package 8 m 45 s. The two extra
invocations reuse the same `-derivedDataPath`, so the split adds **32 s on catalyst and
3 m 30 s on the simulator** — it does not rebuild the app. The simulator leg is the cost
driver because it is a 3-vCPU VM building and running 2,459 tests; caching is the lever for
that, not another matrix split.

**What is not certified on CI, said out loud:** a **hang** in the four platform-service
classes is reported, not failed — so a Catalyst-only webview path (AppKit window,
`NSWorkspace`, pasteboard, the real cookie store) can regress on a runner where WebKit never
answers and still ship. Their assertions *are* a red leg, and they were green on both legs in
run `42617348657`. A self-hosted Mac runner with a logged-in GUI session would close the gap;
until one exists, this paragraph is the disclosure, and it is repeated in each release's
notes.

The iOS destination is resolved by `scripts/ci_simulator.py` from the image's actual
simulator list, because runner images rename devices between OS releases and a
hard-coded `name=iPhone 16` rots.

### Stage 2 — release (ubuntu-latest)

`needs: [guard, test]`, and it runs when the guard says `is_tip` and the test legs
either passed or were skipped by the docs-only policy. A **red** test leg still blocks
it: the job's `if:` accepts `success` and `skipped`, never `failure`.

1. Re-runs the version, notes, asset-verifier and publish-step self-tests on the
   tagging host.
2. Exits 0 without touching anything unless `HEAD` is the tip of `main` (see
   **Tip only**).
3. Computes the next tag from the existing tags (never from a file).
4. Creates the tag **through the Releases API** (`gh release create --target <sha>`)
   and publishes with generated notes.
5. Verifies the release exists afterwards with `gh release view` rather than trusting
   the command's exit code.

**Tags are created by API, not by `git push`.** This is not a style choice. A
workflow's own token is a GitHub App, and GitHub refuses to let an App push any ref
whose history contains a change to a workflow file:

```
! [remote rejected] v0.5.0 -> v0.5.0 (refusing to allow a GitHub App to create or
  update workflow `.github/workflows/release.yml` without `workflows` permission)
```

The App cannot be granted that permission — it is not in the `permissions:` block and
never can be — so the `git tag` + `git push` route can never be reliable in a repo
whose CI files change. The Releases API is not subject to that check. Consequence: the
tags are lightweight rather than annotated, which does not affect anything that reads
them.

That failure also exposed a worse bug worth remembering: the first version retried the
push, saw its own locally created tag on `HEAD`, answered `SKIP`, and **reported
success** with no tag on the remote and no release. A retry loop that can convert a hard
failure into a green run is worse than no retry. The current logic has four distinct
outcomes — already published (exit 0), tag without release (finish it), no tag (create
both), and `SKIP` with no release tag at all (refuse with `::error::`, exit 1) — and
never treats "I cannot tell" as success.

**Notes come from commits and PRs.** `release_notes.py` groups commit subjects by
Conventional Commit type, and any `(#123)` reference in a subject becomes a linked
entry under **Pull requests**. That covers both shapes this repo can be pushed in:
direct commits and squash-merged PRs.

GitHub's own `--generate-notes` is still not used for the body: every commit so far is
a direct push, and when none carry PRs it emits only a compare link — which is exactly
what `v0.2.0` shipped with before its notes were backfilled.

Seven properties worth knowing, because each one was a deliberate choice:

- **Tests gate the release.** The tag job cannot start until both matrix legs pass —
  or until the guard has decided the push changes only documentation, which is the one
  case in which they are legitimately `skipped`. A red suite on `main` means the
  previous release stays latest, which is the point.
- **One release per commit.** If the pushed commit already carries a `v*` tag the
  script answers `SKIP` and the release stage exits cleanly. Re-running a workflow, or
  a duplicate webhook delivery, can never cut a second release for the same commit.
  `SKIP` also covers the ambiguous case: when `HEAD` carries only a *non*-release tag
  (`v0.5.0-rc1`, whose suffix `release_version.py` drops), the step prints
  `::error::SKIP with no release tag on HEAD <sha>` and exits 1 instead of guessing.
  Policy: **a pre-release tag is not a release**, and no release is cut for that
  commit until the tag is deleted or a new commit is pushed — cutting the next version
  on a commit someone deliberately marked as a candidate would put the ladder ahead of
  the code. (That case used to abort inside a `set -e` assignment and leave a red job
  with no reason in the log at all.)
- **Tip only.** The first thing the release job asks the remote is whether `HEAD` is
  `git ls-remote origin refs/heads/main`; if it is not, the run prints
  "… is not the tip of main (…); superseded, no release cut." and exits 0 without
  touching anything. This is the only thing standing between a queued run and a
  mis-ordered ladder: runs serialise (below), so a superseded run can start *after* a
  newer one has released, and without the guard it would compute the *next* version
  and attach it to an **older** commit (`v0.6.0` below `v0.5.0`). A failed
  `ls-remote` is not a tip mismatch — `set -e`/`pipefail` surfaces git's exit status
  and the job goes red, because "I cannot tell" is never success.
- **Serialised.** `concurrency: release-${{ github.ref }}` with
  `cancel-in-progress: false` queues runs instead of racing for the same tag. There is
  no retry loop: `1e64fbf` removed the five-attempt one, because a loop that re-reads
  tags can read the tag it just created *locally*, answer `SKIP`, and report success
  with nothing on the remote and no release. A run now either publishes or fails.
- **Self-testing.** A rule that has never been shown to fail is not a rule.
  `release_version.py` covers 19 cases (no tags, feat -> minor, fix/docs/chore -> patch,
  a feat anywhere in the range, `!` and `BREAKING CHANGE`, junk tags, pre-release
  suffixes, `HEAD` already tagged, `0.10 > 0.9`, patch passing 9) plus a monotonicity
  sweep that asserts every non-`SKIP` answer is above the highest tag; `release_notes.py`
  covers eight (grouping, ordering, breaking markers, unprefixed subjects, PR links and
  their absence); `ci_simulator.py` covers five (filtering, runtime ordering, hint, empty);
  and `release_publish_selftest.sh` replays the **shipped** body of *Publish the
  release* — extracted from `.github/workflows/release.yml` at run time, never a copy
  that can drift — against a throwaway bare origin and a stub `gh`. It asserts 55 checks
  over 8 scenarios (publish, API rejection, re-run, tag without release, superseded,
  local-only tag, pre-release tag, `ls-remote` down) and keeps the negative control:
  `a4b6467`'s pre-fix body, replayed against an origin whose hook models GitHub's
  workflow-file rejection, must still exit 0 with no tag and no release. It runs in
  both CI legs and needs only bash, git and python3. Two newer suites join it:
  `ci_plan.py` covers the guard's decision (29 checks over 13 cases, including "cannot
  tell" and "a prose file under `.github/` is not documentation") and
  `verify_release_asset.py` covers the post-upload check (12 checks over 11 cases, one
  per way an upload can be wrong). `test_annotation_selftest.sh` covers the *Unit tests*
  step's own verdict: it replays the shipped failure branch and the shipped summary below
  it against six log fixtures cut from the real logs of runs 40899137785 (red: timeout,
  assertion, timeout-without-a-`Failing tests:`-block, and a red with no test name at all),
  42608725459 (red, cut from the real catalyst leg) and 40906839823 (green),
  asserting the exact `::error::` text in each case (20 checks), with the pre-fix
  fixed-sentence body as the negative control — it must still produce the generic
  annotation, or the checks are green by construction.
  `release_watchdog.py` covers its own verdict (6 cases: OK, STALE on the real five-day
  gap, QUIET when main has not moved, no release at all, a release without a timestamp).
- **Skipped is not red.** A superseded push ends as one green Linux job with the macOS
  jobs `skipped`, and the run page carries the guard's one-line reason. The old
  behaviour — a full 13-minute run that exited 0 having done nothing — was worse than
  red because nobody could see it, and the cancelled runs that came from trying to
  avoid it were worse than that because they looked like failures.
- **The upload is verified, not trusted.** `gh release upload` returning 0 proves the
  API call returned 0 and nothing else. After the upload the package job asks the API
  three questions — is the release published, does its asset list hold this zip at the
  exact byte size of the local file, and does the tag point at the commit we built —
  and fails the job if any answer is no. A release with source archives only, a
  truncated asset, or an asset built from another commit can no longer pass.

## Locally

```bash
python3 scripts/release_version.py              # next tag, e.g. v0.71.1
python3 scripts/release_version.py --format json
python3 scripts/release_version.py --dry-run    # explains the decision on stderr
python3 scripts/release_notes.py --from v0.70.0 # what the notes will say
python3 scripts/ci_simulator.py                 # which simulator CI would pick
python3 scripts/ci_plan.py --head <sha> --tip <sha> --changed-files <file>   # the guard's verdict
python3 scripts/ci_plan.py --self-test          # 13 cases
python3 scripts/release_watchdog.py --repo yanksyoon/mattermost-ios   # the 24 h report, read-only
bash scripts/release_publish_selftest.sh        # replay the release step; 8 scenarios
# and, against the real API, read-only, to re-check a release that already exists:
python3 scripts/verify_release_asset.py --repo yanksyoon/mattermost-ios --tag v0.6.0 \
  --sha 7685cd002479cda1ff2023ea9d50b30f1a709646 \
  --asset Mattermost-macOS-v0.6.0.zip --size 13402755
```

All of these are read-only and safe during a card run — they only read tags, simulator
state and the GitHub API, and each self-test works entirely inside a `mktemp`
directory.

The test suite, the way CI runs it (the gate pass; add `-only-testing:` for the timing and
platform passes). On a Mac Catalyst leg, sign ad-hoc — `CODE_SIGNING_ALLOWED=NO` fails to
load the unsigned `WebRTC.framework` out of DerivedData (`Trying to load an unsigned
library`), which looks like a test failure and is not one:

```bash
xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -skip-testing:MattermostUITests \
  -skip-testing:MattermostTests/T31HarvestCookieInstallTests \
  -skip-testing:MattermostTests/T35PasteTests \
  -skip-testing:MattermostTests/T46WebFallbackTests \
  -skip-testing:MattermostTests/T56SelectionTests \
  -skip-testing:MattermostTests/T44CCallsMediaTeardownQueueTests \
  -skip-testing:MattermostTests/T49LoggerConcurrencyTests \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 300 \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=-
```

On a 10-vCPU Mac that ran **2462 tests, 9 skipped, 0 failures in 88.5 s** (2026-11-09,
Xcode 26.6) — the control for the three-pass split in § *Three passes*.

## Stage 3 — package (macos-26)

`needs: [guard, test, release]`, gated on the guard and on the release having published,
so it never builds an app that has no release to attach to. It builds a Mac Catalyst
Release app, stamps the tag into `Info.plist`, re-signs, verifies the seal, zips with
`ditto`, uploads to the release — and then **verifies the upload** (above). What the
archive contains is in `docs/installing.md`.

## What a release contains

A tag, generated notes, GitHub's automatic source archives (`zip` / `tar.gz`), and the
built app: `Mattermost-macOS-<tag>.zip` — a universal (`arm64` + `x86_64`) Mac Catalyst
Release build, ad-hoc signed and not notarized (`f5b353c`, `7685cd0`).

### Installable by someone who is not us

The zip is built for a stranger: the app is re-signed ad-hoc with
`codesign --force --deep --sign -` after the version is stamped into `Info.plist` (editing
the plist breaks the original seal), `ditto` preserves that signature and the extended
attributes, and the release body carries a **one-line install** generated from the tag:

```bash
curl -fL -o /tmp/mm.zip https://github.com/yanksyoon/mattermost-ios/releases/download/<tag>/Mattermost-macOS-<tag>.zip \
  && rm -rf /tmp/mm-unz /Applications/Mattermost.app \
  && ditto -x -k /tmp/mm.zip /tmp/mm-unz \
  && xattr -dr com.apple.quarantine /tmp/mm-unz/Mattermost-macOS-<tag>/Mattermost.app \
  && cp -R /tmp/mm-unz/Mattermost-macOS-<tag>/Mattermost.app /Applications/ \
  && open /Applications/Mattermost.app
```

The `xattr -dr com.apple.quarantine` is in the line because macOS stamps the quarantine
bit on **download**, not on build: a zip cannot ship "quarantine stripped", so the install
command has to strip it after unpacking. What a downloader can check before trusting it:

```bash
mkdir -p /tmp/clean-download && cd /tmp/clean-download
curl -fLO https://github.com/yanksyoon/mattermost-ios/releases/download/<tag>/Mattermost-macOS-<tag>.zip
ditto -x -k Mattermost-macOS-<tag>.zip .
codesign --verify --deep --strict --verbose=2 Mattermost-macOS-<tag>/Mattermost.app
codesign -dv --verbose=2 Mattermost-macOS-<tag>/Mattermost.app 2>&1
```

A real run of that, against a published asset, is quoted in **Evidence** below.

Unzipping by hand, the Gatekeeper override and the bundle-id consequence are in
`docs/installing.md`.

There is still no `.ipa`: shipping an iOS build needs the Apple Developer Program
membership (board card H1). When H1 clears, the natural extension is an `xcodebuild
archive` step that attaches a signed `.ipa` to the same release.

## The watchdog: "nothing released in 24 h" is a report, not a switch

`.github/workflows/release-watchdog.yml` runs on a six-hourly schedule (`17 */6 * * *`)
and on demand. It is read-only: it asks the API for the latest release and for `main`,
writes a line to the run summary, and annotates. It never pauses dispatch, cancels a run
or holds a lock — `hermes pause` halts the scheduler that would resume the work, and that
mistake already cost three days.

The verdicts, from `scripts/release_watchdog.py` (`--self-test`, 6 cases):

| verdict | when | exit |
|---|---|---|
| `OK` | a release was published inside the window | 0 |
| `QUIET` | nothing released in the window, but `main` has not moved — nothing to release | 0 |
| `STALE` | nothing released in the window **and** `main` has moved past the release — the exact shape of the five-day gap | 1 |

`STALE` is the alarm: it is a red scheduled run with the sentence and the two SHAs, not a
paused scheduler. `QUIET` is printed but green, because a repository nobody pushed to is
not a broken pipeline. A failure to *ask* the API exits 2 and says so — "cannot tell" is
never "ok".

Proof on GitHub, 2026-11-09: run
[42646475013](https://github.com/yanksyoon/mattermost-ios/actions/runs/42646475013) (the
workflow dispatched by hand; the schedule `17 */6 * * *` fires on the default branch, which is
where it lives) printed `SELF-TEST: PASS`, then
`release watchdog: OK - last release v0.72.2 was published 0.6 h ago (window 24 h)` and the
same line as a `::notice::`. The alarm path, run against the same API with the window forced
to zero, printed
`STALE - no release in 0.7 h (last: v0.72.2) and main has moved since it (main 95cd4844,
released 17278e6d) - pushes are not reaching main, or the pipeline is not publishing`
and exited 1 — a red report, not a switch.

## Evidence

Measured on 2026-11-09, all times UTC. The card's note (t_6904c92b) carries the same links.

### Three consecutive pushes, each publishing

Pushed one at a time, so each run was the tip of `main` when its release job ran:

1. `93ac31d` → run [42629436355](https://github.com/yanksyoon/mattermost-ios/actions/runs/42629436355)
   → **[v0.72.0](https://github.com/yanksyoon/mattermost-ios/releases/tag/v0.72.0)**. Six of
   six jobs green — guard, parity, `test (catalyst)`, `test (ios-simulator)`, `tag and
   publish`, `package Mattermost.app` — and the verdict job annotated
   `PUBLISHED v0.72.0 - tag, generated notes and the signed Mattermost-macOS-v0.72.0.zip
   asset are on the release (tests: success).` Asset: `Mattermost-macOS-v0.72.0.zip`,
   31,925,466 B. The version moved `v0.71.0 → v0.72.0` (MINOR) because the push range
   contains the `feat(release):` commit.

Each entry is written by the push *after* it, because a release cannot describe its own run
before that run exists; the card's note carries the last ones.

2. `d224215` → run [42637674057](https://github.com/yanksyoon/mattermost-ios/actions/runs/42637674057)
   → **[v0.72.1](https://github.com/yanksyoon/mattermost-ios/releases/tag/v0.72.1)**. A
   documentation-only push, so the guard annotated `test legs skipped by policy (tip of main;
   documentation only (1 file(s)), test legs skipped, release still cut)`, the test job shows
   as **skipped** (not red), and the release body says `**Tests:** skipped for this push -
   documentation only` rather than claiming a green suite. `v0.71.0`'s body claimed
   "Verified ... unit suites green" for exactly this kind of push; that is the bug this line
   replaces.

3. `17278e6` → run [42639190623](https://github.com/yanksyoon/mattermost-ios/actions/runs/42639190623)
   → **[v0.72.2](https://github.com/yanksyoon/mattermost-ios/releases/tag/v0.72.2)**. Also
   documentation only, and the same guard annotation and body line. Three consecutive pushes,
   three releases, no human step between them.

### One red push: no release, and the annotation names the test

`06a14b6` added one deliberately failing test (`T00CDGateProbeTests`, removed by the commit
after it) and pushed it to `main`: run
[42639972490](https://github.com/yanksyoon/mattermost-ios/actions/runs/42639972490).

* Both legs red: `test (catalyst)` and `test (ios-simulator)`, step `Unit tests`.
* `tag and publish` and `package Mattermost.app` **skipped**; the releases list still showed
  `v0.72.2` as the newest, so nothing shipped.
* The check-run annotation on `test (catalyst)` read — verbatim:

  ```
  test (catalyst): T00CDGateProbeTests.testTheReleaseGateBlocksARedPush failed its
  assertions, not a hang - failed - deliberate red push (t_6904c92b): this commit must
  publish nothing
  ```

  It names the test, quotes the assertion, and does **not** say "Environment, not product" —
  the log for that run carries WebKit refusal lines, which is exactly the case the old rule
  mis-filed.

### A re-run of the same SHA: SKIP, never a second release

The red commit's correction (`95cd484`, which also drops the probe test) produced
run [42646382529](https://github.com/yanksyoon/mattermost-ios/actions/runs/42646382529) →
**[v0.72.3](https://github.com/yanksyoon/mattermost-ios/releases/tag/v0.72.3)**, six of six
jobs green.

Re-running that commit's release job (`gh run rerun 42646382529 --job 129275826419`, while
`95cd484` was still the tip) produced, as the check-run annotation:

```
SKIP: already published: v0.72.3 at 95cd4844 - nothing to do (re-run or duplicate delivery
of a commit that already has its release)
```

and the release list still held exactly one `v0.72.3` (target `95cd484`), so the second
attempt cut nothing. Only the release job was re-run here, to keep the macOS minutes down: a
full re-run would execute the gate again first and then take this same path — the decision is
`git tag --points-at HEAD` plus `gh release view`, neither of which depends on which pass
failed or how the run was started.

### The asset is installable by someone who is not us

`v0.72.0`'s zip downloaded into a clean directory and unpacked with `ditto -x -k`:

```
$ codesign -dv --verbose=2 Mattermost-macOS-v0.72.0/Mattermost.app
Executable=.../Mattermost.app/Contents/MacOS/Mattermost
Identifier=com.mattermost.ios
Format=app bundle with Mach-O universal (x86_64 arm64)
CodeDirectory v=20400 size=81579 flags=0x2(adhoc) hashes=2543+3 location=embedded
Signature=adhoc
Info.plist entries=39
TeamIdentifier=not set
Sealed Resources version=2 rules=13 files=11

$ codesign --verify --deep --strict --verbose=2 Mattermost-macOS-v0.72.0/Mattermost.app
... Mattermost.app: valid on disk
... Mattermost.app: satisfies its Designated Requirement
```

`CFBundleShortVersionString` is `0.72.0`, `CFBundleVersion` `188`,
`CFBundleIdentifier` `com.mattermost.ios`, `LSMinimumSystemVersion` `14.0`;
`xattr -p com.apple.quarantine` reports `No such xattr` (curl does not stamp one — a browser
download does, which is why the release body's install line strips it after unpacking).
sha256 `0b05fc33b7e5b6a8123f7cebc60838ccfbdf80a599d76401f97dca73da076b73`.

### Installed from the release, on a real Mac

The **published bytes**, installed at `/Applications/Mattermost(ios).app` on 2026-11-09 —
not a build from the tree, because the question is whether the download works, not whether
the checkout builds:

```
$ gh release download v0.72.4 --repo yanksyoon/mattermost-ios \
    --pattern 'Mattermost-macOS-v0.72.4.zip' --dir asset-check
$ shasum -a 256 asset-check/Mattermost-macOS-v0.72.4.zip
619ca49c9d9eb6b20bf6a9e670aa6b457ca620fa323afabfced28ae6ed6d895d   # the asset's own digest
$ ditto -x -k Mattermost-macOS-v0.72.4.zip unz
$ codesign -dv --verbose=2 unz/Mattermost-macOS-v0.72.4/Mattermost.app
Identifier=com.mattermost.ios
Format=app bundle with Mach-O universal (x86_64 arm64)
CodeDirectory v=20400 size=81579 flags=0x2(adhoc) hashes=2543+3 location=embedded
Signature=adhoc
TeamIdentifier=not set
$ codesign --verify --deep --strict unz/Mattermost-macOS-v0.72.4/Mattermost.app   # rc=0
```

Then `mv` the previous bundle aside, `ditto` the verified one to the install path,
`xattr -dr com.apple.quarantine`, `lsregister -f`, `open -n`. **No re-sign here:** the
version stamp and the signature already come from the package job, and re-signing on the
installing Mac would only make the installed copy stop being the published artifact. The
`codesign --force --deep -s -` step documented in `docs/installing.md` is for a build taken
straight from the tree, where editing `Info.plist` breaks the seal.

Observed on the installed copy:

```
Info.plist: 0.72.4 (194), com.mattermost.ios, LSMinimumSystemVersion 14.0
codesign --verify --deep --strict: rc=0
xattr: com.apple.provenance                 (no com.apple.quarantine)
System Events: "Mattermost, 1, Mattermost"  (one window, (244, 79) 1024x768)
scripts/verify-notification-registration.sh: rc=0 ("registered with the system notification table")
```

It replaced a copy that reported `0.1.7 (8)` — a build that never went through the package
job, so the tag was never stamped into its `Info.plist`. That is the drift this install
closes, and why the installed version is now claimable as a fact rather than a memory.

`v0.72.4`'s own run was documentation only, so its test legs show **skipped** by the G2
policy above, not green. The binary it ships is built from the tree that the fully green run
[42646382529](https://github.com/yanksyoon/mattermost-ios/actions/runs/42646382529) tested:
`git diff --stat v0.72.3 v0.72.4` is one file — `docs/releasing.md`, 32 insertions — and
nothing outside `*.md`.

## Relationship to the board's closing gate

Two different assertions, both required before a card closes:

| Gate | Question | Script |
|---|---|---|
| push gate | is the commit on `origin/main`? | `scripts/verify-pushed.py` |
| release | does that push have a version and release notes? | this workflow |

The push gate is per card and local; the release is per push and happens in CI. A
card that closed on an unpushed commit would satisfy neither.
