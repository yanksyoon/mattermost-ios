# T4d — unread threads on the rail (build note)

Task: `t_4dfdf856`. Reported defect: **"no place in the left panel to see unread threads /
messages"**.

The pane had All / Unreads tabs since T36, but nothing in the channel list said a thread was waiting,
and on a phone the Threads tab carried no count. This note records what was built, what was
**measured**, and how it is proved.

## What changed

| File | Change |
| --- | --- |
| `UI/Native/Thread/GlobalThreadsModels.swift` | `ThreadsRailEntry` (unread count, mentions, `isUnread`, `badgeText`, the VoiceOver sentence) and `GlobalThreadsDerivation.railEntry(totals:drawn:)`, which reuses `displayedTotals` so the rail and the pane's header are **one derivation**, not two. |
| `UI/Native/Thread/GlobalThreadsViewModel.swift` | `railEntry` for the closed pane; `thread_read_changed` now moves the team's `totals` with the thread (the event carries both the new and the previous unread state), so the header/rail drop immediately instead of after the next page load. |
| `UI/Native/Sidebar/ChannelSidebarView.swift` | `ThreadsRailRow` — the entry (upstream copy "Threads", bold while unread, badge for the count, sentence on the row's accessibility value). It sits in the **workspace** section, above the categories. `openThreads()` routes both layouts (tab for compact, pane for split) so the row is not inert. |
| `UI/Native/Thread/GlobalThreadsView.swift` | `NativeThreadsTabView` — the phone's Threads tab, with `.badge` from the same `railEntry`. |
| `UI/Native/NativeShellView.swift` | The Threads `.tabItem` is now that view instead of `NativeThreadsPlaceholderView`. |
| `UI/Native/NativePanePlaceholders.swift` | `NativeThreadsPlaceholderView` deleted (nothing referenced it after the tab became the real pane). |

Upstream parity (`mattermost-mobile` v2.45.0): `app/components/threads_button/threads_button.tsx`
rendered from `app/screens/home/channel_list/categories_list/categories_list.tsx` (import line 14, use
line 154), fed by `observeUnreadsAndMentions` in `app/queries/servers/thread.ts`; the phone counterpart
is the tab bar in `app/screens/home/tab_bar/index.tsx`. Same placement (above the categories), same
copy, same two facts (something is waiting, and how much).

## Measured, not assumed

1. **Following a thread marks it read.** `PUT /users/me/teams/{team}/threads/{id}/following` sets
   `last_viewed_at` and clears `unread_replies` (observed 1 → 0). A fixture that replies first and
   follows second ends up with nothing unread — the first version of the live test asserted `1` and got
   `0` for exactly this reason. `scripts/t4d_thread_unread_probe.py` is that measurement; the suite
   follows first, then has the second account reply.
2. **Below the channel list the entry is unreachable.** The `perfprobe` account on this server is in 11
   categories / 347 channels, and a SwiftUI `List` only builds the rows it is showing: placed after the
   categories, `nativeSidebarAllThreads` was not in the accessibility tree at all (live run `t4d-ui4`
   found no such row after scrolling). Above them it is drawn on the first frame (`t4d-ui5`+). A row
   nobody can see is the reported defect wearing a different hat, which is why the placement is part of
   the fix and not a detail.
3. **A phone pushes the pane; there is no tab bar to go back to.** Tapping the row in the compact
   layout pushes a screen with a Back chevron and **no** `TabBar`, so `app.tabBars.buttons["Channels"]`
   matches nothing (`t4d-ui6`, `t4d-ui7`). The live suite therefore proves the live decrement *before*
   it opens the pane, with the channel list still on screen — which is also the stronger claim.
4. **The rail badge and the pane's counter line are the same number.** Asserted on both layouts: the
   rail value read while the pane is closed, then the pane's `globalThreads.subtitle` after the tap.

## Evidence

| Run | Command | Result |
| --- | --- | --- |
| `t4d-units3` | `qa-test.py --only-testing MattermostTests/T4dUnreadThreadsTests --only-testing MattermostTests/T36GlobalThreadsViewModelTests --only-testing MattermostTests/T36ThreadModelsTests` | **62 run, 0 skipped, 0 failed** (87 s) |
| `t4d-ui8` | live, `MattermostUITests/T4dUnreadThreadsUITests` on iPhone 15 Pro (iOS 17.0.1) | **1 run, 0 failed**, 27.9 s — rail count drawn with the pane closed, server-side read moves it, tap opens the pane, thread gone from Unreads, header agrees |
| `t4d-ui-ipad2` | same test on iPad Pro 11 (M5), iOS 26.0.1 — the **split** layout | **1 run, 0 failed**, 170 s |
| `t4d-units4` / `t4d-ui9-rebased` | the same two suites after rebasing onto `origin/main` (which brought in the owner's last-conversation restore) | **62 run / 0 failed** and **1 run / 0 failed** (137 s) |
| `t4d-regress-t32` | `MattermostUITests/T32SidebarIdentifiersTests` | 5/6 passed; `testTeamsFailureStateIsReachable` fails **identically with this card's changes stashed** (`t4d-baseline-t32`), i.e. pre-existing on this branch, not a regression here |

Screens (exported from the iPad run's attachments): the sidebar with **Threads • 1** above the
categories, "No channel selected" in the detail column — the count is visible with the pane closed.

## Limits that stay

- The number is the **unread thread** count (this client's pane counts threads), not upstream mobile's
  thread-mention sum; mentions ride along in the row's accessibility value ("12 unread threads, 11
  mentions") rather than in the badge.
- The count is the **team**'s, because the list is per team — a reader with two teams sees each team's
  count after switching, not a cross-team total.
- Nothing is drawn before the team resolves (a "0" would read as a failed load).
- The compact layout's Threads tab badge only exists while the pane is a tab; tapping the rail row
  pushes the pane instead, and a pushed screen has no tab bar by design.
- The count is live from the socket only while the app runs; a thread read while the app is suspended
  arrives with the next load, like every other counter in this client.
