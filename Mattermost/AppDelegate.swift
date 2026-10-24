import UIKit

/// Phase-0 AppDelegate. Native counterpart of desktop `app/index.ts` / `initialize.ts`
/// (registration and service bootstrap). Parity row: `App init` -> `@main App` + `AppDelegate`;
/// Status: native, P0.1.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Logger.info("AppDelegate", "Mattermost iOS launched")

        // T19a: Sentry/diagnostics bootstrap. The uncaught-exception handler is installed
        // unconditionally (it writes crash files for the diagnostics report); SentrySDK.start
        // is DSN-gated inside SentryService.start() — with no SentryDSN configured it is a
        // pure no-op (never touches the SDK), verified by unit test. installRealSDKLinkIfLinked
        // is inert until the Sentry Cocoa SDK is linked into the target (see SentrySDKLink.swift).
        SentryService.installRealSDKLinkIfLinked()
        SentryService.shared.installUncaughtExceptionHandler()
        SentryService.shared.start()
        SentryService.shared.addBreadcrumb(category: "app", message: "didFinishLaunching", level: "info")

        // T14: register the BGAppRefreshTask that drives Option-A mention polling. The
        // handler funnels through MentionPoller, whose stores are bound by MattermostApp.task
        // (normal launches) or degrade to logged no-ops (pure background launches).
        // Registering happens exactly once; a second register for the same identifier would
        // crash, so the scheduler guards itself.
        BackgroundRefreshScheduler.shared.register { [weak mentionPoller = MentionPoller.shared] in
            guard let mentionPoller else { return }
            _ = await mentionPoller.pollAllServers()
        }

        // Remote push registration is intentionally NOT performed here — it requires a Push
        // Proxy (risk R1, Phase 4) and entitlement.
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Phase 2 UserActivityMonitor reconciles idle/active presence here.
    }
}