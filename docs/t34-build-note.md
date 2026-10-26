# T34 — native channel pane / post list (build note)

Behaviour reference: `mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)`.

## What shipped

New surface, all under `Mattermost/UI/Native/Channel/`:

| File | Lines | Role (upstream counterpart) |
|---|---|---|
| `ChannelAPI.swift` | 66 | REST: channel posts page, `/users/ids`, file bytes, `/channels/{id}/members/me`, `/emoji` (`remote/posts`, `files`, `users`, `custom_emoji`) |
| `ChannelService.swift` | 104 | Page-then-profiles load order; `ChannelServing` protocol with `pageSize`, `membership`, `fileData`, `customEmoji`, `emojiImage` |
| `ChannelViewModel.swift` | 516 | `@MainActor` state machine: load/paginate/socket-patch/scroll anchor/expanded set/generation guard (`post_list/index.tsx` + `actions/views/post_list`) |
| `ChannelPaneCoordinator.swift` | 159 | Per-server LRU (6 channels) of view models + image caches + one emoji catalogue per server; auth teardown |
| `ChannelScrollPosition.swift` | 282 | Finds the `UIScrollView` under a SwiftUI `ScrollView`, registers each row's own `UIView`, and restores the reader's place by a point offset measured against the viewport — the "put the anchored post back where the reader left it" half of paging |
| `ChannelView.swift` | 533 | List, top sentinel, states, scroll restore, sticky composer stand-in |
| `PostRowView.swift` | 462 | Row: avatar/gutter, header, body, attachments, reactions, system/deleted rows, inline emoji glyphs |
| `PostListModels.swift` | 471 | `PostListDerivation` — pure derivation of rows, separators, grouping, folds, labels |
| `EmojiCatalogue.swift` | 205 | `GET /emoji` name list (published) + one-at-a-time image cache, shared per server |
| `Markdown/MarkdownModel.swift` | 152 | Inline/block tree, `plainText`, `allInlines`, `linkURL` |
| `Markdown/MarkdownParser.swift` | 794 | Block + inline parser (see §3) |
| `Markdown/MarkdownView.swift` | 479 | SwiftUI renderer (`AttributedString` for inlines, custom emoji inline with the text, `Grid` for tables) |
| `Markdown/MarkdownFold.swift` | 213 | The in-block fold caps (lines / characters / table rows / list items) |
| `Markdown/CodeHighlighter.swift` | 261 | Prism-style tokeniser used by fenced blocks |

Wiring changes: `NativePanePlaceholders.swift` (`NativeChannelPaneView` now hosts `ChannelPaneContent`),
`NativeShellView.swift` + `RootView.swift` (pass the resolved `ServerConfig` into the destination pane),
`MattermostApp.swift` (`ChannelPaneCoordinator` StateObject, environment injection, socket fan-out from
the T33 rail, deactivate on sign-out/expiry/removal).

## 1. Data path

* `GET /channels/{id}/posts?per_page=60` — **no ETag**, deliberately: a conditional request would hand
  back `304` and the pane would have nothing to draw on a cold start.
* Paging is `before=<oldest loaded post id>`. **`has_next` is ignored on this endpoint**: the pinned
  server (9.11.19) answers `has_next: false` on *every* channel page, the first of six included, so
  trusting it stopped paging after one page (T34-R3 — the live suite caught it; see §8.1). The page
  length is the signal instead: a full page asks again, a short or empty page ends the window.
  `ChannelViewModel.hasMore` is derived, never assumed.
* Author profiles come from `POST /users/ids` **after** the page. A profile failure does not fail the
  page: rows fall back to the username in `props`.
* `last_viewed_at` comes from `GET /channels/{id}/members/me`; the channel page does not carry read
  state. The unread divider is placed from that value, or from the caller when it already knows it.
* Socket events are applied as patches to the loaded window (`posted`, `post_edited`, `post_deleted`,
  `reaction_added`, `reaction_removed`, `channel_viewed`); anything outside the window is a no-op and
  every other event type is explicitly ignored rather than crashing a switch.
