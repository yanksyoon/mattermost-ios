# C2-AV F1 — the `Button` → gesture restructure, measured, and restated as hardening

Card `t_c297b96a`, the follow-up to F1 of `t_0c520c78` (`docs/t_0c520c78-c2-validation.md` §5 F1).
Subject: C2 of `t_8f9f5449` (`t_2fa3bbe1`, merged as `7f38b14`), whose headline justification was
causal — the three list hosts wrapped `PostRowView` in a `Button`, "a `Button` inside a `Button`'s label
is not a reliable tap target in SwiftUI", so the author tap never fired, and the restructure to
`VStack` + `.onTapGesture` is what makes it fire.

**Verdict: the causal claim does not reproduce anywhere measurable here; the restructure is
hardening, and the documentation now says so.** Nothing in product code changed. The measurement is
three hosts, three runtimes, plus the element tree the runtime actually publishes; the restatement is
in spec §3, build note §2 and `docs/parity.md`'s T39/T42 C2 clauses.

---

## 0. What the card offered, and what was measurable

The card gave two deliverables: (1) measure the claimed failure where "not reliable" plausibly bites —
real device, VoiceOver, or a hit-test probe that shows the inner button losing the tap — and add the
test that fails on the pre-C2 shape; or (2) if it cannot be reproduced anywhere available, restate the
restructure as hardening in spec §3, build note §2 and `docs/parity.md`.

| route | available? | what was done |
|---|---|---|
| real device | **no** — `xcrun devicectl list devices` answers `No devices found.` | none |
| VoiceOver activation | **no automation hook.** XCUITest sends synthesised HID events, which bypass VoiceOver's focus/activation path; no public API lets a test activate an element *as VoiceOver would*. What VoiceOver would focus **is** measurable, and is measured below (element identity, type, hittability, frame). | element-tree probe (§3) |
| hit-test probe | **yes** — the shipped live tests tap the author control itself and assert *which* action ran (the profile sheet carrying the server's own `username`, not the row's jump). Restoring the pre-C2 container is the probe: if the inner button lost the tap, the row's jump would open the post instead and the sheet assertion would fail. | pre-C2 mutation on all three hosts (§2) |

So the claim was measured on the only runtime available — the simulator — on three OS versions, with
the strongest instrument the target has: an element tap whose outcome is read back from the server.

---

## 1. Tree, environment, method

