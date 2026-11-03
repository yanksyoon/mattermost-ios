# T48-AV-R1 — the lookup rows' post options menu

Card: `t_29925e81` (repair of the finding filed by T48-AV, `t_531f894e`).
Repairs: `docs/t48-av-build-note.md` §F1 · reproduced live in `docs/t636e6483-ship-shaped-qa.md` §F1.
Branch/worktree: `.worktrees/t_29925e81` (`t48-r1/lookup-options`), rebased onto `7eab509` — the shared
tree was being edited by four other repair cards at the same time, so this one moved out of it. The
shared checkout was never staged from this card.

## The finding, restated

T48 (`00cd217`) mounted `PostOptionsSheet` in the channel pane and the thread pane only. Three other
hosts draw the same `PostRowView` for the same kind of post and passed **no** `actions:`, so
`PostRowView` built no ellipsis at all (`if let actions, actions.hasAnyAction …`,
`PostRowView.swift:258`):

| host | file | row |
|---|---|---|
| search results | `Search/SearchView.swift` | `SearchResultRowView` |
| the mentions feed | `Activity/MentionsView.swift` | `ActivityRowView` |
| saved **and** pinned | `Search/SavedPinnedViews.swift` | `PostCollectionView` |

The last family was not named by the ship-shaped QA card; it was found by reading every
`PostRowView(` call site in the AV pass.

## Why it was not a two-line fix, and what the repair is

A lookup row names a post from **any channel of the team** (a mention can come from any team), so the
host cannot hand the row "this pane's" `PostOptionsViewModel`: the permission union, the archived
flag, the saved set and the team name are facts of *that row's* channel.

`Mattermost/UI/Native/Channel/PostOptionsLookup.swift` (new):

