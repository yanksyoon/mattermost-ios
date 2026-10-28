// T635-A instrumentation (card t_7cb5dd3e): what the post list's scroll view actually holds while a
// **restored** channel pane paints no rows.
//
// The defect is invisible to the rest of the app: `ChannelView` reports `.loaded`, `items` is non-empty
// and `channelPostList` exists in the accessibility tree, yet a `LazyVStack` materialises nothing when
// the viewport sits outside the content. Nothing in the product logs a scroll offset, so this file is
// the measurement: `-uiTestExposeScrollGeometry` publishes the controller's geometry as an
// accessibility value (for a UI test) **and** appends it to `Documents/t635-scroll-geometry.log`
// (so `simctl`-only runs, with no XCTest in the loop, can be read back with
// `xcrun simctl get_app_container … data`).
//
// Gated on a launch argument, exactly like every other seam in `ChannelUITestHook`: a build a person
// launches cannot reach this code, and the file is never written without the flag.

import Foundation
import SwiftUI

/// One reading of the post list's scroll view.
struct ChannelScrollGeometrySample {
    var attached: Bool
    var offsetY: CGFloat
    var contentHeight: CGFloat
    var viewportHeight: CGFloat
    var insetTop: CGFloat
    var insetBottom: CGFloat
    var laidOutRows: Int
    /// Rows whose laid-out frame intersects the viewport right now — the honest "a row is on screen".
    var visibleRows: Int
    var topRowID: String?
    var topRowOffset: CGFloat
    /// How far below the viewport's top edge the **lowest** laid-out row reaches, in points.
    ///
    /// This, not `distanceFromBottom`, is what "the pane is on its newest message" means. A measured
    /// stuck state had `offset + viewport == contentSize` (so `distanceFromBottom == 0`, i.e. the *content*
    /// was at its end) and exactly one row whose bottom sat 15 pt below the viewport's top edge: 475 pt
    /// of blank pane below the last thing that was drawn. The content being at its end proves nothing
    /// while the layout that produced that content has not materialised the rows in it.
    var lowestRowBottom: CGFloat
    var distanceFromBottom: CGFloat
    var itemCount: Int
    var fitsViewport: Bool

    /// The offset is inside the scrollable range: `-insetTop ≤ y ≤ contentHeight + insetBottom - viewport`.
    ///
    /// A restored pane that fails this check has been left past the end of its own content, which is
    /// exactly the state in which a `LazyVStack` has nothing to materialise.
    var offsetInsideContent: Bool {
        guard attached, viewportHeight > 0 else { return false }
        let minimum = -insetTop - 1
        let maximum = max(minimum, contentHeight + insetBottom - viewportHeight) + 1
        return offsetY >= minimum && offsetY <= maximum
    }

    /// The claim the acceptance criterion is written against: at least one row is materialised **and**
    /// on screen, with a non-empty window behind it.
    var showsARow: Bool { itemCount > 0 && visibleRows > 0 }

    /// A row reaches the viewport's bottom edge (20 pt of tolerance for the list's 12 pt bottom padding
    /// and sub-pixel layout noise) — the newest message is on screen, not just "some row".
    var bottomRowOnScreen: Bool {
        guard viewportHeight > 0, lowestRowBottom.isFinite else { return false }
        return lowestRowBottom >= viewportHeight - 20
    }

    var summary: String {
        String(format: "rows=%d visible=%d items=%d offset=%.1f size=%.1f viewport=%.1f "
                       + "insetT=%.1f insetB=%.1f top=%@ topY=%.1f lowestRow=%.1f "
                       + "fromBottom=%.1f fits=%@ inside=%@ bottomRow=%@",
               laidOutRows, visibleRows, itemCount, offsetY, contentHeight, viewportHeight,
               insetTop, insetBottom, topRowID ?? "none", topRowOffset, lowestRowBottom,
               distanceFromBottom, fitsViewport ? "yes" : "no",
               offsetInsideContent ? "yes" : "no", bottomRowOnScreen ? "yes" : "no")
    }

