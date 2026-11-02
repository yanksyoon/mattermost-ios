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
///
/// A case must also be a **switch**: flipping it must be able to change what is on screen in at least
/// one direction. A key with one legal state is not a switch, even when a call site reads it
/// (`docs/t_39ea6115-surface-catalogue-dispositions.md` §1.1 — `.plugins` had no native form and no
/// possible `native` mode; `.settings` was shell chrome with no web form of its own; `.profile` was
/// read and discarded and the sheet is a sub-region of the row host). All three are retired, as is
/// `.threads` above: the catalogue is eight cases and each one has a mode that changes a screen.
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
    /// Global / in-channel search (S19), plus Saved (S20) and a channel's pinned posts (S21), which
    /// are the same list over a different source. Native by default since the `t_aa211ff6` flip:
    /// T39-AV failed, T39-R repaired, and T55-AV-R passed `.search` with findings
    /// (`docs/t_aa211ff6-lookup-surface-defaults.md` §3/§4).
    case search
    /// Mentions / activity list (S25). Native by default since the `t_aa211ff6` flip, on T42-AV's
    /// PASS-WITH-FINDINGS and T42-R's closure of F1–F5.
    case activity
    /// Channel info / members panel.
    case channelInfo
    /// Mattermost Calls.
    case calls

    public var id: String { rawValue }

    /// Human-readable title for the Surface inspector (debug-only).
    public var title: String {
        switch self {
        case .auth: return "Auth / Login"
        case .sidebar: return "Sidebar"
        case .channelView: return "Channel view"
        case .composer: return "Composer"
        case .search: return "Search"
        case .activity: return "Activity"
        case .channelInfo: return "Channel info"
        case .calls: return "Calls"
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
    /// | `.search` | T39-AV (`t_3c83d5e7`, **FAIL**) → T39-R (`t_37a4545b`) → **T55-AV-R (`t_6059f7ce`), `.search` PASS-WITH-FINDINGS after repair** → T39-R2 (`t_c3957991`, harness only) | `docs/t39-search-build-note.md`, `docs/t55-revalidation-build-note.md` §3/§6 (mutation-checked closures, T39 live 7/7), `docs/t39-r2-build-note.md` |
    /// | `.activity` | T42-AV (`t_af5a4d3b`, PASS-WITH-FINDINGS; findings were documentation/test-strength only) + T42-R (`t_b483a58d`, F1–F5 closed) | `docs/t42-build-note.md`, `docs/parity.md` T42 row (46 unit, 4/4 live, 4/4 again after T42-R) |
    ///
    /// Everything not listed here defaults to `.web`, so an unapproved card can never ship its
    /// surface native. A card flips its own surface to native-by-default by appending its rawValue
    /// **after** its `-AV` card has passed, in its own clearly-labelled commit — that exact diff is
    /// what the next validator audits (`scripts/verify-dual-render-gates.sh` gate 5 fails on a
    /// non-empty registry unless `--allow-approved-registry` accompanies the approval commit).
    public static let nativeApprovedSurfaces: Set<Surface> = [.auth, .calls, .sidebar, .channelView, .composer, .search, .activity]

    /// **No catalogue reservations.** This set was `[.settings, .plugins]` when gate 11 landed
    /// (`t_cdcc1f38`); `t_6d420e01` retired both cases, so every remaining `Surface` is a real switch
    /// with a production call site and there is nothing left to reserve.
    ///
    /// The mechanism stays: gate 11 of `scripts/verify-dual-render-gates.sh` requires every `Surface`
    /// case to be consulted (`resolvedMode(for: .<case>)`, `SurfaceHost(.<case` or
    /// `defaultMode(for: .<case>)` in `Mattermost/`) **or** to be the pane host's value, **or** to be
    /// listed here. That literal is pinned to `[]`; growing it — or emptying it back — is a deliberate
    /// act that needs `--allow-unhosted-change` (the same shape as gate 5's
    /// `--allow-approved-registry`), so an inert key cannot be tolerated with a one-line edit.
    ///
    /// The three cases that used to live here are retired by
    /// `docs/t_39ea6115-surface-catalogue-dispositions.md`: `.settings` was shell chrome with no web
    /// form of its own, `.plugins` could never resolve `native`, and `.profile` was read and discarded
    /// (its sheet is a sub-region of the row host). A reservation is for a name a future card will key
    /// on; none of the three could ever be keyed on again.
    public static let unhostedSurfaces: Set<Surface> = []

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
    /// `Surface.shell` case (the eight switch keys are the inventory-driven render regions, and a "shell"
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

/// Whether a row host that draws posts offers the author-profile popover.
///
/// A profile popover is **not a surface of its own**: it is part of the view it is anchored in, and it
/// can only be reached through the rows that view draws. The retired `.profile` surface used to answer
/// a different question — "does this build ship a native profile *card*" — and T41's card resolved it
/// `web` (it was never in `nativeApprovedSurfaces`), which made `ChannelView` remove the author tap
/// entirely. That reasoning only holds while the webview still paints the conversation. It does not:
/// `.channelView` is pane-owning (`paneOwningSurfaces`, `docs/dual-render.md` §12), so while the pane
/// is native there is no web conversation on screen and the web client's own popover cannot answer a
/// tap the reader makes on a native row. The reported defect was exactly that state — the reader got
/// neither popover.
///
/// So the tap belongs to the host that draws the row, and to nothing else. The parameter is the **row
/// host**: how *that* view's surface resolved — `SurfaceDefaults.paneHostSurface` for the channel
/// timeline, and each list host's own mode (`t_07216319`, `t_2fa3bbe1`):
///
/// | row host | author tap |
/// |---|---|
/// | native | **offered** — the native rows are the only ones on screen, so this sheet is the only popover |
/// | web | not offered — the webview draws those rows and its own popover answers the tap |
///
/// **The `.web` row is defensive only — the app cannot build it.** `ContentView` mounts the native
/// shell, and therefore `ChannelPaneContent`, only inside
/// `SurfaceHost(SurfaceDefaults.paneHostSurface)`, so a native row cannot exist while the pane host
/// resolves `web`. The other native row hosts are gated the same way by their own content views
/// (`SearchPaneContent`, `MentionsPaneContent` draw their lists only while `.search` / `.activity`
/// resolve native) and the thread pane passes `.native` as a fact. That cell pins the policy's answer
/// — `testAWebPaneTakesTheTapOffWithItsRows` drives it from `-surfaceMode shell=web`, where no native
/// pane is mounted by construction — not a state a reader can be in (F3 of
/// `docs/t_97162159-profile-tap-validation.md`).
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
/// **The second parameter is gone** (`t_6d420e01`, spec §4.3 of
/// `docs/t_39ea6115-surface-catalogue-dispositions.md`): it existed only to pin `.profile`'s
/// _discarded_ answer in a truth table, and once the case is retired the `native × web` cell it pinned
/// is unrepresentable. The live statement the old cell made — "a flag that does not exist cannot
/// remove the tap" — is only measurable against a running app, and `T429ProfileTapUITests` already
/// makes it on the shipped defaults with no `-surfaceMode profile=` on the launch line.
public enum ProfilePopoverPolicy {

    /// The avatar/name tap on a post row.
    ///
    /// - Parameter rowHost: how the surface that **draws** this row resolved
    ///   (`SurfaceDefaults.paneHostSurface` for the channel timeline, `.native` as a fact for the
    ///   thread pane — see F1).
    public static func offersAuthorTap(rowHost: SurfaceRenderMode) -> Bool {
        switch rowHost {
        case .native: return true
        case .web: return false
        }
    }
}