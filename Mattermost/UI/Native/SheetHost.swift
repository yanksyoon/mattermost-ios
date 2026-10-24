// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/components/post_options/ (bottom-sheet presentation), app/screens/user_profile/ (sheet),
//        app/screens/emoji_picker/ (sheet) — @gorhom/bottom-sheet usage patterns.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §3; no
// upstream source copied. SwiftUI decomposition is this repo's own (docs/component-map.md §1).

import Observation
import SwiftUI

/// The one place the native UI presents a sheet (`docs/component-map.md` §1: *"Modal / bottom-sheet
/// → `.sheet(item:)` + `presentationDetents`; sheet host pattern lives in `UI/SheetHost.swift`"*).
///
/// ## Why a shared host instead of `@State private var isPresenting…` per screen
///
/// A view can present exactly **one** sheet at a time, and a second `.sheet` attached while one is
/// up is silently dropped by UIKit — no error, no presentation, the tap just does nothing. Upstream's
/// RN client has the same constraint (`@gorhom/bottom-sheet` is a single host per screen tree) and
/// solves it by keeping one presenter at the root. Sixteen screen cards each owning a `@State`
/// boolean would reproduce the failure mode sixteen times, and every one of them would be a
/// different, independently-written answer to "what happens when a second sheet is asked for".
///
/// So: screens describe *what* they want shown (`SheetRoute`), `SheetHostModel` decides *whether it
/// can be shown now* (or queues it behind the sheet that is up), and one `.sheetHost(_:)` modifier at
/// the root renders it with the detents the route asked for.
///
/// Seeded by T30b with the synchronized `UI/Native/` tree. Nothing presents through it yet: the first
/// adopters are the screen cards that own a modal surface (`userProfile` — S24/T41, `emojiPicker` —
/// S17/T37, `postOptions` — S38/T34+T37, the server switcher and Settings the shell already shows).
/// It is deliberately *not* a stub of a screen: it contains no screen, only the presentation
/// mechanism every screen card would otherwise have to write for itself.
struct SheetRoute: Identifiable, Hashable {
    /// Stable identity. Two requests with the same id describe the same sheet — that is what makes
    /// `present` idempotent for a repeated tap on the same control.
    let id: String
    /// The detents the sheet should offer. Empty means "the system default" (`.large`).
    let detents: Set<PresentationDetent>

    init(id: String, detents: Set<PresentationDetent> = []) {
        self.id = id
        self.detents = detents
    }

    /// What `.sheet` actually applies. `.large` is the system default and is not passed explicitly,
    /// so a caller that supplies no detents gets exactly what a plain `.sheet` would give it.
    var effectiveDetents: Set<PresentationDetent> {
        detents.isEmpty ? [.large] : detents
    }
}

/// The shell's sheet presentation state: at most one sheet up, at most one queued.
///
/// `@MainActor` because presentation is main-thread-only, `@Observable` per the component map's
/// view-model rule (§1: `useState` → `@Observable` view model).
///
/// ## The rules, and why they are these rules
///
/// * `present(_:)` while nothing is up — shows it.
/// * `present(_:)` for the sheet that is **already up** — no-op. A double tap on "Settings" must not
///   dismiss and re-present the settings sheet (that would also lose its scroll position).
/// * `present(_:)` for a *different* sheet while one is up — queues it, and **the latest request
///   wins**. This is the real reason the model exists: UIKit drops a competing presentation, so
///   without a queue a tapped reaction-emoji from inside the post-options sheet would vanish. Latest
///   wins rather than a FIFO stack because a queue of sheets the user never asked to see in that
///   order is worse than one, and each request is a current intent rather than a job item.
/// * `dismiss()` promotes the queued sheet in the same call, so there is never a frame with "nothing
///   presented but something pending".
@MainActor
@Observable
final class SheetHostModel {
    /// The sheet that is up, or `nil`. Read-only from outside: presentation goes through the methods
    /// below so the queue cannot be bypassed.
    private(set) var route: SheetRoute?
    /// At most one queued route, waiting for `route` to be dismissed.
    private(set) var pending: SheetRoute?

    init(route: SheetRoute? = nil) {
        self.route = route
    }

    /// Ask for `route` to be presented. Returns `true` when it is on screen after this call.
    @discardableResult
    func present(_ route: SheetRoute) -> Bool {
        guard let current = self.route else {
            self.route = route
            return true
        }
        guard current.id != route.id else { return true }   // already up: not a second sheet
        pending = route                                      // latest queued request wins
        return false
    }

    /// Dismiss the sheet that is up and, if one was queued, show it immediately.
    func dismiss() {
        route = pending
        pending = nil
    }

    /// Dismiss only if the sheet with `id` is the one that is up.
    ///
    /// A sheet's own `onDismiss` can fire after the sheet was already replaced by a queued one (the
    /// classic "dismissed the sheet the user had just opened"); scoping the dismissal to the route it
    /// was called for turns that late callback into a no-op instead of closing someone else's sheet.
    func dismiss(_ id: String) {
        guard route?.id == id else { return }
        dismiss()
    }

    /// Drop the queue without touching what is on screen.
    func cancelPending() {
        pending = nil
    }

    /// The write path SwiftUI itself uses (`.sheet(item:)` writes `nil` when the user swipes a sheet
    /// away, and the identity of the item when it presents one).
    ///
    /// It exists as a method rather than an exposed `route` setter so that *every* route out of a
    /// sheet — the model's own `dismiss()` and an interactive swipe-dismiss by the system — promotes
    /// the queued route. A publicly settable `route` would let UIKit's dismissal strand the queue.
    func applySheetChange(_ newValue: SheetRoute?) {
        if let newValue {
            present(newValue)
        } else {
            dismiss()
        }
    }
}

/// Attach the shell's one sheet presenter.
///
/// Used once, at the root of the native UI tree (the shell or the screen that owns a split view), so
/// every screen's modal request goes through the same presentation point:
///
/// ```swift
/// NativeShellView(...)
///     .sheetHost(sheetHost) { route in
///         switch route.id {
///         case "settings": SettingsView(...)
///         default:         EmptyView()
///         }
///     }
/// ```
private struct SheetHostModifier<SheetContent: View>: ViewModifier {
    let host: SheetHostModel
    @ViewBuilder var sheetContent: (SheetRoute) -> SheetContent

    func body(content: Content) -> some View {
        // The read of `host.route` happens *here*, in the modifier's own body, because that is the
        // tracking scope `@Observable` registers a dependency in. `.sheet(item:)` reads the binding
        // lazily inside SwiftUI's presentation machinery, which is not guaranteed to be inside this
        // scope — without the touch the sheet would not re-evaluate when the model changes.
        _ = host.route
        return content.sheet(
            item: Binding(
                get: { host.route },
                set: { host.applySheetChange($0) }
            )
        ) { route in
            sheetContent(route)
                .presentationDetents(route.effectiveDetents)
                .presentationDragIndicator(.visible)
        }
    }
}

extension View {
    /// Present the shell's sheets from `host` — one presenter for the whole native UI tree, so two
    /// screens asking at the same time produce a queued presentation instead of a dropped one.
    func sheetHost<SheetContent: View>(
        _ host: SheetHostModel,
        @ViewBuilder content: @escaping (SheetRoute) -> SheetContent
    ) -> some View {
        modifier(SheetHostModifier(host: host, sheetContent: content))
    }
}
