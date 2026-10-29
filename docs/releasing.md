# Releasing

Every push to `main` publishes a GitHub Release. The version increments at the
**minor** position, with the patch reset to zero:

```
v0.1.4  ->  v0.2.0  ->  v0.3.0  ->  v0.4.0  ...
```

That rule replaces the hand-cut `v0.1.x` personal builds, which bumped the patch.
The tag ladder is the only source of truth: `scripts/release_version.py` reads tags
from git, never a version file, so the number cannot drift from what was released.

## Mechanics

`.github/workflows/release.yml` runs on every push to `main`: **guard**, then **test**,
then **release**, then **package** (which builds and attaches the app). `needs: guard`
gates the two macOS jobs, and a red suite produces no tag, no release and no notes.

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
   timeout, and `CODE_SIGNING_ALLOWED=NO` so no signing identity is needed.
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
  `release_version.py` covers ten cases (no tags, minor bump, junk tags, pre-release
  suffixes, `HEAD` already tagged, `0.10 > 0.9`); `release_notes.py` covers eight
  (grouping, ordering, breaking markers, unprefixed subjects, PR links and their
  absence); `ci_simulator.py` covers five (filtering, runtime ordering, hint, empty);
  and `release_publish_selftest.sh` replays the **shipped** body of *Publish the
  release* — extracted from `.github/workflows/release.yml` at run time, never a copy
  that can drift — against a throwaway bare origin and a stub `gh`. It asserts 46 checks
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
  it against five log fixtures cut from the real logs of run 40899137785 (red: timeout,
  assertion, timeout-without-a-`Failing tests:`-block, and a red with no test name at all)
  and 40906839823 (green), asserting the exact `::error::` text in each case (15 checks),
  with the pre-fix fixed-sentence body as the negative control — it must still produce the
  generic annotation, or the checks are green by construction.
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
python3 scripts/release_version.py              # next tag, e.g. v0.3.0
python3 scripts/release_version.py --format json
python3 scripts/release_version.py --dry-run    # explains the decision on stderr
python3 scripts/release_notes.py --from v0.2.0  # what the notes will say
python3 scripts/ci_simulator.py                 # which simulator CI would pick
python3 scripts/ci_plan.py --head <sha> --tip <sha> --changed-files <file>   # the guard's verdict
python3 scripts/ci_plan.py --self-test          # 13 cases
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
Release build, ad-hoc signed and not notarized (`f5b353c`, `7685cd0`). Unzipping, the
Gatekeeper override and the bundle-id consequence are in `docs/installing.md`.

There is still no `.ipa`: shipping an iOS build needs the Apple Developer Program
membership (board card H1). When H1 clears, the natural extension is an `xcodebuild
archive` step that attaches a signed `.ipa` to the same release.

## Relationship to the board's closing gate

Two different assertions, both required before a card closes:

| Gate | Question | Script |
|---|---|---|
| push gate | is the commit on `origin/main`? | `scripts/verify-pushed.py` |
| release | does that push have a version and release notes? | this workflow |

The push gate is per card and local; the release is per push and happens in CI. A
card that closed on an unpushed commit would satisfy neither.
