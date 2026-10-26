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
* The un-driven edge: **two readers reacting at the same instant** is covered by the coalescing unit
  tests (one request in flight, `desired` moves, one rollback) and by the same-instant alias test, but
  a UI-level race against a second *client* (the web app reacting while the native pill is tapped) is
  not driven on this host; the socket path makes it idempotent by construction
  (`applyReaction` is set-shaped and is the same call both paths use).
* **Cross-card note for T34's live suite** (not this card's file, which stays untouched for
  t_667988fd): `MattermostUITests/T34-ChannelPostListUITests.swift` derives the pill it looks for from
  the *server's* spelling of the first reaction on its `reactedPost`
  (`reactions.first?["emoji_name"]`). That is `tada` in the current fixture, which has no alias, so it
  still resolves — but the moment that fixture's first reaction is an alias (`thumbsup`/`+1`), the
  drawn identifier is the canonical `+1` and that test would look for a pill that is correctly not
  there. T37's canonicalisation is upstream's rule, so the fix belongs in that test (canonicalise the
  name it expects, or assert by count) when its owner next touches it; recorded here so it is not
  discovered as a surprise red.
