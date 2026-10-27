# Release pipeline: what actually failed, and what closed the gaps

Board card `t_4ae44452`. Everything below was re-derived from `gh run view --log`,
`gh release list`, `gh release view` and `git ls-remote --tags` on 2026-10-26, not from
the card's summary. Where the card was imprecise it is noted.

## F1 — the tag push was rejected (real, confirmed)

Run `40332873749`, job *tag and publish*, 13:55:38Z — verbatim:

```
current=v0.4.0 head_tags=[] next=v0.5.0
To https://github.com/yanksyoon/mattermost-ios
 ! [remote rejected] v0.5.0 -> v0.5.0 (refusing to allow a GitHub App to create or
   update workflow `.github/workflows/release.yml` without `workflows` permission)
error: failed to push some refs to 'https://github.com/yanksyoon/mattermost-ios'
attempt 1: tag push for v0.5.0 lost a race, retrying
```

The retry's own diagnosis ("lost a race") was wrong: nothing had raced. A workflow's
`GITHUB_TOKEN` is a GitHub App, and GitHub refuses to let an App push any ref whose
history contains a change to a workflow file. `permissions:` cannot grant it.

Fixed in `1e64fbf` + `75796c1` by creating the tag through the Releases API
(`gh release create --target <sha>`). Verified working: run `40335431737` printed
`RELEASE CREATED: v0.5.0 at 75796c1a`, and `git ls-remote --tags` shows that tag on
`75796c1`.

## F2 — the retry loop greened a run that published nothing (confirmed, worse than F1)

Same run, three seconds later (13:55:41Z), second loop iteration:

```
current=v0.5.0 head_tags=['v0.5.0'] next=SKIP
HEAD a4b6467 already carries a release tag; nothing to do.
  existing: v0.5.0
```

`v0.5.0` was a tag that iteration had just created **locally**; it was never on the
remote. The step took the `SKIP` branch and `exit 0`. `gh run view 40332873749 --json`
reports that job, and the run, as `success` — while `v0.5.0` did not exist on GitHub
until 14:12:46Z, when a different run created it. A retry that converts a hard failure
into a green run with no tag and no release is the worst failure mode in the pipeline.

The loop is gone (`1e64fbf`). The step now has four explicit outcomes — already
published / tag-without-release (finish it) / no tag (create both) / `SKIP` with no
release tag at all (refuse with `::error::`, exit 1) — and
`scripts/release_publish_selftest.sh` keeps the negative control: `a4b6467`'s body,
replayed against an origin that models the rejection, must still reproduce the silent
green (55 checks, 8 scenarios + the control).

## F3 — what the owner saw: cancelled runs that look like failures (confirmed, with one correction)

Release-workflow runs created between 13:10 and 14:42 that day:

| run | commit | conclusion | detail |
|---|---|---|---|
| `40329269631` | `c370ecb` | **failure** | a real test failure: `Executed 1241 tests, with 3 tests skipped and 1 failure`, `** TEST FAILED **`, `xcodebuild exit: 65`; the release job is `skipped` |
| `40332873749` | `a4b6467` | success | F1+F2 above: green, nothing published |
| `40335356084` | `1e64fbf` | cancelled | all jobs cancelled |
| `40335431737` | `75796c1` | success | published `v0.5.0` |
| `40338431401` | `f5b353c` | success | release step printed *"f5b353cc is not the tip of main (1ff1feb1); superseded, no release cut."* — after both test legs |
| `40339556034` | `1ff1feb` | **cancelled** | `test (catalyst)` had already **passed** at 14:38:02; `test (ios-simulator)` was cancelled at 14:42:46 |
| `40341709601` | `99e644f` | **cancelled** | `jobs: []` — it never started one |
| `40342086356` | `7685cd0` | success | published `v0.6.0`, attached the app, all four jobs green |

So: the two runs the card cites are exactly as cited. Two corrections to the narrative:

1. **They were cancelled by two different mechanisms.** `40341709601` never ran a job:
   it was queued at 14:39:54 and cancelled at 14:42:15, the moment the newer run
   `40342086356` was created. That is GitHub's pending-run replacement inside
   `concurrency: release-<ref>` — the documented behaviour when `cancel-in-progress` is
   `false`. `40339556034`, by contrast, was **running** (a completed job) when it was
   cancelled, and `cancel-in-progress: false` cannot cancel a running run: that
   cancellation came from outside the workflow — a human stopping the waste by hand,
   32 s after the tip run had been queued.
2. **The waste was real but was not "13 minutes before deciding".** A full green run
   from that era: test legs 14:47:50 → 14:58:38 (~10.8 min, both in parallel), release
   14:58:41 → 14:58:57, package 14:59:01 → 15:05:33 (~6.5 min) — ~17 macOS runner-minutes
   per green push. `40339556034` had already spent ~12 of them when it was cancelled
   (8.5 min on the iOS leg, plus the 3.8 min Catalyst leg that had finished), and had it
   finished, its release job would have printed "not the tip of main" like the run
   before it. The tip check did run in the *release* job, i.e. after everything.

## What the four gaps needed, and what they got

| gap | what was wrong | what closed it |
|---|---|---|
| **G1** | the tip check lived in the release job, so a superseded push ran both test legs and the package build first | `guard` job (ubuntu, seconds) + `scripts/ci_plan.py`; `test`, `release` and `package` gate on its outputs. The release job keeps its own tip check as a second line. |
| **G2** | `docs/**`-only pushes cost the same 13 minutes | policy: documentation-only pushes **skip the test legs and still release and package**. Implemented once, in `ci_plan.py`, tested by 13 cases. |
| **G3** | the package job printed the release's asset list and compared it to nothing | `scripts/verify_release_asset.py`: release published, asset present at the exact byte size of the local zip, and the tag's commit equal to the built `SHA`; the package job fails if any of those is false. |
| **G4** | the Mac build reuses the iOS bundle id | decision recorded in `docs/installing.md`, with the measured consequence and the migration cost. Corrections to the premise: the Mac build is **not** sandboxed (`ENABLE_APP_SANDBOX = NO`), so there is no shared container, and the ad-hoc download's secrets are not namespaced by the bundle id at all (they live in `~/Library/Application Support/Mattermost/`). |

Details of each are in `docs/releasing.md` (G1–G3) and `docs/installing.md` (G4).

## One more correction, in the docs themselves

`docs/releasing.md` and `docs/installing.md` both described the asset as
`Mattermost-macOS-arm64-<tag>.zip` and the build as arm64-only. `7685cd0` made the build
universal and renamed the artifact: the real asset on `v0.6.0` is
`Mattermost-macOS-v0.6.0.zip`, 13,402,755 bytes, `lipo -archs` = `x86_64 arm64`. Both
documents are corrected.

## Residual limitation, stated so it is not assumed away

The guard decides at *run* time. A run that was the tip when it started and is
superseded while its macOS legs are queued still finishes them; its release job then
refuses to publish (`published=false`) and the package job is skipped, so no release is
made and no app is built — but the test minutes are spent. Removing that last case means
`cancel-in-progress: true`, which would also cancel a publish that is already in flight;
the setting stays `false` deliberately, because a missed tag is cheap to re-cut and a
half-made release is not. Runs that are still *pending* when a newer push arrives are
cancelled by GitHub itself; that is the platform's queue, not a failure, and the guard
means such a run now costs seconds instead of a full pipeline.
