// T34-R5b: the delivery watchdog's visibility gate, as one testable value.
//
// `SocketClient.StallWatchdog` treats a silent-but-open socket as a wedge **only** when the app reports
// that somebody is looking at data this socket feeds (`isSurfaceVisible`). T34-R5b extended that question
// from "the channel pane holds a loaded window for the channel on screen" to three surfaces:
//
//  * the **channel pane**, as before (`ChannelPaneCoordinator.hasLoadedWindow`);
//  * a **thread pane** or the **threads list** — a thread covers the channel it belongs to, so the old
//    gate answered `false` exactly while the reader was staring at the chain a lost `posted` would leave
//    stale (the limit `docs/t34-socket-stall-watchdog-build-note.md` §5 named);
//  * the **mentions feed** — a top-level tab on a phone and a sheet in the regular layout, so it writes no
//    `NativeLocation` at all: the view that draws it is the only object that knows it is on screen, and it
//    reports that to `ActivityCoordinator`.
//
// Why a struct of closures rather than the closure inline in `MattermostApp.bindShellStores`: that wiring
// is inside an `App`, which no unit test can build. Kept here, the rules ("foreground", "native routing",
// "a loaded window for *that* server", "the feed is on screen") are exercisable without a UI — and the
// app's own wiring is then one literal that cannot invent a fourth rule.

import Foundation

/// The shell's answer to "is a live surface this server's socket feeds on screen right now?".
@MainActor
struct NativeSurfaceVisibility {

    /// `UIApplication.shared.applicationState == .active` in production.
    var appIsActive: () -> Bool

    /// `NativeNavigation.acceptsNativeRouting`: with the pane host on the webview, the native panes are
    /// not on screen at all, so nothing native can be staring at a stale window.
    var acceptsNativeRouting: () -> Bool

    /// The destination the shell is showing (`NativeNavigation.location`).
    var location: () -> NativeLocation

    /// `ChannelPaneCoordinator.hasLoadedWindow`.
    var channelWindowLoaded: (UUID, String) -> Bool

    /// `ThreadCoordinator.hasLoadedThread` — the chain for that root is loaded.
    var threadLoaded: (UUID, String) -> Bool

    /// `ThreadCoordinator.hasLoadedThreadList` — any team's threads list for that server is loaded.
    var threadListLoaded: (UUID) -> Bool

    /// `ActivityCoordinator.hasLoadedFeedOnScreen` — the mentions feed for that server is mounted **and**
    /// holds a loaded window.
    var feedOnScreen: (UUID) -> Bool

    /// The one rule. Every branch asks the same question — "is a window somebody is reading stale?" — and
    /// answers `false` when it cannot prove one is: a `false` only costs a delay (the next gap, or the
    /// pane's own appearance refetch), while a wrong `true` turns the watchdog into a poll.
    func isVisible(serverID: UUID) -> Bool {
        guard appIsActive(), acceptsNativeRouting() else { return false }

        // The mentions feed first, and on its own: it is a tab/sheet, so it can be visible while the
        // location still names the channel the reader came from — and that channel's window may well be
        // evicted, which must not make the answer "nobody is looking".
        if feedOnScreen(serverID) { return true }

        let place = location()
        guard place.serverID == serverID else { return false }

        if place.pane == .threads {
            // `/{team}/threads` with a post is the thread pane; without one it is the paged list.
            guard let rootID = place.postID, !rootID.isEmpty else {
                return threadListLoaded(serverID)
            }
            return threadLoaded(serverID, rootID)
        }

        guard let channelID = place.channelID, !channelID.isEmpty else { return false }
        return channelWindowLoaded(serverID, channelID)
    }
}
