import Foundation
import Combine

/// A parsed Mattermost deep link (`mattermost://host/path`, or an http(s) link whose host is a
/// configured server). Native counterpart of desktop `navigationManager` + `getDeeplinkingURL`.
struct DeepLink: Equatable {
    /// The server base URL the link targets (or nil if the host is unknown/unparseable).
    let serverURL: URL?
    /// Path fragment (e.g. `/team/channel/general`) to route the SPA to.
    let path: String
}

enum DeepLinkParsing {
    /// Maximum length allowed for a raw deep-link string, mirroring desktop `MAX_URL_LENGTH`ets
    /// guard in `parseURL` (a defensive bound, not a correctness limit).
    static let maxLength = 2048

    /// Parse a raw deep-link string into its `mattermost://` (or server http/https) form.
    ///
    /// Mirrors desktop `getDeeplinkingURL`/`openLinkInPrimaryTab`: a `mattermost://` scheme is
    /// normalised to the server URL it names; an http(s) URL is accepted as-is.
    static func parse(_ raw: String) -> DeepLink? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return nil }
        guard !trimmed.contains("\\0"), !trimmed.lowercased().contains("%00"),
              !trimmed.contains("\u{0000}") else { return nil }
        guard let url = URL(string: trimmed) else { return nil }
        return parse(url)
    }

    static func parse(_ url: URL) -> DeepLink? {
        let scheme = (url.scheme ?? "").lowercased()

        // Mattermost owns the `mattermost` scheme. Accept `mattermost://host/path` and the
        // sub-scheme `mattermost-beta://...` (desktop registers both).
        var serverURL: URL?
        var relPath = ""
        if scheme == "mattermost" || scheme == "mattermost-beta" {
            // Interpret the host as the server authority, keeping any explicit port.
            guard let host = url.host, !host.isEmpty else { return nil }
            var comps = URLComponents()
            comps.scheme = "https"
            comps.host = host
            comps.port = url.port
            guard let base = comps.url else { return nil }
            serverURL = base
            relPath = url.path
        } else if scheme == "http" || scheme == "https" {
            // Direct http(s) link: drop scheme-weirdness, keep path.
            serverURL = url
            relPath = url.path
        } else {
            return nil
        }
        return DeepLink(serverURL: serverURL, path: relPath)
    }
}

/// Routes `mattermost://` deep links to the correct server (and SPA path) at runtime.
///
/// Native counterpart of desktop `navigationManager` (`src/app/navigationManager.ts`) wired to
/// SwiftUI's `onOpenURL` / `UIApplicationDelegate.application(_:open:options:)`. Semantics mirror
/// `openLinkInPrimaryTab`:
/// - If the link's host matches a configured server, switch the shell to it and push the path
///   into that server's SPA (via the bridge's `BROWSER_HISTORY_PUSH`).
/// - If no server matches and server management is enabled, the router reports a
///   `needsServerAdd` so the shell can offer to add that URL (desktop `ServerHub.showNewServerModal`).
/// - If a route arrives before the shell is ready, it is queued and flushed on `ready()`.
@MainActor
final class DeepLinkRouter: ObservableObject {

    enum Outcome: Equatable {
        /// Routed to a server — will land on `path`.
        case routed
        /// The host isn't configured; the UI should offer to add this server.
        case needsServerAdd(serverURL: URL?)
        /// Nothing to do (malformed/ignored link).
        case ignored
        /// Shell internals not yet ready; will be handled once `ready()` is called.
        case queued
    }

    /// The server store this router drives (injected; not retained to avoid a strong cycle with
    /// the app-level state object). Used to switch the active server.
    weak var serverStore: ServerStore?
    /// Drives a webview to the routed SPA path once a server is active.
    weak var viewStore: ViewStore?

    private var isReady = false
    private var queued: DeepLink?

    /// Set by the app once stores + webviews are available. Flushes any queued link.
    func ready() {
        isReady = true
        if let queued {
            self.queued = nil
            _ = route(queued)
        }
    }

    /// Entry point for SwiftUI `onOpenURL` and the app delegate.
    @discardableResult
    func handle(_ url: URL) -> Outcome {
        guard let link = DeepLinkParsing.parse(url) else {
            Logger.debug("DeepLinkRouter", "unparseable deep link ignored: \(url.absoluteString)")
            return .ignored
        }
        return route(link)
    }

    /// Convenience for string-based links (e.g. tests / other routers).
    @discardableResult
    func handle(_ raw: String) -> Outcome {
        guard let link = DeepLinkParsing.parse(raw) else { return .ignored }
        return route(link)
    }

    private func route(_ link: DeepLink) -> Outcome {
        guard isReady else {
            queued = link
            Logger.debug("DeepLinkRouter", "queued deep link until shell ready")
            return .queued
        }

        guard let serverStore else { return .ignored }

        // Match by host (client-managed servers), mirroring ServerManager.lookupServerByURL.
        guard let target = matchingServer(for: link.serverURL, in: serverStore.servers) else {
            if serverStore.servers.isEmpty {
                // No servers at all: offer to add the linked host.
                return .needsServerAdd(serverURL: link.serverURL)
            }
            Logger.debug("DeepLinkRouter", "no configured server matches \(link.serverURL?.host ?? "<none>"); caller may offer add")
            return .needsServerAdd(serverURL: link.serverURL)
        }

        // Switch to the correct server.
        serverStore.switchTo(id: target.id)
        viewStore?.setPrimary(target.id)

        // Drive the SPA to the deep-linked path via the bridge (BROWSER_HISTORY_PUSH), unless
        // the path is empty (just landing on the server root).
        pushPathToActiveServer(link.path)
        return .routed
    }

    /// Pick the configured server whose identity host matches `link.serverURL`.
    private func matchingServer(for link: URL?, in servers: [ServerConfig]) -> ServerConfig? {
        guard let linkHost = link?.host?.lowercased() else { return nil }
        // Host is enough for a match (port/scheme handled by the identity key). Prefer an exact
        // host match; fall back to a subdomain-less base-host comparison is NOT done — host must
        // align, mirroring desktop's strict ServerManager keying.
        return servers.first { ($0.url.host ?? "").lowercased() == linkHost }
    }

    /// Ask the active server's webview to SPA-navigate to `path`.
    private func pushPathToActiveServer(_ path: String) {
        guard let viewStore,
              let primary = viewStore.primaryServerID,
              let store = viewStore.view(forServerID: primary) else { return }
        let bridge = store.bridge
        if path.isEmpty || path == "/" {
            return
        }
        bridge.delegate?.pushBrowserHistory(path: path)
    }
}
