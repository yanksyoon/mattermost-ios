# T37 — emoji reactions and the picker on the native surface

Behaviour reference: `mattermost/mattermost-mobile @ v2.45.0`
(`162f2560d0e1df073220f7701d5a67cc17c8abeb`) — `app/actions/remote/reactions.ts`,
`app/actions/local/reactions.ts`, `app/screens/reactions/*`, `app/screens/emoji_picker/*`,
`app/utils/emoji/*`. Licence: Apache-2.0, behaviour ported with attribution
(`docs/THIRD_PARTY_NOTICES.md` §14).

## What was built

| Piece | File |
| --- | --- |
| System emoji table (lookup, categories, search ranking) | `Mattermost/UI/Native/Emoji/SystemEmoji.swift` |
| Recently-used list (MRU, cap 27, per server+user) | `Mattermost/UI/Native/Emoji/EmojiRecents.swift` |
| Picker model (recents → custom → categories, search) | `Mattermost/UI/Native/Emoji/EmojiPickerModels.swift` |
| Picker sheet | `Mattermost/UI/Native/Emoji/EmojiPickerView.swift` |
| Alias rule, toggle machine, reactors, sheet order | `Mattermost/UI/Native/Reactions/ReactionModels.swift` |
| `POST /reactions`, `DELETE /users/{uid}/posts/{pid}/reactions/{emoji}` | `Mattermost/UI/Native/Reactions/ReactionAPI.swift` |
| Optimistic apply / coalescing / rollback / socket alignment | `Mattermost/UI/Native/Reactions/ReactionCoordinator.swift` |
| Pills (+ `+` chip, long-press reactors) | `Mattermost/UI/Native/Reactions/ReactionBarView.swift` |
| Reactor sheet | `Mattermost/UI/Native/Reactions/ReactionSheetView.swift` |
| Emoji table generator | `scripts/t37_emoji_build.py` → `Mattermost/Resources/emoji.json` |
| Server probe (measured endpoints) | `scripts/t37_reaction_probe.py` |

Wiring: `ChannelViewModel` and `ThreadViewModel` conform to `ReactionTarget` (they own the post
window and the socket patch); `ChannelServing` / `ThreadServing` gained the two writes with
throwing defaults, so a stub that does not implement them still draws pills and reports an error on
a tap instead of silently doing nothing.

## Measured facts (local Mattermost 9.11.19, `scripts/t37_reaction_probe.py`)

* add → `POST /reactions` `{user_id, post_id, emoji_name}`;
* remove → `DELETE /users/{uid}/posts/{pid}/reactions/{emoji}` (`+1` must be percent-encoded);
* **aliases are separate rows**: adding `thumbsup` and then `+1` leaves *two* reactions. Hence the
  pill is the alias group (`+1 2`), the write uses the canonical alias, and a remove deletes every
  alias the reader holds — otherwise the pill comes back on the next page load.
* login for the probe: `POST /users/login` with `X-Requested-With: XMLHttpRequest` answers the token
  in the **`Token` response header**.

## Two real defects the live run found (both fixed)

1. **`emoji.json` was never bundled.** `Mattermost/Resources/` is not one of the project's
   file-system-synchronised groups, so the generated table was absent from `Mattermost.app` and
   `SystemEmojiCatalogue.shared` silently fell back to T34's 60-name table — the picker would have
   shipped with 60 emoji and no alias folding. Fixed by adding the file reference + Resources build
   phase entry to `project.pbxproj`; `T37ReactionTests.testAliasesShareOnePillName` now asserts
   `degradedReason == nil` so a missing resource fails a test instead of degrading quietly.
2. **An optimistic tap did not redraw the pill.** `appendReaction`/`patch` mutate the stored posts,
   but `items` is *derived*, and only the socket path rebuilt. A tap reached `POST /reactions` and the
   pill kept drawing the old count. Fixed by rebuilding inside `applyReaction` when the post changed
   (both panes). Caught by the live UI run, not by the unit tests — the tests asserted the *store*.

A third, smaller issue: `@Published` fires before the value is written, so the picker's recents/custom
subscriptions rebuilt from the previous list (the picker lagged one record behind). The subscriptions
now build from the publisher's value.

