// The debug switch that can **force** which mention input is live, resolved the way every other Path B
// gate in this repo resolves (`SurfaceModeResolver`): launch argument → persisted debug override. There
// is deliberately **no compile-time default tier**: the shipped answer is not a constant any more.
//
// Why (t_ba355551): the constant used to be `.bridge`, and a Release build takes the `!debugAffordances`
// branch, so the shipped app forced `.bridge`. On the native workspace no web pane is mounted, so the
// page never reports `notify_mention`, the socket was refused by the same constant, and the T14 poller
// does not register on Catalyst. The test button worked and a real message produced nothing. Which
// input is live is now **measured** from the pane that is rendering
// (`NotificationInputGate.mode(for:)`): native pane → the socket, web pane → the page.
//
// What survives here is the debug affordance, unchanged in shape: `-notificationPath socket|bridge`
// (or `-notificationPath=native|web`) and the persisted row exist in DEBUG/PERF_PROBE builds only and
// force the answer for an experiment. A Release build reads neither, and `overrideMode` is `nil` —
// which is what makes the derived answer the shipped one.

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

    /// Whether this build carries the debug override tiers. Compile-time (`#if DEBUG`), the same gate
    /// `SurfaceModeResolver.debugAffordancesEnabled` uses: a Release build resolves no override at all,
    /// so no stored row and no launch flag can steer a shipped binary.
    static let debugAffordancesEnabled: Bool = {
        #if DEBUG || PERF_PROBE
        return true
        #else
        return false
        #endif
    }()

    /// The forced input, or `nil` for the shipped behaviour — derive it from the pane that is
    /// rendering. `nil` is not a fallback: it *is* the answer a Release build always has.
    @Published private(set) var overrideMode: NotificationInputMode?

    /// True when this run's override came from the `-notificationPath` launch argument (the Settings
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
            self.overrideMode = nil
            self.isLaunchOverridden = false
            return
        }
        if let launched = Self.parseLaunchMode(arguments) {
            self.overrideMode = launched
            self.isLaunchOverridden = true
            return
        }
        if let raw = preferences.get(String.self, forKey: Keys.mode),
           let stored = NotificationInputMode(rawValue: raw) {
            self.overrideMode = stored
            self.isLaunchOverridden = false
            return
        }
        self.overrideMode = nil
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
    /// DEBUG-only writer (the `-AV` probes use it). `nil` removes the stored row, so the derived answer
    /// keeps ruling and no stale row outlives the experiment.
    func setOverride(_ mode: NotificationInputMode?) {
        if let mode {
            preferences.set(mode.rawValue, forKey: Keys.mode)
        } else {
            preferences.removeObject(forKey: Keys.mode)
        }
        self.overrideMode = mode
        self.isLaunchOverridden = false
    }
    #endif

    // MARK: - Launch argument

    /// Parse `-notificationPath <token>`. Both `["-notificationPath", "socket"]` and the single-token
    /// form are accepted; an unknown token is ignored (never fatal), so a typo degrades to the derived
    /// answer rather than to a mode the shell was not asked for.
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
