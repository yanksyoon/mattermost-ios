#!/usr/bin/env python3
"""scripts/differential.py — enumerate the whole input space, diff generate.py against reference.py.

Blocking in CI. Stdlib only, no network.

  * statuses:  the full 2^7 cross-product of the seven facts, every world, byte-compared with the
               hand-authored table in scripts/reference.py;
  * prose:     the ladder paragraph in reference.py's docstring is read back and evaluated over the
               same 128 worlds — a stale sentence fails exactly like a stale row (t_93d9cafb);
  * findings:  a covering set of named worlds, compared with the expected finding kinds;
  * decoupling: every status is re-derived with has_verdict flipped, and must not move — the report
               flag may never leak into the ladder (the card's F5 property, in the small).

Exit 1 on any difference. A failure means one of the two readings of design §3.2 is wrong; fix the
reading, never the other side.
"""

import importlib.util
import itertools
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses resolve annotations through sys.modules (py3.9)
    spec.loader.exec_module(module)
    return module


generate = load("parity_generate", os.path.join(ROOT, "parity/generate.py"))
reference = load("parity_reference", os.path.join(HERE, "reference.py"))


# --------------------------------------------------------------------------------------
# the reference's *prose*, read back from its own docstring
# --------------------------------------------------------------------------------------
# reference.py is the file a reader opens to learn the rules, so its ladder paragraph has to say
# what its table says. These four functions parse the three `... -> ...` lines out of the module
# docstring and evaluate them; check 2 below diffs the result against the 128 hand-authored rows.
# Nothing here is copied from generate.py — the only input is the docstring text.


def _prose_ladder(docstring):
    """The ladder lines only: the block after `evaluated in this order:`, up to the blank line.

    Anchored to that sentence so a changelog line that quotes an old `... -> ...` form cannot be
    mistaken for a rung.
    """
    lines, started = [], False
    for raw in (docstring or "").splitlines():
        if "evaluated in this order" in raw:
            started = True
            continue
        if not started:
            continue
        if not raw.strip():
            if lines:
                break
            continue
        if "->" in raw:
            lines.append(" ".join(raw.split()))
    if len(lines) != 3:
        raise ValueError("expected 3 ladder lines in the reference docstring, found %d: %r"
                         % (len(lines), lines))
    return lines


def _truth(expr, env):
    expr = expr.strip()
    if expr == "otherwise":
        return True
    if expr.startswith("not "):
        return not _truth(expr[4:], env)
    if expr.startswith("(") and expr.endswith(")"):
        return all(_truth(atom, env) for atom in expr[1:-1].split(" and "))
    if expr in env:
        return env[expr]
    raise ValueError("the docstring's ladder names %r, which is not a fact" % expr)


def _verdict(expr, env):
    """`status`, `A if C else B`, and the `A if C; else D if E else F` chain the prose uses."""
    for segment in [s.strip() for s in expr.split(";") if s.strip()]:
        if segment.startswith("else "):
            segment = segment[5:].strip()
        body, sep, rest = segment.partition(" if ")
        if not sep:
            return body
        condition, _, alternative = rest.partition(" else ")
        if _truth(condition, env):
            return _verdict(body, env)
        if alternative.strip():
            return _verdict(alternative, env)
    raise ValueError("no branch of the docstring's ladder applied to %r" % (env,))


def _prose_status(lines, env):
    for line in lines:
        condition, _, action = line.partition("->")
        if _truth(condition, env):
            return _verdict(action, env)
    raise ValueError("the docstring's ladder has no fallback branch")


def main():
    failures = []

    # 1. statuses — the full cross-product
    worlds = 0
    for combo in itertools.product((False, True), repeat=7):
        facts = generate.Facts(*combo)
        want = reference.STATUS_TABLE[combo]
        got = generate.derive_status(facts)
        worlds += 1
        if got != want:
            failures.append("status %s: generate=%r reference=%r"
                            % (" ".join("1" if x else "0" for x in combo), got, want))
        # the report bit must not move the ladder (F5, in the small)
        flipped = generate.derive_status(generate.Facts(*combo, has_verdict=True))
        if flipped != got:
            failures.append("has_verdict changed the status for %s: %r -> %r"
                            % (combo, got, flipped))

    # 2. prose — reference.py's docstring ladder against reference.py's table
    prose_worlds = 0
    try:
        ladder = _prose_ladder(reference.__doc__)
    except ValueError as exc:
        failures.append("reference docstring: %s" % exc)
        ladder = []
    if ladder:
        for combo in itertools.product((False, True), repeat=7):
            env = dict(zip(reference.TABLE_ORDER, combo))
            want = reference.STATUS_TABLE[combo]
            got = _prose_status(ladder, env)
            prose_worlds += 1
            if got != want:
                failures.append("docstring %s: docstring=%r table=%r"
                                % (" ".join("1" if x else "0" for x in combo), got, want))

    # 3. findings — the covering worlds
    for name, (facts_tuple, want) in sorted(reference.FINDINGS_WORLDS.items()):
        claim, path, test, ancestor, clean, evidence, approved, has_verdict, paths_state = facts_tuple
        facts = generate.Facts(claim, path, test, ancestor, clean, evidence, approved, has_verdict)
        got = generate.find_row_findings(facts, paths_state)
        if got != want:
            failures.append("findings %s: generate=%r reference=%r" % (name, got, want))

    # 4. the table is complete — no world is missing or duplicated
    if len(reference.STATUS_TABLE) != worlds:
        failures.append("reference table covers %d worlds, the cross-product is %d"
                        % (len(reference.STATUS_TABLE), worlds))

    if failures:
        for line in failures:
            print("[FAIL] differential: %s" % line)
        return 1
    print("differential: PASS — %d status worlds, %d finding worlds, %d table rows, %d docstring worlds"
          % (worlds, len(reference.FINDINGS_WORLDS), len(reference.STATUS_TABLE), prose_worlds))
    return 0


if __name__ == "__main__":
    sys.exit(main())
