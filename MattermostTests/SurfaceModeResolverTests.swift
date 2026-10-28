import XCTest
@testable import Mattermost

/// Unit tests for the T26 dual-render decision point (`Surface`, `SurfaceDefaults`,
/// `SurfaceModeResolver`). These pin the resolution order (debug override — launch argument or
/// persisted inspector value — -> remote/config default -> compile-time default), the persistence
/// round-trip through `AppPreferences`, and the unknown-surface/mode rejection so a typo'd debug
/// flag degrades to the default instead of crashing.
@MainActor
final class SurfaceModeResolverTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SurfaceModeResolverTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeResolver(arguments: [String] = [],
                              remoteDefault: ((Surface) -> SurfaceRenderMode?)? = nil) -> SurfaceModeResolver {
        SurfaceModeResolver(preferences: AppPreferences(defaults: defaults),
                            arguments: arguments,
                            remoteDefault: remoteDefault)
    }

    // MARK: Compile-time default

    /// The registry is the **only** route to native-by-default (`docs/dual-render.md` §5). It holds
    /// five entries: `.auth` (T31-AV, F8), `.calls` (T44d-AV `t_466e8e90`), and the workspace set
    /// `.sidebar` + `.channelView` + `.composer` from the owner's 2026-10-27 scope-A decision
    /// (`t_c93b8337`; `.composer` follows from pane ownership — the pane draws the composer inside
    /// itself). Every other surface still falls back to the web view. Pinning the exact set is the
    /// point: a card that quietly adds its surface here fails this test and the `-AV` gate script.
    func testOnlyTheApprovedRegistryDefaultsToNative() {
        XCTAssertEqual(SurfaceDefaults.nativeApprovedSurfaces,
                      [.auth, .calls, .sidebar, .channelView, .composer],
                      "T31-AV approved `.auth`, T44d-AV approved `.calls`, and the owner approved the "
                      + "workspace on 2026-10-27; adding to this set is an -AV claim")
        let resolver = makeResolver()
        for surface in Surface.allCases {
            let expected: SurfaceRenderMode = SurfaceDefaults.nativeApprovedSurfaces.contains(surface)
                ? .native : .web
            XCTAssertEqual(resolver.resolvedMode(for: surface), expected,
                           "\(surface) must resolve to its compile-time default")
        }
    }

    /// Native-by-default is reached only through the approval registry, never inline.
    func testNativeByDefaultRequiresApproval() {
        // The structural rule: `defaultMode` returns native ONLY for an approved surface.
        for surface in Surface.allCases {
            let expected: SurfaceRenderMode = SurfaceDefaults.nativeApprovedSurfaces.contains(surface)
                ? .native : .web
            XCTAssertEqual(SurfaceDefaults.defaultMode(for: surface), expected,
                           "\(surface): only an approved surface may default native")
        }
        XCTAssertEqual(SurfaceDefaults.defaultMode(for: .auth), .native,
                       "the approved surface really is native by default")
        XCTAssertEqual(SurfaceDefaults.defaultMode(for: .threads), .web,
                       "an unapproved surface really is web by default")
    }

    /// Both halves of the 2026-10-27 scope-A decision (`t_c93b8337`), pinned so neither can drift:
    /// `.sidebar` is native by default **and** `.channelView` is native by default *and* pane-owning.
    /// `.composer` is part of the same release because the pane-owning card draws the composer inside
    /// the pane: leaving it `web` over a released webview produces a dead input placeholder.
    ///
    /// The owner approved sidebar + channel view as one release; the earlier `.sidebar`-only reading
    /// (where `.channelView` stayed `web`) is deliberately not the shipped state — with the pane host
    /// still `web` the native shell would be painted over a live WKWebView. A reviewer who sees this
    /// test change is looking at a product decision, not at a refactor.
    func testTheWorkspaceFlipApprovesBothSurfacesAndOnlyThePaneHostOwnsThePane() {
        XCTAssertEqual(SurfaceDefaults.defaultMode(for: .sidebar), .native,
                      "`.sidebar` (team rail + channel list) is approved native-by-default")
        XCTAssertEqual(SurfaceDefaults.defaultMode(for: .channelView), .native,
                      "`.channelView` is approved native-by-default too (scope A) — the pane host "
                      + "mounting native is what makes the native workspace reachable in Release")
        XCTAssertEqual(SurfaceDefaults.defaultMode(for: .composer), .native,
                      "the pane-owning card draws the composer inside the pane; a `web` composer "
                      + "there is a dead placeholder once the webview is released")
        XCTAssertEqual(SurfaceDefaults.paneOwningSurfaces, [.channelView],
                      "only the pane host may release the per-server webview; a sidebar does not "
                      + "own the work area")
        XCTAssertTrue(SurfaceDefaults.paneOwningSurfaces.isSubset(of: SurfaceDefaults.nativeApprovedSurfaces),
                      "pane ownership is the stronger claim: it must be a subset of the -AV registry")
        // Everything else in the workspace stays web: the flip is scoped to the surfaces above.
        for surface in [Surface.threads, .search, .profile, .activity, .channelInfo, .plugins] {
            XCTAssertEqual(SurfaceDefaults.defaultMode(for: surface), .web,
                           "\(surface.rawValue) was not part of the approved scope and must stay web")
        }
    }

    // MARK: Debug override wins (launch argument)

    func testLaunchArgumentOverrideWinsOverCompileTimeDefault() {
        let resolver = makeResolver(arguments: ["-surfaceMode", "channelView=native"])
        XCTAssertEqual(resolver.resolvedMode(for: .channelView), .native)
        XCTAssertEqual(resolver.resolvedMode(for: .threads), .web, "unlisted surfaces keep their default")
        XCTAssertTrue(resolver.isLaunchOverridden(.channelView))
    }

    func testLaunchArgumentSingleTokenFormIsAccepted() {
        let resolver = makeResolver(arguments: ["-surfaceMode=composer=native", "foo"])
        XCTAssertEqual(resolver.resolvedMode(for: .composer), .native)
        XCTAssertEqual(resolver.resolvedMode(for: .threads), .web)
    }

    func testUnknownSurfaceIsRejected() {
        // A typo'd surface must be ignored (and never crash); the rest of the run is untouched.
        let resolver = makeResolver(arguments: ["-surfaceMode", "notASurface=native",
                                                "-surfaceMode", "channelView=native"])
        XCTAssertEqual(resolver.resolvedMode(for: .channelView), .native)
        XCTAssertEqual(resolver.resolvedMode(for: .threads), .web)
        XCTAssertEqual(resolver.launchOverrides.count, 1,
                       "only the valid pair is retained, the unknown surface is dropped")
    }

    func testUnknownModeIsRejected() {
        let resolver = makeResolver(arguments: ["-surfaceMode", "threads=flash",
                                                "-surfaceMode", "auth=web"])
        XCTAssertEqual(resolver.resolvedMode(for: .threads), .web, "invalid mode is ignored")
        XCTAssertEqual(resolver.resolvedMode(for: .auth), .web)
        XCTAssertEqual(resolver.launchOverrides.count, 1, "valid pair retained; bad mode dropped")
    }

    // MARK: Persisted override (runtime toggle) round-trips through AppPreferences

    func testPersistedOverrideRoundTripsThroughAppPreferences() {
        let first = makeResolver()
        first.setOverride(.native, for: .search)

        // A *fresh* resolver over the same UserDefaults must read the override back (relaunch
        // parity: the user's inspector choice survives a restart).
        let second = makeResolver()
        XCTAssertEqual(second.resolvedMode(for: .search), .native)
        XCTAssertEqual(second.overrides[.search], .native)

        // And an unrelated surface still defaults to web.
        XCTAssertEqual(second.resolvedMode(for: .threads), .web)
    }

    func testTogglingBackToDefaultClearsOverride() {
        let resolver = makeResolver()
        resolver.setOverride(.native, for: .search)
        XCTAssertEqual(resolver.resolvedMode(for: .search), .native)

        // Toggling back to web (the compile default) must clear the row so the default rules.
        resolver.setOverride(.web, for: .search)
        XCTAssertEqual(resolver.resolvedMode(for: .search), .web)
        XCTAssertNil(resolver.overrides[.search], "writing the default removes the override row")

        // The persisted store is clean too.
        XCTAssertEqual(makeResolver().resolvedMode(for: .search), .web)
    }

    func testClearOverrideFallsBackToDefault() {
        let resolver = makeResolver()
        resolver.setOverride(.native, for: .plugins)
        resolver.clearOverride(for: .plugins)
        XCTAssertEqual(resolver.resolvedMode(for: .plugins), .web)
        XCTAssertEqual(makeResolver().resolvedMode(for: .plugins), .web)
    }

    func testClearAllOverridesResetsEverySurface() {
        let resolver = makeResolver()
        resolver.setOverride(.native, for: .channelInfo)
        resolver.setOverride(.native, for: .threads)
        resolver.clearAllOverrides()
        XCTAssertTrue(resolver.overrides.isEmpty)
        XCTAssertEqual(makeResolver().resolvedMode(for: .channelInfo), .web)
        XCTAssertEqual(makeResolver().resolvedMode(for: .threads), .web)
    }

    /// Stale/unknown persisted keys are dropped (a future build may retire a surface; stale
    /// rows must never crash the shell or survive as confusing no-ops).
    func testUnknownPersistedOverrideIsDropped() {
        let prefs = AppPreferences(defaults: defaults)
        prefs.set(["threads": "native", "bogusSurface": "native", "activity": "weirdMode"],
                  forKey: SurfaceModeResolver.Keys.surfaceModes)

        let resolver = makeResolver()
        XCTAssertEqual(resolver.resolvedMode(for: .threads), .native)
        XCTAssertEqual(resolver.resolvedMode(for: .activity), .web, "invalid persisted mode is dropped")
        XCTAssertEqual(resolver.overrides.count, 1, "only the valid row survives decoding")
    }

    // MARK: Resolution order between the tiers

    func testLaunchArgumentBeatsPersistedOverride() {
        let first = makeResolver()
        first.setOverride(.native, for: .threads)

        // A launch flag for the same surface wins this run over the persisted inspector setting.
        let resolver = makeResolver(arguments: ["-surfaceMode", "threads=web"])
        XCTAssertEqual(resolver.resolvedMode(for: .threads), .web)
    }

    func testPersistedOverrideBeatsRemoteDefault() {
        // A persisted user choice (tier 2) outranks a remote/config default (tier 3). Note the
        // asymmetry that makes this test necessary in this direction: the persisted tier can only
        // ever hold the *non-default* value (`setOverride` drops a row equal to the compile
        // default), so the remote default has to disagree with the user for precedence to show.
        let resolver = makeResolver(remoteDefault: { $0 == .profile ? .web : .native })
        resolver.setOverride(.native, for: .profile)
        XCTAssertEqual(resolver.resolvedMode(for: .profile), .native,
                       "the persisted override wins over the remote default")
        XCTAssertEqual(resolver.resolvedMode(for: .threads), .native,
                       "surface without an override still takes the remote default")
    }

    func testRemoteDefaultFillsBetweenPersistedAndCompileTimeDefault() {
        let resolver = makeResolver(remoteDefault: { $0 == .profile ? .native : nil })
        XCTAssertEqual(resolver.resolvedMode(for: .profile), .native)
        XCTAssertEqual(resolver.resolvedMode(for: .threads), .web,
                       "unhandled surfaces fall through to the compile-time default")
    }

    // MARK: The single decision point

    func testInspectorToggleRoundTripsLive() {
        let resolver = makeResolver()
        let before = resolver.resolvedMode(for: .threads)

        resolver.setOverride(.native, for: .threads)
        XCTAssertEqual(resolver.resolvedMode(for: .threads), .native)
        resolver.clearOverride(for: .threads)
        XCTAssertEqual(resolver.resolvedMode(for: .threads), before)

        // No duplicated webview is a UI-layer property; the resolver must simply return to a
        // stable `.web` decision after the cycle so the surface can be re-mounted once.
        XCTAssertEqual(resolver.resolvedMode(for: .threads), .web)
    }

    // MARK: Surface catalogue + persistence-key contract

    /// The 12 surfaces named in the T26 card must all exist and keep their raw values: those
    /// strings are the launch-argument keys (`-surfaceMode <rawValue>=<mode>`) and the persisted
    /// override keys, so renaming one silently breaks a user's stored choice.
    func testCataloguePinsTheTwelveContractSurfaces() {
        let required: [(Surface, String)] = [
            (.auth, "auth"), (.sidebar, "sidebar"), (.channelView, "channelView"),
            (.composer, "composer"), (.threads, "threads"), (.search, "search"),
            (.profile, "profile"), (.activity, "activity"), (.settings, "settings"),
            (.channelInfo, "channelInfo"), (.calls, "calls"), (.plugins, "plugins")
        ]
        for (surface, rawValue) in required {
            XCTAssertEqual(surface.rawValue, rawValue, "\(rawValue) is part of the T26 contract")
            XCTAssertTrue(Surface.allCases.contains(surface))
            XCTAssertEqual(Surface(rawValue: rawValue), surface, "raw value must round-trip")
            XCTAssertFalse(surface.title.isEmpty, "every surface needs an inspector title")
        }
        XCTAssertEqual(Set(Surface.allCases).count, Surface.allCases.count, "no duplicate surfaces")
    }

    func testPersistenceKeyIsStable() {
        // Changing this key orphans every user's stored per-surface choice.
        XCTAssertEqual(SurfaceModeResolver.Keys.surfaceModes, "mm.surfaceModes")
    }

    // MARK: T30 — the `shell` launch alias

    /// `-surfaceMode shell=native` is the T30 card's flag spelling. `shell` is **not** a `Surface`
    /// (the 12 inventory surfaces are the render regions, and a `shell` region would duplicate
    /// `channelView` in the inspector, in `mm.surfaceModes` and in the approval registry), so it is
    /// a launch-only alias for the pane host surface.
    func testShellLaunchAliasAddressesThePaneHostSurface() {
        XCTAssertEqual(SurfaceDefaults.paneHostAlias, "shell")
        XCTAssertNil(Surface(rawValue: "shell"), "the alias must not become a 13th surface")

        let resolver = makeResolver(arguments: ["-surfaceMode", "shell=native"])
        XCTAssertEqual(resolver.resolvedMode(for: SurfaceDefaults.paneHostSurface), .native)
        XCTAssertTrue(resolver.isLaunchOverridden(SurfaceDefaults.paneHostSurface))
        // The alias names one surface, not the app: everything else keeps its compile-time default.
        // (Since T31-R that is not uniformly `.web` — `.auth` is approved native — so the assertion is
        // about *not being steered by this flag*, which is the property the alias can break.)
        for surface in Surface.allCases where surface != SurfaceDefaults.paneHostSurface {
            XCTAssertFalse(resolver.isLaunchOverridden(surface),
                           "\(surface) must not be steered by the shell alias")
            XCTAssertEqual(resolver.resolvedMode(for: surface),
                           SurfaceDefaults.defaultMode(for: surface),
                           "\(surface) keeps its compile-time default")
        }
    }

    /// The alias resolves through the same launch parser, so its malformed forms degrade exactly
    /// like every other flag (`shell=nativee`, `shellx=native`, an unknown mode).
    ///
    /// "Degrade to the default" is not "degrade to `.web`": since the 2026-10-27 flip the pane
    /// host's compile-time default is `.native`, so the assertion is against `defaultMode(for:)`.
    /// What must hold is that a malformed alias steers nothing.
    func testMalformedShellAliasDegradesToTheDefault() {
        let fallback = SurfaceDefaults.defaultMode(for: SurfaceDefaults.paneHostSurface)
        XCTAssertEqual(makeResolver(arguments: ["-surfaceMode", "shell=nativee"])
                        .resolvedMode(for: SurfaceDefaults.paneHostSurface), fallback)
        XCTAssertEqual(makeResolver(arguments: ["-surfaceMode", "shellx=native"])
                        .resolvedMode(for: SurfaceDefaults.paneHostSurface), fallback)
        XCTAssertEqual(makeResolver(arguments: ["-surfaceMode", "shell"])
                        .resolvedMode(for: SurfaceDefaults.paneHostSurface), fallback)
        XCTAssertFalse(makeResolver(arguments: ["-surfaceMode", "shell=nativee"])
                        .isLaunchOverridden(SurfaceDefaults.paneHostSurface))
    }

    func testModeRawValuesAreTheDocumentedSpellings() {
        XCTAssertEqual(SurfaceRenderMode.web.rawValue, "web")
        XCTAssertEqual(SurfaceRenderMode.native.rawValue, "native")
    }

    // MARK: Malformed debug flags degrade to the default (never crash)

    func testDanglingSurfaceModeArgumentIsIgnored() {
        let resolver = makeResolver(arguments: ["-surfaceMode"])
        XCTAssertTrue(resolver.launchOverrides.isEmpty)
        XCTAssertEqual(resolver.resolvedMode(for: .threads), .web)
    }

    func testEmptyValueAndMissingSeparatorAreIgnored() {
        let resolver = makeResolver(arguments: ["-surfaceMode", "=native",
                                                "-surfaceMode", "channelViewnative",
                                                "-surfaceMode", ""])
        XCTAssertTrue(resolver.launchOverrides.isEmpty, "no malformed spec may be retained")
        XCTAssertEqual(resolver.resolvedMode(for: .threads), .web)
        XCTAssertEqual(resolver.resolvedMode(for: .channelView),
                       SurfaceDefaults.defaultMode(for: .channelView),
                       "a malformed spec steers no surface, approved or not")
    }

    // MARK: Always-usable-app escape hatch

    /// The unified surface's "Use web view" affordance must win even when the native decision came
    /// from this run's `-surfaceMode` flag — otherwise a debug launch could leave the app on an
    /// unported stand-in with no way back.
    func testForceWebForThisRunBeatsLaunchArgument() {
        let resolver = makeResolver(arguments: ["-surfaceMode", "threads=native",
                                                "-surfaceMode", "search=native"])
        XCTAssertEqual(resolver.resolvedMode(for: .threads), .native)
        XCTAssertTrue(resolver.isLaunchOverridden(.threads))

        resolver.forceWebForThisRun(.threads)

        XCTAssertEqual(resolver.resolvedMode(for: .threads), .web)
        XCTAssertFalse(resolver.isLaunchOverridden(.threads), "the launch override is dropped")
        // Only that surface: the rest of the debug configuration still holds.
        XCTAssertEqual(resolver.resolvedMode(for: .search), .native)
        XCTAssertTrue(resolver.isLaunchOverridden(.search))
        // The compile default is web, so no override row is left behind.
        XCTAssertNil(resolver.overrides[.threads])
        XCTAssertEqual(makeResolver().resolvedMode(for: .threads), .web)
    }

    /// T93B follow-up (`t_065c8753`): the escape hatch's pre-work runs **before** the mode write, in
    /// the caller's own turn. That ordering is the fix: the pane's webview must exist when the web
    /// branch mounts, because creating it from the branch's appearance made SwiftUI rebuild the pane
    /// mid-flip and install a second container for the one webview.
    func testForceWebForThisRunRunsItsPreWorkBeforeWritingTheMode() {
        let resolver = makeResolver(arguments: ["-surfaceMode", "channelView=native"])
        XCTAssertEqual(resolver.resolvedMode(for: .channelView), .native)

        var seen: [(Surface, SurfaceRenderMode)] = []
        resolver.willForceWeb = { surface in
            seen.append((surface, resolver.resolvedMode(for: surface)))
        }

        resolver.forceWebForThisRun(.channelView)

        XCTAssertEqual(seen.count, 1, "pre-work runs exactly once")
        XCTAssertEqual(seen.first?.0, .channelView, "for the surface the caller asked for")
        XCTAssertEqual(seen.first?.1, .native, "the mode is still the old one while pre-work runs")
        XCTAssertEqual(resolver.resolvedMode(for: .channelView), .web)
    }

    /// The hook is optional: every other route into `.web` (and every test that does not wire one)
    /// must keep working with `nil`.
    func testForceWebForThisRunWorksWithoutAPreWorkHook() {
        let resolver = makeResolver()
        XCTAssertNil(resolver.willForceWeb)
        resolver.forceWebForThisRun(.threads)
        XCTAssertEqual(resolver.resolvedMode(for: .threads), .web)
    }

    /// An explicit inspector pick is a user decision and beats a stale launch flag for that
    /// surface (a toggle that appears dead is worse than losing a debug shortcut).
    func testInspectorToggleDropsLaunchOverrideForThatSurface() {
        let resolver = makeResolver(arguments: ["-surfaceMode", "channelView=native"])
        XCTAssertEqual(resolver.resolvedMode(for: .channelView), .native)

        resolver.setOverride(.web, for: .channelView)
        XCTAssertEqual(resolver.resolvedMode(for: .channelView), .web)
        XCTAssertFalse(resolver.isLaunchOverridden(.channelView))
    }

    // MARK: R2/R3 — the debug tiers are compiled out of Release (T26-R)

    /// `#if DEBUG` in the test bundle mirrors the app target, so this pins that the suite is
    /// exercising the debug-affordance build (`SurfaceModeResolver.debugAffordancesEnabled`).
    func testDebugAffordancesAreCompiledInForThisBuild() {
        #if DEBUG
        XCTAssertTrue(SurfaceModeResolver.debugAffordancesEnabled,
                      "a Debug build carries the launch + persisted override tiers")
        #else
        XCTFail("the unit suite is expected to run against a DEBUG build")
        #endif
    }

    /// R2 choice (a): the persisted tier is a debug affordance, so a Release build **ignores a
    /// stored row**. `releaseSemantics` builds exactly what a Release build computes.
    func testPersistedOverrideIsIgnoredWithoutDebugAffordances() {
        // A row a DEBUG build could have written (a stale `native` choice for an unapproved
        // surface) must not survive into Release: a shipped app may never show a stand-in.
        AppPreferences(defaults: defaults).set(["threads": "native"],
                                               forKey: SurfaceModeResolver.Keys.surfaceModes)

        let debugResolver = makeResolver()
        XCTAssertEqual(debugResolver.resolvedMode(for: .threads), .native,
                       "sanity: a Debug build honours the stored row")

        let releaseResolver = SurfaceModeResolver.releaseSemantics(
            preferences: AppPreferences(defaults: defaults))
        XCTAssertTrue(releaseResolver.overrides.isEmpty, "Release decodes no persisted overrides")
        XCTAssertEqual(releaseResolver.resolvedMode(for: .threads), .web,
                       "Release must fall back to the compile-time default")
    }

    /// R2 choice (a), tier 1: a launch flag is not parsed in a Release build either.
    func testLaunchOverrideIsIgnoredWithoutDebugAffordances() {
        let releaseResolver = SurfaceModeResolver.releaseSemantics(
            preferences: AppPreferences(defaults: defaults),
            arguments: ["-surfaceMode", "threads=native"])
        XCTAssertTrue(releaseResolver.launchOverrides.isEmpty)
        XCTAssertEqual(releaseResolver.resolvedMode(for: .threads), .web)
    }

    /// Only the debug tiers go away in Release: the remote seam (tier 3) and the compile-time
    /// default (tier 4) still decide.
    func testReleaseSemanticsStillHonourRemoteDefaultAndCompileDefault() {
        let releaseResolver = SurfaceModeResolver.releaseSemantics(
            preferences: AppPreferences(defaults: defaults),
            remoteDefault: { $0 == .profile ? .native : nil })
        XCTAssertEqual(releaseResolver.resolvedMode(for: .profile), .native)
        XCTAssertEqual(releaseResolver.resolvedMode(for: .threads), .web)
    }

    // MARK: R5 — the reset paths beat a launch override too (T26-R)

    /// "Reset all to defaults" must mean it: stored rows **and** this run's launch entries go, so
    /// no surface is left native by a flag the button could not otherwise clear.
    func testClearAllOverridesAlsoDropsLaunchOverrides() {
        let resolver = makeResolver(arguments: ["-surfaceMode", "threads=native",
                                                "-surfaceMode", "plugins=native"])
        resolver.setOverride(.native, for: .search)
        XCTAssertEqual(resolver.resolvedMode(for: .threads), .native)
        XCTAssertEqual(resolver.resolvedMode(for: .plugins), .native)
        XCTAssertEqual(resolver.resolvedMode(for: .search), .native)

        resolver.clearAllOverrides()

        XCTAssertTrue(resolver.overrides.isEmpty)
        XCTAssertTrue(resolver.launchOverrides.isEmpty, "a launch override must not survive the reset")
        for surface in [Surface.threads, .plugins, .search] {
            XCTAssertEqual(resolver.resolvedMode(for: surface), .web,
                           "\(surface) must fall back to its compile-time default")
        }
    }

    /// A single-surface clear drops that surface's launch override as well (otherwise the row
    /// would look stuck: the flag outranks the cleared stored value).
    func testClearOverrideDropsLaunchOverrideForThatSurface() {
        let resolver = makeResolver(arguments: ["-surfaceMode", "threads=native",
                                                "-surfaceMode", "search=native"])
        resolver.clearOverride(for: .threads)

        XCTAssertEqual(resolver.resolvedMode(for: .threads), .web)
        XCTAssertFalse(resolver.isLaunchOverridden(.threads))
        XCTAssertEqual(resolver.resolvedMode(for: .search), .native,
                       "other surfaces keep their launch override")
        XCTAssertTrue(resolver.isLaunchOverridden(.search))
    }

    /// `hasAnyOverride` drives the "Reset all to defaults" button, so a pure `-surfaceMode` launch
    /// (no stored row) is resettable rather than a dead button (R5).
    func testHasAnyOverrideCoversLaunchAndStoredOverrides() {
        XCTAssertFalse(makeResolver().hasAnyOverride, "defaults: nothing to reset")

        let launchOnly = makeResolver(arguments: ["-surfaceMode", "channelView=native"])
        XCTAssertTrue(launchOnly.overrides.isEmpty, "a launch flag stores nothing")
        XCTAssertEqual(launchOnly.launchOverrides.count, 1)
        XCTAssertTrue(launchOnly.hasAnyOverride, "a launch override alone must enable the reset")

        let storedOnly = makeResolver()
        storedOnly.setOverride(.native, for: .threads)
        XCTAssertTrue(storedOnly.hasAnyOverride)

        launchOnly.clearAllOverrides()
        XCTAssertFalse(launchOnly.hasAnyOverride)
    }

    // MARK: Harness invariant — one webview per server, re-attached not recreated

    /// `SurfaceHost`'s `web` branch must re-attach the webview the shell already owns. If a
    /// toggle recreated the `WKWebView`, the server's session (cookies/localStorage) and the
    /// in-memory page would be lost — the failure mode this card exists to prevent.
    func testWebViewInstanceIsStableAcrossSurfaceToggles() {
        let resolver = makeResolver()
        let viewStore = ViewStore()
        let server = ServerConfig(name: "Local", url: URL(string: "http://127.0.0.1:8111")!)
        let firstStore = viewStore.ensureStore(for: server)
        let webView = firstStore.webView

        resolver.setOverride(.native, for: .activity)
        XCTAssertEqual(resolver.resolvedMode(for: .activity), .native)
        resolver.setOverride(.web, for: .activity)
        XCTAssertEqual(resolver.resolvedMode(for: .activity), .web)

        let reattached = viewStore.ensureStore(for: server)
        XCTAssertTrue(reattached === firstStore,
                      "the harness must re-attach the same per-server store")
        XCTAssertTrue(reattached.webView === webView,
                      "the harness must re-attach the same WKWebView (no duplicate webview)")
        XCTAssertEqual(viewStore.mountedStores(for: [server]).count, 1,
                       "one server owns exactly one webview")
    }
}