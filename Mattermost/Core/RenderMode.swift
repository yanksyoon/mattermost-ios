import Foundation

/// A distinct renderable region of the Mattermost client (T26 dual-render harness).
///
/// Each surface can render either **natively** — a SwiftUI "screen card" driven by the
/// Mattermost REST API v4 + WebSocket v4 (Path B) — or through the **webview escape hatch**
/// — the web app in `WKWebView` (Path A) — independently of every other surface.
///
/// Port role: `Surface` is the key of the per-surface dual-render switch. A screen card names
/// its own surface when it opts in; there is deliberately no global "port everything" switch.
/// See `docs/dual-render.md` for the opt-in contract.
///
/// A case names a region whose mode the switch can change **while that region is on screen**. A
/// region that only ever exists inside another region's native card is that region's sub-region and
/// inherits its mode — it is not a case (`t_7ffa9e76`,
/// `docs/t_7ffa9e76-threads-surface-retirement.md`; the thread pane under `.channelView` is the
/// first, and the rule is checked by gate 11 of `scripts/verify-dual-render-gates.sh`).
public enum Surface: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Login / auth flow. SSO/OAuth still runs inside the webview (the IdP hand-off), while the
    /// sign-in form, the MFA step and the expiry banner are the native S01/S02/S03 cards — native by
    /// default since the T31-AV approval (T31-R).
    case auth
    /// Left channel/team sidebar — the T32 team rail plus the T33 channel list. Native by default
    /// since the owner approved the surface on 2026-10-27 (`t_c93b8337`, scope A): T33-AV2 passed
    /// with findings and explicitly deferred the flip, so the sign-off is the owner's.
    case sidebar
    /// The main channel view: channel header + post list. This is the surface the single
    /// per-server WKWebView pane maps to in the current Path A shell, and — since the 2026-10-27
    /// owner decision (`t_c93b8337`, scope A) — the one pane-owning surface: its native card
    /// replaces the per-server webview instead of being painted over it.
    case channelView
    /// The message composer (new post). Native by default with the 2026-10-27 workspace flip: the
    /// pane the flip approves draws the composer *inside* it, so a `web` composer there would be a
    /// dead placeholder over a released webview (see the ledger entry below).
    case composer
    /// Global / in-channel search.
    case search
    /// The user's own profile.
    case profile
    /// Mentions / activity list.
    case activity
    /// Settings. The shell's settings are already a native SwiftUI `SettingsView`.
    case settings
    /// Channel info / members panel.
    case channelInfo
    /// Mattermost Calls.
    case calls
    /// Plugin surfaces (Boards, Playbooks, custom slash-apps).
    case plugins

    public var id: String { rawValue }

    /// Human-readable title for the Surface inspector (debug-only).
    public var title: String {
        switch self {
        case .auth: return "Auth / Login"
        case .sidebar: return "Sidebar"
        case .channelView: return "Channel view"
        case .composer: return "Composer"
        case .search: return "Search"
        case .profile: return "Profile"
        case .activity: return "Activity"
        case .settings: return "Settings"
        case .channelInfo: return "Channel info"
        case .calls: return "Calls"
        case .plugins: return "Plugins"
        }
    }
}

/// How a `Surface` renders right now. The switch is binary: the webview, or a native screen.
public enum SurfaceRenderMode: String, CaseIterable, Codable, Sendable {
    /// The webview renders this surface (the web app — Path A fallback).
    case web
    /// A native SwiftUI screen card renders this surface (Path B).
    case native
}

/// Compile-time render defaults, including the native-by-default approval registry.
///
/// This is the **single structural gate** that prevents a screen card from silently shipping
/// native-by-default: a surface is `native` *by default* only if it is listed in
/// `nativeApprovedSurfaces`, and adding to that set is the one edit the paired `-AV`
/// adversarial validator audits. Everything not approved defaults to `.web`, so an unapproved
/// card can never take its surface native without the validator seeing the change.
public enum SurfaceDefaults {

