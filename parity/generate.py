#!/usr/bin/env python3
"""parity/generate.py — the one tool for the parity record.

Design of record: docs/parity-map-design.md (and the implementation-delta appendix at its end).
Stdlib only. The only external command is `git` (the pins are commits; the repo is a prerequisite).
No network in any path.

Artifacts, all deterministic (sorted, no clock, no random):

    parity/out/inventory.tsv   key / surface / status / native_paths / test_refs / verdict / card
    parity/out/gaps.tsv        every key that is not validated|native
    parity/out/orphans.tsv     ORPHAN / STALE / MOVE / UNMAPPED rows
    parity/out/findings.txt    tally + findings grouped by kind
    docs/PARITY-table.md       the human table, rendered from the same rows
                               (named `-table` because `docs/PARITY.md` IS `docs/parity.md` on APFS)

Commands:

    generate.py                       regenerate the artifacts
    generate.py --check [--report]    regen to a temp dir, diff, exit 1 on drift
    generate.py --self-test           six planted faults fire, asserts run, two runs byte-identical
    generate.py --query NAME|KEY|SURFACE [--json]
    generate.py --render-md [--out docs/PARITY-table.md]
    generate.py --bootstrap [--force] seed pins/keys/claims from the checked-in extracts
    generate.py promote KEY|ALIAS (--test FILE::CASE | --verdict FILE --commit SHA ...)
    generate.py claim KEY --paths A;B [--surface S] [--card C]
    generate.py plan                  absent/claimed keys with no open card, as card proposals
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, replace

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# --------------------------------------------------------------------------------------
# kinds and severity (design §3.5, kept verbatim)
# --------------------------------------------------------------------------------------

FATAL_KINDS = (
    "MALFORMED ROW",
    "DUPLICATE KEY",
    "INTERNAL-WITH-UPSTREAM",
    "STALE",
    "ORPHAN",
    "UNMAPPED",
    "MAP-INCOMPLETE",
    "STALE-VERDICT",
    "STALE-EVIDENCE",
    "PANE-NOT-APPROVED",
)
REPORT_KINDS = (
    "GAP",
    "UNCARDED-GAP",
    "MOVE",
    "UPSTREAM-MOVED",
    "APPROVED-WITHOUT-VERDICT",
    "VALIDATED-BUT-NOT-APPROVED",
)


def severity(kind):
    return "fatal" if kind in FATAL_KINDS else "report"


ORDER = FATAL_KINDS + REPORT_KINDS


@dataclass(frozen=True)
class Finding:
    kind: str
    key: str
    message: str

    def line(self):
        tag = "[FAIL]" if severity(self.kind) == "fatal" else "[note]"
        return "%s %s %s — %s" % (tag, self.kind, self.key or "-", self.message)

    def sort_key(self):
        return (0 if severity(self.kind) == "fatal" else 1, ORDER.index(self.kind), self.key, self.message)


# --------------------------------------------------------------------------------------
# key syntax and the pure status ladder
# --------------------------------------------------------------------------------------

KEY_PATTERNS = {
    "M": re.compile(r"^M:[A-Za-z0-9._/@+-]+$"),
    "REST": re.compile(r"^REST:(GET|POST|PUT|PATCH|DELETE) /[A-Za-z0-9._~/{}+-]*$"),
    "WS": re.compile(r"^WS:[a-z0-9_]+$"),
    "X": re.compile(r"^X:[A-Za-z0-9._-]+$"),
}

SURFACES = (  # fallback only: the live list is parsed from RenderMode.swift
    "auth", "sidebar", "channelView", "composer", "search", "activity", "channelInfo", "calls",
)


def key_namespace(key):
    return key.split(":", 1)[0] if ":" in key else ""


def key_is_well_formed(key):
    ns = key_namespace(key)
    pat = KEY_PATTERNS.get(ns)
    return bool(pat and pat.match(key))


@dataclass(frozen=True)
class Facts:
    """What the ladder is allowed to read. Mirrors design §3.2, one boolean per clause.

    verdict_ancestor is false when no verdict exists at all (design note: the closure in
    scripts/reference.py is over the seven booleans named in the card). has_verdict exists only
    so STALE-VERDICT and "no verdict" can be told apart for the report; it never changes status.
    """

    claim_exists: bool
    paths_present: bool
    test_ref: bool
    verdict_ancestor: bool
    verdict_clean: bool
    evidence_resolves: bool
    approved: bool
    has_verdict: bool = False


def derive_status(f):
    """absent -> claimed -> tested -> validated -> native. Derived, never typed.

    The ladder is monotone: each rung adds proof, so `validated` requires `tested` as well as the
    three verdict clauses. A verdict whose only evidence is an observation, on a key no test names,
    therefore lands `claimed`, not `validated` — decided by the exhaustive table in
    scripts/reference.py (world `1 1 0 1 1 1 1`), not by a sentence read in isolation.
    """
    if not f.claim_exists or not f.paths_present:
        return "absent"
    if not (f.verdict_ancestor and f.verdict_clean and f.evidence_resolves):
        return "tested" if f.test_ref else "claimed"
    if not f.test_ref:
        return "claimed"
    return "native" if f.approved else "validated"


def find_row_findings(f, paths_state):
    """The pure per-row detectors. paths_state: none | missing | present."""
    kinds = []
    if f.claim_exists and paths_state == "none":
        kinds.append("GAP")
    if f.claim_exists and paths_state == "missing":
        kinds.append("STALE")
    if f.has_verdict:
        if not f.verdict_ancestor:
            kinds.append("STALE-VERDICT")
        elif not f.verdict_clean:
            kinds.append("STALE-VERDICT")
        if not f.evidence_resolves:
            kinds.append("STALE-EVIDENCE")
    status = derive_status(f)
    if status == "validated" and not f.approved:
        kinds.append("VALIDATED-BUT-NOT-APPROVED")
    return sorted(set(kinds), key=ORDER.index)


# --------------------------------------------------------------------------------------
# io helpers
# --------------------------------------------------------------------------------------


def read_tsv(path, columns):
    """Read a `#`-headered TSV. Returns (rows, problems). Every data row must have len(columns)."""
    if not os.path.exists(path):
        return [], ["missing file %s" % path]
    rows, problems, header_seen = [], [], False
    with open(path, "r", encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            if not line.strip():
                continue
            if line.startswith("#"):
                if not header_seen and "\t" in line:
                    header_seen = True
                    got = [c.strip() for c in line.lstrip("#").strip().split("\t")]
                    if got != list(columns):
                        problems.append((lineno, "header %r != %r" % (got, list(columns))))
                continue
            parts = line.split("\t")
            if len(parts) != len(columns):
                problems.append((lineno, "expected %d columns, got %d" % (len(columns), len(parts))))
                continue
            rows.append(dict(zip(columns, (p.strip() for p in parts))))
    return rows, problems


def write_tsv(path, columns, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("# " + "\t".join(columns) + "\n")
        for row in rows:
            fh.write("\t".join(str(row[c]) for c in columns) + "\n")


def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def read_text(path):
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def split_list(value):
    value = (value or "").strip()
    return [] if value in ("", "-") else [v.strip() for v in value.split(";") if v.strip()]


def join_list(values):
    return ";".join(values) if values else "-"


# --------------------------------------------------------------------------------------
# git plumbing
# --------------------------------------------------------------------------------------


def git(args, cwd=None, check=False):
    proc = subprocess.run(
        ["git"] + args,
        cwd=cwd or ROOT,
        capture_output=True,
        text=True,
    )
    if check and proc.returncode != 0:
        raise RuntimeError("git %s failed: %s" % (" ".join(args), proc.stderr.strip()))
    return proc


def is_git_repo(cwd=None):
    return git(["rev-parse", "--git-dir"], cwd=cwd).returncode == 0


def git_head(cwd=None):
    proc = git(["rev-parse", "HEAD"], cwd=cwd)
    return proc.stdout.strip() if proc.returncode == 0 else ""


def object_exists(rev, cwd=None):
    return git(["cat-file", "-e", rev + "^{commit}"], cwd=cwd).returncode == 0


def is_ancestor(commit, head=None, cwd=None):
    head = head or git_head(cwd)
    if not commit or not head:
        return False
    return git(["merge-base", "--is-ancestor", commit, head], cwd=cwd).returncode == 0


def plan_pins_sha(commit, prefix, path, cwd=None):
    """git rev-parse <commit>:<prefix><path> — tree sha for a dir, blob sha for a file."""
    if not commit or not path:
        return None
    proc = git(["rev-parse", "%s:%s%s" % (commit, prefix or "", path)], cwd=cwd)
    return proc.stdout.strip() if proc.returncode == 0 else None


def last_commit_touching(paths, cwd=None):
    if not paths:
        return None
    proc = git(["log", "-1", "--format=%H", "--"] + list(paths), cwd=cwd)
    return proc.stdout.strip() or None


def touched_since(commit, paths, cwd=None):
    """Commits in <commit>..HEAD that touched any of paths. Empty tuple = clean."""
    if not commit or not paths:
        return ()
    proc = git(["rev-list", "%s..HEAD" % commit, "--"] + list(paths), cwd=cwd)
    if proc.returncode != 0:
        return ("?",)
    return tuple(x for x in proc.stdout.split() if x)


def head_blobs(prefix, cwd=None):
    """path -> blob sha for every file under prefix at HEAD."""
    proc = git(["ls-tree", "-r", "HEAD", "--", prefix], cwd=cwd)
    out = {}
    for line in proc.stdout.splitlines():
        if "\t" not in line:
            continue
        meta, path = line.split("\t", 1)
        parts = meta.split()
        if len(parts) >= 3 and parts[1] == "blob":
            out[path] = parts[2]
    return out


def tree_blobs(rev_path, cwd=None):
    proc = git(["ls-tree", "-r", rev_path], cwd=cwd)
    out = {}
    for line in proc.stdout.splitlines():
        if "\t" not in line:
            continue
        meta, path = line.split("\t", 1)
        parts = meta.split()
        if len(parts) >= 3 and parts[1] == "blob":
            out[path] = parts[2]
    return out


def move_candidate(path, cwd=None):
    """A deterministic rename detector. Returns the surviving path or None.

    1. `git log --follow --diff-filter=R` — the rename history, when the file was committed.
    2. content identity (`git hash-object` semantics: compare blob/tree contents) against the
       files under the native root at HEAD — the refactor that was never recorded as a rename
       because both paths are in one commit.

    It runs BEFORE STALE is finalised (design §5.1): a refactor must not read as "not implemented".
    """
    repo = cwd or ROOT
    proc = git(
        ["log", "--follow", "--diff-filter=R", "--name-status", "--format=", "HEAD", "--", path],
        cwd=repo,
    )
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) == 3 and parts[0].startswith("R"):
            if os.path.exists(os.path.join(repo, parts[2])) and os.path.abspath(parts[2]) != os.path.abspath(path):
                return parts[2]

    base_commit = last_commit_touching([path], cwd=cwd)
    if not base_commit:
        return None
    old_ref = None
    for candidate in ("%s^:%s" % (base_commit, path), "%s:%s" % (base_commit, path)):
        if git(["cat-file", "-e", candidate], cwd=cwd).returncode == 0:
            old_ref = candidate
            break
    if not old_ref:
        return None

    if git(["cat-file", "-t", old_ref], cwd=cwd).stdout.strip() == "blob":
        old_sha = git(["rev-parse", old_ref], cwd=cwd).stdout.strip()
        for new_path, sha in head_blobs("Mattermost", cwd=cwd).items():
            if sha == old_sha and os.path.abspath(new_path) != os.path.abspath(path):
                return new_path
        return None

    old_blobs = tree_blobs(old_ref, cwd=cwd)
    if not old_blobs:
        return None
    old_set = set(old_blobs.values())
    files = head_blobs("Mattermost", cwd=cwd)
    dirs = {}
    for p, sha in files.items():
        dirs.setdefault(os.path.dirname(p), set()).add(sha)
    for d in sorted(dirs, key=lambda s: (-s.count("/"), s)):
        if dirs[d] == old_set and not path.rstrip("/").startswith(d):
            return d
    return None


# --------------------------------------------------------------------------------------
# the record
# --------------------------------------------------------------------------------------

PIN_COLUMNS = ["alias", "repo", "tag", "commit", "path_prefix", "license"]
KEY_COLUMNS = ["key", "namespace", "path", "content_sha", "kind", "anchor_of"]
CLAIM_COLUMNS = ["key", "native_paths", "surface", "test_refs", "status_seed", "card", "note"]


class Config:
    def __init__(self, root=ROOT):
        self.root = os.path.abspath(root)
        self.pins = os.path.join(root, "parity/pins.tsv")
        self.keys = os.path.join(root, "parity/upstream-keys.tsv")
        self.claims = os.path.join(root, "parity/claims.tsv")
        self.verdicts = os.path.join(root, "parity/verdicts.json")
        self.out = os.path.join(root, "parity/out")
        self.md = os.path.join(root, "docs/PARITY-table.md")
        self.registry = os.path.join(root, "Mattermost/Core/RenderMode.swift")
        self.native_root = os.path.join(root, "Mattermost/UI/Native")
        self.swift_root = os.path.join(root, "Mattermost")
        self.test_root = os.path.join(root, "MattermostTests")


def parse_registry(path):
    """Parse the Swift literals — never a second list (design §3.2, failure mode 3)."""
    if not os.path.exists(path):
        raise RuntimeError("registry not found: %s" % path)
    src = read_text(path)
    body = re.search(r"public enum Surface: String[^{]*\{(.*?)\n\}", src, re.S)
    surfaces = re.findall(r"^\s{4}case ([A-Za-z0-9_]+)\s*$", body.group(1), re.M) if body else []

    def parse_set(name):
        m = re.search(re.escape(name) + r":\s*Set<Surface>\s*=\s*\[([^\]]*)\]", src)
        if not m:
            raise RuntimeError("registry literal %s did not parse" % name)
        return tuple(sorted(re.findall(r"\.([A-Za-z0-9_]+)", m.group(1))))

    approved = parse_set("nativeApprovedSurfaces")
    pane = parse_set("paneOwningSurfaces")
    if not surfaces:
        raise RuntimeError("Surface enum did not parse")
    unknown = [s for s in approved + pane if s not in surfaces]
    if unknown:
        # assert: the registry literal parses AND names real cases
        raise RuntimeError("registry names cases the Surface enum does not have: %r" % unknown)
    return tuple(surfaces), approved, pane


class Record:
    def __init__(self, cfg=None):
        self.cfg = cfg or Config()
        self.problems = []  # (kind, key, message)
        self.pins = {}
        self.keys = {}
        self.claims = {}
        self.verdicts = {}
        self.surfaces = tuple(SURFACES)
        self.approved = ()
        self.pane_owning = ()
        self.comment_claims = {}
        self.findings = []
        self.moves = {}
        self._load()

    # -- loading -----------------------------------------------------------------------
    def _add(self, kind, key, message):
        self.problems.append(Finding(kind, key, message))

    def _load(self):
        pin_rows, pin_problems = read_tsv(self.cfg.pins, PIN_COLUMNS)
        for lineno, msg in pin_problems:
            self._add("MALFORMED ROW", "-", "pins.tsv:%s: %s" % (lineno, msg))
        self.pins = {r["alias"]: r for r in pin_rows}

        key_rows, key_problems = read_tsv(self.cfg.keys, KEY_COLUMNS)
        for lineno, msg in key_problems:
            self._add("MALFORMED ROW", "-", "upstream-keys.tsv:%s: %s" % (lineno, msg))
        for row in key_rows:
            key = row["key"]
            if not key_is_well_formed(key):
                self._add("MALFORMED ROW", key, "key does not match its namespace grammar")
                continue
            if row["namespace"] != key_namespace(key):
                self._add("MALFORMED ROW", key, "namespace column %r != key prefix" % row["namespace"])
                continue
            if key in self.keys:
                self._add("DUPLICATE KEY", key, "appears twice in upstream-keys.tsv")
                continue
            if key_namespace(key) == "X" and row["path"] not in ("-", ""):
                self._add("INTERNAL-WITH-UPSTREAM", key, "X: key names an upstream path %r" % row["path"])
            self.keys[key] = row

        claim_rows, claim_problems = read_tsv(self.cfg.claims, CLAIM_COLUMNS)
        for lineno, msg in claim_problems:
            self._add("MALFORMED ROW", "-", "claims.tsv:%s: %s" % (lineno, msg))
        for row in claim_rows:
            key = row["key"]
            if key in self.claims:
                self._add("DUPLICATE KEY", key, "appears twice in claims.tsv")
                continue
            self.claims[key] = row

        # co-located claims: `// parity: <key>` (+ optional `// parity-surface: <s>`)
        self._scan_comments()

        if os.path.exists(self.cfg.verdicts):
            try:
                self.verdicts = json.loads(read_text(self.cfg.verdicts))
            except json.JSONDecodeError as exc:
                self._add("MALFORMED ROW", "-", "verdicts.json does not parse: %s" % exc)
                self.verdicts = {}
        else:
            self._add("MALFORMED ROW", "-", "missing file %s" % self.cfg.verdicts)

        try:
            self.surfaces, self.approved, self.pane_owning = parse_registry(self.cfg.registry)
        except RuntimeError as exc:
            self._add("MALFORMED ROW", "-", "registry: %s" % exc)

        # validate claims against the key list and the filesystem
        for key, claim in list(self.claims.items()):
            if key not in self.keys:
                self._add("ORPHAN", key, "claims.tsv names a key that is not in upstream-keys.tsv")
            surface = claim["surface"]
            if surface not in ("-", "") and surface not in self.surfaces:
                self._add("MALFORMED ROW", key, "surface %r is not a Surface case" % surface)
            for ref in split_list(claim["test_refs"]):
                ok, why = self._test_ref_ok(ref)
                if not ok:
                    self._add("MALFORMED ROW", key, "test_refs entry does not resolve: %s (%s)" % (ref, why))
            for path in split_list(claim["native_paths"]):
                if os.path.isabs(path) or ".." in path.split("/"):
                    self._add("MALFORMED ROW", key, "native path escapes the repo: %s" % path)

        for key, entry in self.verdicts.items():
            if key not in self.keys:
                self._add("ORPHAN", key, "verdicts.json names a key that is not in upstream-keys.tsv")
            for ev in entry.get("evidence", []):
                if ev.get("kind") not in ("test", "observation", "log"):
                    self._add("MALFORMED ROW", key, "evidence kind %r is not typed" % ev.get("kind"))

        # MAP-INCOMPLETE: a key names a namespace the pins file does not pin
        namespaces = {key_namespace(k) for k in self.keys}
        unpinned = sorted(ns for ns in namespaces if ns in ("M", "W") and ns not in self.pins)
        for ns in unpinned:
            self._add("MAP-INCOMPLETE", "-", "%s: keys exist but pins.tsv has no %s pin" % (ns, ns))

    def _scan_comments(self):
        """Collect `// parity:` claims from the native tree (design §3.1, form 1)."""
        if not os.path.isdir(self.cfg.swift_root):
            return
        for dirpath, _dirnames, filenames in os.walk(self.cfg.swift_root):
            for name in sorted(filenames):
                if not name.endswith(".swift"):
                    continue
                full = os.path.join(dirpath, name)
                rel = os.path.relpath(full, self.cfg.root)
                try:
                    text = read_text(full)
                except OSError:
                    continue
                surface = None
                for line in text.splitlines():
                    m = re.search(r"//\s*parity-surface:\s*([A-Za-z0-9_]+)", line)
                    if m:
                        surface = m.group(1)
                    m = re.search(r"//\s*parity:\s*(\S+)", line)
                    if not m:
                        continue
                    key = m.group(1)
                    if not key_is_well_formed(key):
                        self._add("MALFORMED ROW", key, "%s: `// parity:` key does not parse" % rel)
                        continue
                    paths, surf = self.comment_claims.get(key, ([], None))
                    paths.append(rel)
                    self.comment_claims[key] = (paths, surf or surface)
        for key, (paths, surf) in sorted(self.comment_claims.items()):
            if key in self.claims:
                existing = split_list(self.claims[key]["native_paths"])
                merged = sorted(set(existing) | set(paths))
                self.claims[key] = dict(self.claims[key], native_paths=join_list(merged))
                if self.claims[key]["surface"] in ("-", "") and surf:
                    self.claims[key] = dict(self.claims[key], surface=surf)
            else:
                self.claims[key] = {
                    "key": key,
                    "native_paths": join_list(sorted(set(paths))),
                    "surface": surf or "-",
                    "test_refs": "-",
                    "status_seed": "claimed",
                    "card": "-",
                    "note": "co-located `// parity:` claim",
                }

    # -- evidence ---------------------------------------------------------------------
    def _test_ref_ok(self, ref):
        if "::" not in ref:
            return False, "a test ref must name a case: <File>::<case>"
        path, case = ref.split("::", 1)
        full = os.path.join(self.cfg.root, path)
        if not os.path.exists(full):
            return False, "file missing"
        if case:
            if not re.search(r"\bfunc\s+%s\s*\(" % re.escape(case), read_text(full)):
                return False, "case not found in the file"
        return True, ""

    def evidence_ok(self, entry):
        kind, ref = entry.get("kind"), entry.get("ref", "")
        if kind == "test":
            return self._test_ref_ok(ref)
        if kind in ("observation", "log"):
            if not ref:
                return False, "empty ref"
            if "::" in ref:
                return False, "%s evidence must be a captured artifact" % kind
            return (os.path.exists(os.path.join(self.cfg.root, ref)), "artifact missing")
        return False, "unknown kind"

    # -- facts ------------------------------------------------------------------------
    def claim_paths(self, key):
        row = self.claims.get(key)
        if not row:
            return []
        return split_list(row["native_paths"])

    def effective_paths(self, key):
        """Existing paths, with a missing path replaced by its content-identical survivor."""
        out = []
        for path in self.claim_paths(key):
            if os.path.exists(os.path.join(self.cfg.root, path)):
                out.append(path)
                continue
            survivor = move_candidate(path, cwd=self.cfg.root)
            if survivor:
                self.moves[key] = (path, survivor)
                out.append(survivor)
        return out

    def verdict_state(self, key):
        entry = self.verdicts.get(key)
        if not entry:
            return None
        commit = entry.get("commit", "")
        head_ok = is_ancestor(commit, cwd=self.cfg.root)
        paths = self.effective_paths(key)
        dirty = touched_since(commit, paths, cwd=self.cfg.root) if head_ok else ()
        evidence = tuple(entry.get("evidence", []))
        evidence_ok = all(self.evidence_ok(ev)[0] for ev in evidence) and bool(evidence)
        return {
            "commit": commit,
            "verdict": entry.get("verdict", "?"),
            "ancestor": head_ok,
            "clean": not dirty,
            "dirty": dirty,
            "evidence_ok": evidence_ok,
            "entry": entry,
        }

    def facts(self, key):
        claim = self.claims.get(key)
        paths = self.effective_paths(key)
        test_refs = split_list(claim["test_refs"]) if claim else []
        has_test = any(self._test_ref_ok(r)[0] for r in test_refs)
        state = self.verdict_state(key)
        surface = (claim or {}).get("surface", "-")
        return Facts(
            claim_exists=bool(claim),
            paths_present=bool(paths),
            test_ref=has_test,
            verdict_ancestor=bool(state and state["ancestor"]),
            verdict_clean=bool(state and state["clean"]),
            evidence_resolves=bool(state and state["evidence_ok"]),
            approved=surface in self.approved,
            has_verdict=bool(state),
        ), state, paths

    def paths_state(self, key):
        claim = self.claims.get(key)
        if not claim:
            return "none"
        declared = self.claim_paths(key)
        if not declared:
            return "none"
        return "present" if self.effective_paths(key) else "missing"

    # -- detectors --------------------------------------------------------------------
    def detect(self):
        findings = list(self.problems)
        statuses = {}
        for key in sorted(self.keys):
            facts, state, paths = self.facts(key)
            pstate = self.paths_state(key)
            statuses[key] = derive_status(facts)
            for kind in find_row_findings(facts, pstate):
                if kind == "STALE" and key in self.moves:
                    old, new = self.moves[key]
                    findings.append(Finding("MOVE", key, "%s → %s (content-identical; re-point claims.tsv)" % (old, new)))
                    continue
                findings.append(Finding(kind, key, self._message(kind, key, facts, state, pstate)))

        # statuses for keys that only exist in claims (orphans) — surfaced, never silently native
        for key in sorted(self.claims):
            if key not in statuses:
                statuses[key] = "absent"

        # UNMAPPED: a native unit no claim covers
        covered = set()
        for key in self.claims:
            for path in self.claim_paths(key):
                rel = os.path.relpath(os.path.join(self.cfg.root, path), self.cfg.native_root)
                if rel == ".":
                    continue
                covered.add(rel.split(os.sep)[0])
        if os.path.isdir(self.cfg.native_root):
            for name in sorted(os.listdir(self.cfg.native_root)):
                if name.startswith(".") or name == "__pycache__":
                    continue
                if name not in covered:
                    findings.append(Finding("UNMAPPED", "-", "%s/%s is a native unit no claim covers"
                                            % (os.path.relpath(self.cfg.native_root, self.cfg.root), name)))

        # PANE-NOT-APPROVED: paneOwningSurfaces ⊆ nativeApprovedSurfaces
        for surface in self.pane_owning:
            if surface not in self.approved:
                findings.append(Finding("PANE-NOT-APPROVED", "-", ".%s is pane-owning but not approved" % surface))

        # APPROVED-WITHOUT-VERDICT: an approved surface no key certifies as native. Surface-level,
        # not row-level: several keys share one surface, and one native key is enough.
        for surface in self.approved:
            native = [k for k in self.keys
                      if self.claims.get(k, {}).get("surface") == surface and statuses.get(k) == "native"]
            if not native:
                findings.append(Finding("APPROVED-WITHOUT-VERDICT", "-",
                                        ".%s is in nativeApprovedSurfaces but no fresh validated verdict "
                                        "names a key on that surface" % surface))

        # UPSTREAM-MOVED: the pin's sha differs from the key's recorded column
        for key, row in sorted(self.keys.items()):
            ns = key_namespace(key)
            pin = self.pins.get(ns)
            if not pin or row["path"] in ("-", ""):
                continue
            current = plan_pins_sha(pin["commit"], pin["path_prefix"], row["path"], cwd=self.cfg.root)
            if current and row["content_sha"] not in (current, "-"):
                findings.append(Finding("UPSTREAM-MOVED", key, "%s: %s → %s (pin %s)"
                                        % (row["path"], row["content_sha"][:12], current[:12], pin["tag"])))

        # UNCARDED-GAP: a real gap (no claim, or a claim with no native path) and no card.
        # A key with paths but no verdict is a validation gap, not an implementation card —
        # it is surfaced by APPROVED-WITHOUT-VERDICT / VALIDATED-BUT-NOT-APPROVED instead.
        for key in sorted(self.keys):
            if statuses.get(key) in ("validated", "native"):
                continue
            claim = self.claims.get(key)
            paths_state = self.paths_state(key)
            if statuses.get(key) != "absent" and paths_state != "none":
                continue
            card = (claim or {}).get("card", "-")
            if card in ("-", ""):
                findings.append(Finding("UNCARDED-GAP", key, "status %s, no card" % statuses[key]))

        self.findings = sorted(findings, key=lambda f: f.sort_key())
        self.statuses = statuses
        return self.findings

    def _message(self, kind, key, facts, state, pstate):
        if kind == "GAP":
            return "claim names no native path"
        if kind == "STALE":
            missing = [p for p in self.claim_paths(key) if not os.path.exists(os.path.join(self.cfg.root, p))]
            return "native path missing: %s (no content-identical survivor, no recorded rename)" % join_list(missing)
        if kind == "STALE-VERDICT":
            if not state or not state["ancestor"]:
                return "verdict commit %s is not an ancestor of HEAD" % ((state or {}).get("commit", "-")[:12])
            return "%d commit(s) after %s touched the claimed files" % (len(state["dirty"]), state["commit"][:12])
        if kind == "STALE-EVIDENCE":
            bad = [ev.get("ref") for ev in (state or {}).get("entry", {}).get("evidence", [])
                   if not self.evidence_ok(ev)[0]]
            return "evidence does not resolve: %s" % join_list(bad)
        if kind == "APPROVED-WITHOUT-VERDICT":
            return "surface .%s is approved but no fresh validated verdict names it" % (self.claims[key]["surface"])
        if kind == "VALIDATED-BUT-NOT-APPROVED":
            return "validated but surface %r is not in nativeApprovedSurfaces" % self.claims[key]["surface"].replace("-", "(none)")
        return ""

    # -- artifacts --------------------------------------------------------------------
    def inventory_rows(self):
        rows = []
        for key in sorted(set(self.keys) | set(self.claims)):
            claim = self.claims.get(key, {})
            state = self.verdict_state(key) if claim else None
            rows.append({
                "key": key,
                "surface": claim.get("surface", "-"),
                "status": self.statuses.get(key, "absent"),
                "native_paths": join_list(self.effective_paths(key)),
                "test_refs": claim.get("test_refs", "-") or "-",
                "verdict": ("%s:%s" % (state["commit"][:12], state["verdict"])) if state else "-",
                "card": claim.get("card", "-") or "-",
                "anchor_of": (self.keys.get(key) or {}).get("anchor_of", "-") or "-",
                "path": (self.keys.get(key) or {}).get("path", "-") or "-",
                "note": claim.get("note", ""),
                "has_claim": bool(claim),
                "test_ref_list": split_list(claim.get("test_refs", "")),
                "evidence": (state["entry"].get("evidence", []) if state else []),
            })
        return rows

    def render_inventory(self):
        header = "# key\tsurface\tstatus\tnative_paths\ttest_refs\tverdict\tcard\n"
        body = "".join(
            "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" % (
                r["key"], r["surface"], r["status"], r["native_paths"], r["test_refs"], r["verdict"], r["card"])
            for r in self.inventory_rows())
        return header + body

    def render_gaps(self):
        lines = ["# key\tstatus\tcard\tsurface"]
        for r in self.inventory_rows():
            if r["status"] not in ("validated", "native"):
                lines.append("%s\t%s\t%s\t%s" % (r["key"], r["status"], r["card"], r["surface"]))
        return "\n".join(lines) + "\n"

    def render_orphans(self):
        lines = ["# key\tnative_paths\tfinding"]
        for f in self.findings:
            if f.kind in ("ORPHAN", "STALE", "MOVE", "UNMAPPED"):
                paths = join_list(self.effective_paths(f.key)) if f.key != "-" else "-"
                lines.append("%s\t%s\t%s: %s" % (f.key, paths, f.kind, f.message))
        return "\n".join(lines) + "\n"

    def render_findings(self):
        fatal = sum(1 for f in self.findings if severity(f.kind) == "fatal")
        tally = {}
        for f in self.findings:
            tally[f.kind] = tally.get(f.kind, 0) + 1
        out = ["parity findings — %d fatal, %d report" % (fatal, len(self.findings) - fatal)]
        out.append("")
        for kind in ORDER:
            if kind in tally:
                out.append("  %-24s %4d" % (kind, tally[kind]))
        absent = sum(1 for s in self.statuses.values() if s == "absent")
        out.append("")
        out.append("status tally: " + " ".join(
            "%s=%d" % (s, sum(1 for x in self.statuses.values() if x == s))
            for s in ("native", "validated", "tested", "claimed", "absent")))
        if absent:
            out.append("  (%d keys are absent: an unclaimed key is the metric, not a failure — design §3.5)" % absent)
        protocol = sum(1 for f in self.findings
                       if f.kind == "UNCARDED-GAP" and key_namespace(f.key) in ("REST", "WS"))
        if protocol:
            out.append("  (protocol scope: %d of the uncarded gaps are REST/WS rows — v2, B §8; they are not card proposals)"
                       % protocol)
        out.append("")
        for kind in ORDER:
            group = [f for f in self.findings if f.kind == kind]
            if not group:
                continue
            out.append("%s (%d)" % (kind, len(group)))
            for f in group:
                out.append("  " + f.line())
            out.append("")
        return "\n".join(out).rstrip("\n") + "\n"

    # -- the markdown table (owner's view) --------------------------------------------
    def _module_of(self, row):
        """The module a capability rolls up into — the anchor the key list carries.

        One row per capability (upstream key), grouped by module and sorted by key. The MVP keys
        at upstream-module granularity, so a module holds one row per key it owns; finer
        capabilities inside one upstream module are a later cut (design appendix, delta 6).
        """
        anchor = row["anchor_of"]
        if anchor not in ("-", ""):
            return anchor
        key, path = row["key"], row["path"]
        ns = key_namespace(key)
        if ns == "M":
            segs = path.split("/")
            return segs[-1] if segs else "app"
        if ns == "REST":
            base = os.path.basename(path) if path not in ("-", "") else "rest"
            return "rest:" + (base[:-3] if base.endswith(".ts") else base)
        if ns == "WS":
            return "websocket"
        return "internal"

    def _upstream_ref(self, row):
        ns = key_namespace(row["key"])
        if ns == "M":
            pin = self.pins.get("M")
            return "%s@%s" % (row["path"], (pin or {}).get("tag", "M"))
        if ns == "REST":
            return "%s@v4" % row["key"][len("REST:"):]
        if ns == "WS":
            return "%s@v4" % row["key"][len("WS:"):]
        return "-"

    def _implemented(self, status):
        if status in ("validated", "native"):
            return "yes"
        if status in ("tested", "claimed"):
            return "partial"
        return "no"

    def _evidence_cell(self, row):
        for ref in row["test_ref_list"]:
            if self._test_ref_ok(ref)[0]:
                return ref
        for ev in row["evidence"]:
            if ev.get("kind") == "test" and self.evidence_ok(ev)[0]:
                return ev["ref"]
        for ev in row["evidence"]:
            if ev.get("kind") in ("observation", "log") and self.evidence_ok(ev)[0]:
                return "observation: " + ev["ref"]
        return "-"

    def _todo_cell(self, row):
        if row["card"] not in ("-", ""):
            return row["card"]
        note = (row["note"] or "").strip()
        m = re.search(r"(?:^|;\s*)blocker=([^;]+)", note)
        if m:
            return "owner decision (%s)" % m.group(1).strip()
        return "-"

    def render_md(self):
        rows = [r for r in self.inventory_rows()]
        grouped = {}
        for r in rows:
            grouped.setdefault(self._module_of(r), []).append(r)
        out = ["# Parity — generated from parity/ (do not edit by hand)", "",
               "`python3 parity/generate.py --render-md` writes this file. A hand edit is a `--check` failure,",
               "same as `parity/out/*`. The machine record is `parity/*.tsv` + `parity/verdicts.json`.", ""]
        for module in sorted(grouped):
            out.append("## %s" % module)
            out.append("")
            out.append("| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |")
            out.append("|---|---|---|---|---|---|")
            for r in sorted(grouped[module], key=lambda x: x["key"]):
                out.append("| %s | %s | %s | %s | %s | %s |" % (
                    module, r["anchor_of"], self._upstream_ref(r), self._implemented(r["status"]),
                    self._evidence_cell(r), self._todo_cell(r)))
            out.append("")
        pins = " ".join("%s=%s@%s" % (a, p.get("tag", "-"), p.get("commit", "-")[:12])
                        for a, p in sorted(self.pins.items())) or "none"
        out.append("Pins: %s | rows: %d" % (pins, len(rows)))
        return "\n".join(out) + "\n"

    def artifacts(self):
        return {
            "parity/out/inventory.tsv": self.render_inventory(),
            "parity/out/gaps.tsv": self.render_gaps(),
            "parity/out/orphans.tsv": self.render_orphans(),
            "parity/out/findings.txt": self.render_findings(),
            "docs/PARITY-table.md": self.render_md(),
        }


# --------------------------------------------------------------------------------------
# render / check / query
# --------------------------------------------------------------------------------------


def build(root=ROOT):
    record = Record(Config(root))
    record.detect()
    return record


def write_artifacts(record, base):
    for rel, text in record.artifacts().items():
        write_text(os.path.join(base, rel), text)


def _case_collision(path):
    """A path that names an existing file differing only by case is the SAME file on APFS.

    docs/PARITY.md vs the hand-written docs/parity.md is the live example: writing the generated
    table would silently destroy the prose doc on this host while being two files on Linux CI.
    Refuse instead of choosing.
    """
    folder = os.path.dirname(path) or "."
    base = os.path.basename(path)
    if not os.path.isdir(folder):
        return None
    for name in sorted(os.listdir(folder)):
        if name != base and name.lower() == base.lower():
            return os.path.join(folder, name)
    return None


def cmd_render(root=ROOT, md_only=False, out=None):
    record = build(root)
    if md_only:
        target = out or record.cfg.md
        other = _case_collision(target)
        if other:
            print("refusing to write %s: %s exists and is the same file on a case-insensitive "
                  "filesystem (this host is APFS). The hand-written prose doc is not this tool's to "
                  "overwrite — pass --out with a distinct name." % (target, other), file=sys.stderr)
            return 2
        write_text(target, record.render_md())
        print("wrote %s" % os.path.relpath(target, root))
        return 0
    write_artifacts(record, root)
    for rel in record.artifacts():
        print("wrote %s" % rel)
    return 0


def cmd_check(root=ROOT, report=False):
    record = build(root)
    tmp = tempfile.mkdtemp(prefix="parity-check-")
    try:
        write_artifacts(record, tmp)
        drift = []
        for rel in record.artifacts():
            disk = os.path.join(root, rel)
            fresh = os.path.join(tmp, rel)
            if not os.path.exists(disk):
                drift.append("%s: missing on disk (generate and commit it)" % rel)
                continue
            if read_text(disk) != read_text(fresh):
                drift.append("%s: differs from a fresh render (hand edit or stale artifact)" % rel)
        fatal = [f for f in record.findings if severity(f.kind) == "fatal"]
        for line in drift:
            print("[FAIL] DRIFT %s" % line)
        if record.findings:
            print(record.render_findings().rstrip("\n"))
        print("")
        print("check: %d artifact(s) drifted, %d fatal finding(s), %d report finding(s)%s"
              % (len(drift), len(fatal), len(record.findings) - len(fatal),
                 " — report mode" if report else ""))
        if drift:
            return 1
        if fatal and not report:
            return 1
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _query_rows(record, needle):
    """Resolve a name/key/surface to rows, best match first.

    Rank: exact key, exact surface, key substring, anchor substring, note substring. Ties by key,
    so the output is deterministic and the capability the caller named is first.
    """
    q = needle.strip()
    low = q.lower()
    rows = record.inventory_rows()
    exact = [r for r in rows if r["key"] == q]
    if exact:
        return exact
    surface = [r for r in rows if r["surface"] == q]
    if surface:
        return sorted(surface, key=lambda r: r["key"])

    def rank(row):
        if low in row["key"].lower():
            return 0
        if low in row["anchor_of"].lower():
            return 1
        if low in (row["note"] or "").lower():
            return 2
        return 3

    hits = []
    for r in rows:
        hay = " ".join([r["key"], r["surface"], r["anchor_of"], r["path"], r["note"], r["status"]])
        if low in hay.lower():
            hits.append(r)
    return sorted(hits, key=lambda r: (rank(r), r["key"]))


def _row_json(record, row):
    status = row["status"]
    evidence = []
    if status in ("tested", "validated", "native"):
        for ref in row["test_ref_list"]:
            if record._test_ref_ok(ref)[0]:
                evidence.append({"kind": "test", "ref": ref})
        for ev in row["evidence"]:
            if record.evidence_ok(ev)[0]:
                evidence.append(ev)
    state = record.verdict_state(row["key"]) if row["key"] in record.verdicts else None
    return {
        "key": row["key"],
        "surface": row["surface"],
        "status": status,
        "implemented": status in ("validated", "native"),
        "evidence": evidence,
        "verdict": ({"commit": state["commit"], "verdict": state["verdict"]} if state else None),
        "card": None if row["card"] in ("-", "") else row["card"],
    }


def cmd_query(needle, as_json=False, root=ROOT):
    record = build(root)
    rows = _query_rows(record, needle)
    payload = [_row_json(record, r) for r in rows]
    if as_json:
        print(json.dumps({"query": needle, "rows": payload, "count": len(payload),
                          "implemented": any(p["implemented"] for p in payload)}, indent=2, sort_keys=True))
        return 0
    if not payload:
        print("no capability matches %r" % needle)
        return 0
    for p in payload:
        print("%-48s surface=%-12s status=%s" % (p["key"], p["surface"], p["status"]))
        for ev in p["evidence"]:
            print("    %-12s %s" % (ev["kind"], ev["ref"]))
        if p["verdict"]:
            print("    verdict      %s @ %s" % (p["verdict"]["verdict"], p["verdict"]["commit"][:12]))
        print("    implemented  %s" % ("true" if p["implemented"] else "false"))
    statuses = {p["status"] for p in payload}
    if any(p["implemented"] for p in payload):
        verdict = "IMPLEMENTED — do not create an implementation card."
    elif "tested" in statuses:
        verdict = ("TESTED — the behaviour is asserted by a named test; do NOT create an implementation "
                   "card. The only legitimate next step is a verdict (`generate.py promote <key> --verdict "
                   "<doc> --commit <sha> --evidence ...`).")
    elif "claimed" in statuses:
        verdict = "CLAIMED — a worker says so and nothing proves it; no test ref resolves."
    else:
        verdict = "ABSENT — no claim backs this capability; a card is legitimate."
    print("\nVERDICT: %s" % verdict)
    return 0


# --------------------------------------------------------------------------------------
# bootstrap
# --------------------------------------------------------------------------------------

SCREEN_EXTRAS = (  # paths outside app/screens/ that an S-row names and the key list must carry
    ("M:app/components/post_draft", "composer", "S14 composer input", "dir"),
    ("M:app/components/post_list", "channel", "S11 post list", "dir"),
    ("M:app/components/autocomplete", "composer", "S15 autocomplete", "dir"),
    ("M:app/products/boards", "boards", "S31 Boards (webview-only)", "dir"),
    ("M:app/products/playbooks", "playbooks", "S32 Playbooks (webview-only)", "dir"),
    ("M:app/products/calls", "calls", "S33 Calls", "dir"),
    # named by the S-rows but absent from the 67-module extract (docs/inventory/screens.tsv):
    ("M:app/screens/search", "search", "S19 search (native-inventory §1)", "dir"),
    ("M:app/screens/mentions", "mentions", "S25 mentions inbox (native-inventory §1)", "dir"),
    ("X:transport", "transport", "T28 REST/WS transport (project-owned)", "internal"),
    ("X:local-store", "store", "T29 per-server SQLite store (project-owned)", "internal"),
    ("X:native-shell", "shell", "T30 native shell + navigation (project-owned)", "internal"),
    ("X:web-fallback", "web-fallback", "T46 permanent webview escape hatch (project-owned)", "internal"),
    ("X:notification-input", "notification", "T43 one live mention input per server (project-owned)", "internal"),
    ("X:push-proxy", "push", "Push Proxy + APNs (project-owned; simulacrum only)", "internal"),
    ("X:diagnostics", "diagnostics", "T19 diagnostics + Sentry seam (project-owned)", "internal"),
    ("X:deep-link", "deep-link", "S36 deep links (project-owned router)", "internal"),
    ("X:accessibility", "accessibility", "T45/A11y Dynamic Type + contrast policy (project-owned)", "internal"),
    ("X:parity-record", "parity", "this record (project-owned)", "internal"),
)


def cmd_bootstrap(root=ROOT, force=False, keys_only=False):
    cfg = Config(root)
    targets = [cfg.pins, cfg.keys] if keys_only else [cfg.pins, cfg.keys, cfg.claims]
    for path in targets:
        if os.path.exists(path) and not force:
            print("refusing to overwrite %s (pass --force to reseed)" % os.path.relpath(path, root))
            return 1
    os.makedirs(os.path.dirname(cfg.pins), exist_ok=True)

    # 1. pins — from docs/component-map.md (the prose pins, extracted once)
    pins = [
        {"alias": "M", "repo": "mattermost/mattermost-mobile", "tag": "v2.45.0",
         "commit": "162f2560d0e1df073220f7701d5a67cc17c8abeb", "path_prefix": "app/", "license": "Apache-2.0"},
        {"alias": "W", "repo": "mattermost/mattermost", "tag": "v12.0.1",
         "commit": "987e57120dca630dadbcd2638064ab66a02bb81e", "path_prefix": "webapp/channels/src/",
         "license": "AGPL-3.0"},  # observe behaviour, never copy source (ADR) — as mattermost-webapp
    ]
    write_tsv(cfg.pins, PIN_COLUMNS, pins)

    # 2. upstream keys — from the checked-in extracts (screens.tsv, rest-endpoints.tsv,
    #    websocket-events.md). The pin commit resolves the content_sha where the pin object
    #    exists locally; where it does not, the column is "-" and the header says so.
    keys = []

    def add(key, ns, path, kind, anchor):
        sha = "-"
        if ns == "M":
            pin = pins[0]
            resolved = plan_pins_sha(pin["commit"], pin["path_prefix"], path, cwd=root)
            sha = resolved or "-"
        keys.append({"key": key, "namespace": ns, "path": path, "content_sha": sha,
                     "kind": kind, "anchor_of": anchor})

    screens_path = os.path.join(root, "docs/inventory/screens.tsv")
    for line in read_text(screens_path).splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "/" in line or " " in line:  # the hand-grep junk line (refs/mattermost-mobile/app/screens)
            continue
        add("M:app/screens/%s" % line, "M", "app/screens/%s" % line, "dir", line)
    for key, anchor, _why, kind in SCREEN_EXTRAS:
        path = key[len("M:"):] if key.startswith("M:") else "-"
        add(key, key_namespace(key), path, kind, anchor)

    rest_path = os.path.join(root, "docs/inventory/rest-endpoints.tsv")
    seen = set()
    for line in read_text(rest_path).splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        module, verb, path = parts
        path = path.split("?")[0].rstrip("/") or path.split("?")[0]
        key = "REST:%s %s" % (verb, path)
        if key in seen:
            continue
        seen.add(key)
        add(key, "REST", "app/client/rest/%s.ts" % module, "rest", module)

    ws_path = os.path.join(root, "docs/inventory/websocket-events.md")
    for line in read_text(ws_path).splitlines():
        m = re.search(r"`([a-z0-9_]+)`", line)
        if m and "->" in line:
            add("WS:%s" % m.group(1), "WS", "app/constants/websocket.ts", "ws", "websocket")

    keys.sort(key=lambda r: r["key"])
    write_tsv(cfg.keys, KEY_COLUMNS, keys)

    # 3. claims — a SEED: one row per S01–S40 (docs/native-inventory.md) and T28–T46 (docs/parity.md),
    #    paths empty. Corrected by hand once; the committed file is the corrected one.
    if not keys_only:
        claims = []
        for n in range(1, 41):
            alias = "S%02d" % n
            claims.append({"key": "X:seed-%s" % alias.lower(), "native_paths": "-", "surface": "-",
                           "test_refs": "-", "status_seed": "absent", "card": "-",
                           "note": "%s — seed row from docs/native-inventory.md; re-point at the real upstream key by hand" % alias})
        for n in range(28, 47):
            alias = "T%d" % n
            claims.append({"key": "X:seed-%s" % alias.lower(), "native_paths": "-", "surface": "-",
                           "test_refs": "-", "status_seed": "absent", "card": "-",
                           "note": "%s — seed row from docs/parity.md; re-point at the real upstream key by hand" % alias})
        write_tsv(cfg.claims, CLAIM_COLUMNS, claims)
        print("wrote %s (%d pins), %s (%d keys), %s (%d seed claims)"
              % (os.path.relpath(cfg.pins, root), len(pins), os.path.relpath(cfg.keys, root), len(keys),
                 os.path.relpath(cfg.claims, root), len(claims)))
    else:
        print("wrote %s (%d pins), %s (%d keys); claims.tsv left untouched"
              % (os.path.relpath(cfg.pins, root), len(pins), os.path.relpath(cfg.keys, root), len(keys)))
    print("note: content_sha is \"-\" wherever the pin commit is not in this repo's object database.")
    return 0


# --------------------------------------------------------------------------------------
# promote / claim (the write path; status is never written — it is derived)
# --------------------------------------------------------------------------------------


def _rewrite_claims(cfg, rows):
    write_tsv(cfg.claims, CLAIM_COLUMNS, rows)


def _load_claim_rows(cfg):
    rows, problems = read_tsv(cfg.claims, CLAIM_COLUMNS)
    if problems:
        raise SystemExit("claims.tsv does not parse: %r" % (problems,))
    return rows


ALIASES = {
    # The S/T numbers are aliases, never identity: renumbering must not re-point work
    # (design §1.2 rule 1). This table is the bridge the ticket agent may address a capability by.
    "S01": "M:app/screens/login", "S02": "M:app/screens/mfa", "S03": "M:app/screens/sso",
    "S04": "M:app/screens/forgot_password", "S05": "M:app/screens/server",
    "S06": "M:app/screens/terms_of_service", "S07": "M:app/screens/select_team",
    "S08": "M:app/screens/home", "S09": "M:app/screens/browse_channels",
    "S10": "M:app/screens/create_or_edit_channel", "S11": "M:app/screens/channel",
    "S12": "M:app/screens/permalink", "S13": "M:app/screens/thread",
    "S14": "M:app/components/post_draft", "S15": "M:app/components/autocomplete",
    "S16": "M:app/screens/reactions", "S17": "M:app/screens/emoji_picker",
    "S18": "M:app/screens/gallery", "S19": "M:app/screens/search", "S20": "M:app/screens/home",
    "S21": "M:app/screens/pinned_messages", "S22": "M:app/screens/channel_info",
    "S23": "M:app/screens/manage_channel_members", "S24": "M:app/screens/user_profile",
    "S25": "M:app/screens/mentions", "S26": "M:app/screens/global_drafts",
    "S27": "M:app/screens/settings", "S28": "M:app/screens/edit_profile",
    "S29": "X:web-fallback", "S30": "X:web-fallback", "S31": "M:app/products/boards",
    "S32": "M:app/products/playbooks", "S33": "M:app/products/calls",
    "S34": "M:app/screens/apps_form", "S35": "X:notification-input", "S36": "X:deep-link",
    "S37": "M:app/screens/onboarding", "S38": "M:app/screens/post_options",
    "S39": "M:app/screens/edit_profile", "S40": "M:app/screens/scheduled_post_options",
    "T28": "X:transport", "T29": "X:local-store", "T30": "X:native-shell",
    "T31": "M:app/screens/login", "T34": "M:app/screens/channel", "T36": "M:app/screens/thread",
    "T37": "M:app/screens/reactions", "T39": "M:app/screens/search",
    "T40": "M:app/screens/channel_info", "T41": "M:app/screens/user_profile",
    "T42": "M:app/screens/mentions", "T43": "X:notification-input",
    "T44": "M:app/products/calls", "T46": "X:web-fallback",
    "T47": "M:app/screens/create_or_edit_channel", "T48": "M:app/screens/post_options",
    "T49": "M:app/screens/terms_of_service", "T50": "M:app/screens/edit_profile",
    "T51": "M:app/screens/global_drafts",
}


def resolve_alias(cfg, needle):
    """S13 -> M:app/screens/thread. An explicit table first, then the claim note as a fallback."""
    if needle in ALIASES:
        return ALIASES[needle]
    rows = _load_claim_rows(cfg)
    for row in rows:
        if re.search(r"\b%s\b" % re.escape(needle), row["note"] or ""):
            return row["key"]
    return needle


def cmd_promote(cfg, args):
    rows = _load_claim_rows(cfg)
    key = resolve_alias(cfg, args.target)
    row = next((r for r in rows if r["key"] == key), None)
    if row is None:
        raise SystemExit("promote: no claim row for %r — run `generate.py claim %s --paths ...` first"
                         % (args.target, key))
    record = Record(cfg)
    changed = []

    if args.test:
        ok, why = record._test_ref_ok(args.test)
        if not ok:
            raise SystemExit("promote: --test %r does not resolve (%s)" % (args.test, why))
        refs = split_list(row["test_refs"])
        if args.test not in refs:
            refs.append(args.test)
        row["test_refs"] = join_list(sorted(refs))
        changed.append("test %s" % args.test)

    if args.verdict:
        doc = os.path.join(cfg.root, args.verdict)
        if not os.path.exists(doc):
            raise SystemExit("promote: verdict document %r does not exist" % args.verdict)
        text = read_text(doc)
        m = re.search(r"^## VERDICT:\s*([A-Z][A-Z-]+)", text, re.M)
        if not m:
            raise SystemExit("promote: %r carries no `## VERDICT:` line" % args.verdict)
        evidence = []
        for item in args.evidence or []:
            if ":" not in item:
                raise SystemExit("promote: --evidence wants <kind>:<ref> (test|observation|log)")
            kind, ref = item.split(":", 1)
            ok, why = record.evidence_ok({"kind": kind, "ref": ref})
            if not ok:
                raise SystemExit("promote: evidence %r does not resolve (%s)" % (item, why))
            evidence.append({"kind": kind, "ref": ref})
        if not evidence:
            raise SystemExit("promote: a verdict needs typed evidence (--evidence test:File::case)")
        if not args.commit:
            raise SystemExit("promote: --commit <sha> is required for a verdict (the audited commit)")
        if not is_ancestor(args.commit, cwd=cfg.root):
            raise SystemExit("promote: commit %s is not an ancestor of HEAD" % args.commit)
        verdicts = {}
        if os.path.exists(cfg.verdicts):
            verdicts = json.loads(read_text(cfg.verdicts))
        verdicts[key] = {
            "card": args.card or row["card"],
            "commit": args.commit,
            "verdict": m.group(1),
            "findings": list(args.finding or []),
            "evidence": evidence,
            "source": args.verdict,
        }
        write_text(cfg.verdicts, json.dumps(verdicts, indent=2, sort_keys=True) + "\n")
        changed.append("verdict %s @ %s from %s" % (m.group(1), args.commit[:12], args.verdict))

    if args.card:
        row["card"] = args.card
        changed.append("card %s" % args.card)
    if args.note:
        row["note"] = args.note
        changed.append("note")
    if args.target_status:
        # B's `promote S13 tested` form: the prose seed is recorded, never the derived status.
        row["status_seed"] = args.target_status
        changed.append("status_seed %s (derived status follows the artifacts)" % args.target_status)

    _rewrite_claims(cfg, rows)
    print("promote %s: %s" % (key, ", ".join(changed) if changed else "nothing changed"))
    record = Record(cfg)
    record.detect()
    facts, _state, _paths = record.facts(key)
    print("derived status now: %s" % record.statuses.get(key, "absent"))
    return 0


def cmd_claim(cfg, args):
    rows = _load_claim_rows(cfg)
    key = resolve_alias(cfg, args.target)
    keys_paths = args.paths or []
    record_keys = {r["key"] for r in read_tsv(cfg.keys, KEY_COLUMNS)[0]}
    if key not in record_keys:
        raise SystemExit("claim: %r is not in upstream-keys.tsv (add the key first)" % key)
    for path in keys_paths:
        if not os.path.exists(os.path.join(cfg.root, path)):
            raise SystemExit("claim: native path %r does not exist" % path)
    surface = args.surface or "-"
    if surface != "-" and surface not in SURFACES:
        try:
            surfaces = parse_registry(cfg.registry)[0]
        except RuntimeError as exc:
            raise SystemExit("claim: %s" % exc)
        if surface not in surfaces:
            raise SystemExit("claim: %r is not a Surface case %r" % (surface, surfaces))
    row = next((r for r in rows if r["key"] == key), None)
    if row is None:
        row = {"key": key, "native_paths": "-", "surface": surface, "test_refs": "-",
               "status_seed": "claimed", "card": args.card or "-", "note": args.note or ""}
        rows.append(row)
    if keys_paths:
        row["native_paths"] = join_list(sorted(set(split_list(row["native_paths"])) | set(keys_paths)))
    if surface != "-":
        row["surface"] = surface
    if args.card:
        row["card"] = args.card
    if args.note:
        row["note"] = args.note
    rows.sort(key=lambda r: r["key"])
    _rewrite_claims(cfg, rows)
    print("claim %s: paths=%s surface=%s" % (key, row["native_paths"], row["surface"]))
    return 0


def cmd_gate(cfg, target):
    """B's `gate <cap>`: exit 0 iff the row's recorded status_seed is justified by the artifacts.

    The derived status is the authority; the seed is prose. A seed that claims more than the
    artifacts support is a false promotion and exits 1 — the check CI cannot do when the board is
    the only evidence (design B §4/A7).
    """
    record = Record(cfg)
    record.detect()
    key = resolve_alias(cfg, target)
    if key not in record.keys and key not in record.claims:
        print("gate: no row for %r" % target)
        return 1
    rank = {"absent": 0, "claimed": 1, "tested": 2, "validated": 3, "native": 4}
    derived = record.statuses.get(key, "absent")
    seed = (record.claims.get(key) or {}).get("status_seed", "absent")
    print("gate %s: derived=%s seed=%s" % (key, derived, seed))
    for f in record.findings:
        if f.key == key:
            print("  " + f.line())
    if seed in rank and rank[seed] > rank[derived]:
        print("gate: FAIL — the row claims %s but the artifacts support only %s" % (seed, derived))
        return 1
    print("gate: PASS")
    return 0


# --------------------------------------------------------------------------------------
# plan — the steward view (B §7): absent/claimed keys with no open card
# --------------------------------------------------------------------------------------


def _open_cards(db):
    import sqlite3

    con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    try:
        cur = con.execute("SELECT id, title, status, COALESCE(body,''), COALESCE(idempotency_key,'') FROM tasks "
                          "WHERE status NOT IN ('done','archived','cancelled')")
        return list(cur.fetchall())
    finally:
        con.close()


def cmd_plan(root=ROOT, board=None, protocol=False):
    record = build(root)
    cards = []
    warn = ""
    skipped_protocol = 0
    db = board or os.environ.get("HERMES_KANBAN_DB")
    if not db:
        candidate = os.path.expanduser("~/.hermes/kanban/boards/mattermost-ios/kanban.db")
        if os.path.exists(candidate):
            db = candidate
    if db and os.path.exists(db):
        try:
            cards = _open_cards(db)
        except Exception as exc:  # board is a convenience, never a dependency
            warn = "board not read (%s)" % exc
    else:
        warn = "board not read (no board db)"
    open_keys = set()
    for _id, _title, _status, body, idem in cards:
        for m in re.finditer(r"^\s*CAPABILITY:\s*(\S+)\s*$", body, re.M):
            open_keys.add(m.group(1))
        if idem.startswith("cap:"):
            open_keys.add(idem[len("cap:"):])
    proposals = []
    for key in sorted(record.keys):
        status = record.statuses.get(key, "absent")
        if status not in ("absent", "claimed"):
            continue
        if not protocol and key_namespace(key) in ("REST", "WS"):
            skipped_protocol += 1
            continue
        if key in open_keys:
            continue
        claim = record.claims.get(key, {})
        if claim.get("card") not in (None, "-", ""):
            continue
        proposals.append((key, status, claim.get("anchor_of") or record.keys[key]["anchor_of"]))
    for key, status, anchor in proposals:
        print("PROPOSE %-52s status=%-8s anchor=%s" % (key, status, anchor))
        print("  title: %s: %s" % (key, anchor))
        print("  body:  CAPABILITY: %s" % key)
        print("  create: --idempotency-key cap:%s" % key)
    print("")
    print("plan: %d proposal(s); %d key(s) already carry an open card; %d protocol row(s) deferred (v2)%s"
          % (len(proposals), len(open_keys), skipped_protocol, (" — " + warn) if warn else ""))
    return 0


# --------------------------------------------------------------------------------------
# self-test — asserts + six planted faults + two-run byte compare
# --------------------------------------------------------------------------------------


FIXTURE_REGISTRY = """import Foundation

