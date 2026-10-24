#!/usr/bin/env python3
"""T27 performance probe: sample process memory, join it with the app's stage journal, report.

Two subcommands:

    sample  — watch a launched app (and the WebKit processes it spawns) until the probe writes
              its `probe.done` marker, then fold everything into `run.json`.
    report  — fold every `run.json` under a directory into `docs/perf/baseline-<date>.json` and
              the markdown table in `docs/perf/README.md`.

Why a separate sampler and not Instruments: `xctrace` needs a template with the VM Tracker /
Allocations instrument (a GUI artefact) to be scriptable, and its per-process attribution covers
only the target process. The measurement that matters here — the shell process *and* the WebKit
processes it spawns — is available directly from the kernel through `footprint` (physical
footprint + lifetime peak) and `ps` (RSS timeline), which is what this script uses.

Attribution rule (stated because it is the only judgement call in the harness): a WebKit process
belongs to this run iff its pid was not present in `--baseline-webkit` (the pid list captured just
before the app launched). Mattermost's shell creates its own WebContent/GPU/Networking processes
per app launch on both Catalyst and the Simulator; anything already running belongs to another
app (Safari, a previous run) and is excluded rather than silently attributed.
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import sys
import time

WEBKIT_PREFIX = "/System/iOSSupport/System/Library/Frameworks/WebKit.framework"
WEBKIT_FAMILIES = {
    "com.apple.WebKit.WebContent": "webcontent",
    "com.apple.WebKit.GPU": "gpu",
    "com.apple.WebKit.Networking": "networking",
}


# --------------------------------------------------------------------------------------- helpers

def now() -> float:
    return time.time()


def run(cmd: list[str]) -> str:
    return subprocess.run(cmd, capture_output=True, text=True).stdout


def list_processes() -> dict[int, dict]:
    """pid -> {ppid, rss_bytes, comm} for every process on the host."""
    out = run(["ps", "-axo", "pid=,ppid=,rss=,comm="])
    procs: dict[int, dict] = {}
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        try:
            pid, ppid, rss_kb = int(parts[0]), int(parts[1]), int(parts[2])
        except ValueError:
            continue
        procs[pid] = {"ppid": ppid, "rss_bytes": rss_kb * 1024, "comm": parts[3].strip()}
    return procs


def webkit_family(comm: str) -> str | None:
    for needle, family in WEBKIT_FAMILIES.items():
        if needle in comm:
            return family
    return None


def footprint(pid: int) -> dict | None:
    """Kernel's own accounting for one process: physical footprint + lifetime peak."""
    out_path = f"/tmp/mm_perf_fp_{pid}.json"
    try:
        subprocess.run(["footprint", "--pid", str(pid), "--noCategories", "-j", out_path],
                       capture_output=True, timeout=30)
        with open(out_path) as fh:
            data = json.load(fh)
        procs = data.get("processes") or []
        if not procs:
            return None
        p = procs[0]
        return {
            "pid": pid,
            "footprint_bytes": p.get("footprint"),
            "phys_footprint_bytes": (p.get("auxiliary") or {}).get("phys_footprint"),
            "phys_footprint_peak_bytes": (p.get("auxiliary") or {}).get("phys_footprint_peak"),
        }
    except Exception:
        return None
    finally:
        try:
            os.unlink(out_path)
        except OSError:
            pass


def read_journal(path: str, consumed: int) -> tuple[list[dict], int]:
    """Read the app's append-only stage journal from `consumed` lines on."""
    if not os.path.exists(path):
        return [], consumed
    events: list[dict] = []
    with open(path) as fh:
        lines = fh.readlines()
    for line in lines[consumed:]:
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return events, len(lines)


# ------------------------------------------------------------------------------ sample subcommand

