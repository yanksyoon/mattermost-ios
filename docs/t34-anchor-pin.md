# T34 anchor pin — making "the restore is deleted" fail something

Task `t_a4d02070`, filed by T34-QA (`t_667988fd`). This note is the record of what was measured, what
was changed, and what the new pin does and does not prove. Every number below is from a run on this
host against the real 9.11.19 at `127.0.0.1:8065`; log paths are in the repo.

## 1. The finding this closes

QA mutated `Mattermost/UI/Native/Channel/ChannelView.swift` twice and reverted each time
(`docs/t34qa-build-note.md` §8):

* **mutation A** — the `restoreReader(restore, proxy:)` call removed from the
  `onChange(of: model.pendingScrollRestore)` handler: `testLoadingOlderPostsDoesNotMoveTheAnchoredPost`
  **passed** (80.3 s). The user-visible property held without the restore.
* **mutation B** — the same handler replaced with `scrollController.scrollToBottom()`: the test
  **failed** (`moved -230.5 pt from y=302.0 …`). The assertion is not vacuous.

So the live suite's claim was "the list does not jump" — true, verified — and not "the restore works".
The card asked for one of two pins; **option 1 was taken** (pin the restore path itself), and the
mechanism behind mutation A was also measured rather than guessed (§5).

## 2. What changed

| file | change |
| --- | --- |
| `Mattermost/UI/Native/Channel/ScrollRestoreRunner.swift` | **new**. The restore loop, lifted out of the view: `ScrollRestoreSurface` (four closures: content height, a row's distance from the viewport's top edge, scroll by a delta, bring a row back into view), `ScrollRestoreRunner.run(anchor:baselineContentHeight:surface:pause:)` and `ScrollRestoreReport`. Behaviour is the T34-R4 loop unchanged — measure, correct the residual through the point offset, settle only after three consecutive settled observations inside a 75-frame budget — plus bookkeeping. |
| `ChannelView.swift` | `restoreReader` is now a thin adapter: it builds the surface from `ChannelScrollController` + `ScrollViewProxy`, runs the loop, publishes the report on the model and consumes the anchor. A new `ScrollRestoreSeam` view (mounted only under `-uiTestExposeLoadEarlier`) publishes the report as `channelPostList.scrollRestore`. |
| `ChannelViewModel.swift` | `@Published private(set) var lastScrollRestore: ScrollRestoreReport?` + `recordScrollRestore(_:)`. |
| `MattermostTests/T34ScrollRestorePathTests.swift` | **new**, 9 tests: the loop against a fake surface that simulates the page insert. |
| `MattermostTests/T34ChannelViewRestoreWiringTests.swift` | **new**, 2 tests: the **real** `ChannelPostListView` hosted in a window, driven through `requestScrollRestore`. |
| `MattermostUITests/T34-ChannelPostListUITests.swift` | the anchor test now also reads `channelPostList.scrollRestore` and fails when no restore ran; the report is printed and attached. |

Design note on *why two levels*: no unit test of the loop can prove its own caller (mutation A is a
deletion in the caller), and no live UI test can see inside the loop without a signal the loop itself
publishes. Hence the loop is testable in isolation (arithmetic, sign, single application, un-laid-out
fallback, budget) **and** the caller is testable in-process (anchor consumed + report published) **and**
the live suite reads the same report.

## 3. Evidence — unit and hosted

All runs: `scripts/qa-test.py --platform ios --sim id=495B0295-5421-4667-92FD-DA47D89BD6E0`
(iPad Pro 11-inch M4, iOS 18.3.1), `-only-testing MattermostTests/T34ScrollRestorePathTests
-only-testing MattermostTests/T34ChannelViewRestoreWiringTests`.

| label | code under test | verdict |
| --- | --- | --- |
| `t34pin-units3` | the new tests, product reverted to the shipped loop | **11 run, 0 failed, 155 s** |
| `t34pin-mutationA` | `await restoreReader(restore, proxy: proxy)` deleted from the `onChange` handler | **11 run, 4 failed, 148 s** — both wiring tests: `the list never consumed the pending anchor: no restore ran (last report: none)` and `no ScrollRestoreReport was published`. The 9 runner tests stayed green, which is the point: they pin the loop, not its caller. |
| `t34pin-mutationC` | the runner computes the adjustment but never applies it (`surface.scrollBy` removed) | **9 run, 11 failed, 74 s** — `content moves up by exactly the page height: ("0.0") is not equal to ("1000.0")`, `the scroll view saw exactly one move: ("[]") is not equal to ("[1000.0]")`, `("exhausted") is not equal to ("settled")`. |

