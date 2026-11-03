# T48-R — the preference frames 9.11.19 actually sends

Card `t_fddfb0d5`. The gap on the card was "`preferences_changed` does not move an **already open**
post-options menu": the pin→Unpin hop landed, the Save→Remove hop did not, though the server held the
flag and closing/reopening the sheet read the right state. T48-AV (`t_531f894e`, §F2) measured the
cause on the wire; this card fixes it and flips the live test that recorded it.

## §1 The cause, as measured (not inferred)

`preferences_changed` and `preferences_deleted` carry `data.preferences` as a **JSON string**, not a
JSON array. The raw frame captured from 9.11.19 by `scripts/t48_av_probe.py` (save, then unsave):

```
event: preferences_changed, preferences_type: "str"
data.preferences = "[{\"user_id\":\"jruqqzxtobg7tn4wehwmwjjo5c\",\"category\":\"flagged_post\",\"name\":\"4nmfh6s7678fjjuekw8ykhb43c\",\"value\":\"true\"}]"
```

`SocketEvent.init(frame:)` guarded on `raw.arrayValue`, which is `nil` for a string, so the whole frame
was dropped: `.preferencesChanged` / `.preferencesDeleted` never existed against a live server. The pin
hop uses a `post_edited` frame whose payload is an object, which is why one hop landed and the other
did not.

The rest of the delivery path was checked and is not at fault:
`TeamSocketScope.accepts` accepts preferences as server-wide facts, `ChannelPaneCoordinator.handle`
feeds every post-options model before the channel windows, and `PostOptionsViewModel.handle` already
had the `.preferencesChanged` branch (with the 23-test unit suite covering it). The decoder was the
only broken link.

## §2 The fix

`Mattermost/Core/MM/SocketEvent.swift` — one helper, both call sites:

```swift
private static func preferences(from data: MMRawJSON?) -> [MMPreference]? {
    guard let raw = data?["preferences"] else { return nil }
    return try? jsonStringOrObject(raw).decode([MMPreference].self)
}
```

`jsonStringOrObject` is the existing helper the `posted` / `reaction_added` / `updatedCategories`
events already use for exactly this string-or-object ambiguity. A payload that is neither shape still
returns `nil`, so the fix widens the accepted wire forms without making every frame "decodable".

The same two cases feed T39's Saved screen (`PostCollectionViewModel`) and the sidebar service, so
those surfaces become live again on the same fix; neither was re-run live here (§5).

## §3 The falsifier: a unit test that fails on the code it replaced

New `MattermostTests/T48PreferencesSocketTests.swift` (4 tests):

1. `testTheMeasuredStringShapedSaveFrameDecodes` — the captured save frame above, verbatim.
2. `testTheMeasuredStringShapedUnsaveFrameDecodes` — the unsave direction, same string shape.
3. `testTheArrayShapedFrameStillDecodes` — the array shape the old fixture used (must not regress).
4. `testAMalformedPreferencePayloadIsStillDropped` — not-json must stay dropped, not become an empty event.

Measured on Mac Catalyst (`scripts/qa-test.py --platform mac`):

| Tree | Result | Log |
|---|---|---|
| old decoder (`da171b4`) + this test file | **4 run / 2 failures** — the two string-shaped tests red, the array and malformed ones green | `build/logs/t48r-red-mac.log` |
| decoder fix + this test file | **4 run / 0 skipped / 0 failed** | `build/logs/t48r-green-mac.log` |

Regression suites at the publish base (`db239f0` + this change), same runner:

| Suite | Result | Log |
|---|---|---|
| `MattermostTests/T48PreferencesSocketTests` | **4 run / 0 failed** | `build/logs/t48r-final-T48PreferencesSocketTests.log` |
| `MattermostTests/T48PostOptionsTests` | **29 run / 0 failed** | `build/logs/t48r-final-T48PostOptionsTests.log` |
| `MattermostTests/SocketClientTests` | **19 run / 0 failed** | `build/logs/t48r-final-SocketClientTests.log` |

## §4 The live difference between the pin path and the save path

`testASecondClientsPinAndSaveMoveTheOpenMenu` (fixture 9.11.19, `http://127.0.0.1:8065`, channel
`#t36-threads`, iPhone 15 Pro simulator) drives the sheet open and has **another session** write to the
server. The `XCTExpectFailure` wrapper is gone; the assertions are the product's again.

The two hops were measured apart, with only the decoder changed:

* **Old decoder, flip applied** → the test fails at `T48PostOptionsUITests.swift:261`, exactly the
  `postOptions.unsave` assertion, **after** the pin assertion at :247–:250 passed. `post_edited` moved
  the open sheet; `preferences_changed` did not. That is the card's "prove the difference" — not a
  timeout, and no assertion was edited. (`build/logs/t48r-live-red2.log`, 1 run / 1 failure, 132.0 s.)
* **Decoder fixed, same test, same fixture** → **1 run / 0 failures** in 60.3 s
  (`build/logs/t48r-live-green.log`), again **1 run / 0 failures** in 66.8 s with the file as it is
  committed — no in-flight harness edits (`build/logs/t48r-live-green-head.log`) — once at `bde77c5`
  in 72.6 s (`build/logs/t48r-pub-live3.log`), and at the publish base `db239f0` **1 run / 0
  failures** in 69.4 s (`build/logs/t48r-final-live.log`).

The green run's shape is the one the card asked for: the sheet is never closed between the write and
the assertion, so only the socket can have moved it.

Three attempts produced **no result** and are recorded rather than counted: `t48r-live-red.log`
(runner killed during bootstrap — "Early unexpected exit … signal kill", 515 s),
`t48r-pub-live.log` (the suite's own sign-in step lost keyboard focus at :336 — harness flake at load
≈600), `t48r-pub-live2.log` (runner killed during bootstrap, 391 s). The host carried five to eight
concurrent `qa-test.py` runs from sibling cards for most of this pass, with load averages between 100
and 1000; the clean runs above are the ones taken in the lulls.

## §5 Not measured

* **Real device / parity soak** — this pass is simulator-only.
* **The Saved screen live** (`PostCollectionViewModel`) and the sidebar preference consumer: the same
  two decoder cases feed them, and the unit suite covers the derivation, but no live run here drove a
  save from another session into the Saved tab.
* **The rest of `T48PostOptionsUITests`** — only the socket test was run, on purpose: the other four
  measure writes this card does not touch, and the suite's harness is the subject of `t_ff68111a`.

## §6 Fixture note

`t36reply` (the second author the suite signs in as) was missing from this fixture and was created by
the idempotent `scripts/t36_thread_seed.py`; the channel `#t36-threads` already existed and the seed
created only what was absent.

## §7 Artifacts

* `Mattermost/Core/MM/SocketEvent.swift` — the decoder fix.
* `MattermostTests/T48PreferencesSocketTests.swift` — the wire-form falsifier.
* `MattermostUITests/T48PostOptionsUITests.swift` — the wrapper removed.
* Logs (in the run worktree `~/.hermes/profiles/mmios-ios/cache/scratch/t48r-wt/build/logs/`):
  `t48r-red-mac.log`, `t48r-green-mac.log`, `t48r-pub-prefs.log`, `t48r-pub-t48units.log`,
  `t48r-pub-socketunits.log`, `t48r-live-red2.log`, `t48r-live-green.log`,
  `t48r-live-green-head.log`, `t48r-pub-live3.log`, `t48r-final-live.log`,
  `t48r-final-T48PreferencesSocketTests.log`, `t48r-final-T48PostOptionsTests.log`,
  `t48r-final-SocketClientTests.log`, plus the three no-result attempts above.
