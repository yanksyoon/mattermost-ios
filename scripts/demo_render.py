#!/usr/bin/env python3
"""Cut the raw simulator recording into the README demo artefacts (T74).

Input is one continuous `xcrun simctl io <udid> recordVideo` take plus the xcodebuild log
that ran `MattermostUITests/TDemoCaptureUITests`. The test prints

    DEMO-BEAT <name> 2026-11-09T17:41:02.418Z

on stdout at each story beat, on the host clock, and `scripts/demo_capture.sh` passes the
instant recording started. That is enough to cut the take without scene detection or a
human scrubbing frames: `start = launch - pad_before`, `end = back + pad_after`.

Outputs (into --out-dir):
    <slug>.mp4      the trimmed source, no audio track, full device resolution
    <slug>.gif      the embeddable one, <= 8 MB, 12-15 fps, <= 1200 px wide
    poster.png      a still from the "channel" beat (only when --poster-name is given)

The GIF encoder is ffmpeg's two-pass palette path with a diff-mode palette; the width is
stepped down automatically until the file fits the README's 8 MB budget, and the chosen
setting is printed so a re-shot demo is reproducible.

Usage:
    python3 scripts/demo_render.py --mov build/demo/raw-light.mov \
        --log build/logs/demo-capture-light.log --record-start 1794218000.25 \
        --out-dir docs/media/demo --slug native-demo --poster-name poster.png
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import shutil
import subprocess
import sys

MAX_GIF_BYTES = 8 * 1024 * 1024
MIN_SECONDS, MAX_SECONDS = 15.0, 25.0
GIF_FPS_CHOICES = (13, 12)
GIF_WIDTH_CHOICES = (640, 600, 560, 520, 480, 440)
PALETTE_COLOURS = 128


def _resolve_tools() -> tuple[str, str]:
    """An ffmpeg that actually has libx264, and its matching ffprobe.

    Measured on the build host 2026-11-10: `/usr/local/bin/ffmpeg` is a 2022 build with no
    libx264 (`-c:v libx264` -> "Unrecognized option 'preset'"), and it sorts before
    Homebrew's 8.0.1 in PATH. Silently falling back to `h264_videotoolbox` would change the
    encode settings under the caller, so pick the encoder explicitly instead.
    """
    wanted = [os.environ.get("DEMO_FFMPEG", ""), "/opt/homebrew/bin/ffmpeg",
              shutil.which("ffmpeg") or ""]
    for candidate in wanted:
        if not candidate or not os.path.exists(candidate):
            continue
        try:
            out = subprocess.run([candidate, "-hide_banner", "-encoders"],
                                 capture_output=True, text=True, timeout=20)
        except (OSError, subprocess.SubprocessError):
            continue
        if "libx264" in out.stdout:
            probe = os.path.join(os.path.dirname(candidate), "ffprobe")
            return candidate, probe if os.path.exists(probe) else (shutil.which("ffprobe") or "ffprobe")
    return shutil.which("ffmpeg") or "ffmpeg", shutil.which("ffprobe") or "ffprobe"


FFMPEG, FFPROBE = _resolve_tools()


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def beats_from_log(path: str) -> dict[str, float]:
    """DEMO-BEAT lines -> {name: epoch seconds}. The test writes ISO-8601 with millis."""
    beats: dict[str, float] = {}
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            marker = "DEMO-BEAT "
            if marker not in line:
                continue
            tail = line.split(marker, 1)[1].strip().split()
            if len(tail) < 2:
                continue
            name, stamp = tail[0], tail[1]
            try:
                parsed = _dt.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
            except ValueError:
                continue
            beats[name] = parsed.timestamp()
    return beats


def probe_duration(path: str) -> float:
    out = run([FFPROBE, "-v", "error", "-show_entries", "format=duration",
               "-of", "json", path])
    if out.returncode != 0:
        raise SystemExit(f"ffprobe failed on {path}: {out.stderr[-500:]}")
    return float(json.loads(out.stdout)["format"]["duration"])


def has_audio(path: str) -> bool:
    out = run([FFPROBE, "-v", "error", "-select_streams", "a", "-show_entries",
               "stream=index", "-of", "csv=p=0", path])
    return bool(out.stdout.strip())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mov", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--record-start", type=float, required=True,
                    help="epoch seconds when recordVideo started (printed by demo_capture.sh)")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--slug", default="native-demo")
    ap.add_argument("--poster-name", default="",
                    help="write a PNG of the channel beat under this file name")
    ap.add_argument("--poster-beat", default="channel")
    ap.add_argument("--start-beat", default="app-launched",
                    help="beat the cut opens on (the test prints it as the app takes over)")
    ap.add_argument("--end-beat", default="back",
                    help="beat the cut closes on")
    ap.add_argument("--pad-before", type=float, default=0.4,
                    help="seconds of run-up before --start-beat")
    ap.add_argument("--pad-after", type=float, default=-0.15,
                    help="seconds held after --end-beat (the app is torn down just after it)")
    ap.add_argument("--speed", type=float, default=1.0,
                    help="uniform time-lapse of the cut (no cuts, no montage); 1.0 = real time")
    ap.add_argument("--max-gif-bytes", type=int, default=MAX_GIF_BYTES)
    args = ap.parse_args()

    if not os.path.exists(args.mov):
        raise SystemExit(f"no recording at {args.mov}")
    if not os.path.exists(args.log):
        raise SystemExit(f"no xcodebuild log at {args.log}")

    beats = beats_from_log(args.log)
    required = ["launch", "sidebar", "channel", "thread", "reply", "back", args.start_beat, args.end_beat]
    missing = [b for b in dict.fromkeys(required) if b not in beats]
    if missing:
        raise SystemExit(
            f"the log has no DEMO-BEAT line for {', '.join(missing)} — the take did not "
            f"complete, so there is nothing to cut (beats found: {sorted(beats)})")

    total = probe_duration(args.mov)
    # Everything is relative to the recording, whose clock started at --record-start.
    def at(name: str, pad: float = 0.0) -> float:
        return max(0.0, min(total, beats[name] - args.record_start + pad))

    start = max(0.0, at(args.start_beat, -args.pad_before))
    end = min(total, at(args.end_beat, args.pad_after))
    story = end - start
    out_seconds = story / args.speed
    print(f"recording : {args.mov} ({total:.2f} s)")
    print(f"beats     : {', '.join(f'{k}={v - args.record_start:.2f}s' for k, v in sorted(beats.items(), key=lambda kv: kv[1]))}")
    print(f"cut       : {start:.2f} .. {end:.2f}  ({story:.2f} s of story"
          + (f", played at {args.speed:.2f}x = {out_seconds:.2f} s)" if args.speed != 1.0 else ")"))
    if not (MIN_SECONDS <= out_seconds <= MAX_SECONDS):
        print(f"WARNING: the delivered take is {out_seconds:.2f} s; the card asks for "
              f"{MIN_SECONDS:.0f}-{MAX_SECONDS:.0f} s", file=sys.stderr)

    os.makedirs(args.out_dir, exist_ok=True)
    mp4 = os.path.join(args.out_dir, f"{args.slug}.mp4")
    gif = os.path.join(args.out_dir, f"{args.slug}.gif")

    # The source video: full device resolution, no audio track, faststart so a GitHub
    # "view raw" starts playing immediately. A speed other than 1.0 is a **uniform**
    # time-lapse of the same continuous take (setpts), never a cut.
    speed_filter = [] if args.speed == 1.0 else ["-filter:v", f"setpts=PTS/{args.speed},fps=30"]
    out = run([FFMPEG, "-y", "-loglevel", "error", "-ss", f"{start:.3f}",
               "-to", f"{end:.3f}", "-i", args.mov, "-an", *speed_filter,
               "-c:v", "libx264", "-preset", "slow", "-crf", "21",
               "-pix_fmt", "yuv420p", "-movflags", "+faststart", mp4])
    if out.returncode != 0:
        raise SystemExit(f"ffmpeg mp4 failed: {out.stderr[-800:]}")
    if has_audio(mp4):
        raise SystemExit("the mp4 must be muted; ffmpeg left an audio stream in it")
    print(f"mp4       : {mp4} ({os.path.getsize(mp4) / 1e6:.2f} MB, no audio track)")

    if args.poster_name:
        poster = os.path.join(args.out_dir, args.poster_name)
        shot = at(args.poster_beat, 1.2)
        out = run([FFMPEG, "-y", "-loglevel", "error", "-ss", f"{shot:.3f}",
                   "-i", args.mov, "-frames:v", "1", poster])
        if out.returncode != 0:
            raise SystemExit(f"ffmpeg poster failed: {out.stderr[-800:]}")
        size = run([FFPROBE, "-v", "error", "-select_streams", "v",
                    "-show_entries", "stream=width,height", "-of", "csv=p=0", poster])
        print(f"poster    : {poster} ({size.stdout.strip()})")

    # The embeddable GIF. Step down until the README's 8 MB budget is met; the card's
    # bounds are "1200 px wide max, 12-15 fps", both satisfied by every candidate.
    chosen = None
    for fps in GIF_FPS_CHOICES:
        for width in GIF_WIDTH_CHOICES:
            filter_chain = (
                (f"setpts=PTS/{args.speed}," if args.speed != 1.0 else "")
                + f"fps={fps},scale={width}:-1:flags=lanczos,split[a][b];"
                f"[a]palettegen=max_colors={PALETTE_COLOURS}:stats_mode=diff[p];"
                f"[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle"
            )
            out = run([FFMPEG, "-y", "-loglevel", "error", "-ss", f"{start:.3f}",
                       "-to", f"{end:.3f}", "-i", args.mov, "-loop", "0",
                       "-filter_complex", filter_chain, gif])
            if out.returncode != 0:
                raise SystemExit(f"ffmpeg gif failed: {out.stderr[-800:]}")
            size = os.path.getsize(gif)
            print(f"gif try   : {fps} fps, {width} px -> {size / 1e6:.2f} MB")
            if size <= args.max_gif_bytes:
                chosen = (fps, width, size)
                break
        if chosen:
            break
    if not chosen:
        raise SystemExit(f"no GIF candidate fits {args.max_gif_bytes} bytes")
    fps, width, size = chosen
    frames = run([FFPROBE, "-v", "error", "-count_frames", "-select_streams", "v",
                  "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", gif])
    print(f"gif       : {gif} ({size / 1e6:.2f} MB, {width} px, {fps} fps, "
          f"{frames.stdout.strip() or '?'} frames)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
