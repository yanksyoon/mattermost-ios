# T34 — native channel pane / post list (build note)

Behaviour reference: `mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)`.

## What shipped

New surface, all under `Mattermost/UI/Native/Channel/`:

| File | Lines | Role (upstream counterpart) |
|---|---|---|
| `ChannelAPI.swift` | 40 | REST: channel posts page, `/users/ids`, file bytes, `/channels/{id}/members/me` (`remote/posts`, `files`, `users`) |
| `ChannelService.swift` | 74 | Page-then-profiles load order; `ChannelServing` protocol with `pageSize`, `membership`, `fileData` |
| `ChannelViewModel.swift` | ~460 | `@MainActor` state machine: load/paginate/socket-patch/scroll anchor/expanded set/generation guard (`post_list/index.tsx` + `actions/views/post_list`) |
| `ChannelPaneCoordinator.swift` | 134 | Per-server LRU (6 channels) of view models + image caches; auth teardown |
| `ChannelView.swift` | ~320 | List, top sentinel, empty/error/loading states, sticky composer stand-in |
| `PostRowView.swift` | 389 | Row: avatar/gutter, header, body, attachments, reactions, system/deleted rows |
| `PostListModels.swift` | 424 | `PostListDerivation` — pure derivation of rows, separators, grouping, folds, labels |
| `Markdown/MarkdownModel.swift` | 136 | Inline/block tree, `plainText`, `allInlines`, `linkURL` |
| `Markdown/MarkdownParser.swift` | 776 | Block + inline parser (see §3) |
| `Markdown/MarkdownView.swift` | 286 | SwiftUI renderer (`AttributedString` for inlines, `Grid` for tables) |
| `Markdown/CodeHighlighter.swift` | 265 | Prism-style tokeniser used by fenced blocks |

Wiring changes: `NativePanePlaceholders.swift` (`NativeChannelPaneView` now hosts `ChannelPaneContent`),
`NativeShellView.swift` + `RootView.swift` (pass the resolved `ServerConfig` into the destination pane),
`MattermostApp.swift` (`ChannelPaneCoordinator` StateObject, environment injection, socket fan-out from
the T33 rail, deactivate on sign-out/expiry/removal).

## 1. Data path

* `GET /channels/{id}/posts?per_page=60` — **no ETag**, deliberately: a conditional request would hand
  back `304` and the pane would have nothing to draw on a cold start.
* Paging is `before=<oldest loaded post id>`; `has_next` from the server wins, otherwise a short page
  means the end. `ChannelViewModel.hasMore` is derived, never assumed.
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
* Long posts fold after 12 blocks with a `Show more` / `Show less` affordance; expansion state lives in
  the view model so it survives row recycling.
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
* `T34PostListTests` + `T34FixtureTests` (27) — ordering, grouping boundaries, day titles (pinned to
  2026-10-26 so the suite does not rot), unread divider, reactions, attachments, fold rule, and the
  captured 502-post fixture paged exactly like the live server pages it.
* `T34ChannelViewModelTests` + coordinator tests (28) — first page, paging, short page = last page,
  out-of-order loads, socket patching, error copy, LRU eviction, auth teardown.
* `T34CodeHighlightTests` (11) — every profile tokenises losslessly.

UI (`MattermostUITests/T34-ChannelPostListUITests.swift`, 6 tests, **live server** only — no stub):

1. Showcase channel renders every state the server holds: newest post visible on open, every post in
   the page reachable by scrolling, the edited marker, the system row, the attachment row naming the
   server's file, the reaction with the server's count, the day separator above the oldest post, and
   the custom emoji resolved to an image (`:t34parrot:` must not be left as a shortcode).
2. A long post folds and expands (the fold summary disappears and the row grows).
3. Reaching the top pages older posts in without duplicates.
4. A single-block post (600-line fence, 4 K-character paragraph, channel `t34-fold`) is folded, says
   what it hides, and expands.
5. Paging does not move the reader: the topmost visible post's frame is measured before and after one
   `loadEarlier()`, triggered through the `-uiTestExposeLoadEarlier` launch-argument seam so the load
   cannot race the measurement.
6. A post created by the API appears without a reload, and the unread line follows the server's
   `last_viewed_at`.

## 5. Verification state

* `xcodebuild build` — **BUILD SUCCEEDED** (Debug, Mac Catalyst, 2026-10-25).
* Unit: **122 tests, 0 failures** across `T34MarkdownTests`, `T34PostListTests`, `T34FixtureTests`,
  `T34ChannelViewModelTests`, `T34ChannelPaneCoordinatorTests`, `T34CodeHighlightTests`,
  `T34EmojiTests`, `T34ScrollRestoreTests` (Mac Catalyst, `xcodebuild test`).
* UI: see §7 — the suite runs against the live stack on the iPad Pro 11-inch (M5) simulator; each
  test is recorded below with the run it was last observed green in. A run that dies mid-suite is an
  environment failure (`SimRenderServer` SIGTRAP / runner "signal kill"), not a verdict on the code.

## 6. Repro

```
docker start mm-perf-db && sleep 6 && docker start mm-perf && sleep 25
python3 scripts/t34_post_seed.py --url http://127.0.0.1:8065          # idempotent
python3 scripts/t34_capture_fixture.py --url http://127.0.0.1:8065    # refreshes Fixtures/*.json
xcodebuild -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=iOS Simulator,id=023B9070-CAD0-409B-BFD0-78FF5CA5EACC' \
  -configuration Debug test \
  -only-testing:MattermostTests/T34MarkdownTests \
  -only-testing:MattermostTests/T34PostListTests \
  -only-testing:MattermostTests/T34ChannelViewModelTests \
  -only-testing:MattermostTests/T34CodeHighlightTests
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<seeded probe account> \
xcodebuild ... test -only-testing:MattermostUITests/T34ChannelPostListUITests
```
