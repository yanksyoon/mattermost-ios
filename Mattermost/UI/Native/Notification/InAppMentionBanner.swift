// T54 (inventory S25) — the **in-app** mention banner.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 `app/screens/in_app_notification/`
// (a mention that arrives while the app is open and the conversation is not on screen is shown as a
// tappable banner over the app, not as a system notification) and `app/screens/snack_bar/` (the one
// banner slot: a second notice replaces the first, and it hides itself after a bounded time).
// Licence: Apache-2.0 — behaviour ported; no upstream source copied. This SwiftUI decomposition is
// this repo's own (docs/component-map.md §1).
//
// Why this file exists at all: T43 built the mention *decision* (`MentionNotificationPolicy`) and one
// input path (`NativeNotificationFeed`) whose only presentation was `NotificationWorker` — a **system**
// notification. With the app in the foreground that meant a mention in another channel produced
// nothing visible except a rail badge, which is exactly the gap upstream's in-app notification fills.
//
// The rule this card is written around: **one policy, two presentations.** The mention rules are not
// restated here. `MentionNotificationPolicy` still decides *whether* a post is the reader's mention;
// `MentionPresentationPolicy` below decides only *which surface* shows that decision (in-app banner,
// system notification, or nothing), from facts the shell owns: is the app foreground, is the mention's
// server the one on screen, and which conversation is on screen.
//
// What is deliberately **not** here:
//   * no second ledger. `NativeNotificationFeed` writes the one `MentionLedger` before either surface is
//     used, so the T14 poll cannot re-deliver a mention the banner consumed (T43's rule, reused);
//   * no scheduling. A system-surface decision still goes through `NotificationWorker`, the one
//     scheduler, so T13's Notification Service Extension contract and the tap router are untouched;
//   * no per-screen overlay. `RootView` mounts `InAppMentionBannerHost` once, above the whole navigation
//     stack, so the banner is reachable on the sidebar, in a channel and in both layouts.

import Foundation
import SwiftUI
import UIKit

// MARK: - Which surface shows a mention

/// What the shell is showing, in the terms the presentation decision needs.
///
/// `onScreen` is deliberately `VisibleChannel` — the T43 type the worker already uses — so the banner
/// and the system path cannot disagree about "the conversation the reader is looking at": both read the
/// same answer, produced by the same closure (`MattermostApp.bindShellStores`).
struct MentionSurfaceContext: Equatable {
    /// The app is in the foreground. Backgrounded, the system notification is the only surface that can
    /// be seen, so it is the better one by definition.
    var appIsActive: Bool
    /// The mention's server is the shell's primary server. On another server nothing of that server is
    /// on screen, so a foreground mention there is still a banner.
    var isPrimaryServer: Bool
    /// The conversation on screen for that server (`.unknown` = a webview pane, Path A).
    var onScreen: VisibleChannel

    init(appIsActive: Bool, isPrimaryServer: Bool, onScreen: VisibleChannel) {
        self.appIsActive = appIsActive
        self.isPrimaryServer = isPrimaryServer
        self.onScreen = onScreen
    }
}

/// Why a mention that the policy accepted was nevertheless not shown anywhere.
///
/// A separate type from `MentionDropReason` on purpose: "the reader's notification settings say no" is a
/// policy fact, "which surface" is a presentation fact. Keeping them apart is what lets the Settings
/// read-out say which of the two stopped a mention.
enum MentionPresentationBlock: Equatable {
    /// The mention policy itself refused the post.
    case policy(MentionDropReason)
    /// The reader is looking at that very conversation: neither surface is needed.
    case channelOnScreen
    /// A webview is drawing the pane, so the page owns the focused-channel rule (T8's conservative
    /// whole-server rule, kept for Path A).
    case webPaneOwnsFocus

    var label: String {
        switch self {
        case .policy(let reason): return reason.label
        case .channelOnScreen: return "you are looking at this channel"
        case .webPaneOwnsFocus: return "the web view is drawing this server's pane"
        }
    }
}

/// Where a mention is shown, once it survives the policy.
enum MentionPresentation: Equatable {
    /// The foreground surface: one banner over the shell.
    case inAppBanner(silent: Bool)
    /// The backgrounded surface: `NotificationWorker` schedules it as it always did.
    case systemNotification(silent: Bool)
    /// Neither: suppressed, with the reason worth showing in the read-out.
    case suppressed(MentionPresentationBlock)
}

