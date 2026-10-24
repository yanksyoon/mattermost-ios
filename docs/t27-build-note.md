# T27 build note — memory / performance baseline harness

- **Status:** delivered 2026-10-24. Baseline: `docs/perf/README.md` + `docs/perf/baseline-2026-10-24.json`
- **Card:** T27 (memory/performance baseline harness — webview vs native, measured)
- **Program anchor:** `docs/path-b-adr.md` §4 ("the memory premise, measured not folklore"),
  `docs/dual-render.md` §12.6 (the metric the webview release policy must move)
- **Consumer:** every screen card from here on cites its own delta against this baseline; the
  `-AV` card for each may re-run the probe (`--skip-build --modes web,native`) and compare.

## 1. What was built

| File | What it is |
|---|---|
| `scripts/perf_probe.sh` | the harness: seeds a throwaway server, builds the two real targets with `PERF_PROBE`, launches each arm, runs the external sampler, writes the report. `--repeat N` repeats every arm (run-to-run spread). |
| `scripts/perf_seed.py` | seeds one channel with N text posts and one thread with M replies through the public REST API, so the measured web app has a fixed, reproducible workspace. Writes `creds.json` (0600, under `build/`, never in `docs/` or git). |
| `scripts/perf_collect.py` | the sampler (`ps` RSS timeline + `footprint` snapshots at every stage boundary) and the reporter (`docs/perf/*.json`, `docs/perf/README.md`). |
| `Mattermost/Core/PerfProbe.swift` | the in-app measurement seam, compiled only under `DEBUG \|\| PERF_PROBE`. Inert without `-perfProbe <dir>`. Drives the fixed sequence through the shell's own webview and journals every stage boundary (`os_signpost` intervals on `com.mattermost.ios.perf` **and** an append-only JSONL journal the sampler aligns to). |
| `MattermostTests/PerfProbeTests.swift` | 9 unit tests: inert without the flag, full parsing, defaults, unknown-mode fallback, tilde expansion, non-numeric fallbacks, and **credentials never read from argv**. |
| `docs/perf/README.md`, `docs/perf/baseline-2026-10-24.json` | the landed baseline (generated, not hand-written). |

## 2. The arms, and what each one answers

| arm | what runs | the question it answers |
|---|---|---|
| `web` | server seeded, channel view rendered by the WKWebView, full DOM sequence | what Path A costs today |
| `native` | server seeded, the pane is T26's native stand-in (`-surfaceMode channelView=native`) | what the shell still pays **for the web engine** while a native surface owns the pane |
| `shell` | no server at all, no webview | the floor a real native client starts from |

The sequence is launch → workspace render → log in → open the channel → scroll 12 post-list
steps → open a new post's thread → idle steady state. Every stage boundary is recorded in the
journal and as an `os_signpost` interval; a stage that cannot complete is recorded `ok: false`
with the DOM evidence that explains it, and the run continues.

## 3. How the numbers are produced (no invented figures)

* **`footprint --pid <pid> --noCategories -j`** — the kernel's physical-footprint accounting, the
  same quantity Instruments' VM Tracker reports, including the process's lifetime peak.
* **`ps -axo pid=,ppid=,rss=,comm=`** — sampled every 0.5 s for the timeline, so peak RSS is a real
  maximum over the run rather than one guess.
* **Attribution rule:** a WebKit helper belongs to the run iff its pid was **not** in the pre-launch
  snapshot (Safari's and other apps' helpers are excluded, never mis-attributed). WebContent, GPU
  and Networking are tracked separately and summed.
* Every figure in `docs/perf/baseline-2026-10-24.json` is a sum or a max of those two commands over
  the pids of one run; `runs[].pids` names them.

## 4. The landed baseline (Mac Catalyst + iOS Simulator, 2026-10-24)

Medians over 2 runs per arm; full tables, per-run values and the run-to-run spread are in
`docs/perf/README.md`.

| target | shell (no webview) | Path A steady | loaded webview costs | of that, WebContent | WebContent still alive in `native` | Path A peak RSS |
|---|---:|---:|---:|---:|---:|---:|
| Mac Catalyst | 30.0 MB | 592.1 MB | **562.1 MB** | 90 % | 252.6 MB | 942.9 MB |
| iOS Simulator | 28.6 MB | 489.3 MB | **460.7 MB** | 90 % | 146.4 MB | 1329.2 MB |

Launch → first post: 3.38–3.44 s (Catalyst), 3.06–3.14 s (Simulator). Stage durations for the
Catalyst web arm: workspace 415 ms, login 987 ms, open channel 262 ms, scroll 12 steps 3090 ms,
open thread 1846 ms.

Two things a reader should take from this, both measured rather than asserted:

1. The SwiftUI shell is ~30 MB steady. The per-server webview costs **0.46–0.56 GB**, and ~90 % of
   that is the WebContent process the shell does not own. That is the premise of Path B, as a
   number on this machine.
2. A surface that resolves `native` at HEAD **still carries a live WebContent process**
   (252.6 MB Catalyst / 146.4 MB Simulator steady) — T26-AV's F4, now measured. Rendering
   independence alone buys none of the memory back; only releasing the webview does
   (`docs/dual-render.md` §12.6, implemented by t_64ee78c9).

## 5. Reproduce

```sh
scripts/perf_probe.sh --server-start \
  --targets catalyst,simulator --modes web,shell,native --repeat 2
```

