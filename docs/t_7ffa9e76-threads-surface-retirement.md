# `Surface.threads` is not a switch: retire it (finding F1 of `t_8f9f5449`)

**Status: decided 2026-10-29 by `mmios-architect` (card `t_7ffa9e76`). Not built.** The mechanical
removal + the new gate are card `t_cdcc1f38` (`mmios-ios`, parented on `t_07216319` — see §8.4 for
why that parent). The four same-class findings this card uncovered are card `t_39ea6115`.

Tree measured at `1577337` (`main`, clean working tree), 2026-10-29.
Harness contract: `docs/dual-render.md`. The finding: `docs/t_8f9f5449-profile-popover-parity.md`
§2.1 and §8 (F1).

> **Decision in one sentence.** `Surface.threads` is **retired**, not gated: the thread pane is a
> sub-region of the pane host (`.channelView`), so its render mode *is* the pane host's mode — a
> `web` thread pane would be a dead end with no webview behind it, and the thread route's real web
> fallback (the pane's webview, driven by the web app's own router) is already governed by
> `.channelView` and needs no second switch.

## 1. What was measured (not inherited)

The card's premise was inherited from the parent. It reproduces exactly:

```
$ grep -rn "resolvedMode(for: \.threads)" --include=*.swift Mattermost/
(no output — zero call sites)
```

For every one of the 12 cases, at least one production call site that reads the case:

| `Surface` | consulted at (app target, `Mattermost/`) |
|---|---|
| `.auth` | `UI/Native/Auth/LoginView.swift:47` — `SurfaceHost(.auth)` |
| `.sidebar` | `UI/Native/NativePanePlaceholders.swift:43` |
| `.channelView` | `UI/ContentView.swift:33` — `SurfaceHost(SurfaceDefaults.paneHostSurface)`; also `RootView.swift:47`, `NativeNavigation.swift:345` (the same name, by way of the one constant) |
| `.composer` | `UI/Native/Channel/ChannelView.swift:734`, `UI/Native/Thread/ThreadView.swift:52` |
| `.threads` | **none** |
| `.search` | `UI/Native/Search/SearchView.swift:36`, `SavedPinnedViews.swift:32,69`, `ChannelView.swift:1008` |
| `.profile` | `ChannelView.swift:746` — **read and discarded**, see §2.2 |
| `.activity` | `UI/Native/Activity/MentionsView.swift:32` |
| `.settings` | **none** — `SettingsView` is presented unconditionally (`RootView.swift:180,229`) |
| `.channelInfo` | `ChannelSidebarView.swift:234`, `ChannelView.swift:981` |
| `.calls` | `ChannelView.swift:1021` |
| `.plugins` | **none** |

So F1 is not a one-case hole; **four** cases have no effect on screen (§2.2). This card decides
`.threads` and records the other three with their own dispositions, because the fix they need is a
product decision, not the same edit.

The parent body's type names were corrected on the card already:
`ThreadPaneContent` (one thread) and `GlobalThreadsPaneContent` (the list) live in
`UI/Native/Thread/`; `NativeThreadsPaneView` (`UI/Native/NativePanePlaceholders.swift:369`) is the
route switch between them. There is no `ThreadListPaneView`.

## 2. Why the thread pane cannot be a surface

### 2.1 The three conditions (the rule this card adds to the harness contract)

A `Surface` case is a *switch key*. For the switch to mean anything the region must be renderable
**two ways while it is on screen**:

1. **a native card** exists, or is landing with a named card (the existing `-AV` route);
2. **a web path exists at the moment that region can be on screen** — a webview that is actually
   mounted, not one that pane ownership destroyed;
3. **at least one production call site consults it** — otherwise the key is a decoration.

`.threads` fails (2) and (3). (1) it has: T36's card is real and validated — `docs/parity.md` T36,
`docs/t55-revalidation-build-note.md` §3 records `.threads` **PASS** in the pane-host re-validation.
Retirement withdraws no evidence about the *region*; it stops advertising an independent switch.

### 2.2 Condition (2) is structural, not an accident

`NativeShellView` — the only thing that can mount a thread pane — is the **native branch of the pane
host**:

```swift
// Mattermost/UI/ContentView.swift:33
SurfaceHost(SurfaceDefaults.paneHostSurface) {
    NativeShellView(server: server, navigation: navigation)   // ← the thread pane lives in here
} web: {
    WebPaneHost(server: server, viewStore: viewStore)
}
```