/// The one presentation rule. Pure: no clock, no stores, no network.
///
/// The table it encodes (each row is a unit test in `T54MentionBannerTests`):
///
/// | policy decision            | app      | server     | on screen            | surface            |
/// | -------------------------- | -------- | ---------- | -------------------- | ------------------ |
/// | `.drop(any)`               | any      | any        | any                  | suppressed(policy) |
/// | `.deliver`                 | inactive | any        | any                  | system             |
/// | `.deliver`                 | active   | not primary| any                  | banner             |
/// | `.deliver`                 | active   | primary    | `.channel(same)`     | suppressed         |
/// | `.deliver`                 | active   | primary    | `.unknown` (webview) | suppressed         |
/// | `.deliver`                 | active   | primary    | `.channel(other)`    | banner             |
/// | `.deliver`                 | active   | primary    | `.noChannel`         | banner             |
enum MentionPresentationPolicy {

    /// - Parameter channelID: the mention's channel, compared with the conversation on screen.
    nonisolated static func presentation(for decision: MentionDecision,
                                         channelID: String,
                                         surface: MentionSurfaceContext) -> MentionPresentation {
        switch decision {
        case .drop(let reason):
            return .suppressed(.policy(reason))

        case .deliver(let silent):
            // Backgrounded: an in-app banner is invisible by construction, so the system surface is the
            // only honest answer — and it is the one the worker already schedules.
            guard surface.appIsActive else { return .systemNotification(silent: silent) }

            // The app is open. Whether a banner is noise depends on the conversation on screen, and only
            // the primary server can have one.
            if surface.isPrimaryServer {
                switch surface.onScreen {
                case .channel(let visible) where visible == channelID:
                    return .suppressed(.channelOnScreen)
                case .unknown:
                    // Path A: the page decides. T8's rule (a visible server's mention is suppressed)
                    // is kept verbatim, because a second opinion here can only add noise.
                    return .suppressed(.webPaneOwnsFocus)
                case .channel, .noChannel:
                    break
                }
            }
            return .inAppBanner(silent: silent)
        }
    }
}

// MARK: - The banner

/// One mention, presented in-app. Built from the same `MentionNotification` fields the system path uses,
/// plus the ids a tap needs — so the text a reader sees in the banner and the text a system notification
/// would carry are produced by one formatter (`MentionNotificationFormatting`).
struct MentionBanner: Equatable, Identifiable {
    var serverID: UUID
    var serverName: String
    var teamID: String?
    var channelID: String
    /// The channel's display name — the banner's title, exactly the system notification's title.
    var channelLabel: String
    var postID: String
    /// The author's username, when the feed could read it. `nil` is the poller's fail-soft case.
    var author: String?
    /// `@username: message`, from `MentionNotificationFormatting.body`.
    var body: String
    /// `notify_props.desktop_sound` was off. The in-app banner is silent either way; the flag is kept so a
    /// future haptic/sound decision has the same input the system path has.
    var silent: Bool
    var receivedAt: Date

    /// One banner per post: a replay of the same post cannot become a second banner.
    var id: String { "\(serverID.uuidString)#\(postID)" }

    /// What the banner shows and what VoiceOver announces: the channel and the author, in one sentence —
    /// the same two facts the card's live test asserts.
    var announcement: String {
        let where_ = channelLabel.isEmpty ? "Mention" : "Mention in \(channelLabel)"
        return "\(where_): \(body)"
    }

    /// The title line: the channel, or the neutral fallback the system path uses.
    var title: String {
        let trimmed = channelLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? MentionNotificationFormatting.defaultTitle : trimmed
    }
}

/// What `present(_:)` did, for the read-out and for tests.
enum BannerOutcome: Equatable {
    /// Nothing was visible: this banner took the slot.
    case shown
    /// Another banner was visible and this one took the slot (upstream's "latest wins").
    case replacedVisible
    /// This exact post is already the visible banner.
    case ignoredDuplicate
    /// A banner without the ids a tap needs cannot be opened, so it is not shown.
    case ignoredIncomplete

    var label: String {
        switch self {
        case .shown: return "shown"
        case .replacedVisible: return "replaced the previous banner"
        case .ignoredDuplicate: return "already showing"
        case .ignoredIncomplete: return "ignored (incomplete)"
        }
    }
}

/// The one banner slot, app-wide.
///
/// State, not a second notification ledger: it holds at most the banner **currently visible**. The fact
/// "this mention was handled" lives in `MentionLedger` (T43), which the feed writes before handing a
/// mention to either surface — so a mention the banner showed cannot re-fire from the poller or the
/// socket, and this object never has to remember posts it has finished with.
@MainActor
final class InAppMentionBannerCenter: ObservableObject {

    /// The banner on screen, if any. At most one, ever.
    @Published private(set) var current: MentionBanner?

    /// Counters for the Settings read-out / live test. Presentation facts only.
    @Published private(set) var shownCount = 0
    @Published private(set) var replacedCount = 0
    @Published private(set) var hiddenCount = 0
    @Published private(set) var lastShown: MentionBanner?
    @Published private(set) var lastOutcome = "none"

    /// How long a banner stays. Upstream's snack bar is time-bounded; six seconds is long enough to read
    /// "@user: one line of message" at a glance and short enough not to sit over the composer.
    var visibleDuration: TimeInterval = 6

