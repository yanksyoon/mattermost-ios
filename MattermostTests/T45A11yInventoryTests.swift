import XCTest
@testable import Mattermost

/// T45 — the pass, pinned against the inventory manifest.
///
/// The card's criteria are properties of *every screen at once*: "no user text in
/// a frozen point size", "no icon-only button without a label", "no animation that
/// ignores Reduce Motion". A view test can only speak about one view, so the pin
/// is a scan of the whole tree — `scripts/t45_a11y_inventory.py` — and its result
/// is checked in as `Fixtures/t45-a11y-inventory.json`.
///
/// Why a manifest and not a scan at test time: the sources live under
/// `~/Documents`, which macOS protects with TCC. A Catalyst test host that walks
/// them blocks in `open()` waiting for a consent dialog nobody can click on a
/// headless run — measured: the first version of this file hung for six minutes
/// in `DirEnumRead` on `testAccessibilityIdentifiersNeverFallBelowTheShippedCount`.
/// So the scan runs on the host, where the shell already has consent, and the test
/// asserts the manifest it produced. The honest limitation is stated in
/// `docs/t45-a11y-build-note.md` §3: a new violation is caught when the scan is
/// re-run (`--check` exits non-zero), not by this test until the manifest is
/// regenerated.
final class T45A11yInventoryTests: XCTestCase {

    private struct Manifest {
        let fontSites: Int
        let unexplained: [String]
        let unowned: [String]
        let exemptions: [String]
        let staleExemptions: [String]
        let glyphSites: [[String: Any]]
        let scaledFontSites: Int
        let scaledSymbolSites: Int
        let scaledColumnSites: Int
        let variableLineLimits: Int
        let convertedBySurface: [String: Int]
        let lineLimitOne: [[String: Any]]
        let lineLimitUnexplained: [String]
        let lineLimitExemptions: [String]
        let staleLineLimitExemptions: [String]
        let identifiers: Int
        let labels: Int
        let hints: Int
        let unnamedButtons: [String]
        let reduceMotionUses: Int
        let contrastUses: Int
        let animationSites: [[String: Any]]
        let unguardedAnimations: [String]
        let bySurface: [String: Int]
        let head: String
    }

    private func loadManifest() throws -> Manifest {
        let bundle = Bundle(for: BundleToken.self)
        let url = try XCTUnwrap(bundle.url(forResource: "t45-a11y-inventory", withExtension: "json"),
                                "the T45 inventory manifest is not in the test bundle — "
                                + "run `python3 scripts/t45_a11y_inventory.py --check "
                                + "--emit-manifest MattermostTests/Fixtures/t45-a11y-inventory.json`")
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        func strings(_ key: String) -> [String] {
            (json[key] as? [Any] ?? []).map { item in
                if let text = item as? String { return text }
                if let dictionary = item as? [String: Any] {
                    let file = dictionary["file"] as? String ?? "?"
                    let line = dictionary["line"] as? Int ?? 0
                    return "\(file):\(line)"
                }
                return "\(item)"
            }
        }
        func objects(_ key: String) -> [[String: Any]] {
            (json[key] as? [[String: Any]]) ?? []
        }
        func int(_ key: String) -> Int { (json[key] as? Int) ?? -1 }

        return Manifest(
            fontSites: int("font_sites"),
            unexplained: strings("font_sites_unexplained"),
            unowned: strings("font_sites_unowned"),
            exemptions: ((json["exemptions"] as? [[String: Any]]) ?? []).map { exemption in
                let file = exemption["file"] as? String ?? "?"
                let reason = exemption["reason"] as? String ?? "?"
                return "\(file) :: \(reason)"
            },
            staleExemptions: strings("stale_exemptions"),
            glyphSites: objects("font_sites_glyph"),
            scaledFontSites: int("scaled_font_sites"),
            scaledSymbolSites: int("scaled_symbol_sites"),
            scaledColumnSites: int("scaled_column_sites"),
            variableLineLimits: int("variable_line_limit_sites"),
            convertedBySurface: (json["converted_by_surface"] as? [String: Int]) ?? [:],
            lineLimitOne: objects("line_limit_one"),
            lineLimitUnexplained: strings("line_limit_one_unexplained"),
            lineLimitExemptions: ((json["line_limit_exemptions"] as? [[String: Any]]) ?? []).map { exemption in
                let file = exemption["file"] as? String ?? "?"
                let reason = exemption["reason"] as? String ?? "?"
                return "\(file) :: \(reason)"
            },
            staleLineLimitExemptions: strings("stale_line_limit_exemptions"),
            identifiers: int("accessibility_identifiers"),
            labels: int("accessibility_labels"),
            hints: int("accessibility_hints"),
            unnamedButtons: strings("unnamed_buttons"),
            reduceMotionUses: int("reduce_motion_uses"),
            contrastUses: int("contrast_uses"),
            animationSites: objects("animation_sites"),
            unguardedAnimations: strings("unguarded_animations"),
            bySurface: (json["font_sites_by_surface"] as? [String: Int]) ?? [:],
            head: (json["head"] as? String) ?? ""
        )
    }