Therefore:

* when `.channelView` resolves **web**, no native shell is mounted, `NativeThreadsPaneView` cannot be
  reached, and the reader's thread is the web app's own RHS inside the pane webview;
* when `.channelView` resolves **native**, the shell is mounted and
  `docs/dual-render.md` §12.2/§12.3 apply: pane ownership **destroys** the per-server `WKWebView`
  (destroy, not park). There is no web page behind the native shell to fall back to.

So the two configurations of `.threads` are:

| pane host | `.threads` today | what a *gated* `.threads` would show |
|---|---|---|
| `web` | ignored | the shell is not mounted — the flag cannot be observed |
| `native` | ignored | a note saying a web app is drawing the thread, **over a released webview** |

There is no third row. Gating adds a state that is either unobservable or false, which is the same
defect class the registry ledger already names for the composer ("a dead `\"Message input — web\"
placeholder while `.channelView` is pane-owning, i.e. a read-only workspace",
`SurfaceDefaults.nativeApprovedSurfaces` doc, `RenderMode.swift:97`).

### 2.3 A thread is a destination, and that is the decisive difference from `.composer`

`.composer` stays a surface even though its `web` state is a dead placeholder too. The difference is
what a dead end costs the reader:

* the composer's `web` state is a **strip** at the bottom of a screen that still works (the post
  list, the follow bell, the reactions are all there). A wrong flag costs a read-only pane;
* a thread is a **route**. It is entered from a notification tap (`NotificationWorker`), a permalink
  (`DeepLinkRouter`), a row's reply line (`PostRowView`) or the Threads tab. A `web` thread pane hands
  a reader who just tapped a push notification a full-screen note and no conversation. That is
  strictly worse than the state F1 reports (a thread that draws natively regardless of the flag).

### 2.4 The web fallback for a thread route already exists — and it is not `.threads`

The card asked what the web fallback *is*. It is the pane's webview, and the switch that owns it is
`.channelView`:

```swift
// Mattermost/Core/Native/NativeNavigation.swift:339-346
/// Whether deep links and notification taps should be diverted here instead of the webview's
/// SPA router. … flipping the surface back to `web` (the escape hatch) immediately restores the
/// web path — no stale flag.
var acceptsNativeRouting: Bool {
    resolver?.resolvedMode(for: SurfaceDefaults.paneHostSurface) == .native
}
```

`acceptsNativeRouting == false` hands the URL back to the web app's SPA router, which opens the
thread in the RHS of the pane webview — the web app's thread screen is a region of `.channelView`'s
webview, which is why `docs/dual-render.md` §4 lists it as "S13 Thread RHS + global threads" under the
channel view's web app and not as a webview of its own. **The web fallback is implementable, already
implemented, and keyed on the pane host.** `.threads` never owned one.

### 2.5 The cost of gating T36's live suite (card requirement 2)

`MattermostUITests/T36-ThreadsUITests.swift` launches with `shell=native`, `auth=native`,
`sidebar=native`, `composer=native` and **no** `threads` flag (l. 761-769), so `.threads` resolves
`web` by compile-time default (`nativeApprovedSurfaces` does not list it). The suite asserts the pane
itself: `threadPane` (l. 357, 455, 807), `threadPostList` (l. 162, 809), `thread.post.<id>`
(l. 164, 177, 226, 235, 872). A `web` gate inside `ThreadPaneContent` would replace all of that with a
note and redden the suite.

The card allowed two repairs: add `-surfaceMode threads=native` to the suite, or default `.threads`
to `native` (a registry change, which is an `-AV` claim). Both are worse than retirement:

* **the flag** hides the surface from every future reader — exactly the T429 lesson the C1 card
  cites ("that flag hides this class of defect"), and it would make the suite pass while the
  *shipped* configuration (no flags) still showed the note;
* **the registry entry** would claim an `-AV` for a switch that can never be turned off in any
  configuration a real reader reaches, and it changes `testOnlyTheApprovedRegistryDefaultsToNative`
  and the approval ledger for no rendering benefit.

Retiring `.threads` needs **no** change to the T36 suite at all. That is the strongest argument for
option 2 in the card: the suite's launch line is not a defect, it is the same absence this card
records.

