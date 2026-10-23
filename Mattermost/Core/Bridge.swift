import Foundation
import WebKit

// MARK: - Message name registry

/// Message names exchanged between the Mattermost page and the native shell.
///
/// This is the native counterpart of desktop `src/common/communication.ts`: each constant here
/// has the *exact* string the Mattermost web app / preload uses, so the injected JS shim can
/// post and receive on the same channels as the Electron `ipcRenderer`.
///
/// Security note (the shell's real boundary): a name listed here is **not** automatically
/// reachable from arbitrary page JS. Reachability is decided by (a) which names the injected
/// preload script actually bridges, and (b) a runtime whitelist applied by `Bridge` on every
/// inbound message (see `Bridge.allowlist`). Electron-only IPC the iOS shell does not model
/// (downloads dropdown, popout windows, update flows, app menus, …) is deliberately omitted.
enum BridgeMessage {
    // Page -> native
    static let notifyMention = "notify_mention"
    static let unreadsAndMentions = "unreads-and-mentions"
    static let sessionExpired = "session_expired"
    static let reactAppInitialized = "react-app-initialized"
    static let browserHistoryPush = "browser-history-push"
    static let requestBrowserHistoryStatus = "request-browser-history-status"

    // Native -> page
    static let history = "history"

    // Application info (page -> native, response native -> page)
    static let getAppInfo = "get-app-info"
}

/// The single native handler name under which every bridge message arrives. Mirrors the
/// desktop preload's one `contextBridge` surface: a single well-named channel, nothing else is
/// registered on `WKUserContentController`.
let BridgeHandlerName = "mattermostBridge"

// MARK: - The JsBridge protocol

/// Native counterpart of the desktop *preload* surface (`src/app/preload/internalAPI.js` +
/// `externalAPI.ts`): the contract between a Mattermost web page and the shell.
///
/// Conforming NSObjects are registered as a `WKScriptMessageHandler` on the webview's
/// `WKUserContentController` under `BridgeHandlerName` and decode+dispatch every inbound frame.
/// The protocol declares each supported page→native event and the shell→page send helpers;
/// implementing types decide what the shell actually does with them.
///
/// A type is allowed to reject a message by throwing from the `canHandle` guard (e.g. the
/// message did not come from the main frame, or its body is malformed / oversized). `Bridge`
/// performs the shared validation; conformers receive already-deserialised, frame-checked
/// payloads and are responsible for the *native action* semantics.
@MainActor
protocol JsBridge: AnyObject {

    /// The webview this bridge is attached to (used for the main-frame security check and for
    /// native→page sends). Conformers that own a webview set this on install.
    var webView: WKWebView? { get set }

    /// Inbound page→native events. Each receives the deserialised payload.
    func handleNotifyMention(_ payload: MentionNotification)
    func handleUnreadsAndMentions(_ isUnread: Bool, mentionCount: Int)
    func handleSessionExpired(_ isExpired: Bool)
    func handleReactAppInitialized()
    func handleRequestBrowserHistoryStatus(_ completion: @escaping (BrowserHistoryStatus) -> Void)

    // MARK: Native -> page sends

    /// Ask the page to navigate via its SPA router (desktop `BROWSER_HISTORY_PUSH`).
    func pushBrowserHistory(path: String)
    /// Command the page to page back/forward by a history offset (desktop `HISTORY`).
    func navigateHistory(byOffset offset: Int)
}

// MARK: - Payload models

/// Browser history push/status payload (desktop `utils/url.ts` output for the navigation guard).
struct BrowserHistoryStatus: Equatable {
    /// Whether the page can go back.
    let canGoBack: Bool
    /// Whether the page can go forward.
    let canGoForward: Bool
}

/// A mention-notification request from the page (desktop `NOTIFY_MENTION` -> main/notifications).
struct MentionNotification: Equatable {
    let title: String
    let body: String
    let channelID: String
    let teamID: String
    let serverURL: String
    let silent: Bool
    let soundName: String?

    init(title: String, body: String, channelID: String, teamID: String,
         serverURL: String, silent: Bool = false, soundName: String? = nil) {
        self.title = title
        self.body = body
        self.channelID = channelID
        self.teamID = teamID
        self.serverURL = serverURL
        self.silent = silent
        self.soundName = soundName
    }
}

// MARK: - The Bridge (WKScriptMessageHandler shim + preload)

/// The single native bridge object. Native counterpart of desktop `communication.ts` (channel
/// names) + the preload: it *defines* the injected JS surface, *receives* framed messages from
/// the page, and *dispatches* them to its `JsBridge` delegate after security validation.
///
/// Data flow (mirrors Electron's `ipcRenderer`/`contextBridge`):
/// ```
///   [mattermost web app]  --postMessage(name, body)-->  [Bridge.userContentController(_:]
///                                                          -> validate frame/name/body
///                                                          -> delegate.handle*(payload)
///   [shell]  pushBrowserHistory(path)  --evaluateJavaScript-->  [page dipsatchEvent]
/// ```
///
/// Only names in `allowlist` are ever dispatched; any other name is dropped and logged, so a
/// compromised or unexpected page can never reach unreported shell capability.
final class Bridge: NSObject, WKScriptMessageHandler {

