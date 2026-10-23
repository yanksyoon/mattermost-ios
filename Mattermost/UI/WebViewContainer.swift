import SwiftUI
import WebKit
import Combine
import Foundation
import Security

/// The SwiftUI-wrapped `WKWebView` host — native counterpart of desktop `BaseWindow.myView`
/// / `MattermostWebContentsView`. Parity row: `BaseWindow`, `MattermostWebContentsView` ->
/// `WebViewContainer`. Status: native, P0.2/P1.2.
///
/// Renders the single `WKWebView` owned by `WebViewStore`. The `Coordinator` acts as
/// `WKNavigationDelegate` + `WKUIDelegate` so challenge/redirect/JS-dialog policy lives in
/// native code, not in page JS (security boundary).
struct WebViewContainer: UIViewRepresentable {
    let store: WebViewStore
    /// The server this webview belongs to (drives SessionStore / NotificationWorker tagging).
    let serverID: UUID

    /// The app-wide mention/unread accounting (desktop `AppState`), injected from the environment.
    @EnvironmentObject var sessionStore: SessionStore
    /// The app-wide local-notification scheduler (desktop `main/notifications`), injected from
    /// the environment.
    @EnvironmentObject var notificationWorker: NotificationWorker

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, serverID: serverID,
                    sessionStore: sessionStore, notificationWorker: notificationWorker)
    }

    func makeUIView(context: Context) -> WKWebView {
        // WebViewStore owns the instance; we only attach delegates and add it to the hierarchy.
        let webView = store.webView
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // No per-frame mutation needed — the store drives loading imperatively.
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
        coordinator.store.webView.stopLoading()
    }

    // MARK: Coordinator — the native policy surface

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, JsBridge {
        let store: WebViewStore
        /// The server this bridge belongs to (tags every inbound shell event).
        let serverID: UUID

        /// The webview this bridge is attached to (JsBridge requirement).
        weak var webView: WKWebView?

        /// The per-server trust bag consulted on TLS challenges (Phase 2 `CertTrust`).
        let certTrust: CertTrust

        /// Theme sync for this webview (Phase 2 `ThemeSync`).
        let themeSync: ThemeSync

        /// Mention/unread accounting (desktop `AppState`); receives unreads/expired bridge events.
        let sessionStore: SessionStore
        /// Local-notification scheduler (desktop `main/notifications`); receives mention events.
        let notificationWorker: NotificationWorker

        init(store: WebViewStore,
             serverID: UUID,
             sessionStore: SessionStore,
             notificationWorker: NotificationWorker,
             certTrust: CertTrust = CertTrust(),
             themeSync: ThemeSync = ThemeSync()) {
            self.store = store
            self.serverID = serverID
            self.sessionStore = sessionStore
            self.notificationWorker = notificationWorker
            self.certTrust = certTrust
            self.themeSync = themeSync
            super.init()
            // Route inbound page→native bridge messages to this coordinator (the page-event sink).
            store.bridge.delegate = self
            // Own certificate decisions for this webview: record into the trust bag, then
            // re-drive navigation so the next challenge auto-accepts (or hard-rejects).
            store.certificateDecisionHandler = { [weak self] prompt, trust, dontTrustAgain in
                self?.resolveCertificateDecision(prompt, trust: trust, dontTrustAgain: dontTrustAgain)
            }
        }

        /// The user answered a `CertPromptSheet`. Mirrors the desktop certificate modal's
        /// confirm/cancel: `trust` -> `certificateStore.add` and reload; `dontTrustAgain` ->
        /// record the refusal so future challenges are hard-rejected without re-prompting.
        /// Cancel (both false) just dismisses and leaves the current error state.
        private func resolveCertificateDecision(_ prompt: CertificatePrompt,
                                                trust: Bool,
                                                dontTrustAgain: Bool) {
            do {
                if trust || dontTrustAgain {
                    try certTrust.add(prompt.origin, certificate: prompt.certificate,
                                      dontTrust: dontTrustAgain)
                    Logger.info("CertPrompt", "recorded certificate decision for \(prompt.origin.absoluteString) (trust: \(trust), dontTrustAgain: \(dontTrustAgain))")
                }
                if trust || dontTrustAgain {
                    store.retry()
                }
            } catch {
                Logger.error("CertPrompt", "failed to record certificate decision: \(error.localizedDescription)")
            }
        }

        // MARK: JsBridge

        func handleNotifyMention(_ payload: MentionNotification) {
            Logger.info("Bridge", "mention for \(payload.serverURL): \(payload.body)")
            Task { _ = await notificationWorker.presentMention(payload, fromServerID: serverID) }
        }

        func handleUnreadsAndMentions(_ isUnread: Bool, mentionCount: Int) {
            sessionStore.updateMentions(serverID: serverID, mentionCount: mentionCount, isUnread: isUnread)
        }

        func handleSessionExpired(_ isExpired: Bool) {
            sessionStore.updateExpired(serverID: serverID, isExpired: isExpired)
        }

        func handleReactAppInitialized() {
            Logger.debug("Bridge", "react app initialized (server \(serverID))")
            // Flush any channel navigation queued from a tapped notification for a cold-started SPA.
            notificationWorker.reactAppInitialized(serverID: serverID)
        }

        func handleRequestBrowserHistoryStatus(_ completion: @escaping (BrowserHistoryStatus) -> Void) {
            completion(BrowserHistoryStatus(
                canGoBack: store.webView.canGoBack,
                canGoForward: store.webView.canGoForward
            ))
        }

        /// Native→page: push an SPA path into the routed server (desktop `BROWSER_HISTORY_PUSH`).
        func pushBrowserHistory(path: String) {
            let bridgePayload: [String: Any] = ["name": BridgeMessage.browserHistoryPush, "body": ["path": path]]
            guard let data = try? JSONSerialization.data(withJSONObject: bridgePayload),
                  let json = String(data: data, encoding: .utf8) else { return }
            store.webView.evaluateJavaScript(
                "window.dispatchEvent(new CustomEvent('mattermost-bridge', {detail: \(json)}));"
            )
            Logger.debug("Bridge", "pushed browser history path \(path)")
        }

        func navigateHistory(byOffset offset: Int) {
            let payload: [String: Any] = ["name": BridgeMessage.history, "body": ["offset": offset]]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            store.webView.evaluateJavaScript(
                "window.dispatchEvent(new CustomEvent('mattermost-bridge', {detail: \(json)}));"
            )
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            store.pageError = nil
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            store.isLoading = true
            // Follow the active appearance on every committed page load.
            themeSync.apply(to: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            store.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            store.isLoading = false
            store.pageError = error
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            store.isLoading = false
            store.pageError = error
        }

        /// TLS / server-trust challenge handling. Phase 0 pass-through is now replaced by the
        /// Phase 2 `CertTrust` bag: for a self-signed / enterprise server whose certificate the
        /// user has previously decided to trust, accept it; if the user previously refused it
        /// ("Don't ask again"), hard-reject; otherwise fall back to the default handling so the
        /// stock connection-error / certificate flow (and the native CertPromptSheet once it
        /// lands in Phase 3) can present the decision. Publicly-validated chains keep the
        /// default behaviour — this code never bypasses trust for arbitrary hosts.
        func webView(_ webView: WKWebView,
                     didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let method = challenge.protectionSpace.authenticationMethod
            // Only touch server-trust; anything else (basic, digest, proxied) falls through
            // to the system.
            guard method == NSURLAuthenticationMethodServerTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            guard let serverURL = Self.httpsURL(host: challenge.protectionSpace.host,
                                                port: challenge.protectionSpace.port) else {
                // Unparseable host — fall through to the system so we never bypass trust.
                completionHandler(.performDefaultHandling, nil)
                Logger.debug("WebView", "server-trust challenge with unparseable host -> default")
                return
            }

            let presentedCert = Self.comparableLeafCertificate(from: challenge.protectionSpace.serverTrust)
            guard let presented = presentedCert else {
                // We could not read a presented certificate — do not silently grant trust.
                completionHandler(.performDefaultHandling, nil)
                Logger.debug("WebView", "server-trust challenge for \(challenge.protectionSpace.host) with no readable cert -> default (public chain)")
                return
            }

            guard let recorded = certTrust.trustedCertificate(for: serverURL),
                  CertTrust.areEqual(recorded, b: presented), !recorded.dontTrust else {
                if certTrust.isExplicitlyUntrusted(for: serverURL) {
                    // User refused this certificate before: do not re-prompt, hard-reject.
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    Logger.info("WebView", "rejected explicitly-untrusted certificate for \(challenge.protectionSpace.host)")
                    return
                }

                // First sight of this certificate: do NOT auto-trust or auto-reject. Surface
                // the native CertPromptSheet (the trust bag is consulted on the retry; the
                // user's decision is recorded via `resolveCertificateDecision`). The default
                // handling is still used so the page settles into the connection-error state
                // underneath the prompt (desktop shows its certificate modal over the error).
                let info = Self.certificateInfo(from: challenge.protectionSpace.serverTrust)
                store.pendingCertificatePrompt = CertificatePrompt(origin: serverURL,
                                                                    certificate: presented,
                                                                    info: info)
                completionHandler(.performDefaultHandling, nil)
                Logger.info("WebView", "unseen certificate for \(challenge.protectionSpace.host) -> presenting CertPromptSheet")
                return
            }

            // User previously accepted this exact certificate for this origin: accept it
            // by presenting the server trust as the credential (desktop semantics).
            let accepted = challenge.protectionSpace.serverTrust
            let credential = accepted.map { URLCredential(trust: $0) }
            completionHandler(.useCredential, credential)
            Logger.info("WebView", "accepted previously-trusted self-signed certificate for \(challenge.protectionSpace.host)")
        }

        /// The leaf (server) certificate from a `SecTrust` chain, as a comparable fingerprint.
        /// The chain's index 0 is always the server leaf. Returns nil when unreadable.
        private static func comparableLeafCertificate(from trust: SecTrust?) -> ComparableCertificate? {
            guard let trust else { return nil }
            let count = SecTrustGetCertificateCount(trust)
            guard count > 0 else { return nil }
            guard let leaf = SecTrustGetCertificateAtIndex(trust, 0) else { return nil }
            return try? CertTrust.comparable(from: leaf)
        }

        /// Display-facing details of the leaf certificate (for the CertPromptSheet
        /// "Certificate Information" sheet). Returns nil when the chain is unreadable.
        private static func certificateInfo(from trust: SecTrust?) -> CertificateInfo? {
            guard let trust else { return nil }
            let count = SecTrustGetCertificateCount(trust)
            guard count > 0 else { return nil }
            guard let leaf = SecTrustGetCertificateAtIndex(trust, 0) else { return nil }
            return CertTrust.info(from: leaf)
        }

        /// Build the origin-style URL a challenge is scoped to, without any force-unwrap. Uses
        /// `URLComponents` so a host carrying unexpected characters can never crash the shell.
        private static func httpsURL(host: String, port: Int) -> URL? {
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            if port > 0 && port != 443 {
                components.port = port
            }
            // URLComponents percent-encodes the host; rebuild via the encoded host string so the
            // URL never silently drops the trust scope.
            guard let raw = components.string, !host.isEmpty else { return nil }
            return URL(string: raw)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Allow the Mattermost web app's own navigations. External-protocol / popup
            // handling lands with the deep-link router in Phase 1; block nothing here.
            decisionHandler(.allow)
        }

        // MARK: WKUIDelegate

        /// Block JS dialogs (`alert`/`confirm`/`prompt`) from the page. Desktop's
        /// navigation/security guards refuse script-injected prompt loops; we mirror that by
        /// suppressing them entirely (Phase 0 has no native modal to back them).
        func webView(_ webView: WKWebView,
                     runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping () -> Void) {
            Logger.debug("WebView", "suppressed JS alert: \(message)")
            completionHandler()
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (Bool) -> Void) {
            completionHandler(false)
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            completionHandler(nil)
        }
    }
}