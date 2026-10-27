// The switch that decides which mention input is live, resolved the way every other Path B gate in
// this repo resolves (`SurfaceModeResolver`): launch argument → persisted debug override → compile-time
// default. Nothing here is a new convention; it is the same three tiers, for the same reason — a card
// must be provable without shipping a behaviour change, and the flip is one diff an `-AV` validator can
// audit.
//
// **The compile-time default stays `.bridge`** (Path A, today's input) until `T43-AV` approves the flip.
// That is the board rule every surface follows (`SurfaceDefaults.nativeApprovedSurfaces`): a card proves
// its path behind the flag, its adversarial validator decides, and only then does the default move. So
// a shipped build behaves exactly as it did before T43; `-notificationPath socket` is what makes the
// native path live.

import Foundation
import Combine

@MainActor
final class NotificationPathStore: ObservableObject {

    /// Stable `AppPreferences` key for the persisted debug override. Never read in Release (see
    /// `debugAffordancesEnabled`) — the persisted tier is a debug affordance, exactly like
    /// `mm.surfaceModes`.
    enum Keys {
        static let mode = "mm.notificationPath"
    }

    /// The compile-time default. One constant, so the `-AV` flip is a one-line diff.
    ///
    /// `.bridge` = Path A, unchanged. Flipping this to `.socket` is the claim "the native input has
    /// passed its adversarial validation", and it is the only place that claim is made.
    static let compileDefault: NotificationInputMode = .bridge

    /// Whether this build carries the debug override tiers. Compile-time (`#if DEBUG`), the same gate
    /// `SurfaceModeResolver.debugAffordancesEnabled` uses: a Release build resolves only the compile
    /// default, so no stored row and no launch flag can steer a shipped binary.
    static let debugAffordancesEnabled: Bool = {
        #if DEBUG || PERF_PROBE
        return true
        #else
        return false
        #endif
    }()

    @Published private(set) var mode: NotificationInputMode

    /// True when this run's mode came from the `-notificationPath` launch argument (the Settings
    /// read-out says so, so a debug flag cannot look like a user choice).
    private(set) var isLaunchOverridden: Bool

    private let preferences: AppPreferences

    convenience init(preferences: AppPreferences = AppPreferences(),
                     arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.init(preferences: preferences, arguments: arguments,
                  debugAffordances: Self.debugAffordancesEnabled)
    }

    /// The one initialiser. `debugAffordances` decides whether the launch/persisted tiers exist at all;
    /// the only non-compile-time caller is the DEBUG-only `releaseSemantics` test seam, so a Release
    /// build cannot opt in even in principle.
    private init(preferences: AppPreferences,
                 arguments: [String],
                 debugAffordances: Bool) {
        self.preferences = preferences
        guard debugAffordances else {
            self.mode = Self.compileDefault
            self.isLaunchOverridden = false
            return
        }
        if let launched = Self.parseLaunchMode(arguments) {
            self.mode = launched
            self.isLaunchOverridden = true
            return
        }
        if let raw = preferences.get(String.self, forKey: Keys.mode),
           let stored = NotificationInputMode(rawValue: raw) {
            self.mode = stored
            self.isLaunchOverridden = false
            return
        }
        self.mode = Self.compileDefault
        self.isLaunchOverridden = false
    }

    #if DEBUG
    /// TEST SEAM (DEBUG only): a store with the debug tiers switched off — what a Release build
    /// computes. Mirrors `SurfaceModeResolver.releaseSemantics`; a Release build has no initialiser that
    /// accepts `true`.
    static func releaseSemantics(preferences: AppPreferences,
                                 arguments: [String] = []) -> NotificationPathStore {
        NotificationPathStore(preferences: preferences, arguments: arguments, debugAffordances: false)
    }
    #endif

    #if DEBUG
    /// DEBUG-only writer (the Settings row and the `-AV` probes use it). Writing the compile default
    /// removes the stored row, so the default keeps ruling and no stale row outlives the experiment.
    func setMode(_ mode: NotificationInputMode) {
        if mode == Self.compileDefault {
            preferences.removeObject(forKey: Keys.mode)
        } else {
            preferences.set(mode.rawValue, forKey: Keys.mode)
        }
        self.mode = mode
        self.isLaunchOverridden = false
    }
    #endif

    // MARK: - Launch argument

    /// Parse `-notificationPath <token>`. Both `["-notificationPath", "socket"]` and the single-token
    /// form are accepted; an unknown token is ignored (never fatal), so a typo degrades to the default.
    static func parseLaunchMode(_ arguments: [String]) -> NotificationInputMode? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-notificationPath" {
                guard index + 1 < arguments.count else { return nil }
                return NotificationInputMode.parse(arguments[index + 1])
            }
            if argument.hasPrefix("-notificationPath=") {
                return NotificationInputMode.parse(String(argument.dropFirst("-notificationPath=".count)))
            }
            index += 1
        }
        return nil
    }
}
