# Demo assets

The README's hero demo: one continuous take of the native shell against a throwaway
server, recorded from the iOS simulator's framebuffer.

| File | What it is |
|---|---|
| `native-demo.gif` | the embeddable demo, light appearance, ≤ 8 MB |
| `native-demo.mp4` | the same cut, full device resolution, no audio — linked, never embedded (GitHub READMEs do not render `<video>`) |
| `poster.png` | a still from the `channel` beat, for the README's `<img>` fallback |
| `native-demo-dark.gif` / `native-demo-dark.mp4` / `poster-dark.png` | the same story in dark appearance |

Re-shoot everything with:

```bash
scripts/demo_capture.sh                 # light + dark takes, ~4 minutes
DEMO_VARIANTS=light scripts/demo_capture.sh
```

## How the capture works

1. `scripts/demo_seed.py` rebuilds the throwaway workspace on the local Docker server
   (`127.0.0.1:8065`): team `demo` / "Northwind Studio", channels Town Square,
   Announcements, Design review, Engineering, four synthetic accounts, a conversation
   with a three-reply thread and an unread state. Everything is synthetic — no real
   name, DM, or server URL appears on screen.
2. `xcrun simctl io <udid> recordVideo` records the simulator's own framebuffer.
3. `MattermostUITests/TDemoCaptureUITests` drives the story and prints a `DEMO-BEAT`
   timestamp at each beat. It runs signed in through the product's own vault seam, and
   it asserts each surface it films (header present, reply line on the root, Back
   returns to the channel) plus that the reply it types actually reached the server.
4. `scripts/demo_render.py` cuts the take at those beats with ffmpeg, writes the mp4
   (muted, faststart), the poster, and the palette-optimised GIF, stepping the width
   down until the file fits 8 MB.

The XCUITest runner's own waits (accessibility snapshots, idle waits) make the raw take
slower than a human would drive the app, so both outputs run the **same continuous
take** at `1.3x` (`DEMO_SPEED`). There are no cuts and no montage: every frame between
launch and the return to the channel comes from one recording.

## Capture tooling: the options, measured on this host

The card asked for a comparison before committing to a method. "Agent-repeatable" means
a non-interactive shell can run it end to end, on this machine, without a human click.

| Option | Cost | Permissions | Output quality | Agent-repeatable here | Verdict |
|---|---|---|---|---|---|
| `xcrun simctl io <udid> recordVideo` | free (Xcode) | none — records the simulator framebuffer, so **no** Screen Recording TCC | device-accurate 1206×2622 H.264 of the real native app; no audio; no cursor | **yes** — one command, deterministic app state from a UI test | **chosen** |
| `screencapture -v` / QuickTime on the Mac Catalyst app | free | Screen Recording TCC for the capturing process | the best-looking and most representative build (real Mac window, larger type) | **no on this host** — `screencapture` exits with "could not create image from display" in an unattended shell (measured again on 2026-11-09); a human can record it manually, an agent cannot | rejected for now; see "known gaps" |
| `vhs` / `asciinema` | free | none (terminal) | excellent for CLIs, but they record a terminal — there is no GUI surface to capture | yes, but it cannot record this product | rejected: wrong shape |
| CleanShot X / Kap / Screen Studio | paid (CleanShot ~$29, Screen Studio ~$89; Kap free) | Screen Recording TCC; manual operation | polished (cursor smoothing, zooms, backgrounds) | no — third-party install plus human-driven capture, not reproducible from a script | rejected |
| static screenshot sequence → GIF | free (`simctl io screenshot` + ffmpeg) | none | fully deterministic but no motion, no typing, no transitions — lowest fidelity | yes | fallback only; not needed |

The one honest cost of the chosen path: it films the **iPhone** build, not the Mac
Catalyst window. The GIF therefore shows the phone layout, which is the layout the
same SwiftUI code draws on a phone; the Catalyst window is not in it.

## Known gaps (what this asset does not prove)

