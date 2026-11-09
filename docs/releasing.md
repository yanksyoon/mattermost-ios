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
patch reset to 0). Measured on 2026-11-09, over 17 days: **74 releases**, mostly three or
four a day, so `v0.71` and `v0.72` named two pushes an hour apart and the number said
nothing about what changed. The commit history, meanwhile, is already typed honestly:
405 typed subjects (164 `docs`, 82 `fix`, 71 `feat`, 47 `test`, 13 `build`, 10 `Merge`,
9 `chore` and a handful of others).

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
  tag, and the release step treats `SKIP` as "already published" (annotation + exit 0).
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
* the **test** job's red path annotates the first failing test (see **The window-server
  caveat**) and appends the same line to the summary;
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
4. `xcodebuild test -scheme Mattermost -skip-testing:MattermostUITests`, with
   `-test-timeouts-enabled YES` so a hung harness reports instead of eating the
   timeout. Signing differs by leg and is load-bearing: the **Catalyst** leg uses
   `CODE_SIGNING_ALLOWED=NO` (the macOS Keychain does not demand an
   application-identifier, so signing can be switched off), while the **simulator** leg
   signs ad-hoc (`CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=-`)
   because switching signing off strips the entitlements blob and every Keychain call then
   fails with `-34018`.
5. Fails unless the log contains `** TEST SUCCEEDED **`, and uploads the full log as
   an artifact either way. The failure branch emits **one** `::error::` line, and that line
   carries the diagnosis rather than a fixed sentence: the first entry of xcodebuild's
   `Failing tests:` block, else the test name recovered from an `exceeded execution time
   allowance` line (with the allowance that blew), else the old generic
   `TEST SUCCEEDED not found in the <leg> log`. That line is the check-run annotation a
   reader sees on the run — `gh api repos/.../check-runs/<id>/annotations` — and before
   t_f427b00b it named nothing, so a 5-minute hang was filed as "TEST SUCCEEDED not found".
   `scripts/test_annotation_selftest.sh` replays the shipped block against log fixtures on
   every source push (see **Self-testing** below).

The UI bundle is excluded on purpose: `MattermostUITests` drives a **live Mattermost
server** at `127.0.0.1:8065`, which CI does not provide. Those runs stay local and are
what a card's own gate covers.

### The window-server caveat

The hosted `macos-26` runner is a VM (`Apple Virtual Machine 1`) with **no window
server**. The test host is the app itself, so when the suite starts the app opens its
window and WebKit tries to launch a `WebContent` process — and cannot:

```
[DisplayConfigurationFetch] WebContent[13750] Failed to load a display context,
  even though we are not a headless app.
WebContent[13749] Server root port lookup error - bootstrap: not privileged
WebContent[13749] On-demand launch of the Window Server is allowed for root user only.
```

What that does to a run, measured on run `42608725459` (2026-11-09, job `test (catalyst)`):
the tests that wait for a signal WebKit never delivers fail — `T44CCallsMediaTeardownQueueTests`
(timed out after 30 s waiting for the first close to start), `T49LoggerConcurrencyTests`
(`XCTAssertEqual failed: ("timedOut") is not equal to ("success")`), and the webview
teardown/footprint cases — 400 s of test time and no name in xcodebuild's own summary.
The first red on this lane (`41719495855`, 2026-11-03T21:11Z) was a single case,
`T53MediaFootprintTests.testAStagedPayloadIsWrittenToDiskRatherThanHeldInMemory`; the lane
was green earlier the same day (`41691474450`, 18:11Z), which is why this is a *runner*
condition and not a product regression. `fe1a638` re-measured the three platform-metric
cases on 2026-11-06.

The pipeline's answer, and the limits of it, stated plainly:

* The gate is **not** relaxed. A red leg still blocks the tag and the release.
* The annotation now says **which** failure it is. When the log carries the WebKit lines
  above, the check-run annotation reads
  `test (catalyst): no window server on this runner - <test> failed or timed out while
  WebKit could not start its WebContent process ... Environment, not product` instead of a
  bare test name. `scripts/test_annotation_selftest.sh` case 6 replays a log fixture cut
  from that run and asserts the exact text, so the sentence is proven, not hoped for.
* **What can still be missed:** a genuine webview regression that only reproduces on a
  headless Catalyst host looks the same as this environment failure, and a fix for the
  environment would hide it. That is why the same suites run on the iOS Simulator leg,
  where a display exists, and why a webview-touching change should be checked on a Mac
  with a GUI session before it is called done. A Catalyst-only path (AppKit window,
  `NSWorkspace`, Catalyst-specific keychain behaviour) is **not covered by CI** today;
  the honest fix is a self-hosted Mac runner with a logged-in GUI session, and until one
  exists this paragraph is the disclosure.

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
  42608725459 (red with the WebKit "no window server" lines) and 40906839823 (green),
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

## Evidence

Filled in from the runs on 2026-11-09 (see the card's note for the same links):

| what | run |
|---|---|
| three consecutive pushes, each publishing | pending |
| one red push: no release, annotation names the test | pending |
| one re-run of a released SHA: SKIP with the reason | pending |

## Relationship to the board's closing gate

Two different assertions, both required before a card closes:

| Gate | Question | Script |
|---|---|---|
| push gate | is the commit on `origin/main`? | `scripts/verify-pushed.py` |
| release | does that push have a version and release notes? | this workflow |

The push gate is per card and local; the release is per push and happens in CI. A
card that closed on an unpushed commit would satisfy neither.