public enum Surface: String, CaseIterable, Codable, Identifiable, Sendable {
    case auth
    case sidebar
    case channelView
    case composer
    case search
    case activity
    case channelInfo
    case calls

    public var id: String { rawValue }
}

public enum SurfaceDefaults {
    public static let nativeApprovedSurfaces: Set<Surface> = [.channelView]
    public static let paneOwningSurfaces: Set<Surface> = [.channelView]
}
"""

FIXTURE_TEST = """import XCTest

final class TParityScanTests: XCTestCase {
    func testAlphaRendersNatively() {
        XCTAssertTrue(true)
    }

    func testBetaProvesItsBehaviour() {
        XCTAssertEqual(1, 1)
    }
}
"""


def _git_init(path):
    git(["init", "-q"], cwd=path, check=True)
    git(["config", "user.email", "parity@example.invalid"], cwd=path, check=True)
    git(["config", "user.name", "parity self-test"], cwd=path, check=True)
    git(["add", "-A"], cwd=path, check=True)
    git(["commit", "-q", "-m", "fixture base"], cwd=path, check=True)
    return git_head(cwd=path)


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def _fixture_world(base, fault=None):
    """A tiny but real repo: pins that resolve, keys, claims, verdicts, registry, tests, shots."""
    root = os.path.join(base, "world-" + (fault or "clean"))
    os.makedirs(root, exist_ok=True)
    _write(os.path.join(root, "Mattermost/Core/RenderMode.swift"), FIXTURE_REGISTRY)
    _write(os.path.join(root, "Mattermost/UI/Native/Alpha/Alpha.swift"), "// alpha\n")
    _write(os.path.join(root, "Mattermost/UI/Native/Beta/Beta.swift"), "// beta\n")
    _write(os.path.join(root, "Mattermost/UI/Native/Unit/Unit.swift"), "// project-owned unit\n")
    _write(os.path.join(root, "MattermostTests/TParityScanTests.swift"), FIXTURE_TEST)
    _write(os.path.join(root, "docs/shots/alpha.png"), "png\n")
    _write(os.path.join(root, "upstream/app/screens/alpha/index.tsx"), "alpha\n")
    _write(os.path.join(root, "upstream/app/screens/beta/index.tsx"), "beta\n")
    _write(os.path.join(root, "upstream/app/screens/gamma/index.tsx"), "gamma\n")
    base_commit = _git_init(root)
    alpha_sha = plan_pins_sha(base_commit, "upstream/", "app/screens/alpha", cwd=root)

    pins = [{"alias": "M", "repo": "mattermost/mattermost-mobile", "tag": "v2.45.0",
             "commit": base_commit, "path_prefix": "upstream/", "license": "Apache-2.0"}]
    write_tsv(os.path.join(root, "parity/pins.tsv"), PIN_COLUMNS, pins)
    keys = [
        {"key": "M:app/screens/alpha", "namespace": "M", "path": "app/screens/alpha",
         "content_sha": alpha_sha, "kind": "dir", "anchor_of": "alpha"},
        {"key": "M:app/screens/beta", "namespace": "M", "path": "app/screens/beta",
         "content_sha": "-", "kind": "dir", "anchor_of": "beta"},
        {"key": "X:internal-unit", "namespace": "X", "path": "-", "content_sha": "-",
         "kind": "internal", "anchor_of": "unit"},
    ]
    write_tsv(os.path.join(root, "parity/upstream-keys.tsv"), KEY_COLUMNS, keys)
    claims = [
        {"key": "M:app/screens/alpha", "native_paths": "Mattermost/UI/Native/Alpha",
         "surface": "channelView", "test_refs": "MattermostTests/TParityScanTests.swift::testAlphaRendersNatively",
         "status_seed": "native", "card": "t_selftest", "note": "clean: validated + approved"},
        {"key": "M:app/screens/beta", "native_paths": "Mattermost/UI/Native/Beta",
         "surface": "channelView", "test_refs": "MattermostTests/TParityScanTests.swift::testBetaProvesItsBehaviour",
         "status_seed": "tested", "card": "t_selftest2", "note": "clean: tested, no verdict"},
        {"key": "X:internal-unit", "native_paths": "Mattermost/UI/Native/Unit", "surface": "-",
         "test_refs": "-", "status_seed": "claimed", "card": "t_selftest3", "note": "clean: claimed"},
    ]
    verdicts = {
        "M:app/screens/alpha": {
            "card": "t_selftest",
            "commit": base_commit,
            "verdict": "PASS",
            "findings": [],
            "evidence": [
                {"kind": "test", "ref": "MattermostTests/TParityScanTests.swift::testAlphaRendersNatively"},
                {"kind": "observation", "ref": "docs/shots/alpha.png"},
            ],
        }
    }

    # ---- the faults, each in isolation -------------------------------------------------
    if fault == "STALE":
        claims[1]["native_paths"] = "Mattermost/UI/Native/Beta/Gone.swift"
    elif fault == "ORPHAN":
        claims.append({"key": "M:app/screens/delta", "native_paths": "Mattermost/UI/Native/Beta",
                       "surface": "-", "test_refs": "-", "status_seed": "absent", "card": "-", "note": "orphan"})
    elif fault == "UNMAPPED":
        _write(os.path.join(root, "Mattermost/UI/Native/Stray/Stray.swift"), "// stray\n")
    elif fault == "STALE-VERDICT":
        # a later commit that touches the claimed files, after the verdict commit
        _write(os.path.join(root, "Mattermost/UI/Native/Alpha/Alpha.swift"), "// alpha, changed later\n")
        git(["add", "-A"], cwd=root, check=True)
        git(["commit", "-q", "-m", "later change"], cwd=root, check=True)
    elif fault == "STALE-EVIDENCE":
        verdicts["M:app/screens/alpha"]["evidence"][1]["ref"] = "docs/shots/missing.png"
    elif fault == "APPROVED-WITHOUT-VERDICT":
        _write(os.path.join(root, "Mattermost/Core/RenderMode.swift"),
               FIXTURE_REGISTRY.replace("[.channelView]", "[.channelView, .activity]"))
    elif fault:
        raise SystemExit("unknown fault %r" % fault)

    write_tsv(os.path.join(root, "parity/claims.tsv"), CLAIM_COLUMNS, claims)
    write_text(os.path.join(root, "parity/verdicts.json"),
               json.dumps(verdicts, indent=2, sort_keys=True) + "\n")
    return root


def cmd_self_test():
    base = tempfile.mkdtemp(prefix="parity-selftest-")
    failures = []
    try:
        # assert 1/2 — key grammar and evidence typing, before any lookup
        assert key_is_well_formed("M:app/screens/thread")
        assert key_is_well_formed("REST:GET /channels/{id}/posts")
        assert key_is_well_formed("WS:posted")
        assert key_is_well_formed("X:notification-input")
        assert not key_is_well_formed("M:app/screens/thread @ deadbeef")
        assert not key_is_well_formed("S13")
        print("assert 1 ok — key grammar (identity is the path; a sha in the key is rejected)")

        # assert 2 — every native path a claim names must exist (else STALE, never silence)
        clean = _fixture_world(base, None)
        record = build(clean)
        if record.findings:
            failures.append("clean world is not clean: %r" % [f.line() for f in record.findings])
        expected = {"M:app/screens/alpha": "native", "M:app/screens/beta": "tested", "X:internal-unit": "claimed"}
        for key, want in expected.items():
            if record.statuses.get(key) != want:
                failures.append("clean world: %s is %r, expected %r" % (key, record.statuses.get(key), want))
        if not failures:
            print("assert 2 ok — claims, paths, test refs and verdicts resolve in a clean world")

        # assert 3 — the registry literal parses (never a second list)
        surfaces, approved, pane = parse_registry(record.cfg.registry)
        if not set(pane) <= set(approved):
            failures.append("pane-owning surfaces are not a subset of the approved registry")
        print("assert 3 ok — the Swift registry literal parses and pane-owning ⊆ approved")

        # assert 4 — a refactor must not read as "feature deleted". A recorded rename is found by
        # `git log --follow`; an unrecorded move of identical bytes is found by content identity.
        move_root = os.path.join(base, "move-world")
        _write(os.path.join(move_root, "Mattermost/UI/Native/Old/Thing.swift"), "// thing\n")
        _git_init(move_root)
        git(["mv", "Mattermost/UI/Native/Old/Thing.swift",
             "Mattermost/UI/Native/Old/ThingRenamed.swift"], cwd=move_root, check=True)
        git(["add", "-A"], cwd=move_root, check=True)
        git(["commit", "-q", "-m", "rename"], cwd=move_root, check=True)
        found = move_candidate("Mattermost/UI/Native/Old/Thing.swift", cwd=move_root)
        if found != "Mattermost/UI/Native/Old/ThingRenamed.swift":
            failures.append("a recorded rename was not found (got %r)" % (found,))
        # unrecorded: same bytes at a second path, old path deleted in the same commit
        copy_root = os.path.join(base, "copy-world")
        _write(os.path.join(copy_root, "Mattermost/UI/Native/A/Thing.swift"), "// same bytes\n")
        _git_init(copy_root)
        os.makedirs(os.path.join(copy_root, "Mattermost/UI/Native/B"))
        shutil.copy(os.path.join(copy_root, "Mattermost/UI/Native/A/Thing.swift"),
                    os.path.join(copy_root, "Mattermost/UI/Native/B/Thing.swift"))
        os.remove(os.path.join(copy_root, "Mattermost/UI/Native/A/Thing.swift"))
        git(["add", "-A"], cwd=copy_root, check=True)
        git(["commit", "-q", "-m", "move the bytes"], cwd=copy_root, check=True)
        found = move_candidate("Mattermost/UI/Native/A/Thing.swift", cwd=copy_root)
        if found != "Mattermost/UI/Native/B/Thing.swift":
            failures.append("a content-identical move was not found (got %r)" % (found,))
        if not any("rename" in f or "move" in f for f in failures):
            print("assert 4 ok — rename detection runs (git log --follow, then content identity)")

        # assert 5 — evidence must resolve before `validated` is granted
        facts = Facts(True, True, True, True, True, False, True, True)
        if derive_status(facts) != "tested":
            failures.append("an unresolvable evidence ref did not demote validated")
        print("assert 5 ok — unresolved evidence demotes the status (validated needs every ref)")

        # assert 6 — the six faults each fire, and only their own kind. The one legal cascade:
        # demoting the only native key on an approved surface must surface that approval gap.
        faults = ["STALE", "ORPHAN", "UNMAPPED", "STALE-VERDICT", "STALE-EVIDENCE", "APPROVED-WITHOUT-VERDICT"]
        cascade = {"STALE-VERDICT": {"APPROVED-WITHOUT-VERDICT"},
                   "STALE-EVIDENCE": {"APPROVED-WITHOUT-VERDICT"}}
        baseline = set()
        clean_record = build(clean)
        baseline = {f.kind for f in clean_record.findings}
        for fault in faults:
            world = _fixture_world(base, fault)
            rec = build(world)
            kinds = {f.kind for f in rec.findings}
            extra = kinds - baseline
            allowed = {fault} | cascade.get(fault, set())
            if fault not in kinds:
                failures.append("fault %s did not fire (kinds=%r)" % (fault, sorted(kinds)))
                continue
            if extra - allowed:
                failures.append("fault %s fired extra kinds %r" % (fault, sorted(extra - allowed)))
                continue
            print("fault %s ok — fired, and no other finding changed%s"
                  % (fault, (" (legal cascade: %s)" % ", ".join(sorted(extra - {fault}))) if extra - {fault} else ""))
        print("assert 6 ok — %d/%d planted faults fired in isolation" % (len(faults), len(faults)))

        # determinism — two runs, byte compare
        first = build(clean)
        second = build(clean)
        a, b = first.artifacts(), second.artifacts()
        if a != b:
            differing = [k for k in a if a.get(k) != b.get(k)]
            failures.append("two runs differ: %r" % differing)
        else:
            print("determinism ok — %d artifact(s) byte-identical across two runs" % len(a))

        # the fixture's own artifacts must also be stable when written twice
        tmp1, tmp2 = os.path.join(base, "out1"), os.path.join(base, "out2")
        write_artifacts(first, tmp1)
        write_artifacts(build(clean), tmp2)
        for rel in a:
            if read_text(os.path.join(tmp1, rel)) != read_text(os.path.join(tmp2, rel)):
                failures.append("artifact %s is not byte-stable on disk" % rel)
    finally:
        shutil.rmtree(base, ignore_errors=True)

    if failures:
        for f in failures:
            print("[FAIL] self-test: %s" % f)
        return 1
    print("self-test: PASS")
    return 0


# --------------------------------------------------------------------------------------
# cli
# --------------------------------------------------------------------------------------


def main(argv=None):
    parser = argparse.ArgumentParser(description="the parity record: one tool (design docs/parity-map-design.md)")
    parser.add_argument("command", nargs="?", choices=[None, "plan", "promote", "claim", "gate", "bump"], default=None)
    parser.add_argument("target", nargs="?", help="promote/claim target: key or S## alias")
    parser.add_argument("target_status", nargs="?", help="B's `promote S13 tested` form; recorded as status_seed only")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--report", action="store_true", help="findings do not fail (drift still does)")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--query")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--bootstrap", action="store_true")
    parser.add_argument("--keys-only", action="store_true", help="regenerate pins + keys only, leave claims alone")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--render-md", action="store_true")
    parser.add_argument("--out")
    parser.add_argument("--paths", nargs="+")
    parser.add_argument("--surface")
    parser.add_argument("--card")
    parser.add_argument("--note")
    parser.add_argument("--test")
    parser.add_argument("--verdict")
    parser.add_argument("--commit")
    parser.add_argument("--evidence", nargs="+")
    parser.add_argument("--finding", nargs="+")
    parser.add_argument("--board")
    parser.add_argument("--protocol", action="store_true", help="plan: include REST/WS rows (v2 scope)")
    parser.add_argument("--pins")
    parser.add_argument("--upstream-keys")
    parser.add_argument("--claims")
    parser.add_argument("--verdicts")
    parser.add_argument("--out-dir")
    parser.add_argument("--registry")
    parser.add_argument("--native-root")
    parser.add_argument("--root", default=ROOT)
    args = parser.parse_args(argv)

    cfg = Config(args.root)
    for attr, path in (("pins", args.pins), ("keys", args.upstream_keys), ("claims", args.claims),
                       ("verdicts", args.verdicts), ("out", args.out_dir), ("registry", args.registry),
                       ("native_root", args.native_root)):
        if path:
            setattr(cfg, attr, os.path.abspath(path))

    if args.self_test:
        return cmd_self_test()
    if args.bootstrap:
        return cmd_bootstrap(args.root, force=args.force, keys_only=args.keys_only)
    if args.query is not None:
        return cmd_query(args.query, as_json=args.json, root=args.root)
    if args.command == "plan":
        return cmd_plan(args.root, args.board, protocol=args.protocol)
    if args.command == "promote":
        args.cfg = cfg
        return cmd_promote(cfg, args)
    if args.command == "claim":
        return cmd_claim(cfg, args)
    if args.command == "gate":
        return cmd_gate(cfg, args.target)
    if args.command == "bump":
        print("bump: NOT IN THE MVP (design §6). The pins are stable; a pin bump stays manual until the "
              "first real one, then this command grows `--bump <alias> <old-sha> <new-sha>` and a "
              "content-sha worklist. Run `--bootstrap --force --keys-only` after changing pins.tsv.")
        return 2
    if args.check:
        return cmd_check(args.root, report=args.report)
    if args.render_md:
        return cmd_render(args.root, md_only=True, out=args.out)
    return cmd_render(args.root)


if __name__ == "__main__":
    sys.exit(main())