    weak var delegate: JsBridge?

    /// The message names this bridge instance will accept from the page.
    static let allowlist: Set<String> = [
        BridgeMessage.notifyMention,
        BridgeMessage.unreadsAndMentions,
        BridgeMessage.sessionExpired,
        BridgeMessage.reactAppInitialized,
        BridgeMessage.browserHistoryPush,
        BridgeMessage.requestBrowserHistoryStatus,
        BridgeMessage.getAppInfo,
    ]

    /// Max in bytes tolerated from the page per frame, mirroring the desktop URL guard's hard
    /// bounds. Defends against a malicious page exfiltrating huge bodies over the bridge.
    static let maxBodyBytes = 64 * 1024

    /// The names registered on the content controller. Holds the JS→native subscription open
    /// for the lifetime of the webview (there is no page-unload tearing down mid-scene).
    static let handlerName = BridgeHandlerName

    private let scriptMessageNames: Set<String>

    /// Build a bridge for one webview's content controller.
    /// - Parameter messageNames: inbound message names to *bridge to the page* (i.e. what the
    ///   injected shim exposes). Defaults to `allowlist` (the whole safe surface). Callers that
    ///   want a tighter surface (e.g. a locked-down login-only webview) pass a subset.
    init(messageNames: Set<String> = Bridge.allowlist) {
        self.scriptMessageNames = messageNames
        super.init()
    }

    /// Injected at document-start on every navigation. Mirrors the desktop preload exactly in
    /// spirit: expose *only* the shell channels to `window.desktop`, never raw shell.
    static let preloadJavascript: String = """
    (() => {
        if (window.__mattermostBridgeInstalled) { return; }
        window.__mattermostBridgeInstalled = true;
        const target = window.webkit?.messageHandlers?.\(BridgeHandlerName);
        if (!target) { return; }
        const post = (name, body) => {
            try { target.postMessage({ name, body }); } catch (_) {}
        };
        window.desktop = Object.freeze({
            notifyMention: (title, body, channelId, teamId, url, silent, soundName) =>
                post("\(BridgeMessage.notifyMention)", { title, body, channelId, teamId, url, silent, soundName }),
            setUnreadsAndMentions: (isUnread, mentionCount) =>
                post("\(BridgeMessage.unreadsAndMentions)", { isUnread, mentionCount }),
            setSessionExpired: (isExpired) =>
                post("\(BridgeMessage.sessionExpired)", { isExpired }),
            reactAppInitialized: () =>
                post("\(BridgeMessage.reactAppInitialized)", {}),
            requestBrowserHistoryStatus: () =>
                post("\(BridgeMessage.requestBrowserHistoryStatus)", {}),
            getAppInfo: () =>
                post("\(BridgeMessage.getAppInfo)", {}),
            sendBrowserHistoryPush: (path) =>
                post("\(BridgeMessage.browserHistoryPush)", { path }),
        });
        // SSO entry guard. The web app routes /login/sso/* client-side and renders only the
        // page header with a "Back" link: an empty screen with no identity-provider redirect,
        // because the redirect is the server's answer to a real document request. Forcing a
        // full load for these links is what makes "Sign in with ..." reach the IdP.
        document.addEventListener('click', (event) => {
            let el = event.target;
            while (el && el.tagName !== 'A') { el = el.parentElement; }
            if (!el) { return; }
            const href = el.getAttribute('href') || '';
            if (href.indexOf('/login/sso/') === -1) { return; }
            event.preventDefault();
            event.stopPropagation();
            window.location.href = href;
        }, true);
        window.addEventListener('mattermost-bridge', (event) => {
            const detail = (event.detail || {});
            const name = detail.name;
            const payload = (detail.payload || {});
            if (name === "\(BridgeMessage.history)") {
                history.go(payload.offset || 0);
            } else if (name === "\(BridgeMessage.browserHistoryPush)") {
                const url = (payload.path || '').startsWith('/') ? payload.path : '/' + payload.path;
                try {
                    // Avoid a hard navigation when the SPA can handle it.
                    window.dispatchEvent(new CustomEvent('mattermost-desktop-browser-history', { detail: { path: url } }));
                } catch (_) {}
            }
        });
    })();
    """

    // MARK: WKScriptMessageHandler