* A load generation counter discards answers to superseded loads (two taps on two channels, or a
  retry racing a slow page).

## 2. Rendering rules (parity notes)

* Ordering is `createAt` descending, `id` as tiebreak; rows are built oldest-first for the list so
  grouping and separators read naturally.
* Grouping: same author, same day, within 5 minutes of the **previous** post, and neither post is a
  system message. Grouped rows draw no header (gutter time only).
* Day separators: `Today` / `Yesterday` / weekday within the last week / `Month D, YYYY`.
* Long posts fold after 12 blocks with a `Show more` / `Show less` affordance, and **inside** a block
  too: a single 600-line fence is cut at 20 lines (`… 580 more lines`) and a single 15 K-character
  paragraph at 1,200 characters, so one pasted log cannot blow up the layout (T34 review F6). The
  expansion state lives in the view model so it survives row recycling.
* Custom emoji (`:name:` the server owns) are drawn from `GET /emoji/{id}/image` at text size, inline
  with the words around them; the catalogue **publishes** its name list and image table, so a
  paragraph painted before `/emoji` answered repaints instead of keeping the literal `:name:`
  (T34-R3 — the first live render showed exactly that, see §8.1).
* Deleted posts render as `(message deleted)` only when the server still lists them, and system posts
  render as system rows with no markdown processing.
* Reactions are grouped per emoji, sorted by count then name, and the count comes from the server.

### Deltas from upstream mobile (deliberate)

1. **"(edited)" on a grouped row.** Upstream keeps the marker in the header, which a grouped row does
   not draw, so the fact that a message changed is invisible. T34 draws a muted `(edited)` under the
   body for grouped rows. Hiding information from the reader is worse than one extra word.
2. **The list opens at the newest post.** `defaultScrollAnchor(.bottom)` plus a scroll to the last row
   once the first page lands. Upstream's `inverted` FlatList achieves the same thing by other means.
3. **No composer in T34.** The pane shows a read-only bar that names the channel; typing is T35.
4. **`Load earlier` is a tap, and reaching the top by hand also loads a page.** Upstream pages
   automatically on reaching the top. Here the sentinel is a button *and* the poll that watches the
   reader's own offset fires `loadEarlier()` when a **dragging** reader is at the top, one page per
   arrival (the latch re-arms only when the reader travels more than a screen away from the top, so a
   merge — which lengthens the content above them — cannot be mistaken for a fresh arrival). A window
   that fits on a single screen fills itself. Measured on the live 503-post channel: a sequence of
   fast swipes at the top paged the channel in page by page (503 posts after ~40 gestures, one page
   per genuine arrival). The live test therefore asserts *what* the window contains — the server's
   newest `n` posts, in order — rather than how many pages one visit brought in.


## 3. Markdown

Supported: ATX/setext headings, paragraphs, fenced + indented code, blockquotes (nested), ordered and
unordered lists (nested, tight/loose), GFM tables with alignment, horizontal rules, HTML blocks as
literal text, and inline: emphasis (`*`, `_`, `***` nesting), code spans, links (`[x](y)`, `<url>`),
bare-URL autolinks, `mailto:`, mentions (`@name`), channel links (`~channel`), `:emoji:` and the common
emoticon set, and entity decoding.

Security: HTML is never interpreted. `<script>`, `<style>` and `<iframe>` are removed **with their
contents**; every other tag is escaped into text. Link targets are allow-listed to `http`, `https` and
`mailto` (same-server relative paths allowed only through the explicit `allowRelative` flag); anything
else parses as text with an **empty** target, which `MarkdownView` maps to `nil` rather than a tappable
link. That empty-string convention is the reason a sanitised link cannot be hijacked by the renderer.

Determinism: the parser is pure and total — arbitrary bytes either parse into a tree or into one
paragraph; the random-input test asserts both termination and that `plainText` never loses a
non-whitespace character.

## 4. Tests