| fact | value |
|---|---|
| tree under measurement | `7f38b14` (`7f38b145115785ce725248656c252a9b193b1af9`), detached in `.hermes/kanban/boards/mattermost-ios/workspaces/t_c297b96a/repro`; `git status` clean before and after every run |
| mutation | `docs/t_c297b96a-prec2-mutation.py` (the diff it applies is §5): the pre-C2 `Button` container restored in `SearchResultRowView`, `ActivityRowView` and `PostCollectionView`'s row, **with C2's `onShowProfile` callback still wired** and every C2 accessibility modifier kept. Exactly one variable changes: the container. |
| probe | a temporary `print` in `T5449ListProfileUITests.tapAuthorHeader` recording `elementType`, `identifier`, `isHittable`, `frame` and `row.debugDescription`; reverted before the tree was re-verified (it is not part of any shipped test) |
| runner | `scripts/qa-test.py` (stall-guarded), derived data `~/Library/Developer/Xcode/DerivedData/mmios-t_c297b96a` (private to this card: other board cards were running XCTest against the shared `mattermost-ios-qa` directory at the same time, and an earlier attempt that used the shared directory had its test runner killed with `signal kill` mid-test) |
| server | real Mattermost 9.11.19 at `127.0.0.1:8065`, `perfprobe` + `t41buddy`, channel `#t429-tap` (the suite's own fixture; each test seeds its own post) |

The four-run baseline on the **shipped** shape, same sim and same build, is in §2 row 1: the suite is
green, so a red run below would have been the mutation's answer, not the environment's.

The logs named in §2 are committed with this note (`docs/t_c297b96a-*.log`), unedited except that each
is the runner's own output; the xcresult bundles they come from are under
`~/Library/Developer/Xcode/DerivedData/mmios-t_c297b96a/TestResults/`, one per run label.

---

## 2. Runs

Every count is the runner's own `Executed N tests` line from that run's log.

| # | shape | runtime | tests | result | log |
|---|---|---|---|---|---|
| 1 | **shipped** (`VStack` + gesture) | iPhone 17 Pro, iOS 26.5 (`23F77`), `6B6991BF` | all four `T5449ListProfileUITests` | **4 run / 0 failed / 0 skipped**, 118.911 s | `t_c297b96a-pristine-iso.log` |
| 2 | **pre-C2** (`Button` label) | same | search, saved, mentions | **3 run / 0 failed / 0 skipped**, 82.015 s | `t_c297b96a-prec2-ios265.log` |
| 3 | **pre-C2** | iPhone 15 Pro, iOS 17.0.1 (`21A342`), `146D23D9` | search, saved, mentions | **3 run / 0 failed / 0 skipped**, 78.627 s | `t_c297b96a-prec2-ios17.log` |
| 4 | **pre-C2** | iPhone 16 Pro, iOS 18.3.1 (`22D8075`), `81AD82E4` | search, saved, mentions | **2 run / 0 failed / 1 infrastructure failure**, 368.804 s — §2.1 | `t_c297b96a-prec2-ios183.log` |
| 5 | **pre-C2** | iPhone 16 Pro, iOS 18.3.1, `81A7F251` | search (the row 4 lost) | **1 run / 0 failed / 0 skipped**, 59.022 s | `t_c297b96a-prec2-ios183-b.log` |
| 6 | **pre-C2, repeated** | iPhone 17 Pro, iOS 26.5 | search × **3 iterations** (`-test-iterations 3`) | **3 run / 0 failed / 0 skipped**, 101.877 s | `t_c297b96a-prec2-ios265-iter3.log` |

Per-test times, pre-C2: search 30.786 s / saved 23.415 s / mention 27.814 s on 26.5; 29.782 / 22.621 /
26.224 s on 17.0.1; search 59.022 s on 18.3.1 — the same order as the shipped shape's 33.336 / 24.514 /
23.778 s in run 1. A resolved-but-swallowed tap would not merely fail; it would open the post and fail
on the sheet assertion, so the timing match is a second signal that the author tap ran its own action.
Run 6 exists because the claim is about **reliability**, not about a single tap: three consecutive
iterations of the same test on the same mutated build, all green.

The row's own tap is measured in the same runs as the author tap: the search test dismisses the
profile, taps the row at `(0.55, 0.8)` — away from the author header — and asserts `postFocus.<id>`
appears. It passes with the pre-C2 container too, so both handlers fire in that shape.

### 2.1 Run 4's one failure is not the mutation

The search test failed at `T5449ListProfileUITests.swift:276` — the **sign-in** field, before any row
exists — with `Failed to get matching snapshots: Error getting main window kAXErrorServerNotFound`,
after `Setting up automation session` had taken 50.5 s on a freshly created simulator clone and the
runner logged `Unable to monitor animations` / `Unable to monitor event loop`. A retry on that same
clone never got as far as launching the runner (`Failed to launch app … com.mattermost.iosUITests.xctrunner
… (ipc/mig) server died`, `NSMachErrorDomain -308`), so the clone's automation services were the
problem, not the row. The test was re-run on the standard iPhone 16 Pro simulator of the same runtime
(run 5) and passed in 59.022 s; the two hosts that did run on the clone (saved, mentions) passed.
Run 4 is reported here rather than hidden, and is not counted as either a pass or a failure of the
claim.

---

## 3. What the runtime publishes for the author control inside the pre-C2 row

This is the part VoiceOver would consume, and the reason the failure has nowhere to hide: on the
pre-C2 tree the row is a `Button`, and inside its label the author's avatar and name are **separate
`Button` elements with their own frames**, hittable, and they keep their identifiers.

iOS 26.5, mentions host (`t_c297b96a-prec2-ios265.log:437–455`):

```
[t_c297b96a-probe] author elementType=9 identifier=post.ctpycek4wpg7ix79c5kk796mje.avatar hittable=true frame=(28.0, 286.0, 36.0, 36.0)
[t_c297b96a-probe] row tree:
Attributes: Button, {{0.0, 248.7}, {402.0, 119.3}}, identifier: 'activity.row.ctpycek4wpg7ix79c5kk796mje', label: '#t429-tap, unread message, Buddy Profile: @perfprobe …'
Element subtree:
 →Button, identifier: 'activity.row.ctpycek4wpg7ix79c5kk796mje'
    …
    Other, identifier: 'post.ctpycek4wpg7ix79c5kk796mje'
      Button, {{28.0, 286.0}, {36.0, 36.0}}, identifier: 'post.ctpycek4wpg7ix79c5kk796mje.avatar', label: 'Buddy Profile profile'
      Button, {{74.0, 286.0}, {96.3, 18.0}}, identifier: 'post.ctpycek4wpg7ix79c5kk796mje.author', label: 'Buddy Profile'
```

(`elementType` 9 is `XCUIElement.ElementType.button`.) The same nested structure is published on
18.3.1 (`t_c297b96a-prec2-ios183.log:206–214`) and on 17.0.1. So on every runtime measured, the
pre-C2 shape does **not** make the author control an unreachable or swallowed target: it is a
first-class button inside the row button, and its own action — the profile sheet, whose `username` the
test reads back from `GET /users/{id}` — is what runs.

---

## 4. Why the shape is kept anyway (and what the docs now say)

Two things are true at once, and the documentation had only the first half:

* **The causal claim is false where measured.** "Not a reliable tap target", "never fired or fired the
  row's jump" is a prediction about SwiftUI's nested-control hit-testing; it is contradicted by every
  run in §2 and by the tree in §3.
* **The shape still earns its place as hardening.** With the row a gesture and the author an inner
  `Button`, the row's jump and the author's tap are *different kinds of handler on different
  controls* — the inner controls stay reachable by construction rather than by however SwiftUI
  resolves nested buttons on the runtime in hand, and the row's single combined accessibility element
  plus its `Open profile` action become expressible at all (`T8e`: a 60-row list must not become 180
  VoiceOver stops). It is also the shape `ReactionBarView` already uses and documents in this repo.

What that means for the record, and what was edited:

| file | change |
|---|---|
| `docs/t_8f9f5449-profile-popover-parity.md` §3 | the causal sentence is replaced by the measurement and the hardening rationale; §3's two refuted asides are corrected in the same edit (§6 below) |
| `docs/t_8f9f5449-c2-build-note.md` §2 | "why it is not a style change" becomes "not a style change, and not a measured fix": the paragraph asserts what was measured instead of the prediction |
| `docs/parity.md` T39 and T42, the `T5449-C2` clauses | "a `Button`-in-`Button` label made the author tap unreachable" becomes the hardening statement, with the runtimes measured |

No product code, no test, and no identifier changed. The shape stays exactly as C2 shipped it.

---

## 5. The mutation, verbatim

```diff
--- the shipped row (three hosts): a plain VStack with a gesture
+++ the pre-C2 row (measurement only): the same VStack inside Button(action: onOpen)
@@ Mattermost/UI/Native/Search/SearchView.swift (SearchResultRowView)
     var body: some View {
-        VStack(alignment: .leading, spacing: 2) {
+        Button(action: onOpen) {
+        VStack(alignment: .leading, spacing: 2) {
         …
-        .contentShape(Rectangle())
-        .onTapGesture { onOpen() }
+        }
+        .buttonStyle(.plain)
         .accessibilityAddTraits(.isButton)

@@ Mattermost/UI/Native/Activity/MentionsView.swift (ActivityRowView)  — same edit, `Button(action: onOpen)`
@@ Mattermost/UI/Native/Search/SavedPinnedViews.swift (PostCollectionView's row)
-                    VStack(alignment: .leading, spacing: 2) {
+                    Button { open(row) } label: {
+                    VStack(alignment: .leading, spacing: 2) {
                     …
-                    .contentShape(Rectangle())
-                    .onTapGesture { open(row) }
+                    }
+                    .buttonStyle(.plain)
                     .accessibilityAddTraits(.isButton)
```

`onShowProfile:` (the C2 callback), `.accessibilityElement(children: .combine)`, the label, the hint
and the `Open profile` action are untouched in all three — the rows differ only in what the container
is, which is the variable the claim is about. `SavedPinnedViews.swift` is one view used by both the
Saved tab and the pinned sheet, so the saved test in §2 covers the mutation for the pinned row too
(the pinned host's *push* is a separate, still-unmeasured site — F4 of `t_0c520c78`).

---

## 6. Corrections made in §3 while restating it

The restatement made three neighbouring lines in spec §3 untenable, and leaving them would have
re-broken the same section, so they were corrected in the same edit and are recorded here:

1. **"under `.combine` the inner `post.<id>.author` button is not an addressable accessibility
   element"** — refuted by §3 above (and by C2's own first live run, build note §6.2/§6.3): the inner
   buttons are `Button` elements with identifiers inside a `.combine` row on every runtime measured.
2. **"the test cannot address `post.<id>.author`; it taps the row by a coordinate"** — the shipped tests
   lift `post.<id>.avatar` / `.author` and tap them; the coordinate tap the spec prescribes
   (`0.18, 0.22`) is the one C2 measured to land in the channel line and open the post.
3. **"the avatar and the name stay the only real `Button`s"** — true of the search and mentions rows,
   not of the saved/pinned row, which also carries `savedPosts.remove.<id>` (pre-existing) and, when
   the list knows one, a `channel.<id>` element (F5 of `t_0c520c78`).

---

## 7. Limits, stated so this is not over-read

* **No physical device, so the device case is genuinely unmeasured.** If a device ever shows the
  pre-C2 tap failing, this document is where the counter-measurement goes; until then the causal claim
  has no evidence anywhere in this repo.
* **VoiceOver's activation path was not exercised** (no automation hook, §0). What was measured is what
  VoiceOver focuses — element identity, type, hittability and frame — plus the tap resolution. A
  VoiceOver-only defect that leaves the element tree intact cannot be ruled out by this note; it is
  also invisible to every test this target can write.
* **Simulator runtimes only**: 26.5, 18.3.1, 17.0.1 (the deployment floor). One app build per runtime;
  the host was loaded with other board work throughout (other cards ran XCTest suites against the
  shared derived-data directory at the same time), which is why one run's failure was triaged in §2.1
  rather than counted.
* **The mutation is one variable, not a reconstruction.** It restores the container and keeps C2's
  callback and accessibility, so it answers "is the restructure what makes the tap fire", not "what
  did the app do before C2 existed" (the author tap could not exist before C2 — `onShowProfile` did not
  exist).
* **Rows only.** The push-inside-the-lookup-sheet site, the `Open profile` custom action (XCUITest
  cannot invoke custom accessibility actions) and the pinned host's push remain as C2's validation
  left them (F4).
