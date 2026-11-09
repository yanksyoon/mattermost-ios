# Demo assets

The README's hero demo is **one GIF with two segments**, in the order a reader can install
the product: the Mac Catalyst window first, then the same workspace in the iPhone layout.

| File | What it is |
|---|---|
| `native-demo.gif` | the embeddable demo, light appearance: desktop segment then phone segment, ≤ 8 MB |
| `native-demo.mp4` | the same canvas composition, full window resolution, no audio — linked, never embedded (GitHub READMEs do not render `<video>`) |
| `poster.png` | a still of the **desktop** segment (the `channel` beat), for the README's `<img>` fallback, ≤ 500 KB |
| `native-demo-dark.gif` / `native-demo-dark.mp4` / `poster-dark.png` | the same two segments in dark appearance |

Measured on the shipped assets (2026-11-10):

| File | Bytes | Notes |
|---|---|---|
| `native-demo.gif` | 4 779 618 | 1000×750, 12 fps, 34.3 s |
| `native-demo-dark.gif` | 4 077 778 | 1000×750, 12 fps, 34.5 s |
| `native-demo.mp4` | 1 388 227 | 1330×998 canvas, H.264, no audio |
| `native-demo-dark.mp4` | 1 211 277 | 1330×998 canvas, H.264, no audio |
| `poster.png` | 452 589 | still of the desktop segment |
| `poster-dark.png` | 467 010 | still of the desktop segment |

## The two segments

1. **Desktop (Mac Catalyst), ~11 s.** The app's own window at 1330×998 pt: the grouped
   sidebar (WORKSPACE / WEB VIEW / CHANNELS) with #Design review unread and a mention badge,
   #Town Square on launch, opening #Design review, scrolling, opening a thread, typing and
   sending a reply, and the reply arriving in the thread. Cut on the `DEMO-BEAT` lines of
   `TDemoCaptureUITests` (`sidebar` → `reply`) at **2.6×** so the ~29 s of XCTest-paced story
   lands at ~11 s, as the card asks.
2. **Phone (iPhone 16 Pro, iOS 18.3), ~23 s.** The unchanged T74 simulator-framebuffer take
   (`xcrun simctl io recordVideo`, 1206×2622 at 1.3×). It is placed centred on the same canvas;
   the side bands are the theme background, not a fade.

There is no montage inside a segment: every frame between a segment's first and last beat
comes from one continuous capture. The two segments are concatenated once, desktop first.

## Capture route (what was used and why)

The desktop segment is filmed by **the app itself**: `-demoFrameCapture <dir>` writes the
window to `frame-<epoch-ms>.png` ~4 times a second via `drawHierarchy`, with `frames.jsonl`
recording each frame's wall clock, while the same `TDemoCaptureUITests` story is driven by
XCUITest. `-demoFrameScheme light|dark` forces the appearance for the take (this host's desktop
stays in dark mode; the light take is not a different machine).

| Route | Cost | Permissions | Output | Agent-repeatable here | Verdict |
|---|---|---|---|---|---|
| app films its own window (`-demoFrameCapture`) | free | **none** — `drawHierarchy` on the app's own window needs no Screen Recording TCC | window only, no other windows/dock, ~4.1 fps source | **yes**, scripted end to end | **chosen** |
| `screencapture -v` / QuickTime on the Catalyst window | free | Screen Recording TCC for the capturing process | the best-looking take: includes the AppKit titlebar and traffic lights | **no on this host** — `screencapture -x` still exits "could not create image from display" unattended (re-measured 2026-11-10) | fallback if chrome is required; needs the owner to grant TCC |
| `XCUIScreen.main.screenshot()` loop in the UI test | free | none (XCTest is exempt) | the whole display, including other windows and the dock; 2–4 fps | yes, but the take would need a crop and desktop hygiene | rejected: the window can be filmed directly |
| `XCUIScreen.main.startVideoRecording()` | — | — | — | **not available**: no such API in the XCUIAutomation headers shipped with Xcode 26.6 (checked) | rejected |
| `xcrun simctl io recordVideo` | free | none | device-accurate phone framebuffer | yes | used for the phone segment (T74, unchanged) |

## Re-shoot

```bash
scripts/demo_capture.sh                    # both surfaces, light + dark, then compose (~10 min)
scripts/demo_capture.sh --surface desktop  # desktop segment only, then compose
scripts/demo_capture.sh --surface ios      # phone segment only, then compose
DEMO_VARIANTS=light scripts/demo_capture.sh
```

`--surface desktop` needs the phone takes in `build/demo/phone-<variant>.mp4` and
`--surface ios` needs the desktop cuts in `build/demo/desktop-<variant>.mp4`; the script fails
with the missing path instead of publishing a one-segment hero.

