import Foundation
import Combine

/// Resolves, for each `Surface`, which renderer (`web` or `native`) is active.
///
/// Resolution order, **highest priority first** (T26 scope §1). The first two tiers are
/// **debug-only affordances and are compiled out of Release builds**:
///   1. **Launch override** — a launch argument `-surfaceMode <surface>=<mode>` for this run
///      (ephemeral, never persisted). Read only when `debugAffordancesEnabled`.
///   2. **Persisted user override** — written by the DEBUG-only Surface inspector to
///      `AppPreferences` (`mm.surfaceModes`). Read only when `debugAffordancesEnabled`.
///   3. **Remote/config default** — an optional injected provider. No such default exists yet;
///      a future server- or build-driven default would plug in here.
///   4. **Compile-time default** — `SurfaceDefaults.defaultMode(for:)`: `.web` everywhere until
///      a screen card's `-AV` validation approves native.
///
/// A Release build therefore resolves **only** from tiers 3 and 4 (`debugAffordancesEnabled ==
/// false`): no launch flag and no stored row can put a shipped app on a native screen. The
/// consequence — a Debug→Release upgrade drops a stored per-surface choice, because the choice
/// is a debug affordance — is recorded in `docs/dual-render.md` §3 and §8, together with the one
/// writer that does survive in Release (`forceWebForThisRun`, the always-usable "Use web view"
/// escape hatch, which only ever writes `.web`).
///
/// This is the single decision point the whole dual-render harness reads from. A screen card
/// observes *this* resolver rather than hard-wiring its surface to `.native` (the `-AV`
/// validator rejects that: native-by-default must come through `SurfaceDefaults`).
@MainActor
public final class SurfaceModeResolver: ObservableObject {

    /// UserDefaults keys this store persists under. Stable across releases.
    public enum Keys {
        /// The persisted per-surface user overrides, encoded as
        /// `[Surface.rawValue: SurfaceRenderMode.rawValue]`.
        public static let surfaceModes = "mm.surfaceModes"
    }

    /// Whether this build carries the debug-only override tiers (launch flag + persisted choice).
    ///
    /// This is the **one** switch, and it is compile-time (`#if DEBUG`):
    ///  - the single read path in `init` decodes tiers 1 and 2 only when it is `true`, and a
    ///    Release build's public initialiser passes a literal `false`;
    ///  - the three arbitrary-mode writers (`setOverride`, `clearOverride`, `clearAllOverrides`)
    ///    do not exist outside `DEBUG` at all, so no Release call site can steer a surface.
    /// See `docs/dual-render.md` §5 (the `-AV` gate) and §8 (debug affordances).
    ///
    /// **T27:** a `PERF_PROBE` build also enables them. `PERF_PROBE` is a compilation condition
    /// the perf harness passes on the `xcodebuild` command line
    /// (`SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) PERF_PROBE'`) so it can measure a
    /// Release-optimised binary *and* still launch a surface in either renderer with
    /// `-surfaceMode`. It is not a shipping configuration: a normal Release build has neither
    /// the condition nor any perf code (see `PerfProbe.swift`'s gate).
    public static let debugAffordancesEnabled: Bool = {
        #if DEBUG || PERF_PROBE
        return true
        #else
        return false
        #endif
    }()

    /// Persisted user overrides (tier 2, DEBUG only — see `debugAffordancesEnabled`).
    /// `@Published` so views — the inspector and `SurfaceHost` — rebuild the instant a surface is
    /// toggled at runtime. Always empty in a Release build.
    @Published public private(set) var overrides: [Surface: SurfaceRenderMode]

    /// Ephemeral launch-argument overrides for this run (tier 1, DEBUG only). They win over
    /// persisted overrides but are never written back (they are debug flags, not user choices).
    /// Always empty in a Release build.
    @Published public private(set) var launchOverrides: [Surface: SurfaceRenderMode]

    private let preferences: AppPreferences

    /// Optional remote/config default provider (`nil` == none yet). Hidden behind a closure so
    /// a future server- or build-driven default can be injected without changing this class.
    public var remoteDefault: ((Surface) -> SurfaceRenderMode?)?