* `PostOptionsPresentation` — the value a row raises: the tapped row, its surface, and the
  `PostOptionsViewModel` of **`row.post.channelId`**, resolved through
  `ChannelPaneCoordinator.postOptions(for:channelID:)`. That is the cache the channel pane itself
  uses (one model per channel, fed by the coordinator's socket handler), so a lookup menu and the
  channel's own menu can never disagree about the same post.
* `PostOptionsPresentationMode` (`.sheet` / `.push`) + `PostOptionsPresentationHost` — the same
  "one slot, two legal containers" shape `ProfilePresentationHost` uses. The **container** decides:
  the compact layout's tabs get a sheet (no stack above them); the regular layout's `lookupSheet`
  and `PinnedPostsView` set `.environment(\.postOptionsPresentation, .push)` and the screen is pushed
  on the stack that is already there. A nested sheet is the shape T40 measured failing (its
  confirmation action never ran — zero requests on the wire), which is why the push form exists.
* `PostOptionsLookupActions` — what a lookup row can do: the menu (`showsOptions: true`) and nothing
  the host cannot perform. React / Reply / Edit / Delete need the channel pane's composer, emoji
  picker or draft sink; the derivation reads those four flags as **facts**, so a lookup sheet draws
  Save/Unsave, Pin/Unpin, Mark Unread, Follow, Copy Link and Copy Text — every one of which this host
  really sends — instead of dead rows.
* `PostOptionsLookup.activate(_:)` — the read the sheet makes on open, with **no team hint**: the
  channel's own team (`GET /channels/{id}`) answers, never the pane's. A failed channel-team read
  hides Copy Link rather than building a link to the wrong team (the shape `t9acf2b1c`/R2 repairs in
  the channel pane).

`PostOptionsSheet` gained two things, both defaulted so the channel and thread panes are unchanged:
`showsCancel` (the pushed form dismisses with the stack's back button) and `onPerformed` (a landed
write, reported before the dismissal, so the Saved tab can drop an unsaved row and the pinned sheet
an unpinned one).

## What changed, file by file

| File | Change |
|---|---|
| `Mattermost/UI/Native/Channel/PostOptionsLookup.swift` | **new** — presentation, presentation mode + host modifier, lookup actions, per-row channel resolution, the activation seam |
| `Mattermost/UI/Native/Channel/PostRowView.swift` | `PostOptionsSheet.showsCancel` / `.onPerformed`; the pushed form draws no Cancel row; `.performed` reports the write before dismissing |
| `Mattermost/UI/Native/Channel/PostOptionsViewModel.swift` | the follow write refuses honestly when the channel's team is not known (a lookup activation carries no hint) |
| `Mattermost/UI/Native/Search/SearchView.swift` | `SearchResultRowView(actions:)`; the result list builds the row's actions and owns the presentation slot |
| `Mattermost/UI/Native/Activity/MentionsView.swift` | `ActivityRowView(actions:)`; the feed builds the row's actions and owns the slot |
| `Mattermost/UI/Native/Search/SavedPinnedViews.swift` | `PostCollectionView` builds the row's actions, owns the slot, and re-reads the list after an unsave/unpin; `PinnedPostsView` pushes the options screen |
| `Mattermost/UI/Native/NativeShellView.swift` | the regular layout's lookup sheet pushes the options screen |

The presentation modifier is attached to the **list** that raises it, never to the pane's outer
view: those panes already carry the author popover's presentation there, and two `.sheet` modifiers on
one node is the shape T5449's spec F2 records dropping presentations.

## Tests

### Unit — `MattermostTests/T48R1LookupPostOptionsTests.swift` (new)

| Test | Claim |
|---|---|
| `testTheMenuResolvesTheRowsOwnChannel` | the presentation's model is `row.post.channelId`'s, is the coordinator's cached instance, and two channels are two models; a row with no channel has no menu |
| `testTheOfferIsDerivedFromTheRowsChannelNotTheOneOnScreen` | channel A (may write) offers Pin; channel B (no permissions, archived) does not offer Pin or Mark Unread — from two models fed by one server, with each sheet asking about its own channel |
| `testTheSavedRowOffersUnsaveAndThePinnedRowOffersUnpin` | a saved row offers Unsave, a pinned row offers Unpin |
| `testTheLookupRowOffersOnlyTheOptionsItsHostCanPerform` | the lookup action set offers no React/Reply/Edit/Delete on my own post where the *channel pane's* actions on the **same model** do — the difference is the host, not the state |
| `testTheLookupActivationAsksTheChannelForItsTeamAndNotThePane` | activation with no hint resolves the channel's own team for both the permission union and the permalink |
| `testARefusedWriteFromTheLookupSheetKeepsItsReason` | a refused Unsave returns `.failed` with "Could not save. …", leaves the saved set alone, and sends nothing else |

### UI — the shipped configuration (`app.launchArguments = []`, Release), `MattermostUITests/T93BNativeByDefaultUITests.swift`

The two assertions `t_636e6483` left red are **flipped, not deleted** — same tests, same claims, plus
one assertion each that the sheet is not empty (Save/Unsave drawn):

* `testThePostOptionsMenuOpensOnASearchResultRow`
* `testThePostOptionsMenuOpensOnAMentionRow`

New in the same suite (same configuration, same device coverage):

* `testThePostOptionsMenuOpensOnASavedRowAndUnsaveLandsOnTheServer` — the row is saved through REST,
  Unsave is pressed in the lookup sheet, and the oracle is `GET /users/me/preferences` (the
  `flagged_post` rows the Saved list itself is built from), then the row leaves the list.
* `testThePostOptionsMenuOpensOnAPinnedRowAndUnpinLandsOnTheServer` — the fixture channel opens
  through the shipped quick switcher, a post is pinned through REST, the pinned sheet's row menu
  offers Unpin, and `GET /posts/{id}` answers `is_pinned: false` afterwards.
* `testARefusedPinFromASearchResultSheetStaysOpenWithTheReason` — the search row's sheet is open when
  the author deletes the post from another session; Pin is pressed, the server refuses, and
  `postOptions.error` is drawn **with the sheet still open**.

## Runs

### Unit — Mac Catalyst, `scripts/qa-test.py`, this worktree's own derived data

| Suite | Log | Result |
|---|---|---|
| `MattermostTests/T48R1LookupPostOptionsTests` (before the rebase) | `build/logs/t48r1-units-mac2.log` | 6 run / 0 failures, `** TEST SUCCEEDED **` |
| `MattermostTests/T48R1LookupPostOptionsTests` (rebased onto `bde77c5`) | `build/logs/t48r1-units-rebased.log` | 6 run / 0 failures, `** TEST SUCCEEDED **` |
| `MattermostTests/T48PostOptionsTests` (rebased tree) | `build/logs/t48r1-t48-units.log` | 26 run / 0 failures, `** TEST SUCCEEDED **` |
| both suites, rebased onto `7eab509`, final tree | `build/logs/t48r1-units-final.log` | **35 run / 0 failures** (6 + 29), `** TEST SUCCEEDED **` |

Catalyst rather than the simulator for the same reason T48-AV used it: the host carried five to eight
concurrent `xcodebuild` runs from sibling cards (load average 500–1000) and the simulator's
`installApplication` wedged twice. The suites are model logic and do not depend on the device.

### Release build

`xcodebuild build-for-testing -scheme MattermostReleaseSmoke -configuration Release` →
`** TEST BUILD SUCCEEDED **` (`build/logs/t48r1-iphone-release-build2.log`). This is what proves the
UI rows and the product change **compile in the configuration the card's acceptance names**.

### The shipped-configuration UI rows — measured live on both layouts

The host was quiet this time (load 9–10, no sibling `xcodebuild`), so the suite that the earlier pass
could only compile ran end to end. Both simulators were seeded the way the suite's own class comment
prescribes — a Debug build installed and launched once with
`-uiTestSeedServer`/`-uiTestSeedServerName`/`-uiTestSeedStoredToken`, then the Release build installed
over it (same bundle id, so the container and the Keychain item survive). `build/seed_device.sh` does
that in one command; `build/seed_token.py` gets the token from the fixture's own login.

| Layout | Device (iOS 18.3.1) | Log | Result |
|---|---|---|---|
| compact | iPhone 16 Pro | `build/logs/t48r1-iphone-f1.log` | **5 run / 0 failures**, `** TEST EXECUTE SUCCEEDED **` |
| regular | iPad Pro 11-inch (M4) | `build/logs/t48r1-ipad-f1.log` | **5 run / 0 failures**, `** TEST EXECUTE SUCCEEDED **` |

The five rows, with their measured times on each layout (seconds, iPhone / iPad):

| Test | Claim | compact | regular |
|---|---|---|---|
| `testThePostOptionsMenuOpensOnASearchResultRow` | `post.<id>.menu` on a result row, then the options screen, and it is not empty | 22.2 | 40.1 |
| `testThePostOptionsMenuOpensOnAMentionRow` | the same on a mention row | 16.0 | 11.9 |
| `testThePostOptionsMenuOpensOnASavedRowAndUnsaveLandsOnTheServer` | the Saved row's menu offers **Unsave**, and the write lands: `GET /users/me/preferences` stops holding the `flagged_post` row, and the row leaves the list | 20.9 | 37.9 |
| `testThePostOptionsMenuOpensOnAPinnedRowAndUnpinLandsOnTheServer` | the pinned row's menu offers **Unpin**, and `GET /posts/{id}` answers `is_pinned: false` | 90.0 | 17.3 |
| `testARefusedPinFromASearchResultSheetStaysOpenWithTheReason` | the post is deleted from another session, Pin is pressed, the server refuses, and `postOptions.error` is drawn **with the screen still open** | 25.8 | 52.6 |

Release `build-for-testing` for these products: `** TEST BUILD SUCCEEDED **`
(`build/logs/t48r1-iphone-release-build7.log`; the earlier build on the first rebase is `-build3`).

### The five harness facts the live runs exposed (product unchanged)

Every one of these was a **test** assumption, measured on the device, and fixed in
`T93BNativeByDefaultUITests.swift` — not one required a product change, which is the point of listing
them:

1. **The pushed form is not `postOptions.<id>`.** A `List` identifier is not reliably in this
   runtime's tree once it is a push destination (the same finding `t636e6483` recorded for the pinned
   list), so the form is named by its wrapper: `postOptionsPush` (the rule `profilePush` already
   states). The option rows keep `postOptions.<option>` in both forms. `PostOptionsLookup.swift`'s
   identifier block now says exactly that.