    @MainActor
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        // Main-frame check then feed the shared frame-processing path (also exercised in tests).
        guard message.frameInfo.isMainFrame else {
            Logger.debug("Bridge", "ignoring message from non-main frame")
            return
        }
        handle(frame: (name: message.name, body: message.body, isMainFrame: true))
    }

    /// The whole security + dispatch pipeline for one inbound frame, extracted so it can be
    /// tested without constructing a real `WKScriptMessage`.
    ///
    /// - Parameters:
    ///   - frame: the incoming frame's handler name, raw body and main-frame flag.
    @MainActor
    func handle(frame: (name: String, body: Any, isMainFrame: Bool)) {
        // Hard security boundary 1: only messages on our single channel are ever processed.
        guard frame.name == Bridge.handlerName else {
            Logger.debug("Bridge", "ignoring message on unknown handler \(frame.name)")
            return
        }
        // Hard security boundary 2: only messages from the top frame are treated as page↔shell
        // signals. A sub-frame (ad, plugin iframe) must never reach shell capability.
        guard frame.isMainFrame else {
            Logger.debug("Bridge", "ignoring message from non-main frame")
            return
        }

        guard let body = frame.body as? [String: Any],
              let name = body["name"] as? String else {
            Logger.debug("Bridge", "malformed bridge frame ignored")
            return
        }

        // Hard security boundary 3: only allowlisted names are dispatched — the proxy that a
        // page can actually reach. Anything else is dropped before validation is even attempted.
        guard Self.allowlist.contains(name) else {
            Logger.debug("Bridge", "bridge message outside allowlist ignored: \(name)")
            return
        }

        // T19a: breadcrumb around bridge events (desktop Sentry breadcrumbs on IPC). Buffered
        // always, forwarded to Sentry only when the SDK is linked.
        SentryService.shared.addBreadcrumb(category: "bridge",
                                           message: "received \(name)",
                                           level: "info")

        let payload = (body["body"] as? [String: Any]) ?? [:]

        guard let delegate else {
            Logger.debug("Bridge", "no JsBridge delegate installed")
            validateAppInfo(name, payload: payload)
            return
        }
        dispatch(name, payload: payload, to: delegate)
    }

    /// Route an allowlisted message to the conforming method, with minimal per-name validation.
    @MainActor
    private func dispatch(_ name: String, payload: [String: Any], to delegate: JsBridge) {
        switch name {
        case BridgeMessage.notifyMention:
            guard let notification = decodedNotification(from: payload) else {
                Logger.debug("Bridge", "notify_mention payload malformed")
                return
            }
            delegate.handleNotifyMention(notification)

        case BridgeMessage.unreadsAndMentions:
            let isUnread = (payload["isUnread"] as? Bool) ?? false
            let count = (payload["mentionCount"] as? Int) ?? 0
            delegate.handleUnreadsAndMentions(isUnread, mentionCount: count)

        case BridgeMessage.sessionExpired:
            delegate.handleSessionExpired((payload["isExpired"] as? Bool) ?? false)

        case BridgeMessage.reactAppInitialized:
            delegate.handleReactAppInitialized()

        case BridgeMessage.requestBrowserHistoryStatus:
            delegate.handleRequestBrowserHistoryStatus { [weak self] status in
                DispatchQueue.main.async { self?.sendBrowserHistoryStatus(status) }
            }

        default:
            // get-app-info is answered by the shell, not a page signal.
            validateAppInfo(name, payload: payload)
        }
    }

    /// Decode a `notify_mention` payload with strict optional fields.
    private func decodedNotification(from payload: [String: Any]) -> MentionNotification? {
        guard let title = payload["title"] as? String,
              let body = payload["body"] as? String,
              let channelID = payload["channelId"] as? String,
              let teamID = payload["teamId"] as? String,
              let serverURL = payload["url"] as? String else {
            return nil
        }
        return MentionNotification(
            title: title,
            body: body,
            channelID: channelID,
            teamID: teamID,
            serverURL: serverURL,
            silent: (payload["silent"] as? Bool) ?? false,
            soundName: payload["soundName"] as? String
        )
    }

    /// `get-app-info` (and any other unmatched *allowed* name) is answered with the shell's
    /// version identifiers; nothing else is exposed.
    @MainActor
    private func validateAppInfo(_ name: String, payload: [String: Any]) {
        guard name == BridgeMessage.getAppInfo else { return }
        let info: [String: Any] = [
            "name": "Mattermost iOS",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
            "platform": "ios",
        ]
        sendRawChannel(name: BridgeMessage.getAppInfo, payload: info)
    }

    // MARK: Native -> page sends

    /// Send a named frame back into the page. This is the direct send path (the page's
    /// `mattermost-bridge` listener handles `history` and `browser-history-push`).
    @MainActor
    func sendRawChannel(name: String, payload: [String: Any]) {
        guard let webView = delegate?.webView else { return }
        let data: [String: Any] = ["name": name, "body": payload]
        guard let json = try? JSONSerialization.data(withJSONObject: data),
              let script = String(data: json, encoding: .utf8) else { return }
        let safeScript = script.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let expression = "window.dispatchEvent(new CustomEvent('mattermost-bridge', {detail: JSON.parse(\"\(safeScript)\")}));"
        webView.evaluateJavaScript(expression)
    }

    @MainActor
    func sendBrowserHistoryStatus(_ status: BrowserHistoryStatus) {
        sendRawChannel(name: BridgeMessage.requestBrowserHistoryStatus, payload: [
            "canGoBack": status.canGoBack,
            "canGoForward": status.canGoForward,
        ])
    }
}