    public convenience init(preferences: AppPreferences = AppPreferences(),
                            arguments: [String] = ProcessInfo.processInfo.arguments,
                            remoteDefault: ((Surface) -> SurfaceRenderMode?)? = nil) {
        self.init(preferences: preferences,
                  arguments: arguments,
                  remoteDefault: remoteDefault,
                  debugAffordances: Self.debugAffordancesEnabled)
    }

    /// The one initialiser. `debugAffordances` decides whether tiers 1 and 2 are decoded at all.
    /// It is `private`, and the only non-compile-time caller is the DEBUG-only
    /// `releaseSemantics(_:)` test seam below, so a Release build cannot opt in even in principle.
    private init(preferences: AppPreferences,
                 arguments: [String],
                 remoteDefault: ((Surface) -> SurfaceRenderMode?)?,
                 debugAffordances: Bool) {
        self.preferences = preferences
        self.remoteDefault = remoteDefault
        guard debugAffordances else {
            self.overrides = [:]
            self.launchOverrides = [:]
            return
        }
        let stored: [String: String] = preferences.get([String: String].self,
                                                       forKey: Keys.surfaceModes) ?? [:]
        self.overrides = Self.decodePersistedOverrides(stored)
        self.launchOverrides = Self.parseLaunchOverrides(arguments)
    }

#if DEBUG
    /// TEST SEAM (DEBUG builds only): a resolver with the debug tiers switched off — exactly what a
    /// Release build computes (`overrides == [:]`, `launchOverrides == [:]`). It lets the unit
    /// suite pin the Release contract from a Debug test run
    /// (`testPersistedOverrideIsIgnoredWithoutDebugAffordances`,
    /// `testLaunchOverrideIsIgnoredWithoutDebugAffordances`). A Release build has no counterpart:
    /// there is no initialiser that accepts `true`.
    static func releaseSemantics(preferences: AppPreferences,
                                 arguments: [String] = [],
                                 remoteDefault: ((Surface) -> SurfaceRenderMode?)? = nil)
        -> SurfaceModeResolver {
        SurfaceModeResolver(preferences: preferences,
                            arguments: arguments,
                            remoteDefault: remoteDefault,
                            debugAffordances: false)
    }
#endif

    /// The renderer a surface should use right now, honouring the resolution order above.
    public func resolvedMode(for surface: Surface) -> SurfaceRenderMode {
        if let mode = launchOverrides[surface] { return mode }
        if let mode = overrides[surface] { return mode }
        if let mode = remoteDefault?(surface) { return mode }
        return SurfaceDefaults.defaultMode(for: surface)
    }

    /// Whether `surface`'s decision came from the ephemeral launch override. The inspector
    /// shows (but does not let the user edit) such a surface, since the flag wins this run.
    public func isLaunchOverridden(_ surface: Surface) -> Bool {
        launchOverrides[surface] != nil
    }

    /// True when at least one surface is steered away from its compile-time default by an
    /// override the inspector can clear — a persisted row **or** this run's launch entry.
    ///
    /// This drives "Reset all to defaults", so the button is live for a pure `-surfaceMode`
    /// launch as well (T26-R R5: previously only stored rows enabled it, which left a launch
    /// override with no reset affordance).
    public var hasAnyOverride: Bool {
        !overrides.isEmpty || !launchOverrides.isEmpty
    }

    // MARK: Persisted user overrides (Surface inspector runtime toggle) — DEBUG only

#if DEBUG
    /// Set a surface's render mode from an explicit user action (the Surface inspector toggle).
    ///
    /// Two rules keep the runtime switch honest:
    ///  - writing the compile-time default removes the stored override, so the default keeps
    ///    ruling (minimal, reversible persisted state);
    ///  - an explicit user pick also drops this run's `-surfaceMode` launch override **for that
    ///    surface**, because a stale debug flag must never make a toggle look dead. Other
    ///    surfaces' launch overrides are untouched, so the rest of the debug configuration holds.
    ///
    /// `#if DEBUG`: this is the only API that can write an arbitrary mode, and it does not exist
    /// in a Release build (see `debugAffordancesEnabled`).
    public func setOverride(_ mode: SurfaceRenderMode, for surface: Surface) {
        launchOverrides.removeValue(forKey: surface)
        apply(mode, for: surface)
    }

