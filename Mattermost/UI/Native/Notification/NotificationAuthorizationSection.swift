// Settings → Notifications → authorisation.
//
// Why this exists (the card behind it): authorisation used to be asked **only** on the first mention
// that reached `NotificationWorker.presentMention`. On an install that had never seen one — a quiet
// team, a muted server, a foreground-only session — the OS prompt was never shown, so the app sat at
// `.notDetermined` forever and Settings said nothing about it. The reported symptom ("no
// notifications, and nothing tells me why") was that silence, not a delivery bug.
//
// So this section is the user's own way in:
//   - the state row always says what the system currently answers, in plain words, **including**
//     `notDetermined` ("the app has not been allowed yet") and `denied` ("open System Settings");
//   - `Enable notifications` calls the same `prepareAuthorization()` the first mention calls, on
//     demand — the system prompt appears here, without waiting for a mention to arrive;
//   - `Send a test notification` schedules exactly one local banner through the very path a mention
//     uses (`NotificationWorker.sendTestNotification` → `NotificationScheduling.add`), so "is this
//     working at all" is answerable in Settings;
//   - the diagnostics line is drawn here too, so a support report can quote it without reading
//     `ncprefs.plist`.
//
// It is a view of rows, not a `Section`: `SettingsView` places it inside the existing Notifications
// section, under the badge toggle, so the category the desktop renders stays one category.

import SwiftUI
import UIKit
import UserNotifications

/// The authorisation rows `SettingsView` draws inside its Notifications section.
struct NotificationAuthorizationRows: View {
    @ObservedObject var worker: NotificationWorker

    /// Last test-button outcome, in plain words. `nil` before the button has been used.
    @State private var testOutcome: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                Text(worker.statusLabel)
                    .accessibilityIdentifier("notificationAuthorization.status")
                    .accessibilityValue(worker.authorizationCopy)
            } label: {
                Text("Notifications")
            }
            // The status in full, not only its short form: `notDetermined` must say the app has
            // never been allowed rather than look like a silent "off" (card item 3), and an
            // `authorized` answer with no OS registration row must say that no banner can appear
            // (t_e4d5a252) rather than reading "Allowed".
            Text(worker.authorizationCopy)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("notificationAuthorization.copy")

            if worker.registrationState == .notRegistered {
                Text("Open System Settings > Notifications, find Mattermost in the list, and allow it. "
                     + "Then reopen the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("notificationAuthorization.registrationHint")
            } else if worker.isAllowed && worker.deliverySettings.alertStyle == "none" {
                // t_e4d5a252: the row exists and the app is allowed, but the system's style for it is
                // "none" — the request is delivered to Notification Center and no banner is ever drawn.
                Text("Mattermost is allowed, but its notification style is set to none. "
                     + "Open System Settings > Notifications > Mattermost and choose Banners or Alerts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("notificationAuthorization.styleHint")
            }
        }
        // Re-read on entry: the reader may have changed the system permission while the sheet was
        // closed, and a stale `.notDetermined` row would be the same lie this card removes. The same
        // read refreshes the OS registration fact, so a grant made in System Settings shows up here.
        .task { await worker.reloadAuthorizationStatus() }

        Button {
            Task { await worker.prepareAuthorization() }
        } label: {
            Label("Enable notifications", systemImage: "bell.badge")
        }
        .accessibilityIdentifier("notificationAuthorization.enable")

        if worker.needsSystemSettings {
            Button {
                openSystemSettings()
            } label: {
                Label("Open System Settings", systemImage: "gear")
            }
            .accessibilityIdentifier("notificationAuthorization.openSettings")
        }

        Button {
            Task { await sendTest() }
        } label: {
            Label("Send a test notification", systemImage: "paperplane")
        }
        .accessibilityIdentifier("notificationAuthorization.sendTest")

        if let testOutcome {
            Text(testOutcome)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("notificationAuthorization.testOutcome")
        }

        Text(worker.diagnosticsLine)
            .font(.caption2)
            .monospaced()
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("notificationAuthorization.diagnostics")
    }

    private func sendTest() async {
        let outcome = await worker.sendTestNotification()
        testOutcome = Self.testOutcomeCopy(outcome)
    }

    /// Where a reader who must fix this outside the app goes.
    ///
    /// On a Mac, the app's own Settings page does not list notification permission: it lives in
    /// System Settings > Notifications, so the deep link names that pane (macOS has no public
    /// per-app notification deep link). On iOS, the app's page is exactly right.
    private func openSystemSettings() {
        #if targetEnvironment(macCatalyst)
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            openURL(url)
            return
        }
        #endif
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    /// What the button did, in the same words a reader would use. Every `notSent` reason is named:
    /// "nothing happened" is exactly the report this card exists to end.
    static func testOutcomeCopy(_ outcome: NotificationWorker.PresentOutcome) -> String {
        switch outcome {
        case .scheduled:
            return "Scheduled - a banner should appear now. If it does not, the system or a Focus mode is holding it."
        case .notSent(.authorizationDenied):
            return "Not scheduled - notifications are not allowed. Open System Settings to allow them."
        case .notSent(.authorizationNotDetermined):
            return "Not scheduled yet - answer the system prompt, then tap again."
        case .notSent(.addFailed):
            return "Not scheduled - the system refused the notification request."
        case .notSent(.missingServer), .notSent(.viewShouldNotNotify):
            // Neither is reachable from this button (it never names a server/channel), but the
            // switch stays exhaustive so a future reason cannot fall through silently.
            return "Not scheduled."
        }
    }
}