Unit (`MattermostTests/`):

* `T34MarkdownTests` (27) — headings/lists/quotes/tables/code, emphasis nesting, delimiter runs,
  hostile links, emoticons vs `<3`, entities, HTML stripping, random-input determinism.
* `T34PostListTests` + `T34FixtureTests` (34) — ordering, grouping boundaries, day titles (pinned to
  2026-10-26 so the suite does not rot), unread divider, reactions, attachments, fold rule, and the
  captured 502-post fixture paged exactly like the live server pages it.
* `T34ChannelViewModelTests` + coordinator tests (29) — first page, paging, short page = last page,
  a full page whose `has_next` is `false` still pages (the pinned server's actual answer),
  out-of-order loads, socket patching, error copy, LRU eviction, auth teardown.
* `T34CodeHighlightTests` (11) — every profile tokenises losslessly.
* `T34EmojiTests` (17) — shortcode segmentation, unknown shortcodes stay literal, the accessibility
  text names resolved emoji, and an inline emoji is drawn at text height rather than the file's pixels.
* `T34ScrollRestoreTests` (13) — the adjustment arithmetic, the tolerance, which row counts as the
  reader's anchor (distances below the viewport edge, measured from UIKit — not positions inside the
  content), and that `loadEarlier()` takes the anchor from the view *before* it sends the request.

**131 T34 unit tests** (`MattermostTests/T34*.swift`; the counts above are per file).

UI (`MattermostUITests/T34-ChannelPostListUITests.swift`, 6 tests, **live server** only — no stub):

1. Showcase channel renders every state the server holds: newest post visible on open, every post in
   the page reachable by scrolling, the edited marker, the system row, the attachment row naming the
   server's file, the reaction with the server's count, the day separator above the oldest post, and
   the custom emoji resolved to an image (`:t34parrot:` must not be left as a shortcode).
2. A long post folds and expands (the fold summary disappears and the row grows).
3. Reaching the top pages older posts in without duplicates: the pane's window must equal the
   server's newest `n` posts for the `n` the pane reports (rebuilt from the server with the same
   `before` cursor), the older end must be drawn at the top, and no id may be drawn twice.
4. A single-block post (600-line fence, 4 K-character paragraph, channel `t34-fold`) is folded, says
   what it hides, and expands.
5. Paging does not move the reader: the topmost visible post's frame is measured before and after one
   `loadEarlier()`, triggered through the `-uiTestExposeLoadEarlier` launch-argument seam so the load
   cannot race the measurement.
6. A post created by the API appears without a reload, and the unread line follows the server's
   `last_viewed_at`.

## 5. Verification state (T34-R4, 2026-10-25)

* `xcodebuild build` (Debug, iOS Simulator) — **BUILD SUCCEEDED**.
* Unit: see §8.4 for the counts and the two destinations of this round.
* UI: **6 of 6 green, twice, from a clean simulator boot** against the live stack — §7 has the run
  ids and log paths. `docs/t34-shots/` holds the screenshots those runs attached.

## 6. Repro

Run every test through `scripts/qa-test.py`, not bare `xcodebuild`: derived data inside
`~/Documents` is TCC-protected, and a *failing* test there wedges the runner instead of reporting
(T14b — this is exactly what made the Catalyst runner "hang before establishing connection" in the
round-2 review of this card). `qa-test.py` puts derived data in `~/Library/Developer/Xcode/DerivedData`,
watches for stalls, and prints a verdict.