    /// VoiceOver announcement seam. The real one posts an announcement; a test records the string. The
    /// banner is a transient element, so VoiceOver would otherwise read it only if the reader swiped to it.
    ///
    /// Main-actor on purpose: both the default (UIKit) and the app's own callers are main-actor code, and a
    /// nonisolated closure here would force every caller into a hop for no reason.
    var announce: @MainActor (String) -> Void = { text in
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    /// A tap on the banner: the **same** funnel a system-notification tap uses
    /// (`NativeNavigation.routeMention`). Installed by `MattermostApp`, which owns the router.
    var onOpen: (@MainActor (MentionBanner) -> Void)?

    var now: () -> Date = Date.init

    private var dismissTask: Task<Void, Never>?

    init() {}

    // MARK: Presentation

    @discardableResult
    func present(_ banner: MentionBanner) -> BannerOutcome {
        guard !banner.postID.isEmpty, !banner.channelID.isEmpty else {
            lastOutcome = BannerOutcome.ignoredIncomplete.label
            return .ignoredIncomplete
        }
        if current?.id == banner.id { return .ignoredDuplicate }

        let outcome: BannerOutcome
        if current == nil {
            shownCount += 1
            outcome = .shown
        } else {
            // Latest wins: one visible banner, never a stack. A backlog was rejected on purpose — a queue
            // would show a reader a mention from a minute ago after the newer one, which is the noise the
            // in-app banner exists to avoid.
            replacedCount += 1
            outcome = .replacedVisible
        }
        current = banner
        lastShown = banner
        lastOutcome = outcome.label
        announce(banner.announcement)
        scheduleAutoDismiss()
        Logger.info("InAppMentionBanner", "\(banner.channelLabel) \(banner.postID) -> \(outcome.label)")
        return outcome
    }

    /// Hide the visible banner. Returns whether there was one.
    @discardableResult
    func dismiss() -> Bool {
        dismissTask?.cancel()
        dismissTask = nil
        guard current != nil else { return false }
        current = nil
        hiddenCount += 1
        return true
    }

    /// A tap: the banner goes away **and** the conversation opens, in that order, so the reader never sees
    /// a banner over the channel it just opened.
    func openCurrent() {
        guard let banner = current else { return }
        dismiss()
        onOpen?(banner)
    }

    /// Await the auto-dismiss timer (tests and a live run can use it instead of sleeping).
    func flushAutoDismiss() async {
        await dismissTask?.value
    }

    private func scheduleAutoDismiss() {
        dismissTask?.cancel()
        let delay = max(0, visibleDuration)
        dismissTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }
            self.dismiss()
        }
    }
}

// MARK: - The view

/// The banner itself: a tappable card at the top of the shell.
///
/// It is one accessibility element on purpose — VoiceOver reads "Mention in #channel: @author: message"
/// and the element is a button, so double-tapping opens the conversation. It never becomes first
/// responder and holds no `@FocusState`: the composer's keyboard stays exactly where it was.
struct InAppMentionBannerView: View {
    let banner: MentionBanner
    var onOpen: () -> Void
    var onDismiss: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "at")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor.opacity(0.14)))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(banner.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .mmLineLimit(1)
                    Text(banner.body)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .mmLineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.forward")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mentionBanner")
        .accessibilityLabel(banner.announcement)
        .accessibilityHint("Opens the conversation")
        .accessibilityAddTraits(.isButton)
        // Swipe up or down to dismiss, upstream-snackbar style; the tap is the primary action, so the
        // drag is simultaneous rather than competing with the button.
        .simultaneousGesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                if abs(value.translation.height) > 30 { onDismiss() }
            }
        )
    }
}

/// Mounts the one banner slot above whatever it is applied to (the whole navigation stack, in `RootView`).
///
/// `nil` when nothing is showing, so the host adds no view, no hit-test area and no accessibility element
/// in the common case — the shell's layout is untouched while no mention is on screen.
struct InAppMentionBannerHost: ViewModifier {
    @ObservedObject var center: InAppMentionBannerCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let banner = center.current {
                    InAppMentionBannerView(banner: banner,
                                           onOpen: { center.openCurrent() },
                                           onDismiss: { center.dismiss() })
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .transition(MotionPolicy.transition(.move(edge: .top).combined(with: .opacity),
                                                            for: .incidental,
                                                            reduceMotion: reduceMotion))
                        .zIndex(1)
                }
            }
            .mmAnimation(.spring(response: 0.35, dampingFraction: 0.86),
                         value: center.current,
                         essence: .incidental,
                         reduceMotion: reduceMotion)
    }
}

extension View {
    /// Apply the app's one in-app banner slot.
    func inAppMentionBanner(_ center: InAppMentionBannerCenter) -> some View {
        modifier(InAppMentionBannerHost(center: center))
    }
}
