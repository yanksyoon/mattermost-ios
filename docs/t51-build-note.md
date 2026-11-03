# T51 — global drafts list + scheduled posts (S26, S40)

The parity gap: drafts were persisted per channel (`ComposerDraftStore`, GRDB, one row per
channel+thread root) but there was **no drafts list** — a draft was invisible until the reader
happened to reopen that exact conversation — and there was **no scheduled-post path at all**.
Inventory rows S26 (drafts + scheduled posts) and S40 (scheduled posts).

Behaviour reference: `mattermost/mattermost-mobile` at v2.45.0 —
`app/screens/global_drafts/` (`index.tsx`, `global_drafts_list.tsx`, `empty.tsx`),
`app/database/schema/server/table_schemas/draft.ts`, and for the scheduled half
`app/screens/draft_scheduled_post_options/`, `app/screens/reschedule_draft/`,
`app/actions/remote/scheduled_post.ts`.

**Outcome in one paragraph.** The drafts half shipped and is live-tested end to end. The scheduled
half **could not be measured** on the pinned fixture: every scheduled-post route answers
`404 api.context.404.app_error` on Mattermost 9.11.19 Team Edition (§6). The card's own branch for
that case is followed: the drafts half is kept, and the scheduled half is a named follow-up card
(`T51-S`, created from this card) rather than shipping request code no fixture has ever answered.

---

## 1. What shipped

| Surface | Native counterpart |
| --- | --- |
| The global drafts list: one row per stored draft, channel label, snippet, edited age, thread marker | `GlobalDraftsView` (`Mattermost/UI/Native/Drafts/GlobalDraftsView.swift`) |
| The pure rules: snippet, age copy, team scoping, unlisted-channel marking, the row's route | `GlobalDraftDerivation`, `GlobalDraftRow`, `DraftChannelLabel` (`GlobalDraftsModels.swift`) |
| The screen's state: read the store, delete, re-read | `GlobalDraftsViewModel` |
| Reachability: the sidebar's Workspace block → **Drafts** (both layouts) | `NativeChannelSidebarContent.workspaceSection` — row `channelSidebar.drafts` |
| A draft's team, so the list is team-scoped without a schema change | `ComposerDraft.teamID`, persisted in the row's existing `metadata` JSON |
| A delete that also drops the warm composer's copy | `ComposerViewModel.discardStoredDraft()`, `ChannelPaneCoordinator.discardDraft`, `ThreadCoordinator.discardDraft` |

New files:

```
Mattermost/UI/Native/Drafts/GlobalDraftsModels.swift   rows, snippets, age copy, team scoping, the view model
Mattermost/UI/Native/Drafts/GlobalDraftsView.swift     the sheet: rows, delete, empty state, identifiers
MattermostTests/T51GlobalDraftsTests.swift             26 unit tests
MattermostUITests/T51GlobalDraftsUITests.swift         2 live tests (find/open/delete; relaunch)
scripts/t51_scheduled_probe.py                         the scheduled-post contract, measured (§6)
```

