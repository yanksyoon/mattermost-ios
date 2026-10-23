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

    // MARK: Navigation policy (the SSO path)

    /// SSO providers finish by redirecting to a non-web scheme, or by opening the IdP in a popup.
    /// Both must be classified at the policy layer, otherwise the flow stalls on a blank page
    /// after the user authenticates.
    func testWebSchemesLoadInTheWebView() {
        for raw in ["https://community.mattermost.com/login", "http://localhost:8065/",
                    "about:blank", "data:text/html,hi", "blob:https://chat.example/1",
                    "javascript:void(0)"] {
            XCTAssertEqual(WebViewContainer.WebNavigationPolicy.decision(for: URL(string: raw)), .load,
                           "\(raw) is a web navigation and must load")
        }
    }

    func testNonWebSchemesAreHandedToTheApp() {
        for raw in ["mattermost://chat.example/landing", "msauth://com.example.app/callback",
                    "com.okta.example://callback", "chrome://settings"] {
            XCTAssertEqual(WebViewContainer.WebNavigationPolicy.decision(for: URL(string: raw)), .handOff,
                           "\(raw) cannot be loaded by WKWebView and must be handed to the app")
        }
    }

    func testMissingURLLoadsRatherThanBlocking() {
        XCTAssertEqual(WebViewContainer.WebNavigationPolicy.decision(for: nil), .load,
                       "a navigation without a URL must not be swallowed")
    }

    // MARK: Certificate-challenge scoping (the blank-SSO-page bug)

    /// The trust bag and the certificate sheet exist for the user's own server. A public
    /// identity provider must never be routed through them.
    func testCertChallengeFromConfiguredServerUsesTheTrustBag() {
        XCTAssertEqual(
            WebViewContainer.CertChallengePolicy.scope(challengeHost: "chat.canonical.com",
                                                      serverHost: "chat.canonical.com"),
            .serverOrigin)
        XCTAssertEqual(
            WebViewContainer.CertChallengePolicy.scope(challengeHost: "CHAT.Canonical.COM",
                                                      serverHost: "chat.canonical.com"),
            .serverOrigin,
            "host comparison must be case-insensitive, DNS is")
    }

    func testCertChallengeFromIdentityProviderIsThirdParty() {
        XCTAssertEqual(
            WebViewContainer.CertChallengePolicy.scope(challengeHost: "login.ubuntu.com",
                                                      serverHost: "chat.canonical.com"),
            .thirdParty)
        XCTAssertEqual(
            WebViewContainer.CertChallengePolicy.scope(challengeHost: "static.chat.canonical.com",
                                                      serverHost: "chat.canonical.com"),
            .thirdParty,
            "a sibling subdomain is a different origin with its own certificate")
        XCTAssertEqual(
            WebViewContainer.CertChallengePolicy.scope(challengeHost: "okta.com", serverHost: nil),
            .thirdParty,
            "no configured host means nothing can be scoped to the server")
        XCTAssertEqual(
            WebViewContainer.CertChallengePolicy.scope(challengeHost: "anything", serverHost: ""),
            .thirdParty)
    }
}
