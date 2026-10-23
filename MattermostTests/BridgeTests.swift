import XCTest
import WebKit
@testable import Mattermost

@MainActor
final class BridgeTests: XCTestCase {

    // MARK: Message-name registry (parity: communication.ts)

    /// The names must keep desktop's exact strings so the web app + preload talk on the same
    /// channels (parity `common/communication.ts`).
    func testMessageNamesMirrorDesktopCommunication() {
        XCTAssertEqual(BridgeMessage.notifyMention, "notify_mention")
        XCTAssertEqual(BridgeMessage.unreadsAndMentions, "unreads-and-mentions")
        XCTAssertEqual(BridgeMessage.sessionExpired, "session_expired")
        XCTAssertEqual(BridgeMessage.reactAppInitialized, "react-app-initialized")
        XCTAssertEqual(BridgeMessage.browserHistoryPush, "browser-history-push")
        XCTAssertEqual(BridgeMessage.requestBrowserHistoryStatus, "request-browser-history-status")
        XCTAssertEqual(BridgeMessage.history, "history")
        XCTAssertEqual(BridgeMessage.getAppInfo, "get-app-info")
    }

    /// Only a single native handler is ever registered — the whole JS↔native bridge flows
    /// through one channel (parity: desktop's one `contextBridge.exposeInMainWorld`).
    func testSingleHandlerName() {
        XCTAssertEqual(Bridge.handlerName, "mattermostBridge")
        // The preload must reference that exact handler so page → native messages land.
        XCTAssertTrue(Bridge.preloadJavascript.contains("messageHandlers"))
        XCTAssertTrue(Bridge.preloadJavascript.contains(Bridge.handlerName))
    }

    /// The preload must expose ONLY the allowlisted `window.desktop` surface — never raw shell.
    func testPreloadExposesOnlyDesktopSurface() {
        let js = Bridge.preloadJavascript
        XCTAssertTrue(js.contains("window.desktop"))
        XCTAssertFalse(js.contains("evaluateJavaScript"))       // no native eval baked in
        XCTAssertFalse(js.contains("Keychain"))                  // no vault access
        XCTAssertFalse(js.contains("URLCredentialStorage"))     // no credential exposure
        XCTAssertFalse(js.contains("FileManager"))              // no filesystem juggling
    }

    // MARK: Security boundaries

    /// A frame on an unknown handler name must be dropped (boundary 1).
    func testDropsMessageOnUnknownHandler() {
        let bridge = Bridge()
        let recorder = RecordingBridge()
        bridge.delegate = recorder
        bridge.handle(frame: (name: "some-other-handler", body: ["name": "get-app-info", "body": [:]], isMainFrame: true))
        XCTAssertTrue(recorder.received.isEmpty, "unknown handler must be ignored")
    }

    /// A non-allowlisted page message must be dropped (boundary 3) even on the right handler.
    func testDropsMessageOutsideAllowlist() {
        let bridge = Bridge()
        let recorder = RecordingBridge()
        bridge.delegate = recorder
        bridge.handle(frame: (name: Bridge.handlerName, body: ["name": "open-servers-dropdown", "body": [:]], isMainFrame: true))
        XCTAssertTrue(recorder.received.isEmpty, "non-bridged message must be ignored")
    }

    /// A message from a sub-frame (isMainFrame == false) must be dropped (boundary 2).
    func testDropsSubFrameMessage() {
        let bridge = Bridge()
        let recorder = RecordingBridge()
        bridge.delegate = recorder
        bridge.handle(frame: (name: Bridge.handlerName, body: ["name": BridgeMessage.notifyMention, "body": [:]], isMainFrame: false))
        XCTAssertTrue(recorder.received.isEmpty, "sub-frame messages must never reach shell")
    }

    /// A malformed frame (no `name`) must be dropped.
    func testDropsMalformedFrame() {
        let bridge = Bridge()
        let recorder = RecordingBridge()
        bridge.delegate = recorder
        bridge.handle(frame: (name: Bridge.handlerName, body: ["body": "no name here"], isMainFrame: true))
        XCTAssertTrue(recorder.received.isEmpty)
    }

    // MARK: Routing