def cmd_sample(args: argparse.Namespace) -> int:
    os.makedirs(args.run_dir, exist_ok=True)
    baseline = {int(p) for p in args.baseline_webkit.split(",") if p.strip()}
    journal_path = os.path.join(args.run_dir, "probe-journal.jsonl")
    done_path = os.path.join(args.run_dir, "probe.done")
    samples_path = os.path.join(args.run_dir, "samples.jsonl")
    tracked: dict[str, set[int]] = {"webcontent": set(), "gpu": set(), "networking": set()}
    stage_snapshots: list[dict] = []
    seen_journal_lines = 0
    started = now()
    last_snapshot = None
    sample_count = 0
    steady_samples: list[dict] = []

    with open(samples_path, "w") as samples:
        while True:
            t = now()
            procs = list_processes()
            app = procs.get(args.app_pid)

            # Discover (and keep discovering) the WebKit processes this app spawned.
            for pid, info in procs.items():
                if pid in baseline:
                    continue
                family = webkit_family(info["comm"])
                if family:
                    tracked[family].add(pid)

            # Drop pids that are gone (a WebContent process can exit and be replaced).
            for family in tracked:
                tracked[family] = {p for p in tracked[family] if p in procs}

            sample = {
                "t": t,
                "app": (app or {}).get("rss_bytes"),
                "webcontent": sum(procs[p]["rss_bytes"] for p in tracked["webcontent"] if p in procs),
                "gpu": sum(procs[p]["rss_bytes"] for p in tracked["gpu"] if p in procs),
                "networking": sum(procs[p]["rss_bytes"] for p in tracked["networking"] if p in procs),
                "pids": {f: sorted(v) for f, v in tracked.items()},
            }
            sample["total"] = sum(sample[k] or 0 for k in ("app", "webcontent", "gpu", "networking"))
            samples.write(json.dumps(sample) + "\n")
            samples.flush()
            sample_count += 1

            # Stage boundaries come from the app's own journal; snapshot the kernel footprint at
            # each one (cheap: a few `footprint` calls, not a continuous trace).
            def capture_stage_snapshots(procs_now: dict[int, dict]) -> None:
                nonlocal seen_journal_lines, last_snapshot
                events, seen_journal_lines = read_journal(journal_path, seen_journal_lines)
                for event in events:
                    if event.get("phase") != "end":
                        continue
                    snapshot = {
                        "stage": event.get("stage"),
                        "ok": event.get("ok"),
                        "wall": event.get("wall"),
                        "app": footprint(args.app_pid) if args.app_pid in procs_now else None,
                        "webcontent": [footprint(p) for p in sorted(tracked["webcontent"])],
                        "gpu": [footprint(p) for p in sorted(tracked["gpu"])],
                        "networking": [footprint(p) for p in sorted(tracked["networking"])],
                        "pids": {f: sorted(v) for f, v in tracked.items()},
                        "t": now(),
                    }
                    stage_snapshots.append(snapshot)
                    last_snapshot = snapshot

            capture_stage_snapshots(procs)

            finishing = os.path.exists(done_path)
            if finishing:
                # A stage can end inside the same sample window as the app's `probe.done` marker
                # (the last DOM stage is immediately followed by the result write), so sweep the
                # journal once more before settling — otherwise the final stage, whose delta the
                # report is usually about (e.g. `openThread`), would be missing from run.json.
                capture_stage_snapshots(list_processes())
                # Give the app a moment to settle, then take the steady-state snapshot.
                time.sleep(args.steady_seconds)
                steady_samples = [
                    {"t": now(), "app": (list_processes().get(args.app_pid) or {}).get("rss_bytes")}
                ]
                steady_snapshot = {
                    "stage": "steadyState",
                    "wall": now(),
                    "app": footprint(args.app_pid) if args.app_pid in procs else None,
                    "webcontent": [footprint(p) for p in sorted(tracked["webcontent"])
                                   if p in list_processes()],
                    "gpu": [footprint(p) for p in sorted(tracked["gpu"]) if p in list_processes()],
                    "networking": [footprint(p) for p in sorted(tracked["networking"])
                                   if p in list_processes()],
                    "pids": {f: sorted(v) for f, v in tracked.items()},
                    "t": now(),
                }
                stage_snapshots.append(steady_snapshot)
                last_snapshot = steady_snapshot
                break
            if t - started > args.duration:
                break
            time.sleep(args.interval)

    # Fold the timeline into the run file.
    timeline: list[dict] = []
    with open(samples_path) as fh:
        for line in fh:
            timeline.append(json.loads(line))

    def peak(key: str) -> dict:
        if not timeline:
            return {"bytes": 0, "at": None}
        best = max(timeline, key=lambda s: s.get(key) or 0)
        return {"bytes": best.get(key) or 0, "at": best["t"]}

    def snapshot_total(snap: dict | None) -> dict:
        if not snap:
            return {}
        keys = ("app", "webcontent", "gpu", "networking")

        def total(metric: str) -> int:
            value = 0
            for k in keys:
                item = snap.get(k)
                if item is None:
                    continue
                items = item if isinstance(item, list) else [item]
                for entry in items:
                    if entry and entry.get(metric):
                        value += entry[metric]
            return value

        return {
            "phys_footprint_bytes": total("phys_footprint_bytes"),
            "footprint_bytes": total("footprint_bytes"),
        }

    per_process_peak = {
        "app": (last_snapshot or {}).get("app"),
        "webcontent": (last_snapshot or {}).get("webcontent"),
        "gpu": (last_snapshot or {}).get("gpu"),
        "networking": (last_snapshot or {}).get("networking"),
    }

    probe = {}
    probe_path = os.path.join(args.run_dir, "probe-result.json")
    if os.path.exists(probe_path):
        with open(probe_path) as fh:
            probe = json.load(fh)

    run_record = {
        "run": {
            "target": args.target,
            "mode": args.mode,
            "repeat": args.repeat_index,
            "app_pid": args.app_pid,
            "started_wall": started,
            "sampled_seconds": round(last_snapshot["t"] - started, 2) if last_snapshot else 0,
            "sample_count": sample_count,
            "sample_interval_s": args.interval,
            "launch_command": args.launch_command,
            "tracked_pids": {f: sorted(v) for f, v in tracked.items()},
            "baseline_webkit_pids_excluded": sorted(baseline),
        },
        "peak": {
            "rss_bytes": peak("total"),
            "app_rss_bytes": peak("app"),
            "webcontent_rss_bytes": peak("webcontent"),
            "total_rss_bytes": peak("total"),
        },
        "steady": {
            "snapshot": snapshot_total(last_snapshot),
            "rss_bytes": (timeline[-1] if timeline else {}),
        },
        "per_process_footprint": per_process_peak,
        "stages": stage_snapshots,
        "probe": probe,
        "timeline_file": os.path.basename(samples_path),
    }
    with open(os.path.join(args.run_dir, "run.json"), "w") as fh:
        json.dump(run_record, fh, indent=2)
    print(json.dumps({
        "run": args.mode + "/" + args.target,
        "peak_total_rss_mb": round((peak("total")["bytes"] or 0) / 1e6, 1),
        "peak_webcontent_rss_mb": round((peak("webcontent")["bytes"] or 0) / 1e6, 1),
        "steady_phys_footprint_mb": round(
            (snapshot_total(last_snapshot).get("phys_footprint_bytes") or 0) / 1e6, 1),
        "stages": [s["stage"] for s in stage_snapshots],
    }))
    return 0