Local discrepancy, flagged rather than smoothed: the file has **five** `func test…` declarations
today (l. 93, 194, 263, 299, 401) while the recorded green run is "4/4 green" (`docs/parity.md` T36,
`docs/t36-build-note.md` §7). Not this card's subject; whoever next touches the suite should reconcile
which test the 4/4 count covered.

## 3. The decision

**Retire `Surface.threads`.** The thread pane's render mode is the pane host's mode. Concretely:

* `case threads` and its `title` arm leave `Surface`; the catalogue is **11** cases;
* `ThreadPaneContent`, `GlobalThreadsPaneContent` and `NativeThreadsPaneView` gain **no** gate — they
  keep drawing natively whenever the route mounts, and that is now the documented contract;
* `-surfaceMode threads=<mode>` stops existing. The launch parser drops unknown surfaces silently
  (`docs/dual-render.md` §3, `testUnknownSurfaceIsRejected`), so an old script degrades instead of
  breaking;
* a persisted `mm.surfaceModes` row `"threads"` is dropped by the tolerant decode — a case already
  promised by the doc and pinned by `testUnknownPersistedOverrideIsDropped`
  (`docs/dual-render.md:98-102`: "a retired surface name in a future build cannot crash the shell").

### 3.1 The rule that generalises it

> **A region whose only web form is the pane host's webview is not a surface; it is a sub-region of
> the pane host and inherits its mode.**

This is the same insight `t_8f9f5449` reached from the other end: the profile popover is offered by
the surface **that draws the row** (`rowHost`), not by the surface the row's affordance is named
after. F1 is that rule applied to a pane instead of a row: the thread pane is drawn by the pane host,
so the pane host answers for it.

The honest consequence for the inspector: `threads` is no longer a row, because there is nothing to
toggle. A debug tool that offers a toggle which cannot change anything is the defect this card exists
to remove.

## 4. Change list (for card `t_cdcc1f38`)

### 4.1 Production — `Mattermost/Core/RenderMode.swift`

1. delete `case threads` (l. 31) and its `title` arm (l. 56);
2. amend the enum's doc comment where it counts the catalogue: `RenderMode.swift:12` "the 12 surfaces"
   and `:136` ("the 12 surfaces are the inventory-driven render regions") → eleven;
3. add the retirement note the enum doc needs (one sentence): a case names a region whose mode the
   switch can change while it is on screen; a region that only ever exists inside another region's
   native card is that region's sub-region, not a case (cite this doc and `t_7ffa9e76`);
4. add `SurfaceDefaults.unhostedSurfaces` — §6 below, same file.

`Surface.allCases` consumers need no edit: `MattermostApp.swift:887` (the `mm.surfaceModes`
diagnostic) and `:1036` (the `surfaces=` launch log) iterate; `SurfaceInspector.swift:68,76` takes the
surface as a parameter.

### 4.2 Unit tests — `MattermostTests/SurfaceModeResolverTests.swift` (42 occurrences of `.threads`)

`.threads` is this file's canonical *unapproved* surface ("unlisted surfaces keep their default",
"invalid mode is ignored", tier precedence, reset paths …). Replacement rule:

* substitute `.plugins` (still unapproved, still unhosted, and the archetypal web-only surface —
  `docs/dual-render.md` §1);
* in a function that already asserts `.plugins` (e.g. `testRemoteDefaultFillsBetweenPersistedAndCompileTimeDefault`,
  l. 168-169), substitute `.channelInfo` instead so the function still says two different things;
* `testCataloguePinsTheTwelveContractSurfaces` → `testCataloguePinsTheElevenContractSurfaces`, drop the
  `(.threads, "threads")` row, keep every other assertion;
* add two pins:
  * `XCTAssertNil(Surface(rawValue: "threads"))` — a retired key does not round-trip;
  * a retired **persisted** row (`{"threads": "native"}`) is dropped and leaves no override
    (`hasAnyOverride == false`), so an upgraded install with the old row behaves as if it never had it.

The file must end with **zero** `.threads` occurrences — that grep is the acceptance check.

### 4.3 UI tests — `MattermostUITests/T31WebSessionHarvestUITests.swift:148`

Drop `"-surfaceMode", "threads=native"`. It is a no-op today (unknown after retirement, unconsulted
before it) and leaving it is how a future reader concludes the surface exists.

