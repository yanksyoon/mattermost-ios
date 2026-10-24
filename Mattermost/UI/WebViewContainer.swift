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
    /// The configured server URL. Certificate decisions are scoped to this origin only.
    let serverURL: URL

    /// The app-wide mention/unread accounting (desktop `AppState`), injected from the environment.
    @EnvironmentObject var sessionStore: SessionStore
    /// The app-wide local-notification scheduler (desktop `main/notifications`), injected from
    /// the environment.
    @EnvironmentObject var notificationWorker: NotificationWorker

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, serverID: serverID, serverURL: serverURL,
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
        // The store records "I stopped an unfinished page" itself: `WKWebView.isLoading` flips to
        // false asynchronously (KVO), so a resume decision taken right after this call cannot rely on
        // it (T26-R R6, race found by re-running the UI repro in a batch).
        coordinator.store.stopForDismantle()
    }

    // MARK: Coordinator — the native policy surface

    /// Pure navigation policy for the webview. Extracted from the delegate because
    /// `WKNavigationAction` cannot be constructed in tests, so the SSO rules would otherwise be
    /// unverifiable.
    enum WebNavigationPolicy {
        enum Decision: Equatable {
            /// Let WKWebView load the request.
            case load
            /// Not a web navigation: cancel it and hand the URL to the app (deep links,
            /// IdP app-switch schemes) instead of failing the load silently.
            case handOff
        }

        static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "javascript"]

        static func decision(for url: URL?) -> Decision {
            guard let scheme = url?.scheme?.lowercased() else { return .load }
            return webSchemes.contains(scheme) ? .load : .handOff
        }
    }

    /// Which host a TLS challenge belongs to. The certificate trust bag exists for the user's
    /// own (often self-signed) server; identity providers reached during SSO, CDNs and
    /// integrations must never be judged by it.
    enum CertChallengePolicy {
        enum Scope: Equatable {
            /// The configured server: the trust bag and `CertPromptSheet` apply.
            case serverOrigin
            /// Anything else: system chain only, no prompt, no stored decision.
            case thirdParty
        }

        static func scope(challengeHost: String, serverHost: String?) -> Scope {
            guard let serverHost, !serverHost.isEmpty else { return .thirdParty }
            return challengeHost.caseInsensitiveCompare(serverHost) == .orderedSame ? .serverOrigin : .thirdParty
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, JsBridge {
        let store: WebViewStore
        /// The server this bridge belongs to (tags every inbound shell event).
        let serverID: UUID
        /// The configured server origin. Only challenges from this host consult the trust bag.
        let serverURL: URL

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
             serverURL: URL,
             sessionStore: SessionStore,
             notificationWorker: NotificationWorker,
             certTrust: CertTrust = CertTrust(),
             themeSync: ThemeSync = ThemeSync()) {
            self.store = store
            self.serverID = serverID
            self.serverURL = serverURL
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
            // A new navigation supersedes the previous page: it is no longer "finished" (T26-R R6).
            store.markPageLoadStarted()
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            store.isLoading = true
            // Follow the active appearance on every committed page load.
            themeSync.apply(to: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            store.isLoading = false
            store.markPageLoadFinished()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            // Cancellations (a surface toggle dismantling this view → `stopLoading()`, or a
            // superseding navigation) are not page failures: they leave the page resumable
            // (T26-R R6). `markPageLoadFailed` decides and logs which case this is.
            store.markPageLoadFailed(error)
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            store.markPageLoadFailed(error)
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

            // A challenge from any host other than the configured server is a third party in the
            // flow: the SSO identity provider (e.g. login.ubuntu.com), a CDN, an integration.
            // Those are judged by the system chain alone. Feeding them to the trust bag used to
            // raise an "Untrusted certificate" sheet for a perfectly valid public certificate,
            // and refusing it hard-cancelled TLS, which showed up as a blank page instead of the
            // IdP login form.
            guard CertChallengePolicy.scope(challengeHost: challenge.protectionSpace.host,
                                            serverHost: self.serverURL.host) == .serverOrigin else {
                completionHandler(.performDefaultHandling, nil)
                Logger.debug("WebView",
                             "server-trust challenge for third-party host \(challenge.protectionSpace.host) -> system chain")
                return
            }

            // Even for our own server, a chain the system already validates needs no decision
            // from us; only a genuinely untrusted chain (self-signed / enterprise) reaches the bag.
            if let trust = challenge.protectionSpace.serverTrust, SecTrustEvaluateWithError(trust, nil) {
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
            // SSO providers can bounce back with a non-web scheme (mattermost://…,
            // com.okta…, msauth…). WKWebView cannot load those, and cancelling without
            // handing them to the app looks like "the page after sign-in never loads".
            switch WebNavigationPolicy.decision(for: navigationAction.request.url) {
            case .load:
                decisionHandler(.allow)
            case .handOff:
                decisionHandler(.cancel)
                if let url = navigationAction.request.url {
                    Logger.info("WebView", "non-web navigation (\(url.scheme ?? "?")) -> handing to the app")
                    UIApplication.shared.open(url)
                }
            }
        }

        // MARK: WKUIDelegate

        /// Popup support. Mattermost's SSO buttons ("Sign in with Microsoft", GitLab, Okta…) and
        /// several integrations open via `window.open` / `target="_blank"`. Without this delegate
        /// WKWebView silently drops those navigations, which the user experiences as "the SSO
        /// page does not load". This shell is single-window, so the popup's request is loaded in
        /// the same webview instead of spawning an orphan WKWebView.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard navigationAction.targetFrame == nil, let url = navigationAction.request.url else {
                return nil
            }
            Logger.info("WebView", "popup navigation to \(url.host ?? "unknown") -> main webview")
            webView.load(navigationAction.request)
            return nil
        }

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