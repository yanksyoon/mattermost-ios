// Synthetic scroll driver for scripts/perf_compare.py.
//
// Both subjects are driven the same way: Core Graphics wheel events posted straight to the
// app's pid with CGEventPostToPid. Posting to a pid does not depend on which window is key,
// which keeps the Electron client and the Catalyst client on one input path instead of two
// (AppleScript keystrokes to the focused window, CDP events into a web contents, …).
//
// Usage: perf_scroll <pid> <events> <delta-pixels> <interval-ms>
// Prints one JSON object on stdout: {"granted":bool,"sent":int,"seconds":float}
//
// Requires Accessibility permission for the process that runs it (CGPreflightPostEventAccess).
// A zero `sent` with "granted": false is the honest answer, not a failure to hide.

import CoreGraphics
import Foundation

struct Report: Codable {
    let granted: Bool
    let sent: Int
    let seconds: Double
    let error: String?
}

func fail(_ message: String) -> Never {
    let report = Report(granted: false, sent: 0, seconds: 0, error: message)
    let data = try! JSONEncoder().encode(report)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count == 5 else {
    fail("usage: perf_scroll <pid> <events> <delta-pixels> <interval-ms>")
}
guard let pid = Int32(arguments[1]),
      let events = Int(arguments[2]),
      let delta = Int32(arguments[3]),
      let intervalMs = Int(arguments[4]), intervalMs >= 0 else {
    fail("non-numeric argument")
}

let granted = CGPreflightPostEventAccess()
if !granted {
    let report = Report(granted: false, sent: 0, seconds: 0,
                        error: "accessibility permission refused (CGPreflightPostEventAccess=false)")
    let data = try! JSONEncoder().encode(report)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    exit(3)
}

// Post at the centre of the main display: the wheel event carries a location, and a client that
// hit-tests by location (Electron) needs it to point inside its window. Both subjects are
// required by the preflight to be frontmost and window-sized the same, so the same point is
// inside both.
let screen = CGDisplayBounds(CGMainDisplayID())
let point = CGPoint(x: screen.midX, y: screen.midY)

let started = Date()
var sent = 0
for _ in 0..<events {
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                              wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else {
        continue
    }
    event.location = point
    event.postToPid(pid)
    sent += 1
    if intervalMs > 0 {
        Thread.sleep(forTimeInterval: Double(intervalMs) / 1000.0)
    }
}

let report = Report(granted: true, sent: sent, seconds: Date().timeIntervalSince(started),
                    error: nil)
let data = try! JSONEncoder().encode(report)
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write("\n".data(using: .utf8)!)
