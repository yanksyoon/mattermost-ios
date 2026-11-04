# t_3b2f313a — an unread channel marks its whole group (bold header + blue dot)

Owner request, verbatim: *"For each channel group, if a channel contains an unread message, I want the
whole channel group to also contain the unmarked check (bold text and blue dot)."*

## 1. Upstream parity, read from the pin before implementing

`mattermost/mattermost-mobile` @ `162f2560` (v2.45.0), the file the T33 port cites:
`app/screens/home/channel_list/categories_list/categories/header/header.tsx` (fetched from the tag,
119 lines). The whole header is a `TouchableOpacity` around:

* an animated `chevron-down` icon, and
* one `Text` with `styles.heading` — `color: changeOpacity(theme.sidebarText, 0.64)`,
  `textTransform: 'uppercase'`, `typography('Heading', 75)` —
* (and the category's `muted` opacity, applied to the container).

There is **no unread prop, no bold weight and no dot** anywhere in that component: upstream's header
does not mark unread at all. So the owner's request is a divergence from upstream, not a parity gap,
and it is recorded as such in `docs/parity.md` under the T33 sidebar row rather than silently applied.

## 2. What was built

### The roll-up lives on the group, computed from the rows

`Mattermost/UI/Native/Sidebar/ChannelSidebarModels.swift` — `ChannelSidebarGroup` gains four
read-only values, each derived from `entries` on every read (no stored counter to go stale):

```swift
var mentions: Int        // sum of the rows' mentionCount
var unreadChannels: Int  // entries.filter(\.showsUnreadEmphasis).count
var hasUnread: Bool      // unreadChannels > 0
var headerBadge: ChannelSidebarBadge  // .dot while hasUnread, else .none
var accessibilityValue: String        // "Muted", "Unread", "N mentions", joined
```

`unreadChannels` is the **row's** predicate (`ChannelSidebarEntry.showsUnreadEmphasis`), not
`unreadCount > 0`. That is deliberate: a muted channel with an explicit mention is bold/dotted on its
row, so its group is marked; a muted channel with only ordinary unread messages draws nothing on its
row, so its group draws nothing either. The header cannot claim an unread state the row refuses to show.

`headerBadge` is always `.dot` or `.none` — never `.count` — which is the "bold + dot, no number"
requirement expressed as a value a test can assert. The number is not lost: it rides in
`accessibilityValue` ("Unread, 4 mentions").

### The header draws it

`Mattermost/UI/Native/Sidebar/ChannelSidebarView.swift`

* `ChannelSidebarUnreadDot` — the row's dot extracted into one view (`Circle().fill(Color.accentColor)`,
  7×7, `accessibilityHidden`). The row's `.dot` badge case and the category header now construct the
  **same** view, so there is one indicator and two places, not two indicators.
