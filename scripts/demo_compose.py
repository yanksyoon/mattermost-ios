#!/usr/bin/env python3
"""Compose the README demo (T74 v2): the Mac Catalyst window first, then the iPhone take.

Two stages, so each can be re-run on its own:

    desktop   cut the app's own PNG frame sequence (written by `-demoFrameCapture`, see
              `runDemoFrameCaptureIfRequested` in MattermostApp.swift) on the test's
              `DEMO-BEAT` lines, at a uniform output frame rate, into one mp4.
    combine   put that desktop cut and the phone take on one canvas — desktop first, phone
              second, no montage inside a segment — and write the mp4 source of truth, the
              budgeted GIF and the poster.

Why the app films itself: Screen Recording TCC is denied to the unattended shell on the
build host (`screencapture -v` -> "could not create image from display", re-measured
2026-11-10), so the desktop segment is a `drawHierarchy` frame sequence the app writes from
its own window — the same mechanism `-nativeShellSnapshot` uses for stills. That caps the
source cadence at ~4 fps; the cutter holds each frame for `1/speed` of its real duration, so
motion is stepped, not sped-up.

Usage:
    python3 scripts/demo_compose.py desktop --frames build/demo/frames-light \\
        --log build/logs/demo-desktop-light.log --out build/demo/desktop-light.mp4 \\
        --poster-out build/demo/poster-light.png

    python3 scripts/demo_compose.py combine --desktop build/demo/desktop-light.mp4 \\
        --phone build/demo/phone-light.mp4 --out-dir docs/media/demo --slug native-demo
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from demo_render import FFMPEG, FFPROBE, beats_from_log, run  # noqa: E402  (same-directory helper)

DEFAULT_FPS = 12
MAX_GIF_BYTES = 8 * 1024 * 1024
GIF_FPS_CHOICES = (12, 10, 8)
GIF_WIDTH_CHOICES = (1000, 900, 800, 720, 640, 560)
PALETTE_COLOURS = 128

# Canvas padding per appearance: the segment a viewer is not watching sits on the theme's
# own background rather than a black bar.
PAD_COLOUR = {"light": "0xf2f3f5", "dark": "0x111317"}


def read_frames(frames_dir: str) -> list[tuple[float, str]]:
    index = os.path.join(frames_dir, "frames.jsonl")
    if not os.path.exists(index):
        raise SystemExit(f"no frames.jsonl in {frames_dir} — was the app launched with -demoFrameCapture?")
    out: list[tuple[float, str]] = []
    with open(index, "r", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
                out.append((float(row["epoch"]), os.path.join(frames_dir, row["file"])))
            except (ValueError, KeyError):
                continue
    if len(out) < 20:
        raise SystemExit(f"only {len(out)} frames in {frames_dir}; nothing to cut")
    out.sort(key=lambda pair: pair[0])
    return out


def nearest(frames: list[tuple[float, str]], when: float) -> str:
    lo, hi = 0, len(frames) - 1
    while lo < hi:
        mid = (lo + hi) // 2
        if frames[mid][0] < when:
            lo = mid + 1
        else:
            hi = mid
    if lo > 0 and abs(frames[lo - 1][0] - when) <= abs(frames[lo][0] - when):
        return frames[lo - 1][1]
    return frames[lo][1]


def cmd_desktop(args: argparse.Namespace) -> int:
    frames = read_frames(args.frames)
    beats = beats_from_log(args.log)
    for name in (args.start_beat, args.end_beat):
        if name not in beats:
            raise SystemExit(f"the log has no DEMO-BEAT line for {name!r} (found: {sorted(beats)})")

    start = beats[args.start_beat] - args.pad_before
    end = beats[args.end_beat] + args.pad_after
    picked = [pair for pair in frames if start <= pair[0] <= end]
    if len(picked) < 20:
        raise SystemExit(f"only {len(picked)} frames land in the {args.start_beat}..{args.end_beat} "
                         f"window; the capture did not run through the story")
    source_seconds = end - start
    out_seconds = source_seconds / args.speed
    count = max(2, int(round(out_seconds * args.fps)))
    print(f"frames    : {len(picked)} captured in {source_seconds:.2f} s "
          f"({len(picked) / source_seconds:.1f} fps source)")
    print(f"cut       : {args.start_beat} .. {args.end_beat} = {source_seconds:.2f} s "
          f"at {args.speed:.2f}x -> {out_seconds:.2f} s, {count} frames at {args.fps} fps")

    seq_dir = os.path.join(os.path.dirname(os.path.abspath(args.out)) or ".", "seq-" + args.slug_frames)
    if os.path.isdir(seq_dir):
        shutil.rmtree(seq_dir)
    os.makedirs(seq_dir)
    for i in range(count):
        # Output frame i is the source frame nearest t = start + (i/fps)*speed — real capture
        # time, so a slow drawHierarchy does not silently speed the take up.
        when = start + (i / args.fps) * args.speed
        src = nearest(picked, when)
        dst = os.path.join(seq_dir, f"{i:05d}.png")
        try:
            os.link(src, dst)
        except OSError:
            shutil.copyfile(src, dst)

    out = run([FFMPEG, "-y", "-loglevel", "error", "-framerate", str(args.fps),
               "-i", os.path.join(seq_dir, "%05d.png"), "-an",
               "-c:v", "libx264", "-preset", "slow", "-crf", "19",
               "-pix_fmt", "yuv420p", "-movflags", "+faststart", args.out])
    if out.returncode != 0:
        raise SystemExit(f"ffmpeg desktop mp4 failed: {out.stderr[-800:]}")
    print(f"desktop   : {args.out} ({os.path.getsize(args.out) / 1e6:.2f} MB)")

    if args.poster_out:
        when = beats.get(args.poster_beat, beats[args.end_beat]) + args.poster_offset
        src = nearest(frames, when)
        shutil.copyfile(src, args.poster_out)
        size = os.path.getsize(args.poster_out)
        # The card's budget is 500 KB: step the width down until the PNG fits.
        for width in (1200, 1000, 900, 800, 700, 600, 520):
            if size <= args.max_poster_bytes:
                break
            out = run([FFMPEG, "-y", "-loglevel", "error", "-i", src,
                       "-vf", f"scale='min({width},iw)':-2:flags=lanczos", args.poster_out])
            if out.returncode != 0:
                raise SystemExit(f"ffmpeg poster failed: {out.stderr[-800:]}")
            size = os.path.getsize(args.poster_out)
        print(f"poster    : {args.poster_out} ({size / 1e3:.0f} KB)")
        if size > args.max_poster_bytes:
            raise SystemExit(f"poster is {size} bytes, over the {args.max_poster_bytes} budget")
    return 0


def cmd_combine(args: argparse.Namespace) -> int:
    if not os.path.exists(args.desktop):
        raise SystemExit(f"no desktop cut at {args.desktop}")
    if not os.path.exists(args.phone):
        raise SystemExit(f"no phone take at {args.phone}")

    probe = run([FFPROBE, "-v", "error", "-select_streams", "v:0", "-show_entries",
                 "stream=width,height", "-of", "csv=p=0", args.desktop])
    if probe.returncode != 0:
        raise SystemExit(f"ffprobe failed on {args.desktop}: {probe.stderr[-400:]}")
    if args.canvas:
        width, height = (int(part) for part in args.canvas.lower().split("x"))
    else:
        width, height = (int(part) for part in probe.stdout.strip().split(","))
    width -= width % 2
    height -= height % 2
    pad = PAD_COLOUR.get(args.appearance, PAD_COLOUR["dark"])

    os.makedirs(args.out_dir, exist_ok=True)
    mp4 = os.path.join(args.out_dir, f"{args.slug}.mp4")
    gif = os.path.join(args.out_dir, f"{args.slug}.gif")

    # One canvas for both segments: the desktop fills it, the phone is centred in it. The
    # two segments are concatenated, in that order, with no fades and no montage inside a
    # segment — everything between a segment's first and last capture comes from the take.
    chain = (
        f"[0:v]scale={width}:{height}:force_original_aspect_ratio=decrease,"
        f"pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:color={pad},setsar=1,fps={args.fps}[d];"
        f"[1:v]scale={width}:{height}:force_original_aspect_ratio=decrease,"
        f"pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:color={pad},setsar=1,fps={args.fps}[p];"
        f"[d][p]concat=n=2:v=1:a=0[v]"
    )
    out = run([FFMPEG, "-y", "-loglevel", "error", "-i", args.desktop, "-i", args.phone,
               "-filter_complex", chain, "-map", "[v]", "-an",
               "-c:v", "libx264", "-preset", "slow", "-crf", "20",
               "-pix_fmt", "yuv420p", "-movflags", "+faststart", mp4])
    if out.returncode != 0:
        raise SystemExit(f"ffmpeg combine failed: {out.stderr[-1200:]}")
    print(f"mp4       : {mp4} ({os.path.getsize(mp4) / 1e6:.2f} MB, {width}x{height}, canvas)")

    chosen = None
    for fps in GIF_FPS_CHOICES:
        for gif_width in GIF_WIDTH_CHOICES:
            filter_chain = (
                f"fps={fps},scale={gif_width}:-1:flags=lanczos,split[a][b];"
                f"[a]palettegen=max_colors={PALETTE_COLOURS}:stats_mode=diff[p];"
                f"[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle"
            )
            out = run([FFMPEG, "-y", "-loglevel", "error", "-i", mp4,
                       "-filter_complex", filter_chain, "-loop", "0", gif])
            if out.returncode != 0:
                raise SystemExit(f"ffmpeg gif failed: {out.stderr[-800:]}")
            size = os.path.getsize(gif)
            print(f"gif try   : {fps} fps, {gif_width} px -> {size / 1e6:.2f} MB")
            if size <= args.max_gif_bytes:
                chosen = (fps, gif_width, size)
                break
        if chosen:
            break
    if not chosen:
        raise SystemExit(f"no GIF candidate fits {args.max_gif_bytes} bytes")
    fps, gif_width, size = chosen
    probe = run([FFPROBE, "-v", "error", "-show_entries", "format=duration",
                 "-of", "csv=p=0", mp4])
    print(f"gif       : {gif} ({size / 1e6:.2f} MB, {gif_width} px, {fps} fps, "
          f"{probe.stdout.strip()} s of canvas)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="command", required=True)

    d = sub.add_parser("desktop", help="cut the app's own frame sequence on the DEMO-BEAT lines")
    d.add_argument("--frames", required=True, help="directory with frames.jsonl from -demoFrameCapture")
    d.add_argument("--log", required=True, help="xcodebuild log with the DEMO-BEAT lines")
    d.add_argument("--out", required=True, help="desktop segment mp4 to write")
    d.add_argument("--poster-out", default="", help="still (PNG) from --poster-beat")
    d.add_argument("--poster-beat", default="channel")
    d.add_argument("--poster-offset", type=float, default=1.2)
    d.add_argument("--max-poster-bytes", type=int, default=500_000)
    d.add_argument("--start-beat", default="sidebar")
    d.add_argument("--end-beat", default="reply")
    d.add_argument("--pad-before", type=float, default=0.6)
    # The test taps Back immediately after the end beat; any positive pad lands on the
    # channel re-mount (measured: a blank pane with a spinner). End on the reply itself.
    d.add_argument("--pad-after", type=float, default=0.0)
    d.add_argument("--speed", type=float, default=1.5)
    d.add_argument("--fps", type=int, default=DEFAULT_FPS)
    d.add_argument("--slug-frames", default="desktop")

    c = sub.add_parser("combine", help="desktop segment then phone segment on one canvas")
    c.add_argument("--desktop", required=True)
    c.add_argument("--phone", required=True, help="phone take mp4 to cut the second segment from")
    c.add_argument("--phone-from", type=float, default=0.0)
    c.add_argument("--phone-to", type=float, default=0.0,
                   help="0 = take the whole phone file")
    c.add_argument("--out-dir", required=True)
    c.add_argument("--slug", default="native-demo")
    c.add_argument("--appearance", choices=("light", "dark"), default="dark")
    c.add_argument("--canvas", default="", help="WxH; default = the desktop cut's own size")
    c.add_argument("--fps", type=int, default=DEFAULT_FPS)
    c.add_argument("--max-gif-bytes", type=int, default=MAX_GIF_BYTES)

    args = ap.parse_args()
    if args.command == "desktop":
        return cmd_desktop(args)
    if args.phone_from or args.phone_to:
        trimmed = args.phone + ".trim.mp4"
        span = []
        if args.phone_from:
            span += ["-ss", str(args.phone_from)]
        if args.phone_to:
            span += ["-to", str(args.phone_to)]
        out = run([FFMPEG, "-y", "-loglevel", "error", *span, "-i", args.phone,
                   "-an", "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", trimmed])
        if out.returncode != 0:
            raise SystemExit(f"ffmpeg phone trim failed: {out.stderr[-800:]}")
        args.phone = trimmed
    return cmd_combine(args)


if __name__ == "__main__":
    sys.exit(main())