## The one red test was a defect in the test, not in the picker

`testThePickerFromTheRowMenuAddsTheReactionTheServerStores` was recorded here as **still red** with a
guess ("the cell's action never runs, or the sheet's dismissal cancels the write"). Both guesses were
wrong, and the diagnosis this note shipped with was wrong too. The test tapped
`emojiPicker.emoji.grinning` and then asserted the server held **`tada`** and that
`post.<id>.reaction.tada` appeared — two different emoji. The assertion could never pass, whatever the
app did, and the failure message ("the server holds []") was the `tada` list, which is empty by
construction.

Corrected to one name for the cell, the oracle and the pill (`picked = "grinning"`). The test then
passed on its first run, 39.7 s, with no product change:

```
Test Case '-[MattermostUITests.T37ReactionsUITests testThePickerFromTheRowMenuAddsTheReactionTheServerStores]' passed (39.675 seconds).
** TEST SUCCEEDED **
```

The picker's tap path was therefore always working: the row menu opens the picker, the cell's action
runs, `self.sheet = nil` followed by `model.toggleReaction` in the same closure does **not** cancel the
write (the write is a `Task` owned by the coordinator, not by the dismissed view), and the pill appears.
Recorded plainly because the earlier line in this note said the opposite.

`testAliasSpellingsAreOnePillAndOneRemoveClearsEveryRowIHold` also over-promised in its name: it seeded
two spellings as *another* reader and then never removed anything. It now leaves one row from the other
reader **and two rows of mine under two spellings**, asserts the single pill `+1 3`, then taps **once**
and asserts the server holds neither of my rows while the other reader's survives (`+1 1` on screen).
That is the coordinator's `heldAliases` rule measured end to end — the path that would otherwise leave
a reaction coming back on the next page load.

## Verification

