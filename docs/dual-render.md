# Dual-render harness (T26) — per-surface native vs WKWebView

Status: **landed** (T26, 2026-10-24). Owner: `mmios-ios`. Validator: `T26-AV`.

Round **R4a** (T26-R, 2026-10-24): §12 implemented. `RenderMode.paneOwningSurfaces` is the registry
(empty until the first `-AV` pane claim — since the 2026-10-27 workspace flip it holds
`.channelView`, the same commit that approved that surface); `ViewStore` owns one
`WKWebView` + one isolated persistent `WKWebsiteDataStore` per server UUID, with
`ensureStore(for:)` (creates), `view(forServerID:)` (reads only — never resurrects a released pane),
`release(serverID:)` (destroys, keeps `lastURLs`) and the `mayRelease` truth table;
`ContentView.WebPaneReopening` is the blocking honest state of the return trip; `PerfProbe` gained
the `nativeEvicted` arm; `verify-dual-render-gates.sh` gained the pane-ownership subset check.
Tests: `MattermostTests/ViewStoreTests.swift` (release policy + per-server isolation),
`MattermostUITests/MattermostUITests.swift::testReleasedPaneReopensWebViewWithSessionAndHonestState`.

Measured on this commit (`bash scripts/perf_probe.sh --skip-build --targets catalyst --modes
web,shell,native,nativeEvicted --repeat 2 --no-baseline`, run root
`build/perf-r4a-final/20261024-175054`, all 8 arms green, steady kernel phys_footprint in MiB,
repeat 1 / repeat 2): `web` 494.2 / 495.7, `native` 281.5 / 280.1, `nativeEvicted` **34.9 / 35.2**,
`shell` 29.5 / 29.5. The evicted arm sits 5.4–5.7 MiB above the shell floor with
`tracked_pids.webcontent == []` (§12.6 asked for ≤ shell + 60 MiB), while `native` still carries one
WebContent (428–445 MB RSS): the per-server webview's memory is returned, not parked. Peak is not the
number to read for the release: `nativeEvicted`'s peak still contains the WebContent its store spun up
before release (345.3 / 322.0 MB), exactly as §12.6 predicts. The `web` arm here lands ~12 % below
T27's published 592.1 MB — the same non-reproduction T27-AV measured (493–527 MB over four re-runs),
so read the evicted-vs-shell delta (the metric) rather than an absolute web number.
Code: `Mattermost/Core/RenderMode.swift`, `Mattermost/Core/SurfaceModeResolver.swift`,
`Mattermost/UI/SurfaceHost.swift`, `Mattermost/UI/SurfaceInspector.swift`,
`Mattermost/UI/Native/NativeShellView.swift` (the pane surface's native branch since T30).
Tests: `MattermostTests/SurfaceModeResolverTests.swift`, dual-render cases in
`MattermostUITests/MattermostUITests.swift`.

## 1. What this is, and why it exists

The app is a **SwiftUI shell around the Mattermost web app** (Path A). The programme goal is Path B:
native SwiftUI screens driven by REST v4 + WebSocket v4 (`docs/path-b-adr.md`). Screens land one
card at a time (T31…T46 in `docs/component-map.md`), over months.

Without a switch, the port is a big-bang rewrite: every unported screen is a hole and the app is
broken-but-useful from the first day. With it, **each surface flips to native independently**, and
the webview stays a working fallback for everything not yet ported — permanently, for surfaces that
will never be ported (`S29` System Console, `S30` plugin screens, `S31` Boards, `S32` Playbooks).

The switch is deliberately **per surface, not per app**. There is no "run everything natively"
mode, because a half-ported app in that mode is exactly the failure this card avoids.

## 2. The pieces

| File | Role |
|---|---|
| `Core/RenderMode.swift` | `Surface` (the 12 switch keys), `SurfaceRenderMode` (`web` / `native`), `SurfaceDefaults` (compile-time default + the **native-by-default approval registry**). |
| `Core/SurfaceModeResolver.swift` | The single decision point: `resolvedMode(for:)`, persisted overrides, `-surfaceMode` launch parsing, the always-usable escape hatch. |
| `UI/SurfaceHost.swift` | One `some View` per surface: renders the native branch or the web branch. |
| `UI/Native/NativeShellView.swift` | The pane surface's native branch since T30: the application shell, whose unported regions are explicit placeholders naming the card that ships them — never a blank pane. (The generic `UnportedSurfaceView` stand-in was deleted in T30-R: the shell replaced its only call site, so it was dead code.) |
| `UI/SurfaceInspector.swift` | DEBUG-only sheet: every surface, its resolved mode, a Web/Native toggle, "Reset all". |
| `Core/AppPreferences.swift` | Persistence of the user's overrides (`mm.surfaceModes`). |
| `UI/ContentView.swift` | The first (and today only) consumer: gates the per-server webview pane as `Surface.channelView`. |
| `UI/RootView.swift` | Unchanged on purpose: per-server scene mounting, toolbar, server switcher, settings, downloads are shell chrome and are **not** gated by a surface. |

## 3. Resolution order

`SurfaceModeResolver.resolvedMode(for:)` — highest priority first:

1. **Ephemeral launch override** — `-surfaceMode <surface>=<mode>` for this run.
   **DEBUG builds only**; a Release build parses no launch override at all.
2. **Persisted user override** — written by the Surface inspector to `AppPreferences` under
   `mm.surfaceModes` (survives relaunch). **DEBUG builds only**: the tier is not decoded in a
   Release build (`SurfaceModeResolver.debugAffordancesEnabled == false`), and no Release code
   can write it (the inspector and `setOverride`/`clearOverride`/`clearAllOverrides` are inside
   `#if DEBUG`). See §8 for why, and for the consequence.
3. **Remote/config default** — an injected `remoteDefault: (Surface) -> SurfaceRenderMode?` closure.
   **No provider is wired yet** (nothing in the product supplies a server- or build-driven default),
   so this tier is a documented seam, not a live source. It exists so a future remote default does
   not require touching the resolver — and wiring one is a reviewable decision (`§5`, gate script).
4. **Compile-time default** — `SurfaceDefaults.defaultMode(for:)`, i.e.
   `native` **only** for a surface listed in `SurfaceDefaults.nativeApprovedSurfaces`, otherwise
   `web`. Since the 2026-10-27 workspace flip that registry holds `.auth`, `.calls`, `.sidebar`,
   `.channelView` and `.composer` (§5); every other surface is `web`.

So a **Release build resolves from tiers 3 and 4 only**. With those five approved and no remote
default, a shipped binary renders the workspace natively (team rail, channel list, channel pane and
composer) and still falls back to the webview for every unapproved surface.

Two rules make the switch behave the way a user expects at runtime:

- **An explicit user pick beats the launch flag for that surface.** `setOverride` drops this run's
  `-surfaceMode` entry for that surface, so a stale debug flag can never make a toggle look dead.
  Other surfaces' launch overrides are untouched. (`testInspectorToggleDropsLaunchOverrideForThatSurface`)
- **Writing the compile-time default clears the stored row.** Toggling back to `web` leaves no
  persisted override behind, so the default keeps ruling. (`testTogglingBackToDefaultClearsOverride`)

The reset paths follow the same rule from the other side (T26-R R5): `clearOverride(for:)` drops the
stored row **and** this run's launch entry for that surface, and `clearAllOverrides()` ("Reset all to
defaults") drops every stored row **and** every launch entry — so after a reset no surface is left
native by a flag the button could not see, and the button is enabled for a pure `-surfaceMode`
launch as well (`hasAnyOverride`).

Malformed input degrades instead of crashing: an unknown surface, an unknown mode, a missing `=`,
a missing value, or a dangling `-surfaceMode` at the end of `argv` are all dropped
(`testUnknownSurfaceIsRejected`, `testUnknownModeIsRejected`, `testDanglingSurfaceModeArgumentIsIgnored`,
`testEmptyValueAndMissingSeparatorAreIgnored`). Persisted rows are decoded just as tolerantly, so a
retired surface name in a future build cannot crash the shell (`testUnknownPersistedOverrideIsDropped`).

Do not pass a `-surfaceMode` whose value is the surface's own compile-time default — by
construction that is a no-op (`web` for every surface today).

## 4. Surfaces

The 12 switch keys are the regions of the client, not the 40 inventory screens. Mapping to
`docs/component-map.md` §5 (S-IDs) — a screen card owns its whole surface:

| `Surface` | Owns (component-map §5) |
|---|---|
| `auth` | S01 Login, S02 MFA, S03 SSO, S04 Signup/forgot, S06 ToS gate, S37 onboarding |
| `sidebar` | S08 Channel sidebar, S09 Find/browse channels |
| `channelView` | S11 Channel view (post list), S12 Permalink, S16 Reactions, S38 post options |
| `composer` | S14 Composer, S15 Autocomplete, S17 emoji picker |
| `threads` | S13 Thread RHS + global threads |
| `search` | S19 Search, S20 Saved, S21 Pinned, S26 Drafts |
| `profile` | S24 Profile popover/status, S27 user settings, S28 Edit profile, S39 custom attributes |
| `activity` | S25 Mentions inbox |
| `settings` | shell `SettingsView` (already native, T3/T19a) |
| `channelInfo` | S22 Channel info, S23 Members / manage |
| `calls` | S33 Calls — **pinned to `web` by T44** (2026-10-27): no native card owns this surface, and the pin is deliberate. `docs/t44-build-note.md` §6 gives the reasons (a native surface without the ReplayKit broadcast-extension target *regresses* screen share against today's webview; no licence sign-off for the AGPL/source-available plugin; no surface card) and they still stand. **Amended by T44b** (`t_7b826839`, `docs/t44b-calls-media-path.md`): the media-path half of the reason is gone — a UDP relay sidecar on `mm-perf-net` publishes the SFU's ICE port, `scripts/t44_calls_probe.py` now measures reachability with a credentialed ICE check (`MEDIA PATH: 1/3`), and a real call carries bidirectional opus both ways with `getStats()` counters (`outbound-rtp` +405/+404 packets, `inbound-rtp` +388,800 samples decoded on each side, selected pair `127.0.0.1:8443/udp`). "Bidirectional audio" **is** measurable here now, so lifting the pin rests on licence, screen share and a surface card — T44c (`t_d7b43d10`) owns the engine work. **Amended again by T44-AV-R** (`t_19ac4035`; `docs/t44-build-note.md` §3.3): measured inside this app's own `WebViewStore`, the *pinned* webview does show the plugin's Calls button at iPad width (95 × 32 at x = 646 of 834) but **not** at iPhone width — at 402 pt `.channel-header` computes `display: none` and the desktop `User-Agent` keeps the web app from mounting its mobile header, so `#calls-join-button` exists in the DOM only inside a hidden subtree (0 × 0). The pin gives an iPhone-shaped viewport no way to start a call, so "screen share works exactly as today" only holds where a call can be joined at all. **Amended by T44d** (`t_a2ff267a`, 2026-10-27; `docs/t44d-build-note.md`): a native card now **owns** this surface — `UI/Native/Calls/` renders the call (participant tiles with mute/hand/host, the control bar, the states a call really has) and the channel header offers `Start call` ⇄ `Join call`, gated on `resolvedMode(for: .calls) == .native` so the webview keeps Calls whenever `calls` resolves `web`. The web fallback is therefore still reachable and unchanged, and the licence/screen-share reasons above now bound *what the native surface may do* rather than whether one may exist: screen share stays inside the webview (no ReplayKit extension until T44e), and the camera control is absent. `.calls` **entered `SurfaceDefaults.nativeApprovedSurfaces` at T44d-AV** (`t_466e8e90`, 2026-10-27, verdict PASS-WITH-FINDINGS; `Mattermost/Core/RenderMode.swift`), so `defaultMode(for: .calls) == .native` with no launch flag. Two things that flip does **not** mean, both measured: (a) the entry point is drawn by `NativeChannelPaneView`, so it is reachable only when the pane host (`.channelView`) resolves native — that surface is not approved, so a shipping build still renders the web app and the web client's own Calls UI, and the registry flip is a correct state rather than a user-visible change by itself; (b) screen share is still web-only (no ReplayKit extension until T44e), so the moment `.channelView` is approved the native surface will be the one that loses it unless T44e lands first. The two assertions the pin was waiting on now **pass**: on 2026-10-27 the live suite's `Leave`-ends-the-call and both `user_unmuted`/`user_muted` round trips went 2/2 green in two consecutive runs against the fixture (`build/logs/t44d-run3.log`, `t44d-run5.log`), independently re-run by the `-AV` card (`build/logs/t44d-av-live1.log`: 2 run, 0 skipped, 0 failed, `** TEST SUCCEEDED **`) after four earlier runs had been killed by an AudioToolbox abort that is host audio contention (signature and ladder in §4.2 of that note). |
| `plugins` | S29 System Console, S30 Plugin screens, S31 Boards, S32 Playbooks, S34 Apps framework |

The catalogue is **additive**: surfaces are never repurposed or renamed, because the raw string is
both the `-surfaceMode` key and the persisted override key (`testCataloguePinsTheTwelveContractSurfaces`,
`testPersistenceKeyIsStable`). If a screen card needs a region that is not listed, it adds a case to
`Surface` in the same PR that lands the card, with a `title` and a doc row here.

## 5. The `-AV` gate (the rule the validator enforces)

> **A screen card may only switch its own surface to native-by-default when its paired `-AV`
> adversarial validator has passed.**

Mechanically that means exactly one edit: appending the surface to

```swift
// Mattermost/Core/RenderMode.swift
public static let nativeApprovedSurfaces: Set<Surface> = [.auth, .calls, .sidebar, .channelView, .composer]
```

* **The registry is an approval ledger, not a scratch list.** Each entry is one `-AV` sign-off, and
  the doc row it cites:

  | Surface | Approved by | Evidence |
  |---|---|---|
  | `.auth` | T31-AV (card `t_c57a7551`, verdict `PASS-WITH-FINDINGS`, F8 = approve the surface) | `docs/t31r-patch-note.md` §5 (flip) and its F1–F4 repairs, which landed *with* the flip |
  | `.calls` | T44d-AV (card `t_466e8e90`, verdict `PASS-WITH-FINDINGS`) | `docs/t44d-build-note.md` §4/§7 (2/2 live, `** TEST SUCCEEDED **`); reachability caveat: the entry point mounts inside a native pane, which is now `.channelView` |
  | `.sidebar` | T33-AV2 (card `t_8c99e10a`, verdict `PASS-WITH-FINDINGS`) **+ the owner's decision of 2026-10-27** (card `t_c93b8337`, scope A; human gate `t_4413b7b2`) | `docs/t33r2-build-note.md` §3/§6 — T33-AV2 closed with "the flip itself stays a separate decision", so the validator never granted it; the owner's approval is the sign-off, and T33-R2 (`t_98c39e49`) had already closed AV2-F1–F3 |
  | `.channelView` | T34-AV (card `t_1ca87edd`, verdict `PASS-WITH-FINDINGS`, F1 repaired by `t_cf23dcd7`) + T55-AV-R (card `t_6059f7ce`) **+ the owner's decision of 2026-10-27** (card `t_c93b8337`, scope A) | `docs/t34r5-build-note.md` §5 (F1 repair) and `docs/t55-revalidation-build-note.md` §3/§6: the five regions the pane hosts were re-validated with no FAIL — `.threads` PASS, reactions PASS-WITH-FINDINGS, attachments PASS, `.search` PASS-WITH-FINDINGS, `.channelInfo` PASS. This is the AV debt T34-AV named as the blocker |
  | `.composer` | T35-AV (card `t_3042a50f`, verdict `PASS-WITH-FINDINGS`; repair `t_e7eeaa46`) — **a repair, not a flip grant** — plus the pane-ownership requirement the same 2026-10-27 decision created (card `t_c93b8337`): the release this flip exists for asserts "composer is native" (`t_9928d203` step 4) | `docs/t35-build-note.md`. Without this entry the approved pane draws the dead `"Message input — web (S14/T35)"` placeholder (`ChannelView.composerPlaceholder`) **while `.channelView` is pane-owning, i.e. after the webview is released** — a read-only workspace. The composer mounts only inside the pane, so the entry is pane-local |

  `.sidebar` and `.channelView` are the first entries whose sign-off is a **product decision, not a
  `-AV` verdict**: both validators passed *with findings* and both explicitly deferred the flip. The
  owner took it on 2026-10-27 (scope A: approve both, behind one post-edit QA round), and this
  document records the decision rather than implying a verdict it does not have. `.channelView` is
  additionally the **only** entry in `paneOwningSurfaces` — approving the pane host without pane
  ownership would paint the native shell over a live `WKWebView` (§12.1).

  `.composer` is not a third product approval: it is the consequence of the pane-ownership claim
  above. §12.1 defines pane ownership as "the card renders every region the webview paints
  (sidebar, header, post list, composer, RHS)", so a pane-owning `.channelView` with a `web`
  composer is internally inconsistent — the flip's post-edit QA round caught it as a dead input
  over a released webview (`docs/tc93b-build-note.md` §4).

* **Empty registry = web everywhere** (that was the state from T26 until T31-R). Anything not in the
  registry still defaults to the web view, so an unapproved card can never ship its surface native.
* `scripts/verify-dual-render-gates.sh` gate 5 fails on a non-empty registry unless
  `--allow-approved-registry` is passed, which is how the approval commit is audited: the flag is
  only ever used *by* the commit that carries the ledger entry (`docs/t31r-patch-note.md` §5 records
  both runs — without the flag, gate 5 alone fails; with it, gates 1–10 pass).
* **Native-by-default** is unreachable any other way: `SurfaceDefaults.defaultMode(for:)` is the
  only function that decides it, and it consults nothing but that set
  (`SurfaceModeResolverTests.testOnlyTheApprovedRegistryDefaultsToNative`,
  `testNativeByDefaultRequiresApproval` pin this).
* A card that hard-wires `.native` in a view, constructs its own `WKWebView`, or adds a private
  bypass fails `-AV` review — see §6 step 4 and §8.

**The registry is not the only *runtime* route to a native decision, and this doc used to imply it
was (T26-R R3).** Every route, and what gates it:

| Route | Reaches `.native` by | Gate |
|---|---|---|
| tier 1 `-surfaceMode …=native` | a launch argument | **compiled out of Release**: nothing is parsed unless `debugAffordancesEnabled` |
| tier 2 stored row (`mm.surfaceModes`) | the DEBUG Surface inspector, or `forceWebForThisRun` (web only) | **not decoded in Release**; the only writers are inside `#if DEBUG` |
| tier 3 `remoteDefault` closure | an injected provider | **no producer exists**; both wiring shapes (`remoteDefault:` argument, assignment) fail the gate script |
| tier 4 compile default | `nativeApprovedSurfaces` | the `-AV` approval itself (§5) |
| native branch of `SurfaceHost` | mounts a screen card | only reachable through `resolvedMode(for:)`, i.e. one of the rows above |

So in a Release build the registry (plus an unwired tier 3) *is* the only route — structurally, not
by convention:

* `setOverride`, `clearOverride` and `clearAllOverrides` — the only APIs that can write an
  arbitrary mode — are declared inside `#if DEBUG`. A Release compile has no API that can steer a
  surface at all, so there is no non-DEBUG call site to review.
* `forceWebForThisRun` (the "Use web view" escape hatch, which must exist in Release) only ever
  writes `.web`; it cannot reach `.native`.
* The read path (`SurfaceModeResolver.init`) decodes tiers 1 and 2 only when
  `SurfaceModeResolver.debugAffordancesEnabled` is true, which is `#if DEBUG || PERF_PROBE`
  (`PERF_PROBE` is the non-shipping perf-harness condition — §8 — and it never appears in the
  project's own build settings, which the gate script proves). A Release build passes a literal
  `false` and the resolver stores empty dictionaries.
* `scripts/verify-dual-render-gates.sh` re-checks all of the above mechanically. **What it actually
  checks, and what it therefore cannot claim** — stated explicitly because the first version of this
  script passed *vacuously* on two of these checks (T26-R review G1/G2; probe transcripts in
  `docs/t26r-build-note.md` §3):
  - writer **declarations** inside `#if DEBUG`;
  - writer **call sites**: any `setOverride(` / `clearOverride(` / `clearAllOverrides(` in the app
    target, **qualified or bare** — `resolver.setOverride(…)` is the spelling the app actually uses,
    and the old receiver-dot exclusion was blind to exactly that — excluding only `func`
    declarations and comment lines. It also fails when it finds *zero* call sites, so a scan that can
    no longer see the code cannot report success;
  - the read-path and `persist()` gates, the `private` initialiser, the inspector file wrapper;
  - tier-3 producers in **both** wiring shapes — a labelled argument
    (`SurfaceModeResolver(remoteDefault: { … })`, the shape this section describes) *and* an
    assignment (`x.remoteDefault = …`) — with four named exemptions: the parameter/property type
    annotation, the convenience initialiser's own forwarding (`remoteDefault: remoteDefault`), an
    explicit `nil`, and `self.remoteDefault = remoteDefault` (the private initialiser storing the very
    parameter it was handed, which cannot introduce a provider of its own);
  - no `PERF_PROBE` in the project's build settings;
  - the empty `-AV` registry.

  Honest limits: it is a **regex** gate over the app target (`Mattermost/` — the test targets may
  inject a provider freely), it skips comment lines, and it reasons line by line. A provider routed
  indirectly — a method reference captured without a call, a closure assembled several lines away, a
  helper type proxying `remoteDefault` — is not something it can see. The structural backstop for
  the three writers is the compiler (they do not exist outside `#if DEBUG`, so a Release call site
  cannot build at all); the script is the cheap early warning for the shapes that *do* compile. It
  does not replace the `-AV` — it protects the gate.

A card is allowed to *merge* its `SurfaceHost` native branch **before** the flip (that is how the
screen becomes reachable through `-surfaceMode …=native` and the inspector) — it just may not
change the default until its validator has signed off.

## 6. How a screen card opts in (checklist)

1. **Read the map.** `docs/component-map.md` §5 for your S-IDs: source files, SwiftUI decomposition,
   test-first pure-logic list, and the Apache-2.0 attribution requirement (`docs/THIRD_PARTY_NOTICES.md`).
2. **Build the screen card** as a plain SwiftUI view + view model driven by REST v4 / WebSocket v4.
   Pure logic first, view after (`docs/component-map.md` §6 translation rules). No `WKWebView`
   inside the card, ever: the card must work with the webview torn down.
3. **Hand it to the host that owns your surface.** Today only `channelView` is hosted
   (`ContentView`). Replace the stand-in branch, do not add a second decision:

   ```swift
   SurfaceHost(.channelView) {
       ChannelView(model: model)            // <- your card
   } web: {
       webPane                              // the existing webview fallback
   }
   ```

   For a surface with no host yet, the card introduces `SurfaceHost(surface)` at the one place
   that region is mounted — never a view-local `if #available`/`#if DEBUG`/UserDefaults read.
4. **Keep it off by default.** Verify `SurfaceInspector` still shows your surface as *Web view*
   and `SurfaceDefaults.nativeApprovedSurfaces` does not contain it.
5. **Prove both directions in tests.**
   - Unit: your view model against fixtures, plus a resolver test that the surface still resolves
     `web` with no override.
   - UI: launch with `-surfaceMode <surface>=native` and assert the native card renders **and** the
     shell chrome (server switcher, settings, downloads) still works; then flip back and assert the
     webview returns with its session (pattern: `testLaunchArgumentRendersNativeChannelViewWithChromeIntact`).
6. **Only after the `-AV` card passes**, add the surface to `nativeApprovedSurfaces` in a separate,
   clearly-labelled commit (`feat(surface): approve <surface> native by default (T<n>-AV passed)`)
   and cite the validation evidence in the commit body. That diff — one line in `RenderMode.swift` —
   is what the next `-AV` audits.

## 7. Host contract (what `SurfaceHost` guarantees)

* **One `some View`.** `body` is a single `if` — SwiftUI folds it into `_ConditionalContent`, so
  flipping the mode swaps the mounted representable without invalidating the parent scene.
* **Re-attachable, never recreated.** The `web` branch must render the store the shell
  already owns (`ViewStore.view(for:)` → `WebViewStore.webView`); the store owns the `WKWebView`
  instance. Dismantling the `UIViewRepresentable` does not destroy the webview — cookies, storage,
  signed-in state and the in-memory page survive, and switching back re-attaches the *same* object
  (`testWebViewInstanceIsStableAcrossSurfaceToggles`). Constructing a `WKWebView` inside a surface's
  `web` branch is a contract violation.
* **No duplicate webview.** One `WebViewStore` per server (`ViewStore`), therefore one `WKWebView`
  per server regardless of how many times a surface is toggled.
* **Loaded, resumed, or left alone — never stranded.** The shell calls
  `WebViewStore.loadIfNeeded(_:)` whenever a `web` branch appears (initial mount *and* re-attach):
  nothing committed → load the server URL; a page committed but with a navigation that neither
  finished nor is running → **resume** the committed URL; in flight, finished, or failed → leave it
  alone (`WebViewStore.loadNeed`, pinned by `testLoadNeedTruthTable`). Dismantling the web branch
  calls `stopForDismantle()`, which records the interruption **synchronously** before
  `stopLoading()` — the recorded fact outranks `isLoading`, because that flag flips asynchronously
  and a re-attach right after the toggle could otherwise read a stale `true` and answer "in flight,
  leave it alone" (that race stranded the page once in a batch run; see §11). The old
  `guard store.url == nil` no-oped forever on the same state and left the pane blank/incomplete — the
  R6 bug (§11).
* **Never a blank pane.** A `native` decision renders the surface's own native branch. Until a
  surface has a real card, that branch is an explicit placeholder that names the card which ships it
  and offers "Use web view" (the pane's is `NativeShellView`, which carries the escape hatch in the
  sidebar and on the auth surface); the generic `UnportedSurfaceView` stand-in was deleted in T30-R
  once the shell replaced its last call site.
* **Always a way back.** "Use web view" (and the inspector toggle) call
  `SurfaceModeResolver.forceWebForThisRun(_:)` / `setOverride(_:for:)`, which also drop this run's
  launch override for that surface. There is no sequence of debug flags that can strand the app on
  an unported surface (`testForceWebForThisRunBeatsLaunchArgument`).

## 8. Debug affordances (DEBUG builds only — including the persisted tier)

Everything in this section is compiled out of Release builds. Two of the four items are *written*
by debug-only code and *read* by the resolver:

**Launch flag** — two accepted forms, repeatable:

```
-surfaceMode channelView=native
-surfaceMode=channelView=native
-surfaceMode channelView=native -surfaceMode threads=web
```

`SurfaceModeResolver.debugAffordancesEnabled` is `false` in Release, and then no launch argument is
parsed at all — a debug flag can never ship side effects in a shipped binary.

**One non-shipping exception, and why it does not weaken the gate.** A build compiled with the
`PERF_PROBE` compilation condition also carries the debug tiers (`#if DEBUG || PERF_PROBE` in
`SurfaceModeResolver.debugAffordancesEnabled`). That condition is *never* in the project's build
settings: T27's perf harness passes it per-invocation
(`SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) PERF_PROBE'`) because it measures a
Release-optimised binary and still needs `-surfaceMode` to launch a surface in either renderer. A
shipping Release build has neither the condition nor any perf code
(`Mattermost/Core/PerfProbe.swift`'s own gate). The gate script's check 2b fails if `PERF_PROBE` ever
appears in a `.pbxproj`, `.xcconfig` or `project.yml`, so the exception cannot become the rule by
accident.

**Persisted per-surface choice** (`mm.surfaceModes`) — written by the Surface inspector. This is the
tier the T26 docs got wrong (T26-R R2): §8 used to claim every affordance was DEBUG-only while the
resolver decoded `mm.surfaceModes` unconditionally, so a choice made in a Debug build was honoured by
a Release build. **Chosen fix (a): the persisted tier is DEBUG-only too.**

* What that means: a Release build decodes no stored row at all (`debugAffordancesEnabled` is
  `#if DEBUG`), and a Release build never writes one either (`persist()` returns early). A shipped
  app therefore always resolves from tiers 3/4 — it can never land on a native stand-in, which is the
  invariant the `-AV` programme wants.
* The cost, stated plainly: **a Debug→Release upgrade on the same install drops the player's stored
  per-surface choice** — the surface returns to its compile-time default (native for the five
  approved surfaces, `web` for the rest). Nothing else is lost: the launch flag was never persisted,
  and a Release build cannot create a stored choice in the first place, since the inspector and
  `setOverride`/`clearOverride`/`clearAllOverrides` do not exist there.
* The only write path that exists in Release is **"Use web view"** in a native branch
  (`NativeShellView`'s sidebar row / auth surface → `forceWebForThisRun`). In Release it is a
  *per-run* undo (the written row
  is not read back on the next launch). Since the 2026-10-27 flip this path is reachable — the
  workspace really is native in a Release build — so its per-run scope is now a live UX behaviour
  rather than a dormant one: the same launch returns to the webview, the next launch returns to the
  native workspace. Making the Release escape hatch persistent (accepting `.web` rows only) is the
  design change this paragraph has always deferred; it is carded separately and is not a bug fix.
* Pinned by `testPersistedOverrideIsIgnoredWithoutDebugAffordances`,
  `testLaunchOverrideIsIgnoredWithoutDebugAffordances` (which build a resolver through the DEBUG-only
  `releaseSemantics(_:)` seam, i.e. exactly what a Release compile computes) and by the gate script
  `scripts/verify-dual-render-gates.sh`.

**Surface inspector** — `Settings → Developer → Surface render modes…`
(`accessibilityIdentifier: surfaceInspectorButton`, sheet: `surfaceInspector`, rows:
`surfaceMode.<rawValue>`). Each row shows the surface, its **resolved** mode badge, a "launch
override" chip while a `-surfaceMode` entry still holds, its compile default, and a Web/Native
segmented picker writing a persisted override. "Reset all to defaults" clears every row **and every
launch override** (see §3), and it is enabled whenever `hasAnyOverride` is true — so a pure
`-surfaceMode` run can be reset too (T26-R R5).
The whole of `SurfaceInspector.swift` is inside `#if DEBUG`, so the app facing users has no
developer UI and no writer for the stored tier.

**Headless screenshot probe** — `-surfaceInspectorSnapshot <path>` presents the inspector after a
1.2 s settle and writes a PNG of the window (used for the evidence screenshot; inert without the
flag).

## 9. Persistence

* Key: `mm.surfaceModes` (`SurfaceModeResolver.Keys.surfaceModes`), `AppPreferences` (JSON in
  `UserDefaults`), shape `["<surface>": "web"|"native"]`.
* Only **non-default** choices are stored; writing the default deletes the row.
* Decoding is tolerant: unknown surfaces and unknown modes are dropped, never fatal.
* The launch flag is never persisted — it is a per-run debug flag.

## 10. Test map

| Test | Pins |
|---|---|
| `testOnlyTheApprovedRegistryDefaultsToNative` | the exact approval registry (`[.auth, .calls, .sidebar, .channelView, .composer]`); every other surface falls back to `web` |
| `testTheWorkspaceFlipApprovesBothSurfacesAndOnlyThePaneHostOwnsThePane` | the 2026-10-27 scope-A decision: `.sidebar`, `.channelView` and (from pane ownership) `.composer` native; only `.channelView` pane-owning; the rest still `web` |
| `testNativeByDefaultRequiresApproval` | native-by-default only via `nativeApprovedSurfaces` |
| `testLaunchArgumentOverrideWinsOverCompileTimeDefault` | tier 1 beats tier 4; unlisted surfaces keep default |
| `testLaunchArgumentSingleTokenFormIsAccepted` | `-surfaceMode=x=y` form |
| `testUnknownSurfaceIsRejected` / `testUnknownModeIsRejected` | typo'd flags are dropped, not fatal |
| `testPersistedOverrideRoundTripsThroughAppPreferences` | tier 2 survives relaunch (fresh resolver, same defaults) |
| `testTogglingBackToDefaultClearsOverride` | minimal persisted state |
| `testClearOverrideFallsBackToDefault` / `testClearAllOverridesResetsEverySurface` | inspector reset paths |
| `testUnknownPersistedOverrideIsDropped` | tolerant decode of stale rows |
| `testLaunchArgumentBeatsPersistedOverride` | tier 1 > tier 2 |
| `testPersistedOverrideBeatsRemoteDefault` / `testRemoteDefaultFillsBetweenPersistedAndCompileTimeDefault` | tier 2 > tier 3 > tier 4 |
| `testDebugAffordancesAreCompiledInForThisBuild` | the suite runs against a DEBUG build (tiers 1/2 present) |
| `testPersistedOverrideIsIgnoredWithoutDebugAffordances` / `testLaunchOverrideIsIgnoredWithoutDebugAffordances` | R2: both debug tiers are dead without `debugAffordancesEnabled` (via the `releaseSemantics` seam) |
| `testReleaseSemanticsStillHonourRemoteDefaultAndCompileDefault` | R2: only tiers 1/2 go away in Release |
| `testClearAllOverridesAlsoDropsLaunchOverrides` / `testClearOverrideDropsLaunchOverrideForThatSurface` | R5: the reset paths beat a `-surfaceMode` launch override |
| `testHasAnyOverrideCoversLaunchAndStoredOverrides` | R5: "Reset all" is enabled for a pure launch override |
| `testCataloguePinsTheTwelveContractSurfaces` / `testPersistenceKeyIsStable` / `testModeRawValuesAreTheDocumentedSpellings` | the contract surface names, keys, spellings |
| `testDanglingSurfaceModeArgumentIsIgnored` / `testEmptyValueAndMissingSeparatorAreIgnored` | malformed flags |
| `testForceWebForThisRunBeatsLaunchArgument` / `testInspectorToggleDropsLaunchOverrideForThatSurface` | always-usable-app escape hatch |
| `testWebViewInstanceIsStableAcrossSurfaceToggles` | one webview per server; re-attach not recreate |
| `testLoadNeedTruthTable` (`WebViewStoreTests`) | R6: load / resume / leave-alone decision, incl. the stopped-mid-load row and the stale-`isLoading` row |
| `testStopForDismantleRecordsOnlyUnfinishedPages` (`WebViewStoreTests`) | R6: the dismantle records the interruption synchronously, and only for an unfinished committed page |
| `testCancellationIsNotAPageError` / `testGenuineFailureIsAPageError` (`WebViewStoreTests`) | R6: a stopped navigation stays resumable; a real failure still surfaces |
| `testLoadIfNeededLeavesAFinishedPageAlone` (`WebViewStoreTests`) | R6: finished page untouched; a new navigation clears the flag |
| `testLaunchArgumentRendersNativeChannelViewWithChromeIntact` (UI) | `-surfaceMode channelView=native` renders, chrome unaffected, "Use web view" restores a loaded webview |
| `testSurfaceInspectorTogglesChannelViewAndReturnsToWorkingState` (UI) | runtime toggle both ways, no blank screen, no duplicate webview |
| `testMidLoadSurfaceToggleResumesTheInterruptedWebview` (UI) | R6: a toggle **mid-load** must resume the interrupted navigation, not strand it (slow-subresource stub on `:8112`) |

## 11. Known limits (stated, not hidden)

* **No remote/config default is wired.** Tier 3 is an injectable closure with no producer; adding a
  real one is a separate card (it needs a server-side or build-channel source of truth). Both wiring
  shapes — a `remoteDefault:` argument and an assignment — fail
  `scripts/verify-dual-render-gates.sh`, which is the cheap early warning rather than a proof: a
  producer routed indirectly past the regex would still only be caught by a Release build and review
  (§5 states the limit).
* **Only `channelView` has a host.** The other 11 surfaces are togglable (inspector / launch flag)
  and resolve correctly, but no view mounts them yet — their hosts arrive with their screen cards.
  Toggling e.g. `threads` therefore changes nothing on screen today, because threads are rendered
  *inside* the web app; that is exactly the state until S13 lands.
* **Native surfaces: five.** `.auth`, `.calls`, `.sidebar`, `.channelView` and `.composer` are
  native by default (§5); the rest require a passed `-AV` card. The workspace entries carry the
  owner's 2026-10-27 decision because their validators deferred the flip, and `.composer` follows
  from pane ownership (§12.1).
* **A non-pane native surface still loads a full webview — the switch buys no memory for it
  (T26-R R4).** Every approved surface except the pane host (`.auth`, `.calls`, `.sidebar`) renders
  beside a fully mounted webview: same process count, same memory, same session. The exception is
  the pane host itself — §12's release policy is now live (`paneOwningSurfaces = [.channelView]`), so
  a native workspace releases the per-server `WKWebView` once its navigation settles. For the other
  surfaces the dual-render switch is a *rendering* switch, not a resource one. The follow-up
  decision — **when and whether to evict or park the webview** — is §12. It is recorded there and
  implemented as a pane-level rule only; a per-surface eviction stays unimplemented.
* **A mid-load surface toggle no longer strands the page (T26-R R6, was a real bug — two variants).**
  The old `ContentView.loadIfNeeded()` guarded on `store.url == nil`, so a load interrupted by
  `dismantleUIView` → `stopLoading()` (committed page, nothing in flight) was never resumed — the
  pane stayed permanently incomplete. **Reproduced** with
  `testMidLoadSurfaceToggleResumesTheInterruptedWebview` against a slow-subresource stub
  (`build/uitest-server/mm_stub.py --port 8112 --stall-image 45`): pre-fix the stub saw two page
  requests before the toggle and **none** after, and the sign-in button never appeared (observed at
  +75 s; the run was killed in failure triage, see `docs/t26r-build-note.md`). **Fixed** by
  `WebViewStore.loadNeed`/`loadIfNeeded(_:)` (§7): a committed-but-unfinished navigation is
  re-issued, an in-flight or finished one is not. Re-running the *batch* (three UI flows in one
  `xcodebuild` invocation) then failed the same way once while single-test runs passed: the residual
  variant is a **race on `isLoading`** — `WKWebView.isLoading` flips to `false` asynchronously after
  `stopLoading()`, so a re-attach in that window read `true`, answered "in flight, leave it alone",
  and never retried. **Fixed** by `stopForDismantle()` recording the interruption synchronously (and
  by never recording a cancellation as a page error: `markPageLoadFailed`/`isCancellation` keep a
  stopped navigation resumable instead of painting the retry overlay). Both variants are pinned by
  the truth table (`testLoadNeedTruthTable`, `testStopForDismantleRecordsOnlyUnfinishedPages`,
  `testCancellationIsNotAPageError`, `testGenuineFailureIsAPageError`) and the UI flow passed in the
  batch configuration (79.2 s) that had failed. The UI flow skips (with the exact stub command in the
  skip message) when the `:8112` fixture is not running, because the stub lives in the gitignored
  `build/uitest-server/` — a missing fixture must not look like a regression.
* **The inspector and both debug tiers are DEBUG-only.** The inspector *file* is `#if DEBUG`; the
  writers of the stored tier are `#if DEBUG`; the read path decodes nothing in Release (§8).
  There is no runtime check to bypass in a shipped binary because the code is absent, and
  `scripts/verify-dual-render-gates.sh` proves it stays that way.
* **Launch flag is DEBUG-only**, so the acceptance criterion "launch with
  `-surfaceMode channelView=native`" is a Debug-build behaviour by construction (Release ignores it
  rather than half-honouring it).

## 12. Webview release policy (T26-R R4 decision)

**Decided 2026-10-24 by `mmios-architect` (card `t_58d5611e`). Status: decided and implemented**
(T26-R R4a, 2026-10-24), **live since the 2026-10-27 workspace flip** (`t_c93b8337`: `.channelView`
approved and pane-owning). Validation: the pane-level claim is audited by the `-AV` programme, and
the post-flip QA round is recorded in `docs/tc93b-build-note.md`.

### 12.1 The rule

> **A per-server webview is released only when an `-AV`-approved card renders the *whole pane* it
> occupies.** Warm by default; release is a **pane-level** decision, never a per-surface one.

`ViewStore.release(serverID:)` requires **all four** of:

| # | Condition | Why it is there |
|---|---|---|
| 1 | the **pane host surface** resolves `.native` (today `channelView`: the region the one-per-server webview maps to) | the only surface whose native branch takes the webview's place |
| 2 | that surface is in `SurfaceDefaults.nativeApprovedSurfaces` (§5) | approval is the only evidence that a *real card* exists — a placeholder or skeleton can never be approved, so eviction can never hide behind one |
| 3 | that surface is in `SurfaceDefaults.paneOwningSurfaces` — since the 2026-10-27 flip, `[.channelView]` | the card claims it renders every region the webview paints (sidebar, header, post list, composer, RHS) — nothing in the web app is still needed |
| 4 | the store has no navigation in flight (`isLoading == false`) | never kill a login/SSO mid-flight |

**Registry invariant:** `paneOwningSurfaces ⊆ nativeApprovedSurfaces`, checked by
`scripts/verify-dual-render-gates.sh`. A surface cannot be declared pane-owning before it passes
`-AV`; the pre-approval measurement in §12.6 uses a `PERF_PROBE`-only arm instead of the registry.

**Since the 2026-10-27 flip the policy is live**: `paneOwningSurfaces = [.channelView]` and
`.channelView` is approved, so a Release build with no flags releases the per-server webview once its
navigation settles. The rule did not change — only which registry entries it consults. `ViewStore`
destroys the store rather than parking it (§12.2), and the escape hatch (§8) still works: "Use web
view" flips the pane surface to `.web` for that run and the web branch recreates the store.

### 12.2 What "release" means — destroy, not park

| Candidate | Page memory | WebContent/Networking process | Verdict |
|---|---|---|---|
| Leave as-is (today) | kept | kept | rejected: this is the R4 problem |
| **Park** (`loadHTMLString("about:blank")`, keep the object) | freed | **kept** | rejected: page lost *and* process kept — the worst of both, and it moves neither §12.6 metric |
| **Destroy** (drop the store, let the `WKWebView` deallocate) | freed | freed | **chosen** |

`release(serverID:)` does exactly this: `stopLoading()` → nil the navigation/UI delegates → record
`lastURLs[serverID] = store.url` → drop the store from `ViewStore.stores`. It does **not** call
`WKWebsiteDataStore.remove(forIdentifier:)` — that is `remove(serverID:)` (server removal) and it is
the only thing that logs the user out.

### 12.3 What survives a release, and what does not

| Survives | Lost |
|---|---|
| cookies, localStorage, IndexedDB, the signed-in **session** (persistent `WKWebsiteDataStore(forIdentifier:)`) | the in-memory page: DOM, JS heap, scroll position, SPA router state |
| certificate trust decisions (`CertTrust` is Keychain-backed, not webview state) | JS-held drafts not yet persisted by the server |
| downloads, notifications, mention polling (all native) | `ThemeSync`/`Bridge` pushes (they no-op without a store) |
| the last page URL (`ViewStore.lastURLs`) | — |

The return trip is therefore **one page load + SPA bootstrap**, normally **no re-login**, landing on
the channel the user was on (`lastURLs[serverID] ?? server.url`). An SSO IdP that does not keep its own
session may still re-prompt; that is the same cost as a cold launch, stated rather than hidden.

### 12.4 The return trip, and the honest weakening of §7

"Use web view" is unchanged: one tap, `forceWebForThisRun`, instant resolution flip. What changes is
what the pane shows *after* the flip when the store was released:

1. the web branch's `onAppear` recreates the store (`ViewStore.ensureStore(for:)` — the **creating**
   accessor) and calls `loadIfNeeded(lastURLs[serverID] ?? server.url)`;
2. until the first `didCommit` the pane shows a **blocking, honest** "Reopening web view…" state with
   a `ProgressView` — no blank pane, no second tap, no silent dead tap;
3. then the web app, signed in, on the remembered page.

§7's "re-attach is instant" still holds for every warm webview — which is every webview under this
policy **except** a released pane. That exception is the price of the memory win and is stated here
instead of being papered over.

**The resurrection trap.** `ViewStore.view(for:)` *creates* a store on first use, and `RootView`
currently calls it from its own `body` (toolbar + scene). A released store must not be recreated by a
SwiftUI body pass, or the policy silently defeats itself. Reads go through the **non-creating**
`view(forServerID:)`; only the web branch's `onAppear` may create. `RootView`'s `WebNavToolbar` is
omitted when that read is `nil` (Back/Reload are webview-only chrome).

### 12.5 Where the decision lives in code

| File | Change |
|---|---|
| `Core/RenderMode.swift` | `SurfaceDefaults.paneOwningSurfaces: Set<Surface> = [.channelView]` + doc: pane ownership is an `-AV` claim |
| `Core/ViewStore.swift` | `release(serverID:)`, `ensureStore(for:)`, `lastURLs`, and the pure predicate `WebViewReleasePolicy.mayRelease(...)` |
| `UI/ContentView.swift` | web branch renders the reloading state until the store exists and commits |
| `UI/RootView.swift` | **the only** caller of `release(...)`: on `onAppear` and on `onChange` of the pane surface's resolved mode; toolbar reads the non-creating accessor |
| `Core/PerfProbe.swift` | a `nativeEvicted` measurement mode (§12.6); it must not resurrect a released store |
| `scripts/verify-dual-render-gates.sh` | registry invariant `paneOwningSurfaces ⊆ nativeApprovedSurfaces`, and no shipping call site may pass `allowUnapproved: true` |

The predicate is explicit about the one sanctioned bypass:

```swift
static func mayRelease(paneSurfaceResolved: SurfaceRenderMode,
                       approved: Bool,
                       paneOwning: Bool,
                       navigationInFlight: Bool,
                       allowUnapproved: Bool = false) -> Bool
```

`allowUnapproved: true` exists for exactly one caller — the perf probe's `nativeEvicted` arm, inside
`#if DEBUG || PERF_PROBE` — so the pre-approval measurement never becomes a shipping bypass. The gate
script asserts no other call site passes it.

### 12.6 Measurement — the metric the change must move

Ranked by authority:

1. **WebContent process count** for the released server: **1 → 0**
   (`run.json` → `tracked_pids.webcontent == []`, `per_process_footprint.webcontent == []`).
2. **Steady-state total physical footprint** of the `nativeEvicted` arm: from ≈ `web` down to
   **≤ `shell` + 60 MiB** (headroom for the native card's own views/view models).
3. RSS total, secondary only (jetsam acts on footprint).

The probe's existing `native` arm is **warm** by construction: it creates the store, waits for the
workspace, logs in, and only then measures the stand-in on top (`PerfProbe.run` → `config.mode ==
.native`). That is the correct "before" data point (today's `native` should measure ≈ `web`), but a
released pane cannot run that DOM sequence at all, so `nativeEvicted` is a separate arm: seed the
server config, release the store before sampling, run **no** DOM stages, sit out the steady-state
window, and record `note: pane released, no webview`. Its footprint is comparable to `shell` + the
native card, not to the warm arm's post-login state — the comparison that carries the claim is the
WebContent count and the shell-relative ceiling, and §12.6 says so instead of pretending the arms are
interchangeable.

Before-numbers from the parked T27 harness (Mac Catalyst, Release + `PERF_PROBE`,
`build/perf/20261024-140359`). **Superseded by the landed T27 baseline** —
`docs/perf/README.md` + `docs/perf/baseline-2026-10-24.json` (12 arms, Catalyst + Simulator, warm
`native` arm included; method and limits in `docs/t27-build-note.md`). The landed medians are
**562.1 MB** (Catalyst) / **460.7 MB** (Simulator) of steady footprint for one loaded webview over
a 30.0 / 28.6 MB shell floor, ~90 % of it WebContent, and the warm `native` arm still carries
252.6 / 146.4 MB of WebContent — §11's prediction as a measured number. The 14:01/14:03 table is
kept only as the provenance of the decision's earlier draft:

| Run | app | WebContent | GPU | Networking | total footprint | RSS total |
|---|---|---|---|---|---|---|
| `shell` (no server, no webview) | 28.9 MiB | 0 (no process) | 0 | 0 | 28.9 MiB | 80.8 MiB |
| `web` 2026-10-24 14:03 | 38.0 MiB | 426.1 MiB | 19.0 MiB | 16.3 MiB | **499.5 MiB** | 785.3 MiB |
| `web` 2026-10-24 14:01 | 40.9 MiB | 358.5 MiB | 30.9 MiB | 28.3 MiB | 458.7 MiB | 456.5 MiB |

So one loaded webview costs **≈ 420–470 MiB** of footprint, **85–93 % of it in WebContent**. That is the
delta a released pane must reclaim; a policy that keeps the WebContent process (parking) reclaims none
of the metric that justifies the programme.

Sequencing, non-negotiable: **T27 must land a green baseline first**, and it must include a warm
`native` arm. The 14:01/14:03 runs still failed `scrollPosts`/`openThread`; the landed baseline
(`docs/perf/README.md`, 2026-10-24) is green on every stage of both targets and turns §11's
"native costs the same as web" from a code-reading prediction into the measured 252.6 / 146.4 MB of
WebContent the warm `native` arm still carries. The implementation card is parented on T27.

### 12.7 Rejected alternatives

| Alternative | Why it was rejected |
|---|---|
| Release whenever a surface resolves `.native` | debug tiers (inspector, `-surfaceMode`) reach `.native` with no card; releasing behind a stand-in would strand the user on a stand-in *and* pay a reload, and would break `testLaunchArgumentRendersNativeChannelViewWithChromeIntact` |
| Release when *all* surfaces resolve native | 11 of the 12 surfaces have no host at all today, so "all native" can be true while the webview is still the only thing painting the sidebar. Pane ownership, not a resolution count, is the real condition |
| Park (`about:blank`) | frees the page but keeps the process: neither §12.6 metric moves |
| Release on `.background` only | keeps the escape hatch instant, but leaves the measured foreground footprint unchanged, so it demonstrates nothing. Legitimate as a *complement* later; it cannot be the v1 policy |
| Release per region (e.g. when `threads` ports) | the 12 surfaces are regions of **one** web app; a region card cannot replace the pane |

### 12.8 Consequences and risks

* **Notification taps and deep links.** `NotificationWorker` and `DeepLinkRouter` already guard on
  `view(forServerID:)` being nil, so with the pane released they **silently no-op**. A pane-owning
  card must route a notification tap natively to that channel (implication for T43); until then a
  released pane degrades a tap to "open on the native pane", which is stated, not silent.
* **Multi-server.** Resolution is app-wide, so a pane-owning release applies to *every* server's
  store uniformly (`RootView` mounts all of them). A future per-server override would have to
  re-open this rule.
* **The win arrives with the composite pane, not with the first region card.** Per-surface memory
  only drops when one card renders the whole work area; the first realistic candidate is a native
  channel view that also renders the native sidebar + composer (T32/T33/T34/T35 composed), or the
  native workspace skeleton (T30). This is a schedule consequence, stated so nobody re-files R4 as a
  bug when porting `reactions` does not move the number.
* **`-AV` obligation for a pane-owning card.** Approving one requires proving, with the webview
  released, that *every* region the webview used to paint is still rendered natively (one screenshot
  per region in the §10 style) — not just the surface the card is named after.
