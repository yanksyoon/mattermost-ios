# t_ddf85143 — modals that do not dismiss

**Reported:** "Tapping Cancel in the post options sheet does not close it; the same is true of
several other modals' Done/Cancel."

**Measured on this host, and it does not reproduce.** Nine closes across five modals close their
own presentation on iOS 18.3.1 and iOS 26.5, in the explicit-surface configuration and in the
shipped one (`app.launchArguments = []`). What the tree *did* have is the class of shape the card
names, with no test that could ever have caught it — and that is what this card fixes.

---

## 1. What was measured

The live fixture: `perf` / `t36-threads` on `http://127.0.0.1:8065`, driven by
`MattermostUITests/TModalDismissUITests.swift` (this card's new gate). One launch walks every close
in the table below; each row is an independent assertion, so a red run names the control that
failed rather than "a modal".

| # | Close | How the sheet is presented | How it closes | iOS 18.3.1 | iOS 26.5 |
|---|---|---|---|---|---|
| 1 | `postOptions.cancel` | `.sheet(item:)` on the post list (`ChannelPostListView.sheet`) | `onDismiss` closure clears the item | closed | closed |
| 2 | `channelInfo.done` | `.sheet(isPresented:)` from the pane header | `@Environment(\.dismiss)` in the sheet root | closed | closed |
| 3 | `pinnedClose` | second sheet on the same view as #2 | `onClose` closure | closed | closed |
| 4 | `profile.done` | item-bound sheet on that same view | `dismiss()` | closed | closed |
| 5 | `emojiPicker.close` | `.sheet(isPresented:)` from the composer | `dismiss()` | closed | closed |
| 6 | `addMembers.cancel` | sheet presented **from inside** the channel-info sheet | `dismiss()` | closed | not reached¹ |
| 7 | `channelInfo.done` (after #6) | — | the nested dismissal must not close the parent | closed (parent stayed up) | not reached¹ |
| 8 | `pinnedClose` (from the channel-info row) | the same slot as #6 | `onClose` closure | closed | n/a² |
| 9 | `channelInfo.done` (after #8) | — | — | closed | n/a² |

¹ iOS 26.5 run 1 stopped at #6 because the test addressed the row as `channelInfo.addMembers`; the
real identifier is `channelInfo.action.addMembers` (`ChannelInfoModels.swift:283`). That is a
harness bug in the first draft, fixed before run 2 — not a product failure. The 26.5 run was not
repeated after the fix; iOS 18.3.1 covers #6–#9.

² #8/#9 were added with the `ChannelInfoView` slot change (below).

Shipped configuration (`app.launchArguments = []`, session restored from the vault, surfaces at
their own defaults): `postOptions.cancel` = **closed** (`build/logs/tdf85143-shipped4.log`, green).
Two earlier attempts at this test are red for a harness reason worth recording: the app's own
`nativeShell` root identifier is **not drawn** on a shipped launch even though the channel pane and
the sidebar are up, so a readiness check keyed on it failed a working launch
(`tdf85143-shipped1.log`, `…-shipped3.log` — in both, the run carried on and the close measured
green). The check now keys on the channel list / quick switcher.

Logs (this host, under the worktree `build/logs/`): `tdf85143-repro1` (the reported control alone),
`tdf85143-matrix-ios18` (matrix, pre-change), `tdf85143-matrix2-fixed` (matrix, post-change),
`tdf85143-shipped2`, `tdf85143-units`.

## 2. What was actually wrong

Not one close button. Three shapes, each of which *can* produce exactly the reported symptom, and
none of which had a test:

1. **A dismissal with a silent default.** `PostOptionsSheet.onDismiss` defaulted to `{}`. A host
   that forgot to pass it compiled, drew a Cancel, and the Cancel closed nothing — the card's
   "buttons wired to a completion that no longer dismisses", available to any new call site.
2. **Several `.sheet` modifiers on one view.** `ChannelInfoView` carried two (`showsPinned`,
   `showsAddMembers`); `ChannelPaneContent` carries three. This is the shape the tree's own comment
   at `ChannelView.swift:68-73` says to avoid ("on the same view SwiftUI keeps only the last
   presentation in some states") and the shape T40 measured dropping a presentation outright. On
   iOS 18.3.1 and 26.5 all of them present, so it is a hazard rather than a live failure on these
   runtimes — but it is one sheet addition away from the reported behaviour, and nothing tested it.
3. **No coverage.** `grep -rn "postOptions.cancel" MattermostUITests` was empty before this card.
   Every existing path into the options sheet leaves it *through* something else (edit opens the
   composer, react queues the picker, a landed write dismisses itself), so a Cancel that could not
   close was invisible to the suite.

## 3. What changed

* `Mattermost/UI/Native/Channel/PostRowView.swift` — `PostOptionsSheet.onDismiss` is **required**.
  The compile step now rejects a host that draws a close without saying how it closes. (All three
  hosts already passed one; the default existed only for the host that did not exist yet.)
* `Mattermost/UI/Native/ChannelInfo/ChannelInfoView.swift` — the two `.sheet(isPresented:)`
  modifiers became **one item-bound slot** (`ChannelInfoSheetRoute.pinned` / `.addMembers`). One
  state, one presentation, one dismissal rule; the sheet's close clears the same item that
  presented it.
* `MattermostUITests/TModalDismissUITests.swift` — the gate. It measures the reported control, the
  four other reachable closes, a sheet **inside** a sheet (and that closing it leaves the parent
  up), both items of the collapsed slot, and the shipped launch a reader actually gets.

Not changed, on purpose: `ChannelPaneContent`'s three `.sheet` modifiers. They all present and all
close on both runtimes (rows 2–4 above), so collapsing them would be a refactor with no defect to
point at and a real regression surface (the header exists whether or not a row list has mounted).
It stays listed here as the next candidate if a failure is ever measured there.

## 4. What this does not claim

* The reported symptom is **not reproduced** on this host. If it is real on a reader's device, this
  card's gate does not cover that configuration; what it can say is which close fails once the same
  test is run there (every row is an independent assertion).
* Catalyst is not measured here. The iOS simulator is the platform every previous modal finding in
  this repo was measured on (`docs/t40-*`, `docs/t_8f9f5449-*`), and T40's nested-sheet failure was
  a Catalyst observation that this card cannot re-run in this session.
* The `confirmationDialog` `Cancel` buttons with empty bodies are not a defect: SwiftUI dismisses
  the dialog itself on any button tap. They are unchanged.

## 5. Running the gate

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
TEST_RUNNER_MM_AUTH_LOGIN=<fixture> TEST_RUNNER_MM_AUTH_PASSWORD=<fixture> \
python3 scripts/qa-test.py --platform ios --sim "iPhone 16 Pro" \
  --only-testing MattermostUITests/TModalDismissUITests
```

Both tests skip (never fail) when the environment or the fixture is missing.

## 6. After publish: re-measured at the current tip

The fix was published as `3fc9bd8` (+ this note as `f0dc3d8`) and has since been carried forward by
other cards. Re-run against the tree as it stands now (`a21bca1`, `origin/main` at the time of the
run), so the gate is not a claim about a commit nobody is running any more:

```
qa-test.py --platform ios --sim "iPhone 16 Pro" \
  --only-testing MattermostUITests/TModalDismissUITests
→ outcome finished (xcodebuild rc=0, 428 s), tests: 2 run, 0 skipped, 0 failed, RESULT: PASS
build/logs/tdf85143-tip-a21bca1.log
```

Every row of the table above is reproduced in that log, one line each, from the test itself:

```
MODAL-CLOSE postOptions.cancel: closed
MODAL-CLOSE channelInfo.done: closed
MODAL-CLOSE pinnedClose: closed
MODAL-CLOSE profile.done: closed
MODAL-CLOSE emojiPicker.close: closed
MODAL-CLOSE addMembers.cancel: closed
MODAL-CLOSE channelInfo.done (after nested): closed
MODAL-CLOSE pinnedClose (from channel info): closed
MODAL-CLOSE channelInfo.done (after pinned): closed
MODAL-DISMISS SHIPPED MATRIX postOptions.cancel (shipped)=closed
```

CI on the publish tip `f0dc3d8` (run 41719495855): `guard (tip + change scope)` success,
`test (ios-simulator)` **success** — the platform this change is measured on — and
`test (catalyst)` red on `T53MediaFootprintTests.testAStagedPayloadIsWrittenToDiskRatherThanHeldInMemory`,
a pre-existing main-branch failure recorded in `docs/t_ecfda04e-build-note.md` §"2141 passed, 11
skipped, 1 failed"; this card touches no media staging code.