Mutation C is the "regression *inside* the restore" case the card named: with it, the live anchor test
would still pass on this host (the OS keeps the row) and the unit pin fails loudly.

## 4. Evidence — live, on the simulator QA used

Simulator `DC3E9FB7-E4A0-4B24-8DBB-7960A059EC7A` (iPad Pro 11-inch M5, **iOS 26.0**), server
`127.0.0.1:8065` (Mattermost 9.11.19, docker `mm-perf`), account `perfprobe`
(`TEST_RUNNER_MM_AUTH_*`; password from `scripts/perf_seed.py`).

| label | verdict | note |
| --- | --- | --- |
| `t34pin-live1` | **skipped (no verdict)** | run without `TEST_RUNNER_MM_AUTH_*`; the suite skips itself with `set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD`. Recorded so a skip is never read as a pass. |
| `t34pin-live2` | **pass, 181 s** | the anchor test with the new report assertion |
| `t34pin-live3` | **pass, 165 s** | same, plus the report printed/attached: see below |

The report the live run published (`build/logs/t34pin-live3.log`):

```
t34 restore report: restore post.dnysfb453ifnj8ykub96zrmsth outcome=settled frames=3
measurements=3 corrections=0 applied=0.0 firstResidual=0.0 finalResidual=0.0
```

## 5. The mechanism — measured, not inferred

QA offered two candidate explanations for mutation A and established neither. The report answers it on
this host: at the restore's **first** measurement the anchored row was already exactly at its recorded
distance (`firstResidual=0.0`), the content height had grown (the page really was merged — the test
asserts the older page is reachable afterwards), and the loop therefore applied **zero corrections** and
settled in 3 frames.

That is the first candidate: **iOS 18+ anchoring keeps the reader's place for this prepend by itself**
(the pane applies `defaultScrollAnchor(.bottom, for: .initialOffset)` — `InitialBottomAnchor`), so on
iOS 26.0 a reader gets the correct position with or without `restoreReader`. The restore is a
closed-loop *correction*, and on this OS there is nothing to correct.

What follows, and is now written in `docs/parity.md` (T34 row, Limits): the restore path is still
required — it is what makes the behaviour hold on an OS/layout where the anchor is not preserved, and
the fold toggle (`toggleExpanded`) relies on the same loop for a row whose height changes under the
reader — but its *observable* contribution on iOS 26 is zero, which is exactly why the live frame
comparison could not see mutation A. The pin therefore asserts the restore **ran**, not that it moved
anything.

## 6. What this pin does not prove

* **That a non-zero correction is visually sufficient** on a live list. The live suite proves that
  when the pane is scrolled on purpose the frame comparison fails (QA's mutation B), and the unit tests
  prove the correction is the right size and sign against a synthetic page insert; no live run has yet
  produced a real page insert on a host where the OS does *not* preserve the anchor (iOS 17-like
  layout, or a fold toggle large enough to move the row). Filed as a limit, not claimed.
* **iOS 17 behaviour.** The 18+ anchor is scoped to `.initialOffset`; the 17 fallback is
  `defaultScrollAnchor(.bottom)` plus `pinToBottom()`. Not measured here (no iOS 17 runtime on this
  host) — the restore is what carries that case, and the hosted test pins the wiring for it.
* **The report's own honesty under a gutted loop**: mutation C proves the runner tests catch a loop
  that computes but does not apply; a loop that applied a *wrong* correction would fail the residual
  assertions on the fake surface, not on the live list (§6 first bullet).
* The concurrent-worker note: at the time of writing, `Mattermost/MattermostApp.swift` carried another
  card's **uncommitted, syntactically broken** edit in this shared working tree
  (`error: insufficient indentation of line in multi-line string literal`, line 828), which blocked a
  build of the *live mutation A* run. The unit/hosted mutation A run (§3) and the live positive run (§4)
  were built before that edit landed. The live negative case is therefore **not** recorded here; it is
  the unit/hosted mutation A that carries the acceptance criterion.
