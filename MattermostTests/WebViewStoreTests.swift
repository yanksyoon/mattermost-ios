import XCTest
import WebKit
@testable import Mattermost

@MainActor
final class WebViewStoreTests: XCTestCase {

    /// The document (File 4) pins the Phase-0 WebView configuration: inline media playback ON,
    /// no mediaTypesRequiringUserActionForPlayback. These two are load-bearing defaults.
    func testConfigurationAllowsInlinePlaybackAndAutoplay() {
        let store = WebViewStore()
        XCTAssertTrue(store.configuration.allowsInlineMediaPlayback, "voice/video clips must play inline")
        XCTAssertEqual(
            store.configuration.mediaTypesRequiringUserActionForPlayback,
            [],
            "no user-gesture requirement so media plays as the web app expects"
        )
    }

    func testStoreOwnsASingleReusableWebView() {
        let store = WebViewStore()
        XCTAssertNotNil(store.webView)
        // First access must not create a second instance (identity stability for SwiftUI).
        XCTAssertTrue(store.webView === store.webView)
    }

    func testLoadClearsErrorAndBeginsNavigation() {
        let store = WebViewStore()
        let url = URL(string: "https://community.mattermost.com")!
        // Prime an error to prove load() clears it.
        store.pageError = NSError(domain: "test", code: 0)
        // Load is fire-and-forget: this must not throw and must clear the stale error.
        store.load(url)
        XCTAssertNil(store.pageError)
    }

    func testInitialStateIsEmpty() {
        let store = WebViewStore()
        XCTAssertEqual(store.progress, 0)
        XCTAssertNil(store.title)
        XCTAssertNil(store.url)
        XCTAssertNil(store.pageError)
    }

    /// The server must serve the *web app*, not the mobile "view in app / view in browser"
    /// landing page it returns for iOS UAs — so the shell declares a desktop/Electron UA,
    /// exactly as the desktop client does.
    func testUserAgentMirrorsDesktopShell() {
        let store = WebViewStore()
        guard let userAgent = store.webView.customUserAgent else {
            return XCTFail("shell must pin a custom user agent")
        }
        XCTAssertTrue(userAgent.contains("Mattermost/"), "UA should identify the Mattermost shell")
        XCTAssertTrue(userAgent.contains("Electron/"), "UA should mirror the desktop Electron shell")
        XCTAssertFalse(userAgent.contains("iPhone"), "an iOS UA gets the mobile-app interstitial")
    }
}