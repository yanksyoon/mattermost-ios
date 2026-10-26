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

`.github/workflows/release.yml` runs on every push to `main`, in two stages: **test**,
then **release**. `needs: test` means a red suite produces no tag, no release and no
notes.

### Stage 1 — test (macos-26, matrix: `ios-simulator` + `catalyst`)

The runner image ships **Xcode 26.6 (17F113)**, the same build the app is developed
against, so CI runs the real toolchain rather than a stand-in.

1. Prints the toolchain, so a future break is diagnosable from the log alone.
2. Self-tests the gate scripts — `release_version.py`, `release_notes.py`,
   `ci_simulator.py`, `verify-pushed.py`.
3. Resolves SPM dependencies (GRDB).
4. `xcodebuild test -scheme Mattermost -skip-testing:MattermostUITests`, with
   `-test-timeouts-enabled YES` so a hung harness reports instead of eating the
   timeout, and `CODE_SIGNING_ALLOWED=NO` so no signing identity is needed.
5. Fails unless the log contains `** TEST SUCCEEDED **`, and uploads the full log as
   an artifact either way.

The UI bundle is excluded on purpose: `MattermostUITests` drives a **live Mattermost
server** at `127.0.0.1:8065`, which CI does not provide. Those runs stay local and are
what a card's own gate covers.

The iOS destination is resolved by `scripts/ci_simulator.py` from the image's actual
simulator list, because runner images rename devices between OS releases and a
hard-coded `name=iPhone 16` rots.

### Stage 2 — release (ubuntu-latest)

1. Re-runs the version and notes self-tests on the tagging host.
2. Computes the next tag from the existing tags (never from a file).
3. Creates the tag **through the Releases API** (`gh release create --target <sha>`)
   and publishes with generated notes.
4. Verifies the release exists afterwards with `gh release view` rather than trusting
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
failure into a green run is worse than no retry. The current logic has three distinct
outcomes — already published (exit 0), tag without release (finish it), no tag (create
both) — and never treats "I cannot tell" as success.

**Notes come from commits and PRs.** `release_notes.py` groups commit subjects by
Conventional Commit type, and any `(#123)` reference in a subject becomes a linked
entry under **Pull requests**. That covers both shapes this repo can be pushed in:
direct commits and squash-merged PRs.

GitHub's own `--generate-notes` is still not used for the body: every commit so far is
a direct push, and when none carry PRs it emits only a compare link — which is exactly
what `v0.2.0` shipped with before its notes were backfilled.

Three properties worth knowing, because each one was a deliberate choice:

- **Tests gate the release.** The tag job cannot start until both matrix legs pass.
  A red suite on `main` means the previous release stays latest — which is the point.
- **One release per commit.** If the pushed commit already carries a `v*` tag the
  script answers `SKIP` and the release stage exits cleanly. Re-running a workflow, or
  a duplicate webhook delivery, can never cut a second release for the same commit.
- **Serialised.** `concurrency: release-${{ github.ref }}` with
  `cancel-in-progress: false` queues runs instead of racing for the same tag, and the
  tag step retries up to five times, re-reading tags each attempt.
- **Self-testing.** A rule that has never been shown to fail is not a rule.
  `release_version.py` covers ten cases (no tags, minor bump, junk tags, pre-release
  suffixes, `HEAD` already tagged, `0.10 > 0.9`); `release_notes.py` covers eight
  (grouping, ordering, breaking markers, unprefixed subjects, PR links and their
  absence); `ci_simulator.py` covers five (filtering, runtime ordering, hint, empty).

## Locally

```bash
python3 scripts/release_version.py              # next tag, e.g. v0.3.0
python3 scripts/release_version.py --format json
python3 scripts/release_version.py --dry-run    # explains the decision on stderr
python3 scripts/release_notes.py --from v0.2.0  # what the notes will say
python3 scripts/ci_simulator.py                 # which simulator CI would pick
```

All of these are read-only and safe during a card run — they only read tags and
simulator state.

## What a release contains

A tag, a GitHub-generated changelog, and GitHub's automatic source archives
(`zip` / `tar.gz`). **There is no built `.ipa` or `.app` attached**, on purpose:

- Signing needs the Apple Developer Program membership (board card H1), which is
  not in place, so an unsigned artifact would be a download nobody can install.
- The macOS runner on this public repo could produce an unsigned archive, but it
  would add minutes and a misleading artifact for no benefit.

When H1 clears, the natural extension is an `xcodebuild archive` job that attaches a
signed `.ipa` to the same release, gated on the tag the workflow already creates.

## Relationship to the board's closing gate

Two different assertions, both required before a card closes:

| Gate | Question | Script |
|---|---|---|
| push gate | is the commit on `origin/main`? | `scripts/verify-pushed.py` |
| release | does that push have a version and release notes? | this workflow |

The push gate is per card and local; the release is per push and happens in CI. A
card that closed on an unpushed commit would satisfy neither.
