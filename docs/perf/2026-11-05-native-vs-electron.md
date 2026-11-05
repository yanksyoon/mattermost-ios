# Native Catalyst client vs the official Electron client

Session: 2026-11-05 21:34:02 +0800 on MacBookPro18,3, macOS 26.3.1, 10 logical CPUs. Power: Now drawing from 'AC Power'. Workspace: `https://chat.canonical.com`. Channel: `(not asserted)`.

**Status: BLOCKED — not measured.** Harness: `scripts/perf_compare.py` (sampling primitives reused from `scripts/perf_collect.py`).

## Result: BLOCKED — nothing was measured

A performance comparison of a login screen is not a performance comparison. The run stops in the preflight and reports why, per the card's rule:

- **native_signed_in** — mm.servers hasSession=False for 'https://chat.canonical.com'
- **electron_signed_in** — MMAUTHTOKEN for 'chat.canonical.com': absent from the cookie store
- **channel_asserted** — --channel='': the operator asserts both clients sit on it

Observed state of each subject at preflight time:

- native: version 0.71.0 build 371, configured workspace `https://chat.canonical.com`, `hasSession=False`, running pids [85787]
- electron: version 6.3.1 build 383788041691, configured workspaces ['https://chat.canonical.com', 'https://chat.charmhub.io', 'http://mattermost-k8s:8065'], session cookie for the shared host: ABSENT (MMUSERID present but no MMAUTHTOKEN is a stale session, not a signed-in one)

To make the comparison measurable, sign both clients in to the same workspace, open the same channel in both, and re-run `scripts/perf_compare.py run --workspace <url> --channel <name>`.

Either workspace works as long as both clients use it. The throwaway local fixture this repository already uses for the webview baseline is the cheapest reproducible option: bring up the docker server, seed it with `scripts/perf_seed.py` (user `perfprobe`, team `perf`, channel `#perf-feed` with 200 posts), sign both clients into it, then run with `--workspace http://127.0.0.1:8065 --channel perf-feed`.

The card names the native subject as *0.1.7 build 8*; the installed bundle reports the version above, and the artefact records what is installed and preflighted rather than what the card expected.

No win or loss is named here: no RSS, CPU, launch or energy number was taken for either subject, so any sentence about which client is faster would be invention. The table below keeps every row and says why it is empty.

## Method (the harness; it did not run this session)

Recorded so the next run is reproducible and auditable:

- **RSS** — `ps -axo rss` sampled every 0.5 s over the app's whole process tree (descendants by ppid) plus the WebKit helper processes attributed to the app with `scripts/perf_collect.py`'s rule (pids absent from the pre-launch baseline). Electron's Renderer/GPU/Utility helpers are children and are summed; Catalyst's WebContent/GPU/Networking helpers are not children and are attributed explicitly.
- **CPU** — Δ(cumulative CPU time from `ps -o time=`) over each 0.5 s interval, so mean and p95 are windowed; `ps`'s own %CPU column is a lifetime average and is not used. 100 % = one core.
- **Threads / fds / children** — `ps -M` thread lines, `lsof -p` descriptor count (header removed), and the number of descendant processes, all summed over the same pid set.
- **Energy** — `top -stats power` summed over the tree, sampled every 5 s.
- **Launch** — from `open -n <bundle>` to the first pid match (to process alive) and to the first non-zero System Events window count (to first window), three runs, median. *Not* "to interactive": the app's own first paint is not observable from outside it.
- **Steady state** — RSS at the end of a 10-minute idle window, against the end of the first idle window, to expose growth a 2-minute sample hides.
- **Active window** — 60 s of wheel events posted with Core Graphics straight to the app's pid (`scripts/perf_scroll.swift`), so both clients receive the same synthetic input path rather than two different automation stacks. The event count is recorded; the number of posts actually rendered is not claimed.


| metric | native | electron | ratio (native/electron) | notes |
|---|---:|---:|---:|---|
| idle 120 s — RSS median | not measured | not measured | — | over the process tree |
| idle 120 s — RSS p95 | not measured | not measured | — | same tree, 95th percentile sample |
| idle 120 s — CPU mean % | not measured | not measured | — | windowed Δcpu; 100 % = one core |
| idle 120 s — CPU p95 % | not measured | not measured | — | per-sample distribution |
| threads | not measured | not measured | — | median over the tree |
| open fds | not measured | not measured | — | `lsof -p`, median |
| child processes | not measured | not measured | — | descendants of the main process, median |
| power (top -stats power) | not measured | not measured | — | sum over the tree; not available without root on hosts where top omits it |
| active 60 s — RSS median | not measured | not measured | — | scrolling through 200 posts |
| active 60 s — CPU mean % | not measured | not measured | — | same scroll path for both |
| launch → process alive (median) | not measured | not measured | — | 3 runs |
| launch → first window (median) | not measured | not measured | — | 3 runs |
| steady state — RSS delta after 10 min idle | not measured | not measured | — | positive = growth since the first idle window |

