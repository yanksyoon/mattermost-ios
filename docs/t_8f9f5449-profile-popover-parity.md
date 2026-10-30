# The rest of upstream's profile popover: which hosts, which rows, how it presents

Card: `t_8f9f5449` (architecture / scope). Parent: `t_42968927` (`docs/t_42968927-profile-popover.md`
§4 and §6 left two gaps open). **This card writes no product code.** It decides, records the decision,
and creates the implementation cards.

Reference server: Mattermost **9.11.19** at `127.0.0.1:8065`, accounts `perfprobe` + `t41buddy`
(+ `t42buddy`). Upstream references this document is verified against, all fetched and read for this
card:

| what | source |
|---|---|
| webapp popover, the version the reference server serves | `mattermost/mattermost` tag `v9.11.0`, `webapp/channels/src/components/profile_popover/{profile_popover.tsx,profile_popover_other_user_row.tsx,profile_popover_add_to_channel.tsx,profile_popover_title.tsx}`, `webapp/channels/src/i18n/en.json` |
| the same tree on master (drift check only) | `mattermost/mattermost` `master`, same paths |
| webapp permission selector | `v9.11.0` `webapp/channels/src/packages/mattermost-redux/src/selectors/entities/channels.ts` (`canManageAnyChannelMembersInCurrentTeam`, l. 904) |
| webapp add-to-channel modal | `v9.11.0` `webapp/channels/src/components/add_user_to_channel_modal/add_user_to_channel_modal.tsx` |
| mobile profile sheet | `mattermost/mattermost-mobile` tag `v2.45.0` (162f2560), `app/screens/user_profile/user_profile.tsx`, `app/screens/user_profile/options.tsx`, `app/screens/user_profile/manage_user_options.tsx` |
| Calls plugin config (gate names) | `mattermost/mattermost-plugin-calls` `main`, `server/configuration.go` |

`v9.11.19` is not a published tag at that path (404 for `README.md` too); `v9.11.0` is the nearest
published tag and the file set above is unchanged on `master` except that the Call row moved behind a
`profile_popover_call_button_wrapper` import and custom profile attributes were added. Nothing in this
document depends on the difference.

---

## 1. Finding that shrinks the scope: two of the four rows are **not** upstream here

The parent card's §4 audit listed four missing rows, taken from older-webapp recollections. Read
against the version this programme actually references, only **two** of them exist:

What the **9.11.0 webapp popover** draws for somebody else (`profile_popover_other_user_row.tsx`,
71 lines, read in full):

1. **Message** — always (when the popover is for another user).
2. **Add to a Channel** — icon button, `profile_popover_add_to_channel.tsx`: drawn only when
   `canManageAnyChannelMembersInCurrentTeam && isInCurrentTeam`, where the first term is "I hold
   `manage_public_channel_members` on *some* open channel of this team, or
   `manage_private_channel_members` on some private one" and the second is "the target is a live
   member of the current team". Tapping it opens `AddUserToChannelModal` — a **channel picker**, not
   "add to this channel".
3. **Call** — the Calls plugin's own webapp button (`ProfilePopoverCallButtonWrapper`), present only
   when the plugin is loaded and the plugin's own channel gate allows a call there.

`grep -o '"user_profile[^"]*"' webapp/channels/src/i18n/en.json` (v9.11.0) returns exactly
`account.editProfile`, `account.hoursAhead`, `account.hoursBehind`, `account.localTime`,
`account.localTimeWithTimezone`, `account.post_was_created`, `add_user_to_channel`,
`call.ongoing`, `close`, `custom_status`, `custom_status.set_status`,
`roleTitle.{system_admin,team_admin,channel_admin}`, `send.dm`, `send.dm.yourself`. There is **no**
invite-to-team string and **no** manage/edit string on that surface.

What **mobile v2.45.0** draws in the profile sheet (`options.tsx`, 103 lines, read in full): *Send a
message* and, when the sheet is opened inside a channel context, *Mention*. No Call, no Add to
channel, no Invite, no Manage. `manage_user_options.tsx` is the **channel-members manage mode**
(roles / remove), a different screen reached from `channel_info`, not from a profile.

