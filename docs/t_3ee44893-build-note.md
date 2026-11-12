# t_3ee44893 — the sidebar's DM rows draw the other person's face and their presence

Upstream reference: mattermost/mattermost-mobile @ `162f2560`
(`app/components/channel_item/channel_item.tsx` → `ChannelIcon`, `app/components/channel_icon/`,
`app/utils/user_helper.ts` `getUserIdFromChannelName`, `app/client/rest/users.ts`
`getStatusesByIds`, `app/actions/websocket/user.ts` `status_change`). Apache-2.0, behaviour ported
with attribution per `docs/THIRD_PARTY_NOTICES.md` §3; no upstream source copied.

## 1. What changed

| file | what |
|---|---|
| `Mattermost/UI/Native/Sidebar/SidebarPresence.swift` (**new**) | `SidebarParticipant` (the row's people: id, name, initials), `SidebarPresenceSnapshot` (presence **and when it was observed**), `SidebarPresenceRules` (batch size, freshness window, decay horizon, chunking, the accessibility word), `SidebarPresencePalette` (the dot's colours, in one place), and `SidebarPresenceStore` (the one object that may spend a request: batched `POST /users/status/ids`, a per-person freshness cache, socket patches, and the counters the numbers below come from). |
| `.../Sidebar/DirectLabelResolver.swift` | `DirectLabelMap` now carries `participants` — the *same* membership read that produced the label (a DM's `<id>__<id>` name, a GM's member list) also hands over the account ids the avatar and the presence need. A self-DM takes its participant from the reader's **already-cached** profile (nothing is fetched for it, the cost rule `T33DmLabelResolutionTests` pins); without one it keeps the person glyph. |
| `.../Sidebar/ChannelSidebarModels.swift` | `ChannelSidebarEntry` gains `directParticipants` + `presence` (and `showsDirectAvatar`); its `accessibilityValue` gains the presence word for a DM. `ChannelSidebarData` gains `directParticipants` and `presence`. `entries(from:)`/`groups(from:)` take an injectable `now` so presence can be **aged** at build time. |
| `.../Sidebar/ChannelSidebarService.swift` | `ChannelSidebarServing.statuses(ids:)` (defaulted: a fixture answers "nothing known"); the session implementation goes through the API client like every other read; `SessionChannelSidebarService.load` fills `directParticipants`; `ChannelListViewModel` owns the store (`refreshPresence(force:)`, `presenceDiagnostics`) and applies `status_change` in place. |
| `.../Sidebar/ChannelSidebarView.swift` | The DM/GM row draws `SidebarChannelAvatar` (face + presence dot) or `SidebarCompositeAvatar` (GM); the sidebar injects the app's one `AvatarImageStore` for the server (`ChannelPaneCoordinator.avatarStore`); a `.task` polls presence once a minute **while the list is on screen** and is cancelled with it. |
| `MattermostTests/T3ee44893SidebarAvatarPresenceTests.swift` (**new**) | 14 tests: the six failing-first criteria, the adversarial pairs, and the render/AX evidence test. |
| `docs/t3ee44893-shots/dm-rows.png` | the row view's own output (see §5). |

## 2. Decisions the card asked to be made and recorded

**GM composite.** A GM row draws the first participant's face at 22 pt, the second's at 0.62× in the
bottom-trailing corner **when the conversation has exactly two people**, and from three on a `+N`
chip counting the people *not* drawn (`+2` for a three-person conversation — the lead's face plus
"two more"). Upstream overlaps the pictures; a 22 pt column cannot hold three legible faces, and a
label is worse than a face only when it lies — `+2` does not. **A GM row carries no presence dot**: a
single dot cannot describe several people's statuses, and upstream draws presence for a DM (one
other person). This is stated again in `SidebarCompositeAvatar` and in `SidebarPresence.swift`'s
header.

**Offline is quiet, not absent — and unknown is not offline.** Offline draws a hollow ring; a person
whose status has not been read yet draws the *same* quiet ring but the row's accessibility value
says nothing (`SidebarPresenceRules.word(for:)` returns nil for `.unknown`). Saying "Offline" before
the server has answered would be a claim, and the card is about not telling lies in a list.

**"Theme colours".** The native shell has no server-theme palette: `ThemeSync` carries only the
light/dark appearance (the server's own colours live in the webview's CSS). So the dot's mapping is
`SidebarPresencePalette` — the **system's** semantic colours (`.green`/`.orange`/`.red` and
`Color.secondary.opacity(0.55)`), which follow light/dark and Increase Contrast, in one function, so
a server theme override is a one-place change and no row hard-codes an RGB value. This is a
limitation of the shell today, stated rather than hidden.