## Conditions

- `PASS` **screen_unlocked** — CGSSessionScreenIsLocked=False; a locked session cannot show a frontmost window and window/first-paint detection returns 0 for every app
- `PASS` **native_bundle_present** — /Applications/Mattermost(ios).app version=0.71.0 build=371
- `PASS` **electron_bundle_present** — /Applications/Mattermost.app version=6.3.1 build=383788041691
- `BLOCK` **native_signed_in** — mm.servers hasSession=False for 'https://chat.canonical.com'
- `BLOCK` **electron_signed_in** — MMAUTHTOKEN for 'chat.canonical.com': absent from the cookie store
- `PASS` **same_workspace** — native=https://chat.canonical.com electron=['https://chat.canonical.com', 'https://chat.charmhub.io', 'http://mattermost-k8s:8065'] requested=https://chat.canonical.com
- `BLOCK` **channel_asserted** — --channel='': the operator asserts both clients sit on it
- `NOTE` **both_quit_before_launch** — running now: native=[85787]

## Biggest win and biggest loss

Not nameable: nothing was measured, so there is no win and no loss to report. Naming one would be an opinion, which is what this card forbids.

## What this does not measure

- **Interactive latency.** Neither client exposes time-to-first-paint or input-to-photon to an external sampler; "launch → first window" is a window count, not a rendered frame, and is labelled that way.
- **Memory pressure or swap.** RSS and ps' resident size are not the kernel's footprint under pressure; the existing `docs/perf/README.md` covers `footprint` for the Catalyst/webview question.
- **GPU and energy on battery.** `top -stats power` is sampled, not `powermetrics` (root); the power-source line in Conditions says whether the host was on AC.
- **Server-bound differences.** Both clients talk to the same workspace and the same channel, so network and server work are common-mode, but a server slow enough to dominate a window would hide client-side differences.
- **Long sessions.** One 10-minute steady-state window; multi-hour drift, notifications arriving and reconnects are out of scope.

## Harness verification

The harness is exercised independently of the two subjects, so a failure in a later run is a finding about the clients and not about an unproven tool:

- `python3 scripts/perf_compare.py selftest` — assertions on a synthetic four-process tree: tree walk finds the children, RSS/threads/fds are non-zero, the CPU delta and the `ps -o time=` parser are checked.
- `python3 scripts/perf_compare.py selftest --launch` — additionally times TextEdit's real launch with the same stopwatch used for both subjects (process visibility and first window), and asserts the process stopwatch fired.
- `scripts/perf_scroll.swift` — compiled with `xcrun swiftc` during `run`; the wheel events are posted with Core Graphics (`CGEvent.postToPid`) and the helper reports whether Accessibility allowed it rather than silently delivering nothing.
- Output of the self-test on this host: `docs/perf/selftest-2026-11-05.log`.

## Reproduce

```
scripts/perf_compare.py preflight --workspace <url> --channel <name>
scripts/perf_compare.py run --workspace <url> --channel <name>
scripts/perf_compare.py report            # re-render from the last run dir
scripts/perf_compare.py selftest --launch
```

| flag | meaning | default |
|---|---|---|
| `--workspace URL` | workspace both clients must have configured; defaults to the native app's active server | native's active server |
| `--channel NAME` | the channel both clients must be sitting on; recorded as an operator assertion (neither client exposes it to an external process) | none (a run without it blocks) |
| `--idle SECONDS` | idle window per subject | 120 |
| `--active SECONDS` | scripted-scroll window per subject | 60 |
| `--steady SECONDS` | long idle window for steady-state growth | 600 |
| `--launch-runs N` | launch repetitions, median reported | 3 |
| `--interval SECONDS` | RSS/CPU sample interval | 0.5 |
| `--window-size WxH` | both clients are resized to the same window before measuring | 1440x900 |
| `--scroll-delta PIXELS` | wheel distance per event in the active window | -8 |
| `--csv PATH`, `--md PATH` | artefact destinations | `docs/perf/2026-11-05.csv`, `docs/perf/2026-11-05-native-vs-electron.md` |

Exit codes: 0 measured, 66 blocked in the preflight (the artefacts are still written, with the reason), 65 a metric could not be taken, 64 bad arguments.

Raw per-sample numbers: `docs/perf/2026-11-05.csv`.
