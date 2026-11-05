#!/usr/bin/env bash
# scripts/lean_check.sh — the local half of the Lean check, and on this host it is deliberately a
# no-op.
#
# The proof in lean/ is verified in CI only: .github/workflows/parity-lean.yml, job `lean`. The
# owner's decision (card t_22c3f1ea) is that no Lean toolchain is installed on the development host,
# so local absence is the expected state and not a failure. This script therefore:
#
#   * exits 0 with a sentence saying the proof was NOT checked, when `lake` is absent;
#   * runs `lake build` when a toolchain happens to be present (same build as CI);
#   * never installs anything — a check script that downloads a toolchain is a check nobody runs —
#     and never reports a proof it did not compile.
#
# It is NOT part of any blocking CI job. The blocking local checks are the differential, the
# mutation test and the self-test, and none of them depend on Lean:
#     python3 parity/generate.py --self-test
#     python3 scripts/differential.py
#     python3 scripts/mutate-test.py
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v lake >/dev/null 2>&1 || [ ! -f "${root}/lean/lakefile.toml" ]; then
  cat <<'EOF'
Lean is verified in CI only: .github/workflows/parity-lean.yml (see docs/parity-verification-design.md)
  no Lean toolchain on this host is the expected state; nothing was compiled by this script.
  the blocking local checks (python3 parity/generate.py --self-test, scripts/differential.py,
  scripts/mutate-test.py) do not depend on Lean and are unaffected.
EOF
  exit 0
fi

echo "lake present at $(command -v lake) — building lean/ (the same build the CI job runs)"
cd "${root}/lean"
lake build
