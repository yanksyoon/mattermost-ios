import Foundation

#if canImport(Sentry)
import Sentry
#endif

// MARK: - Real SDK link (Sentry Cocoa integration point)
//
// This file is the ONLY place that touches the real `Sentry` module. It is compiled into the
// target today as a no-op because the Sentry Cocoa SDK is not linked (SwiftPM cannot fetch it
// on this host — see docs/t19a-build-note.md). The day the SDK is added to the target
// (SPM package `getsentry/sentry-cocoa`, product `Sentry`), the `#if canImport(Sentry)` branch
// below activates, installs the `startHook`/`breadcrumbHook` on `SentryService.shared`, and the
// existing DSN guard in `SentryService.start()` drives the real `SentrySDK.start(options:)`.
//
// Wire-up checklist (documented for the operator):
//   1. Add https://github.com/getsentry/sentry-cocoa (product "Sentry") to the Mattermost
//      target's package dependencies.
//   2. Set a real DSN in Info.plist -> SentryDSN (or the future AppConfig).
//   3. Nothing else changes: the DSN guard, crash-file handler, breadcrumbs and diagnostics
//      payload all already flow through `SentryService`.

extension SentryService {

    /// Installs the hooks that invoke the real Sentry Cocoa SDK. Compiles to nothing while the
    /// SDK is absent, so this call is safe unconditionally from AppDelegate.
    static func installRealSDKLinkIfLinked() {
        #if canImport(Sentry)
        SentryService.shared.startHook = { options in
            let sentryOptions = Options()
            sentryOptions.dsn = options.dsn
            sentryOptions.environment = options.environment
            sentryOptions.attachStacktrace = options.attachStacktrace
            sentryOptions.sendDefaultPii = options.sendDefaultPii
            if let userID = options.initialUserID, !userID.isEmpty {
                sentryOptions.initialScope = Scope { scope in
                    scope.setUser(User(userId: userID))
                }
            }
            SentrySDK.start(options: sentryOptions)
        }

        SentryService.shared.breadcrumbHook = { crumb in
            let breadcrumb = Breadcrumb()
            breadcrumb.category = crumb.category
            breadcrumb.message = crumb.message
            switch crumb.level {
            case "debug": breadcrumb.level = .debug
            case "warning": breadcrumb.level = .warning
            case "error": breadcrumb.level = .error
            default: breadcrumb.level = .info
            }
            SentrySDK.addBreadcrumb(breadcrumb)
        }
        #endif
    }
}