    /// A valid allowlisted `notify_mention` frame reaches the delegate with decoded payload.
    func testRoutesNotifyMention() {
        let bridge = Bridge()
        let recorder = RecordingBridge()
        bridge.delegate = recorder
        let body: [String: Any] = [
            "title": "You were mentioned",
            "body": "@channel hello",
            "channelId": "ch1",
            "teamId": "team1",
            "url": "https://community.mattermost.com",
            "silent": true,
            "soundName": "bing",
        ]
        bridge.handle(frame: (name: Bridge.handlerName, body: ["name": BridgeMessage.notifyMention, "body": body], isMainFrame: true))
        guard case .mention(let n)? = recorder.received.first else {
            return XCTFail("expected mention event, got \(String(describing: recorder.received.first))")
        }
        XCTAssertEqual(n.title, "You were mentioned")
        XCTAssertEqual(n.channelID, "ch1")
        XCTAssertEqual(n.serverURL, "https://community.mattermost.com")
        XCTAssertTrue(n.silent)
        XCTAssertEqual(n.soundName, "bing")
    }

    /// `unreads-and-mentions` routes isUnread/mentionCount.
    func testRoutesUnreadsAndMentions() {
        let bridge = Bridge()
        let recorder = RecordingBridge()
        bridge.delegate = recorder
        bridge.handle(frame: (name: Bridge.handlerName, body: ["name": BridgeMessage.unreadsAndMentions, "body": ["isUnread": true, "mentionCount": 3]], isMainFrame: true))
        guard case .unreads(true, 3)? = recorder.received.first else {
            return XCTFail("expected unreads event, got \(String(describing: recorder.received.first))")
        }
    }

    /// A malformed `notify_mention` (missing required fields) must be dropped, not crash.
    func testDropsMalformedMentionPayload() {
        let bridge = Bridge()
        let recorder = RecordingBridge()
        bridge.delegate = recorder
        bridge.handle(frame: (name: Bridge.handlerName, body: ["name": BridgeMessage.notifyMention, "body": ["title": "only title"]], isMainFrame: true))
        XCTAssertTrue(recorder.received.isEmpty)
    }

    // MARK: WebViewStore integration

    /// WebViewStore must install exactly one handler + the preload script on its webview's
    /// content controller (parity: preload registered once per web contents).
    func testWebViewStoreInstallsBridge() {
        let store = WebViewStore()
        let scripts = store.webView.configuration.userContentController.userScripts
        XCTAssertEqual(scripts.count, 1, "exactly one preload user script")
        XCTAssertEqual(scripts[0].source, Bridge.preloadJavascript)
        // A second webview gets its own bridge (per-server isolation).
        let storeB = WebViewStore()
        XCTAssertFalse(store.bridge === storeB.bridge)
    }

    /// The bridge must be reachable off WebViewStore (used by DeepLinkRouter to SPA-navigate).
    func testWebViewStoreExposesBridge() {
        let store = WebViewStore()
        XCTAssertNotNil(store.bridge)
        XCTAssertNil(store.bridge.delegate, "delegate attaches when the webview is mounted")
    }
}

/// Captures events the delegate receives, for assertions.
@MainActor
private final class RecordingBridge: JsBridge {
    weak var webView: WKWebView?
    var received: [Event] = []
    enum Event {
        case mention(MentionNotification)
        case unreads(Bool, Int)
        case sessionExpired(Bool)
        case reactAppInitialized
    }

    func handleNotifyMention(_ payload: MentionNotification) { received.append(.mention(payload)) }
    func handleUnreadsAndMentions(_ isUnread: Bool, mentionCount: Int) { received.append(.unreads(isUnread, mentionCount)) }
    func handleSessionExpired(_ isExpired: Bool) { received.append(.sessionExpired(isExpired)) }
    func handleReactAppInitialized() { received.append(.reactAppInitialized) }
    func handleRequestBrowserHistoryStatus(_ completion: @escaping (BrowserHistoryStatus) -> Void) {
        completion(BrowserHistoryStatus(canGoBack: false, canGoForward: false))
    }
    func pushBrowserHistory(path: String) {}
    func navigateHistory(byOffset offset: Int) {}
}