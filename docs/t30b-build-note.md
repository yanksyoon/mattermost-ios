# T30b build note — synchronized folders + the pbxproj single-owner rule

Card: `t_ada4dd50` (T30b). Unlocks every screen card from T31 on: a card adds files, and
`Mattermost.xcodeproj/project.pbxproj` is not touched.

---

## 1. What shipped

| File | What it is |
|---|---|
| `Mattermost.xcodeproj/project.pbxproj` | **3** `PBXFileSystemSynchronizedRootGroup`s (`Mattermost/UI/Native`, `MattermostTests`, `MattermostUITests`), each registered on its target; 48 hand-written `PBXBuildFile`s and 48 `PBXFileReference`s removed; 199 → **196** objects |
| `Mattermost/UI/Native/SheetHost.swift` | the shared sheet host `docs/component-map.md` §1 already designates — the one file the synchronized tree is seeded with |
| `MattermostTests/SheetHostTests.swift` | 15 unit tests for it (the presentation-queue rules) |
| `scripts/verify-dual-render-gates.sh` | gates 8–10 (§5 below) |
| `scripts/t30b-pbxproj-sync.py` | the one-shot migration, kept as provenance (asserts the pre-migration shape; re-running it fails its first assertion instead of doing something else) |
| `docs/parallel-work.md` | worktree usage, the file manifest / per-card ownership table, the shared-file single-owner rule, the fixed merge order |
| `docs/t30b-*.log` | the transcripts quoted below |

**No existing file moved.** `git diff --name-status a25b7eb~1 a25b7eb` is four modified/added
entries; every `Mattermost/**/*.swift` file is still at its old path (only its *registration* went
away).

---

## 2. Toolchain check: does this Xcode do synchronized folders?

`xcodebuild -version` → **Xcode 26.6 (17F113)**. Yes — and, worth recording because it is the part
that usually bites:

* **`objectVersion` stays 56.** Xcode 16+ writes 77 for *new* projects, but a `56` project accepts
  `PBXFileSystemSynchronizedRootGroup` and `fileSystemSynchronizedGroups` unchanged. The first probe
  build on this file (`build/logs/t30b-step1-cat.log`) succeeded with no version bump and no
  `compatibilityVersion` change, so this card did not rewrite the project's versioning.
* The synchronized group does **not** have to be the project root's folder: `path =
  Mattermost/UI/Native` with `sourceTree = "<group>"` resolves relative to the project directory and
  works for a nested tree.
* No `PBXFileSystemSynchronizedBuildFileExceptionSet` was needed: every file in the three trees
  belongs to exactly one target.

The path taken is therefore **the first one the card offered** (synchronized groups), not the
fallback in §5 of the card (pre-registering the whole manifest by hand). §7 records the one place
this card went *past* the letter of the scope, and why.

---

## 3. The unlock, demonstrated (`docs/t30b-pickup-demo-2026-10-25.log`)

Run in a throwaway worktree at the commit this note describes, so the numbers are the committed
file's. Every step prints the project file's sha256:

```
P0. the project file as committed
sha256: 925097d292b139600893ecd7360294f2c98848020d637ffa3e30076776707f08
object definitions: 196 | distinct ids: 196
PBXFileSystemSynchronizedRootGroup: 3
PBXFileReference entries: 78

P1. a brand-new file dropped into Mattermost/UI/Native/ — no project edit at all
sha256 before build: 925097d2…
build rc=0
** BUILD SUCCEEDED **
compare object: …/Objects-normal/arm64/T30bPickupProbe.o
compiled in the log: 3 mention(s)
sha256 after build : 925097d2…

P2. the same file, deliberately broken — the build must name it
build rc=65
…/Mattermost/UI/Native/T30bPickupProbe.swift:4:33: error: expected expression in list of expressions
** BUILD FAILED **
sha256 after failed build: 925097d2…

P3. the probe is deleted — the build goes green again, still no project edit
build rc=0
** BUILD SUCCEEDED **
sha256 after delete: 925097d2…

