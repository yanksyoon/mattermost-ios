# Three surfaces with no effect on screen: retire `.settings`, `.plugins`, `.profile` — and stop the web-fallback notes naming a web app that is not there

**Status: decided 2026-10-29 by `mmios-architect` (card `t_39ea6115`). Not built.**
Follows `docs/t_7ffa9e76-threads-surface-retirement.md` (F1: `.threads` retired), which filed
these as F2′–F5′ in its §9. Tree measured at `cfc9cb5` (`main`, clean working tree — the parent
card's docs commit; production code identical to `1577337`), 2026-10-29.
Harness contract: `docs/dual-render.md`.

| finding | case | verdict | catalogue |
|---|---|---|---|
| F2′ | `.settings` | **retire** — shell chrome with no web form of its own; gating it breaks server management | 12→11→10 |
| F3′ | `.plugins` | **retire** — a switch that can never resolve `native` is not a switch | 10→9 |
| F4′ | `.profile` | **retire** — read and discarded; the sheet is a sub-region of the row host (the F1 rule) | 9→8 |
| F5′ | the three in-pane notes | **fix the copy** — and the state it describes is **shipped**, not debug-only (escalated, §6.3) | — |

After all four: **8 cases**, `SurfaceDefaults.unhostedSurfaces = []`, gate 11 passing with an empty
reservation set. Cards: `t_6d420e01` (the three retirements + the gate literal), `t_a7432eab` (the
F5′ copy), `t_aa211ff6` (the lookup-defaults decision escalated in §6.3).

## 1. What was measured (not inherited)

The card's four premises reproduce exactly, with two corrections that change a verdict's weight
(§5, §6.2) and one that changes a change list (§5.4).

```
$ grep -rn "resolvedMode(for: \.settings)\|SurfaceHost(\.settings" --include=*.swift Mattermost/
(no output — zero call sites)
$ grep -rn "resolvedMode(for: \.plugins)\|SurfaceHost(\.plugins" --include=*.swift Mattermost/
(no output — zero call sites)
$ grep -rn "\.profile" --include=*.swift Mattermost/     # production, the surface only
Mattermost/UI/Native/Channel/ChannelView.swift:746:  profileSurface: resolver.resolvedMode(for: .profile))
```

The full catalogue, `resolvedMode(for:)`-style call sites, run as the gate-11 predicate on this tree
(the prototype from `t_7ffa9e76` §6.1, re-run here — output verbatim):

```
$ python3 probe_gate11_catalogue.py .        # tree at cfc9cb5, 12 cases
  ok    .auth         consulted at Mattermost/UI/Native/Auth/LoginView.swift:47
  ok    .sidebar      consulted at Mattermost/UI/Native/NativePanePlaceholders.swift:43
  ok    .channelView  consulted at SurfaceDefaults.paneHostSurface
  ok    .composer     consulted at Mattermost/UI/Native/Channel/ChannelView.swift:734
  FAIL  .threads      neither consulted nor declared unhosted
  ok    .search       consulted at Mattermost/UI/Native/Search/SearchView.swift:36
  ok    .profile      consulted at Mattermost/UI/Native/Channel/ChannelView.swift:746
  ok    .activity     consulted at Mattermost/UI/Native/Activity/MentionsView.swift:32
  FAIL  .settings     neither consulted nor declared unhosted
  ok    .channelInfo  consulted at Mattermost/UI/Native/Sidebar/ChannelSidebarView.swift:234
  ok    .calls        consulted at Mattermost/UI/Native/Channel/ChannelView.swift:1021
  FAIL  .plugins      neither consulted nor declared unhosted
RESULT: FAIL — 3 surface key(s) with no effect: ['threads', 'settings', 'plugins']
```

`.profile` is `ok` in that listing and still fails this card's test — §5 shows why a *reference* is
not an *effect*, which is the stated limit of gate 11 and the reason this card exists.

### 1.1 The test, restated with the one clause the parent card left implicit

`docs/dual-render.md` §4 (as amended by `t_7ffa9e76`) requires a case to be renderable two ways
**while it is on screen**: (1) a native card, (2) a web path that is live at that moment, (3) ≥1
production call site that consults it. Applying it here surfaced one refinement worth writing down,
because it is what separates `.search` (kept) from `.threads` (retired) and from all three of today's:

> A case is a **switch** only if flipping it can change what is on screen in **at least one
> direction**. Both directions being dead is what `.threads` was. One direction being dead is the
> composer's strip and is tolerated when the dead direction costs a *decoration*, not a *destination*
> or a *capability*.

That is why `.search`/`.activity`/`.channelInfo` stay although their `web` state is a note: flipping
them `native` mounts a real screen, so the key has an effect. It is also why the three cases decided
here go: flipping them changes nothing at all, in either direction.

## 2. F2′ `.settings` — retire

### 2.1 The region is shell chrome, and it is the only region with no web form at all

`SettingsView` is presented from the shell's toolbar gear, which is attached **unconditionally** —
`RootView.shellToolbarItems` (`RootView.swift:74-80`) is declared on the navigation stack's root
(`:189-220`) and again on every pushed native destination (`:164-188`), and the sheet itself is
unconditional in both layouts (`RootView.swift:180` regular-destination, `:229` compact):

```swift
// Mattermost/UI/RootView.swift:74-80 — no pane-mode test, by design
Button { isPresentingSettings = true } label: { Image(systemName: "gearshape") }
    .accessibilityIdentifier("settingsToolbarButton")
```

`docs/dual-render.md` §2's own table already says so: *"per-server scene mounting, toolbar, server
switcher, **settings**, downloads are shell chrome and are **not** gated by a surface"* (`:58`), and
§4's row for the case reads *"`settings` | shell `SettingsView` (already native, T3/T19a)"*. The case
contradicts both.

Three-part test:

1. **native card** — yes, and it is not even a "card" in the dual-render sense: it is the shell's
   sheet, on screen in **every** pane mode.
2. **a live web path of the same region** — **no, in any configuration.** The web app has a settings
   modal, but it is drawn *inside the pane webview's product menu*, i.e. it is a region of
   `.channelView`, not a second form of the shell's sheet. And the shell's sheet owns things the web
   app cannot do at all: add/remove a **second server**, wipe a server's session, the T43 notification
   input read-out, downloads. A `web` state would not fall back to anything — it would delete the
   only path to those.
3. **a call site** — none.

### 2.2 Why gating is strictly worse than the dead key

`-surfaceMode settings=web` is the **default** (the case is not in `nativeApprovedSurfaces`). A gate
would therefore take the shipped default and make the gear open a note — or nothing — while
`.channelView` is native and its webview is released (§12.2). That is not a fallback; it is the
removal of server management, notification configuration and downloads from the product, on the
configuration every reader is in. The alternative — adding `.settings` to `nativeApprovedSurfaces` to
make the gate inert — is an `-AV` claim for a sheet that is not a rendering claim at all.

**Verdict: retire.** The shell's settings are shell capabilities, not a render region; the web app's
settings are `.channelView`'s (sub-region).

**Migration:** delete `case settings` and its `title` arm. Nothing else reads it; no view gains or
loses a branch. A persisted `mm.surfaceModes` row `"settings"` is dropped by the tolerant decode
(`docs/dual-render.md:98-102`), and `-surfaceMode settings=<mode>` becomes an unknown surface the
launch parser ignores (`testUnknownSurfaceIsRejected`).

## 3. F3′ `.plugins` — retire

### 3.1 A key with one legal state is not a switch

`docs/dual-render.md` §1 makes S29-S32 (System Console, plugin screens, Boards, Playbooks, the Apps
framework) **permanently web**; `docs/component-map.md` S29 records *"webview (T46) always … Not
ported: entirely"*. So:

1. **native card** — none, and none is planned. A plugin screen is a **server-shipped web app**; a
   native form of it would mean re-implementing third-party bundles, which is `docs/path-b-adr.md`'s
   out-of-scope Path B.
2. **web path** — the plugin surfaces are drawn by the pane webview, so they are `.channelView`'s
   sub-region (the F1 rule, exactly).
3. **call site** — none.

`defaultMode(for: .plugins) == .web` forever; the only way to make it `native` is a debug flag that
mounts nothing. In the inspector that row is a toggle a reader can flip with **zero** change on
screen — the precise defect this programme's `-AV` discipline exists to prevent, and the thing that
teaches a reader the inspector is broken.

### 3.2 The "catalogue reservation" objection, answered

`.plugins` is the archetypal member of `SurfaceDefaults.unhostedSurfaces` and the parent card put it
there. A reservation is defensible for a name **a future card will key on**; `.plugins` can never be
keyed on, because there is no future card that renders a plugin surface natively. A permanent
"reservation" is a decision not to have a switch, written in the one place that looks like a pending
decision. Keep the *fact* (S29-S32 are permanently web, §1 already says it); drop the *key*.

Corollary recorded for the tests: `.plugins` is currently the resolver suite's canonical *unapproved*
surface (`SurfaceModeResolverTests.swift:95, 251, 455-469` …). After retirement that role passes to
`.channelInfo` (unapproved, consulted, not retired) and `.search`. See §8.5 — `t_cdcc1f38`'s
substitution plan is corrected by a comment on that card so the file is not churned twice.

**Verdict: retire. Migration:** delete `case plugins` and its `title` arm; `.plugins` leaves
`unhostedSurfaces` (§7).

## 4. F4′ `.profile` — retire (the row-host rule, one level below F1)

### 4.1 The flag is read and discarded, and the sheet is a sub-region

```swift
// Mattermost/Core/RenderMode.swift:179-185 (pre-C1; C1 renames the label, not the shape)
public static func offersAuthorTap(paneHost: SurfaceRenderMode,
                                   profileSurface: SurfaceRenderMode) -> Bool {
    switch (paneHost, profileSurface) {
    case (.native, _): return true      // ← the second argument is wildcarded in both arms
    case (.web, _): return false
    }
}
```

`ChannelView.swift:743-747` is the only production read of `.profile` and it feeds that discarded
parameter. `MattermostTests/T429ProfileTapTests.swift:83-93` pins the consequence: on the shipped
defaults the pane host is `native` and `.profile` is `web`, and the tap **is** offered. So
`-surfaceMode profile=native` — which `T41ProfileUITests.swift:400` and `T45AvatarUITests.swift:89`
pass — cannot be what makes the sheet appear. (Both flags land in §4.4.)

Three-part test:

1. **native card** — yes: `ProfileSheet` + `StatusSetterScreen` + `CustomStatusEditorScreen` (T41).
2. **web path live at the moment the region can be on screen** — **no.** Every host that presents
   the sheet is a row list inside `NativeShellView` (`ChannelView.swift:878-881`; C1 adds the thread
   host, C2 the lookup hosts) and `NativeShellView` **is** the pane host's native branch
   (`ContentView.swift:33-44`). When the pane is web there are no native rows, so there is no native
   sheet to be on screen; the web client's popover is the pane webview's region. `.profile` is a
   **sub-region of the row host** — the §2.1 rule applied to a row list instead of a pane, which is
   the same generalisation `t_8f9f5449` reached from the affordance side.
3. **call site** — one, and its value is thrown away: fails "consults it".

### 4.2 Why gating is worse than retirement — it re-breaks a repaired defect

`-surfaceMode profile=web` is the **default**. A real gate (`showsProfile = resolver.resolvedMode(for:
.profile) == .native`) would remove the author tap on the shipped defaults and, because the pane is
native, hand the tap to a web popover that does not exist — the exact regression `t_42968927` repaired
(reader tapped an author, nothing opened). The only way to keep the tap would be to add `.profile` to
`nativeApprovedSurfaces`, i.e. to make an `-AV` claim whose sole observable effect is to stop a debug
flag from re-introducing a fixed bug. That is not an approval; it is a workaround for a case that
should not exist.

**Verdict: retire.** The row host answers — and after C1 that is the *documented, permanent* rule:
the tap is offered iff the surface that draws the row is native.

### 4.3 What the retirement changes (the arity drop is the whole point)

`ProfilePopoverPolicy.offersAuthorTap` loses its second parameter and keeps a **two-row** truth table
(native row host → offered; web row host → not offered). The `native × web` cell was the *pin for the
repaired defect*; with the case gone that cell is unrepresentable, and the honest replacement is the
*test* T429 keeps: launch with **no** `.profile` flag (which it already does, `T429ProfileTapUITests`
l. 208) and assert the tap exists on the shipped defaults. A unit test cannot say "a flag that does
not exist cannot remove the tap" — the live suite is the only place that statement is measurable, and
it already makes it.

### 4.4 T41's live suite must stop passing a flag that does nothing

`T41ProfileUITests.swift:400` and `T45AvatarUITests.swift:89` both launch with
`-surfaceMode profile=native`. After retirement the parser drops it silently, so leaving it is not a
failure — it is a lie a future reader will read as "the profile card is behind a flag". Both lines go,
and the sentence in `docs/parity.md`'s T41 row that says *"Gated by `-surfaceMode profile=native`"*
goes with them (the sheet is the row host's, and that is now stated there instead).
`T429ProfileTapUITests.swift`'s header comment (l. 4) also names the flag as "the flag that hides the
defect" — that comment stays **correct** and is the record of why the flag had to go.

### 4.5 What `.profile`'s §4 row claims, and what actually ships

`docs/dual-render.md` §4 says `profile` owns *"S24 Profile popover/status, S27 user settings, S28 Edit
profile, S39 custom attributes"*. Measured: the tree has the sheet and the two setters (S24 + status),
and **no** `EditProfileView` (`grep -rln "EditProfile\|CustomAttributes" --include=*.swift Mattermost/`
→ no files); `docs/parity.md`'s T41 row states it plainly — *"no editing of the profile (… is S28's
`edit_profile`, custom attributes S39)"*. `docs/component-map.md`'s S28/S39 rows nonetheless say
`native (T41)`. That is a doc-vs-tree discrepancy in **another** document, recorded here as D-1 (§9);
it is not settled by this card and the row rewrite below only carries what ships.

## 5. F5′ — the in-pane notes name a web app that pane ownership released

### 5.1 The strings

| file | title as measured | body as measured |
|---|---|---|
| `SearchView.swift:49-55` | "Search is rendered by the web app" | already names `search=web` and `-surfaceMode search=native` |
| `MentionsView.swift:37-43` | "Mentions are rendered by the web app" | already names `activity=web` |
| `SavedPinnedViews.swift:44-57` | "Saved messages are rendered by the web app" | already names `-surfaceMode search=native` |

**Correction to the card (measured, narrows the change):** the *bodies* are already honest — they name
the flag. Only the **titles** make the false claim ("rendered by the web app" for an app that is not
mounted). So the smallest honest change is the three title lines plus one clause in the saved body
(which is the only body that does not say *why* the web app cannot draw it).

### 5.2 Reachability: this is the shipped state, not a debug flag

The card's premise was "reachable only with the surface flagged `web` while the pane is native". With
`web` being the **compile-time default** for `.search`/`.activity` (neither is in
`nativeApprovedSurfaces`, `RenderMode.swift:104`) and `.channelView` being native-and-pane-owning by
the 2026-10-27 decision, that is not a debug configuration — it is **the configuration every reader
is in**:

* the compact layout mounts the Search, Saved and Mentions tabs **unconditionally**
  (`NativeShellView.swift:220-242`, with the comment that the panes "say so instead of drawing a
  screen the switch says is not native");
* the regular layout mounts the same three as detail-toolbar buttons, also unconditionally
  (`NativeShellView.swift:146-174`);
* the release policy then **destroys** the per-server `WKWebView` (`docs/dual-render.md` §12.2,
  `RootView.releaseIfNeeded`), so there is no page behind the note.

So on a shipped build, three of the shell's five compact tabs (and three toolbar buttons on iPad)
open a note that says a web app is drawing the content, over a webview that was destroyed on purpose.
That is the same lie of the §2.2 kind the parent card found, at a place a reader actually reaches.

### 5.3 The copy this card specifies

Name the flag, never the web app:

* Search tab — title **"Search is off for this run (`search=web`)"**; body: *"This pane is native, so
  the web app is not mounted to draw it. Launch with `-surfaceMode search=native`, or switch the
  surface in the inspector, to use the native search."*
* Saved — title **"Saved messages are off for this run (`search=web`)"**; body: *"Search, saved and
  pinned share one switch, and this pane is native — the web app is not mounted here. Launch with
  `-surfaceMode search=native` to use the native list."*
* Mentions — title **"Mentions are off for this run (`activity=web`)"**; body: *"This pane is native,
  so the web app is not mounted to draw it. Launch with `-surfaceMode activity=native`, or switch the
  surface in the inspector, to use the native feed."*

Keep every accessibility identifier (`searchWebFallback`, `savedWebFallback`,
`activityWebFallback`) — suites and the build notes reference them.

### 5.4 The state those notes describe is a decision, not a copy bug — filed, not fixed here

Three shipped tabs with no content is a **product** decision this card cannot take: it needs either
the lookup surfaces' `-AV` approvals (T39/T42 both say *"native ✅ behind the flag"*; the flips are
separate sign-offs, exactly like the 2026-10-27 workspace decision) or the shell must stop offering a
tab/button whose surface resolves `web`. Filed as a decision card (§6.3) with the measurements above;
the copy fix lands regardless, because the current titles are wrong in **every** configuration.

## 6. What ships

### 6.1 Catalogue after this card: 8 cases

```
auth, sidebar, channelView, composer, search, activity, channelInfo, calls
SurfaceDefaults.unhostedSurfaces = []
```

No case is renamed (the persisted `mm.surfaceModes` keys are untouched; the additive rule's
never-rename clause is respected). Measure of the end state — the gate-11 predicate run against a
`RenderMode.swift` with the three cases deleted and the reservation set emptied (built on disk,
probe re-run; the tree's own sources are the scan target, so this is the post-landing predicate, not a
sketch):

```
$ python3 make_post_state.py && python3 probe_gate11_catalogue.py . RenderMode.post.swift
cases (8): ['auth', 'sidebar', 'channelView', 'composer', 'search', 'activity', 'channelInfo', 'calls']
unhostedSurfaces: []
  ok    .auth  … ok .calls   (all eight consulted; listing elided)
RESULT: PASS — every Surface case is consulted, or declared unhosted.
```

Both probe runs and the generated `RenderMode.post.swift` are attached to this card.

### 6.2 Gate 11's pinned literal shrinks to `[]` — the deliberate act the gate exists for

`t_cdcc1f38` lands gate 11 with the literal pinned to `[.settings, .plugins]`. This card's commit
changes that literal to `[]` **and passes `--allow-unhosted-change` in the same commit**, which is the
`-AV`-style review signal: the reservation set going empty is the statement "this catalogue has no
reservations left; every case is a switch". A gate added earlier would be red on `main`, and a gate
relaxed later would be a promise — so the order is `t_cdcc1f38` first, this card second (§8).

### 6.3 The escalation card

* **`t_aa211ff6` (decision, `mmios-architect`) — "the shipped native shell offers three lookup tabs
  that can only show a note"**: `.search`/`.saved`/`.activity` default `web` while `.channelView` is
  native and pane-owning, so Search/Saved/Mentions open a note over a released webview on a shipped
  build. Options stated there: (a) approve the lookup defaults with their own `-AV` (the 2026-10-27
  shape), (b) stop offering the tab/button while the surface resolves `web`, (c) accept the notes as a
  stated limit. Not decidable here without the `-AV` evidence.

### 6.4 The copy card

* **`t_a7432eab` copy fix** (`mmios-ios`, parented on `t_2fa3bbe1` C2 — it edits the same three files):
  the three titles + the saved body per §5.3, and the stale `ContentView.swift:34-39` doc comment
  corrected in the same commit (it still says the native shell "is **not** in
  `SurfaceDefaults.nativeApprovedSurfaces` and not pane-owning, so this branch is reachable only
  through the DEBUG affordances" — false since 2026-10-27, and the comment a reader would use to
  conclude §5.2 is a debug-only state).

## 7. The five-part landing checklist, per retired case

`t_7ffa9e76` §7 makes removal legal only with five artefacts. For each of the three:

| # | artefact | `.settings` | `.plugins` | `.profile` |
|---|---|---|---|---|
| 1 | the case gone (`case` + `title` arm) | ✅ | ✅ | ✅ |
| 2 | the acceptance-test rename | `…Eleven…` → `…Eight…`, row dropped | same test | same test |
| 3 | a pin that the retired raw value decodes to `nil` | `XCTAssertNil(Surface(rawValue: "settings"))` | `…("plugins")` | `…("profile")` |
| 4 | a pin that a stale persisted row is dropped | `{"settings":"native"}` → no override, `hasAnyOverride == false` | same | same |
| 5 | gate 11 green in the same commit | literal `[]` + `--allow-unhosted-change` | same | same |

(1)-(4) land in one build card (§8.3); (5) is its acceptance run. Additionally, because `.profile`
was *referenced*, gate 11 would have passed it before and after: the removal is only visible in the
`ProfilePopoverPolicy` arity change and the two UI-suite flags (§4.3, §4.4) — the builder must land
those, or the retirement is invisible.

## 8. Ordering, hotspots, and what not to touch

### 8.1 Why this cannot land before `t_cdcc1f38`

Gate 11 and its pinned literal are `t_cdcc1f38`'s deliverable (parented on the running C1). Landing
this card first would mean either no gate at all or a gate with an unstated pin. Order:
**C1 → `t_cdcc1f38` (gate 11 + `.threads`) → this card (three retirements + literal `[]`)**.

### 8.2 The profile call sites are in flight right now

`ProfilePopoverPolicy.offersAuthorTap(rowHost:profileSurface:)` is being **renamed** by C1
(`t_07216319`, running) and **called** by C2 (`t_2fa3bbe1`: search / saved+pinned / mentions hosts)
and C3 (`t_296843e5`: the two write rows). Dropping the `profileSurface:` argument therefore has to
land **after** all three, and the retirement card is parented on `t_cdcc1f38` + C2 + C3 for that
reason. It must also edit C1's new `MattermostTests/T5449ProfileHostPolicyTests.swift` (its
"`.profile` never consulted" cells become unrepresentable) and C2's hosts, if they pass the argument.

