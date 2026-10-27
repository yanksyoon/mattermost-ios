// T44-AV-R F2 — the webview layout probe, as run (t_19ac4035).
//
// This file is a *template*, deliberately outside MattermostTests/: that folder is a
// PBXFileSystemSynchronizedRootGroup, so anything dropped into it is compiled into the
// MattermostTests target automatically, with no pbxproj entry (measured: the build log names
// "T44RCallsWebviewDomTests.swift (in target 'MattermostTests')" although the pbxproj never
// mentions it). Shipping it in place would move the Catalyst suite from 1489 run / 4 skipped to
// 1490 / 5 — the number every later card compares itself against.
//
// To run it:
//
//   cp scripts/t44r_webview_dom_probe.swift MattermostTests/T44RCallsWebviewDomTests.swift
//   xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
//     -destination 'platform=iOS Simulator,id=<iPhone 16 Pro>' \
//     -derivedDataPath ~/Library/Developer/Xcode/DerivedData/t44r-wt-ios \
//     -only-testing:MattermostTests/T44RCallsWebviewDomTests
//   rm MattermostTests/T44RCallsWebviewDomTests.swift
//
// then read `T44R RESULT width=` blocks out of the log. Build in a clean worktree at the commit
// under test, not in a tree another card is mid-edit in.
//
// What it measures, in the app's own WKWebView stack (WebViewStore: the desktop UA, the same
// configuration, the same bridge), at an explicit width:
//
//   * the real viewport vs the page's own layout width (innerWidth / scrollWidth / clientWidth);
//   * the meta viewport the app's index.html ships;
//   * whether the Calls plugin's entry point exists in the DOM at all (`#calls-join-button`, the
//     header dropdown item, anything whose id/class/aria-label mentions "call"), and its rect;
//   * which ancestor boxes collapsed to zero and which columns are hidden or off-canvas — the
//     measured answer to "why is the button 0 by 0" and to T44-AV's menu button at x = 403;
//   * which elements overflow the viewport;
//   * whether the mobile or the desktop layout mounted.
//
// Two measured facts are baked into the harness, both surprising:
//   * the fixture attaches MMAUTHTOKEN (HttpOnly) / MMUSERID / MMCSRF only to a login request that
//     carries `X-Requested-With: XMLHttpRequest`; the identical request without it answers 200 with
//     no Set-Cookie, and the web app then bounces to /login;
//   * driving that login from *inside* the page (sync XHR, or callAsyncJavaScript) kills the
//     hosted-test process, so the login happens in Swift and only the resulting cookies are
//     injected into this webview's own WKHTTPCookieStore.
//
// Defaults are the fixture's throwaway local values; TEST_RUNNER_MM_CALLS_* are read first, but
// they do not reach a hosted unit test's environment (they are for UI-test runners), which is why
// the defaults exist at all.

import XCTest
import WebKit
import UIKit
@testable import Mattermost

@MainActor
final class T44RCallsWebviewDomTests: XCTestCase {

    private var window: UIWindow?

    func testWebviewOffersCallsAtIPhoneAndIPadWidth() async throws {
        let env = ProcessInfo.processInfo.environment
        // Throwaway harness: the fixture values are defaults because xcodebuild's TEST_RUNNER_*
        // variables do not reach a *hosted unit* test's environment (they are for UI-test runners).
        let rawURL = env["TEST_RUNNER_MM_CALLS_URL"] ?? "http://127.0.0.1:8065"
        try XCTSkipUnless(!rawURL.isEmpty, "set TEST_RUNNER_MM_CALLS_URL to the live fixture")
        guard let serverURL = URL(string: rawURL) else { return XCTFail("bad URL \(rawURL)") }
        let loginID = env["TEST_RUNNER_MM_CALLS_LOGIN"] ?? "perfprobe"
        let password = env["TEST_RUNNER_MM_CALLS_PASSWORD"] ?? "PerfProbe-Not-A-Real-Secret-1"
        let sizes = (env["TEST_RUNNER_MM_CALLS_WIDTHS"] ?? "402x874,834x1194")
            .split(separator: ",").map { $0.split(separator: "x").compactMap { Double($0) } }
            .filter { $0.count == 2 }
            .map { CGSize(width: $0[0], height: $0[1]) }

        print("T44R screen=\(UIScreen.main.bounds.size) scale=\(UIScreen.main.scale) "
              + "idiom=\(UIDevice.current.userInterfaceIdiom.rawValue)")

        for size in sizes {
            try await measure(serverURL: serverURL, loginID: loginID, password: password, size: size)
        }
    }

    // MARK: - One width

