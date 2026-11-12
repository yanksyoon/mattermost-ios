# t_a4e133f6 — a hung gate test left no xcresult in the run, so the hang had no stack

Card: *Gate pass: a hung gate test leaves no xcresult artifact, so the hang cannot be
diagnosed.* Follow-up to `t_a5321d5e` (the T31 cookie case that hung run `43240373846`'s
simulator gate leg); that card fixed the test, not the observability.

## 1. The gap, restated from the run

Run `43240373846`, job `131259733278` (test / ios-simulator), gate step: one case exceeded the
300 s allowance and the job log named the bundle XCTest had written for it —

```
/Users/runner/work/_temp/dd/Logs/Test/Test-Mattermost-2026.11.12_14-47-40-+0000.xcresult
```

— and the run's artifacts did not contain that bundle. The artifact that should have carried
it, `test-xcresult-ios-simulator` (`13956831755`, 1 595 023 bytes), held two bundles: the
timing pass's `Test-Mattermost-2026.11.12_15-07-30` and the platform pass's `…_15-10-37`.
The gate bundle was written at 14:47 and missing at upload time (15:13). Same run, catalyst
leg: `test-xcresult-catalyst` (`13956060868`) held all three (`14-48-04`, `14-54-32`,
`14-54-59`) — so the loss was not "the upload step never uploads the gate", it was the shared
directory.

## 2. Why the directory is not a record — measured here

All three passes used the same `-derivedDataPath "$RUNNER_TEMP/dd"` and let xcodebuild name
their bundles under `dd/Logs/Test`. That directory is a bounded test-log store, and writing a
new bundle into it evicts the oldest. Measured on this Mac (Xcode 26.6 / 17F113, Catalyst
destination, one fixed `-derivedDataPath`, each "pass" a real `xcodebuild test` run):

| write | what was in `Logs/Test` afterwards |
| --- | --- |
| pass 1 — the hanging fixture, no `-resultBundlePath` | `Test-…01-18-36` (the hung pass; `LogStoreManifest` records `totalNumberOfTestFailures => 1`) |
| pass 2 — a green pass, same derived data | `…01-18-36`, `…01-21-18` |
| pass 3 — another green pass | `…01-21-18`, `…02-05-46` — **`…01-18-36` is gone** |
| pass 4 — one more | `…02-05-46`, `…02-06-12` — **`…01-21-18` is gone** |

So a later pass in the same derived data removes an earlier pass's bundle: three passes write
three bundles, the directory keeps the newest two. That is the mechanism the workflow was
depending on, reproduced — on run `43240373846`'s catalyst leg all three happened to survive
(they were written within six minutes of each other), which is why the card's "probably
dropped" was worth measuring rather than asserting: the bound is real, its exact shape
(count vs size vs age) is not claimed here, and after this change nothing depends on it.

## 3. The change

`.github/workflows/release.yml`:

* each pass names its own bundle, outside the store:
  `$RUNNER_TEMP/gate-<leg>.xcresult`, `timing-<leg>.xcresult`, `platform-<leg>.xcresult`
  (`rm -rf` first, because xcodebuild refuses an existing result-bundle path);
* `Upload test diagnostics` lists those three paths instead of the
  `dd/Logs/Test/*.xcresult` glob, keeps `if-no-files-found: warn` (a pass that never ran
  leaves no file and must not fail the upload), and still collects the old
  `*.spindump` / `*.sysdiagnose*` / `*.log` globs;
* the new `self_test_gate_hang` dispatch input sets
  `TEST_RUNNER_MATTERMOST_GATE_HANG_FIXTURE=1` on the gate step ("0" on every push).

`MattermostTests/TGateHangFixtureTests.swift` is the deliberate hang, now env-gated: it does
nothing unless the flag is "1", and then it blocks past the allowance so XCTest writes the
same diagnostic a real hang writes. It reads both spellings of the variable — xcodebuild
strips the `TEST_RUNNER_` prefix on the way to a simulator test runner, while a Catalyst
process inherits it intact — so the switch cannot silently do nothing on one leg.