    // MARK: - The measurement is what it claims to be

    /// The manifest is a real scan of a real commit, not an empty file that makes
    /// every assertion below trivially true.
    func testManifestIsAProvenanceBearingScan() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(manifest.head.count, 40, "the manifest has no source commit")
        XCTAssertTrue(manifest.head.allSatisfy(\.isHexDigit), "head is not a sha")
        XCTAssertGreaterThan(manifest.fontSites, 0,
                             "a scan that found no font sites did not run")
        XCTAssertGreaterThan(manifest.glyphSites.count, 10,
                             "the glyph allow-list is missing — the scan did not classify")
        XCTAssertEqual(manifest.exemptions.count, 6,
                       "the exemption list changed shape — the pass allows six fixed sites "
                       + "and every one must carry a reason:\n" + manifest.exemptions.joined(separator: "\n"))
        XCTAssertTrue(Set(manifest.bySurface.keys).isSubset(of: ["channel", "composer", "settings", "sidebar", "thread"]),
                      "a font site was found outside the measured surfaces: \(manifest.bySurface.keys)")
        // Every surface the card names has to show the conversion, not just be free
        // of offenders — a surface with no conversions at all was not reached.
        for surface in ["sidebar", "channel", "composer", "thread"] {
            XCTAssertGreaterThanOrEqual(manifest.convertedBySurface[surface] ?? 0, 1,
                                        "\(surface) has no Dynamic Type conversion — "
                                        + "the pass did not reach it (converted: \(manifest.convertedBySurface))")
        }
        // Settings is the exception, and it is an exception worth stating rather
        // than hiding: `Profile/` already set its text in semantic styles before
        // this pass, and its only two fixed sites are avatar initials (exempt). The
        // pin for settings is therefore the global "no unexplained text" test and
        // the AX3 screenshot, not a conversion count. If a conversion appears here,
        // someone added a fixed size to settings and this number should be updated
        // deliberately.
        XCTAssertEqual(manifest.convertedBySurface["settings"] ?? -1, 0,
                       "settings gained a Dynamic Type conversion — say which site and why")
    }

    // MARK: - Fonts

    /// No *user text* is left in a frozen point size.
    func testNoUserTextIsSetInAFixedPointSize() throws {
        let manifest = try loadManifest()
        XCTAssertTrue(manifest.unexplained.isEmpty,
                      "user text in a fixed point size:\n" + manifest.unexplained.joined(separator: "\n"))
    }

    /// Nothing outside T45's ownership was edited to make the number look good.
    func testNoUnownedFileWasUsedToMakeTheCountPass() throws {
        let manifest = try loadManifest()
        XCTAssertTrue(manifest.unowned.isEmpty,
                      "fixed-point text in files T45 does not own:\n" + manifest.unowned.joined(separator: "\n"))
    }

    /// Every exemption still names a site that exists. An exemption that has gone
    /// stale silently re-arms the bug it was excusing.
    func testNoExemptionIsStale() throws {
        let manifest = try loadManifest()
        XCTAssertTrue(manifest.staleExemptions.isEmpty,
                      "stale exemptions:\n" + manifest.staleExemptions.joined(separator: "\n"))
    }

    /// The conversions are present in the numbers the pass claims, not merely
    /// absent from the offender list.
    func testTheConversionIsPresentNotMerelyAbsent() throws {
        let manifest = try loadManifest()
        XCTAssertGreaterThanOrEqual(manifest.scaledFontSites, 45,
                                    "Dynamic Type text conversions are missing")
        XCTAssertGreaterThanOrEqual(manifest.scaledSymbolSites, 20,
                                    "scaled standalone glyphs are missing")
        XCTAssertGreaterThanOrEqual(manifest.scaledColumnSites, 3,
                                    "scaled text columns are missing")
        XCTAssertGreaterThanOrEqual(manifest.variableLineLimits, 15,
                                    "variable line limits are missing")
    }

    /// The only one-line caps left are the documented ones — a count badge and an
    /// avatar initial in a fixed rail, neither of which can truncate (the count is
    /// drawn `99+`, the initial has a scale factor).
    func testBareOneLineLimitsAreOnlyTheDocumentedOnes() throws {
        let manifest = try loadManifest()
        let files = Set(manifest.lineLimitOne.compactMap { $0["file"] as? String })
        XCTAssertTrue(files.isSubset(of: ["Mattermost/UI/Native/Sidebar/TeamSidebarView.swift",
                                         "Mattermost/UI/DownloadsView.swift"]),
                      "an unguarded .lineLimit(1) came back in: \(files.sorted())")
        // T45-AV-R §6: the count was printed and never asserted, so a fourth cap shipped
        // green. The scan now classifies every site; the manifest records the verdict.
        XCTAssertTrue(manifest.lineLimitUnexplained.isEmpty,
                      "a .lineLimit(1) outside the documented three:\n"
                      + manifest.lineLimitUnexplained.joined(separator: "\n"))
        XCTAssertEqual(manifest.lineLimitExemptions.count, 3,
                       "the exemption list changed shape — the pass allows exactly three caps "
                       + "and every one must carry a reason:\n"
                       + manifest.lineLimitExemptions.joined(separator: "\n"))
        XCTAssertTrue(manifest.staleLineLimitExemptions.isEmpty,
                      "a .lineLimit(1) exemption no longer names a site:\n"
                      + manifest.staleLineLimitExemptions.joined(separator: "\n"))
    }

    // MARK: - Labels

    /// No `Button` draws a glyph and names nothing.
    ///
    /// T45-AV-R §5: the scan that feeds this assertion could not *see* the app's own button
    /// shape (`Button { … } label: { Image(…) }`) — it read the action closure and stopped
    /// there — so a probe file with exactly that shape and no label measured 0 unnamed and
    /// PASS. The scan now classifies every shape; the fixed manifest below is what this test
    /// asserts, so it catches the violation on the next regeneration.
    func testNoIconOnlyButtonIsUnnamed() throws {
        let manifest = try loadManifest()
        XCTAssertTrue(manifest.unnamedButtons.isEmpty,
                      "glyph-only buttons with no accessibilityLabel:\n"
                      + manifest.unnamedButtons.joined(separator: "\n"))
    }

    /// The identifiers the UI tests address the shell by never fall below the
    /// shipped count — this pass edits every screen, which is exactly the change
    /// that could rename a control out from under a test.
    func testAccessibilityIdentifiersNeverFallBelowTheShippedCount() throws {
        let manifest = try loadManifest()
        XCTAssertGreaterThanOrEqual(manifest.identifiers, 465,
                                    "accessibilityIdentifier count fell to \(manifest.identifiers)")
    }

    func testAccessibilityLabelsNeverFallBelowTheShippedCount() throws {
        let manifest = try loadManifest()
        XCTAssertGreaterThanOrEqual(manifest.labels, 95,
                                    "accessibilityLabel count fell to \(manifest.labels)")
        XCTAssertGreaterThanOrEqual(manifest.hints, 2,
                                    "accessibilityHint count fell to \(manifest.hints)")
    }

    // MARK: - Settings the shell must consult

    /// Every animation site reads Reduce Motion.
    ///
    /// T45-AV-R §6: this used to ask the *file* (`guarded_file`), so one read anywhere in a
    /// file vouched for every animation in it, and nothing failed on a site at all. The
    /// manifest now carries a per-statement verdict, and both are asserted.
    func testEveryAnimationSiteConsultsReduceMotion() throws {
        let manifest = try loadManifest()
        let unguarded = manifest.animationSites.filter { ($0["guarded"] as? Bool) != true }
        XCTAssertTrue(unguarded.isEmpty, "animates without reading reduce motion: \(unguarded)")
        XCTAssertTrue(manifest.unguardedAnimations.isEmpty,
                      "animation sites that do not consult Reduce Motion:\n"
                      + manifest.unguardedAnimations.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(manifest.animationSites.count, 4,
                                    "the animation scan found nothing — it is looking at the wrong tree")
    }

    /// Both settings are read in the shell — they were read nowhere before this
    /// pass.
    func testReduceMotionAndContrastAreWired() throws {
        let manifest = try loadManifest()
        XCTAssertGreaterThanOrEqual(manifest.reduceMotionUses, 4)
        XCTAssertGreaterThanOrEqual(manifest.contrastUses, 3)
    }
}

/// Stable anchor for `Bundle(for:)` in a test target with no ObjC classes.
private final class BundleToken {}