* **Unit tests on Catalyst, from a clean derived-data path** (the card's DoD):
  `python3 scripts/qa-test.py --platform mac --derived-data ~/Library/Developer/Xcode/DerivedData/mm-ios-t37-clean --label t37-catalyst-clean --only-testing MattermostTests`
  → `xcodebuild test … -destination platform=macOS,variant=Mac Catalyst -derivedDataPath
  ~/Library/Developer/Xcode/DerivedData/mm-ios-t37-clean` (a path that had never been built in, so the
  run is a full build), and the runner's own verdict:

  ```
  run        : t37-catalyst-clean
  outcome    : finished (xcodebuild rc=0, 101s)
  tests      : 1129 run, 4 skipped, 0 failed
  RESULT: PASS

  Test Suite 'All tests' passed …
  	 Executed 1129 tests, with 4 tests skipped and 0 failures (0 unexpected) in 48.844 (49.608) seconds
  ** TEST SUCCEEDED **
  ```

  The 4 skips are the pre-existing host-dependent ones and none of them is T37: `CertTrustTests
  testKeychainSetOverwritesAnExistingItem` (no keychain entitlement in an ad-hoc Catalyst host),
  `MentionPollerTests testLiveMentionsFetch_optIn` (opt-in live), and both
  `SelfSignedTrustTests` cases (need a cert fixture). **34 of the 1129 are T37** and all 34 passed
  (`grep -c "T37ReactionTests.*passed"` → 35, which is 34 tests + the suite line).

* **The live suite, 3/3 green** against a real Mattermost 9.11.19 at `127.0.0.1:8065`:

  ```
  TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
  TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
  python3 scripts/qa-test.py --platform ios --sim 023B9070-CAD0-409B-BFD0-78FF5CA5EACC \
    --label t37-live-final --only-testing MattermostUITests/T37ReactionsUITests
  ```

  `build/logs/t37-live-final.log` — see the run's table below. Every assertion reads its expectation
  back from the server (`GET /posts/{id}` → `metadata.reactions`), never from the app.

  | Test | What the server must show | Result |
  | --- | --- | --- |
  | `testTappingAPillWritesTheReactionToTheServerAndTappingAgainRemovesIt` | tap → my user id in `smile`; second tap → gone; pill 1 → 2 → 1 | pass |
  | `testThePickerFromTheRowMenuAddsTheReactionTheServerStores` | row menu → React → picker → `grinning` cell; my id stored under `grinning`; pill appears | pass |
  | `testAliasSpellingsAreOnePillAndOneRemoveClearsEveryRowIHold` | `+1` + `thumbsup` = one pill `+1 3`; one tap deletes **both** of my rows, the other reader's survives, pill `+1 1` | pass |

* **Screenshots** `docs/t37-shots/t37-01…06`: exported from that run's `xcresult` attachments by
  `python3 scripts/t37_export_shots.py ~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa/TestResults/t37-live-final-1105ae.xcresult docs/t37-shots`
  (the script exists so the export is repeatable and the names come from the test's own
  `XCTAttachment.name`, not from hand-renaming). They are the app's own frame on the simulator
  against the real server: the pill after an add, after a remove, the picker over the real
  `t36-threads` channel (custom section drawing `:t34parrot:` from `GET /emoji/{id}/image`, then the
  system categories), the pill the picker produced, the alias pill reading `👍 3` with no second
  `thumbsup` pill, and the same pill after the one-tap clear. No fixture-only mock screens.

* The iOS 18.5 simulator runtime on this host cannot run the test host at all
  (`Library not loaded: libswiftWebKit.dylib` — the runtime volume lacks it); everything above ran on
  iOS 26.0 (`iPhone 17 Pro`, `023B9070-CAD0-409B-BFD0-78FF5CA5EACC`).

* Attribution and parity are in place: `docs/THIRD_PARTY_NOTICES.md` §14 (the upstream read set for
  S16/S17 and the five endpoint shapes the server disagreed with) and the T37 row in
  `docs/parity.md` (which also corrects T34's "reactions are not tappable" and T35's "no emoji
  picker" from this card's perspective).

## Known limits / follow-ups

* The picker is reachable from the row menu, a pill's `+` chip and the composer toolbar; a *first*
  reaction on a message with no pills needs the row menu, and the row menu is only offered when the
  `.composer` surface is native (T35's write-surface gate). That coupling is inherited, not new, but
  it means a web-composer pane cannot react natively yet.
* Recents live on the device (per server **and** user, cap 27). They are not the server's
  `recent_emojis` preference, so they do not follow the account to another device — upstream keeps
  its list in the per-server database, so neither client syncs it.
* Search ranking uses a deterministic subsequence tier instead of upstream's Fuse scores (documented
  in `SystemEmoji.swift`); same ordering rules for the exact/prefix tiers.
* Reactor names come from the pane's profile cache; an unknown reactor draws "Unknown user" rather
  than an invented name, and the sheet triggers one batched `/users/ids` for the ids it lacks.
* No skin-tone variants, and custom emoji are listed from `GET /emoji` only (no upload/deletion).
* The un-driven edge: **two readers reacting at the same instant**. The *machine* half is covered by
  the coalescing unit tests (one request in flight, `desired` moves, one rollback) and by the
  same-instant alias test, and the *wire* half now is too: a reaction written by a second client while
  the pane is open arrives over the socket and draws exactly one pill
  (`testForeignReactionArrivesOverTheSocketOnce`). What is still **not** driven on this host is a
  genuine race — the web app reacting *while* the native pill is being tapped, so that our own write
  and that client's `reaction_added` land in the same second. Both paths are set-shaped and go through
  the same call (`applyReaction`), which is what makes the double delivery harmless — but that is an
  argument, not a measurement (T37-AV F1/F5; the earlier wording here claimed the socket path made it
  idempotent "by construction", when in fact the scope refused every reaction event, so that path never
  ran at all).
* **Undriven and now listed as such:** a reaction made from the **thread pane**. `ThreadView.swift`'s
  row menu opens the picker for a thread reply and `ThreadViewModel.handle` has the same
  `reaction_added`/`reaction_removed` branches as the channel pane, and the routing half is unit-pinned
  (`T37SocketReactionRoutingTests`), but no live test drives a reaction inside an open thread — T37-AV
  F5 named it, and this round documents it instead of claiming it.
* **Cross-card note for T34's live suite** (not this card's file, which stays untouched for
  t_667988fd): `MattermostUITests/T34-ChannelPostListUITests.swift` derives the pill it looks for from
  the *server's* spelling of the first reaction on its `reactedPost`
  (`reactions.first?["emoji_name"]`). That is `tada` in the current fixture, which has no alias, so it
  still resolves — but the moment that fixture's first reaction is an alias (`thumbsup`/`+1`), the
  drawn identifier is the canonical `+1` and that test would look for a pill that is correctly not
  there. T37's canonicalisation is upstream's rule, so the fix belongs in that test (canonicalise the
  name it expects, or assert by count) when its owner next touches it; recorded here so it is not
  discovered as a surprise red.

## T37-R — the T37-AV repair (2026-10-26, card `t_cd4723f2`)

The T37-AV round (`t_de2110ce`) returned **FAIL** on `origin/main f02e345`, with one HIGH finding, one
MEDIUM identifier finding, one LOW row-accuracy finding, one DoD finding and one coverage finding. This
round closes all five. Nothing in the sections above was deleted: it is what T37 did, and the one
sentence in it that claimed something untrue is corrected in place (§Known limits).

### F1 (HIGH) — a foreign reaction now reaches the pane

The app has one WebSocket per server, and its only route into the panes is
`TeamSidebarCoordinator.onTeamEvent` → `ChannelPaneCoordinator.handle`, gated by
`TeamSocketScope.accepts`. That gate **refused** `.reactionAdded`/`.reactionRemoved` on the stated
grounds that "a reaction names a post, not a channel". The AV measured the opposite at three
independent points (`av-ws-watch.log`: the server pushes `reaction_added` to this user's own socket
with `channel_id` inside the reaction payload; `av-t37-socket.log`: no pill in 30 s;
`av-t37-contrast.log`: a foreign `posted` on the same socket *does* arrive). So
`ChannelViewModel.handle`'s and `ThreadViewModel.handle`'s reaction branches were unreachable in the
running app, and the card's own unit tests could not see it because they called `handle` directly.

Three changes, in the order the frames travel:

1. `MMReaction` parses `channel_id`. It is the **routing** fact, so `encode(to:)` omits it when empty:
   the JSON this client writes back into a row's `metadata.reactions` keeps the shape the server's own
   rows have.
2. `SocketEvent`'s reaction decoder takes `channel_id` from inside the reaction JSON (where 9.11.19
   puts it) and falls back to the frame's `data.channel_id`, so a proxy that strips one form does not
   produce a silently unroutable event.
