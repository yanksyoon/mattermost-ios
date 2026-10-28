// T95-B — one way to reach a bottom tab, so no suite has to know whether a channel happens to be
// covering the bar.
//
// The compact shell's shape is upstream's (decision `docs/t95-shell-tab-bar-decision.md` §2 D1): a
// `NavigationStack` above the `TabView`, so a channel is pushed **over** the tabs and the bottom bar
// leaves the screen while it is open — the same thing the Mobile v2 design does on a phone (the bar
// slides off inside a channel, and only tablets keep it). The reader's route from a channel to a tab
// is therefore `Back`, then the tab; after T95-A the shell no longer invents a town-hall channel at
// launch (§3 D2), so a reset launch lands on the channel list with its bar and a launch that restored
// the last channel shows the pushed pane with `Back`.
//
// A suite must not care which of the two it got. It says `ShellSettle.tapTab("Search", in: app)` and
// this file does what a reader does: tap the tab when the bar is on screen, otherwise pop the pushed
// channel (at most three times) and tap it. When the bar never comes back from a push the call fails
// with the accessibility tree, because that means the shell's structure changed — a deviation card,
// not a test workaround (`docs/t95-shell-tab-bar-decision.md` §2, last row).
//
// The regular (iPad/Mac) layout draws no bottom bar: there the same screens are reached from the
// detail column's toolbar (`shellSearchButton`, `shellSavedButton`, `shellActivityButton`). With no
// bar and nothing pushed there is nothing to settle, so `tapTab` returns `false` and the call site
// runs its own toolbar branch — the helper settles the compact shape, it does not decide which
// layout is under test.

import XCTest

enum ShellSettle {

    /// The compact shell's tab titles, so a call site cannot drift from `NativeTab.title`.
    enum Tab {
        static let channels = "Channels"
        static let threads = "Threads"
        static let activity = "Mentions"
        static let search = "Search"
        static let saved = "Saved"
    }

    /// Pop whatever the compact shell pushed over the tab bar, back to the channel list.
    ///
    /// Returns `true` when the bar is on screen afterwards (already there, or revealed by `Back`).
    /// Never fails: "this layout has no bar" and "the bar is still covered" are answered by the
    /// return value, and the caller decides what that means in its own context.
    @discardableResult
    static func revealTabs(_ app: XCUIApplication, maxPops: Int = 3) -> Bool {
        if app.tabBars.firstMatch.exists { return true }
        var pops = 0
        while !app.tabBars.firstMatch.exists, pops < maxPops {
            let back = app.navigationBars.buttons["Back"]
            guard back.exists, back.isHittable else { break }
            back.tap()
            pops += 1
            _ = app.tabBars.firstMatch.waitForExistence(timeout: 10)
        }
        return app.tabBars.firstMatch.exists
    }

    /// Tap a bottom tab from wherever the shell is: from the channel list when the bar is up, and
    /// from a pushed channel after `Back` when it is not.
    ///
    /// - Parameters:
    ///   - wait: how long to give the bar to appear before popping (a launch still loading the list
    ///     needs a moment; a layout that has no bar at all should not pay for one).
    /// - Returns: `true` when the tab was tapped; `false` when the layout draws no tab bar and
    ///   nothing is covering one (the regular split layout), so the caller uses its toolbar button.
    @discardableResult
    static func tapTab(_ title: String,
                       in app: XCUIApplication,
                       wait: TimeInterval = 10,
                       maxPops: Int = 3,
                       file: StaticString = #filePath,
                       line: UInt = #line) -> Bool {
        if !app.tabBars.firstMatch.exists {
            _ = app.tabBars.firstMatch.waitForExistence(timeout: wait)
        }

        if !app.tabBars.firstMatch.exists {
            // A pushed channel is the only thing that takes the bar away on compact. Pop it.
            let back = app.navigationBars.buttons["Back"]
            guard back.exists else { return false }
            if !revealTabs(app, maxPops: maxPops) {
                XCTFail("a pushed channel covers the tab bar, but Back did not bring it back after "
                        + "\(maxPops) taps, so \"\(title)\" cannot be reached:\n\(app.debugDescription)",
                        file: file, line: line)
                return false
            }
        }

        let tab = app.tabBars.buttons[title]
        guard tab.waitForExistence(timeout: 10) else {
            XCTFail("the tab bar is on screen but offers no \"\(title)\" tab:\n\(app.debugDescription)",
                    file: file, line: line)
            return false
        }
        tab.tap()
        return true
    }

    /// Any element type carrying `identifier`: SwiftUI decides whether an identifier lands on an
    /// `other`, a `staticText` or a `button`, and that changes across OS versions.
    private static func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Wait until the app is signed in, whichever landing the launch produced.
    ///
    /// A launch with `-uiTestResetPersistedState` lands on the channel list (tab bar up); a launch
    /// **without** it restores the last channel and shows the pushed pane, where `nativeShell` is
    /// not in the accessibility tree at all (the push replaces the root — T37-R2 F1b, and after
    /// T95-A the restore is the last channel or nothing, `docs/t95-shell-tab-bar-decision.md` §3).
    /// A relaunch helper that waits on `nativeShell` alone therefore decides the test's outcome
    /// inside the helper: it fails on the very configuration the test set up. This is the one place
    /// that answers "are we in?" for both shapes.
    @discardableResult
    static func waitForSignedIn(_ app: XCUIApplication,
                                timeout: TimeInterval = 40,
                                file: StaticString = #filePath,
                                line: UInt = #line) -> Bool {
        let field = app.textFields["loginIDField"]
        let shell = element(app, "nativeShell")
        let pane = element(app, "nativeChannelPane")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !field.exists, shell.exists || pane.exists || app.tabBars.firstMatch.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("the app must come back signed in (the channel list, its tab bar, or a pushed "
                + "channel pane) within \(Int(timeout)) s:\n\(app.debugDescription)",
                file: file, line: line)
        return false
    }
}

