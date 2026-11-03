// T95-B — one way to reach a bottom tab, so no suite has to know whether a channel happens to be
// covering the bar.
//
// The compact shell's shape is upstream's (decision `docs/t95-shell-tab-bar-decision.md` §2 D1): a
// `NavigationStack` above the `TabView`, so a channel is pushed **over** the tabs and the bottom bar
// leaves the screen while it is open — the same thing the Mobile v2 design does on a phone (the bar
// slides off inside a channel, and only tablets keep it). The reader's route from a channel to a tab
// is therefore `Back`, then the tab. Launch opens a channel too: the saved one, else the team's town
// hall (t_295b0a32 restored that fallback), so a reset launch lands on a pushed pane and only a
// launch whose list has not loaded lands on the channel list with its bar.
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

    /// The channel sidebar's own scroll surface — what a suite swipes to realise a row that is
    /// below the fold.
    ///
    /// T8f replaced the channel list's `List` with `ScrollView` + `LazyVStack`, so the element these
    /// suites used to reach with `element(app, "nativeTeamSidebar").collectionViews.firstMatch` no
    /// longer exists: the list carries `channelSidebar.scroll` on its scroll view now
    /// (`NativeChannelSidebarContent.scrollIdentifier`). The *identifier* is what makes this
    /// correct rather than positional — `nativeTeamSidebar` also contains the team rail's own
    /// `ScrollView`, which sits to the left, so `scrollViews.firstMatch` can swipe the three team
    /// icons and never the channel list.
    ///
    /// The legacy query is kept as a fallback so a suite run against a build from before T8f
    /// scrolls instead of failing on "no such element"; on this tree it resolves to nothing.
    static func channelSidebarScroll(_ app: XCUIApplication) -> XCUIElement {
        let scroll = element(app, "channelSidebar.scroll")
        if scroll.exists { return scroll }
        let legacy = element(app, "nativeTeamSidebar").collectionViews.firstMatch
        return legacy.exists ? legacy : scroll
    }

    /// What one sweep of the sidebar cost, so a call site can put it in its failure message and a
    /// reader can tell "the row is not in this account's list" from "the sweep gave up early".
    struct SidebarReveal {
        let row: XCUIElement
        let swipes: Int
        /// `Back` taps spent getting the channel list on screen at all (a launch opens a channel —
        /// `t_295b0a32` — so the sidebar is covered until the pane is popped).
        let pops: Int
        /// Measured only when the sweep failed — the count itself is an any-type query, and this
        /// helper does not spend the log budget it was fixed to protect (`docs/t8d-build-note.md` §2).
        let rowsDrawn: Int?
        var found: Bool { row.exists }
        var report: String {
            var text = "\(found ? "realised" : "not realised") after \(swipes) swipe(s) of the sidebar"
            if pops > 0 { text += ", after \(pops) Back tap(s) to the channel list" }
            if let rowsDrawn {
                text += ", \(rowsDrawn) channel row(s) drawn at the end"
            }
            return text
        }
    }

    /// Bring the **channel list** on screen after a launch that landed on a pushed channel pane.
    ///
    /// Since `t_295b0a32` a signed-in launch opens a channel and pushes it *over* the list, so the
    /// sidebar (`channelSidebar.*`) is not in the accessibility tree until the pane is popped the way
    /// a reader pops it — `Back`. Measured 2026-11-04 against `origin/main` f631629: a sweep started
    /// while the hand-over was in flight failed hard (`Failed to swipe up "channelSidebar.scroll": No
    /// matches found`), so this waits for the landing first, then pops, bounded.
    ///
    /// The 6 s wait is a ceiling, not a sleep: a launch that lands on the list answers at once and
    /// costs only the round trip.
    ///
    /// - Returns: how many `Back` taps it took (0 when the list was already up) — reported by callers
    ///   so a failure says whether the list was ever reached.
    @discardableResult
    static func revealChannelList(_ app: XCUIApplication, maxPops: Int = 3) -> Int {
        _ = app.otherElements["nativeChannelPane"].waitForExistence(timeout: 6)
        var pops = 0
        while pops < maxPops, !channelSidebarScroll(app).exists {
            let back = app.navigationBars.buttons["Back"]
            guard back.exists, back.isHittable else { break }
            back.tap()
            pops += 1
            _ = channelSidebarScroll(app).waitForExistence(timeout: 10)
        }
        return pops
    }

    /// Scrolling the chrome, not a fixture: reach the channel row for `channelID`.
    ///
    /// **Why every live sidebar test needs this.** The channel list is a `ScrollView` + `LazyVStack`
    /// (`NativeChannelSidebarContent`), so a row outside the materialised window is *not in the
    /// accessibility tree at all* — "the row does not exist" and "the row is 4 000 pt below the fold"
    /// are the same answer to an existence query. On the shared fixture server this stopped being
    /// hypothetical: account `perfprobe` is in **351** channels of team `perf`, the sidebar's content
    /// holds **5 095 pt** inside its 874 pt viewport ("Vertical scroll bar, 8 pages"), and the rows
    /// materialised at rest are `T8G probe 00xx` — the suites' own channels are nowhere near them.
    /// T36, T44D and T31 were written when the fixture channel was above the fold
    /// (`docs/t36-build-note.md` §7, 2026-10-25); that assumption is the defect, not the product.
    ///
    /// The order is deliberate. Down first with fast flicks (a row far below is cheap to reach), then
    /// back up **slowly**, because a fast flick crosses several screens and can step straight over the
    /// row — a lazy stack only materialises a row while it is near the viewport, so an overshoot looks
    /// exactly like absence. Slow swipes on the way back up re-cross the list in fine steps, so an
    /// overshoot costs time, never correctness. Both bounds are reported.
    ///
    /// **The query type is part of the contract, not a style choice.** Every existence check here runs
    /// *inside the app process* as XCUITest's accessibility serialiser, and that log volume is what
    /// libtrace quarantines; past the quota the next `os_log` under a snapshot takes the app down with
    /// a SIGSEGV (`docs/t8d-build-note.md` §1–§2, and the measured instance in
    /// `docs/t_c941e3d3-build-note.md` §4: the first version of this helper used an any-type query per
    /// swipe and killed the app once in five launches). So the hot path asks a **type-scoped**
    /// `buttons` query — measured rows are `Button`s — and the any-type form is used only when a phase
    /// ends without a hit, where an element-type disagreement across OS versions is the only thing it
    /// can still add.
    ///
    /// Never asserts: the caller owns the assertion and its timeout, so it can say what *it* required.
    static func revealSidebarChannel(_ app: XCUIApplication,
                                     channelID: String,
                                     maxDownSwipes: Int = 24,
                                     maxUpSwipes: Int = 32,
                                     maxPops: Int = 3) -> SidebarReveal {
        let identifier = "channelSidebar.channel.\(channelID)"
        let cheap = app.buttons[identifier]
        func pause() { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        /// Cheap hit on the hot path: no element materialised unless the row is there.
        func cheapHit() -> XCUIElement? {
            pause()
            return cheap.exists ? cheap : nil
        }
        /// The expensive form, at a phase boundary only.
        func exhaustiveHit() -> XCUIElement? {
            let any = element(app, identifier)
            return any.exists ? any : nil
        }
        if let row = cheapHit() {
            return SidebarReveal(row: row, swipes: 0, pops: 0, rowsDrawn: nil)
        }
        // The sidebar is only in the tree while the channel list is on screen, and since t_295b0a32 a
        // signed-in launch opens a channel (the saved one, else the team's town hall) and pushes it
        // *over* the list — so the first call after a settle is looking at a pushed pane. Measured
        // 2026-11-04 against `origin/main` f631629, "not realised after 0 swipe(s) of the sidebar,
        // 0 channel row(s) drawn" with `nativeChannelPane` "Town Square" in the dump: the sweep never
        // started.
        //
        // The push lands a beat *after* the list is first drawn, so the order matters: wait for the
        // landing, pop it the way a reader does (`Back`, the same tap `revealTabs` uses), and only
        // then start the sweep. Starting while the hand-over is in flight is not a slow failure but a
        // hard one — `Failed to swipe up "channelSidebar.scroll": No matches found` (5/5 red, same
        // date) — because the element the query resolved is gone when the event is synthesized.
        // The 6 s ceiling is a ceiling, not a sleep: a launch that lands on the list answers at once
        // and the wait costs only the round trip.
        //
        // This deliberately does not call `revealTabs`: that helper stops when the *tab bar* is
        // visible, while a sidebar sweep needs the *list* — on this tree the two arrive together, but
        // the list is what the sweep must be handed.
        let pops = revealChannelList(app, maxPops: maxPops)
        // The pop animates; a swipe sampled mid-animation is the same lost element as above.
        pause()
        pause()
        let list = channelSidebarScroll(app)
        guard list.exists else {
            print("[shellsettle] no sidebar scroll surface after \(pops) Back tap(s): cannot scroll to \(identifier)")
            let any = element(app, identifier)
            return SidebarReveal(row: any, swipes: 0, pops: pops, rowsDrawn: drawnSidebarRows(app))
        }
        var swipes = 0
        var found: XCUIElement?
        for _ in 0..<maxDownSwipes {
            if let hit = cheapHit() { found = hit; break }
            list.swipeUp(velocity: .fast)
            swipes += 1
        }
        if found == nil { found = exhaustiveHit() }
        if found == nil {
            for _ in 0..<maxUpSwipes {
                if let hit = cheapHit() { found = hit; break }
                list.swipeDown(velocity: .slow)
                swipes += 1
            }
        }
        if found == nil { found = exhaustiveHit() }
        let reveal = SidebarReveal(row: found ?? element(app, identifier),
                                   swipes: swipes,
                                   pops: pops,
                                   rowsDrawn: found == nil ? drawnSidebarRows(app) : nil)
        print("[shellsettle] \(identifier): \(reveal.report)")
        return reveal
    }

    /// Every channel row currently in the accessibility tree — a diagnostic count for the message
    /// above, never an expectation (which rows are materialised is the shell's business).
    static func drawnSidebarRows(_ app: XCUIApplication) -> Int {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "channelSidebar.channel."))
            .count
    }

    /// Wait until the app is signed in, whichever landing the launch produced.
    ///
    /// A launch with `-uiTestResetPersistedState` has nothing saved: since t_295b0a32 it opens the
    /// team's town hall (a pushed pane with `Back`), and only a launch whose channel list has not
    /// loaded lands on the channel list (bar up). A launch **without** the reset restores the last
    /// channel and shows the pushed pane, where `nativeShell` is not in the accessibility tree at all
    /// (the push replaces the root — T37-R2 F1b).
    /// A relaunch helper that waits on `nativeShell` alone therefore decides the test's outcome
    /// inside the helper: it fails on the very configuration the test set up. This is the one place
    /// that answers "are we in?" for both shapes.
    @discardableResult
    static func waitForSignedIn(_ app: XCUIApplication,
                                timeout: TimeInterval = 40,
                                file: StaticString = #filePath,
                                line: UInt = #line) -> Bool {
        // T8d — every `.exists` here is a full accessibility snapshot, and the snapshot is not free:
        // XCUITest's serialiser runs *inside the app process* and logs each element it visits
        // (`com.apple.dt.xctest:Default`). Measured on `81A7F251` (run `t8d-base-A`): 79.5 MB of app
        // log for one 8-test batch, 78% of it from that serialiser, and one any-type identifier
        // query on a fully drawn shell costs ~1 MB. Sustained past ~600 KB/s the process's firehose
        // buffer is quarantined, and the next `os_log` while a snapshot is being taken faults through
        // `runtime_issue_os_log_fault_callback` and crashes the app (see `docs/t8d-build-note.md` §1).
        //
        // So this wait does the cheap thing: one typed query per identifier per iteration instead of
        // three any-type ones, and it looks twice a second instead of four times. `nativeShell` and
        // `nativeChannelPane` are `Other` elements (measured from the tree in `t8d-base-A`), and a
        // type-scoped query costs ~10x less than `descendants(matching: .any)` because the walk
        // fetches the element type for candidates first and the rest of the attribute set only for
        // them. Same claim, same 40 s budget, ~an order of magnitude less log.
        let field = app.textFields["loginIDField"]
        let shell = app.otherElements["nativeShell"]
        let pane = app.otherElements["nativeChannelPane"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !field.exists, shell.exists || pane.exists || app.tabBars.firstMatch.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTFail("the app must come back signed in (the channel list, its tab bar, or a pushed "
                + "channel pane) within \(Int(timeout)) s:\n\(app.debugDescription)",
                file: file, line: line)
        return false
    }
}

