#!/bin/bash
# release_publish_selftest.sh — prove the "Publish the release" step, in both CI legs.
#
# The release step is the most dangerous code in this repo: it decides whether a release
# exists. docs/releasing.md argues that "a rule that has never been shown to fail is not a
# rule", so this script replays the step body **as shipped** — extracted from
# .github/workflows/release.yml at run time, never a copy that can drift — against a
# throwaway bare repository standing in for github.com, plus a stub `gh` that models the
# Releases API (tag refs created by --target, required by --verify-tag, 422 on duplicate).
#
# It also keeps the negative control: a4b6467's pre-fix "Tag and publish" body is replayed
# against an origin whose pre-receive hook models the rejection GitHub actually made
# ("refusing to allow a GitHub App to create or update workflow ... without workflows
# permission"), and must exit 0 having created neither a tag nor a release. That silent
# green is the defect this repo fixed in 1e64fbf; if the old body stops reproducing it,
# this script fails, because a harness that cannot show the bug proves nothing.
#
# Nothing here touches the network, gh auth, or the real repository's refs: every object
# lives under $TMPDIR and is deleted on exit. Requirements: bash, git, python3 — nothing
# else (the macOS leg runs this under bash 3.2, so no bash-4 constructs).
#
# Usage: bash scripts/release_publish_selftest.sh
#        KEEP=1 bash scripts/release_publish_selftest.sh    # keep the logs for an autopsy
# Exit:  0 when every check holds (prints "SELF-TEST: PASS"), 1 otherwise.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE/.." && pwd)
HELPER="$HERE/release_publish_selftest"
REAL_GIT=$(command -v git)
WORKFLOW="$REPO_ROOT/.github/workflows/release.yml"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/release-publish-selftest.XXXXXX") || {
  echo "cannot create a temporary directory" >&2
  exit 1
}
STEP_BODY="$WORK/publish_step.sh"
OLD_BODY="$WORK/old_publish_step.sh"
FAILS=0
CHECKS=0
RC=""

say() { printf '%s\n' "$*"; }