P4. the same thing in the synchronized *test* tree: a new unit-test file, no project edit
tests      : 1 run, 0 skipped, 0 failed
RESULT: PASS
sha256 after : 925097d2…
```

Why three steps and not one: a compile of a file nobody registered could in principle be a stale
object. So the same file is (1) compiled — an object is produced and named in the log — (2) broken on
purpose, which makes the build **fail naming that exact path**, and (3) deleted, which returns the
build to green. The project file's sha256 is identical at all four measurements, and
`git status --porcelain -- project.pbxproj` printed nothing at each step.

The UI-test tree was demonstrated the same way (a brand-new `MattermostUITests/*.swift` ran, 19 s,
`RESULT: PASS`, project file unchanged — `docs/t30b-uitest-tree-pickup-2026-10-25.log`), and the
permanent `MattermostTests/SheetHostTests.swift` is itself the same proof: 15 tests, added and run
with no project edit (`docs/t30b-sheethost-2026-10-25.log`).

---

## 4. What did not change

* `Mattermost/` is **not** synchronized: it mixes sources with `Info.plist`, `Mattermost.entitlements`,
  `PrivacyInfo.xcprivacy` and `Assets.xcassets`. Those keep their hand-written entries (78
  `PBXFileReference`s remain, down from 124).
* `Core/Native/NativeNavigation.swift` stays a hand-registered file: it is the route table, which the
  integration card owns (docs/parallel-work.md §6), and it is not a screen tree.
* No source file changed content except the two new files; the whole existing suite is unchanged and
  green (§8).

---

## 5. The rule, encoded (`scripts/verify-dual-render-gates.sh` gates 8–10)

| Gate | Assertion |
|---|---|
| 8 | the three trees are still `PBXFileSystemSynchronizedRootGroup`s, each **registered in its target's `fileSystemSynchronizedGroups`**, each carrying **git-tracked** files, `Mattermost/UI/Native/SheetHost.swift` still present, and **no `.swift` file in a synchronized tree also has a hand-written `in Sources` entry** |
| 9 | `project.pbxproj` defines **every object id exactly once** (the defect two concurrent editors produced twice on this board) and no group's `children` names an undefined id |
| 10 | this diff (`git diff <base>...HEAD` + the working tree) adds **no `PBXFileReference` for a source file**; the one allowance is the four non-source resources that stay outside the trees (`Info.plist`, `Mattermost.entitlements`, `PrivacyInfo.xcprivacy`, `Assets.xcassets`), and even those only with `--allow-pbxproj-resource-entry` |

Two gate-writing defects were found and fixed while proving these (the card's own standard: a test
that only ever passes is the defect T26-R was repaired for):

1. The first version delimited pbxproj objects with a lazy regex over `};`; with `re.S` it matched
   **one object from line 10 to line 189** and reported the sync group under the wrong id. Replaced
   with a brace-counting scanner that skips quoted strings (`pbx_objects`).
2. Gate 8's first "is it tracked by git" run failed *correctly* but for the wrong reason (the seed
   file was still untracked at that moment) — which is exactly the check working; it passes from the
   commit on.

### 5.1 Proof the checks fail when broken (`docs/t30b-gate-probes-2026-10-25.log`)

Each break is a real edit run in a throwaway worktree, then reverted:

```
D0 baseline                                   RESULT: PASS
D1 drop the app target's fileSystemSynchronizedGroups entry
   FAIL  Mattermost/UI/Native is a synchronized group (C0…01) but target F5…01 does not list it in
         fileSystemSynchronizedGroups — its files would not be built at all        → RESULT: FAIL
D2 hand-register a file the folder already carries
   FAIL  synchronized-tree file(s) also registered in the project file (duplicate compile): SheetHost.swift
   FAIL  SheetHost.swift: a .swift file belongs in a synchronized folder, not in …pbxproj → RESULT: FAIL
D3 define an object id twice (the two-editor defect)
   FAIL  defines the same object id more than once: ['C00000000000000000000001']
         (two workers wrote the same id; one of the two entries is silently dropped) → RESULT: FAIL
D4 a card registers its new screen by hand, against main
   FAIL  FakeScreenView.swift: a .swift file belongs in a synchronized folder …        → RESULT: FAIL
D5 an unlisted resource entry                                   → RESULT: FAIL (not in the allowance)
   a listed resource entry, no flag                              → RESULT: FAIL (needs the flag)
   the same diff with --allow-pbxproj-resource-entry             → RESULT: PASS
D6 restored worktree                                          RESULT: PASS
```

Gate 10's honest limit, stated in the script: it audits `git diff <base>...HEAD` plus the working
tree, so a card that never commits is not audited — the integration card runs it again at merge.

---

## 6. The seeded file: `Mattermost/UI/Native/SheetHost.swift`

The card's instruction was to seed the folder with the one file the component map already designates,
and to create no screen stubs. So `SheetHost.swift` is *not* a stub of a screen: it is the shared
presentation mechanism every modal screen would otherwise write for itself.

It exists because **UIKit presents exactly one sheet per view and silently drops a second request**.
Sixteen cards each owning `@State private var isPresenting…` would reproduce that failure sixteen
ways. The model (`SheetHostModel`) makes the decision explicit and testable:

* `present(_:)` while nothing is up → shows it;
* the same route again → no-op (a double tap must not reset the sheet);
* a different route while one is up → **queued, latest wins** (a FIFO of sheets the user did not ask
  for in that order is worse than one);
* `dismiss()` promotes the queued route in the same transition;
* `dismiss(id:)` scoped to a route that is no longer up does nothing (the late-`onDismiss` case);
* a system dismissal (`applySheetChange(nil)`, which is what `.sheet(item:)` writes on a swipe)
  promotes the queue exactly like `dismiss()` — the reason the state is not a public `var`.

`SheetRoute` carries `id` + `presentationDetents` and nothing about screens, so no card's screen is
pre-declared here. 15 tests (`MattermostTests/SheetHostTests.swift`), all passing.

Nothing presents through it yet — the first adopters are T31 (auth) and the modal screens T34/T37/T41.
That is stated in the file and in `docs/parallel-work.md` §6 rather than pretended otherwise.

---

## 7. The one deliberate step past the letter of the scope: the test trees

Scope §1 asks for `Mattermost/UI/Native/` on the Mattermost target. This card also synchronized
`MattermostTests/` and `MattermostUITests/`, because **a screen card ships a screen *and* its tests**:
with only the app tree synchronized, every card from T31 on would still have to edit
`project.pbxproj` for its test file, i.e. the single-owner rule in item 4 would be violated by
construction, and gate 10 (which fails a card's diff that adds a `PBXFileReference`) would fail every
honest card. The transform is identical, the proof is identical (§3 P4/P5), and it is recorded here
rather than done silently. If the reviewer wants the literal scope only, reverting the two test
groups is a 3-line change to `scripts/t30b-pbxproj-sync.py` plus the same for the gate's
`SYNC_TREES`.

---

## 8. The suite

### 8.1 Mac Catalyst, whole `MattermostTests`

```
run        : t30b-cat-final
outcome    : finished (xcodebuild rc=0, 35s)
tests      : 599 run, 4 skipped, 0 failed
RESULT: PASS
```

(`Executed 599 tests, with 4 tests skipped and 0 failures`; the 15 new `SheetHostTests` are in there.
T30's baseline was 584, so 584 + 15 = 599 — no test disappeared.)

### 8.2 iOS Simulator, whole scheme (unit + UI)

```
run        : t30b-ios-final2
outcome    : finished (xcodebuild rc=0, 400s)
tests      : 15 run, 1 skipped, 0 failed          # MattermostUITests
RESULT: PASS
```

with the unit phase of the same run reporting `Executed 599 tests, with 3 tests skipped and 0
failures`, and `** TEST SUCCEEDED **` as the run's verdict
(`docs/t30b-full-ios-2026-10-25.log`). Log: `build/logs/t30b-ios-final2.log`.

The skips are the pre-existing, self-declared ones, not new:

| Skipped | Reason |
|---|---|
| `MattermostUITests.testSSOReachesIdentityProviderWithoutCertificatePrompt` | needs the self-signed TLS stub on :8443, which is not running in this session (`XCTSkipUnless`) |
| `MattermostTests.MentionPollerTests.testLiveMentionsFetch_optIn` | opt-in live server |
| `MattermostTests.SelfSignedTrustTests` ×2 | self-signed fixture |

T30's baseline on this host was 584 unit + 15 UI; now 599 unit (584 + 15 `SheetHostTests`) + 15 UI —
no test was lost, and nothing outside the two new files changed.

### 8.3 Release build (whole-module optimisation, no DEBUG)

```
xcodebuild build -configuration Release -destination 'platform=macOS,variant=Mac Catalyst'
… ** BUILD SUCCEEDED **        (rc=0)
```

`SheetHost.swift` is compiled in that configuration too — the shared sheet host is not behind
`#if DEBUG`, and nothing in this card's change does anything different in Release
(`build/logs/t30b-release-cat.log`).

---

## 9. Reproducing

```bash
# 1. the unlock, by hand (in a throwaway worktree)
git worktree add --detach .worktrees/t30b-pickup HEAD
cd .worktrees/t30b-pickup
shasum -a 256 Mattermost.xcodeproj/project.pbxproj
printf 'import SwiftUI\nstruct Probe: View { var body: some View { Text("x") } }\n' \
    > Mattermost/UI/Native/T30bPickupProbe.swift
xcodebuild build -project Mattermost.xcodeproj -scheme Mattermost \
    -destination 'platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath ~/Library/Developer/Xcode/DerivedData/t30b-pickup
shasum -a 256 Mattermost.xcodeproj/project.pbxproj      # identical
find ~/Library/Developer/Xcode/DerivedData/t30b-pickup -name 'T30bPickupProbe.o'
rm Mattermost/UI/Native/T30bPickupProbe.swift
# the full transcript, including the deliberately-broken build: docs/t30b-pickup-demo-2026-10-25.log

# 2. the gate, passing
scripts/verify-dual-render-gates.sh

# 3. the gate, failing on purpose (each break reverted immediately):
#    docs/t30b-gate-probes-2026-10-25.log has the five breaks and the allowance path

# 4. the suites
scripts/qa-test.py --platform mac --label t30b-cat
scripts/qa-test.py --platform ios --sim id=81A7F251-8B31-4945-8783-5A264C14B8D5 --label t30b-ios
```

---

## 10. Limitations

1. **`objectVersion` stays 56.** That is what the toolchain accepted here; a project that moves to 77
   (Xcode's default for new projects) has not been tested by this card.
2. **Gate 10 is diff-based by design.** It cannot see a registration added by a commit that never
   reaches the branch under test; the integration card re-runs it per merge.
3. **The ownership table in `docs/parallel-work.md` is a convention, not a compiler rule.** The
   mechanical half (no hand registration, no duplicate ids, no reverted folder) is gated; a card
   editing another card's view file still compiles.
4. **The synchronized trees are Git-dependent.** They work because git carries the files; a build
   from a directory where the tree is empty (e.g. an export that drops nested folders) has nothing to
   compile — gate 8's *"has git-tracked files"* check is the tripwire for that.
5. **No Xcode GUI verification.** `xcodebuild` (which is what CI and every card here uses) parses and
   builds the project; whether the folder renders identically in the Xcode navigator was not
   asserted, because it cannot be automated on this host.

---

## 11. Commit

`a25b7eb` — `build(t30b): synchronized folders for the native UI + test trees, so screen cards never
edit project.pbxproj (T30b)`