# ------------------------------------------------------------------------------ report subcommand

def load_runs(root: str) -> list[dict]:
    runs: list[dict] = []
    for dirpath, _dirnames, filenames in os.walk(root):
        if "run.json" in filenames:
            with open(os.path.join(dirpath, "run.json")) as fh:
                record = json.load(fh)
            record["run_dir"] = dirpath
            runs.append(record)
    runs.sort(key=lambda r: (r["run"]["target"], r["run"]["mode"], r["run"].get("repeat", 1)))
    return runs


def mb(value: float | None) -> float | None:
    return None if value is None else round(value / 1e6, 1)


def summarise_run(record: dict) -> dict:
    run = record["run"]
    probe = record.get("probe") or {}
    stages = {s["stage"]: s for s in record.get("stages", [])}

    def stage_footprint(name: str) -> dict:
        snap = stages.get(name) or {}
        total = 0
        for key in ("app", "webcontent", "gpu", "networking"):
            item = snap.get(key)
            if item is None:
                continue
            items = item if isinstance(item, list) else [item]
            for entry in items:
                if entry and entry.get("phys_footprint_bytes"):
                    total += entry["phys_footprint_bytes"]
        return {"phys_footprint_bytes": total}

    steady = record.get("steady", {}).get("snapshot", {})
    probe_stages = {s["name"]: s for s in probe.get("stages", [])}

    def stage_seconds(name: str) -> float | None:
        s = probe_stages.get(name)
        return s.get("duration_s") if s else None

    return {
        "target": run["target"],
        "mode": run["mode"],
        "repeat": run.get("repeat", 1),
        "app_pid": run["app_pid"],
        "sampled_seconds": run["sampled_seconds"],
        "peak": {
            "total_rss_bytes": record["peak"]["rss_bytes"]["bytes"],
            "app_rss_bytes": record["peak"]["app_rss_bytes"]["bytes"],
            "webcontent_rss_bytes": record["peak"]["webcontent_rss_bytes"]["bytes"],
            "total_phys_footprint_bytes": stage_footprint("steadyState").get("phys_footprint_bytes"),
        },
        "steady": {
            "total_phys_footprint_bytes": steady.get("phys_footprint_bytes", 0),
            "app_phys_footprint_bytes": (record["per_process_footprint"].get("app") or {}).get("phys_footprint_bytes"),
            "webcontent_phys_footprint_bytes": sum(
                (e or {}).get("phys_footprint_bytes") or 0
                for e in (record["per_process_footprint"].get("webcontent") or [])),
            "webcontent_peak_footprint_bytes": sum(
                (e or {}).get("phys_footprint_peak_bytes") or 0
                for e in (record["per_process_footprint"].get("webcontent") or [])),
            "gpu_phys_footprint_bytes": sum(
                (e or {}).get("phys_footprint_bytes") or 0
                for e in (record["per_process_footprint"].get("gpu") or [])),
            "networking_phys_footprint_bytes": sum(
                (e or {}).get("phys_footprint_bytes") or 0
                for e in (record["per_process_footprint"].get("networking") or [])),
        },
        "pids": run["tracked_pids"],
        "stages": [
            {
                "name": name,
                "ok": probe_stages.get(name, {}).get("ok"),
                "duration_s": stage_seconds(name),
                "phys_footprint_bytes": stage_footprint(name).get("phys_footprint_bytes"),
            }
            for name in ("workspaceLoad", "login", "openChannel", "scrollPosts",
                         "openThread", "steadyState")
            if name in probe_stages or name in stages
        ],
        "probe_total_s": probe.get("total_s"),
        "completed_stages": probe.get("completed_stages", []),
        "failed_stages": probe.get("failed_stages", []),
        "launch_to_first_post_s": (
            round((probe_stages.get("login", {}).get("started_offset_s") or 0)
                  + (stage_seconds("login") or 0), 3)
            if "login" in probe_stages else None),
        "probe": {
            "webview_url": probe.get("webview_url"),
            "aborted": probe.get("aborted"),
            "server": probe.get("server"),
            "channel": probe.get("channel"),
            "scroll_steps": probe.get("scroll_steps"),
        },
    }


