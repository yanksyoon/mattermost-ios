# Dual-render harness (T26) — per-surface native vs WKWebView

Status: **landed** (T26, 2026-10-24). Owner: `mmios-ios`. Validator: `T26-AV`.
Code: `Mattermost/Core/RenderMode.swift`, `Mattermost/Core/SurfaceModeResolver.swift`,
`Mattermost/UI/SurfaceHost.swift`, `Mattermost/UI/UnportedSurfaceView.swift`,
`Mattermost/UI/SurfaceInspector.swift`.
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
| `UI/UnportedSurfaceView.swift` | The honest stand-in used when a surface is native but no screen card is approved yet — never a blank pane. |
| `UI/SurfaceInspector.swift` | DEBUG-only sheet: every surface, its resolved mode, a Web/Native toggle, "Reset all". |
| `Core/AppPreferences.swift` | Persistence of the user's overrides (`mm.surfaceModes`). |
| `UI/ContentView.swift` | The first (and today only) consumer: gates the per-server webview pane as `Surface.channelView`. |
| `UI/RootView.swift` | Unchanged on purpose: per-server scene mounting, toolbar, server switcher, settings, downloads are shell chrome and are **not** gated by a surface. |

## 3. Resolution order

`SurfaceModeResolver.resolvedMode(for:)` — highest priority first:

1. **Ephemeral launch override** — `-surfaceMode <surface>=<mode>` for this run
   (`DEBUG` builds only; a Release build parses no launch override at all).
2. **Persisted user override** — written by the Surface inspector to `AppPreferences`
   under `mm.surfaceModes` (survives relaunch).
3. **Remote/config default** — an injected `remoteDefault: (Surface) -> SurfaceRenderMode?` closure.
   **No provider is wired yet** (nothing in the product supplies a server- or build-driven default),
   so this tier is a documented seam, not a live source. It exists so a future remote default does
   not require touching the resolver.
4. **Compile-time default** — `SurfaceDefaults.defaultMode(for:)`, i.e.
   `native` **only** for a surface listed in `SurfaceDefaults.nativeApprovedSurfaces`, otherwise
   `web`. That registry is **empty today**, so every surface is `web` and the webview is the
   complete fallback.

Two rules make the switch behave the way a user expects at runtime:

- **An explicit user pick beats the launch flag for that surface.** `setOverride` drops this run's
  `-surfaceMode` entry for that surface, so a stale debug flag can never make a toggle look dead.
  Other surfaces' launch overrides are untouched. (`testInspectorToggleDropsLaunchOverrideForThatSurface`)
