import Foundation
#if !targetEnvironment(macCatalyst)
import BackgroundTasks
#endif
import UIKit

/// The single `BGAppRefreshTask` identifier the shell is permitted to launch. It MUST match
/// the `BGTaskSchedulerPermittedIdentifiers` entry in `Info.plist` exactly — a task whose
/// identifier is not listed there is silently never launched, and Debug-print shows
/// "Operation ... not permitted".
enum BackgroundRefreshTaskID {
    static let mentionPoll = "com.mattermost.ios.refresh"
}

/// Scheduler for the T14 background mention poller (Option A — local notifications driven
/// by a periodic `BGAppRefreshTask` instead of APNs). Native counterpart of the desktop's
/// always-on `AutoLauncher`/presence re-delivery; parity row: `AutoLauncher` ->
/// `BackgroundRefreshScheduler` (design §4c, Phase 4 item 28).
///
/// Capability truth (verified before implementing, recorded in docs/t14-build-note.md):
/// `BGAppRefreshTask` needs only the two plain Info.plist keys added in T14 —
/// `UIBackgroundModes = fetch` and `BGTaskSchedulerPermittedIdentifiers` — plus the
/// `BackgroundTasks` framework. There is NO entitlement and NO paid Apple Developer
/// Program capability involved, unlike APNs (T12/T13), which stays out of scope (this
/// file never calls `registerForRemoteNotifications`).
///
/// Scheduling reality (honest, mirrored in the build note): iOS decides *if and when* a
/// refresh task actually runs — the `earliestBeginDate` is only a hint, frequency is
/// throttled by the OS to conserve power, and the system may grant the task minutes to
/// hours after the request. This is best-effort, not a push replacement.
///
/// Mac Catalyst (T20) note: `BGTaskScheduler` is compiled into the Catalyst SDK but the
/// scheduler does not run background tasks on macOS (`API_UNAVAILABLE(macos)` in the
/// BackgroundTasks headers; Apple's Catalyst availability matrix excludes it). On a
/// Catalyst build the scheduler compiles to a documented no-op so the T20 Mac target keeps
/// building.
final class BackgroundRefreshScheduler {

    static let shared = BackgroundRefreshScheduler()

    /// The BGTask launch handler supplied by the app (wires the poller). A nil handler
    /// means the task was never registered — never the case after `register(...)` has run.
    private var launchHandler: (@Sendable () async -> Void)?

    /// Whether `register(...)` has been called (only the first call registers; UIKit will
    /// crash if the same identifier is registered twice).
    private(set) var isRegistered = false

    private init() {}

    // MARK: - Registration (AppDelegate.didFinishLaunchingWithOptions)

    /// Register the refresh task's launch handler. Called exactly once from
    /// `AppDelegate.application(_:didFinishLaunchingWithOptions:)`. On Catalyst the
    /// registration is skipped (documented no-op — BackgroundTasks does not run on macOS).
    @MainActor
    func register(launchHandler: @escaping @Sendable () async -> Void) {
        guard !isRegistered else {
            Logger.debug("BackgroundRefreshScheduler", "register called twice; ignoring duplicate")
            return
        }
        self.launchHandler = launchHandler
        #if targetEnvironment(macCatalyst)
        Logger.info("BackgroundRefreshScheduler", "background refresh is not supported on Mac Catalyst; skipping registration (documented no-op)")
        #else
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundRefreshTaskID.mentionPoll,
            using: nil
        ) { [weak self] task in
            // `task` is a BGAppRefreshTask. Profile: the launch handler runs on an
            // arbitrary queue; the poller funnels onto its own actor.
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handle(task)
        }
        isRegistered = true
        Logger.info("BackgroundRefreshScheduler", "registered refresh task \(BackgroundRefreshTaskID.mentionPoll) (registered=\(registered))")
        #endif
    }

    // MARK: - Task execution wrapper

    /// Runs the launch handler for a delivered `BGTask`. Ownership contract (Apple's
    /// "Refreshing and Maintaining Your App Using Background Tasks" sample):
    ///   - reschedule the *next* refresh immediately (a task consumes its slot);
    ///   - install an `expirationHandler` that cancels the in-flight work when the system
    ///     is about to terminate the task;
    ///   - ALWAYS call `setTaskCompleted(success:)` once the work (or its cancellation)
    ///     finishes — never leave the task hanging, or the system kills the app;
    ///   - never call `setTaskCompleted` after the expiration handler fires.
    #if !targetEnvironment(macCatalyst)
    private func handle(_ task: BGTask) {
        // Arm the next opportunity right away: a delivered task is a consumed slot, so a
        // fresh request must be submitted for the poll to ever recur.
        Self.scheduleNextRefresh()

        let work: Task<Void, Never> = Task { @MainActor in
            await launchHandler?()
        }

        task.expirationHandler = {
            // System-pressure deadline: cancel the in-flight poll (its URLSession work
            // cooperates with Task cancellation); the work task below observes the
            // cancellation and completes the task with success: false.
            Logger.info("BackgroundRefreshScheduler", "expiration handler fired; cancelling in-flight refresh")
            work.cancel()
        }

        Task { @MainActor in
            await work.value
            let success = !work.isCancelled
            Logger.info("BackgroundRefreshScheduler", "refresh task completed success=\(success)")
            task.setTaskCompleted(success: success)
        }
    }
    #endif

    // MARK: - Submission

    /// Submit the next refresh request. Idempotent: any previously pending request for the
    /// identifier is cancelled first, so repeated background transitions never pile up
    /// duplicate slots. The earliest-begin hint is deliberately modest — iOS decides the
    /// real timing and throttles based on usage.
    static func scheduleNextRefresh() {
        #if targetEnvironment(macCatalyst)
        Logger.debug("BackgroundRefreshScheduler", "schedule skipped: not supported on Mac Catalyst")
        #else
        guard UIApplication.shared.backgroundRefreshStatus == .available else {
            // The user (or MDM) disabled Background App Refresh for this app — degrade to
            // a logged no-op, exactly the acceptance-criterion behaviour.
            Logger.debug("BackgroundRefreshScheduler", "schedule skipped: background refresh status = \(UIApplication.shared.backgroundRefreshStatus.rawValue)")
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: BackgroundRefreshTaskID.mentionPoll)
        // Hint only (~5 min): the OS picks the actual moment; a large hint here would
        // starve test/dev runs, a too-small one is ignored by iOS anyway.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        do {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundRefreshTaskID.mentionPoll)
            try BGTaskScheduler.shared.submit(request)
            Logger.debug("BackgroundRefreshScheduler", "submitted refresh request (earliest +5m)")
        } catch {
            // Non-fatal (e.g. the OS declined): the foreground path keeps notifying;
            // log and move on — never crash, never a stuck task.
            Logger.debug("BackgroundRefreshScheduler", "submit failed: \(error)")
        }
        #endif
    }

    /// Drop any pending refresh request (e.g. when the app returns to the foreground —
    /// the live webviews own mention delivery while active).
    static func cancelPending() {
        #if targetEnvironment(macCatalyst)
        // no-op on Catalyst (nothing was ever scheduled)
        #else
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundRefreshTaskID.mentionPoll)
        #endif
    }

    // MARK: - Pure policy (unit-tested)

    /// Whether background refresh is usable given the system status. `.available` is the
    /// only runnable state; `.denied` (user toggled it off) and `.restricted` (parental
    /// controls/MDM) both degrade to a no-op.
    static func isAvailable(status: UIBackgroundRefreshStatus) -> Bool {
        status == .available
    }
}