    /// Drop a single surface's stored override **and** this run's launch override for it, so the
    /// surface falls back to tiers 3/4.
    ///
    /// Both halves are required: with only the stored row dropped, a `-surfaceMode` entry keeps
    /// the surface native and the inspector row looks stuck (T26-R R5).
    public func clearOverride(for surface: Surface) {
        launchOverrides.removeValue(forKey: surface)
        overrides.removeValue(forKey: surface)
        persist()
    }

    /// Drop every override the inspector can see — stored rows **and** this run's launch entries —
    /// so "Reset all to defaults" really means every surface resolves by its compile-time default
    /// (T26-R R5: previously a launch override survived the reset and kept the surface native).
    public func clearAllOverrides() {
        overrides = [:]
        launchOverrides = [:]
        persist()
    }
#endif

    /// Escape hatch behind the always-usable-app rule: force the webview for `surface` for the
    /// rest of this run, however the native decision arrived.
    ///
    /// Unlike the DEBUG-only `setOverride` this also drops an ephemeral `-surfaceMode` launch
    /// override for that surface: the flag is a debug affordance, and the user must always be able
    /// to get back to a working pane without relaunching. A launch override for any *other*
    /// surface is untouched, so the rest of the debug configuration keeps holding.
    ///
    /// It stays available in Release (the stand-in that offers it is the documented way out of a
    /// native decision) and it only ever writes `.web`, so it cannot be a route to `.native`.
    /// In a Release build the written `.web` row is not read back on the next launch, because the
    /// persisted tier is a debug affordance (`docs/dual-render.md` §3/§8).
    public func forceWebForThisRun(_ surface: Surface) {
        launchOverrides.removeValue(forKey: surface)
        apply(.web, for: surface)
    }

    /// The one write path for a surface's stored override: the DEBUG setters and the escape hatch
    /// both route through it, so "writing the default clears the row" cannot fork.
    private func apply(_ mode: SurfaceRenderMode, for surface: Surface) {
        if mode == SurfaceDefaults.defaultMode(for: surface) {
            overrides.removeValue(forKey: surface)
        } else {
            overrides[surface] = mode
        }
        persist()
    }

    private func persist() {
        // A Release build does not read the persisted tier (§3), so it does not write one either:
        // no shipped binary leaves `mm.surfaceModes` state behind for a later Debug build to
        // inherit.
        guard Self.debugAffordancesEnabled else { return }
        let dict = overrides.reduce(into: [String: String]()) { $0[$1.key.rawValue] = $1.value.rawValue }
        preferences.set(dict, forKey: Keys.surfaceModes)
    }

    /// Tolerantly decode stored rows: an unknown surface or mode key is dropped, never fatal (a
    /// future build may have retired a surface; stale rows must not crash the shell).
    static func decodePersistedOverrides(_ stored: [String: String]) -> [Surface: SurfaceRenderMode] {
        stored.reduce(into: [:]) { acc, pair in
            guard let surface = Surface(rawValue: pair.key),
                  let mode = SurfaceRenderMode(rawValue: pair.value) else { return }
            acc[surface] = mode
        }
    }

    // MARK: Launch-argument parsing

    /// Parse `-surfaceMode <surface>=<mode>` pairs. Both the two-token form
    /// `["-surfaceMode", "channelView=native"]` and the single-token form
    /// `["-surfaceMode=channelView=native"]` are accepted.
    ///
    /// Unknown surfaces and unknown modes are rejected (never crash) and simply ignored, so a
    /// typo'd debug flag degrades to the default instead of taking the app down.
    static func parseLaunchOverrides(_ arguments: [String]) -> [Surface: SurfaceRenderMode] {
        var specs: [String] = []
        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            if arg == "-surfaceMode" {
                if i + 1 < arguments.count {
                    specs.append(arguments[i + 1])
                    i += 2
                    continue
                }
                i += 1
                continue
            }
            if arg.hasPrefix("-surfaceMode=") {
                specs.append(String(arg.dropFirst("-surfaceMode=".count)))
            }
            i += 1
        }
        var result: [Surface: SurfaceRenderMode] = [:]
        for spec in specs {
            let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let surface = Surface(rawValue: parts[0]),
                  let mode = SurfaceRenderMode(rawValue: parts[1]) else { continue }
            result[surface] = mode
        }
        return result
    }
}