2. **The pinned row's post is also in the channel behind the sheet**, so an app-wide
   `post.<id>.menu` query matched two buttons and `.tap()` refused ("Multiple matching elements
   found"). Row queries are now scoped to the pane that draws them (`nativeSearchPane`,
   `nativeSavedPane`, `nativeActivityPane`, `pinnedSheet`).
3. **The Saved list is team-scoped.** The seeding helper writes one post per team when the shell's
   team cannot be read, so the test saves every candidate and measures the row the pane actually
   draws.
4. **The regular layout's rail does not honour a team switch from this state.** Measured: the rail
   row was tapped and the rail still read "Operations" a minute later, so the quick switcher scoped
   its search elsewhere and answered "No channel matches". The pinned test now measures in the
   **shell's own team** (every fixture team has a town-square; the channel is only the row's host).
5. **Two timing facts**: the search list redraws after submit (a broader set is drawn for a beat, so
   the menu is re-resolved rather than sampled once), and the refusal message is drawn in a section
   **below** the options, which a `List` does not realise until it is scrolled into view.

The retry wrapper written for the earlier, saturated host (`build/retry_live.sh`, gitignored) is still
the tool for a busy host: it waits for a quiet machine, reboots the device, installs the app by hand
with a hard timeout, and only stops early when the log says a **test** failed. On a quiet host the
whole thing is one command:

```
scripts/t48r1_live_suite.sh <iphone-udid> t48r1-iphone   # 5 rows, compact
scripts/t48r1_live_suite.sh <ipad-udid>   t48r1-ipad     # 5 rows, regular
```

## Publish

| | |
|---|---|
| code + tests + this note | `48219c5` |
| base | `7eab509` (origin/main at the time of the rebase) |
| worktree/branch | `.worktrees/t_29925e81`, `t48-r1/lookup-options`, one commit |
| verified | `git ls-remote origin refs/heads/main` == `48219c5…` after the push |

The shared checkout was not used for the commit: this card worked in its own worktree, so none of the
sibling cards' uncommitted files were staged, and nothing listed in the steward's notes was deleted.

