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

`.github/workflows/release.yml` runs on every push to `main`:

1. `scripts/release_version.py --self-test` — proves the bump rules before tagging.
2. Computes the next tag from the existing tags (never from a file).
3. Creates an annotated tag at the pushed commit and pushes it.
4. `gh release create --generate-notes --latest` — GitHub assembles the notes from
   the commits since the previous tag.

Three properties worth knowing, because each one was a deliberate choice:

- **One release per commit.** If the pushed commit already carries a `v*` tag the
  script answers `SKIP` and the workflow exits cleanly. Re-running a workflow, or a
  duplicate webhook delivery, can never cut a second release for the same commit.
- **Serialised.** `concurrency: release-${{ github.ref }}` with
  `cancel-in-progress: false` queues runs instead of racing for the same tag, and
  the tag step additionally retries up to five times, re-reading tags each attempt,
  in case a run still loses the race.
- **Self-testing.** A version rule that has never been shown to fail is not a rule.
  `--self-test` covers ten cases including no tags, the minor bump, junk tags,
  pre-release suffixes, `HEAD` already tagged, and `0.10 > 0.9` ordering.

## Locally

```bash
python3 scripts/release_version.py              # next tag, e.g. v0.2.0
python3 scripts/release_version.py --format json
python3 scripts/release_version.py --dry-run    # explains the decision on stderr
python3 scripts/release_version.py --self-test
```

Local use is read-only and safe during a card run — it only reads tags.

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
