# t_fc31e308 — the unit lane read its own source under `~/Documents` and wedged there

Infrastructure card. **Test-harness and documentation only** — no product file changes semantics;
the one app-tree file touched (`MarkdownView.swift`) was reverted after the teeth probe (§4), so the
diff is `project.pbxproj`, two test files, one new test helper, `scripts/qa-test.py` and
`docs/test-plan.md`.

Host: macOS 26.3.1, Xcode as configured for this repo, Catalyst + `iPhone 16 Pro
(81A7F251-8B31-4945-8783-5A264C14B8D5)` simulator, derived data
`~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa` (outside TCC). Every measurement below was
taken **from the shared checkout** `/Users/yangsooyoon/Documents/yanks/code/mattermost-ios` — the
path that reproduces the wedge — not from a worktree.

## 1. What was broken

`MattermostTests/T56SelectionTests.swift:165` built a path from `#filePath`, walked up two folders and
opened two app sources:

```swift
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = try String(contentsOf: root.appendingPathComponent("Mattermost/UI/Native/..."), ...)
```

From the shared checkout that path is under `~/Documents`, so the test host's `open()` is a TCC
`kTCCServiceSystemPolicyDocumentsFolder` request. In a non-interactive run nothing answers the
prompt, so the call never returns: `sample` of the wedged host showed 100 % of samples in
`open()`, under `String(contentsOf:)`, at that test line. Both full-suite runs from the shared
checkout died on the *same case* (4681 and 8874 case lines in), and `scripts/qa-test.py` could only
report it as `RESULT: WEDGED, rc=124` after 240 s of silence.

The TCC db did carry a grant for `com.mattermost.ios`, but with a `csreq` bound to an earlier
ad-hoc signature; every test build gets a new cdhash, so the grant no longer covered the binary
asking. Passing runs and failing runs therefore differed by build, not by code — which is why the
same command passed at 01:06 and hung at 01:47 the same day.

## 2. The decision

Two layers, because the card asked for a fix that keeps the invariant *and* a harness that never
lets this class look like a hang:

1. **Give the scan a build product instead of the checkout** (removes the TCC dependency; keeps the
   invariant a real assertion on the real source text of the build under test):
   a new `PBXShellScriptBuildPhase` — **"Bundle Scanned Sources"** — on the `MattermostTests`
   target copies `MarkdownView.swift` and `MarkdownSelectionView.swift` into
   `$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/SourceScan/`, and
   `MattermostTests/SourceScan.swift` reads them from `Bundle(for:)`.
2. **Predict the class in `qa-test.py`**: when the checkout itself is inside `~/Documents`,
   `~/Desktop` or `~/Downloads` and any test target still builds a URL from `#filePath`, the runner
   refuses *before* building (exit 2, file:line named) instead of discovering the wedge 4 000 cases
   later. `--allow-tcc-unsafe-source-read` overrides with a warning.

`TARGET_BUILD_DIR`, not `BUILT_PRODUCTS_DIR`: this is an app-hosted test bundle, so the product is
built into the host's `Contents/PlugIns` (Catalyst) / `PlugIns` (iOS). Measured — the first attempt
used `BUILT_PRODUCTS_DIR` and wrote to a bundle that is not the one that runs; the test failed with
a path under `Build/Products/Debug-maccatalyst/MattermostTests.xctest` (not
`Mattermost.app/Contents/PlugIns/…`). The declared `outputPaths` use the same variable so
incremental builds re-copy when either source changes.

`T34FixtureLoader`'s source-tree fallback was removed for the same reason: it was dead code (the
three `Fixtures/*.json` are bundle resources on both platforms, verified by `ls`), and it was the
second `#filePath` read in the suite.

**Nothing was weakened.** The scan is the same two files, the same comment-stripping, the same three
forbidden strings (`NSAttributedString(html`, `NSAttributedString(data:`, `WKWebView(`). Two
assertions were added: the copy must look like Swift (>200 bytes, contains `import `) and must
contain the file's own declaration, so a wrong or truncated copy fails instead of passing every
"must not contain" check by accident.

## 3. Measurements (all from the shared checkout)