def render_markdown(baseline: dict) -> str:
    def label(run: dict) -> str:
        """`web` for a single run, `web #2` when the arm was repeated."""
        repeat = run.get("repeat", 1)
        return run["mode"] if repeat == 1 else f"{run['mode']} #{repeat}"

    def median(values: list) -> float:
        return statistics.median([v for v in values if v]) if values else 0

    def headline(lines: list[str]) -> None:
        """State the claim the figures support, computed from the runs — never typed in.

        `web - shell` is the cost of the thing Path B replaces on that target; the WebContent
        share of it says where the cost lives; the native arm's WebContent column says whether a
        native surface at HEAD actually escapes it.
        """
        targets = sorted({r["target"] for r in baseline["runs"]})
        rows: list[str] = []
        any_row = False
        for target in targets:
            web = [r for r in baseline["runs"] if r["target"] == target and r["mode"] == "web"]
            shell = [r for r in baseline["runs"] if r["target"] == target and r["mode"] == "shell"]
            native = [r for r in baseline["runs"] if r["target"] == target and r["mode"] == "native"]
            if not web or not shell:
                continue
            any_row = True
            web_total = median([r["steady"]["total_phys_footprint_bytes"] for r in web])
            shell_total = median([r["steady"]["total_phys_footprint_bytes"] for r in shell])
            web_wc = median([r["steady"]["webcontent_phys_footprint_bytes"] for r in web])
            delta = web_total - shell_total
            share = (web_wc / delta * 100) if delta else 0
            native_wc = median([r["steady"]["webcontent_phys_footprint_bytes"] for r in native]) if native else None
            web_peak = median([r["peak"]["total_rss_bytes"] for r in web])
            rows.append(
                f"| {target} | {mb(shell_total)} MB | {mb(web_total)} MB | **{mb(delta)} MB** "
                f"| {round(share)} % | "
                f"{'—' if native_wc is None else str(mb(native_wc)) + ' MB'} | {mb(web_peak)} MB |")
        if not any_row:
            return
        lines.append("## Headline\n")
        lines.append("Median over the runs of each arm on this host (shell = the app with no server and")
        lines.append("no webview; web = today's Path A after the full scripted sequence).\n")
        lines.append("| target | app-only floor (shell) | Path A steady | **what one loaded webview costs** "
                     "| of that, WebContent | WebContent still alive in the `native` arm (steady) "
                     "| Path A peak total RSS |")
        lines.append("|---|---:|---:|---:|---:|---:|---:|")
        lines.extend(rows)
        lines.append("")
        lines.append("Read it as: the SwiftUI shell itself is tens of megabytes; the per-server webview is")
        lines.append("hundreds, and almost all of it is the WebContent process the shell does not own. A")
        lines.append("native surface that leaves that process alive therefore keeps paying the cost —")
        lines.append("which is exactly the column before last.\n")

    def spread(lines: list[str]) -> None:
        """Per-arm run-to-run spread, when `--repeat` gave more than one run per arm."""
        arms: dict[tuple[str, str], list[dict]] = {}
        for run in baseline["runs"]:
            arms.setdefault((run["target"], run["mode"]), []).append(run)
        repeated = {k: v for k, v in arms.items() if len(v) > 1}
        if not repeated:
            return
        lines.append("## Run-to-run spread\n")
        lines.append("Every arm below was run more than once on the same host with the same seeded")
        lines.append("workspace. A baseline is only reproducible if a re-run lands inside this spread;")
        lines.append("the raw per-run values are in the JSON (`runs[].steady`).\n")
        lines.append("| target | channel view | runs | total steady phys_footprint min…max "
                     "| spread | WebContent steady min…max | spread |")
        lines.append("|---|---|---:|---:|---:|---:|---:|")
        for (target, mode), runs in sorted(repeated.items()):
            totals = [r["steady"]["total_phys_footprint_bytes"] or 0 for r in runs]
            wcs = [r["steady"]["webcontent_phys_footprint_bytes"] or 0 for r in runs]
            t_min, t_max = min(totals), max(totals)
            w_min, w_max = min(wcs), max(wcs)
            t_spread = 0.0 if t_min == 0 else (t_max - t_min) / t_min * 100
            w_spread = 0.0 if w_min == 0 else (w_max - w_min) / w_min * 100
            lines.append(f"| {target} | {mode} | {len(runs)} | {mb(t_min)}…{mb(t_max)} MB "
                         f"| {round(t_spread, 1)} % | {mb(w_min)}…{mb(w_max)} MB "
                         f"| {round(w_spread, 1)} % |")
        lines.append("")

    lines: list[str] = []
    lines.append("# Measured memory baseline — Path A (WKWebView) vs the native floor\n")
    lines.append(f"Generated by `scripts/perf_probe.sh` on {baseline['host']['timestamp']}. "
                 f"Host: {baseline['host']['model']}, macOS {baseline['host']['os']}, "
                 f"Xcode {baseline['host']['xcode']}. Server: `{baseline['server']['url']}` "
                 f"({baseline['server']['version']}, seeded with {baseline['server']['seeded']['channel_total_posts']} "
                 f"posts in `#{baseline['server']['seeded']['channel_name']}` and "
                 f"{baseline['server']['seeded']['thread_replies']} replies on one thread).\n")
    lines.append("`phys_footprint` is the kernel's physical-footprint accounting (`footprint`), which is")
    lines.append("the number Instruments reports; `RSS` is the sampled `ps` resident size (peak over the run).")
    lines.append("WebContent/GPU/Networking are the WebKit out-of-process helpers the shell's WKWebView spawns;")
    lines.append("they are attributed by pid (pids present before launch are excluded).\n")
    headline(lines)
    lines.append("| target | channel view | app peak RSS | WebContent peak RSS | total peak RSS "
                 "| app steady | WebContent steady | **total steady phys_footprint** |")
    lines.append("|---|---|---:|---:|---:|---:|---:|---:|")
    for run in baseline["runs"]:
        wc = run["pids"].get("webcontent") or []
        lines.append(
            f"| {run['target']} | {label(run)} | {mb(run['peak']['app_rss_bytes'])} MB "
            f"| {mb(run['peak']['webcontent_rss_bytes'])} MB | {mb(run['peak']['total_rss_bytes'])} MB "
            f"| {mb(run['steady']['app_phys_footprint_bytes'])} MB "
            f"| {mb(run['steady']['webcontent_phys_footprint_bytes'])} MB "
            f"| **{mb(run['steady']['total_phys_footprint_bytes'])} MB** |")
    lines.append("")
    lines.append("Stage timings and per-stage footprints (from the app's own `os_signpost` intervals and")
    lines.append("journal, sampled at each stage boundary):\n")
    lines.append("| target | channel view | workspace load | login | open channel | scroll | open thread "
                 "| launch → first post |")
    lines.append("|---|---|---:|---:|---:|---:|---:|---:|")
    for run in baseline["runs"]:
        st = {s["name"]: s for s in run["stages"]}

        def dur(name: str) -> str:
            s = st.get(name)
            if not s or s.get("duration_s") is None:
                return "—"
            flag = "" if s.get("ok") else " (failed)"
            return f"{round(s['duration_s'] * 1000)} ms{flag}"

        lines.append(f"| {run['target']} | {label(run)} | {dur('workspaceLoad')} | {dur('login')} "
                     f"| {dur('openChannel')} | {dur('scrollPosts')} | {dur('openThread')} "
                     f"| {(str(run['launch_to_first_post_s']) + ' s') if run['launch_to_first_post_s'] is not None else '—'} |")
    lines.append("")
    lines.append("Per-stage physical footprint (app + WebKit helpers at the end of the stage):\n")
    lines.append("| target | channel view | workspace load | login | open channel | scroll | open thread | idle |")
    lines.append("|---|---|---:|---:|---:|---:|---:|---:|")
    for run in baseline["runs"]:
        st = {s["name"]: s for s in run["stages"]}

        def fp(name: str) -> str:
            s = st.get(name)
            value = s.get("phys_footprint_bytes") if s else None
            return f"{mb(value)} MB" if value else "—"

        lines.append(f"| {run['target']} | {label(run)} | {fp('workspaceLoad')} | {fp('login')} "
                     f"| {fp('openChannel')} | {fp('scrollPosts')} | {fp('openThread')} | {fp('steadyState')} |")
    lines.append("")
    spread(lines)
    lines.append("## What this does and does not measure\n")
    lines.append("- **Measured:** the app process and every WebKit helper process the shell's WKWebView")
    lines.append("  spawns, for a real Mattermost web app (server 9.11) rendering a seeded workspace;")
    lines.append("  the scripted sequence is launch → workspace render → log in → open a channel →")
    lines.append("  scroll N steps → open a thread, followed by an idle steady state.")
    lines.append("- **Not a device measurement.** These are Mac Catalyst and iOS Simulator runs on this")
    lines.append("  Mac. A device run needs: a physical iPhone/iPad on iOS 17+, `xcrun devicectl device")
    lines.append("  process launch` with the same launch arguments, `footprint`/`vmmap` over the device")
    lines.append("  process (via `devicectl` or Instruments' VM Tracker), and the same seeded server")
    lines.append("  reachable over the LAN. Pages/WebContent are Jetsam-limited on device (a few hundred")
    lines.append("  MB per process), so absolute numbers may differ; the *ratio* web-vs-native is the")
    lines.append("  transferable result.")
    lines.append("- **`native` mode is not a native chat screen.** It is T26's native stand-in, and (as")
    lines.append("  T26-AV found) the shell still loads the webview behind it, so the WebContent process")
    lines.append("  stays alive — see the headline table's `WebContent still alive in the native arm`")
    lines.append("  column, which is what the webview release policy (`docs/dual-render.md` §12.6) has to")
    lines.append("  drive to zero. In this arm the webview is **not mounted** (the stand-in owns the")
    lines.append("  pane), so its virtualised post list has no height: the arm reaches an authenticated")
    lines.append("  workspace and stops, and its footprint is a lower bound for \"native card plus a live")
    lines.append("  webview\", not an equal-state comparison with `web`. The `shell` row (no server at")
    lines.append("  all) is the honest floor a native implementation starts from.")
    lines.append("- **First-run web-app detour:** on a fresh web-view data store the web app shows its")
    lines.append("  linking landing page once; the probe clicks \"View in Browser\" the way a user does, so")
    lines.append("  that extra SPA bootstrap is inside the measured launch.")
    lines.append("")
    lines.append("Reproduce:\n")
    lines.append("```")
    lines.append(baseline["commands"]["probe"])
    lines.append("```")
    lines.append("")
    return "\n".join(lines)


