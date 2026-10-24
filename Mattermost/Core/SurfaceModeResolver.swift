import Foundation
import Combine

/// Resolves, for each `Surface`, which renderer (`web` or `native`) is active.
///
/// Resolution order, **highest priority first** (T26 scope §1):
///   1. **Debug override** — a launch argument `-surfaceMode <surface>=<mode>` for this run
///      (ephemeral), or a persisted user override written to `AppPreferences` by the Surface
///      inspector (the runtime toggle). Both are debug-only affordances (`isDebug`).
///   2. **Remote/config default** — an optional injected provider. No such default exists yet;
///      a future server- or build-driven default would plug in here. See `docs/dual-render.md`.
///   3. **Compile-time default** — `SurfaceDefaults.defaultMode(for:)`: `.web` everywhere until
///      a screen card's `-AV` validation approves native.
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

    /// Whether the compile is a Debug build. The launch-argument override and the Surface
    /// inspector are debug-only affordances; a Release build ignores `-surfaceMode` entirely
    /// so a debug flag can never ship side-effects a user cannot undo.
    public static let isDebug: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// Persisted user overrides (from the Surface inspector). `@Published` so views — the
    /// inspector and `SurfaceHost` — rebuild the instant a surface is toggled at runtime.
    @Published public private(set) var overrides: [Surface: SurfaceRenderMode]

    /// Ephemeral launch-argument overrides for this run. They win over persisted overrides but
    /// are never written back (they are debug flags, not user choices). Empty when not a Debug
    /// build or when no `-surfaceMode` argument is present.
    @Published public private(set) var launchOverrides: [Surface: SurfaceRenderMode]

    private let preferences: AppPreferences

    /// Optional remote/config default provider (`nil` == none yet). Hidden behind a closure so
    /// a future server- or build-driven default can be injected without changing this class.
    public var remoteDefault: ((Surface) -> SurfaceRenderMode?)?

    public init(preferences: AppPreferences = AppPreferences(),
                arguments: [String] = ProcessInfo.processInfo.arguments,
                remoteDefault: ((Surface) -> SurfaceRenderMode?)? = nil) {
        self.preferences = preferences
        self.remoteDefault = remoteDefault
        let stored: [String: String] = preferences.get([String: String].self, forKey: Keys.surfaceModes) ?? [:]
        // Tolerantly decode: unknown surface or mode keys are dropped, never fatal (a future
        // build may have retired a surface; stale rows must not crash the shell).
        self.overrides = stored.reduce(into: [:]) { acc, pair in
            guard let surface = Surface(rawValue: pair.key),
                  let mode = SurfaceRenderMode(rawValue: pair.value) else { return }
            acc[surface] = mode
        }
        self.launchOverrides = Self.isDebug ? Self.parseLaunchOverrides(arguments) : [:]
    }

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

    // MARK: Persisted user overrides (Surface inspector runtime toggle)

    /// Set a surface's render mode from an explicit user action (the Surface inspector toggle).
    ///
    /// Two rules keep the runtime switch honest:
    ///  - writing the compile-time default removes the stored override, so the default keeps
    ///    ruling (minimal, reversible persisted state);
    ///  - an explicit user pick also drops this run's `-surfaceMode` launch override **for that
    ///    surface**, because a stale debug flag must never make a toggle look dead. Other
    ///    surfaces' launch overrides are untouched, so the rest of the debug configuration holds.
    public func setOverride(_ mode: SurfaceRenderMode, for surface: Surface) {
        launchOverrides.removeValue(forKey: surface)
        if mode == SurfaceDefaults.defaultMode(for: surface) {
            overrides.removeValue(forKey: surface)
        } else {
            overrides[surface] = mode
        }
        persist()
    }

    /// Drop a single surface's persisted override, falling back to the default.
    public func clearOverride(for surface: Surface) {
        overrides.removeValue(forKey: surface)
        persist()
    }

    /// Drop every persisted override (the inspector's "Reset all" / a cannot-undo guard).
    public func clearAllOverrides() {
        overrides = [:]
        persist()
    }

    /// Escape hatch behind the always-usable-app rule: force the webview for `surface` for the
    /// rest of this run, however the native decision arrived.
    ///
    /// Unlike `setOverride` this also drops an ephemeral `-surfaceMode` launch override for that
    /// surface: the flag is a debug affordance, and the user must always be able to get back to a
    /// working pane without relaunching. A launch override for any *other* surface is untouched,
    /// so the rest of the debug configuration keeps holding.
    public func forceWebForThisRun(_ surface: Surface) {
        launchOverrides.removeValue(forKey: surface)
        setOverride(.web, for: surface)
    }

    private func persist() {
        let dict = overrides.reduce(into: [String: String]()) { $0[$1.key.rawValue] = $1.value.rawValue }
        preferences.set(dict, forKey: Keys.surfaceModes)
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