`--server-start` needs a Docker daemon (it starts `mattermost/mattermost-team-edition:release-9`
plus Postgres and keys them `mm-perf` / `mm-perf-db`); without Docker, point `--server-url` at a
throwaway server you own. Re-running against existing builds: add `--skip-build`. The script fails
the run (and says which arm) when the app never writes its journal, when a target's build does not
report `BUILD SUCCEEDED`, or when a stage cannot be driven.

Raw runs for the landed baseline: `build/perf/20261024-164606/` (12 arm directories; not
committed — `build/` is ignored, the JSON is the record).

## 6. Two defects found while landing the harness (both fixed here)

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | Simulator arms never started the probe: the app launched, loaded the webview, and no journal or `probe.done` ever appeared (the run burned its whole 300 s budget and reported "the sequence did not run") | `-perfProbe <dir>` was a **relative** path. Catalyst inherits the shell's CWD; a Simulator app's CWD is inside the simulator, so the app wrote its journal where nobody was watching (`createDirectory` failure was swallowed by `try?`) | the script makes `OUT_ROOT`/`RUN_ROOT` absolute before launching; `PerfProbe.init` logs the failure it used to swallow; `run_one` fails fast (25 s) when no journal appears instead of waiting out the budget |
| 2 | `openThread` always failed ("no reply affordance") and the thread-open footprint was missing from the report | the probe looked for `.post__comment` / `[data-testid="post-comment"]`, which the current web app does not render; the reply affordance is `button[id*="commentIcon"]` / `.post-menu__item[aria-label="reply"]` (rendered on hover, or statically for a root post that has replies), and the RHS is `#sidebar-right` / `.sidebar--right`. Separately, the sampler could break out on `probe.done` in the same 0.5 s window a stage ended, losing that stage's snapshot | `openThread` now tries the comment icon, then a synthetic hover, then the post dot-menu (`[data-testid^="PostDotMenu-Button-"]` → `[data-testid^="reply_to_post_"]`), and records which selector worked; the sampler re-reads the journal once when it sees `probe.done` |

Selectors were derived by **observing** the Apache-2.0 webapp (`components/common/comment_icon.tsx`,
`components/dot_menu/dot_menu.tsx`) and the live DOM — no webapp source is copied into this repo.

## 7. Verification (runner's own verdict)

| Bundle | Command | Verdict |
|---|---|---|
| Mac Catalyst unit | `xcodebuild test … -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:MattermostTests` | **TEST SUCCEEDED** — Executed 356 tests, with 1 test skipped and 0 failures (`docs/t27-catalyst-unit-2026-10-24.log`) |
| iOS Simulator unit | same, `-destination 'platform=iOS Simulator,id=6B6991BF…'` | **TEST SUCCEEDED** — Executed 356 tests, with 1 test skipped and 0 failures (`docs/t27-ios-unit-2026-10-24.log`) |
| Perf probe (12 arms) | `scripts/perf_probe.sh --targets catalyst,simulator --modes web,shell,native --repeat 2` | all 12 arms green (`failed runs: 0`), every `web` arm completing all five scripted stages |

The single skip is the pre-existing opt-in live-network test (`MentionPollerTests.testLiveMentionsFetch_optIn`),
not a dual-render or perf test.

## 8. Limits — what this does **not** measure

* **Not a device measurement.** Both targets run on this Mac. A device run needs a physical
  iPhone/iPad (iOS 17+), `xcrun devicectl device process launch --device <udid> <bundle-id>
  -perfProbe <dir> -perfProbeServer <url> …` with the same flags, `devicectl`-driven
  `footprint`/`vmmap` over the app **and** its WebContent processes (or Instruments' VM Tracker),
  and the seeded server reachable over the LAN. It was not run here: **no device is attached to
  this host.** Jetsam limits WebContent differently on device, so absolute values will differ; the
  shell-vs-webview *ratio* is the transferable result.
* **The `native` arm is not a native chat screen.** It is T26's stand-in, and its webview is
  unmounted (so the virtualised post list has no height and the DOM sequence is not driven there).
  Its footprint is a lower bound for "native card + live webview", not an equal-state comparison.
  The `nativeEvicted` arm that measures the release policy is a different card (t_64ee78c9).
* **Text-only workspace.** 200 text posts + 24 replies, no image attachments, emoji reactions,
  custom emoji, plugin UI, or Calls. Each of those changes the webview's memory.
* **One machine, one server version** (Mattermost 9.11.19, local). A different server version
  ships a different web bundle.
* **Process memory only.** No GPU memory beyond the WebKit GPU helper's own footprint, no energy,
  no compressed-memory/swap accounting, no per-thread detail.
* **Peak is sampled, not traced.** RSS at 0.5 s; `phys_footprint_peak` comes from the kernel and is
  the true per-process peak, but the summed "total peak" is a sum of per-process peaks and may be
  slightly pessimistic (the peaks need not coincide).
* **Run-to-run spread is real:** 6.6–9.5 % on the `web` arms, ≤0.2 % on `shell`. A comparison
  between two arms smaller than that band is not a result.

## 9. Wire-up for later cards

Each screen card can measure its own surface without touching this harness:

```sh
# the surface's own arm, with the app already built
scripts/perf_probe.sh --skip-build --targets catalyst --modes native --no-baseline
jq '.steady.total_phys_footprint_bytes, .pids.webcontent' \
  build/perf/<stamp>/catalyst-native/run.json
```

`run.json` names the app pid, the WebContent/GPU/Networking pids, peak and steady footprint, and
the per-stage snapshots — so a card cites `steady.total_phys_footprint_bytes`, the WebContent
count and (once the release policy lands) `pids.webcontent == []` rather than a vibe.
