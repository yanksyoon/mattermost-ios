# T95 — the phone shell's tab bar in a channel: decision (keep the push), and the launch fix

Card: `t_95a14431` (architect). Date: 2026-10-27. Status: **decided**; implementation carded to
`mmios-ios` (§6). Evidence: `docs/t95-upstream-layout-evidence-2026-10-27.log` (every quoted line,
re-checkable), `docs/t39-r2-build-note.md` §4.1 + §6 F-1, `docs/t39-r2-evidence-2026-10-27.log` §6.

---

## 1. The question, and the correction

As filed: on the **phone** layout a pushed channel covers the tab bar, so `Search`, `Saved` and
`Recent mentions` cannot be reached while a channel is open; the reader must go Back first. The
card's premise is that upstream keeps the tab bar — "its `TabView` wraps the stacks (each tab owns
a stack)" — and asks for (a) per-tab stacks or (b) a channel presentation that leaves the bar.

**That premise is wrong for the pinned upstream, and inverted.** Upstream's Stack wraps the Tabs,
not the other way round, and the bottom tab bar is *designed* to leave the screen when a channel
opens on a phone:

* the design of record (Mattermost "Mobile v2 Design" → **Bottom Tab Bar** → *Hiding the Bottom Tab
  Bar in Channels*): "Once a user is within a channel, the bottom tab bar slides off the bottom to
  save room for the channel content and the Message Input component. **For Tablets, however, the
  bottom tab remains at all times** since channels are in view at the same time as the sidebar."
* the pinned code (`mattermost-mobile` v2.45.0 = `162f2560`, the `M` pin in `docs/component-map.md`):
  `app/routes/(authenticated)/_layout.tsx` is a `Stack` whose only declared screen is `(home)`;
  `app/routes/(authenticated)/(home)/_layout.tsx` is the `Tabs` navigator (channel_list, search,
  mentions, saved_messages, account); `app/routes/(authenticated)/channel.tsx` — `channel` — is a
  **sibling route of `(home)` in that Stack**. `app/screens/navigation.ts:31-51` sends tab screens to
  `/(authenticated)/(home)/<screen>` and everything else, `channel` included, to
  `/(authenticated)/<screen>`; `navigateToScreen` opens it with `router.push` (`:62-77`). So a channel
  is a screen pushed **above** the tab navigator, which is exactly why the phone channel header has
  its own back chevron (`app/screens/channel/header/header.tsx:154-157, 343`).
* the pinned `app/screens/home/tab_bar/index.tsx` is only the bar *component*; its `TAB_BAR_VISIBLE`
  animation is driven by the header search field, not by channels (only emitter:
  `app/components/navigation_header/search.tsx:56`).

So the measurement in the card — a pushed `nativeChannelPane` with a `Back` button and no `TabBar`
node — is **upstream-parity behaviour, not a defect**. What was actually wrong is the *test's*
assumption that the bar is always on screen (a real harness defect, fixed in T39-R2 by popping back
first).

**Retraction:** the product claim in `docs/t39-r2-build-note.md` §6 F-1 ("upstream keeps the tab
bar", "does not fix the UX") and the matching doc comment in `T39JumpUITests.swift` /
`T39SearchUITests.swift` (`openSearch`) are withdrawn. `docs/t39-r2-build-note.md` is another card's
record and is not rewritten here; the correction is this document (§6 card A fixes the two comments).

---

## 2. Decision D1 — keep the shell's structure; do not move the stack into the tabs

**Rejected: (a) per-tab `NavigationStack`s.** Not upstream's shape: it would leave the tab bar on
screen inside a channel, i.e. a *visible* deviation from the pinned client, and it needs a second
navigation model (per-tab path storage) for a behaviour upstream does not have.

**Rejected: (b) a channel presentation that does not cover the tab bar** (sheet, half-height pane,
inset presentation). Same objection plus an invented interaction: upstream's channel is a plain push
on phone and the tab bar is intentionally gone.

**Kept:** `RootView`'s `NavigationStack` above the `TabView` (`Mattermost/UI/RootView.swift:93-131`,
`Mattermost/UI/Native/NativeShellView.swift:14-40, 192-233`) — the compact layout pushes a channel,
the regular layout renders the same value in the detail column and never pushes.

Consequences, stated so nobody re-opens them as bugs:

| thing | outcome |
|---|---|
| `NativeNavigation.path` | unchanged — one compact push stack above the tabs (`NativeNavigation.swift:319-322`), one writer (`apply`), one rendered value (`location`). No per-tab stacks, no per-tab path memory. |
| deep links / notification taps | unchanged. They push on compact (`apply` → `path = [newLocation]`, `:590-623`) and select the detail column on regular. Upstream does the same: `router.push('/channel')` on phone, `AdditionalTabletView` swapping the detail on tablet. |
| tab reachability from an open channel | Back, then the tab — the reader's own path on upstream too. Tab-bar taps are an entry point **from the channel list**, not from a channel. |
| the T39-R2 helper pattern (`returnToSidebar` → tap the tab) | correct and stays; it does what a reader does. It is not a workaround for a product defect. |
| a future "keep the tab bar in a channel" change | an explicit deviation card with a stated reason, not a bug fix. Upstream's design doc is the citation to beat. |

---

## 3. Decision D2 — `LaunchDestination`: restore the last channel, stop inventing a town hall

Upstream's cold-start policy (`app/init/launch.ts:245-262`, then `:290-294`) is layout-independent
and has exactly two branches before giving up: the **last thread**, else the **last channel**; if
neither exists it sets `HOME` and routes to `/(authenticated)/(home)` — the channel list with its tab
bar. There is **no** town-hall or "first channel" fallback.