- **Writing the compile-time default clears the stored row.** Toggling back to `web` leaves no
  persisted override behind, so the default keeps ruling. (`testTogglingBackToDefaultClearsOverride`)

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
| `calls` | S33 Calls (currently "webview always, may cut for v1") |
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
public static let nativeApprovedSurfaces: Set<Surface> = []
```

* Empty registry = web everywhere (today's state, and the state any `-AV`-less build must stay in).
* Native-by-default is **unreachable** any other way: `SurfaceDefaults.defaultMode(for:)` is the
  only function that decides it, and it consults nothing but that set
  (`testEverySurfaceDefaultsToWeb`, `testNativeByDefaultRequiresApproval` pin this).
* A card that hard-wires `.native` in a view, constructs its own `WKWebView`, or adds a private
  bypass fails `-AV` review — see §6 step 4 and §8.

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
* **The webview is re-attached, never recreated.** The `web` branch must render the store the shell
  already owns (`ViewStore.view(for:)` → `WebViewStore.webView`); the store owns the `WKWebView`
  instance. Dismantling the `UIViewRepresentable` does not destroy the webview — cookies, storage,
  signed-in state and the in-memory page survive, and switching back re-attaches the *same* object
  (`testWebViewInstanceIsStableAcrossSurfaceToggles`). Constructing a `WKWebView` inside a surface's
  `web` branch is a contract violation.
* **No duplicate webview.** One `WebViewStore` per server (`ViewStore`), therefore one `WKWebView`
  per server regardless of how many times a surface is toggled.
* **Re-creatable on demand.** A store that was never loaded (app launched straight into a native
  surface) or was torn down (`ViewStore.remove(serverID:)` on server removal) loads the first time
  the `web` branch appears — `ContentView.loadIfNeeded()` guards on `store.url == nil`, so an
  already-loaded webview is never re-navigated.
* **Never a blank pane.** A `native` decision with no approved card renders `UnportedSurfaceView`,
  which explains the state and offers "Use web view".
* **Always a way back.** "Use web view" (and the inspector toggle) call
  `SurfaceModeResolver.forceWebForThisRun(_:)` / `setOverride(_:for:)`, which also drop this run's
  launch override for that surface. There is no sequence of debug flags that can strand the app on
  an unported surface (`testForceWebForThisRunBeatsLaunchArgument`).

## 8. Debug affordances (all DEBUG-only)

**Launch flag** — two accepted forms, repeatable:

```
-surfaceMode channelView=native
-surfaceMode=channelView=native
-surfaceMode channelView=native -surfaceMode threads=web
```

`SurfaceModeResolver.isDebug` is `false` in Release, and then no launch argument is parsed at all —
a debug flag can never ship side effects in a shipped binary.

**Surface inspector** — `Settings → Developer → Surface render modes…`
(`accessibilityIdentifier: surfaceInspectorButton`, sheet: `surfaceInspector`, rows:
`surfaceMode.<rawValue>`). Each row shows the surface, its **resolved** mode badge, a "launch
override" chip while a `-surfaceMode` entry still holds, its compile default, and a Web/Native
segmented picker writing a persisted override. "Reset all to defaults" clears every row.
The section is inside `#if DEBUG`, so the app facing users has no developer UI.

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
| `testEverySurfaceDefaultsToWeb` | empty approval registry; web fallback everywhere |
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
| `testCataloguePinsTheTwelveContractSurfaces` / `testPersistenceKeyIsStable` / `testModeRawValuesAreTheDocumentedSpellings` | the contract surface names, keys, spellings |
| `testDanglingSurfaceModeArgumentIsIgnored` / `testEmptyValueAndMissingSeparatorAreIgnored` | malformed flags |
| `testForceWebForThisRunBeatsLaunchArgument` / `testInspectorToggleDropsLaunchOverrideForThatSurface` | always-usable-app escape hatch |
| `testWebViewInstanceIsStableAcrossSurfaceToggles` | one webview per server; re-attach not recreate |
| `testLaunchArgumentRendersNativeChannelViewWithChromeIntact` (UI) | `-surfaceMode channelView=native` renders, chrome unaffected, "Use web view" restores a loaded webview |
| `testSurfaceInspectorTogglesChannelViewAndReturnsToWorkingState` (UI) | runtime toggle both ways, no blank screen, no duplicate webview |

## 11. Known limits (stated, not hidden)

* **No remote/config default is wired.** Tier 3 is an injectable closure with no producer; adding a
  real one is a separate card (it needs a server-side or build-channel source of truth).
* **Only `channelView` has a host.** The other 11 surfaces are togglable (inspector / launch flag)
  and resolve correctly, but no view mounts them yet — their hosts arrive with their screen cards.
  Toggling e.g. `threads` therefore changes nothing on screen today, because threads are rendered
  *inside* the web app; that is exactly the state until S13 lands.
* **Native surfaces: none.** `nativeApprovedSurfaces` is empty by design; the first entry requires a
  passed `-AV` card (§5).
* **The inspector is DEBUG-only.** Verified by `#if DEBUG` around the Settings section and the
  launch-argument parse; there is no runtime check to bypass in Release because the code is absent.
* **Launch flag is DEBUG-only**, so the acceptance criterion "launch with
  `-surfaceMode channelView=native`" is a Debug-build behaviour by construction (Release ignores it
  rather than half-honouring it).