3. `TeamSocketScope` attributes a reaction exactly like every other channel-scoped event —
   `reaction.channelId.isEmpty || isInActiveTeam(channelID: reaction.channelId)` — and an
   unattributable reaction is **accepted** (each pane keeps only its own posts,
   `postsByID[reaction.postId] != nil`), the same reasoning the scope already used for
   `threadFollowChanged`.

Pinned by `MattermostTests/T37SocketReactionRoutingTests.swift` (7 tests): the measured frame decodes
with its channel; a frame without one still decodes; the scope admits the open channel and another
channel of the active team and refuses another team's; and one test drives the **production fan-in**
(real `TeamSidebarCoordinator` + its scope + `onTeamEvent` wired exactly as `MattermostApp` wires it →
`ChannelPaneCoordinator.handle` → the row grows its pill, the other team's reaction is refused, the
foreign removal clears it). That last test is the one that would have caught the shipped defect.

The tests bite: with the branch restored to `return false` (the shipped behaviour) and nothing else
changed, `Executed 7 tests, with 8 failures (0 unexpected) in 5.339 (5.341) seconds` — three of the
seven fail by name (`docs/t37r-mutation-2026-10-26.log`). Restored: 7/7 green.

Live proof, the two AV tests adopted unmodified in substance (`T37ReactionsUITests`):

```
python3 scripts/qa-test.py --platform ios --sim 023B9070-CAD0-409B-BFD0-78FF5CA5EACC \
  --derived-data ~/Library/Developer/Xcode/DerivedData/t37r-ios --label t37r-socket \
  --only-testing MattermostUITests/T37ReactionsUITests/testForeignReactionArrivesOverTheSocketOnce \
  --only-testing MattermostUITests/T37ReactionsUITests/testForeignPostArrivesButItsReactionDoesNot
→ tests: 2 run, 0 skipped, 0 failed (122 s)   ·  Executed 2 tests, with 0 failures …  ** TEST SUCCEEDED **
```