    /// Surfaces whose native screen card has passed its `-AV` adversarial validation.
    ///
    /// **Approval ledger** (each entry is one `-AV` sign-off — plus, for the workspace surfaces, the
    /// owner's explicit product decision that a `-AV` verdict deliberately deferred, or the
    /// pane-ownership requirement that decision created — and the doc row it cites):
    ///
    /// | Surface | Approved by | Evidence |
    /// |---|---|---|
    /// | `.auth` | T31-AV (`t_c57a7551`, verdict `PASS-WITH-FINDINGS`, F8 = approve) | `docs/t31r-patch-note.md` §5; findings F1–F4 repaired by T31-R before the flip was treated as final |
    /// | `.calls` | T44d-AV (`t_466e8e90`, verdict `PASS-WITH-FINDINGS`) | `docs/t44d-build-note.md` §4/§7 (`build/logs/t44d-av-live1.log`: 2/2 live tests, `** TEST SUCCEEDED **`), `docs/parity.md` T44d row; reachability caveat recorded there — the entry point only mounts inside a native pane, and that pane is now `.channelView` (approved below) |
    /// | `.sidebar` | T33-AV2 (`t_8c99e10a`, verdict `PASS-WITH-FINDINGS`) **+ owner decision 2026-10-27** (`t_c93b8337`, scope A; gate `t_4413b7b2`) | `docs/t33r2-build-note.md` §3/§6 — T33-AV2 closed with "the flip itself stays a separate decision", so the validator never granted it; the owner's approval, recorded on this card, is the sign-off |
    /// | `.channelView` | T34-AV (`t_1ca87edd`, verdict `PASS-WITH-FINDINGS`; F1 repaired by `t_cf23dcd7`) + T55-AV-R (`t_6059f7ce`, no FAIL on the five repaired regions the pane hosts) **+ owner decision 2026-10-27** (`t_c93b8337`, scope A) | `docs/t34r5-build-note.md` §5 (F1 repair runs); `docs/t55-revalidation-build-note.md` §3/§6 (`.threads` PASS, reactions PASS-WITH-FINDINGS, attachments PASS, `.search` PASS-WITH-FINDINGS, `.channelInfo` PASS — the AV debt T34-AV said had to clear first) |
    /// | `.composer` | T35-AV (`t_3042a50f`, verdict `PASS-WITH-FINDINGS`; repair `t_e7eeaa46`) — **repair, not a flip grant** — plus the pane-ownership requirement of the same 2026-10-27 scope-A decision (`t_c93b8337`): the release the flip is for asserts "composer is native" (`t_9928d203` step 4) | `docs/t35-build-note.md`; without this entry the approved pane draws the dead `"Message input — web (S14/T35)"` placeholder (`ChannelView.composerPlaceholder`) while `.channelView` is pane-owning, i.e. a read-only workspace. The composer mounts nowhere outside the pane, so the entry is pane-local |
    ///
    /// Everything not listed here defaults to `.web`, so an unapproved card can never ship its
    /// surface native. A card flips its own surface to native-by-default by appending its rawValue
    /// **after** its `-AV` card has passed, in its own clearly-labelled commit — that exact diff is
    /// what the next validator audits (`scripts/verify-dual-render-gates.sh` gate 5 fails on a
    /// non-empty registry unless `--allow-approved-registry` accompanies the approval commit).
    public static let nativeApprovedSurfaces: Set<Surface> = [.auth, .calls, .sidebar, .channelView, .composer]

    /// **Catalogue reservations**: a name a future card can key on, with **no host and no switch
    /// today** — production code consults none of these, so their mode changes nothing on screen.
    ///
    /// Gate 11 of `scripts/verify-dual-render-gates.sh` requires every `Surface` case to be
    /// consulted (`resolvedMode(for: .<case>)`, `SurfaceHost(.<case` or `defaultMode(for: .<case>)`
    /// in `Mattermost/`), to be `paneHostSurface`'s value, **or** to be listed here. So a case can
    /// only stay inert by being *declared*, and growing this set is a deliberate act: the literal is
    /// pinned to `[.settings, .plugins]` and changing it needs `--allow-unhosted-change` (the same
    /// shape as gate 5's `--allow-approved-registry`).
    ///
    /// Members, each with its reason row in `docs/dual-render.md` §11: `.settings` — the shell's
    /// `SettingsView` is presented unconditionally (`RootView.swift:180,229`) and the web app's
    /// settings modal has no host of its own; `.plugins` — S29-S32 are permanently web by decision
    /// (`docs/dual-render.md` §1), so the key can never resolve `native`. Both are retired by
    /// `docs/t_39ea6115-surface-catalogue-dispositions.md` (card `t_6d420e01`); this set is what
    /// keeps the gap visible until that card lands.
    public static let unhostedSurfaces: Set<Surface> = [.settings, .plugins]

    /// Surfaces whose native card renders the *entire* per-server work area — every region the
    /// one-per-server WKWebView paints (sidebar, channel header, post list, composer, RHS).
    ///
    /// `.channelView` is the only entry, and it is the stronger half of the 2026-10-27 owner
    /// decision (`t_c93b8337`, scope A): without it the pane host would resolve native while the
    /// webview stayed alive underneath, which is the "native shell painted over a live WKWebView"
    /// bug class. `paneOwningSurfaces ⊆ nativeApprovedSurfaces` is enforced by
    /// `scripts/verify-dual-render-gates.sh`; appending here is an `-AV` claim, not a build flag.
    ///
    /// Pane ownership is the *third* condition of the webview release policy
    /// (`docs/dual-render.md` §12.1): a surface may only trigger `ViewStore.release(...)` when its
    /// native card really replaces the webview, which is a stronger claim than "a screen card
    /// renders this region" and therefore stricter than `nativeApprovedSurfaces` — the subset
    /// check in the gate script is what keeps the two from drifting.
    public static let paneOwningSurfaces: Set<Surface> = [.channelView]

