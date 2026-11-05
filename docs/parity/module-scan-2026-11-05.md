# Module scan v2 — per-capability parity, 2026-11-05 (t_0230e17e)

The previous scans proved that a file existed. This one asks, capability by capability, *what does upstream
do, where is it in our tree, and what proves it works*. The record is `parity/module-scan.tsv` (159 rows,
16 modules, one row per (module, upstream capability)); `docs/PARITY.md` is the generated view of it and must
be regenerated, never edited.

## Pins (re-derived before a single row was written)

    git ls-remote https://github.com/mattermost/mattermost-mobile.git refs/tags/v2.45.0
    -> 162f2560d0e1df073220f7701d5a67cc17c8abeb   # v2.45.0
    git ls-remote https://github.com/mattermost/mattermost.git refs/tags/v12.0.1
    -> 987e57120dca630dadbcd2638064ab66a02bb81e   # v12.0.1 (monorepo; mattermost-webapp has no v12 tags)

Both trees were fetched at those SHAs into the scan scratch dir and every `upstream_ref` is a path in that
tree. Nothing was derived from memory or from `component-map.md`.

## Method

* A capability is a thing the reader can do or see, read out of the upstream code path (handler, derivation,
  testID), not out of a README paragraph.
* `ours` is `native | partial | webview | absent`; `ours_ref` is a `file:line` in our tree, or the grep that
  returns nothing.
* **Evidence rule**: a green unit case at HEAD, a live XCUITest case that actually ran in this scan, or an AX
  id observed on a running build. A file path on its own is not evidence; `MISSING` means nothing proves it.
* **Verdict** is the QA verdict, not the presence of code: `parity` = evidence resolves; `gap` = it does not
  (either the capability is absent or nothing proves it); `owner-decision` = blocked on a scope/licence call.
* Anything that cannot be exercised here is `partial`/`owner-decision` with the blocker named — never a pass.

## Runs at HEAD 69c7bf4 (clean tree)

    Unit  python3 scripts/qa-test.py --platform ios --sim id=81A7F251-... --only-testing MattermostTests
          -> 2231 cases declared; 2222 passed, 8 skipped (opt-in live: poller, self-signed trust, calls
             engine, media transport), 1 crashed the host (T31HarvestCookieInstallTests::
             testARealStoreKeepsTheInstalledCookieAndTheProductionReaderFindsIt) -> rc=65.
          -> build/logs/parity-scan-unit.log. 0 failed assertions across both launches; the suite is NOT
             "green" and this scan does not claim it is (card t_d393d211).
    Live  python3 scripts/qa-test.py ... --label parity-live
          -> 17 run, 2 skipped, 0 failed, rc=0 (T36ThreadsUITests 11/11, T05ChannelHeaderUITests 4/5,
             T8dDirectMessagePagingUITests 0/1) -> build/logs/parity-live.log
    Live  ... --label parity-live-fixtures (t05_bookmarks_proxy.py on :8078 + t8d_dm_seed.py --count 45)
          -> 2 run, 0 skipped, 0 failed, rc=0 — both cases that had skipped now pass.
             -> build/logs/parity-live-fixtures.log

## Where we stand, per module (from `docs/PARITY.md`)

| module | capabilities | verified | partial | missing | out of scope |
|---|---|---|---|---|---|
| auth | 8 | 8 | 0 | 0 | 0 |
| channel-admin | 8 | 7 | 0 | 1 | 0 |
| channel-header | 12 | 8 | 2 | 2 | 0 |
| channel-timeline | 17 | 15 | 0 | 2 | 0 |
| composer | 12 | 8 | 0 | 4 | 0 |
| drafts-scheduled | 4 | 2 | 0 | 2 | 0 |
| files-attachments | 11 | 9 | 1 | 1 | 0 |
| mentions-activity | 7 | 7 | 0 | 0 | 0 |
| notifications | 10 | 8 | 1 | 1 | 0 |
| profile-popover | 8 | 7 | 0 | 0 | 1 |
| reactions-emoji | 5 | 5 | 0 | 0 | 0 |
| search | 10 | 9 | 0 | 0 | 1 |
| shell-transport | 9 | 8 | 0 | 1 | 0 |
| sidebar | 15 | 15 | 0 | 0 | 0 |
| thread | 17 | 13 | 1 | 2 | 1 |
| web-fallback | 6 | 1 | 0 | 2 | 3 |
| total | 159 | 130 | 5 | 18 | 6 |

## The six defects that started this scan

