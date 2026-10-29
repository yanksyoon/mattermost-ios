# The author's name and avatar opened nothing — the popover belonged to `web`

Card: `t_42968927` (reported by the owner against the installed native build).
Tree: `main` @ `627f842` + this card's working tree. Verified on the local throwaway server
(Mattermost 9.11.19, `127.0.0.1:8065`, accounts `perfprobe` + `t41buddy`) on `iPhone 17 Pro /
iOS 26.5` (simulator).

## 1. What the reader saw

Tapping a person's name or picture in the chat opened nothing. Two independent causes, both
confirmed in the code before any change:

1. **The surface gate.** `ChannelPaneContent` decided whether a post's author is tappable from
   `resolver.resolvedMode(for: .profile) == .native`. `.profile` is **not** in
   `SurfaceDefaults.nativeApprovedSurfaces`, so it resolves `web` by default and `onShowProfile` was
   passed as `nil` — `PostRowView` then drew a plain avatar with no button and no name affordance.
   The comment justified that with "the webview's own profile popover is the only one on screen".
   That was true before the 2026-10-27 workspace flip; it is false now. `.channelView` is
   **pane-owning** (`SurfaceDefaults.paneOwningSurfaces`), so while the pane is native the webview is
   not painting the conversation at all. The reader got neither popover, which is exactly the report.
2. **The name was not an affordance.** Only the avatar was wrapped in a `Button`; the author's name
   was plain `Text`. Upstream (webapp `components/profile_popover`, mobile
   `app/screens/user_profile`) makes both the avatar and the username open the popover.

## 2. The decision: the tap belongs to the pane, not to `.profile`

Two candidate fixes were on the card. **Taken: the first** — make the tap a property of the pane
host, not of `.profile`'s own resolution. The choice, and why the other was rejected:

* A popover is **part of the pane it is anchored in**. It can only be reached through the rows that
  pane draws, and it is answerable only by whatever is painting those rows. The fact that this build
  does or does not ship a native profile *card* (`.profile`) is a different question.