`T36-ThreadsUITests` is **not** touched (§2.5). No other suite passes a `threads` flag
(`grep -rn "threads=" MattermostUITests/` → that one line only).

### 4.4 The trap that hid F1

`.threads` is three different things in this tree, and only one of them is the surface:

| spelling | owner | after retirement |
|---|---|---|
| `NativeTab.threads` (`Core/Native/NativeNavigation.swift:39,49`), `location.pane == .threads` (`NativeShellView.swift:276`, `RootView.swift:196`, `NativeNavigation.swift` ×6) | the shell's **route** enum — the Threads tab / a thread destination | unchanged |
| `page.threads`, `list.threads`, `ThreadTotals.threads` (`Core/MM/MMThreadTypes.swift:136-149`, `Thread/*ViewModel.swift`) | the **API** payload | unchanged |
| `Surface.threads` | the render switch | **deleted** |

A `grep -rn "\.threads"` therefore returns 32 production hits and 0 of them are the surface, which is
how a never-consulted case survived several rounds of review. The builder must delete the enum case
only, and the reviewer must not accept any change to the first two rows.

### 4.5 Docs

* `docs/dual-render.md`: §2 "the 12 switch keys" → 11; §4 table (drop the `threads` row, add the
  sub-region rule as §4's second paragraph — the retired-surfaces amendment); §10 test-map row for the
  catalogue test (Eleven) + the new retired-key pins; §11's known-limit bullet (this card has already
  replaced its stale "toggling `threads` changes nothing" claim with the measured four-case state,
  commit `7f88650` — keep it in step with the code once the case is gone).
* `docs/parity.md`: T36 status cell — the retirement sentence placed there by this card stays.
* `docs/component-map.md` §5: S13 keeps its row (the *screen* is unchanged); no edit expected — verify.

## 5. What this does NOT change

* **T36's card and its evidence.** The thread pane, its 5 live tests, the `-surfaceMode shell=native`
  launch line, the `.composer` gate inside the thread's reply box (`ThreadView.swift:52` — a different
  surface, deliberately kept), the read-on-open write, the 60-reply window: all unchanged.
* **C1 (`t_07216319`).** Its thread host passes `rowHost: .native` "as a fact about the view". After
  this decision that fact is *permanent and documented*: the thread pane can only exist inside a
  native pane host, so its rows are native by construction. Nothing to revisit — the card's condition
  ("if this card makes `.threads` resolvable") does not fire, because the decision goes the other way.
  The C1 comment that points at F1 stays correct; a builder landing C1 may append "retired, see
  `docs/t_7ffa9e76-…`" if it is editing that comment anyway.
* **The profile popover parity work** (C1/C2/C3): unaffected.

## 6. The structural fix — gate 11 (so this class cannot recur silently)

A retirement alone fixes one case. The class recurs because *nothing* checks that a catalogue key is
consulted, and because `docs/dual-render.md` §11's known-limit ("only `channelView` has a host … their
hosts arrive with their screen cards") reads as if every unconsulted case were just early. It is not:
T36, T39, T40, T42, T44d and T41 all landed card **sites** — the checkbox "does this card consult its
surface?" was never in an acceptance list.

`scripts/verify-dual-render-gates.sh` gains **gate 11**, same shape as the registry gates it already
has:

```
== 11. every Surface case is consulted, or declared unhosted ==
```

* **Declaration.** New `SurfaceDefaults.unhostedSurfaces: Set<Surface>` in `RenderMode.swift`:
  "catalogue reservations — a name that exists so a future card can key on it, with no host and no
  switch today". Each member needs a row in `docs/dual-render.md` §11 naming its reason.
* **Consulted** means at least one reference of the shape
  `resolvedMode(for: .<case>)`, `SurfaceHost(.<case>` or `defaultMode(for: .<case>)` in `Mattermost/`
  outside `Core/RenderMode.swift`, **or** the case being `SurfaceDefaults.paneHostSurface`'s value
  (`.channelView`, reached through the constant + the `shell` alias).
* **Fail** when a case is neither consulted nor declared, and **fail** when `unhostedSurfaces` is not
  exactly `[.settings, .plugins]`, unless `--allow-unhosted-change` is passed — the same
  "deliberate act, visible in the diff" shape as gate 5's registry flag. Growing the list therefore
  costs a review, not a one-line edit.