cleanup() {
  if [ "${KEEP:-0}" = "1" ]; then
    say "artifacts: $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

# --- assertions -------------------------------------------------------------------
expect() { # description command...
  local desc=$1
  shift
  CHECKS=$((CHECKS + 1))
  if "$@" >/dev/null 2>&1; then
    say "  [PASS] $desc"
  else
    say "  [FAIL] $desc"
    FAILS=$((FAILS + 1))
  fi
}

expect_absent() { # description command... (passes when the command fails)
  local desc=$1
  shift
  CHECKS=$((CHECKS + 1))
  if "$@" >/dev/null 2>&1; then
    say "  [FAIL] $desc"
    FAILS=$((FAILS + 1))
  else
    say "  [PASS] $desc"
  fi
}

rc_is() { [ "$(cat "$WORK/$1/rc" 2>/dev/null)" = "$2" ]; }
release_count_is() { [ "$(ls "$WORK/$1/ghstate/releases" 2>/dev/null | wc -l | tr -d ' ')" = "$2" ]; }
log_has() { grep -q -e "$2" "$WORK/$1/out.log" 2>/dev/null; }
log_lacks() { ! grep -q -e "$2" "$WORK/$1/out.log" 2>/dev/null; }
file_has() { grep -q -e "$2" "$1" 2>/dev/null; }
grep_file() { grep -q -F -e "$2" "$1" 2>/dev/null; }
file_lacks() { ! grep -q -e "$2" "$1" 2>/dev/null; }
remote_tag_at() { [ "$(git -C "$WORK/$1/origin.git" rev-parse -q --verify "refs/tags/$2" 2>/dev/null)" = "$3" ]; }
remote_absent() { [ -z "$(git -C "$WORK/$1/origin.git" rev-parse -q --verify "refs/tags/$2" 2>/dev/null)" ]; }
calls_log() { cat "$WORK/$1/ghstate/log/calls.log" 2>/dev/null; }
call_count_is() { [ "$(grep -c -e "$2" "$WORK/$1/ghstate/log/calls.log" 2>/dev/null | tr -d ' ')" = "$3" ]; }

show_log() { # scenario dir
  say "  --- $1 log ---"
  sed 's/^/  | /' "$WORK/$1/out.log" 2>/dev/null
}

# --- fixture: a synthetic github.com -----------------------------------------------
seed() { # $1 = scenario dir, $2 = commit to take the scripts/workflow from (optional)
  local name=$1 ref=${2:-} base="$WORK/$1"
  mkdir -p "$base" || return 1
  git init -q --bare -b main "$base/origin.git" || return 1
  git init -q -b main "$base/seed" || return 1
  (
    cd "$base/seed" || exit 1
    git config user.email qa@example.invalid
    git config user.name QA
    git config commit.gpgsign false
    mkdir -p scripts .github/workflows
    if [ -n "$ref" ]; then
      git -C "$REPO_ROOT" show "$ref:scripts/release_version.py" > scripts/release_version.py || exit 1
      git -C "$REPO_ROOT" show "$ref:scripts/release_notes.py" > scripts/release_notes.py || exit 1
      git -C "$REPO_ROOT" show "$ref:.github/workflows/release.yml" > .github/workflows/release.yml || exit 1
    else
      cp "$REPO_ROOT/scripts/release_version.py" scripts/ || exit 1
      cp "$REPO_ROOT/scripts/release_notes.py" scripts/ || exit 1
      cp "$WORKFLOW" .github/workflows/ || exit 1
    fi
    echo one > f
    git add -A
    git commit -qm "c1: baseline"
    git tag v0.4.0
    echo two >> f
    git add -A
    git commit -qm "c2: the commit under test"
    git remote add origin "$base/origin.git"
    git push -q origin main --tags
  ) || return 1
}

clone_work() { # $1 = scenario dir: a fresh runner checkout of origin
  local base="$WORK/$1"
  git clone -q "$base/origin.git" "$base/work" || return 1
  git -C "$base/work" config user.email qa@example.invalid
  git -C "$base/work" config user.name QA
  git -C "$base/work" config commit.gpgsign false
}

run_step() { # $1 = scenario dir, $2 = extra PATH prefix ('' for none), rest = VAR=value
  local name=$1 extra=$2 base
  shift 2
  base="$WORK/$name"
  mkdir -p "$base/ghstate"
  (
    cd "$base/work" || exit 99
    # `env` so extra VAR=value pairs arrive as assignments, not as a command name.
    env PATH="${extra:+$extra:}$HELPER/fakebin:$PATH" \
      GH_STATE="$base/ghstate" ORIGIN="$base/origin.git" REPO=fake/repo GH_TOKEN=fake \
      REAL_GIT="$REAL_GIT" "$@" \
      bash "$STEP_BODY" > "$base/out.log" 2>&1
    echo $? > "$base/rc"
  )
  RC=$(cat "$base/rc")
}

# =====================================================================================
say "release publish-step self-test"
say "workflow: $WORKFLOW"
say "scratch:  $WORK"
say ""

# --- S0: the body under test is the shipped one, and it has no retry loop ------------
say "== S0 the body under test =="
python3 "$HELPER/extract_step.py" "$WORKFLOW" "Publish the release" > "$STEP_BODY"
EXTRACT_RC=$?
expect "extract_step.py found the 'Publish the release' step" [ "$EXTRACT_RC" = "0" ]
expect "the body is the shipped text (it ends by reporting RELEASE CREATED)" \
  file_has "$STEP_BODY" "RELEASE CREATED:"
expect "the body still guards on being the tip of main" \
  file_has "$STEP_BODY" "not the tip of main"
expect_absent "the body carries no retry loop (the 1e64fbf regression)" \
  file_has "$STEP_BODY" "for attempt in"
expect_absent "the body does not push refs itself (git tag / git push)" \
  file_has "$STEP_BODY" "^[[:space:]]*git \(push\|tag\) "
say "  (body: $(wc -l < "$STEP_BODY" | tr -d ' ') lines)"

# --- S1: tip of main, no tag -> a release ------------------------------------------
seed s1 && clone_work s1
S1_SHA=$(git -C "$WORK/s1/work" rev-parse HEAD)
run_step s1 ""
say ""
say "== S1 tip of main, no tag -> publish =="
expect "S1 exits 0" rc_is s1 0
expect "S1 created the tag on the remote at HEAD" remote_tag_at s1 v0.5.0 "$S1_SHA"
expect "S1 created exactly one release" release_count_is s1 1
expect "S1 reported RELEASE CREATED: v0.5.0" log_has s1 "RELEASE CREATED: v0.5.0"
expect "S1 verified the side effect with gh release view" call_count_is s1 "release view" 1
show_log s1

# --- S2: the Releases API rejects the create ---------------------------------------
seed s2 && clone_work s2
run_step s2 "" FAKE_GH_FAIL_CREATE=1
say ""
say "== S2 the API rejects the create -> red, nothing created =="
expect "S2 exit 1" rc_is s2 1
expect "S2 printed ::error::could not create release v0.5.0" \
  log_has s2 "::error::could not create release v0.5.0"
expect_absent "S2 did not report success" log_has s2 "RELEASE CREATED"
expect "S2 created no release" release_count_is s2 0
expect "S2 left no tag on the remote" remote_absent s2 v0.5.0
show_log s2

# --- S3: re-run of the same tip -> green no-op ------------------------------------
seed s3 && clone_work s3
run_step s3 ""
RC_FIRST=$RC
run_step s3 ""
say ""
say "== S3 re-run of the same tip =="
expect "S3 first run published (exit 0)" [ "$RC_FIRST" = "0" ]
expect "S3 second run exits 0" rc_is s3 0
expect "S3 second run took the already-published path" log_has s3 "already published: v0.5.0"
expect "S3 exactly one release exists" release_count_is s3 1
expect "S3 exactly one release create across both runs" call_count_is s3 "release create" 1
show_log s3

# --- S4: tag on the remote but no release -> finish it -----------------------------
seed s4 && clone_work s4
git -C "$WORK/s4/origin.git" update-ref refs/tags/v0.5.0 "$(git -C "$WORK/s4/work" rev-parse HEAD)"
run_step s4 ""
say ""
say "== S4 tag exists without its release -> completed with --verify-tag =="
expect "S4 exits 0" rc_is s4 0
expect "S4 completed the release instead of cutting a new tag" log_has s4 "has no release; completing it"
expect "S4 used --verify-tag (it did not move the tag)" \
  grep_file "$WORK/s4/ghstate/log/calls.log" "--verify-tag"
expect "S4 created the release" release_count_is s4 1
show_log s4

# --- S5: not the tip -> exit 0 and touch nothing -----------------------------------
seed s5 && clone_work s5
(
  cd "$WORK/s5/seed" || exit 1
  echo three >> f
  git add -A
  git commit -qm "c3: newer tip"
  git push -q origin main
) || say "  (S5: could not advance the tip)"
run_step s5 ""
say ""
say "== S5 a superseded run (not the tip of main) =="
expect "S5 exits 0" rc_is s5 0
expect "S5 said it was superseded" log_has s5 "is not the tip of main"
expect "S5 created no tag" remote_absent s5 v0.5.0
expect "S5 created no release" release_count_is s5 0
show_log s5

# --- S6: a release tag that exists only in the runner's checkout -------------------
# The state the old retry loop left behind on run 40332873749.
seed s6 && clone_work s6
git -C "$WORK/s6/work" tag v0.5.0
run_step s6 ""
say ""
say "== S6 a local-only release tag at HEAD cannot green the job =="
expect "S6 exits 1" rc_is s6 1
expect_absent "S6 did not claim 'already published'" log_has s6 "already published"
expect "S6 created no release" release_count_is s6 0
expect "S6 put no tag on the remote" remote_absent s6 v0.5.0
show_log s6

# --- S7: a non-bare (pre-release) tag at HEAD -------------------------------------
# release_version.py drops suffixes, so v0.5.0-rc1 answers SKIP; the bare-tag scan then
# finds nothing. Before the fix the assignment died under set -e/pipefail and the job
# went red with no reason at all. Now it must refuse *with* its ::error:: line.
seed s7 && clone_work s7
git -C "$WORK/s7/work" tag v0.5.0-rc1
run_step s7 ""
say ""
say "== S7 only a pre-release tag (v0.5.0-rc1) at HEAD =="
expect "S7 does not publish" rc_is s7 1
expect "S7 says why it refused (::error::SKIP with no release tag on HEAD)" \
  log_has s7 "::error::SKIP with no release tag on HEAD"
expect "S7 created no release" release_count_is s7 0
expect "S7 put no tag on the remote" remote_absent s7 v0.5.0
show_log s7

# --- S8: the tip check cannot reach the remote ------------------------------------
# Not a green: pipefail must surface git's 128. Do not "fix" this into an exit 0.
seed s8 && clone_work s8
run_step s8 "$HELPER/fakebin_gitfail"
say ""
say "== S8 git ls-remote fails at the tip check =="
expect_absent "S8 does not green the job" rc_is s8 0
expect "S8 surfaced git's failure (128)" rc_is s8 128
expect "S8 created no release" release_count_is s8 0
show_log s8

# =====================================================================================
say ""
say "== NEGATIVE CONTROL: a4b6467's 'Tag and publish' body =="
if ! git -C "$REPO_ROOT" cat-file -e "a4b6467^{commit}" 2>/dev/null; then
  CHECKS=$((CHECKS + 1))
  say "  [FAIL] cannot read a4b6467 (the checkout must not be shallow: fetch-depth 0)"
  FAILS=$((FAILS + 1))
else
  git -C "$REPO_ROOT" show "a4b6467:.github/workflows/release.yml" > "$WORK/old_workflow.yml"
  python3 "$HELPER/extract_step.py" "$WORK/old_workflow.yml" "Tag and publish" > "$OLD_BODY"
  OLD_EXTRACT=$?
  expect "extracted the pre-fix body from history" [ "$OLD_EXTRACT" = "0" ]
  expect "the pre-fix body is the retry loop we removed" file_has "$OLD_BODY" "for attempt in 1 2 3 4 5"

  seed old a4b6467 && clone_work old
  # An origin that enforces the rule GitHub enforced on run 40332873749.
  cat > "$WORK/old/origin.git/hooks/pre-receive" <<'HOOK'
#!/bin/bash
while read -r old new ref; do
  case "$ref" in
    refs/tags/v*)
      name=${ref#refs/tags/}
      echo "! [remote rejected] $name -> $name (refusing to allow a GitHub App to create or update workflow \`.github/workflows/release.yml\` without \`workflows\` permission)" >&2
      echo "error: failed to push some refs to 'https://github.com/yanksyoon/mattermost-ios'" >&2
      exit 1
      ;;
  esac
done
exit 0
HOOK
  chmod +x "$WORK/old/origin.git/hooks/pre-receive"

  mkdir -p "$WORK/old/ghstate"
  (
    cd "$WORK/old/work" || exit 99
    PATH="$HELPER/fakebin:$PATH" GH_STATE="$WORK/old/ghstate" ORIGIN="$WORK/old/origin.git" \
      REAL_GIT="$REAL_GIT" bash "$OLD_BODY" > "$WORK/old/out.log" 2>&1
    echo $? > "$WORK/old/rc"
  )
  expect "the pre-fix body is the fixture that greened run 40332873749: exit 0" rc_is old 0
  expect "it retried the rejected push before answering SKIP" log_has old "lost a race, retrying"
  expect "it then reported nothing to do" log_has old "nothing to do"
  expect "yet it created no tag on the remote" remote_absent old v0.5.0
  expect "and no release" release_count_is old 0
  show_log old
fi

say ""
say "elapsed: ${SECONDS}s"
if [ "$FAILS" = "0" ]; then
  say "SELF-TEST: PASS ($CHECKS checks, 8 scenarios + 1 negative control)"
  exit 0
fi
say "SELF-TEST: FAIL $FAILS (of $CHECKS checks)"
KEEP=1
exit 1