Modified: `Composer/ComposerModels.swift` (the draft's `teamID`), `Composer/ComposerDraftStore.swift`
(metadata ↔ `teamID` mapping, no schema change), `Composer/ComposerViewModel.swift` (writes the team;
`discardStoredDraft`), `Channel/ChannelPaneCoordinator.swift` (`draftsStore(for:)`,
`discardDraft`), `Thread/ThreadCoordinator.swift` (`discardDraft`), `Sidebar/ChannelSidebarView.swift`
(the Drafts row, the sheet, open/discard wiring).

### The route, named

There is no new `Surface` case and no web fallback. The drafts list is a **route inside the native
sidebar**, the same shape as T46's permanent-web rows: it is reachable from the Workspace block of
the channel list — above the categories, beside Threads and "Jump to a channel…" — and it opens as a
sheet over the sidebar in **both** layouts (compact and split both mount
`NativeChannelSidebarPane` → `NativeChannelSidebarContent`). With the sidebar surface set to `web`
the row does not exist, which is honest: the list is part of the native shell, not a new switchable
pane.

## 2. What a row says, and the decisions that are not obvious

- **Title** — `#Display Name` for a public channel, the display name otherwise (a DM is titled with
  the people, never `id__id`).
- **Snippet** — the message with every whitespace run collapsed, cut at 140 characters with `…`; a
  message with only attachments says `1 attachment` / `N attachments`.
- **Age** — `Edited just now` / `… N min ago` / `… N h ago` / `… N d ago`, and an absolute date after
  a week. A timestamp in the future (a clock that moved) reads `just now`, never a negative age.
  `updateAt == 0` reads `Saved earlier`.
- **Thread drafts** are marked `Thread draft` and open the **thread pane at their root**, where the
  thread composer (keyed `(channel, root)`) restores the text. A channel draft opens the channel.
- **A draft for a channel the reader left is still listed and explicitly marked** —
  `Channel not in this team's list`, with its words intact and its channel id as the route. The card
  allowed "listed, or explicitly marked"; this build does both, because hiding it would make a draft
  in a left channel unreachable again — the exact defect the card closes. The row still opens: the
  channel pane reports what the server says about a channel the reader can no longer read.
- **Team scoping** — the list is "every draft for the server+team". A draft written by this build
  carries its team and is listed only on that team. A draft written **before** T51 has no team in its
  row; it is listed on every team (with the current team's channel label) rather than hidden, because
  hiding it would strand it. Both branches are unit-tested
  (`testADraftBelongingToAnotherTeamIsNotListedHere`, `testADraftWithNoTeamIsListedOnEveryTeam`).

## 3. Storage: the team rides in the row's `metadata` column

The `draft` table (T29) keys a draft by `(channel_id, root_id)` and has no team column. A channel id
is only unique inside one server, and the drafts list needs the team to scope itself, so the composer
now writes `{"team_id": "<id>"}` into the row's existing `metadata` JSON column — already defined,
already persisted, and previously always `nil` for drafts. **No migration, no new table, no new
column.** A malformed metadata blob reads as "team unknown" and never costs the draft's text
(`testMalformedMetadataIsTeamUnknownRatherThanALostDraft`).

The list reads the **same** `ComposerDraftStoring` the composer writes
(`ChannelPaneCoordinator.draftsStore(for:)`), so there is no second copy to drift.

## 4. Delete is a store delete, and the warm composer is told

A channel's composer stays warm after the reader leaves it (T35's cache). Deleting the row from the
list while that composer still holds the words would make the delete undo itself: reopening the
channel would show text whose row is gone, and the next keystroke would write it back. So the list's
delete does two things, in this order: the host drops the warm composer's copy
(`ComposerViewModel.discardStoredDraft()`, which cancels any queued write and bumps the draft
generation), then the store deletes the row, then the list re-reads the store. If the row survives
the store's answer it stays on screen with `That draft could not be deleted. Try again.` — the list
never claims a delete that did not happen (`testAVetoedDeleteKeepsTheRowAndSaysSo`).

## 5. Live results

Run on the tree this note ships with (rebased onto `origin/main` `2b81b2f`; the published commit is
named in the card's closing comment, because a commit cannot name its own SHA).
Server: the pinned fixture at `127.0.0.1:8065` (Mattermost **9.11.19** Team Edition, account
`perfprobe`). Simulator: iPhone 16 Pro, iOS 18.3.1, `parallel-testing-enabled NO`. The host was under
extreme load for much of the session (load average into the hundreds, swap nearly full, ~60 MB free
of 16 GB); every number below is a real run, and the attempts that did not finish were XCTest
failing to bootstrap its host ("Early unexpected exit … Test crashed with signal kill") or being
killed by the stall watchdog, not product failures — the successful runs are the ones cited.

Command (the env supplies the fixture account; each live test **skips**, never fails, without it):

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
python3 scripts/qa-test.py --platform ios --sim "id=81A7F251-8B31-4945-8783-5A264C14B8D5" \
  --derived-data ~/Library/Developer/Xcode/DerivedData/mmios-t51 \
  --only-testing MattermostTests/T51GlobalDraftsTests \
  --only-testing MattermostUITests/T51GlobalDraftsUITests --label t51-final1 \
  -- -parallel-testing-enabled NO
```

`build/logs/t51-final1.log` — **one invocation, `** TEST SUCCEEDED **`, 333.3 s**:

| Suite | Result |
| --- | --- |
| `MattermostTests/T51GlobalDraftsTests` | 26 tests, 0 failures (0.58 s) |
| `MattermostUITests/T51GlobalDraftsUITests` | 2 tests, 0 failures (220.9 s) |

`build/logs/t51-live.log` — the same live class on its own, **2 tests, 0 failures, 244.9 s**:
`testADraftIsFoundInTheListOpenedInItsChannelAndDeleted` (117.0 s) and
`testADraftSurvivesARelaunchAndIsReachableFromTheList` (127.9 s, 110.4 s in the suite run).
`build/logs/t51-all-units.log` — the whole unit bundle on this tree: **2020 tests, 8 skipped,
0 failures** in 599.0 s.

What the two live tests prove:

1. `testADraftIsFoundInTheListOpenedInItsChannelAndDeleted` — a draft typed in `#t51-drafts` is
   listed after the channel is left; tapping the row opens that channel and the composer restores the
   text; Delete removes the row, and a **new process** still does not show it.
2. `testADraftSurvivesARelaunchAndIsReachableFromTheList` — the app is killed and relaunched without
   the reset flag (same server row, same session, same per-server draft database); the draft is found
   from the list alone and a **fresh** composer (this process never opened the channel) restores the
   text. The app's container confirms the row directly, in
   `Library/Application Support/MattermostStores/<serverID>.sqlite`, table `draft`:

```
channel_id=9rzho77t37f6xqg1n7zuykejsh root_id= message="t51 relaunch 1793694846 — never sent"
update_at=1793694889191 metadata={"team_id":"ocz148uck3r88dcjikj497bosh"}
```

**One finding the live run forced.** The row's first shape gave each line its own identifier, and the
live test found the row container but not its lines: SwiftUI collapses a subtree carrying
`.accessibilityAddTraits` into a single element, so per-line identifiers do not surface. The row is
now **one accessibility element** — glyph + title + snippet + age, labelled
`"<title>, <kind>, <snippet>, <edited>"`, which is also what VoiceOver reads — with the delete button
deliberately outside that element so it stays separately addressable. The tests assert the row's
label, which is how a reader hears the same words.

## 6. Scheduled posts (S40): the measured refusal

`scripts/t51_scheduled_probe.py` creates (or reuses) `t51probe` by open sign-up and asks the pinned
Mattermost **9.11.19** server for each route the card names. Re-run 2026-11-03:

```
GET    /posts/scheduled/team/{team_id}   404 api.context.404.app_error
POST   /posts/schedule (create_at ms)    404 api.context.404.app_error
POST   /posts/schedule (create_at s)     404 api.context.404.app_error
GET    /posts/scheduled/{id}             404 api.context.404.app_error
PUT    /posts/schedule/{id}              404 api.context.404.app_error
DELETE /posts/schedule/{id}              404 api.context.404.app_error
```

The server's own detailed error is "There doesn't appear to be an api call for the url=…" — i.e.
**the scheduled-post API is not registered on this Team Edition build** (the feature is
enterprise-gated), not "the request was malformed". There is therefore no way on this host to
measure:

- which `create_at` shape the route takes (epoch seconds vs milliseconds);
- whether an empty message or a past date is refused, and with what sentence;
- whether a recurrence can be expressed at all (the card: "recurrence only if the server under test
  supports it");
- the socket events `scheduled_post_created/updated/deleted`.

Per the card's own branch, **no scheduling request ships in this tree**. Shipping the Swift request
shapes with nothing but a 404 to test against would be exactly the "untested requests" the card
forbids. The scheduled half — the date/time picker converted to the server's offset, the pure
derivation with its unit tests and mutation check, the four routes, the socket patches — is a named
follow-up card created from this one (`T51-S`, card `t_e5f917f9`: *scheduled posts — the fixture
answers 404 on every route; needs a licensed server*), carrying this measurement and the acceptance
criteria from the original card's §2–§4.

What the *drafts* half already gives that follow-up: `ComposerDraft.teamID` (§3) is the same fact a
scheduled post needs, and `GlobalDraftDerivation.editedCopy` is the pure time-formatting precedent
the scheduling derivation should follow.

## 7. Limits of this evidence

- The drafts list has **no server record to read back** — drafts are local until sent, which is what
  a draft is. The live oracle is therefore a **relaunch** (a new process reading the same per-server
  SQLite file), not an API read: `testADraftSurvivesARelaunchAndIsReachableFromTheList` types a
  draft, kills the app, relaunches without the reset flag, and finds it from the list alone, with a
  fresh composer restoring the text. The delete's persistence is asserted the same way. This is the
  strongest oracle available for local state and the build note says so rather than implying a
  server read.
- A **server switch** keeps drafts because the draft database is one file per server id
  (`ComposerDraftStoreProvider.path`), and the list is constructed against the active server's store.
  The unit test `testTwoServersNeverSeeEachOthersDrafts` pins the file isolation with the same channel
  id on two servers; the live suite has one configured server, so the switch itself is not live-run.
- The drafts list reads what the store holds when it opens (and on pull-to-refresh). There is no
  socket event for drafts — a draft is written by this device — so a *second* device's draft does not
  appear until the store is re-read. That is local-only by construction, not a missing feature.
- `ComposerDraftStoring` swallows store errors (a composer must still type when disk is full), so the
  list cannot distinguish "no drafts" from "the database could not be opened" — the provider's
  in-memory fallback then shows an empty list. The delete path detects its own failure by re-reading
  the store (§4); the read path has no such signal, and this note records the gap.

## 8. Publish

The code these numbers were measured on is commit `487ffb0`, rebased onto `origin/main` `bde77c5`.
The publish commit (this note's final revision) and the assertion
`git ls-remote origin refs/heads/main` == local `git rev-parse HEAD` are recorded in the card's
closing comment, because a commit cannot name its own SHA. Staged by pathspec: the T51 paths only —
the sibling cards' in-flight edits in the shared checkout were neither staged nor committed.