```
docker start mm-perf-db && sleep 6 && docker start mm-perf && sleep 25
python3 scripts/t34_post_seed.py --url http://127.0.0.1:8065          # idempotent
python3 scripts/t34_capture_fixture.py --url http://127.0.0.1:8065    # refreshes Fixtures/*.json

python3 scripts/qa-test.py --platform ios --sim id=DC3E9FB7-E4A0-4B24-8DBB-7960A059EC7A \
  --only-testing MattermostTests/T34MarkdownTests --only-testing MattermostTests/T34PostListTests \
  --only-testing MattermostTests/T34ChannelViewModelTests --only-testing MattermostTests/T34CodeHighlightTests \
  --only-testing MattermostTests/T34EmojiTests --only-testing MattermostTests/T34ScrollRestoreTests

TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<seeded probe account> \
python3 scripts/qa-test.py --platform ios --sim id=DC3E9FB7-E4A0-4B24-8DBB-7960A059EC7A \
  --only-testing MattermostUITests/T34ChannelPostListUITests --label t34-ui

# screenshots for docs/t34-shots/ (attachments the suite records):
xcrun xcresulttool export attachments --path <run>.xcresult --output-path /tmp/t34-shots
```

## 7. UI suite — what was observed (T34-R4)

Two consecutive full runs on the iPad Pro 11-inch (M5) simulator (`DC3E9FB7`) against the live stack
(`mm-perf` / `mm-perf-db`, `127.0.0.1:8065`), no other worker on the device:

| run | log | verdict |
|---|---|---|
| `t34r4-suite1` | `docs/t34r4-ui-suite1-2026-10-25.log` | `Executed 6 tests, 0 failures` — 6/6 **pass** |
| `t34r4-suite2` | `docs/t34r4-ui-suite2-2026-10-25.log` | `Executed 6 tests, 0 failures` — 6/6 **pass** (this run produced `docs/t34-shots/`) |

Per test (suite2 timings): showcase 42 s, long-post fold 20 s, single-block fold 19 s, paging 68 s,
anchor-across-a-page 85 s, socket insert 18 s.

The two tests that were red in every previous round are now green **and** their assertions were
rewritten so they no longer depend on the things that made them flaky:

* `testLoadingOlderPostsDoesNotMoveTheAnchoredPost` — the restore is measured from UIKit now (§8.2),
  and the test is the same measurement it always was: the anchored row's `frame.minY` before and
  after a page insert, ±2 pt. Its two screenshots (`t34-07-anchor-before-older-page.png`,
  `t34-08-anchor-after-older-page.png`) are **byte-identical** — the same pixels before and after the
  page landed, which is what "no jump" means.
* `testReachingTheTopLoadsOlderPostsWithoutDuplicates` — no longer assumes one page per visit; it
  checks the pane's window against the server's own newest-`n` sequence (§8.3).

A run that dies mid-suite (`SimRenderServer` SIGTRAP, "signal kill") is an environment failure, not a
verdict on the code; re-run with the simulator to yourself.

## 8. T34-R4 — the round that closed the review

Round 2 of review (`origin/main` `052a2dc`) left three blocking findings. All three were corrected
here, and this section records what was wrong, because two of the three were *diagnosis* errors, not
typos.

### 8.1 F1 — the anchored post moved by 585 pt after a page insert

The R3 restore read a row's position from a SwiftUI `GeometryReader` preference — a value in the
scroll **content**'s coordinate space, republished whenever SwiftUI decided a row had moved — and
combined it with a `contentOffset` read at a different moment. When the two disagreed (a layout pass
in flight), the correction was computed against a stale pair and the move was applied twice: the live
test measured the anchored row at `y=-340.9` after starting at `y=245.0`, i.e. the reader was carried
~586 pt into older history.

**Fix: measure from UIKit, in a closed loop.** Every post row now registers its own `UIView` with the
scroll controller (`RowAnchorProbe` feeding a row registry inside `ChannelScrollController`).
`offsetFromTop(ofRow:)` converts that view's bounds into the scroll view's
coordinate space and subtracts `bounds.origin.y`, which answers "how far below the viewport's top edge
is this row *right now*" synchronously, with no layout-pass bookkeeping. The restore loop measures,
corrects the residual, and measures again; a second measurement *contains* the first correction, so
applying a move twice is not expressible. If the row is not laid out (a page pushes it a few screens
down and the lazy stack drops it), SwiftUI's `scrollTo` brings it back and the loop measures from
there. The anchor itself is now taken by `loadEarlier()` through `readerAnchorProvider` **before** the
request goes out, instead of from the previous 8 Hz sample.