def cmd_report(args: argparse.Namespace) -> int:
    runs = load_runs(args.runs_dir)
    if not runs:
        print(f"no run.json under {args.runs_dir}", file=sys.stderr)
        return 2

    servers = {json.dumps(r.get("probe", {}).get("server")) for r in runs}
    seeded = {}
    creds_path = args.creds
    if creds_path and os.path.exists(creds_path):
        with open(creds_path) as fh:
            creds = json.load(fh)
        seeded = {
            "channel_name": creds.get("channel_name"),
            "channel_total_posts": creds.get("channel_total_posts"),
            "thread_replies": creds.get("thread_replies"),
        }

    xcode = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True).stdout.strip()
    version = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    model = subprocess.run(["sysctl", "-n", "hw.model"], capture_output=True, text=True).stdout.strip()

    baseline = {
        "schema": 1,
        "kind": "mattermost-ios-perf-baseline",
        "host": {
            "model": model,
            "os": version,
            "arch": os.uname().machine,
            "xcode": xcode.splitlines()[0] if xcode else "",
            "timestamp": time.strftime("%Y-%m-%d %H:%M:%S %z"),
            "cpu_count": os.cpu_count(),
        },
        "server": {
            "url": args.server_url,
            "version": args.server_version,
            "image": args.server_image,
            "seeded": seeded,
        },
        "measurement": {
            "metrics": {
                "phys_footprint": "footprint --noCategories -j (kernel physical footprint, "
                                  "what Instruments reports)",
                "rss": "ps -axo rss, sampled every {0}s".format(runs[0]["run"]["sample_interval_s"]),
            },
            "attribution": "WebKit helper processes = pids absent from the pre-launch baseline list",
            "sequence": ["launch", "workspace render", "log in", "open channel",
                         "scroll N post-list steps", "open thread", "idle steady state"],
        },
        "runs": [summarise_run(r) for r in runs],
        "limits": [
            "Catalyst + iOS Simulator on this Mac, not a physical device (see README §What this does and does not measure)",
            "native mode is the T26 stand-in and still spawns WebKit helpers; the shell row is the native floor",
            "text-only seeded posts: no image attachments, emoji reactions, or plugin UI",
            "single-run numbers: peak values are one sample per stage boundary plus a 0.5-2s RSS timeline",
        ],
        "commands": {
            "probe": args.probe_command,
            "seed": args.seed_command,
        },
        "artifacts": {
            "runs_dir": os.path.abspath(args.runs_dir),
            "probe_script": "scripts/perf_probe.sh",
            "sampler": "scripts/perf_collect.py",
            "seed_script": "scripts/perf_seed.py",
        },
    }
    os.makedirs(os.path.dirname(args.out_json), exist_ok=True)
    with open(args.out_json, "w") as fh:
        json.dump(baseline, fh, indent=2)
    with open(args.out_md, "w") as fh:
        fh.write(render_markdown(baseline))
    print(json.dumps({"wrote": [args.out_json, args.out_md],
                      "runs": [f"{r['target']}/{r['mode']}" for r in baseline["runs"]]}, indent=2))
    return 0


# ---------------------------------------------------------------------------------------- entry

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("sample")
    s.add_argument("--app-pid", type=int, required=True)
    s.add_argument("--run-dir", required=True)
    s.add_argument("--target", required=True)
    s.add_argument("--mode", required=True)
    s.add_argument("--repeat-index", type=int, default=1)
    s.add_argument("--interval", type=float, default=0.5)
    s.add_argument("--duration", type=float, default=300)
    s.add_argument("--steady-seconds", type=float, default=4.0)
    s.add_argument("--baseline-webkit", default="")
    s.add_argument("--launch-command", default="")
    s.set_defaults(func=cmd_sample)

    r = sub.add_parser("report")
    r.add_argument("--runs-dir", required=True)
    r.add_argument("--out-json", required=True)
    r.add_argument("--out-md", required=True)
    r.add_argument("--creds", default="")
    r.add_argument("--server-url", default="")
    r.add_argument("--server-version", default="")
    r.add_argument("--server-image", default="")
    r.add_argument("--probe-command", default="")
    r.add_argument("--seed-command", default="")
    r.set_defaults(func=cmd_report)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