    private func measure(serverURL: URL, loginID: String, password: String,
                         size: CGSize) async throws {
        let store = WebViewStore(dataStoreIdentifier: UUID())
        let webView = store.webView
        webView.frame = CGRect(origin: .zero, size: size)

        let controller = UIViewController()
        controller.view.addSubview(webView)
        window?.isHidden = true
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window

        // 2. Sign in from the test process and hand the server's own cookies to this webview.
        //    Two measured facts drive this shape:
        //      * the server attaches MMAUTHTOKEN (HttpOnly) / MMUSERID / MMCSRF only to a login
        //        request that carries `X-Requested-With: XMLHttpRequest` — the same request
        //        without it answers 200 with no Set-Cookie, and the app then bounces to /login;
        //      * doing that login from *inside* the page (sync XHR or callAsyncJavaScript) kills
        //        the hosted-test process, so the login happens in Swift and only the resulting
        //        cookies are injected.
        let cookies = try await signInForCookies(serverURL, loginID: loginID, password: password)
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        for cookie in cookies {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                cookieStore.setCookie(cookie) { continuation.resume() }
            }
        }
        let stored = await withCheckedContinuation { (continuation: CheckedContinuation<[HTTPCookie], Never>) in
            cookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        print("T44R width=\(Int(size.width)) cookies=\(cookies.map(\.name).sorted()) "
              + "inStore=\(stored.count)")
        store.load(serverURL)
        _ = await waitForLoad(webView, marker: "document.body && document.body.innerText.length > 100",
                              seconds: 30)
        try? await Task.sleep(nanoseconds: 4_000_000_000)

        // 3. Click through the landing page if this client gets one.
        let landing = try? await webView.evaluateJavaScript(Self.dismissLandingScript) as? String
        print("T44R width=\(Int(size.width)) landing=\(landing ?? "nil")")
        _ = await waitForLoad(webView, marker: "document.querySelector('.channel-header') !== null",
                              seconds: 30)
        // 4. The plugin mounts its header button asynchronously after its config call returns;
        //    give the workspace a fixed settle window before measuring.
        try? await Task.sleep(nanoseconds: 8_000_000_000)

        let script = Self.measurementScript(width: size.width, height: size.height)
        let raw = try await webView.evaluateJavaScript(script)
        let text = (raw as? String) ?? "{\"error\":\"probe returned \(type(of: raw))\"}"
        print("T44R RESULT width=\(Int(size.width)) height=\(Int(size.height))")
        print(text)
        store.stopLoading()
        webView.removeFromSuperview()
        window.isHidden = true
    }

