// Behaviour reference: `mattermost-webapp`'s `components/root/root.tsx`
// (`showLandingPageIfNecessary`) and `components/linking_landing_page` — the page that asks
// "Where would you like to view this?" before it will show any surface.

import Foundation
import WebKit

/// The web app's first-visit **desktop-app landing page**.
///
/// A fresh per-server `WKWebsiteDataStore` has `BrowserStore.hasSeenLandingPage()` false, so on the
/// first page load `Root` pushes `/landing#<the path the reader asked for>` and replaces the
/// surface with "Where would you like to view this? / View in Desktop App / View in Browser".
/// Measured on a 9.11 server from this shell: `/admin_console` and `/playbooks` both rendered that
/// page, and the committed URL still contained the surface's path — which is why a test that
/// asserts `url.contains("/admin_console")` passes while the reader sees no console at all.
///
/// The desktop client never sees this page because `isDesktopApp()` returns early (its UA carries
/// `Mattermost/… Electron/…`). The shell must not claim that UA: the web app switches to its
/// Electron code path, which needs a fuller `window.desktop` API and leaves the workspace stuck on
/// "Loading" (measured, `WebViewStore.userAgent`). What is left is the navigation itself: the push
/// has already marked the page seen, so loading the fragment's path again shows the real surface.
///
/// T46-R: the fragment is resolved only for a landing page **of the configured server**. Comparing
/// it to the landing page's own origin (the first implementation) accepted
/// `https://evil.example/landing#/admin_console`, i.e. a server that redirects the fallback's
/// webview elsewhere could name the next route. The origin and the install path are both the
/// server's now (`T46WebFallbackTests.testAnythingThatIsNotASameServerSurfaceIsNotFollowed` fails
/// against the old rule, measured).
enum WebAppLandingPage {

    /// The route, under the server's base path.
    static let route = "landing"

    /// The web app's own "this browser has seen the landing page" flag (measured, not read from
    /// upstream source: after one visit to `/landing` on a real 9.11.19 server, `localStorage`
    /// contains `__landingPageSeen__=true` — that is the key the SPA writes for itself).
    static let seenFlagKey = "__landingPageSeen__"

    /// The script that marks the landing page seen **before** the SPA boots.
    ///
    /// Why it is more than cosmetic (measured on 9.11.19): the landing page is not the surface, so
    /// its own first load is a page the reader did not ask for and cannot use — `/landing` renders
    /// "Where would you like to view this?" with a URL that still carries the surface's path, which
    /// is how a `url.contains("/admin_console")` assertion passed while no console was drawn.
    /// Following it afterwards (`surfaceTarget(in:on:)`) works, but it costs a full extra boot of
    /// the web app and it leaves the reader on the prompt for as long as that boot takes. Seeding
    /// the flag means the first boot is already the surface.
    ///
    /// **What the landing page is *not* responsible for** (a hypothesis this card measured and
    /// dropped, `docs/t46-build-note.md` §5.2): the session sign-out that first looked like the
    /// landing page's doing. With the flag seeded — so the landing page never rendered — the surface
    /// *still* landed on `/login?redirect_to=…`, and the boot trace named the cause: the web app
    /// calls `POST /api/v4/users/logout` (200) because the session it was handed was missing
    /// `MMCSRF`/`MMUSERID`. The fix lives in `WebSessionCookiePolicy.sessionCookies`; this flag is
    /// only the navigation half.
    ///
    /// `atDocumentStart` is the requirement: the SPA reads the flag while booting. `try` because a
    /// store with storage disabled must not break the page; the caller keeps the URL-based skip as
    /// the fallback for exactly that case.
    static let preloadScript = """
    (() => {
        try {
            if (window.localStorage && !window.localStorage.getItem('\(seenFlagKey)')) {
                window.localStorage.setItem('\(seenFlagKey)', 'true');
            }
        } catch (_) {}
    })();
    """

    /// The script, as a user script for the fallback's content controller.
    static var userScript: WKUserScript {
        WKUserScript(source: preloadScript,
                     injectionTime: .atDocumentStart,
                     forMainFrameOnly: true)
    }

    /// The same-server surface a `/landing#<path>` URL names, or `nil` when `url` is not the
    /// landing page, is not on `serverURL`'s origin, or names a path outside the server's install.
    ///
    /// Only a fragment that starts with a single `/` is accepted: `//host/path` and
    /// `https://host/path` are other origins, and following them from a shell-driven navigation
    /// would be an open redirect. The query is preserved (the web app pushes pathname + search).
    ///
    /// The fragment is the web app's own router location, so on a sub-path install
    /// (`https://host/company/mattermost`) it carries the base path too
    /// (`#/company/mattermost/admin_console`). A fragment that addresses something outside the
    /// install is refused rather than navigated to — the server's install is the boundary this
    /// shell knows about.
    static func surfaceTarget(in url: URL, on serverURL: URL) -> URL? {
        guard let base = MMBaseURL(serverURL),
              let landing = base.absolute("/" + route),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path == landing.path,
              let fragment = components.fragment,
              fragment.hasPrefix("/"),
              !fragment.hasPrefix("//"),
              let target = URL(string: fragment, relativeTo: url)?.absoluteURL,
              isOnServerOrigin(target, base: base),
              isUnderInstall(target, base: base),
              target.path != landing.path else {
            return nil
        }
        return target
    }

    /// Same scheme, host and port as the configured server. A port is compared by value, so
    /// `https://host:443` and `https://host` are one origin.
    private static func isOnServerOrigin(_ url: URL, base: MMBaseURL) -> Bool {
        url.scheme?.lowercased() == base.serverURL.scheme?.lowercased()
            && url.host?.lowercased() == base.serverURL.host?.lowercased()
            && effectivePort(of: url) == effectivePort(of: base.serverURL)
    }

    private static func effectivePort(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    /// Inside the server's install: the base path itself, or a path below it.
    private static func isUnderInstall(_ url: URL, base: MMBaseURL) -> Bool {
        let path = url.path
        if base.basePath.isEmpty { return path.hasPrefix("/") }
        return path == base.basePath || path.hasPrefix(base.basePath + "/")
    }
}