* **Members at landing:** `.settings` (the shell's `SettingsView` is presented unconditionally,
  `RootView.swift:180,229`; the web app's settings modal has no host) and `.plugins` (web-only by
  decision, `docs/dual-render.md` §1: S29-S32 will never be ported). Both are card `t_39ea6115`'s
  subject; the gate is what keeps them from being forgotten a third time.
* **Honest limit, stated in the gate's own comment:** the check measures *references*, not *effect*.
  `.profile` passes gate 11 while its value is discarded by `ProfilePopoverPolicy` (§2.2/§9 F4), so a
  read-and-ignored case is invisible to it. That is why `t_39ea6115` exists; a gate that tried to
  prove "the value changes what is drawn" would need to execute the UI, which is the `-AV`
  programme's job, not a regex's.

The gate must pass **in the same commit** that retires the case — that is why both live in
`t_cdcc1f38`: a gate added earlier would be red on `main`, and a gate added later would be a promise.

### 6.1 The predicate, run before and after (prototype)

Implemented as a standalone probe first, against this tree and against a copy of it with the
retirement applied — so the design is measured, not asserted:

```
$ probe_gate11.py .                      # today's tree
cases (12): [… 'threads', … 'settings', … 'plugins']
  ok    .auth        consulted at Mattermost/UI/Native/Auth/LoginView.swift:47
  ok    .channelView consulted at SurfaceDefaults.paneHostSurface
  ok    .composer    consulted at Mattermost/UI/Native/Channel/ChannelView.swift:734
  FAIL  .threads     neither consulted nor declared unhosted
  ok    .profile     consulted at Mattermost/UI/Native/Channel/ChannelView.swift:746
  FAIL  .settings    neither consulted nor declared unhosted
  FAIL  .plugins     neither consulted nor declared unhosted
RESULT: FAIL — 3 surface key(s) with no effect: ['threads', 'settings', 'plugins']

$ probe_gate11.py <tree with the case deleted + unhostedSurfaces added>
cases (11): […]
  ok    .settings    declared unhosted
  ok    .plugins     declared unhosted
RESULT: PASS — every Surface case is consulted, or declared unhosted.
```

Two facts worth keeping: the predicate names **exactly** the three cases §1/§2.2 measured by hand
(no false positives on the nine that gate), and `.profile` is `ok` — the read-and-discarded case passes,
which is why the limit above is stated in the gate's own comment rather than discovered later.

The prototype is attached to this card (`probe_gate11.py`); `t_cdcc1f38` folds it into gate 11 in
`scripts/verify-dual-render-gates.sh` in the house gate style (numbered section, `ok`/`FAIL` lines,
`RESULT:` footer). The existing gates still pass on this card's docs-only diff
(`bash scripts/verify-dual-render-gates.sh --allow-approved-registry` → `RESULT: PASS`).

## 7. Amendment to the catalogue's additive rule (`docs/dual-render.md` §4)

The harness doc said: *"The catalogue is **additive**: surfaces are never repurposed or renamed,
because the raw string is both the `-surfaceMode` key and the persisted override key."* That rule
correctly forbids **renaming** (it would silently orphan a persisted row) and says nothing about
**retirement** — yet the doc's own resolution chapter already anticipates it ("a retired surface name
in a future build cannot crash the shell", l. 101-102) and the resolver tolerates it by construction.
So §4 gets one added sentence:

> Adding a case is additive (§4 as written). **Removing** one is legal only by a decision card that
> records why the region is not a switch (this card is the first), and it must land with: the case
> gone, the acceptance-test rename, a pin that the retired raw value decodes to `nil`, a pin that a
> stale persisted row is dropped, and gate 11 green. A retired key is never reused for a different
> region — the persisted row would inherit a mode the reader did not choose.

## 8. Consequences recorded

### 8.1 Counts

`Surface.allCases.count` 12 → 11. Three places name "twelve" in prose (`RenderMode.swift:12`,
`dual-render.md:51`, `:109`, plus the test name) — all in §4.1/§4.5's list. No other count assertion
exists (`testCataloguePinsTheTwelveContractSurfaces` is the only one).

### 8.2 The inspector

One fewer row, and the Inspector's `Reset all` is unaffected (it clears rows by key). A reader who
looks for "Threads" in the inspector and does not find it should find, in `docs/dual-render.md` §4,
the sentence that says why.

### 8.3 Release behaviour