`testForeignReactionArrivesOverTheSocketOnce` → 21.9 s (fails in 65 s with 2 failures at `f02e345`),
`testForeignPostArrivesButItsReactionDoesNot` → 30.6 s. `docs/t37r-socket-2026-10-26.log`.

### F2 (MEDIUM) — `emojiPicker.search` is in the tree now

The container identifier sat on the layout `VStack`, so its children inherited it and the search
`TextField` reported `emojiPicker` (0 occurrences of `emojiPicker.search` in the AV's hierarchy dump).
The sheet now carries `.accessibilityElement(children: .contain)` **with** the identifier, which makes
the sheet its own element and leaves every child's identifier intact, and the container id moved off
the modifier chain that ends in `.toolbar` (one id, one place).

The adopted live tests assert it rather than work around it: `searchInPicker` uses
`emojiPicker.search` and **fails** if the identifier does not resolve — the AV harness's fallback ("a
text field identified `emojiPicker`") is deliberately gone, so the identifier cannot rot silently
again. It passes in `testRecentsSurviveRelaunch` and `testComposerPickerInsertsThePickedEmoji`
(`docs/t37r-live-2026-10-26.log`).

### F3 (LOW) — the parity rows now say what the code does

Code unchanged (the documented behaviour was wrong, not the behaviour). `docs/parity.md`:

* T37: `Reactors` → `ReactionReactors.rows`, and it **keeps the server's order**; it does not move the
  reader to the top (measured in the AV's sheet screenshot: the other reader is drawn first).
* T37: `ReactionGroups` → `ReactionAliases.groups`.
* T35: the composer's picker inserts the **character** for a system emoji (`🎉`, measured) and only a
  **custom** emoji's shortcode (`:t34parrot:`); `EmojiPickerViewModel.insertion(for:)` is called by a
  unit test only, so the `:` list and the picker do **not** share an insertion function.
* T37's socket sentence is new and states the F1 rule (attributed by `channel_id`, unattributable ones
  accepted and filtered per pane).

The insertion rule is not just prose any more: `testComposerPickerInsertsThePickedEmoji` drives both
branches against the real server.

### F4 (MEDIUM) — the two commits without a card id, recorded

History is published; it is not rewritten. For the record, of T37's four commits
(`b54ec73..f02e345`):

| Commit | Subject | Card id |
| --- | --- | --- |
| `b8b5779` | `feat(t37): emoji reactions and the picker on the native post list` | **absent** |
| `335ffae` | `fix(t37): rebuild the rows after an optimistic react; live suite` | **absent** |
| `106fb73` | `test(t37): tap and assert one emoji, and prove one tap clears every alias` | `Card: t5b764481 (T37)` |
| `f02e345` | `docs(t37): parity row, NOTICE section 14, and the verification record` | `Card: t5b764481 (T37)` |

The T37-R commit that carries this section names its own card (`Card: t_cd4723f2`, with the T37 card
id it repairs) in its body.

### F5 (MEDIUM) — coverage: seven adopted live tests, and the two gaps stated as gaps

`MattermostUITests/T37ReactionsUITests.swift` went from 3 tests to **10**, against the real 9.11.19 at
`127.0.0.1:8065`, every expectation read back from the server:

| Test | What it drives | Time |
| --- | --- | --- |
| `testTappingAPillWritesTheReactionToTheServerAndTappingAgainRemovesIt` | the original add/remove | 30.3 s |
| `testThePickerFromTheRowMenuAddsTheReactionTheServerStores` | the original picker write | 27.5 s |
| `testAliasSpellingsAreOnePillAndOneRemoveClearsEveryRowIHold` | the original alias rule | 31.8 s |
| `testBurstOfTapsConvergesAndNeverDrifts` | **new** — 7 then 7 taps with no settling, pill == server count, one row of mine, three stable samples | 49.2 s |
| `testServerCustomEmojiIsOfferedAndWritten` | **new** — the server's `:t34parrot:` in the Custom section, written under its own case-sensitive name, drawn as a pill | 38.5 s |
| `testReactorSheetNamesBothReadersIncludingMe` | **new** — the reactor sheet, both display names, `(you)` on mine, no "Unknown user" | 35.1 s |
| `testRecentsSurviveRelaunch` | **new** — pick, terminate, relaunch without the reset seam, the recent is still there | 101.9 s |
| `testComposerPickerInsertsThePickedEmoji` | **new** — composer mode: `🎉` for a system emoji, `:t34parrot:` for a custom one | 36.4 s |
| `testForeignReactionArrivesOverTheSocketOnce` | **new (F1)** — another client's add and remove arrive over the socket | 29.4 s |
| `testForeignPostArrivesButItsReactionDoesNot` | **new (F1 control)** — the foreign post arrives, and so does its reaction | 28.8 s |

One portability note, because it is a fact about XCUITest rather than about the product: the burst
test's first port tapped through `element.coordinate(…)` and failed with `Failed to get matching
snapshot: No matches found` *at the burst* — the row re-renders after every write and a re-resolving
coordinate raises the moment the pill is between frames. The taps now go through the application's
coordinate space at the pill's captured frame, and the poll reads a label only when the element
exists. No assertion was weakened: the expected counts, the server oracle and the "exactly one row of
mine" check are the AV's.

**Still undriven, now stated** (also in §Known limits): a reaction made from the **thread pane**
(`ThreadView.swift`'s row menu opens the picker for a reply; `ThreadViewModel.handle` has the same
branches; the routing half is unit-pinned — but no live test reacts inside a thread), and the genuine
two-client **same-instant race** (the web app reacting while the native pill is tapped).

### Verification — T37-R

Catalyst units, from derived-data paths that had **never been built in** (both runs full builds), the
runner's own lines:

```
--derived-data ~/Library/Developer/Xcode/DerivedData/t37r-cat-before   (at f02e345 + this card's new test file absent)
  tests      : 1129 run, 4 skipped, 0 failed
  Executed 1129 tests, with 4 tests skipped and 0 failures (0 unexpected) in 48.173 (48.848) seconds
  ** TEST SUCCEEDED **                                    docs/t37r-catalyst-before-2026-10-26.log

--derived-data ~/Library/Developer/Xcode/DerivedData/t37r-cat-after    (this repair, 41 T37 tests)
  tests      : 1136 run, 4 skipped, 0 failed
  Executed 1136 tests, with 4 tests skipped and 0 failures (0 unexpected) in 44.648 (45.283) seconds
  ** TEST SUCCEEDED **                                    docs/t37r-catalyst-after-2026-10-26.log
```

The 4 skips are the same host-dependent ones as before the repair, none of them T37
(`CertTrustTests.testKeychainSetOverwritesAnExistingItem`, `MentionPollerTests
testLiveMentionsFetch_optIn`, both `SelfSignedTrustTests`). The 7 extra tests are this card's
`T37SocketReactionRoutingTests` (1136 − 1129), and `grep -c "T37SocketReactionRoutingTests.*passed"`
answers 8 = 7 tests + the suite line.

The live suite, whole file, one run:

```
python3 scripts/qa-test.py --platform ios --sim 023B9070-CAD0-409B-BFD0-78FF5CA5EACC \
  --derived-data ~/Library/Developer/Xcode/DerivedData/t37r-ios --label t37r-live-full2 \
  --only-testing MattermostUITests/T37ReactionsUITests
→ tests      : 10 run, 0 skipped, 0 failed          (xcodebuild rc=0, 466 s)
  Executed 10 tests, with 0 failures (0 unexpected) in 408.830 (408.844) seconds
  ** TEST SUCCEEDED **                                    docs/t37r-live-2026-10-26.log
```

Everything above ran on iOS 26.0 / `iPhone 17 Pro` (`023B9070-CAD0-409B-BFD0-78FF5CA5EACC`) against the
real Mattermost 9.11.19 at `127.0.0.1:8065`; the iOS 18.5 runtime on this host still cannot run the
test host (`libswiftWebKit.dylib` missing). Not validatable here, unchanged from T37-AV: real APNs, a
Mattermost Cloud workspace, and the same-instant two-client race.