### 8.3 One build card

* **`t_6d420e01` (mmios-ios) — retire `.settings`, `.plugins`, `.profile`; empty `unhostedSurfaces`**:
  `RenderMode.swift` (3 cases + `title` arms, `unhostedSurfaces = []`, the two catalogue counts,
  `ProfilePopoverPolicy` arity + doc table, the enum's retirement note extended with the "one legal
  state is not a switch" clause of §1.1), `SurfaceModeResolverTests` (retire the three; re-point the
  unapproved-surface role to `.channelInfo`/`.search`; catalogue pin → Eight; the two new pins of §7),
  `T429ProfileTapTests` (two-row table; the "offered while `.profile` resolves web" test becomes
  "offered on the shipped defaults, no flag"), `ChannelView`/`ThreadView`/`SearchView`/
  `SavedPinnedViews`/`MentionsView` (drop the `profileSurface:` argument — whatever C1/C2 named it),
  `T41ProfileUITests:400` + `T45AvatarUITests:89` (drop the flag pair), `scripts/verify-dual-render-gates.sh`
  (literal `[]` + `--allow-unhosted-change`), `docs/dual-render.md` (§2 count, §4 rows and the
  retirement list, §10 test-map name, §11 known limits), `docs/parity.md` (T41's "Gated by" sentence;
  T39/T42 rows stay as they are — their gates are real and are §6.3's subject), build note
  `docs/t_39ea6115-build-note.md`.

### 8.4 Hotspot

`Mattermost/Core/RenderMode.swift` and the three lookup views. `RenderMode.swift` is edited by C1
(running) and `t_cdcc1f38` (next); the lookup views by C2. Both retirements and the copy fix are
parented behind those cards rather than racing them. **Flagged as `hotspot: Mattermost/Core/RenderMode.swift`
and `hotspot: Mattermost/UI/Native/Search/{SearchView,SavedPinnedViews}.swift` in this card's metadata.**

### 8.5 The correction `t_cdcc1f38` needs

That card's §4.2 tells the builder to substitute `.plugins` for `.threads`'s 42 occurrences in
`SurfaceModeResolverTests.swift`. If `.plugins` is retired one card later, those 42 substitutions are
re-done — gratuitous churn in the file every resolver test lives in. A comment on `t_cdcc1f38`
corrects the substitution to **`.channelInfo`** (falling back to `.search` where the function already
asserts `.channelInfo`), which is unapproved, consulted, and not retired by this card. If the
substitution has already landed when this card's builder reaches it, the builder substitutes again —
the acceptance check is the same either way: **zero** occurrences of `.settings`, `.plugins`,
`.profile` in that file.

## 9. Discrepancies recorded, not decided

* **D-1 `component-map.md` S28/S39 vs the tree.** §S28 says *"`Edit profile` — `native` (T41)"* and §S39
  *"Custom profile attributes — `native` (T41), feature-gated"*; no `EditProfileView` or custom-attribute
  view exists (`grep -rln` → nothing) and `docs/parity.md`'s T41 row says profile editing is **not**
  ported. Two docs disagree; the tree sides with parity. Belongs to whoever reconciles the inventory,
  not to a surface disposition (it changes no switch key).
* **D-2 the stale `ContentView.swift:34-39` comment** — folded into the copy card (§6.4) because it is
  one comment and because it is what makes §5.2's shipped state look like a debug state.

## 10. What this does NOT change

* **`.composer`.** Its `web` state is a dead placeholder too, and it **stays** a switch: flipping it
  native mounts a real input, and the dead direction costs a strip on a working screen (the parent
  card's §2.3 gave the same reason for `.threads` going the other way). The ledger entry at
  `RenderMode.swift:97` is unchanged.
* **`.search`, `.activity`, `.channelInfo`, `.calls`.** Consulted, and native is a real destination.
  Their `web` states are degenerate (§6.3) — recorded, not hidden, and not a reason to retire a key
  that works.
* **The `-AV` registry.** `nativeApprovedSurfaces` and `paneOwningSurfaces` are untouched; gate 5/6
  keep their literal (still pass with `--allow-approved-registry`).
* **`.threads`** stays retired per `t_7ffa9e76`; nothing here revives it.
* **`mm.surfaceModes` compatibility.** Three more retired keys decode to nothing and are dropped —
  the same tolerance the harness already promises and pins.

## 11. Sources

Measured on `cfc9cb5` (production code identical to `1577337`):

* `Mattermost/Core/RenderMode.swift` (the enum, `title`, `nativeApprovedSurfaces:104`,
  `paneOwningSurfaces:120`, `paneHostSurface:128`, `ProfilePopoverPolicy:149-185`);
* `Mattermost/UI/RootView.swift:45-48, 63-91, 139-236` (shell chrome, both layouts, the two sheets);
* `Mattermost/UI/ContentView.swift:32-45` (pane host = the shell's mount point) and its stale comment;
* `Mattermost/UI/Native/NativeShellView.swift:133-201` (regular toolbar + lookup sheet),
  `:203-244` (the five compact tabs, unconditional);
* `Mattermost/UI/Native/Channel/ChannelView.swift:727-747` (`composerIsNative`, `offersAuthorProfile`),
  `:878-881` (the profile sheet), `:996-1033` (header affordances);
* `Mattermost/UI/Native/Profile/ProfileView.swift:54-70, 144-171` (sheet + the two pushed setters),
  `StatusSetterView.swift`;
* `Mattermost/UI/Native/Search/SearchView.swift:34-62`, `SavedPinnedViews.swift:30-75`,
  `Mattermost/UI/Native/Activity/MentionsView.swift:30-50` (the three notes);
* `Mattermost/UI/ContentView.swift` + `ViewStore.release` path via `RootView.releaseIfNeeded:389-433`;
* `MattermostTests/SurfaceModeResolverTests.swift:95, 244-261, 442-485` (+ `.profile` at 211-221, 251,
  445-446), `T429ProfileTapTests.swift:63-103`;
* `MattermostUITests/T41ProfileUITests.swift:391-403`, `T45AvatarUITests.swift:89`,
  `T429ProfileTapUITests.swift:1-28, 208`, `T39SearchUITests.swift:177-180`,
  `T39JumpUITests.swift:207-210`;
* `docs/dual-render.md` §1, §2 (`:58`), §4 (`:107-150`), §10 (`:432`), §11 (`:444-466`), §12.2;
  `docs/parity.md` T39/T41/T42 rows; `docs/component-map.md` S27/S28/S29/S39;
  `docs/t_7ffa9e76-threads-surface-retirement.md` §2.1, §6, §7, §9;
* `scripts/verify-dual-render-gates.sh` gates 5 (`:270`) / 6 (`:283`), usage block (`:52`);
* the gate-11 prototype from `t_7ffa9e76` (attachment `probe_gate11.py`), re-run and extended here.
