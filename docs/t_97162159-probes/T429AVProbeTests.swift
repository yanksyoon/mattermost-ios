// t_97162159 (QA probe, NOT part of the shipped change): pins what `.profile` resolves to under the
// **exact** launch arguments the live T429 suite passes, so the claim "the live suite launches without
// `-surfaceMode profile=native` and `.profile` really is web there" is a measurement instead of a
// reading of the argument list.
//
// Attack 2 of the validation card. Delete before handing the tree back.

import XCTest
@testable import Mattermost

@MainActor
final class T429AVProbeTests: XCTestCase {

    /// Copied verbatim from `MattermostUITests/T429ProfileTapUITests.launchApp()`.
    private let liveLaunchArguments = ["-uiTestResetPersistedState",
                                       "-uiTestForgetSession", "http://127.0.0.1:8065",
                                       "-uiTestSeedServer", "http://127.0.0.1:8065",
                                       "-uiTestSeedServerName", "Local Mattermost",
                                       "-surfaceMode", "shell=native",
                                       "-surfaceMode", "auth=native",
                                       "-surfaceMode", "sidebar=native",
                                       "-uiTestLogLevel", "error",
                                       "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "T429AVProbeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func resolver(_ arguments: [String]) -> SurfaceModeResolver {
        SurfaceModeResolver(preferences: AppPreferences(defaults: defaults), arguments: arguments)
    }

    func testTheLiveSuiteLaunchArgumentsResolveProfileWeb() {
        let r = resolver(liveLaunchArguments)
        var dump = ""
        for surface in Surface.allCases {
            dump += "\(surface.rawValue)=\(r.resolvedMode(for: surface).rawValue) "
        }
        print("PROBE-T429AV launch-arguments resolution: \(dump)")

        XCTAssertEqual(r.resolvedMode(for: SurfaceDefaults.paneHostSurface), .native,
                       "the pane host must be native in the live suite's launch")
        XCTAssertEqual(r.resolvedMode(for: .profile), .web,
                       "the live suite must launch in the state that produced the report: `.profile` web")
        XCTAssertTrue(ProfilePopoverPolicy.offersAuthorTap(
                        paneHost: r.resolvedMode(for: SurfaceDefaults.paneHostSurface),
                        profileSurface: r.resolvedMode(for: .profile)))
    }

    func testTheT41LaunchArgumentsResolveProfileNative() {
        var arguments = liveLaunchArguments
        arguments += ["-surfaceMode", "profile=native"]
        let r = resolver(arguments)
        XCTAssertEqual(r.resolvedMode(for: .profile), .native,
                       "T41's suite passes profile=native — the flag that hid the defect")
    }
}