Our shell does restore the last channel (`LaunchDestination.request(saved:)`) but then falls back to
the team's town hall, then to the first non-DM channel
(`NativeNavigation.swift:807-849`, `ChannelSidebarCoordinator.applyLaunchDestinationIfNeeded`,
`Native/Sidebar/ChannelSidebarCoordinator.swift:172-196`). So:

* **keep** the last-channel restore on **both** layouts (upstream restores it on both);
* **remove** the town-hall → first-channel fallback. On compact, a launch with nothing saved lands on
  the channel list (tab bar present); on regular, on the split view with an empty detail — upstream's
  tablet renders the Channel screen with no current channel in the same situation, and our
  `NativeEmptyDestinationView` is the honest equivalent of "nothing selected yet".

**This also removes the UI-test race at its cause.** `-uiTestResetPersistedState` removes the whole
`UserDefaults` persistent domain (`Mattermost/MattermostApp.swift:115-127`), which includes
`LastChannelStore`'s `mm.native.lastChannel`. Every reset launch therefore had `saved == nil`, so the
town-hall branch opened a channel as soon as the channel directory arrived and the push raced the
first tab tap — the measurement in the card. With D2 the same launch is deterministic: no saved
channel, tab bar on screen.

Cost, stated rather than discovered later: `MattermostTests/LastChannelLaunchTests.swift` loses its
town-hall expectations, and suites that relied on the implicit push (T34 waits on `channelPostList`
straight after launch — `T34-ChannelPostListUITests.swift:188, 307, 456, 575`) must open a channel
like a reader. Both are in card A/B (§6); no suite may be "fixed" by re-adding the fallback.

**Not in scope, recorded as deviations:**

| id | deviation from the pinned upstream | why it stays for now |
|---|---|---|
| D-1 | the **regular** (iPad/Mac) layout has no bottom tab bar; upstream's tab bar stays on tablet at all times (design doc §1). Ours renders `NavigationSplitView` + three toolbar buttons for Search / Saved / Mentions (`NativeShellView.regularLayout`, T39/T42). | the root-view split idiom has no tab position in SwiftUI without wrapping the split view in a `TabView`; the toolbar buttons are reachable and tested. Revisit only if a Pad parity audit asks for the bar — it is a card of its own, not a phone bug. |
| D-2 | upstream restores the last **thread** before the last channel (`launch.ts:250-255`); `LaunchDestination` has no thread branch. | separate parity gap; needs the thread route restored through `openThreads`, not a launch-policy edit. Card it from the parity table, not from here. |

---

## 4. What the parity table says now

`docs/component-map.md` §1.1 (added by this card) records the shell layout as **mapped**: compact =
tabs + push, the push covers the bar on purpose; regular = split view + detail column. S08/S11/S19/
S20/S25 each gain one line saying where their screen is reached, so "unreachable from a channel" is
not re-filed as a defect.

`docs/parity.md` is the desktop-module table and is untouched: no desktop module changed (the row it
would touch — `TabManager` → mounted scenes — already maps the navigation model).

---

## 5. Evidence index

* `docs/t95-upstream-layout-evidence-2026-10-27.log` — the tag→commit check, the design-doc quote,
  and the ten pinned-tree excerpts (`authenticated/_layout`, `(home)/_layout`, `channel.tsx`,
  `navigation.ts`, `screens.ts`, `channel/header/header.tsx`, `home/tab_bar/index.tsx`,
  `navigation_header/search.tsx`, `init/launch.ts`, `detox/maestro/…/attach_logs.yml`) with line
  numbers.
* `docs/t39-r2-build-note.md` §4.1 (the harness defect) and §6 F-1 (the claim withdrawn here).
* `docs/t39-r2-evidence-2026-10-27.log` §6 (the accessibility-tree measurement).
* `Mattermost/UI/Native/NativeShellView.swift:14-40, 192-233`; `Mattermost/UI/RootView.swift:93-131`;
  `Mattermost/Core/Native/NativeNavigation.swift:807-849`;
  `Mattermost/UI/Native/Sidebar/ChannelSidebarCoordinator.swift:166-196`.

---

## 6. Implementation cards filed (assignee `mmios-ios`)

**A — launch policy parity + the comments that call parity a bug.** Product code:
`LaunchDestination` loses the town-hall/first-channel branch (delete `townHallNames`,
`townHallAvailable`, `fallbackChannelID`, and their call sites in `ChannelSidebarCoordinator`);
`LastChannelLaunchTests` drops the town-hall cases and gains "nothing saved → no request" and
"a saved channel that is gone → no request". Comments corrected: `NativeShellView`'s layout decision
(why the push covers the bar, citing the design doc + route tree), `LaunchDestination`'s header
(the town hall is not upstream's behaviour), the two `openSearch` doc comments in T39's suites.
New UI test: a compact launch with nothing saved shows the tab bar (no `nativeChannelPane`); opening
a channel replaces the bar with `Back`, and `Back` brings the bar back — that is the parity
assertion, and it falsifies a future "keep the tab bar" regression in the right direction.

**B — the suites that relied on the implicit town-hall push** (child of A, so they land in order).
Every suite that launches the native shell and waits on a channel pane without opening a channel
now opens one (T34 is the known case; audit T33/T36/T40/T42/T47/T48 the same way), and every suite
that taps a tab uses one settle helper — "tab bar, or `Back` then tab bar" — instead of a bare
`app.tabBars.buttons[...].tap()`. Acceptance: the full UI suite green on one tree, with the town-hall
branch gone, and no test that passes only because a channel was pushed for it.