| command | result | log |
|---|---|---|
| `scripts/qa-test.py --platform mac --only-testing MattermostTests` | **2526 run / 9 skipped / 0 failed, rc=0, `RESULT: PASS`, 128 s** — no wedge, `testNoHTMLParserInEitherRenderer` passed in 0.008 s | `build/logs/tfc31-mac-unit.log` |
| `scripts/qa-test.py --platform mac --only-testing MattermostTests/T56SelectionTests` | 14 run / 0 skipped / 0 failed | `build/logs/tfc31-mac-t56b.log` |
| `scripts/qa-test.py --sim id=81A7F251-… --only-testing MattermostTests` | **2526 run / 8 skipped / 0 failed, rc=0, `RESULT: PASS`, 64 s** — the iOS lane from the same checkout (it wedged here too, per the card's comment) | `build/logs/tfc31-ios-unit.log` |
| `scripts/qa-test.py --sim id=81A7F251-… --only-testing MattermostTests/T56SelectionTests` | 14 run / 0 skipped / 0 failed | `build/logs/tfc31-ios-t56.log` |
| `scripts/qa-test.py --sim id=81A7F251-… --only-testing MattermostTests/T34PostListTests` | 30 run / 0 skipped / 0 failed (bundle-only fixture load) | `build/logs/tfc31-ios-t34.log` |

The suite count matches the pre-wedge worktree run from t_21b2f119 (2526 / 9 / 3-failures-then; the
three Catalyst metric failures were fixed by t_9f5de5d7 before this card), so nothing was skipped or
dropped to make this pass.

Copy freshness, byte-level: `cmp` of the bundled
`…/MattermostTests.xctest/Contents/Resources/SourceScan/MarkdownSelectionView.swift` against
`Mattermost/UI/Native/Channel/Markdown/MarkdownSelectionView.swift` is identical, and on iOS the
copies land at `Mattermost.app/PlugIns/MattermostTests.xctest/SourceScan/`.

## 4. Teeth, proven on the real files

1. **The scan catches a real violation.** Appended to the *actual* `MarkdownView.swift` (inside
   `#if false`, so the app still compiles):

   ```swift
   static func zqTeethProbe() -> NSAttributedString? {
       NSAttributedString(html: Data(), options: [:], documentAttributes: nil)
   }
   ```

   `--platform mac --only-testing …/testNoHTMLParserInEitherRenderer` →
   `XCTAssertFalse failed - MarkdownView.swift must not parse HTML`
   (`build/logs/tfc31-mac-teeth.log`), rc=65 in 38 s — a report, not a wedge. The bundled copy
   contained `zqTeethProbe` (grep count 1), which is the incremental-rebuild proof: the phase
   re-copied the changed source rather than scanning a stale copy. Probe reverted; `git status` for
   that file is clean.

2. **The guard refuses the class.** With a probe file
   `MattermostTests/ZGuardProbe.swift` containing `URL(fileURLWithPath: #filePath)`:

   ```
   [qa-test] REFUSING TO RUN
   these test lines build a path from their own source file and read it:
     MattermostTests/ZGuardProbe.swift:3: let zGuardProbeURL = URL(fileURLWithPath: #filePath)
   … pass --allow-tcc-unsafe-source-read.
   EXIT=2
   ```

   and the same call with `allow=True` warns and continues. The predicate was also run against the
   pre-fix sources: it matches exactly `T56SelectionTests.swift:165` and
   `T34PostListTests.swift:788` — the two lines the card named — with no false positives across the
   other 50 test files (`StaticString = #filePath` parameters do not match), and it is scoped: for a
   path outside `~/Documents`/`~/Desktop`/`~/Downloads` the guard reports "no wedge to predict" and
   does not gate. Probe file deleted.

## 5. What a maintainer has to know

- Adding a third scanned file means adding it to the build phase's `inputPaths`/`outputPaths` and
  `cp` lines **and** a `ScannedSource` case; a missing copy is a hard failure naming the path, never
  a skip.
- The phase runs before `Resources` on the test target and is sandbox-safe (`ENABLE_USER_SCRIPT_SANDBOXING
  = YES`): both inputs and both outputs are declared.
- Raw `xcodebuild test` (bypassing `qa-test.py`) gets the copy too — it is a build phase, not a
  wrapper feature — but it also gets no stall watcher and no guard. The guard is the harness's
  answer to the class; it is not a substitute for the derived-data rule in `docs/test-plan.md` §6.
- `scripts/qa-test.py --self-test` is unchanged and still the standing break-proof for the
  "failing test reports, does not hang" property.