### Decisions

| row | decision | why |
|---|---|---|
| **Call** | **in scope** → card `t_296843e5` (with Add to a channel) | upstream offers it, and this build already ships the whole surface (`.calls` is `nativeApprovedSurfaces`, T44d-AV). The missing piece is a routing path, not a capability. |
| **Add to a channel** | **in scope** → same card | upstream offers it; this build has the write (`POST /channels/{id}/members`) and every read the gate needs. Shape is the **cross-channel picker**, not a per-channel row. |
| **Invite to team** | **closed — not a parity target** | not a row of the 9.11 webapp popover, not a row of mobile v2.45.0. Building it would be adding a feature this programme does not reference, and no team-invite API path exists in this build either. |
| **Manage / Edit** | **closed — not a parity target** | same: no such row in either reference. The nearest upstream equivalent is mobile's channel-members *manage mode*, which is T40's screen; this build's version has remove + role badge and no role *change* (§8, finding F3). |

**Correction to the card's own premise.** The card says the Add-to-channel sheet "would need the
pane's channel injected". It would not: upstream's row is **team-scoped** and opens a **picker**, and
the sheet already has the team through `navigation.location.teamID`. What it needs is a *permission
answer* (team-wide manage-members, and per-channel for the picker's list), which §7 specifies. Do not
inject a channel into `ProfileSheet`.

---

## 2. Hosts: one rule, one state per host, and where a presentation may legally live

### 2.1 The rule is the row's own host surface — rename the parameter

`ProfilePopoverPolicy.offersAuthorTap(paneHost:profileSurface:)` currently reads `.channelView`, which
was right for the only host that existed. Generalised: **a profile popover is answerable only by the
view that draws the row**, so the input is how *that* view's surface resolved.

```
offersAuthorTap(rowHost: SurfaceRenderMode, profileSurface: SurfaceRenderMode) -> Bool
    (.native, _) -> true
    (.web,    _) -> false
```

Rename the label `paneHost:` → `rowHost:`. Do **not** change the arity: `profileSurface` stays,
deliberately read and ignored, because the truth table is the regression pin for the parent defect
(`.profile` resolving `web` must not remove the tap). Update the four doc-comment rows to say "row
host" and name one non-channel example. Call sites: `ChannelView.swift` (`offersAuthorProfile`) plus
`MattermostTests/T429ProfileTapTests.swift` (4 cells).

Truth table after the rename (same rule, more hosts):

| row host surface | `.profile` | tap offered |
|---|---|---|
| any **native** host (`channelView`, `threads`, `search`, `activity`) | web | **offered** |
| any native host | native | offered |
| any **web** host | web | not offered — the webview draws those rows and its own popover answers |
| any web host | native | not offered — no native row exists to anchor to |

**The one host where "row host" is not a resolver answer.** `ThreadPaneContent` /
`ThreadPostListView` draw natively and *nothing consults `.threads`*: `resolvedMode(for: .threads)`
has **no call site anywhere** in `Mattermost/` (measured by search; only `Surface.threads`'s
declaration and `NativeNavigation`'s route enum match). That is a dual-render hole in its own right
(finding F1, follow-up card). It also means the thread host must pass `rowHost: .native` **as a fact
about the view**, not as a resolver read: passing `resolver.resolvedMode(for: .threads)` would return
`web` by default and take the tap off a row that is drawn natively — a new instance of the defect this
whole thread of cards exists to fix. Write that as a comment at the call site pointing at F1.

### 2.2 Presentation legality: a profile opened from inside a modal is **pushed**, not presented

Measured hazard, already in this repo's record — `ProfileView.swift`'s own header states the rule for
this surface (*"One sheet, and nothing presented from inside it except a push"*) and cites T40's
validator measurement: a nested sheet whose confirmation action never ran (zero requests on the wire
for `AddMembersView`'s submit).

The hosts are not all at the same level in the presentation stack:

| host | container | legal presentation |
|---|---|---|
| `ChannelPaneContent` | pane destination (root stack / detail column) | **sheet** — shipped by T41/T429; do not change (T41 + T429 live tests assert `profileSheet`) |
| `ThreadPostListView` | pane destination | **sheet**, folded into its existing `ChannelListSheet` slot |
| `SearchPaneContent` / `SavedPaneContent` / `MentionsPaneContent` in the **compact** layout | `TabView` tab (no stack above) | **sheet**, own slot |
| the same three in the **regular** layout | `NativeShellView`'s `lookupSheet` → `NavigationStack` | **push** on that stack |
| `PostCollectionView` inside `PinnedPostsView` | a sheet, wrapped in its own `NavigationStack` | **push** on that stack |

So the same view has two legal presentations depending on who hosts it. Resolve it once, structurally:

```swift
enum ProfilePresentation { case sheet, push }
// EnvironmentValues.profilePresentation, default .sheet.
```

`NativeShellView` sets `.environment(\.profilePresentation, .push)` on the three lookup-sheet
contents; `PinnedPostsView` sets it on its content. Every other host leaves the default. Two modifiers
in `UI/Native/Profile/` consume it:

* `profileSheetHost(_ state: Binding<ProfilePopoverState>, server:navigation:)` → `.sheet(item:)`
  presenting `ProfileSheet`.
* `profilePushHost(_ state: Binding<ProfilePopoverState>, server:navigation:)` →
  `.navigationDestination(item: $state.target)` presenting `PushedProfileScreen` (new: the existing
  `ProfileScreen` with `onClose` = dismiss-the-push, resolving its model through `ProfileCoordinator`
  in `.task`, exactly as `ProfileSheet` does today; iOS 17 floor, `navigationDestination(item:)` is
  available).

A host calls `ProfilePresentationHost` (one view wrapping both) so it cannot pick the wrong one, and
**no host adds a second `.sheet` modifier to a view that already has one** — the thread host folds
`.profile(ProfileTarget)` into `ChannelListSheet` (`ChannelView.swift` l. 22) and both switches over
it (`ChannelPostListView.sheetContent`, `ThreadPostListView.sheetContent`) gain that case.

### 2.3 Per-host table

| host | file | state | presentation | row host passed |
|---|---|---|---|---|
| RHS / pushed thread (`ThreadPostListView`) | `Thread/ThreadView.swift` | `ChannelListSheet.profile(ProfileTarget)` | sheet (existing slot) | `.native` (F1) |
| Search results (`SearchResultRowView` ← `SearchView`) | `Search/SearchView.swift` | new `ProfilePopoverState` | `ProfilePresentationHost` | `.search` |
| Saved + Pinned (`PostCollectionView`) | `Search/SavedPinnedViews.swift` | new `ProfilePopoverState` per list | `ProfilePresentationHost` | `.search` (saved tab) / `.native` (pinned sheet, same reasoning as F1 — the pinned sheet only mounts from a native pane, and there is no `.search` read on that path) |
| Recent mentions (`ActivityRowView` ← `MentionsView`) | `Activity/MentionsView.swift` | new `ProfilePopoverState` | `ProfilePresentationHost` | `.activity` |

`GlobalThreadsView` is **not** a host: its rows are thread summaries and their participant avatars
open the thread, not a profile. No change.

### 2.4 Should mentions/search behave differently because they are "not the conversation"?

No — and this is a decision, not an omission. Upstream's affordance belongs to **the row**: the webapp
draws the same post component (with the same profile popover on avatar and username) in the centre
timeline, the RHS, search results and the mentions inbox. What differs by host is *not* whether the tap
exists but what the row's **primary** action is (a jump), so:

* the author target is strictly the **name and the avatar**, never the row;
* the row's own tap keeps working everywhere else in the row, unchanged;
* the profile opens as this host's legal presentation (§2.2), so a result tapped from the regular
  layout's lookup sheet *pushes* rather than covering the results.

---

## 3. The three list hosts: one handler per control (hardening, not a measured fix)

In `ChannelPostListView` the row is a plain `VStack` and `PostRowView` already draws a real `Button`
around the avatar and the name — the parent card's fix works because nothing wraps it. The three list
hosts wrapped the whole row **in** a `Button` whose label contains `PostRowView`:

```
Button(action: onOpen) { VStack { channel line; PostRowView(...) } }
```

**The restructure is hardening; the causal claim this section first made does not reproduce.** That
draft said a `Button` inside a `Button`'s label "is not a reliable tap target in SwiftUI", so passing
`onShowProfile` into those rows "produces an author affordance that either never fires or fires the
row's jump". Measured (`docs/t_c297b96a-c2-f1-restatement.md`): with that exact container restored and
`onShowProfile` still wired, the three hosts' live tests pass and the inner control's **own** action
runs — the profile sheet, with the `username` read back from `GET /users/{id}` — on every runtime
available here (simulator iOS 26.5, iOS 18.3.1 and iOS 17.0.1 for all three hosts), and
the runtime publishes the avatar and the name as separate `Button` elements inside the row's button.
No device was attached and XCUITest cannot drive VoiceOver's activation path, so a device-only or
VoiceOver-only failure is *unmeasured* rather than refuted — but a prediction this document cannot
show is not a justification it may keep asserting.

The shape is still required, for reasons that do not depend on hit-test resolution: the row's jump and
the author's tap must be **different handlers on different controls** (a gesture on the container, real
`Button`s for the avatar and the name) instead of one control nested inside another's label, and only
then is the row's VoiceOver contract expressible at all (point 3). It is also the shape
`ReactionBarView` already uses and documents. Identical in all three:

1. The row container stops being a `Button`. It becomes the same visual `VStack` with
   `.contentShape(Rectangle())` and `.onTapGesture { onOpen() }`, plus `.accessibilityAddTraits(.isButton)`.
   (Precedent for a plain view as a tap target in this repo: `ReactionBarView`, whose comment records
   why a `Button` was abandoned there.)
2. `onShowProfile` is passed into `PostRowView`, so the avatar and the name stay real `Button`s and
   remain the *only* inner controls.
3. Accessibility stays **one element per row** (the `T8e` rule; a 60-row list must not become 180
   VoiceOver stops): keep `.accessibilityElement(children: .combine)` and the existing explicit
   label, and add
   `.accessibilityAction(named: Text("Open profile")) { onShowProfile?(author.id) }`.
   Consequence, measured (`docs/t_c297b96a-c2-f1-restatement.md` §3 corrects an earlier draft of this
   line): the inner `post.<id>.avatar` / `.author` **stay addressable** inside these rows —
   `PostRowView` is itself `.accessibilityElement(children: .contain)` and an outer `.combine` does not
   flatten a nested container, so they remain `Button` elements with their own frames (which is what
   the live tests tap).

### What the live test taps

The test addresses the author control itself — `post.<id>.avatar`, else `post.<id>.author`, both
inside the row — and asserts the **outcome**, not a coordinate:

```swift
let row = element(app, "searchResult.\(postID)")   // etc.
XCTAssertTrue(row.waitForExistence(timeout: 60))
XCTAssertTrue(row.label.contains(authorDisplayName), "the row must be drawing that author")
// tapAuthorHeader: assert the header sits inside the row, then header.tap()
```

The guard that makes it non-vacuous is the label assertion plus the sheet's own identity assertion
(§9). Do **not** swap this for a coordinate tap: C2 measured that `(0.18, 0.22)` of a row that draws a
channel line lands in that line and opens the post (build note §6.3) — a failure with nothing to do
with the author control. Do **not** add a test-only identifier probe for the author either; the
identifiers the test uses are the shipped ones.

Rows keep their identifiers: `searchResult.<postID>`, `activity.row.<postID>`,
`savedPosts.row.<postID>` / `pinnedPosts.row.<postID>`.

---

## 4. The action set: the permission matrix

`ProfileActionSet.resolve` becomes a pure function of a context, so every cell is a unit test:

```swift
struct ProfileActionContext {
    var myUserID: String?
    var hasCustomStatus: Bool
    var callsAvailable: Bool          // CallsCoordinator.isCallsAvailable(serverID:)
    var callsSurfaceNative: Bool      // resolver.resolvedMode(for: .calls) == .native
    var hasLiveCallElsewhere: Bool    // calls.surface != nil && surface.channelID != this DM
    var hasTeam: Bool                 // navigation?.location.teamID != nil
    var inCurrentTeam: Bool?          // nil = not resolved yet
    var canManageAnyChannelMembers: Bool?   // nil = not resolved yet
}
```

Matrix (rows drawn in this order, which is upstream's DOM order — Message first, the two secondary
actions after it):

| action | another member (human) | bot | deactivated | my own profile | requires |
|---|---|---|---|---|---|
| `.message` | ✅ | ✅ | ❌ reason | ❌ reason | `DMShortcut.canMessage` (unchanged) |
| `.setStatus` `.customStatus` `.clearCustomStatus` | ❌ | ❌ | ❌ | ✅ | unchanged (T41) |
| `.call` | ✅ | ❌ absent | ❌ absent | ❌ absent | `callsAvailable && callsSurfaceNative && !hasLiveCallElsewhere` |
| `.addToChannel` | ✅ | ✅ (bots are members too) | ❌ absent | ❌ absent | `hasTeam && inCurrentTeam == true && canManageAnyChannelMembers == true` |

Rules that keep it honest:

* **unknown is absent, not assumed** — `inCurrentTeam == nil` or `canManageAnyChannelMembers == nil`
  means the row is not drawn yet. That is `ChannelInfoCapabilities.none`'s own rule ("a screen that
  has not finished loading permissions must not offer one it cannot prove").
* **`.call` is the one exception, deliberately**: `isCallsAvailable` answers `true` until a probe
  returns 404 (`CallsCoordinator`'s doc says so, and the pane header's own button rides it). A Call
  row that disappears before the first probe would mean nobody can start the first call.
* Each absence carries a reason string in the same slot `messageUnavailableReason` uses today
  (`callUnavailableReason`, `addToChannelUnavailableReason`), so the sheet can say "You are already in
  a call." rather than showing nothing.

---

## 5. Call

**What it is.** Not a new surface: it is a *route* into `.calls`, which is already approved, already
presents full screen, and already has live coverage (T44d, 2/2 twice). The row's job is one thing the
pane header cannot do — reach a conversation that may not exist yet.

```
tap Call
  → dismiss the profile sheet                    (a nested fullScreenCover from inside a sheet is the
                                                  T40 failure mode; never present the call surface
                                                  from the sheet)
  → POST /channels/direct {myID, profile.id}      (ProfileService.directChannel — T41's write path)
  → navigation.openChannel(request)               (the DM opens in the pane)
  → CallsCoordinator.requestStart(server:channel) (new: a one-shot pending intent, per server)
  → the pane mounts CallsJoinEntry, which consumes the intent in .task and calls
      startCall(server:channelID:channelName:)
  → CallsSurfaceView (.fullScreenCover, owned by CallsJoinEntry — unchanged)
```

`requestStart` is the only new mechanism, and it is app-scoped on purpose: the pane can be re-created
between the tap and its appearance (rotation, a channel switch mid-flight), and an intent owned by a
view would be lost. Consume-once, and clear it on sign-out with the rest of the coordinator's state.

Gates: the matrix row above. `startCall` already refuses a second concurrent call and no socket/plugin
(`lastError` alert) — those failures are surfaced by `CallsJoinEntry`'s existing alert, so the row does
not add a second error path.

Risks to carry on the card:
* **microphone permission** is requested by the existing join path; the row adds no new prompt.
* T44d's recorded hazard: this suite is host audio-sensitive (an `AURemoteIO::Initialize` abort at high
  load). Run it alone on a quiet host, as `docs/t44d-build-note.md` §4.2 says.
* A call already live in another channel → the row is absent with a reason; switching calls
  (upstream's `switch_call_modal`) stays out of scope.

## 6. Add to a channel

**Shape (upstream's, not the card's):** a channel **picker**, team-scoped.

```
tap "Add to a channel"
  → push AddToChannelPickerView on the profile sheet's own NavigationStack   (legal: push)
      list  = my channels in `navigation.location.teamID` where I can manage members
      search field (upstream's search_channel_with_permissions_provider equivalent)
      on select: GET /channels/{id}/members/{userID}
                 → member already?  "Already a member" (submit disabled)
                 → not a member?    enable "Add" → POST /channels/{id}/members {user_id}
      server's answer inserted optimistically; failure shows a banner and removes the row
```

**Where the permission answer comes from** (all routes already exist in this build):

| need | route | file |
|---|---|---|
| my channels on the team | `GET /users/me/teams/{tid}/channels` | `ChannelSidebarAPI.teamChannels` |
| my channel roles | `GET /users/me/channel_members` (`MMChannelMember.roles`) | `ChannelSidebarAPI.myChannelMembers` |
| my system + team roles | `GET /users/me`, `GET /teams/{tid}/members/{me}` | `ChannelInfoAPI.currentPrincipal`, `.teamMembership` |
| role → permission ids | `POST /roles/names` (one request for the union) | `ChannelInfoAPI.roles` |
| target is in the team | `GET /teams/{tid}/members/{userID}` | `ChannelInfoAPI.teamMembership` |
| add | `POST /channels/{id}/members` | `ChannelInfoAPI.addChannelMember` |

Per-channel gate: extract the expression that already exists in `ChannelInfoCapabilities.derive` into
`ChannelInfoCapabilities.canManageMembers(channel:permissions:)` and call it from both `derive` and the
picker — one rule, two quantifiers:

* the **row** is drawn when it holds for **∃** channel in the team (`canManageAnyChannelMembers`,
  upstream's selector);
* a **picker row** is drawn when it holds for **that** channel.

The answers are resolved once per (server, team) through a small `ChannelMemberAdminDirectory` cached
by `ProfileCoordinator` — not per profile open, and never on the row's tap path.

## 7. Presentation: the sheet stays (decision)

Keep T41's medium-detent sheet. Reasons, in order of weight:

1. **This surface is the full profile screen, not upstream's hover card** (name, position, email,
   joined, last active, presence polling) — the T41 decision, and its build note says so. An anchored
   popover sized to that content cannot fit beside a phone row, and an anchored card sized to a
   desktop hover card would silently delete those fields.
2. **The dismissal set the card lists is a consequence, not a missing behaviour**: outside tap and
   second tap are unavailable because the sheet covers the row. Adding them means replacing the
   presentation, not adding a gesture.
3. What it *would* take is concrete, so a future card is not guessing: `.popover(item:)` with
   `.presentationCompactAdaptation(.popover)` and a `GeometryReader`-derived anchor rect at the row,
   plus a shortened content variant (identity + presence + the action rows only). That is a **T41
   product change** with a new screen variant — not a parity fix — and it needs the owner's call on
   which content the anchored form keeps.

Escalation path if the owner disagrees: one card, `owner sign-off`, scope "anchored profile card on
iPhone (short content variant)", `-AV` not implied.

---

## 8. Findings filed from this card

* **F1 — `.threads` is never consulted.** No `resolvedMode(for: .threads)` call site exists; the thread
  pane draws natively regardless. Every other surface is switchable. Follow-up card `t_8f9f5449-F1`
  (decision card: gate it or retire the surface — with the warning that gating it reddens T36's whole
  live suite while `.threads` is unapproved).
* **F2 — the channel pane carries four `.sheet` modifiers on one view tree** (post list, pinned,
  channel info, profile). It works today, but it is the exact shape that silently drops presentations.
  Not this card's to fix; recorded so the next host does not copy it (§2.2 forbids it for new hosts).
* **F3 — member administration is only half-ported**: `ChannelMembersView` removes members and shows a
  role badge, but there is no role *change* (`setRoles`, upstream's `canChangeMemberRoles`). Not a
  popover row (§1), so it belongs to a T40 follow-up if the owner wants it.

---

## 9. Acceptance tests, per surface

Every test asserts against the **server's** value, never a local string. Each suite seeds its own
fixture: `#t429-tap` (perfprobe + t41buddy) is reused because its two accounts already exist and its
own fixture posts are cheap; **do not** post into `#t41-profile` (that collision is recorded in
`docs/t_42968927-profile-popover.md` §5.1 and pushed T41's seed post out of the pane's window).

| surface | live test | taps | asserts |
|---|---|---|---|
| thread (RHS / pushed) | `testTheAuthorOfAThreadReplyOpensTheirProfile` | `thread.post.<replyID>.author` (a real element here) | `profileSheet` appears; `profile.username` == `GET /users/{authorID}`'s `username` |
| search | `testTheAuthorOfASearchResultOpensTheirProfile` | search result row coordinate (§3) | same, plus `searchResult.<id>` still opens the post when tapped elsewhere in the row |
| saved | `testTheAuthorOfASavedPostOpensTheirProfile` | saved row coordinate | same |
| pinned (`PostCollectionView` in `PinnedPostsView`) | `testTheAuthorOfAPinnedPostPushesTheProfile` | pinned row coordinate | the profile appears **as a push** (pinned sheet still up, `profileSheet` absent, `profile.username` present) |
| mentions | `testTheAuthorOfAMentionOpensTheirProfile` | activity row coordinate | same as search |
| Call | `testCallOpensTheDirectChannelAndJoins` | `profile.call` on t41buddy | sheet dismisses, DM opens, `callsSurface` appears, `Leave` → server `{"active":false}` |
| Add to a channel | `testAddToChannelAddsTheAuthorToTheChosenChannel` | `profile.addToChannel` → picker row → `addToChannel.submit` | `GET /channels/{id}/members/{buddy}` answers 200 afterwards; the picker's own row shows the member |
| matrix (no server) | unit | — | every cell of §4, including `nil` context → row absent |

Fixtures: saved = `PUT /users/{me}/preferences` `flagged_post`; pinned = `POST /posts/{id}/pin`;
mention = t41buddy posts `@perfprobe`; DM/call = t41buddy's profile. All are writes the existing
suites already perform, so nothing new is needed on the server beyond the two accounts.

Suites: `MattermostUITests/T5449ThreadProfileUITests.swift`,
`…/T5449ListProfileUITests.swift`, `…/T5449ProfileActionsUITests.swift`;
units: `MattermostTests/T5449ProfileHostPolicyTests.swift`, `…/T5449ProfileActionMatrixTests.swift`,
`…/T5449AddToChannelPickerTests.swift`.

Gates for each card: whole unit target green (currently 1788/8 skipped/0 failed),
`scripts/verify-dual-render-gates.sh --allow-approved-registry`, its own live suite green, and the
parent's `T429ProfileTapUITests` + `T41ProfileUITests` re-run green (the action set and the sheet are
their subject).

---

## 10. Cards this document creates

| id | card | assignee | parents |
|---|---|---|---|
| `t_07216319` (C1) | profile popover on the native **thread** host + the `rowHost` rename | `mmios-ios` | this card |
| `t_2fa3bbe1` (C2) | profile popover on **search / saved+pinned / mentions** + the nested-tap restructure + presentation legality | `mmios-ios` | C1 |
| `t_296843e5` (C3) | the two write rows: **Call** and **Add to a channel** | `mmios-ios` | C1 |
| `t_7ffa9e76` (F1) | decide `.threads`: gate it or retire it | `mmios-architect` | this card |

C2 is chained behind C1 because it consumes the renamed policy. C3 is **not** chained behind C2 even
though both write in `UI/Native/Profile/`: C3's only overlap is `ProfileView.swift`, and it does not
need the `ProfilePresentationHost` helper (the profile sheet already has its own `NavigationStack`, so
the add-to-channel picker can be a plain `navigationDestination` there). If the board dispatches C2 and
C3 to the same working tree at the same time, land C3's picker push without touching the two
presentation modifiers.

**No card is created for the presentation change.** Anchored popover vs sheet is a T41 product
decision (§7); it needs the owner's call on which content the anchored form keeps, and it is not a
parity fix. If the owner asks for it, that is one new card with `owner sign-off` in its body.