* Adding `.profile` to `SurfaceDefaults.nativeApprovedSurfaces` would have made the tap work, but it
  is an `-AV` approval claim about a *whole native surface* — and this sheet is not upstream's
  popover: it is the full profile screen (position, email, joined, last active) plus the popover's
  actions. Making it native-by-default for every reader is a product decision that belongs to an
  `-AV` card and an owner sign-off (the registry's own ledger says so), not to a tap bug.

The rule is a pure function, `ProfilePopoverPolicy.offersAuthorTap(paneHost:profileSurface:)` in
`Mattermost/Core/RenderMode.swift`, so the truth table is a unit test rather than a comment:

| pane host | `.profile` | author tap |
|---|---|---|
| native | web | **offered** — the reported state; no web popover exists to answer it |
| native | native | offered |
| web | web | not offered — the webview's own popover is the one on screen |
| web | native | not offered — no native pane is mounted, nothing to anchor to |

The same gate now also governs the pane header's own profile control (`nativeProfileButton`): it was
hidden by the same `.profile` check while the pane was native, i.e. the signed-in account's profile
was unreachable from the centre pane on the shipped defaults. That is the same defect one control
over, and it is covered live.

## 3. The repair

| file | change |
|---|---|
| `Mattermost/Core/RenderMode.swift` | `ProfilePopoverPolicy` — the pure rule above, with the truth table in its doc comment |
| `Mattermost/UI/Native/Channel/ChannelView.swift` | `profileSurfaceIsNative` → `offersAuthorProfile` (pane host + `.profile`, feeding the policy); rows and the header avatar both use it; `@State profileTarget` → `ProfilePopoverState` |
| `Mattermost/UI/Native/Channel/PostRowView.swift` | `authorName`: the name is a `Button` calling the **same** `onShowProfile` closure as the avatar when the host supplies one, and inert text when it does not; `post.<id>.author` remains the identifier |
| `Mattermost/UI/Native/Profile/ProfileView.swift` | `ProfilePopoverState` — the pane's one-slot presentation (a tap re-aims, dismissal empties); the action stack is driven by `ProfileActionSet` instead of three ad-hoc conditions |
| `Mattermost/UI/Native/Profile/ProfileModels.swift` | `ProfileAction` + `ProfileActionSet.resolve(profile:myUserID:hasCustomStatus:)`, the permission matrix |
| `Mattermost/UI/Native/Profile/ProfileViewModel.swift` | `actions`, the set the screen draws |

one popover at a time: the pane keeps a single `ProfilePopoverState` bound to one `.sheet(item:)`, so
the header avatar and every row share one presentation slot and a second tap re-targets it rather
than stacking a second sheet. That is structural (SwiftUI can only present one sheet per slot), and
the state machine itself is unit-tested.

## 4. The action set against upstream — the audit the card asked for

Upstream's popover can draw six things. This is what this build offers now, per viewer:

| upstream row | this build | why |
|---|---|---|
| **Message** (opens/creates the DM) | ✅ `[.message]` for another member or a bot; absent with a stated reason for my own profile and for a deactivated account | `DMShortcut` (T41), now surfaced through `ProfileActionSet`; the write path is `POST /channels/direct`, live-tested by T41 |
| **Set a status / custom status / clear it** | ✅ `[.setStatus, .customStatus(.clearCustomStatus)]` on my own profile only | T41's setter and editor, unchanged |
| **Call** (when Calls is enabled) | ❌ absent | there is no per-user call path: `CallsCoordinator.startCall` takes a **channel**, so a "Call this person" row would have to create the DM, join a call in it and own the full-screen surface — a write path with no live coverage here. Not faked. |
| **Add to channel** (with the channel permission) | ❌ absent | the permission lives on `ChannelInfoCapabilities` and the write on `ChannelInfoViewModel.addMembers`; a popover row would need the pane's channel + capability injected into the sheet, and the card does not name the host pane's channel as in scope |
| **Invite to team** (with the team permission) | ❌ absent | no team-invite API path exists in this build at all |
| **Manage / Edit** (a system admin acting on another user) | ❌ absent | there is no user-administration screen in this build to open |

Absent, not drawn disabled: a row that cannot work is worse than no row. The four gaps are stated
here, in the parity row, and in `ProfileActionSet`'s doc comment, so the next card that adds one has
the reason it was missing rather than a silent hole.

Wording: the sheet's button stays **"Send message"**, not upstream's popover "Message". `DMShortcut`
documents the distinction (upstream's *popover* says "Message", its *full profile screen* says "Send
message") and this sheet is the full profile screen — name, position, email, joined, last active —
which is what T41 shipped and what the T41 build note records. Changing the copy alone would not
make it the desktop popover.

## 5. Evidence

Unit — `MattermostTests/T429ProfileTapTests.swift`, 9 tests. The **whole unit target** on the final
tree: **1788 run / 8 skipped / 0 failed** (`build/logs/t429-units-final.log`); the focused run of
`T429ProfileTapTests + T41ProfileTests + SurfaceModeResolverTests + T34PostListTests` was
**139 run / 0 failed** (`build/logs/t429-units.log`).

* the truth table above, all four cells;
* **the regression at the real decision point**: a resolver built from the shipped defaults (no
  flags, no stored overrides) resolves `.channelView` = native and `.profile` = web, and the tap is
  offered — the exact pair the reader was in;
* `-surfaceMode shell=web` takes the tap off again;
* `ProfilePopoverState`: present → present another → one target, re-aimed; dismiss → empty; present
  again works;
* the action matrix: another member = `[.message]`, own profile = `[.setStatus, .customStatus]`
  (+ `[.clearCustomStatus]` when set, with "This is your own profile." as the message reason),
  deactivated = `[]` with the deactivation sentence, bot = `[.message]`, no resolved account =
  `[]` with a reason.

Live — `MattermostUITests/T429ProfileTapUITests.swift`, against the running 9.11.19 server,
**4 run / 0 skipped / 0 failed** (`build/logs/t429-live-ownchannel.log`,
xcresult `…/TestResults/t429-live-ownchannel-e0aa58.xcresult`; the first green run on the same tree
was `build/logs/t429-live.log`, 156 s):

```
testTappingTheAvatarOpensThatAuthorsProfile            passed (23.7 s)
testTappingTheAuthorNameOpensTheSameProfile            passed (25.7 s)
testBothAffordancesOpenOnePopoverAtATime               passed (31.4 s)
testThePanesOwnProfileEntryIsOfferedWhileProfileResolvesWeb  passed (23.2 s)
```

The suite launches **without** `-surfaceMode profile=native` on purpose: T41's suite passes that flag,
which is exactly what hid this defect. Each test ensures its **own** channel (`#t429-tap`, created on
first run, with `t41buddy` added as a member), posts a fresh message **as `t41buddy`** (with a
separator post from `perfprobe` first, so the buddy's row is not a grouped row and therefore really
has a header), opens the channel through the quick switcher, and asserts the sheet's `@username`
equals the **server's** value for the tapped post's author.

### 5.1 A fixture collision this card caused, and repaired

The first version of the suite posted its fixture into **T41's** `#t41-profile`.
`T41ProfileUITests.testSendMessageOpensTheDirectChannelWithTheAuthor` then failed
(`build/logs/t429-t41-dm.log`: "the buddy's post must be on screen to tap"): four tests × two posts
per run pushed T41's own seed post to **position 38 of 41** in the newest-first page, i.e. far above
the pane's visible window, so its avatar was not in the lazy list at all. Measured, then repaired:
the 24 residue posts were soft-deleted (`…/scratch/t429_cleanup.py`, reads the channel's newest 200
and deletes exactly the `t_42968927 …` messages), the suite now uses `#t429-tap`, and T41's test is
green again on the same server (`build/logs/t429-t41-dm2.log`, 1 run / 0 failed).

Screenshots, exported from the run's own attachments (mid-presentation, which is why the sheet is
translucent): `~/.hermes/profiles/mmios-ios/cache/scratch/t429-shots/` — `t429-name-tap`,
`t429-avatar-tap`, `t429-one-popover`, `t429-header-profile`. The name-tap frame shows
`Buddy Profile / @t41buddy / Online / Email / Local time / Activity / Member` over the channel.

T41's own live suite was spot-checked against the refactored action rows, because its assertions are
the ones the `ProfileActionSet` change could break: `testProfilePopoverShowsTheServersOwnIdentity`
(own profile — no Message row, a reason instead) `build/logs/t429-t41-identity.log` **1/1**,
`testSendMessageOpensTheDirectChannelWithTheAuthor` (another member — the Message row, live DM)
`build/logs/t429-t41-dm2.log` **1/1**, and `testPresenceFollowsAnotherClientsChangeWhileTheProfileIsOpen`
(the sheet open while the server changes presence) `build/logs/t429-t41-presence.log` **1/1**. In the
combined `T41 + T429` run four T41 tests passed (background auto-away, DND, custom status, my own
presence through the socket) and then the presence test **wedged** for 20 minutes in
`revealSidebarRow`'s sidebar swipe (`build/logs/t429-live-final.log`: `App event loop idle
notification not received` at `t = 1476.60s` while looking for
`channelSidebar.channel.<id>`). The same test passes solo in 90 s, it never reaches the profile code
before the tap, and it has nothing to do with this change; it is recorded here as an observed harness
hazard (the fixture sidebar on this server is thousands of rows tall — see `T70AuthorNamesUITests`,
which uses the quick switcher for exactly that reason) rather than as a regression.

**Red on the pre-fix shape** (the evidence that the tests detect the defect rather than the fix):
with the product files reverted and only the UI test present,
`build/logs/t429-prefix.log` = **4 run / 8 failed**, every test failing on its first assertion —

```
T429ProfileTapUITests.swift:115 the author's avatar must be an affordance on the shipped defaults
T429ProfileTapUITests.swift:148 avatar affordance missing
T429ProfileTapUITests.swift:173 the pane header must offer the signed-in profile
T429ProfileTapUITests.swift:189 the profile sheet must mount      (name tap)
```

## 6. What is still not covered

* **The other hosts upstream offers the popover in.** `ThreadView` (`RHS`), `SearchView`,
  `MentionsView` and `SavedPinnedViews` all draw `PostRowView` but pass no `onShowProfile`, so their
  author names and avatars are still inert. They are separate panes with their own sheets, so each
  needs its own presentation slot and its own live coverage; the rule to apply is the same
  (`ProfilePopoverPolicy` on the pane host), and they are named in the parity row so this is a
  recorded gap rather than an accident.
* **The grouped-row case.** A grouped row has no header by definition, so there is no name and no
  avatar to tap — upstream behaves the same way (`only the first post in a run carries the header`).
  The live test deliberately posts a separator so it is not testing a row that cannot have a header.
* **Deactivated accounts live.** The empty action set is unit-pinned; no fixture account on this
  server is deactivated, and deactivating one would change every other card's fixture.
* **Dismissal is a sheet's, not a popover's.** The card lists upstream's dismissal set — outside
  click, Escape, a second tap. T41 shipped this surface as a medium-detent **sheet**, and this card
  did not change the presentation: Done (a `profile.done` button), a downward swipe, and Escape on a
  hardware keyboard dismiss it; there is no outside tap or second tap to dismiss, because the sheet
  covers the row that was tapped. Making it an anchored popover is a T41 presentation change, not a
  tap fix, and it is not attempted here.
