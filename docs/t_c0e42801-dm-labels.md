# DM rows read "Direct message" instead of a person's name — mechanism and repair

Card: `t_c0e42801` (reported against the installed native build, Debug `2d2b903`).
Branch: `wt/t_c0e42801`. Base: `ee71f23` (post-INTEGRATE main).

## 1. What the reader saw

On a workspace with a few hundred channels, a large share of the left sidebar's direct-message rows
read **"Direct message"**. Not one row: many of them, in the same load.

## 2. Why (each link measured in code, no guessing)

1. **A 1:1 DM has no display name.** Mattermost sends `display_name: ""` for a DM; the channel's
   `name` is `<userID>__<userID>`. `ChannelSidebarDerivation.displayName` therefore has exactly one
   usable source for the row — the label map — and the literal `"Direct message"` is what it draws
   when that map has no entry (`ChannelSidebarModels.swift`, `displayName(channel:kind:data:)`).
2. **The label map was all-or-nothing.** `SessionChannelSidebarService.load` ran the whole label
   step inside `abandoning(after: 10)` and, on a lost deadline, assigned
   `(labels: [:], terms: [:])` — every DM in the list degraded at once. That is the shape the report
   describes ("a lot of them"), and it is the defect.
3. **The step was the slowest of the load by construction.** Every id went into **one**
   `POST /users/ids` (no chunking), after one `GET /channels/{id}/members` per group channel in
   batches of 8. On a big workspace that is a large body plus many round trips: exactly what a 10 s
   deadline hits.
4. **Two silent row-droppers even on success.** An id the server did not return was dropped by
   `compactMap`/`people.isEmpty`; a self-DM (`<myid>__<myid>`) filtered itself out of
   `memberIDsByChannel`, so it could never be labelled.

## 3. The repair (in the card's own order)

1. **Profiles already in hand, before any request.** New `UserProfileCache`
   (`Mattermost/Core/MM/UserProfileCache.swift`): one in-memory `InMemoryStore` per **server**
   (`UserProfileCache.shared(for: server.id)`), dropped on sign-out/expiry/server removal
   (`ChannelSidebarCoordinator.deactivate`). `DirectLabelResolver` asks it first, so a person another
   screen has already fetched costs nothing. The channel pane feeds it:
   `SessionChannelService.users(ids:)` remembers every batch it fetches
   (`ChannelPaneCoordinator.service(for:)` passes the same per-server cache).
2. **Chunked profile fetches.** `APIClient.users(ids:)` now dedupes, skips an empty list without a
   request, and splits at `APIClient.usersBatchSize = 100`, merging the answers in input order — so
   every caller of the endpoint benefits, not only the sidebar. `DirectLabelResolver` fetches its
   **own** chunks (≤100) so that one failed chunk does not lose the others.
3. **Incremental publication.** `DirectLabelResolver` (`UI/Native/Sidebar/DirectLabelResolver.swift`)
   publishes the map it can already name after every step (cache hit, each profile chunk, each group
   batch). `load` consumes it through the new `abandoningLatest(after:initial:)`, which resumes with
   **what the work had so far** instead of `nil`: a lost deadline now costs only the rows still
   outstanding. `abandoning` (the `nil`-on-timeout form) is kept for the optional calls that have no
   partial answer.