Nothing else moved: pass membership, `scripts/test_verdict.sh` and
`scripts/classify_platform_tests.sh` are untouched (their self-tests and
`scripts/test_annotation_selftest.sh` are green below).

## 4. Proof, part 1 — the run that was already red (fixture unconditional)

The first version of this change landed the fixture without a gate, on purpose: it committed
the workflow change and a 900 s sleep together so the next run would red itself and show
whether the bundle lands. That is run **`43267906492`** (`fe8be81`, push, 2026-11-12
17:17Z):

| before (run `43240373846`) | after (run `43267906492`) |
| --- | --- |
| `test-xcresult-ios-simulator` = `13956831755`, **1 595 023 bytes**, 2 bundles (timing, platform) | `test-xcresult-ios-simulator` = **`13970215256`**, **93 436 256 bytes**, 3 bundles: `gate-ios-simulator.xcresult`, `timing-…`, `platform-…` |
| `test-xcresult-catalyst` = `13956060868`, 3 bundles, no gate hang | `test-xcresult-catalyst` = **`13969525569`**, **114 550 839 bytes** |

Gate step annotations in that run (`gh run view 43267906492 --log`):

```
##[error]test (ios-simulator): TGateHangFixtureTests.testDeliberateHangNamesThisFrame
         (exceeded execution time allowance of 5 minutes)
##[error]test (catalyst): WebKit cannot start in this test host -
         TGateHangFixtureTests.testDeliberateHangNamesThisFrame hung
         (exceeded execution time allowance of 5 minutes) …
```

And on the downloaded artifact, which is the thing the card asked for:

```
$ xcrun xcresulttool get test-results activities \
    --path ios/gate-ios-simulator.xcresult \
    --test-id "TGateHangFixtureTests/testDeliberateHangNamesThisFrame()"
  "title" : "Test exceeded execution time allowance of 5 minutes"
  attachment: "2026-11-12 174520 +0000-Spindump_0_9134A5BC-….txt"

$ xcrun xcresulttool export attachments --path ios/gate-ios-simulator.xcresult \
    --test-id … --output-path ios-attach
  Exported 1 attachment … 26A895D2-971B-4BAF-A946-A1A5AA03A610.txt

$ grep -n testDeliberateHangNamesThisFrame ios-attach/26A895D2-….txt
161: @objc TGateHangFixtureTests.testDeliberateHangNamesThisFrame() + 56 …
162: TGateHangFixtureTests.testDeliberateHangNamesThisFrame() + 84
     (TGateHangFixtureTests.swift:15,16 in MattermostTests …)
```

A hang in the gate pass now lands a bundle whose spindump names the frame the test was in —
the property run `43240373846` could not offer, and the reason `t_a5321d5e` had to infer the
`await` from a missing log line.

## 5. Proof, part 2 — the permanent knob, after gating

`fe8be81` could not stay as it was: a test that always hangs reds every push. The gated
version is `3c5a77d`, and it is proven twice on the runner.

**A normal push skips the fixture.** Run **`43276993530`** (`3c5a77d`, push, 2026-11-12
18:10Z): both legs green — gate pass `Executed 2570 tests, with 15 tests skipped and 0
failures (0 unexpected) in 442.301 (622.129) seconds` on the simulator, `… 138.674 (157.515)
seconds` on catalyst (2570 = the 2569 of the previous run plus this case; 15 skipped = the 14
of the previous run plus this one). Inside `test-xcresult-ios-simulator` (`13973076045`) the
case is a node with `"nodeType" : "Test Case"`, `"result" : "Skipped"`,
`"durationInSeconds" : 0.0027` — the switch is off, and it costs 2.7 ms. Tag `v0.76.4` was
published and the package job succeeded on that run.

**The dispatch fires it.** Run **`43280063687`**, `gh workflow run release.yml --ref main -f
self_test_gate_hang=true` on the same SHA:

| leg | job | gate step | artifact |
| --- | --- | --- | --- |
| ios-simulator | `131415937751` | failed by design, `##[error]test (ios-simulator): TGateHangFixtureTests.testDeliberateHangNamesThisFrame (exceeded execution time allowance of 5 minutes)` at 19:44:31Z | `test-xcresult-ios-simulator` = **`13979430821`** (122 029 680 bytes) |
| catalyst | `131450820371` | failed by design, `##[error]test (catalyst): … TGateHangFixtureTests.testDeliberateHangNamesThisFrame hung (exceeded execution time allowance of 5 minutes) …` at 20:08:22Z | `test-xcresult-catalyst` = **`13978934228`** (113 713 315 bytes) |

The catalyst job `131415937716` first appeared as `cancelled` with no steps run — the
runner-capacity cancellation this pipeline has hit before (`t_a5321d5e`); `gh run rerun
43280063687 --job 131415937716` produced the row above. Both artifacts hold `gate-<leg>.xcresult`
plus `timing-<leg>` and `platform-<leg>`, and on both legs the gate bundle's activities reach
the hang:

```
$ xcrun xcresulttool get test-results activities --path gate-ios-simulator.xcresult \
    --test-id "TGateHangFixtureTests/testDeliberateHangNamesThisFrame()"
  "title" : "Test exceeded execution time allowance of 5 minutes"
  attachment "2026-11-12 194107 +0000-Spindump_0_EBD3CA64-….txt"

$ xcrun xcresulttool export attachments … --test-id "TGateHangFixtureTests/testDeliberateHangNamesThisFrame()"
$ grep -n testDeliberateHangNamesThisFrame 50D07BDE-….txt
160: @objc TGateHangFixtureTests.testDeliberateHangNamesThisFrame() + 56 …
161: TGateHangFixtureTests.testDeliberateHangNamesThisFrame() + 196
     (TGateHangFixtureTests.swift:49,16 in MattermostTests …)

# and the same on the catalyst bundle (gate-catalyst.xcresult, spindump 2026-11-12 200714 …)
173: TGateHangFixtureTests.testDeliberateHangNamesThisFrame() + 196
     (TGateHangFixtureTests.swift:49,16 in MattermostTests …)
```

Line 49 of the gated fixture is the `Thread.sleep` — the sample names the frame the test was
in, which is the property run `43240373846` could not offer. `tag and publish` and the package
job were skipped on this run: a red run publishes nothing, by design.

The earlier red run §4 (`43267906492`, fixture unconditional) also carried the catalyst side:
`test-xcresult-catalyst` = `13969525569` (114 550 839 bytes) holds `gate-catalyst.xcresult`
with the same activity and spindump (`2026-11-12 174015 …`).

## 6. Controls (what proves the self-tests did not move)

| command | result |
| --- | --- |
| `bash scripts/test_annotation_selftest.sh` | `SELF-TEST: PASS (27 checks)` |
| `bash scripts/classify_platform_tests.sh --self-test` | `SELF-TEST: PASS (4 checks)` |
| `python3 scripts/ci_plan.py --self-test` | `SELF-TEST: PASS (29 checks, 13 cases)` |
| `python3 -c 'yaml.safe_load(...)'` on `release.yml` | parses; six jobs; ten test steps; upload paths are the three named bundles plus the legacy globs |
| `xcodebuild build-for-testing` (ios-simulator, Xcode 26.6) | `** TEST BUILD SUCCEEDED **` — the gated fixture compiles |

## 7. Files

* `.github/workflows/release.yml` — per-pass `-resultBundlePath`, the upload list, the
  `self_test_gate_hang` input, the gate step's `TEST_RUNNER_…` variable.
* `MattermostTests/TGateHangFixtureTests.swift` — the env-gated deliberate hang.
* `docs/releasing.md` — "Where a hung gate's stack lives: one result bundle per pass".
* `docs/t_a4e133f6-build-note.md` — this note.

## 8. Residual risk, stated

* The fixture is one always-skipped case in the gate pass. It is a skip by design, not a
  coverage move — no class changes pass.
* A dispatch with the flag spends 300 s per leg before going red (two legs) and publishes
  nothing. It is a proof button, not something to wire into a schedule.
* The exact eviction rule of the `Logs/Test` store is not claimed (§2). The fix does not
  depend on it: the bundles live outside that directory now, and the upload names them.