**Why a poll, when the server has `status_change`.** Measured earlier in this repo
(`docs/parity-legacy.md`, T41 row): on 9.11.19 `status_change` is addressed to the account **whose
status changed**, so a peer's presence never arrives over the socket. This card therefore does both:
it applies a `status_change` frame in place when one arrives (requirement 4's test drives exactly
that), and it re-reads the people it is drawing every `pollInterval` while the list is on screen.
`staleAfter` is the honest floor: an `online` that has not been confirmed in ten minutes is drawn
offline, so a dropped socket cannot leave a green dot alive.

## 3. Cost — the measured numbers

All counts are the client's **own request decisions**, counted by the test double over the real
`ChannelListViewModel` + `SidebarPresenceStore` code path (`testTwoHundredRowsCostTwoRequests…`,
`testAPollAfterTheWindowAsksAgainOnce`, `testEachPersonCostsOnePictureRequest…`):

| situation | requests |
|---|---|
| 200 DM rows, first load | **2** `POST /users/status/ids` (200 ids, chunked at `statusBatchSize = 100`) |
| a redraw / scroll of those 200 rows | **0** |
| two more polls inside the freshness window (60 s) | **0** |
| one poll after the window | **2** (two chunks; still 2 for 200 rows, never 200) |
| a `status_change` frame | **0** — the payload carries the new value |
| a person's picture, however many rows and redraws | **1** per distinct account (`AvatarImageStore`'s memory cache → disk → network, 404 remembered for the session, a transient failure retried after 30 s) |
| 200 distinct people drawn twice | **200** picture requests, not 400 |

The live server was **not** re-measured for this card: the dev fixture has a handful of DMs, not
200 accounts, and inventing a 200-account fixture would measure the fixture rather than the client.
What is left unverified is stated in §6.

## 4. Accessibility

The row stays **one** element (T8e's rule — `.accessibilityRepresentation` replaces the row's
subtree), so the face is decoration (`.accessibilityHidden(true)`) and the **presence word joins the
row's value**: "Ada Lovelace" keeps its label, the value reads "Online" / "Away" / "Do not disturb" /
"Offline", and a mention still reads "3 mentions, Online". A GM value carries no status, and an
unread status adds nothing.

## 5. Evidence

* **The row as drawn.** `docs/t3ee44893-shots/dm-rows.png`, written by
  `testTheRowRendersItsFaceAndPresenceForTheEvidenceScreenshot` — the real `ChannelSidebarRow` view
  in a `UIHostingController`, with a stubbed `AvatarImageStore`. Six rows: online (green disc), away
  (orange), dnd (red), offline (**hollow ring**), a three-person GM (`+2` chip, no dot), and an
  account whose picture 404s (**"AT" initials**, green dot). The image is 59,248 bytes; a blank
  canvas of that size compresses far smaller, and the test asserts a floor so the file cannot be an
  empty render.
* **The accessibility values**, printed by the same test:
  `dm-online="Online" | dm-away="Away" | dm-dnd="Do not disturb" | dm-offline="Offline" | gm-composite="" | dm-initials="Online"`.
* **Tests.** `MattermostTests/T3ee44893SidebarAvatarPresenceTests` — 14 run / 0 failed
  (`build/logs/ios-20261112-192149.log`), added to the full unit lane.
* **The adversarial pairs were run, not asserted in prose:**
  * presence made static (the `.statusChange` case returns `.ignored`) →
    `testAStatusChangeFrameMovesTheDotWithoutARequest` fails on three assertions
    (`build/logs/ios-20261112-191744.log`: "ignored" ≠ "applied", `online` ≠ `offline`,
    "Online" ≠ "Offline");
  * the freshness cache dropped (`needed = unique`, so every pass re-asks) →
    `testTwoHundredRowsCostTwoRequestsAndARedrawCostsNone` fails: **6** requests / 600 ids instead
    of 2 / 200 (`build/logs/ios-20261112-191854.log`).

## 6. What this leaves (stated, not hidden)

* **No live UI run for this card.** The rows are verified by the derivation/unit lane and by the
  rendered row; the signed-in app was not driven against the dev server for this change, so the
  screenshot is the view's own render rather than a device capture (the card allows either).
* A DM/GM whose profiles the load could not name keeps the **glyph** — initials need a name, and a
  face cannot be invented. The row then says "Direct message"/"Group message" exactly as before.
* Presence is a per-server, session-lifetime cache; a poll costs two requests a minute for a
  200-DM list while the sidebar is on screen (one for a small account). Nothing here persists across
  a launch — presence is not a fact worth caching to disk.
* A `status_change` frame about somebody who has no DM row in this team is ignored (no rebuild, no
  request) — the account may have a DM in another team, and that list has its own model.
* The composite cap is `+9` for readability (`+10` would not fit a 13.6 pt chip); the label still
  names everyone.