4. **A self-DM reads "You"** (upstream's own label for the conversation with yourself), never
   "Direct message", and carries my own username/name as quick-switcher terms when my profile is in
   hand.

Behaviour on a genuinely unresolvable id (a 403, an account the server will not return) is unchanged
and deliberate: that row still draws "Direct message". The point of the repair is that it is now
**one row**, not the whole list.

## 4. Diagnostics

The sidebar's diagnostic line already printed `service=labels ok (N)`. It now prints
`labels ok (N/M)` — labels resolved against the number of direct channels in the load — so the gap
between "the server would not name these people" and "the client lost them" is a number, not a guess.
Unit-pinned: `testTheLoadReportsLabelsAgainstTheNumberOfDirectChannels` asserts `labels ok (1/1)`.

## 5. Verification (what actually ran)

`xcodebuild test -only-testing:MattermostTests/T33DmLabelResolutionTests` on iPhone 16 Pro
(iOS 18.3.1, simulator) — **14 tests, 0 failures**
(`build/logs/integrate/t-c0e42801-lexp.log`). They run the production resolver and the production
`load` against a scripted transport; no socket, no server.

| Property | Test | Result |
| --- | --- | --- |
| A DM row shows the other person's name; zero "Direct message" rows | `testADirectMessageRowShowsTheOtherPersonsNameAndNeverDirectMessage` | pass |
| 250 DMs → requests of 100/100/50, all 250 named, no "Direct message" row | `testOneOversizedRequestIsNeverSent` | pass |
| A profile already in hand makes **no** request | `testProfilesAlreadyInHandMakeNoRequestAtAll` | pass |
| The channel pane's fetch fills the cache the sidebar reads | `testTheChannelPaneRemembersItsProfilesForTheSidebar` | pass |
| One failed batch does not discard the batch that answered | `testAFailedBatchKeepsTheRowsTheOtherBatchesNamed` | pass |
| A lost deadline keeps what landed; only the outstanding batch is unlabelled | `testADeadlineKeepsWhatHasAlreadyLandedInsteadOfDiscardingTheWholeMap` | pass |
| Self-DM reads "You" (and no request is made) | `testASelfDirectMessageReadsYouNotDirectMessage` | pass |
| Self-DM carries my own search terms | `testASelfDirectMessageCarriesMyOwnSearchTerms` | pass |
| A deactivated account is still named | `testADeactivatedProfileStillNamesItsRow` | pass |
| An unresolvable id leaves one honest "Direct message", the rest named | `testAProfileTheServerWillNotNameLeavesTheRowHonestAndTheOthersNamed` | pass |
| A GM names every member but me | `testAGroupMessageNamesEveryMemberButMe` | pass |
| **The card's falsifier**: 320 DMs + 20 GMs + a public channel → 340 direct rows, **0** labelled "Direct message"/"Group message", every request ≤ 100 ids | `testALargeSidebarDrawsNoDirectMessageRows` | pass |
| `load` end-to-end reports `labels ok (1/1)` | `testTheLoadReportsLabelsAgainstTheNumberOfDirectChannels` | pass |
| A second load names the DMs without another profile request | `testASecondLoadNamesTheDirectMessagesWithoutAnotherProfileRequest` | pass |

Whole `MattermostTests` suite: **1744 run / 8 skipped / 0 failures**
(`build/logs/integrate/t-c0e42801-units.log`, `XCODEBUILD_EXIT=0`) — the 14 new tests on top of the
merged-tree baseline of 1730 run / 8 skipped / 0 failed. `build-for-testing` on this tree (app +
`MattermostTests` + `MattermostUITests`): **TEST BUILD SUCCEEDED**
(`build/logs/integrate/t-c0e42801-build.log`, `XCODEBUILD_EXIT=0`).

## 6. What was **not** verified on this host — stated, not papered over

- **No live 300+-channel workspace was launched.** That needs a server with 300+ channels and a
  signed-in account on this machine; the card's launch-and-count falsifier is reproduced at the
  derivation level instead (`entries(...)` is the same code the list draws from, and the fixture is
  340 direct channels), plus the load itself end-to-end against a scripted transport. A live run
  would add nothing about the mechanism — the deadline and the batching are local facts — but it is
  the one acceptance step this host could not perform.
- `N/M` from a real load on such a workspace is therefore not reported here; the diagnostics line is
  ready for it (`service=labels ok (N/M)` in the `-shellSnapshot` dump).

## 7. Limits that stay (by design)

- The cache is **in memory and per process**: a relaunch starts empty and pays the requests again
  (chunked). Persisting it is a separate decision (the profile rows would need an eviction policy).
- A group channel's member list is still read one channel per request (`per_page=100`), 8 channels at
  a time — there is no "members of many channels" endpoint. A GM with more than 100 members names the
  first 100.
- The `InMemoryStore` copy is unbounded in users. A workspace's member list is bounded by the
  workspace, and it is dropped at sign-out; no eviction rule was invented for it.
- `parity.md` owes no change: upstream's `getChannelName` names a DM from the partner's profile and
  calls a self-DM "You", which is now what this client does. The row was never a parity promise about
  *when* the profile arrives.