    private func waitForLoad(_ webView: WKWebView, marker: String, seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let ok = try? await webView.evaluateJavaScript(marker) as? Bool, ok {
                // wait for the SPA to paint text as well
                if let len = try? await webView.evaluateJavaScript(
                    "document.body ? document.body.innerText.length : 0") as? Int, len > 200 {
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    /// Logs in with the fixture account and returns the session cookies the *server* set.
    /// `X-Requested-With: XMLHttpRequest` is not cosmetic: measured against this fixture, the same
    /// login without it answers 200 with no `Set-Cookie` at all (see the harness header).
    private func signInForCookies(_ url: URL, loginID: String, password: String) async throws
        -> [HTTPCookie] {
        var request = URLRequest(url: url.appendingPathComponent("api/v4/users/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["login_id": loginID, "password": password])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw XCTSkip("no HTTP response") }
        guard http.statusCode == 200 else { throw XCTSkip("login failed: \(http.statusCode)") }
        let raw = http.allHeaderFields
            .filter { ($0.key as? String)?.lowercased() == "set-cookie" }
            .compactMap { $0.value as? String }
        // Parse each Set-Cookie on its own: `Expires=Thu, 26 Nov …` contains a comma, so joining
        // the header values and parsing once produces garbage cookies.
        var cookies: [HTTPCookie] = []
        for value in raw {
            cookies.append(contentsOf: HTTPCookie.cookies(
                withResponseHeaderFields: ["Set-Cookie": value], for: url))
        }
        // `allHeaderFields` may fold the three Set-Cookie headers into one comma-joined string,
        // and `Expires=Thu, 26 Nov …` contains a comma of its own — so if parsing above produced
        // nothing usable, take them from the shared cookie storage, where URLSession put them.
        if cookies.isEmpty {
            cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        }
        guard !cookies.isEmpty else { throw XCTSkip("login set no cookies") }
        return cookies
    }

    private static func jsString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let wrapped = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(wrapped.dropFirst().dropLast())
    }

    private static let dismissLandingScript = """
        (() => {
          const norm = (e) => (e.textContent || '').replace(/\\s+/g, ' ').trim().toLowerCase();
          const remember = [...document.querySelectorAll('label, span, div, p')]
            .find((e) => norm(e) === 'remember my preference');
          const clickable = [...document.querySelectorAll('button, a, [role=button]')];
          const browser = clickable.reverse()
            .find((e) => norm(e).indexOf('view in browser') !== -1);
          if (!browser) { return 'no landing page: ' + location.pathname; }
          if (remember) {
            const box = remember.parentElement ? remember.parentElement.querySelector('input[type=checkbox]') : null;
            if (box && !box.checked) { box.click(); }
          }
          browser.click();
          return 'clicked View in Browser at ' + location.pathname;
        })()
        """

    // MARK: - The measurement

    private static func measurementScript(width: Double, height: Double) -> String {
        """
        (() => {
          const r = (e) => { const b = e.getBoundingClientRect();
            return {x: Math.round(b.x), y: Math.round(b.y), w: Math.round(b.width),
                    h: Math.round(b.height), right: Math.round(b.right)}; };
          const describe = (e) => ({tag: e.tagName.toLowerCase(), id: e.id,
            cls: (e.className || '').toString().slice(0, 90), ...r(e),
            minW: getComputedStyle(e).minWidth, flex: getComputedStyle(e).flex,
            text: (e.innerText || e.getAttribute('aria-label') || '').trim().slice(0, 60)});
          const vw = window.innerWidth, vh = window.innerHeight;
          const de = document.documentElement, body = document.body;
          const meta = document.querySelector('meta[name=viewport]');
          const callish = [...document.querySelectorAll('*')].filter((e) => {
            const s = (e.id || '') + ' ' + (e.className || '').toString() + ' '
              + (e.getAttribute('aria-label') || '') + ' ' + (e.getAttribute('data-testid') || '')
              + ' ' + (e.getAttribute('title') || '');
            return /call/i.test(s);
          });
          const buttons = [...document.querySelectorAll(
              'button, [role=button], a.channel-header__icon, .channel-header__icon')]
            .map((e) => ({label: (e.getAttribute('aria-label') || e.innerText || '').trim().slice(0, 40),
                          id: e.id, cls: (e.className || '').toString().slice(0, 50), ...r(e)}));
          const overflow = [...document.querySelectorAll('*')].filter((e) => {
            const b = e.getBoundingClientRect();
            return b.width > 0 && b.right > vw + 0.5 && e.children.length < 60;
          }).slice(0, 18).map(describe);
          const header = document.querySelector('.channel-header');
          // Why a header child can be present-but-zero: walk the ancestor chain and report the
          // computed box each level actually got.
          const chain = (el) => {
            const out = []; let e = el;
            while (e && e !== document.documentElement && out.length < 12) {
              const cs = getComputedStyle(e);
              out.push({tag: e.tagName.toLowerCase(), id: e.id,
                        cls: (e.className || '').toString().slice(0, 60), ...r(e),
                        display: cs.display, minW: cs.minWidth, flex: cs.flex,
                        overflow: cs.overflow, pos: cs.position});
              e = e.parentElement;
            }
            return out;
          };
          const joinButton = document.querySelector('#calls-join-button');
          const columns = {};
          [['lhs', '.sidebar--left'], ['teamSidebar', '.team-sidebar'],
           ['channelView', '#channel_view, .channel-view'], ['header', '.channel-header'],
           ['rhs', '.sidebar--right, #sidebar-right'], ['center', '#app-content, .app__content']]
            .forEach(([name, sel]) => {
              const el = document.querySelector(sel);
              columns[name] = el ? {selector: sel, ...r(el),
                                    display: getComputedStyle(el).display} : null;
            });
          return JSON.stringify({
            requested: {w: \(Int(width)), h: \(Int(height))},
            screen: {w: Math.round(screen.width), h: Math.round(screen.height),
                     dpr: window.devicePixelRatio},
            viewport: {innerWidth: vw, innerHeight: vh,
                       clientWidth: de.clientWidth, scrollWidth: de.scrollWidth,
                       bodyScrollWidth: body ? body.scrollWidth : null},
            layoutOverflows: (de.scrollWidth > vw + 0.5),
            metaViewport: meta ? meta.getAttribute('content') : null,
            userAgent: navigator.userAgent.slice(0, 120),
            pathname: location.pathname + location.search,
            navigator: {platform: navigator.platform,
                        maxTouchPoints: navigator.maxTouchPoints,
                        standalone: !!navigator.standalone},
            landingish: document.querySelectorAll('[class*=landing], [class*=Landing]').length,
            mobileQueryMatches: window.matchMedia('(max-width: 768px)').matches,
            htmlClass: de.className.slice(0, 160),
            bodyClass: body ? body.className.slice(0, 160) : null,
            markers: {
              mobileHeader: document.querySelectorAll(
                '.MobileChannelHeader, .mobile-channel-header, .channel-header--mobile').length,
              desktopHeader: document.querySelectorAll('.channel-header').length,
              sidebarLeft: document.querySelectorAll('.sidebar--left').length,
              callsJoinButton: document.querySelectorAll('#calls-join-button').length,
              callsAnyClass: document.querySelectorAll(
                '[class*=call], [id*=call], [data-testid*=call]').length,
              pluginConfigLoaded: !!window.basename || !!window.mm_config
            },
            callishCount: callish.length,
            callish: callish.slice(0, 12).map(describe),
            header: header ? describe(header) : null,
            columns: columns,
            joinButtonChain: joinButton ? chain(joinButton) : null,
            headerButtons: buttons.slice(0, 40),
            overflow: overflow,
            nodes: document.querySelectorAll('*').length,
            bodyTextLength: body ? body.innerText.length : 0,
            bodyTextSample: body ? body.innerText.replace(/\\s+/g, ' ').slice(0, 300) : null,
            errors: (window.__mmErrorLog || []).slice(0, 10)
          }, null, 1);
        })()
        """
    }
}