    /// The same reading as `summary`, for the append-only log: it carries a wall clock and how long
    /// the app had been running, so several samples can be read as a timeline.
    var logLine: String {
        let now = Date()
        let uptime = ChannelScrollDiagnostics.elapsedSeconds
        return String(format: "t=%8.2fs wall=%@ %@",
                      uptime,
                      ChannelScrollDiagnostics.wallClock.string(from: now),
                      summary)
    }
}

/// Append-only geometry log, plus the one-off "this launch started here" marker.
///
/// Deliberately a plain file in `Documents`: `simctl` has no way to read an accessibility value, so the
/// criterion-3 verification (five launches, no XCTest) is only possible if the app writes its own
/// measurement somewhere the container exposes.
enum ChannelScrollDiagnostics {
    static let fileName = "t635-scroll-geometry.log"
    /// A sample every 250 ms is four readings a second: enough to see the pane settle (or fail to) and
    /// small enough that five launches stay under a few hundred kilobytes.
    static let sampleInterval: Duration = .milliseconds(250)
    /// Cap for the whole file, so a long manual session cannot fill the container.
    private static let maximumLines = 20_000

    static let wallClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let startedAt = Date()
    /// Seconds since this process started — the x axis every line shares.
    static var elapsedSeconds: Double { Date().timeIntervalSince(startedAt) }

    private static let queue = DispatchQueue(label: "t635.scroll-geometry")
    private static var handle: FileHandle?
    private static var lines = 0
    private static var announced = false

    static var isEnabled: Bool { ChannelUITestHook.exposesScrollGeometry }

    /// Append one line (plus a session marker on the first call of a launch).
    static func record(_ line: String) {
        guard isEnabled else { return }
        let body = line + "\n"
        queue.async {
            if !announced {
                announced = true
                write("== session \(UUID().uuidString.prefix(8)) start "
                      + "\(wallClock.string(from: Date())) pid=\(ProcessInfo.processInfo.processIdentifier) ==\n")
            }
            write(body)
        }
    }

    private static func write(_ text: String) {
        guard lines < maximumLines else { return }
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(fileName) else { return }
        if handle == nil {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            handle?.seekToEndOfFile()
        }
        guard let handle, let data = text.data(using: .utf8) else { return }
        handle.write(data)
        lines += 1
    }
}

/// The `-uiTestExposeScrollGeometry` element: a four-point, clear square in the pane header that
/// republishes the list's geometry four times a second.
///
/// It lives in the header (not inside the scroll content) for the same reason `ScrollRestoreSeam` does:
/// a view inside a `LazyVStack` whose viewport is outside the content is not built at all, so a probe
/// placed there could never report the state this card is about.
struct ScrollGeometrySeam: View {
    let controller: ChannelScrollController
    let itemCount: Int

    @State private var summary = "no geometry yet"
    @State private var readings = 0
    /// How many consecutive readings saw a non-empty window with no row on screen — the defect's shape.
    @State private var blankReadings = 0

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 4, height: 4)
            .accessibilityElement()
            .accessibilityLabel("Scroll geometry report")
            .accessibilityValue("\(summary) blankStreak=\(blankReadings) n=\(readings)")
            .accessibilityIdentifier("channelPostList.scrollGeometry")
            .task {
                while !Task.isCancelled {
                    sample()
                    try? await Task.sleep(for: ChannelScrollDiagnostics.sampleInterval)
                }
            }
    }

    @MainActor
    private func sample() {
        let sample = controller.geometry(itemCount: itemCount)
        readings += 1
        if itemCount > 0, !sample.showsARow { blankReadings += 1 } else { blankReadings = 0 }
        summary = sample.summary
        ChannelScrollDiagnostics.record(sample.logLine)
    }
}
