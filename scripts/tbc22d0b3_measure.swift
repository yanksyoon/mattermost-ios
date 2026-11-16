// t_bc22d0b3 evidence tool: measure the header's trailing controls off a real `drawHierarchy` PNG.
//
// Why pixels when the app already reports points: the point values come from the same layout code
// under test, and the card asks for the measured pixel gaps. This reads the PNG and reports, for one
// horizontal band, the columns that carry ink — grouping them into runs whose gaps are the gaps a
// reader sees. Points = pixels / scale (2 on this host's captures).
//
// Usage: swift scripts/tbc22d0b3_measure.swift <png> <y0> <y1> <x0> <x1> <scale>
//
// How the PNG and the band are produced (docs/t_bc22d0b3-build-note.md §3.3): launch the Catalyst
// build of this branch against a fixture server with
//
//   -uiTestSeedServer <url> -uiTestSeedStoredToken <token>
//   -uiTestOpenDeepLink <url>/<team>/channels/<channel-id>
//   -uiTestExposeHeaderGeometry -nativeShellSnapshot <dir> -uiTestLogLevel info
//
// which writes `<dir>/native-shell-light.png` (2× window) and logs the same layout in points
// (`Tbc22d0b3: header geometry …`). The header band in that capture is y ≈ 402…512 px at x ≥ 2200 px
// for a 2660×1996 window; the app's own report gives the exact band (`header=<x>,<y>,<w>,<h>`).

import CoreGraphics
import Foundation
import ImageIO

let args = CommandLine.arguments
guard args.count >= 7,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("usage: measure.swift <png> <y0> <y1> <x0> <x1> <scale>")
    exit(2)
}
let y0 = Int(args[2])!, y1 = Int(args[3])!, x0 = Int(args[4])!, x1 = Int(args[5])!
let scale = Double(args[6])!

let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let space = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(data: &pixels, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    print("could not make a bitmap context")
    exit(2)
}
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    // A `CGBitmapContext`'s first byte row is the image's TOP row, so y indexes top-down directly.
    let index = (y * width + x) * 4
    return (Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]))
}

print("image \(width)x\(height), band y=\(y0)…\(y1) x=\(x0)…\(x1), scale \(scale)")
let background = rgb(x0, y0)
print("background at (\(x0),\(y0)) = rgb\(background)  ->  measured in points/px")

func isInk(_ x: Int, _ y: Int) -> Bool {
    let (r, g, b) = rgb(x, y)
    let distance = abs(r - background.0) + abs(g - background.1) + abs(b - background.2)
    return distance > 60
}

var runs: [(start: Int, end: Int, minY: Int, maxY: Int)] = []
var runStart: Int?
var runMinY = Int.max, runMaxY = Int.min
for x in x0...min(x1, width - 1) {
    var found = false
    var columnMinY = Int.max, columnMaxY = Int.min
    for y in y0...min(y1, height - 1) where isInk(x, y) {
        found = true
        columnMinY = min(columnMinY, y)
        columnMaxY = max(columnMaxY, y)
    }
    if found {
        if runStart == nil { runStart = x }
        runMinY = min(runMinY, columnMinY)
        runMaxY = max(runMaxY, columnMaxY)
    } else if let start = runStart {
        runs.append((start, x - 1, runMinY, runMaxY))
        runStart = nil
        runMinY = Int.max
        runMaxY = Int.min
    }
}
if let start = runStart { runs.append((start, min(x1, width - 1), runMinY, runMaxY)) }

print("runs: \(runs.count)")
for (index, run) in runs.enumerated() {
    let widthPt = Double(run.end - run.start + 1) / scale
    let heightPt = Double(run.maxY - run.minY + 1) / scale
    print(String(format: "  run %d: x %d…%d  (%.1f pt wide, %.1f pt tall)  y %d…%d",
                 index, run.start, run.end, widthPt, heightPt, run.minY, run.maxY))
}
for index in 1..<max(runs.count, 1) {
    let gap = Double(runs[index].start - runs[index - 1].end - 1) / scale
    print(String(format: "  gap %d→%d: %.1f pt", index - 1, index, gap))
}
if let first = runs.first, let last = runs.last {
    print(String(format: "  first run starts at x=%.1f pt from the crop's left edge",
                 Double(first.start - x0) / scale))
    print(String(format: "  last run ends at x=%.1f pt; distance to image right edge %.1f pt",
                 Double(last.end) / scale, Double(width - 1 - last.end) / scale))
}
