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

    /// Nothing ships native-by-default: the approval registry is empty, so every surface falls
    /// back to the web view until its screen card's `-AV` validation approves native (T46).
    func testEverySurfaceDefaultsToWeb() {
        XCTAssertTrue(SurfaceDefaults.nativeApprovedSurfaces.isEmpty,
                      "no surface may be native-by-default before its -AV validator passes")
        let resolver = makeResolver()
        for surface in Surface.allCases {
            XCTAssertEqual(resolver.resolvedMode(for: surface), .web,
                           "\(surface) must default to the web view")
        }
    }

    /// Native-by-default is reached only through the approval registry, never inline.
    func testNativeByDefaultRequiresApproval() {
        // The structural rule: `defaultMode` returns native ONLY for an approved surface.
        // With the registry empty, every surface must be `.web`.
        for surface in Surface.allCases {
            XCTAssertEqual(SurfaceDefaults.defaultMode(for: surface), .web)
        }
    }

    // MARK: Debug override wins (launch argument)

    func testLaunchArgumentOverrideWinsOverCompileTimeDefault() {
        let resolver = makeResolver(arguments: ["-surfaceMode", "channelView=native"])
        XCTAssertEqual(resolver.resolvedMode(for: .channelView), .native)
        XCTAssertEqual(resolver.resolvedMode(for: .auth), .web, "unlisted surfaces keep their default")
        XCTAssertTrue(resolver.isLaunchOverridden(.channelView))
    }

    func testLaunchArgumentSingleTokenFormIsAccepted() {
        let resolver = makeResolver(arguments: ["-surfaceMode=composer=native", "foo"])
        XCTAssertEqual(resolver.resolvedMode(for: .composer), .native)
        XCTAssertEqual(resolver.resolvedMode(for: .auth), .web)
    }

    func testUnknownSurfaceIsRejected() {
        // A typo'd surface must be ignored (and never crash); the rest of the run is untouched.
        let resolver = makeResolver(arguments: ["-surfaceMode", "notASurface=native",
                                                "-surfaceMode", "channelView=native"])
        XCTAssertEqual(resolver.resolvedMode(for: .channelView), .native)
        XCTAssertEqual(resolver.resolvedMode(for: .auth), .web)
        XCTAssertEqual(resolver.launchOverrides.count, 1,
                       "only the valid pair is retained, the unknown surface is dropped")
    }

    func testUnknownModeIsRejected() {
        let resolver = makeResolver(arguments: ["-surfaceMode", "channelView=flash",
                                                "-surfaceMode", "auth=web"])
        XCTAssertEqual(resolver.resolvedMode(for: .channelView), .web, "invalid mode is ignored")
        XCTAssertEqual(resolver.resolvedMode(for: .auth), .web)
        XCTAssertEqual(resolver.launchOverrides.count, 1, "valid pair retained; bad mode dropped")
    }

    // MARK: Persisted override (runtime toggle) round-trips through AppPreferences

    func testPersistedOverrideRoundTripsThroughAppPreferences() {
        let first = makeResolver()
        first.setOverride(.native, for: .sidebar)

        // A *fresh* resolver over the same UserDefaults must read the override back (relaunch
        // parity: the user's inspector choice survives a restart).
        let second = makeResolver()
        XCTAssertEqual(second.resolvedMode(for: .sidebar), .native)
        XCTAssertEqual(second.overrides[.sidebar], .native)

        // And an unrelated surface still defaults to web.
        XCTAssertEqual(second.resolvedMode(for: .auth), .web)
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
        prefs.set(["channelView": "native", "bogusSurface": "native", "sidebar": "weirdMode"],
                  forKey: SurfaceModeResolver.Keys.surfaceModes)

        let resolver = makeResolver()
        XCTAssertEqual(resolver.resolvedMode(for: .channelView), .native)
        XCTAssertEqual(resolver.resolvedMode(for: .sidebar), .web, "invalid persisted mode is dropped")
        XCTAssertEqual(resolver.overrides.count, 1, "only the valid row survives decoding")
    }

    // MARK: Resolution order between the tiers

    func testLaunchArgumentBeatsPersistedOverride() {
        let first = makeResolver()
        first.setOverride(.native, for: .channelView)

        // A launch flag for the same surface wins this run over the persisted inspector setting.
        let resolver = makeResolver(arguments: ["-surfaceMode", "channelView=web"])
        XCTAssertEqual(resolver.resolvedMode(for: .channelView), .web)
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
        XCTAssertEqual(resolver.resolvedMode(for: .calls), .native,
                       "surface without an override still takes the remote default")
    }

    func testRemoteDefaultFillsBetweenPersistedAndCompileTimeDefault() {
        let resolver = makeResolver(remoteDefault: { $0 == .profile ? .native : nil })
        XCTAssertEqual(resolver.resolvedMode(for: .profile), .native)
        XCTAssertEqual(resolver.resolvedMode(for: .auth), .web,
                       "unhandled surfaces fall through to the compile-time default")
    }

    // MARK: The single decision point

    func testInspectorToggleRoundTripsLive() {
        let resolver = makeResolver()
        let before = resolver.resolvedMode(for: .channelView)

        resolver.setOverride(.native, for: .channelView)
        XCTAssertEqual(resolver.resolvedMode(for: .channelView), .native)
        resolver.clearOverride(for: .channelView)
        XCTAssertEqual(resolver.resolvedMode(for: .channelView), before)

        // No duplicated webview is a UI-layer property; the resolver must simply return to a
        // stable `.web` decision after the cycle so the surface can be re-mounted once.
        XCTAssertEqual(resolver.resolvedMode(for: .channelView), .web)
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
        // Everything else stays on the web view: the alias names one surface, not the app.
        for surface in Surface.allCases where surface != SurfaceDefaults.paneHostSurface {
            XCTAssertEqual(resolver.resolvedMode(for: surface), .web)
        }
    }

    /// The alias resolves through the same launch parser, so its malformed forms degrade exactly
    /// like every other flag (`shell=nativee`, `shellx=native`, an unknown mode).
    func testMalformedShellAliasDegradesToTheDefault() {
        XCTAssertEqual(makeResolver(arguments: ["-surfaceMode", "shell=nativee"])
                        .resolvedMode(for: SurfaceDefaults.paneHostSurface), .web)
        XCTAssertEqual(makeResolver(arguments: ["-surfaceMode", "shellx=native"])
                        .resolvedMode(for: SurfaceDefaults.paneHostSurface), .web)
        XCTAssertEqual(makeResolver(arguments: ["-surfaceMode", "shell"])
                        .resolvedMode(for: SurfaceDefaults.paneHostSurface), .web)
    }

    func testModeRawValuesAreTheDocumentedSpellings() {
        XCTAssertEqual(SurfaceRenderMode.web.rawValue, "web")
        XCTAssertEqual(SurfaceRenderMode.native.rawValue, "native")
    }

    // MARK: Malformed debug flags degrade to the default (never crash)

    func testDanglingSurfaceModeArgumentIsIgnored() {
        let resolver = makeResolver(arguments: ["-surfaceMode"])
        XCTAssertTrue(resolver.launchOverrides.isEmpty)
        XCTAssertEqual(resolver.resolvedMode(for: .channelView), .web)
    }

    func testEmptyValueAndMissingSeparatorAreIgnored() {
        let resolver = makeResolver(arguments: ["-surfaceMode", "=native",
                                                "-surfaceMode", "channelViewnative",
                                                "-surfaceMode", ""])
        XCTAssertTrue(resolver.launchOverrides.isEmpty, "no malformed spec may be retained")
        XCTAssertEqual(resolver.resolvedMode(for: .channelView), .web)
    }

    // MARK: Always-usable-app escape hatch

    /// The unified surface's "Use web view" affordance must win even when the native decision came
    /// from this run's `-surfaceMode` flag — otherwise a debug launch could leave the app on an
    /// unported stand-in with no way back.
    func testForceWebForThisRunBeatsLaunchArgument() {
        let resolver = makeResolver(arguments: ["-surfaceMode", "channelView=native",
                                                "-surfaceMode", "threads=native"])
        XCTAssertEqual(resolver.resolvedMode(for: .channelView), .native)
        XCTAssertTrue(resolver.isLaunchOverridden(.channelView))

        resolver.forceWebForThisRun(.channelView)

        XCTAssertEqual(resolver.resolvedMode(for: .channelView), .web)
        XCTAssertFalse(resolver.isLaunchOverridden(.channelView), "the launch override is dropped")
        // Only that surface: the rest of the debug configuration still holds.
        XCTAssertEqual(resolver.resolvedMode(for: .threads), .native)
        XCTAssertTrue(resolver.isLaunchOverridden(.threads))
        // The compile default is web, so no override row is left behind.
        XCTAssertNil(resolver.overrides[.channelView])
        XCTAssertEqual(makeResolver().resolvedMode(for: .channelView), .web)
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
        AppPreferences(defaults: defaults).set(["channelView": "native"],
                                               forKey: SurfaceModeResolver.Keys.surfaceModes)

        let debugResolver = makeResolver()
        XCTAssertEqual(debugResolver.resolvedMode(for: .channelView), .native,
                       "sanity: a Debug build honours the stored row")

        let releaseResolver = SurfaceModeResolver.releaseSemantics(
            preferences: AppPreferences(defaults: defaults))
        XCTAssertTrue(releaseResolver.overrides.isEmpty, "Release decodes no persisted overrides")
        XCTAssertEqual(releaseResolver.resolvedMode(for: .channelView), .web,
                       "Release must fall back to the compile-time default")
    }

    /// R2 choice (a), tier 1: a launch flag is not parsed in a Release build either.
    func testLaunchOverrideIsIgnoredWithoutDebugAffordances() {
        let releaseResolver = SurfaceModeResolver.releaseSemantics(
            preferences: AppPreferences(defaults: defaults),
            arguments: ["-surfaceMode", "channelView=native"])
        XCTAssertTrue(releaseResolver.launchOverrides.isEmpty)
        XCTAssertEqual(releaseResolver.resolvedMode(for: .channelView), .web)
    }

    /// Only the debug tiers go away in Release: the remote seam (tier 3) and the compile-time
    /// default (tier 4) still decide.
    func testReleaseSemanticsStillHonourRemoteDefaultAndCompileDefault() {
        let releaseResolver = SurfaceModeResolver.releaseSemantics(
            preferences: AppPreferences(defaults: defaults),
            remoteDefault: { $0 == .profile ? .native : nil })
        XCTAssertEqual(releaseResolver.resolvedMode(for: .profile), .native)
        XCTAssertEqual(releaseResolver.resolvedMode(for: .auth), .web)
    }

    // MARK: R5 — the reset paths beat a launch override too (T26-R)

    /// "Reset all to defaults" must mean it: stored rows **and** this run's launch entries go, so
    /// no surface is left native by a flag the button could not otherwise clear.
    func testClearAllOverridesAlsoDropsLaunchOverrides() {
        let resolver = makeResolver(arguments: ["-surfaceMode", "channelView=native",
                                                "-surfaceMode", "threads=native"])
        resolver.setOverride(.native, for: .search)
        XCTAssertEqual(resolver.resolvedMode(for: .channelView), .native)
        XCTAssertEqual(resolver.resolvedMode(for: .threads), .native)
        XCTAssertEqual(resolver.resolvedMode(for: .search), .native)

        resolver.clearAllOverrides()

        XCTAssertTrue(resolver.overrides.isEmpty)
        XCTAssertTrue(resolver.launchOverrides.isEmpty, "a launch override must not survive the reset")
        for surface in [Surface.channelView, .threads, .search] {
            XCTAssertEqual(resolver.resolvedMode(for: surface), .web,
                           "\(surface) must fall back to its compile-time default")
        }
    }

    /// A single-surface clear drops that surface's launch override as well (otherwise the row
    /// would look stuck: the flag outranks the cleared stored value).
    func testClearOverrideDropsLaunchOverrideForThatSurface() {
        let resolver = makeResolver(arguments: ["-surfaceMode", "channelView=native",
                                                "-surfaceMode", "threads=native"])
        resolver.clearOverride(for: .channelView)

        XCTAssertEqual(resolver.resolvedMode(for: .channelView), .web)
        XCTAssertFalse(resolver.isLaunchOverridden(.channelView))
        XCTAssertEqual(resolver.resolvedMode(for: .threads), .native,
                       "other surfaces keep their launch override")
        XCTAssertTrue(resolver.isLaunchOverridden(.threads))
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
        storedOnly.setOverride(.native, for: .sidebar)
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

        resolver.setOverride(.native, for: .channelView)
        XCTAssertEqual(resolver.resolvedMode(for: .channelView), .native)
        resolver.setOverride(.web, for: .channelView)
        XCTAssertEqual(resolver.resolvedMode(for: .channelView), .web)

        let reattached = viewStore.ensureStore(for: server)
        XCTAssertTrue(reattached === firstStore,
                      "the harness must re-attach the same per-server store")
        XCTAssertTrue(reattached.webView === webView,
                      "the harness must re-attach the same WKWebView (no duplicate webview)")
        XCTAssertEqual(viewStore.mountedStores(for: [server]).count, 1,
                       "one server owns exactly one webview")
    }
}