Host specifics that are load-bearing (all measured on this machine):

* **Deployment target override.** The UITest target declares a macOS 26.5 deployment target;
  this host is 26.3.1, so `xcodebuild` refuses to run it. The script passes
  `MACOSX_DEPLOYMENT_TARGET=13.0` (the app's own target) to both `build-for-testing` and
  `test-without-building`.
* **Unsigned build, ad-hoc re-sign of *both* bundles.** `CODE_SIGNING_ALLOWED=NO` for the
  build, then `codesign --force --deep -s -` on `Mattermost.app` **and**
  `MattermostUITests-Runner.app`. Signing only the app leaves an unsigned runner, and macOS's
  AppleSystemPolicy kills it before it connects (`... Runner encountered an error (Early
  unexpected exit ... Test crashed with signal kill before establishing connection)` —
  reproduced 2026-11-10).
* **`-clonedSourcePackagesDirPath`.** The Catalyst build reuses the SourcePackages checkout
  from the simulator DerivedData; a fresh package resolve hangs on GRDB's SQLiteLib submodule.
* **ffmpeg with libx264.** `/usr/local/bin/ffmpeg` on this host is a 2022 build with no
  libx264; `scripts/demo_render.py` / `scripts/demo_compose.py` pick `/opt/homebrew/bin/ffmpeg`
  explicitly (override with `DEMO_FFMPEG`).

The fixture is `scripts/demo_seed.py`: team `demo` / "Northwind Studio", channels Town Square,
Announcements, Design review, Engineering, Off-Topic, accounts robin / ava / jordan / riley —
all synthetic, against the throwaway server on `127.0.0.1:8065`. Nothing from a real
workspace is on screen: no real server hostname, no real names, no email addresses, and the
mention badge is the fixture's own seeded `@robin` mention.

## Cutting and composing

`scripts/demo_compose.py desktop` maps each output frame to the captured frame nearest its
real capture time (so a slow `drawHierarchy` cannot silently speed the take up), hard-links
the sequence and encodes it. `scripts/demo_compose.py combine` puts desktop and phone on one
canvas, writes the mp4 source of truth, and steps the GIF down in fps/width until it fits
8 MB (each try is printed).

Prove the segments are what the table says without trusting prose:

```bash
ffmpeg -i docs/media/demo/native-demo.gif -vf "select=eq(n\,0)"  -frames:v 1 frame-1.png
ffmpeg -i docs/media/demo/native-demo.gif -vf "select=eq(n\,15)" -frames:v 1 frame-15.png
```

Both are the **desktop** layout: a ~240 pt grouped sidebar beside a timeline and a composer
row, which the iPhone layout does not draw. They are not the phone (a narrow single column).

## Known gaps (what this asset does not prove)

* **No AppKit chrome.** `drawHierarchy` captures the app's window *content*; the titlebar and
  the red/yellow/green traffic lights are drawn by AppKit above it and are not in the frame.
  What identifies the segment as the Mac build is the desktop layout and window proportions
  (sidebar beside timeline, 1330×998 pt), not the window buttons. A take that shows the
  titlebar still needs Screen Recording TCC plus `screencapture -v` while the same UI test
  drives the app (the pre-`bb40ed7` take did that and does show traffic lights).
* **Stepped motion.** The source cadence is ~4.1 fps (PNG encode on the app's main actor). The
  desktop segment is played at 2.6× on a 12 fps canvas, so typing and the arriving reply read
  as fast-but-stepped rather than smooth. This was checked by eye on extracted frames
  (sidebar → channel → thread → typed → sent), not asserted.
* **Debug build.** The demo test needs the Debug-only `-uiTestSeededStoredToken` /
  `-surfaceMode` / `-demoFrameCapture` seams.
* **Different recording days.** The phone segment is the 2026-11-09 take, so its clock text
  differs from the desktop take's; the conversation, workspace and story are the same seed.
* No audio track, by design. The content is fixture data; the app talks to a real Mattermost
  9.11.19 over REST + WebSocket.

## Maintenance

Re-run `scripts/demo_capture.sh` after any UI change the story touches (sidebar, channel
timeline, post row, thread pane, composer). If a beat's identifier changed, the capture test
fails and publishes nothing.

Keep the README pointing at this file **in-repo** (`docs/media/demo/native-demo.gif`). GitHub
only routes images through the camo proxy when they are hosted elsewhere; camo drops any
response over 5 MB, which both GIFs would hit. If these assets move to a CDN, re-encode under
5 MB first (`GIF_WIDTH_CHOICES` in `scripts/demo_compose.py`).