| complaint | row (and the thing that proves it now) | state |
|---|---|---|
| thread pane's back button | `thread/back-out-returns-to-the-entry-point` — unit `NativeNavigationTests::testBackFromAListOpenedThreadReturnsToTheListNotTheLastChannel` + live `T36ThreadsUITests` (timeline→channel, list→list) | fixed (t_1617a61c); live green |
| reply counts in the thread pane | `thread/reply-count-in-the-pane-header` — unit `T36ThreadModelsTests::testTheReplyCountPrefersTheServersNumberOverThePage` + live `testReplyingUpdatesTheRootsReplyCountAndTheThreadTakesSocketReplies`. Note: mobile puts the count on the channel row only; the pane header count matches **webapp** `thread_viewer` | fixed (t_6a4a8224); live green |
| invisible channel header / bookmarks | `channel-header/the-title-opens-channel-info` + `bookmarks-bar-in-server-order` — live `T05ChannelHeaderUITests` A/B/C/E and D (D only with the bookmarks proxy) | fixed (t_05caa678); live green |
| notifications never fire | `notifications/*` — 17 unit cases on scheduling/policy/routing; **real APNs is not exercised** (no entitlement, no push proxy) | open — sign-off item 8 |
| DM labels | `sidebar/dm-rows-name-the-people` — unit `T33DmLabelResolutionTests` (6 cases) + live `T8dDirectMessagePagingUITests` (45 seeded DMs, Load more) | fixed (t_8d539b3f); live green |
| reaction shortcodes | `reactions-emoji/reaction-pills` — unit `T37ReactionTests` (alias folding, canonical name sent) | verified |

## Owner sign-off — 21 items (items 1–18 are exactly the "To be implemented" table; 19–21 are divergences under "Out of scope" that we decided ourselves and you must confirm)

1. `channel-timeline / urgent-message-priority-badge` — enterprise licence + fixture; does v1 keep priority?
2. `channel-timeline / apps-bindings` — t_61525849 (S34 decision)
3. `thread / mention-highlighting-in-thread-posts` — t_0268627c
4. `thread / open-in-channel-from-thread-options` — t_510a5563
5. `thread / root-deleted-while-the-pane-is-open` — divergence: we keep the pane and say so instead of auto-popping
6. `channel-header / ignore-mentions-in-a-channel` — t_8525d2c8
7. `channel-header / per-channel-auto-translation` — enterprise feature, no licensed fixture
8. `notifications / receive-a-real-apns-push` — no APNs certificate/push proxy here; local+poll only?
9. `search / webapp filters` — divergence: typed modifiers + chips instead of filter menus
10. `profile-popover / shared-channels` — divergence: omitted, matching mobile
11. `composer / slash-commands` — t_4ee9856c
12. `composer / typing-indicator` — t_34f44d28
13. `composer / archived-and-read-only-banners` — t_03411e94
14. `composer / scheduled-posts-and-priority` — t_e5f917f9 (existing, blocked: licence)
15. `files-attachments / table-and-latex-readers` — component-map S18 calls them out of scope; confirm
16. `channel-admin / convert-a-group-message-to-a-channel` — t_d088f075
17. `drafts-scheduled / scheduled-posts-create-list-reschedule-recurrence` — t_e5f917f9
18. `drafts-scheduled / a-scheduled-draft-in-the-global-drafts-list` — t_e5f917f9
19. `shell-transport / share-extension-to-post-a-file` — needs a second target/entitlement; v1 or not?
20. `web-fallback / apps-interactive-dialog-forms` — t_61525849 (S34 decision)
21. `web-fallback / apps-integration-selector` — t_61525849 (S34 decision)

## Carded, no owner decision needed (the 4 partial rows + the harness)

| row | card |
|---|---|
| `channel-header / member-count-subtitle` (constant "View info") | t_0f8e0eb2 |
| `thread / unread-divider-from-thread-viewed-at` (wired, unproven) | t_dbf5395b |
| `files-attachments / zoom-and-share-an-image` (implemented, unproven) | t_ccf6837d |
| `notifications / tap-fallbacks-when-the-post-is-gone` | t_14c96dfd |
| unit suite crash (not a parity row) | t_d393d211 |

## What this host could not validate

* **APNs / real push** — no entitlement, no certificate, no push proxy; `simctl push` proves the handler, not
  the path. Owner decision (item 8).
* **Licensed server features** — scheduled posts, priority, auto-translation, channel bookmarks (the fixture
  needs `t05_bookmarks_proxy.py`); only the proxy path was exercised.
* **Real device** — every live run here is an iPhone 16 Pro simulator. No device soak, no battery/thermal/audio
  session behaviour, no real keyboard/dynamic-type pass.
* **Two live clients** — typing indicator and cross-client read receipts need a second signed-in client; the
  45 seeded DM *users* are not a second client.
* **The full UI suite** — only 3 suites were run (202 cases exist). The rest of the UI target is unexercised in
  this scan, and the full-target attempt I started first was aborted (it ran the whole target, ~2000 cases).