* No audio track, by design.
* Recorded against a local, seeded, throwaway server. The product behaviour is real —
  the app talks to Mattermost 9.11.19 over its HTTP and websocket APIs — but the content
  is fixture data.
* The Mac Catalyst window is not shown (Screen Recording TCC, above). Re-shooting that
  is a manual job: QuickTime/`screencapture -v` while a human drives the app.
* The GIF is a 1.3× time-lapse of a continuous take; the mp4 is the same window and the
  same treatment, so the two always match.

## Maintenance

Re-run `scripts/demo_capture.sh` after any UI change that the story touches (sidebar,
channel timeline, post row, thread pane, composer). If a beat's identifier changed, the
capture test fails and publishes nothing — it never ships a take where a step silently
did nothing.

Keep the README pointing at this file **in-repo** (`docs/media/demo/native-demo.gif`).
GitHub only routes images through the camo proxy when they are hosted elsewhere; camo
drops any response over 5 MB, which the 6.5 MB GIF would hit. If these assets ever move
to a CDN/jsDelivr, re-encode under 5 MB first (`GIF_WIDTH_CHOICES` / `GIF_FPS_CHOICES`
in `scripts/demo_render.py`).

## Desktop take (2026-11-09)

`desktop-demo.gif` (4.2 MB, 35 s), `desktop-demo.mp4`, `desktop-poster.png` are the same story
filmed on the **Mac Catalyst** build, screen-recorded from a real window rather than the simulator
framebuffer. The story, the fixture and the beat names are identical to the phone take; only the
capture path differs.

Route: the host's Screen Recording grant went to the terminal app, so `screencapture -v` is
scriptable here. The take is driven by the same `TDemoCaptureUITests` — no human hands on the app.

```bash
# 1. fixture (team "Northwind Studio", accounts robin/ava/jordan/riley, all synthetic)
python3 scripts/demo_seed.py --url http://127.0.0.1:8065 \
  --creds-out /tmp/demo_creds.json --env-out /tmp/demo_env.sh

# 2. build the UI test bundle. Two overrides are needed on this host:
#    - the UITest target declares a macOS 26.5 deployment target and the host is 26.3.1, so
#      xcodebuild refuses to run it; override down to 13.0 (the app's own target).
#    - an ad-hoc signed test *bundle* cannot load into an ad-hoc signed runner ("mapping process
#      and mapped file (non-platform) have different Team IDs"), so the bundle is built unsigned
#      and the app is re-signed afterwards, which is what lets it launch.
xcodebuild build-for-testing -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/mm-demo-dd \
  MACOSX_DEPLOYMENT_TARGET=13.0 CODE_SIGNING_ALLOWED=NO
codesign --force --deep -s - /tmp/mm-demo-dd/Build/Products/Debug-maccatalyst/Mattermost.app

# 3. record the display, drive the test, stop the recorder
screencapture -v -x /tmp/demo_desktop.mov &          # SIGINT the *screencapture* pid, not the shell
set -a; . /tmp/demo_env.sh; set +a
xcodebuild test-without-building -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/mm-demo-dd \
  MACOSX_DEPLOYMENT_TARGET=13.0 -only-testing:MattermostUITests/TDemoCaptureUITests

# 4. cut on the DEMO-BEAT timestamps, crop to the window, encode
ffmpeg -ss <launch-beat> -to <back-beat+2> -i /tmp/demo_desktop.mov \
  -vf "crop=2070:1535:470:175,scale=1280:-2:flags=lanczos" -c:v h264_videotoolbox -b:v 6M take.mp4
ffmpeg -ss 17 -to 52.5 -i take.mp4 \
  -vf "fps=12,scale=1080:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=192:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
  -loop 0 desktop-demo.gif
```

Known gaps of this take: it is a **Debug** build (the demo test needs the Debug-only
`-uiTestSeedStoredToken` / `-surfaceMode` seams), the appearance is the host's dark mode, so there
is no light desktop variant yet, and the window geometry is whatever the test inherits — the crop
rectangle above is tied to this host's display size (3024x1964). Re-derive it from a frame if the
display changes.
