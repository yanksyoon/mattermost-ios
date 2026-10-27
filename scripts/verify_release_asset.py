#!/usr/bin/env python3
"""Verify the *uploaded* release, not the local zip that was about to be uploaded.

The package job already checks its own zip (bundle id, version, `codesign --verify`,
`unzip -l` contents). None of that proves the asset reached the release: `gh release
upload` can fail, leave a zero-byte asset, attach the zip of a *different* commit, or
upload to a draft nobody can download, and the job would still be green with a release
that has source archives only. That is gap G3 on board card t_4ae44452.

Three assertions, all against the GitHub API through `gh`:

  1. the release exists, is published (not a draft), and its tag is the one we uploaded to
  2. its asset list contains <asset> with the exact byte size of the local zip (and > 0)
  3. the tag's commit is the commit the zip was built from, so the download and the notes
     describe the same tree

Usage
  python3 scripts/verify_release_asset.py --repo o/r --tag v0.6.0 --sha <40hex> \\
      --asset Mattermost-macOS-v0.6.0.zip --size 13402755
  python3 scripts/verify_release_asset.py --self-test

Exit: 0 every assertion holds, 1 otherwise (including "could not ask": a check that did
not run is not a pass).
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile

DRAFT_OK = False


class VerifyError(Exception):
    """A check could not be evaluated. Treated as failure, never as success."""


def run_gh(gh: str, args: list[str]) -> str:
    r = subprocess.run([gh, *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise VerifyError(f"`gh {' '.join(args)}` failed ({r.returncode}): "
                          f"{(r.stderr or r.stdout).strip()[:400]}")
    return r.stdout


def gh_json(gh: str, args: list[str]):
    out = run_gh(gh, args)
    try:
        return json.loads(out)
    except json.JSONDecodeError as exc:
        raise VerifyError(f"`gh {' '.join(args)}` did not return JSON: {exc}") from exc


def tag_commit(gh: str, repo: str, tag: str) -> str:
    """Resolve the commit a tag points at, dereferencing an annotated tag if present."""
    ref = gh_json(gh, ["api", f"repos/{repo}/git/ref/tags/{tag}"])
    obj = ref.get("object") or {}
    if obj.get("type") == "tag":
        annotated = gh_json(gh, ["api", obj["url"]])
        return str((annotated.get("object") or {}).get("sha", ""))
    return str(obj.get("sha", ""))


def verify(gh: str, repo: str, tag: str, sha: str, asset: str, size: int) -> list[tuple[str, bool, str]]:
    results: list[tuple[str, bool, str]] = []

    # 1. the release itself
    try:
        rel = gh_json(gh, ["release", "view", tag, "--repo", repo,
                           "--json", "tagName,isDraft,assets"])
        drained = False
        if rel.get("tagName") != tag:
            results.append(("RELEASE", False, f"tagName is {rel.get('tagName')!r}, expected {tag!r}"))
        elif rel.get("isDraft") is True and not DRAFT_OK:
            results.append(("RELEASE", False, "the release is a draft: nobody can download it"))
        else:
            state = "draft" if rel.get("isDraft") else "published"
            results.append(("RELEASE", True, f"{tag} is {state}"))

        # 2. the asset
        assets = rel.get("assets") or []
        match = [a for a in assets if a.get("name") == asset]
        sizes = ", ".join(f"{a.get('name')}={a.get('size')}" for a in assets) or "no assets"
        if not match:
            results.append(("ASSET", False, f"{asset} is not on the release ({sizes})"))
        else:
            got = int(match[0].get("size") or 0)
            if got == 0:
                results.append(("ASSET", False, f"{asset} is listed with 0 bytes"))
            elif got != size:
                results.append(("ASSET", False,
                                f"{asset} is {got} bytes on the release, {size} locally "
                                f"(truncated or a different build)"))
            else:
                results.append(("ASSET", True, f"{asset} {got} bytes matches the built zip"))
        del drained
    except VerifyError as exc:
        results.append(("RELEASE", False, str(exc)))
        results.append(("ASSET", False, "not evaluated (the release could not be read)"))

    # 3. the tag points at the built commit
    try:
        got_sha = tag_commit(gh, repo, tag)
        if got_sha == sha:
            results.append(("TAG COMMIT", True, f"{tag} -> {sha[:8]} (the built commit)"))
        elif not got_sha:
            results.append(("TAG COMMIT", False, f"could not resolve {tag} to a commit"))
        else:
            results.append(("TAG COMMIT", False,
                            f"{tag} -> {got_sha[:8]}, built {sha[:8]} "
                            f"(the asset is not the commit the release claims)"))
    except VerifyError as exc:
        results.append(("TAG COMMIT", False, str(exc)))

    return results


def emit(results: list[tuple[str, bool, str]], tag: str, asset: str) -> int:
    print(f"verify-release-asset: tag={tag} asset={asset}")
    failed = 0
    for name, ok, detail in results:
        print(f"  [{'PASS' if ok else 'FAIL'}] {name:<10} {detail}")
        if not ok:
            failed += 1
    if failed:
        print(f"\nVERIFY: FAIL ({failed} check(s)) — the release does not match what this job built.")
        return 1
    print("\nVERIFY: PASS — the release carries this job's asset, at this job's commit.")
    return 0


# ---------------------------------------------------------------------------------
# self-test: a stub `gh` modelling the API, one mode per way the upload can be wrong
# ---------------------------------------------------------------------------------
STUB = r'''#!/usr/bin/env python3
import json, os, sys
mode = os.environ.get("STUB_MODE", "ok")
args = sys.argv[1:]
built = os.environ.get("STUB_SHA", "")
tag = os.environ.get("STUB_TAG", "v0.6.0")
asset = os.environ.get("STUB_ASSET", "Mattermost-macOS-v0.6.0.zip")
size = int(os.environ.get("STUB_SIZE", "13402755"))

if args[:2] == ["release", "view"]:
    if mode == "gh_down":
        print("error: HTTP 503", file=sys.stderr); sys.exit(1)
    assets = []
    if mode != "missing_asset":
        assets.append({"name": asset, "size": 0 if mode == "zero_asset"
                       else (size - 1 if mode == "size_mismatch" else size)})
    if mode == "extra_asset":
        assets.append({"name": "notes.txt", "size": 12})
    print(json.dumps({"tagName": tag, "isDraft": mode == "draft", "assets": assets}))
    sys.exit(0)

if args[:1] == ["api"] and len(args) == 2:
    url = args[1]
    if mode == "tag_down":
        print("error: HTTP 404", file=sys.stderr); sys.exit(1)
    if url.endswith("/git/ref/tags/" + tag):
        target = "0" * 40 if mode == "wrong_commit" else built
        if mode == "annotated":
            print(json.dumps({"object": {"type": "tag", "sha": "1" * 40,
                                         "url": "https://api.github.com/repos/o/r/git/tags/abc"}}))
        else:
            print(json.dumps({"object": {"type": "commit", "sha": target}}))
        sys.exit(0)
    if "/git/tags/" in url:
        print(json.dumps({"object": {"sha": built}}))
        sys.exit(0)
    print("error: unexpected url " + url, file=sys.stderr); sys.exit(1)

print("error: unexpected argv " + " ".join(args), file=sys.stderr); sys.exit(1)
'''


def self_test() -> int:
    failures = 0
    checks = 0
    sha = "7685cd002479cda1ff2023ea9d50b30f1a709646"
    tag = "v0.6.0"
    asset = "Mattermost-macOS-v0.6.0.zip"
    size = 13402755

    def expect(desc: str, got, want) -> None:
        nonlocal failures, checks
        checks += 1
        if got == want:
            print(f"  [PASS] {desc}")
        else:
            failures += 1
            print(f"  [FAIL] {desc}: got {got!r}, want {want!r}")

    print("verify_release_asset self-test\n")
    with tempfile.TemporaryDirectory() as tmp:
        stub = os.path.join(tmp, "gh")
        with open(stub, "w", encoding="utf-8") as fh:
            fh.write(STUB)
        os.chmod(stub, 0o755)

        def case(mode: str):
            os.environ["STUB_MODE"] = mode
            os.environ.update({"STUB_SHA": sha, "STUB_TAG": tag, "STUB_ASSET": asset,
                               "STUB_SIZE": str(size)})
            return emit(verify(stub, "o/r", tag, sha, asset, size), tag, asset)

        print("== V1 a correct upload passes ==")
        expect("V1 exit 0", case("ok"), 0)

        print("\n== V2 the asset never reached the release (source archives only) ==")
        expect("V2 exit 1", case("missing_asset"), 1)

        print("\n== V3 a zero-byte asset ==")
        expect("V3 exit 1", case("zero_asset"), 1)

        print("\n== V4 the asset is a different/truncated build ==")
        expect("V4 exit 1", case("size_mismatch"), 1)

        print("\n== V5 the tag points at another commit ==")
        expect("V5 exit 1", case("wrong_commit"), 1)

        print("\n== V6 the release is an undownloadable draft ==")
        expect("V6 exit 1", case("draft"), 1)

        print("\n== V7 gh is down: not a pass ==")
        expect("V7 exit 1", case("gh_down"), 1)
        print("\n== V8 the tag ref cannot be read: not a pass ==")
        expect("V8 exit 1", case("tag_down"), 1)

        print("\n== V9 an extra asset does not confuse the check ==")
        expect("V9 exit 0", case("extra_asset"), 0)

        print("\n== V10 an annotated tag is dereferenced to its commit ==")
        expect("V10 exit 0", case("annotated"), 0)

        print("\n== V11 the negative control: the old check (no assertion) would pass ==")
        # The old step only *printed* the asset list; nothing compared it to anything.
        res = verify(stub, "o/r", tag, sha, asset, size)
        os.environ["STUB_MODE"] = "missing_asset"
        res_bad = verify(stub, "o/r", tag, sha, asset, size)
        expect("V11 good upload has 3 passing checks", [ok for _, ok, _ in res], [True, True, True])
        expect("V11 a release with no asset fails", any(not ok for _, ok, _ in res_bad), True)

    print("\n" + (f"SELF-TEST: PASS ({checks} checks, 11 cases)"
                  if failures == 0 else f"SELF-TEST: FAIL {failures} of {checks} checks"))
    return 0 if failures == 0 else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", help="OWNER/NAME")
    ap.add_argument("--tag")
    ap.add_argument("--sha", help="the commit the zip was built from")
    ap.add_argument("--asset", help="asset file name on the release")
    ap.add_argument("--size", type=int, help="byte size of the local zip")
    ap.add_argument("--gh", default=os.environ.get("GH_BIN", "gh"))
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    missing = [n for n, v in (("--repo", args.repo), ("--tag", args.tag), ("--sha", args.sha),
                              ("--asset", args.asset), ("--size", args.size)) if not v]
    if missing:
        print(f"::error::verify_release_asset is missing {', '.join(missing)}", file=sys.stderr)
        return 1
    try:
        return emit(verify(args.gh, args.repo, args.tag, args.sha, args.asset, args.size),
                    args.tag, args.asset)
    except VerifyError as exc:
        print(f"VERIFY: FAIL — {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
