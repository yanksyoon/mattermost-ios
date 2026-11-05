// SourceScan — the source text of app files that the unit suite scans for invariants.
//
// Some invariants are properties of the *source*, not of a value: "this renderer never builds an
// HTML parser", "this file never opens a web view". Asserting them needs the file's text, and the
// obvious way to get it — `URL(fileURLWithPath: #filePath)` walking up to the checkout — is a
// wedge, not just a shortcut: this repo lives under `~/Documents`, which macOS TCC protects, and
// a test host's `open()` on a path there blocks on a consent prompt that never arrives in a
// non-interactive run. That is how the whole Mac unit lane died at
// `T56SelectionTests.testNoHTMLParserInEitherRenderer` (card t_fc31e308): `sample` of the stuck
// host showed 100% of samples in `open()`, called from `String(contentsOf:)` at the test line.
//
// So the scanned files are copied into the test bundle at build time by the "Bundle Scanned
// Sources" shell phase on the MattermostTests target (`project.pbxproj`), which writes them to
// `SourceScan/` inside `$(UNLOCALIZED_RESOURCES_FOLDER_PATH)` in the (non-TCC) derived-data
// products. The invariant keeps its teeth — it still scans the real source text of the build
// being tested, and a violation still fails — but nothing reads the checkout at run time.
//
// A missing copy is a hard failure with the path it looked at, never a silent skip: a scan that
// cannot find its input must not look like a passing invariant.

import Foundation

/// One of the app sources that the unit suite scans for a source-level invariant.
enum ScannedSource: String, CaseIterable {
    /// The block-by-block renderer. Must not parse HTML nor host a web view.
    case markdownView = "MarkdownView.swift"
    /// The selectable single-`UITextView` renderer. Same invariant.
    case markdownSelectionView = "MarkdownSelectionView.swift"

    /// A declaration that must appear in the file — so a scan of the wrong (or stale) copy fails
    /// instead of passing every "must not contain" assertion by scanning something else.
    var declaration: String {
        switch self {
        case .markdownView: return "struct MarkdownView: View"
        case .markdownSelectionView: return "struct MarkdownBodyDocument"
        }
    }

    /// The checkout-relative path, for messages only — never for reading.
    static let checkoutDirectory = "Mattermost/UI/Native/Channel/Markdown"
}

/// Reads the copies of `ScannedSource` files that the build put in the test bundle.
enum SourceScan {
    private final class BundleToken {}

    /// Subdirectory the build phase writes into the test bundle's resources.
    static let bundleDirectory = "SourceScan"

    /// Where a scanned file is expected to be in the built test bundle.
    static func url(for source: ScannedSource) throws -> URL {
        let bundle = Bundle(for: BundleToken.self)
        let root = bundle.resourceURL ?? bundle.bundleURL
        let candidate = root
            .appendingPathComponent(bundleDirectory, isDirectory: true)
            .appendingPathComponent(source.rawValue, isDirectory: false)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw SourceScanError.missing(source: source, expected: candidate.path,
                                          bundlePath: bundle.bundlePath)
        }
        return candidate
    }

    /// The text of a scanned file, as the build saw it.
    static func text(of source: ScannedSource) throws -> String {
        let text = try String(contentsOf: url(for: source), encoding: .utf8)
        // An empty or truncated copy would let every "must not contain" assertion pass for the
        // wrong reason, so the copy is checked to look like Swift before it is scanned.
        guard text.contains("import "), text.count > 200 else {
            throw SourceScanError.unreadable(source: source, bytes: text.utf8.count)
        }
        return text
    }

    /// The text of a scanned file with its comments removed, one trimmed code line per element.
    ///
    /// Comments are allowed to *discuss* the forbidden API (the renderer headers name the HTML
    /// initialiser they do not call); only executable lines are scanned.
    static func executableLines(of source: ScannedSource) throws -> [String] {
        try text(of: source)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
    }
}

enum SourceScanError: Error, CustomStringConvertible {
    case missing(source: ScannedSource, expected: String, bundlePath: String)
    case unreadable(source: ScannedSource, bytes: Int)

    var description: String {
        switch self {
        case let .missing(source, expected, bundlePath):
            return """
            \(source.rawValue) is not in the test bundle (looked for \(expected) in \
            \(bundlePath)). The "Bundle Scanned Sources" build phase on the MattermostTests target \
            copies \(ScannedSource.checkoutDirectory)/\(source.rawValue) there. This is a hard \
            failure on purpose: without the copy the invariant would pass without scanning \
            anything. Rebuild the test target rather than restoring a run-time read of the \
            checkout — from ~/Documents that read blocks on a TCC prompt and wedges the runner \
            (card t_fc31e308).
            """
        case let .unreadable(source, bytes):
            return """
            \(source.rawValue) was copied into the test bundle but is not scannable source \
            (\(bytes) bytes, no `import `). A truncated copy must not pass a "must not contain" \
            scan by accident — check the "Bundle Scanned Sources" build phase output.
            """
        }
    }
}