An early exit needs the content to have been re-laid-out *and settled* (`abs(height - base) > 1` for
the base captured at anchor time, stable across a sample), because an un-laid-out list reports the old
positions, which read as "no correction needed".

The row-geometry preference key, the `frames` dictionary and the per-row `GeometryReader` are gone.

### 8.2 F2 — the DoD screenshot artifact

`docs/t34-shots/` now exists: nine PNGs exported from the attachments of the green suite run
(`xcrun xcresulttool export attachments`), all captured from the native pane reading the real server
at `127.0.0.1:8065`. `docs/parity.md`'s T34 row points at them and at the run ids.

### 8.3 F3 — the paging test

Two separate problems, both fixed:

1. **The test's stop condition was wrong.** It swiped until the sentinel's frame intersected the list,
   which in a lazy list is true while the sentinel is off screen, and in one run broke out after three
   gestures and then found no element at all. It now swipes until the *pane reports it holds more
   posts than the first page*.
2. **The test assumed one page per visit.** The swipe loop paged the whole 503-post channel in
   (503 posts loaded), which is the pane behaving correctly — the reader kept arriving at the top —
   but broke the "the older page's oldest is the pane's oldest" assertion. The test now rebuilds the
   server's newest-`n` sequence for the `n` the pane reports and asserts the two agree, plus (drawn at
   the top, no duplicates).

### 8.4 Evidence (this round)

| what | command | verdict |
|---|---|---|
| units, **Mac Catalyst** (the card's DoD line) | `scripts/qa-test.py --platform mac --only-testing MattermostTests --label t34r4-units-catalyst` | **`Executed 901 tests, with 4 tests skipped and 0 failures (0 unexpected)`** — `RESULT: PASS` in 62 s (`docs/t34r4-catalyst-units-2026-10-25.log`). 131 of the 901 are T34 (`T34MarkdownTests` 27, `T34PostListTests` 30 + `T34FixtureTests` 4, `T34ChannelViewModelTests` 25 + `T34ChannelPaneCoordinatorTests` 4, `T34CodeHighlightTests` 11, `T34EmojiTests` 17, `T34ScrollRestoreTests` 13). The 4 skips are pre-existing (`CertTrust` keychain entitlement on an ad-hoc Catalyst host, and the opt-in live mention poll) — no T34 skip. |
| units, iOS Simulator | `scripts/qa-test.py --platform ios --sim id=DC3E9FB7… --only-testing MattermostTests --label t34r4-units-ios` | **`Executed 901 tests, with 3 tests skipped and 0 failures (0 unexpected)`** — `RESULT: PASS` in 38 s (`docs/t34r4-ios-units-2026-10-25.log`); one fewer skip than Catalyst because that host has a keychain |
| live UI suite ×2 | `scripts/qa-test.py --platform ios --sim id=DC3E9FB7… --only-testing MattermostUITests/T34ChannelPostListUITests` | **6/6 pass, twice** (`docs/t34r4-ui-suite1-2026-10-25.log`, `docs/t34r4-ui-suite2-2026-10-25.log`) |
| anchor test alone | same runner, `--only-testing …/testLoadingOlderPostsDoesNotMoveTheAnchoredPost` | **pass** (`docs/t34r4-anchor-2026-10-25.log`) |
| the paging test *before* the repair | same runner, first attempt this round | **fail** — `docs/t34r4-paging-fail-2026-10-25.log`, kept because it is the evidence for §8.3 (the swipe loop paged the whole 503-post channel in, `503 posts loaded`) |

The Catalyst runner that "hung before establishing connection" three times in the round-2 review
completes in 62 s here. It was never a code problem: the review ran `xcodebuild` with derived data
inside `~/Documents`, which is TCC-protected, and a failing/symbolicating test run wedges there
(T14b — the reason `scripts/qa-test.py` exists). §6 makes that runner the documented way to run these
tests.