**No change.** `.threads` was `web` by default and ignored; the thread pane drew natively anyway.
After retirement it is absent and the pane still draws natively. Nothing about a Release build, the
registry (`nativeApprovedSurfaces` untouched), pane ownership (`[.channelView]` untouched) or the
release policy changes.

### 8.4 Ordering against the running profile-popover cards

`RenderMode.swift` is being edited **right now** by `t_07216319` (C1: the `paneHost:` → `rowHost:`
rename and its doc-comment table) and C2/C3 follow it. `t_cdcc1f38` is therefore parented on
`t_07216319`, not on this card directly, so the enum edit lands on a tree where C1 is already in.
`RenderMode.swift` is this board's current hotspot — flagged in this card's completion metadata.

## 9. Findings this card files but does not decide (card `t_39ea6115`)

Each is measured above; each needs its own decision, and none of them is "add a gate":

* **F2′ `.settings` is never consulted.** `SettingsView` is presented unconditionally from
  `RootView.swift:180` (regular) and `:229` (compact). By §2.1's test the region fails (2) and (3) and
  is a retirement candidate, or the switch should be honoured by gating the sheet — a product question
  (a web settings modal over a released webview is the same dead end as §2.2).
* **F3′ `.plugins` is never consulted and never will be.** `docs/dual-render.md` §1 says S29-S32 are
  permanently web. It is the legitimate member of `unhostedSurfaces`; the only open question is
  whether a key that can never resolve `native` should be a switch at all.
* **F4′ `.profile` is read and discarded.** `ChannelView.swift:746` passes it to
  `ProfilePopoverPolicy.offersAuthorTap(paneHost:profileSurface:)`, and
  `MattermostTests/T429ProfileTapTests.swift:83-93` asserts the tap is **offered while `.profile`
  resolves `web`** — i.e. `-surfaceMode profile=native` (which T41's live suite passes) cannot be what
  makes the sheet appear. This is deliberate (the truth-table pin from `t_42968927`) and documented,
  but the switch has no observable effect, so either the sheet gains a real gate or the case goes.
* **F5′ the in-pane web-fallback notes name a web app that pane ownership released.**
  `SearchView.swift:50` "Search is rendered by the web app", `MentionsView.swift:38` "Mentions are
  rendered by the web app", `SavedPinnedViews.swift:48` "Saved messages are rendered by the web app".
  Reachable only with `-surfaceMode search=web` etc. **while the pane is native**, i.e. exactly when
  `docs/dual-render.md` §12.2 has destroyed the webview. The copy is a lie of the §2.2 kind; the
  smallest honest change is to name the flag, not the web app ("Search is off for this run
  (`search=web`)"). Not a defect a reader can hit without a debug flag, which is why it is a finding
  and not a card of its own priority.

## 10. Sources

Measured on `1577337`:

* `Mattermost/Core/RenderMode.swift` (the enum, `title`, the approval ledger, `ProfilePopoverPolicy`);
* `Mattermost/UI/ContentView.swift:32-45` (the pane host is the shell's mount point), `UI/RootView.swift:47,180,196,229`,
  `UI/SurfaceHost.swift:33-60`, `UI/SurfaceInspector.swift:68,76`;
* `Mattermost/Core/Native/NativeNavigation.swift:339-346` (`acceptsNativeRouting`), `:428-455` (open/close thread);
* `Mattermost/UI/Native/NativeShellView.swift:276-282`, `UI/Native/NativePanePlaceholders.swift:355-416`,
  `UI/Native/Thread/ThreadView.swift:1-53`, `UI/Native/Search/SearchView.swift:20-62`,
  `UI/Native/Activity/MentionsView.swift:32-38`, `UI/Native/Channel/ChannelView.swift:734-747,878-881,981,1008,1021`;
* `MattermostTests/SurfaceModeResolverTests.swift` (42 `.threads`), `T429ProfileTapTests.swift:83-103`,
  `NativeNavigationTests.swift` (the *route* enum, same spelling);
* `MattermostUITests/T36-ThreadsUITests.swift:761-769`, `T31WebSessionHarvestUITests.swift:144-149`;
* `docs/dual-render.md` §1-§5, §10-§12.2, `docs/parity.md` T36, `docs/t_8f9f5449-profile-popover-parity.md` §2.1/§8;
* `scripts/verify-dual-render-gates.sh` gates 5/6 (the shape gate 11 copies).
