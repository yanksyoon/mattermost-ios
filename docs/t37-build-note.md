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

## Verification

* `xcodebuild test -only-testing:MattermostTests` → **1129 tests, 0 failures** (3 skipped,
  pre-existing), of which 34 are new in `MattermostTests/T37ReactionTests.swift`.
* Live UI (`scripts/qa-test.py`, `iPhone 17 Pro`, throwaway server at `127.0.0.1:8065`):
  * `testTappingAPillWritesTheReactionToTheServerAndTappingAgainRemovesIt` — **passes**: a reaction
    another account left is drawn as `smile 1`; a tap makes the server hold mine and the pill reads
    `smile 2`; a second tap clears the server row and the pill returns to `smile 1`.
  * `testAliasSpellingsAreOnePillAndOneRemoveClearsEveryRowIHold` — **passes**: `+1` and `thumbsup`
    left by another account draw **one** pill `+1 2`, with no `thumbsup` pill.
  * `testThePickerFromTheRowMenuAddsTheReactionTheServerStores` — **still red**: the row menu opens
    the picker and the cells are found and tapped, but no `POST /reactions` arrives, so either the
    cell's action never runs or the sheet's dismissal cancels the write. Not yet diagnosed; the
    picker's model, the write and the sheet are covered by unit tests, but the *tap → write* path
    through the picker is **not verified live**. Treat this as the one open item on T37.
* The iOS 18.5 simulator runtime on this host cannot run the test host at all
  (`Library not loaded: libswiftWebKit.dylib` — the runtime volume lacks it); everything above ran on
  iOS 26.0 (`iPhone 17 Pro`).

## Known limits / follow-ups

* The picker is reachable from the row menu, a pill's `+` chip and the composer toolbar; a *first*
  reaction on a message with no pills needs the row menu, and the row menu is only offered when the
  `.composer` surface is native (T35's write-surface gate). That coupling is inherited, not new, but
  it means a web-composer pane cannot react natively yet.
* Search ranking uses a deterministic subsequence tier instead of upstream's Fuse scores (documented
  in `SystemEmoji.swift`); same ordering rules for the exact/prefix tiers.
* Reactor names come from the pane's profile cache; an unknown reactor draws "Unknown user" rather
  than an invented name, and the sheet triggers one batched `/users/ids` for the ids it lacks.
