// T46 — the permanent web escape hatch for surfaces that will never be ported.
//
// Reference for *what* these surfaces are: `mattermost/mattermost` monorepo, webapp routes
// (`/boards`, `/playbooks`, `/admin_console`, `/plugins/<plugin id>`), observed against a real
// 9.11.19 server. No upstream source is copied; the types below are this repo's own.
// Licence: Apache-2.0 for the webapp UI (`docs/THIRD_PARTY_NOTICES.md`); the server itself is
// AGPL-3.0 and is not linked, copied or vendored — a route is a URL string, not code.
//
// ## Why this is not a `Surface` case
//
// T46's scope text asks for "per-surface `SurfaceMode` entries that stay `web` forever". That is
// the one shape `docs/dual-render.md` §4 forbids, on a decision this repo made *after* this card
// was written (`t_39ea6115` §1.1, landed by `t_6d420e01` the day before this card ran):
//
//   > A case is a *switch key* … Flipping it must also be able to change what is on screen in
//   > **at least one direction** — a key with one legal state is not a switch.
//
// and it retired `.plugins` for exactly the reason this card would re-create it: "S29–S32 are
// permanently web … No future card can render one natively, so the key's `native` state was
// unreachable — one legal state is not a switch." A `Surface` case also has to be consulted by a
// `SurfaceHost` (`scripts/verify-dual-render-gates.sh` gate 11), and a `SurfaceHost`'s web branch
// is the *pane's* webview — which the pane-owning `.channelView` card destroys when it resolves
// native (`ViewStore.release`), so the key could not even render its own region.
//
// So the catalogue below is a **route list**, not a switch: these surfaces have exactly one
// renderer (the server's web app) and the honest type says so. They are documented as permanent in
// `docs/dual-render.md` §13. Re-adding them as `Surface` keys would resurrect the retired
// `.plugins` raw value, which the catalogue rule forbids ("A retired key is never reused for a
// different region"), and would make gate 11's `unhostedSurfaces` pin grow again.

import Foundation

/// A server surface the native client opens **in the web app, permanently**.
///
/// A value is a *route* — the thing the reader wants to look at — not a render mode. The native
/// shell offers these from its own navigation (the channel list's "Web view" section), opens them
/// in a webview that shares the server's session, and returns to the native stack on close
/// (`docs/dual-render.md` §13).
public struct WebFallbackSurface: Hashable, Identifiable, Codable, Sendable {

    /// The surfaces that are permanently web. All four are webapp routes:
    ///
    /// | kind | route | why it is never native |
    /// |---|---|---|
    /// | `boards` | `/boards` | Boards is a server-shipped product bundle (own UI, own release cycle) |
    /// | `playbooks` | `/playbooks` | same: a product bundle served by the plugin |
    /// | `systemConsole` | `/admin_console` | the admin console is the server's own UI, versioned with it |
    /// | `plugin` | `/plugins/<id>` | a plugin screen is arbitrary third-party UI |
    public enum Kind: String, CaseIterable, Codable, Sendable {
        case boards
        case playbooks
        case systemConsole
        case plugin
    }

    public let kind: Kind

    /// The plugin id for `.plugin` (e.g. `com.mattermost.calls`); ignored by every other kind.
    public let pluginID: String?

    public init(kind: Kind, pluginID: String? = nil) {
        self.kind = kind
        self.pluginID = kind == .plugin ? pluginID : nil
    }

    /// Stable identity: the raw kind, plus the plugin id for `.plugin`. Two taps on the same row
    /// name the same surface (and a different plugin is a different surface).
    public var id: String {
        switch kind {
        case .boards: return Kind.boards.rawValue
        case .playbooks: return Kind.playbooks.rawValue
        case .systemConsole: return Kind.systemConsole.rawValue
        case .plugin: return "\(Kind.plugin.rawValue).\(pluginID ?? "")"
        }
    }

    /// What the native chrome calls this surface.
    public var title: String {
        switch kind {
        case .boards: return "Boards"
        case .playbooks: return "Playbooks"
        case .systemConsole: return "System Console"
        case .plugin: return pluginID.map { "Plugin: \($0)" } ?? "Plugin screen"
        }
    }

    /// The glyph the row draws. Decoration only: the row is labelled by `title` (T45's rule).
    public var systemImage: String {
        switch kind {
        case .boards: return "rectangle.grid.2x2"
        case .playbooks: return "book.closed"
        case .systemConsole: return "gearshape.2"
        case .plugin: return "puzzlepiece.extension"
        }
    }

    /// The route **under the server's base path**, or `nil` when the entry names nothing loadable.
    ///
    /// A `.plugin` entry with no id, or with an id that could escape the `/plugins/` root, has no
    /// path: the row exists, the route does not, and the caller renders "cannot be opened" rather
    /// than a 404 the reader cannot explain.
    public var path: String? {
        switch kind {
        case .boards: return "/boards"
        case .playbooks: return "/playbooks"
        case .systemConsole: return "/admin_console"
        case .plugin:
            guard let pluginID, Self.isValidPluginID(pluginID) else { return nil }
            return "/plugins/" + pluginID
        }
    }

    /// The absolute URL for this surface on `serverURL`, preserving a sub-path install
    /// (`https://host/company/mattermost` + `/boards` → `https://host/company/mattermost/boards`).
    ///
    /// The join is `MMBaseURL.absolute(_:)` — the same helper the plugin REST routes use — so a
    /// sub-path server cannot behave differently from the transport.
    public func url(relativeTo serverURL: URL) -> URL? {
        guard let path else { return nil }
        return MMBaseURL(serverURL)?.absolute(path)
    }

    /// A plugin id has to be one path segment: it is pasted into `/plugins/<id>` and the webview
    /// takes it literally. `.`/`..`, slashes, queries, fragments, whitespace and control characters
    /// are refused so a row can never address a different part of the server.
    public static func isValidPluginID(_ id: String) -> Bool {
        guard (1...190).contains(id.count) else { return false }
        guard let first = id.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first) else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return !id.contains("..")
    }

    /// The rows the native chrome offers, in order. `.plugin` is not one of them: it needs an id,
    /// so it is reached through its own row ("Plugin screen…") rather than a fixed entry.
    public static let fixedMenu: [WebFallbackSurface] = [
        WebFallbackSurface(kind: .boards),
        WebFallbackSurface(kind: .playbooks),
        WebFallbackSurface(kind: .systemConsole),
    ]
}