* `CategoryHeader` — the name's `.fontWeight(group.hasUnread ? .bold : .regular)`, and the dot after
  the `Spacer` (the row badge's position) while `group.headerBadge.isDot`.
* The T8e single-element guarantee is unchanged: same `accessibilityIdentifier`
  (`channelSidebar.category.<type>` / `…custom.<id>`), same `Button` label = `displayName`, and the
  value now comes from `group.accessibilityValue` (it used to be `"Muted"` / `""` only).

The rule lives entirely in `CategoryHeader`, so the `channels`, `favorites`, `direct_messages` and
custom groups, and the Threads/Drafts rows, all behave the same by construction. Collapse state is not
consulted: a collapsed group's header is marked exactly like an expanded one's, which is the point of
the request.

### Probe (evidence only, ships inert)

`Mattermost/MattermostApp.swift` gained `-sidebarGroupSnapshot <dir> [-sidebarGroupName <name>]`,
outside `#if DEBUG` (the same pattern as T1617's `-threadBackSnapshot`): it waits for the native
sidebar, picks the named category, collapses it only if it is not already collapsed (restoring the
previous state afterwards), captures the window with `drawHierarchy` — no Screen Recording permission —
and walks the sidebar column in 160 pt steps, writing a crop per step. It also writes the facts the
marker was drawn from, so the picture can be checked against the model:

* `sidebar-group.txt` — the chosen group: identifier, name, collapsed, `unreadChannels`, `mentions`,
  `hasUnread`, `headerBadge`, `headerValue`, and every row with its emphasis.
* `sidebar-groups.txt` — **every** group's roll-up, read after the layout was restored.
* `sidebar-scroll.txt` — which `UIScrollView` was walked (its frame and content height) and how many
  steps; the SwiftUI identifier `channelSidebar.scroll` does not reach the backing `UIScrollView`, so
  the pick is geometric and stated rather than implied.

## 3. Unit tests (6 new, in `MattermostTests/T33-ChannelSidebarTests`)

| test | pins |
|---|---|
| `testAGroupWithAnUnreadChannelIsMarkedAndAReadGroupIsNot` | one unread channel ⇒ `hasUnread`, `headerBadge == .dot`, value `Unread`; all read ⇒ neither, value `""` |
| `testACollapsedGroupWithAnUnreadChannelIsStillMarked` | the marker ignores the collapse state (header is the only visible thing) |
| `testTwoUnreadChannelsDrawOneDottedHeaderAndNoNumber` | two unread rows ⇒ one dot, `badgeText == nil`, value `Unread, 3 mentions` |
| `testTheHeaderFollowsTheRowRuleSoAMutedMentionMarksTheGroupAndAMutedUnreadDoesNot` | name states the rule: a muted mention marks the group, a muted ordinary unread does not |
| `testAMutedCategorySaysSoBeforeItsUnreadFact` | value composition: `Muted, Unread, 1 mention` |
| `testTheHeaderMarkerIsTheRowsOwnRollUpAndCannotDisagreeWithThem` | the roll-up **is** `entries.filter(\.showsUnreadEmphasis).count`; removing the unread row flips the header with no other bookkeeping |

```
python3 scripts/qa-test.py --platform mac --only-testing MattermostTests/T33ChannelSidebarTests \
  --label t3b2f313a-units
-> 80 run, 0 skipped, 0 failed   (build/logs/t3b2f313a-units.log)
```

(74 before this card; the six names above are the delta.)

Full suite, same command with `--only-testing MattermostTests`:

```
-> 2220 run, 9 skipped, 1 failed   (build/logs/t3b2f313a-units-full.log)
   failed: T53MediaFootprintTests.testAStagedPayloadIsWrittenToDiskRatherThanHeldInMemory
```

That failure is **pre-existing on this host and unrelated to this card**: the test compares the
process's `phys_footprint` before/after staging a 32 MB payload and asserts the delta is under 32 MB;
here the delta was 37 MB in the full run and 775 MB standalone. Re-run with this card's changes
stashed (`build/logs/t3b2f313a-t53-base.log`, base `b5c6001`): **still fails**, 835 MB. It is a
footprint measurement dominated by allocator state, not a sidebar assertion.

## 4. Screenshot — native Release Catalyst

Built `-configuration Release`, `platform=macOS,variant=Mac Catalyst`, copied with `ditto` and
**ad-hoc re-signed** (`codesign --force --deep -s -`, required on this host — `docs/t_0304915b`),
launched with the probe against the account the Release container already holds
(`https://chat.canonical.com`, team `sqmc4sz4…`). Nothing in the account's layout was changed: the
chosen category (`Sprints`) was already collapsed (`wasCollapsed=true`), so the probe wrote nothing
back.

| file | what it shows |
|---|---|
| `t3b2f313a-01-collapsed-unread-group.png` | the sidebar column: **FAVORITES, SPRINTS, OUTAGES, KNOWLEDGEBASE, CHANNELS** all collapsed (chevron ›), each **bold** with a **blue dot** on the right; read groups (PFE expanded, NINJA, HR, ARCHIVE, NOT IMPORTANT) grey and unbolded; DIRECT MESSAGES expanded, bold, dotted |
| `t3b2f313a-02-sprints-header.png` | the SPRINTS header close up: `› SPRINTS` bold + blue dot |
| `t3b2f313a-03-window.png` | the whole app window at rest (the native sidebar in the shell) |
| `sidebar-group.txt`, `sidebar-groups.txt`, `sidebar-scroll.txt` | the model's own roll-up for every group at capture time |

The note for the chosen group at capture time:

```
name=Sprints  category=channelSidebar.category.custom.d8rdp5xowjgq7xqtertxs9684y
collapsed=true  wasCollapsed=true  unreadChannels=1  mentions=4
hasUnread=true  headerBadge=dot  headerValue=Unread, 4 mentions
rows=3p9pzc…:unread=58,mentions=4,emphasis=true | yay355…:…emphasis=false | …
```

and `sidebar-groups.txt` at the same moment (the groups the picture shows, with the values they were
drawn from):

```
PFE             collapsed=false unreadChannels=0 mentions=0 badge=none value=
Ninja           collapsed=true  unreadChannels=0 mentions=0 badge=none value=
Favorites       collapsed=true  unreadChannels=2 mentions=0 badge=dot  value=Unread
Sprints         collapsed=true  unreadChannels=1 mentions=4 badge=dot  value=Unread, 4 mentions
Outages         collapsed=true  unreadChannels=2 mentions=0 badge=dot  value=Unread
HR              collapsed=true  unreadChannels=0 mentions=0 badge=none value=
archive         collapsed=true  unreadChannels=0 mentions=0 badge=none value=
Not important   collapsed=true  unreadChannels=0 mentions=0 badge=none value=
Knowledgebase   collapsed=true  unreadChannels=1 mentions=0 badge=dot  value=Unread
Channels        collapsed=true  unreadChannels=9 mentions=7 badge=dot  value=Unread, 7 mentions
Direct Messages collapsed=false unreadChannels=6 mentions=6 badge=dot  value=Unread, 6 mentions
```

The screenshot and the note agree group for group: every `badge=dot` header is bold + dotted in the
picture, and every `badge=none` header is not.

## 5. What did not change

Row rendering (the dot moved into a shared view but draws identically), row sorting, the totals
arithmetic (`ChannelSidebarDerivation.totals` is untouched and still desktop-exact: a muted channel
contributes nothing), collapse behaviour, and every existing identifier. The footer aggregate is not
derived from the new group values.

## 6. Limits of this evidence

* The screenshot is a **Release** Catalyst product (the card's requirement), but it is photographed by
  the app's own `drawHierarchy` probe rather than an XCUITest: the UI-test bundle cannot run on this
  host's Catalyst destination (its deployment target is newer than the host), the same limit T1617
  recorded. The behaviour is pinned by the unit tests above; the probe only photographs it.
* The account is a real one (`chat.canonical.com`), so the categories are whatever that account has —
  that is also why six marked headers appear rather than a fixture's single one.
* The unit suite runs on Catalyst; the iOS simulator shares the same pure derivation, but no live iOS
  UI run was made for this card (no row layout, sorting or arithmetic changed, so there is nothing
  layout-shaped to re-measure).