    /// The surface whose native branch takes the webview's place — the region the single
    /// per-server `WKWebView` maps to, and therefore the surface the release policy watches.
    ///
    /// Named once here so no view or store hard-codes `.channelView` (the resolver's `-surfaceMode`
    /// tests and `ContentView`'s `SurfaceHost` both read this). Reassigned only by a card that moves
    /// the pane host, which is a structural change, not a per-surface decision.
    public static let paneHostSurface: Surface = .channelView

    /// Launch-argument alias for `paneHostSurface` (T30).
    ///
    /// The T30 card's acceptance criterion spells its flag `-surfaceMode shell=native`, because the
    /// thing that card mounts is the *shell* — the native equivalent of the whole workspace chrome
    /// (sidebar + channel view + threads), which is exactly what the pane host surface maps to. The
    /// alias exists so that flag works as written, and it is **launch-only**: there is no
    /// `Surface.shell` case (the 11 surfaces are the inventory-driven render regions, and a "shell"
    /// region would duplicate `channelView` in the inspector, in `mm.surfaceModes`, and in the
    /// approval registry). It is parsed in the DEBUG-only launch tier (`parseLaunchOverrides`), so
    /// it cannot steer a Release build — same rule as every other launch override.
    public static let paneHostAlias = "shell"

    /// The render mode a surface falls back to when no debug override and no remote/config
    /// default applies.
    public static func defaultMode(for surface: Surface) -> SurfaceRenderMode {
        nativeApprovedSurfaces.contains(surface) ? .native : .web
    }
}

/// Whether a pane that draws posts offers the author-profile popover.
///
/// A profile popover is **not a surface of its own**: it is part of the pane it is anchored in, and
/// it can only be reached through the rows that pane draws. The `.profile` surface answers a
/// different question — "does this build ship a native profile *card*" — and T41's card resolved it
/// `web` (it is not in `nativeApprovedSurfaces`), which made `ChannelView` remove the author tap
/// entirely. That reasoning only holds while the webview still paints the conversation. It does not:
/// `.channelView` is pane-owning (`paneOwningSurfaces`, `docs/dual-render.md` §12), so while the
/// pane is native there is no web conversation on screen and the web client's own popover cannot
/// answer a tap the reader makes on a native row. The reported defect was exactly that state — the
/// reader got neither popover.
///
/// So the tap belongs to the host that draws the row, not to `.profile`. The parameter is the **row
/// host**: how *that* view's surface resolved — `SurfaceDefaults.paneHostSurface` for the channel
/// timeline, and each list host's own mode (`t_07216319`, `t_2fa3bbe1`):
///
/// | row host | `.profile` | author tap |
/// |---|---|---|
/// | native | web | **offered** — the reported regression; no web popover exists to answer it |
/// | native | native | offered |
/// | web | web | not offered — the webview draws those rows and its own popover answers the tap |
/// | web | native | not offered — no native row exists to anchor a popover to |
///
/// A **non-channel** example, because the rule is not about the pane: the search results list
/// (`Search/SearchView.swift`) and the mentions inbox (`Activity/MentionsView.swift`) draw their own
/// rows, so their own resolution is the input — while the channel pane passes how the pane host
/// resolved. The reference is the view that draws the post, whatever surface it belongs to.
///
/// The thread pane is the one host whose input is a **fact rather than a resolver read**: nothing in
/// `Mattermost/` consulted `resolvedMode(for: .threads)` (finding F1 of
/// `docs/t_8f9f5449-profile-popover-parity.md`, now retired — see
/// `docs/t_7ffa9e76-threads-surface-retirement.md`), so the resolver answered `web` for `.threads`
/// while `ThreadPostListView` drew every row natively.
///
/// `.profile` is deliberately read and ignored: keeping it in the signature is what lets the truth
/// table above be pinned by a test instead of living in a comment.
public enum ProfilePopoverPolicy {

    /// The avatar/name tap on a post row.
    ///
    /// - Parameters:
    ///   - rowHost: how the surface that **draws** this row resolved (`SurfaceDefaults.paneHostSurface`
    ///     for the channel timeline, `.native` as a fact for the thread pane — see F1).
    ///   - profileSurface: how `.profile` resolved. **Not consulted** — see the table above.
    public static func offersAuthorTap(rowHost: SurfaceRenderMode,
                                       profileSurface: SurfaceRenderMode) -> Bool {
        switch (rowHost, profileSurface) {
        case (.native, _): return true
        case (.web, _): return false
        }
    }
}