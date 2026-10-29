# F5′ — the three in-pane notes name the flag, not a web app the pane released

**Card:** `t_a7432eab` (implementation of `t_39ea6115` §5, amended by `t_aa211ff6` §6).
**Branch:** `t_a7432eab`, worktree `/Users/yangsooyoon/Documents/yanks/code/mattermost-ios/.worktrees/t_a7432eab`.
**Base:** parent C2 `t_2fa3bbe1` (`adc9a59`), merged with `main` `5f4e3e1` (merge `510c5ff`) so the
dispositions and lookup-defaults docs are on the branch. `main` is untouched from this card.
**Commits:** `acf18cd` (the copy + the `ContentView` comment), `3f93731` (the Saved note's title and
identifier, plus the new live suite), and this note's commit.

## 1. What shipped

| file | change |
|---|---|
| `Mattermost/UI/Native/Search/SearchView.swift` | title `"Search is off for this run (`search=web`)"`; body names the surface, not the pane |
| `Mattermost/UI/Native/Search/SavedPinnedViews.swift` | title `"Saved messages are off for this run (`search=web`)"` (verbatim), body keeps "share one switch" and adds that the switch resolves `web` for this run; identifier now addressable (§3 F2) |
| `Mattermost/UI/Native/Activity/MentionsView.swift` | title `"Mentions are off for this run (`activity=web`)"`; body names the surface |
| `Mattermost/UI/ContentView.swift:34-42` | the T30 comment no longer claims the shell is unapproved/non-pane-owning: `.channelView` is in **both** registries since the 2026-10-27 decision, so the shell is the shipped pane and the webview is released behind it (`docs/dual-render.md` §12, `docs/t_39ea6115-surface-catalogue-dispositions.md` §5.2) |
| `MattermostUITests/TA7432FallbackCopyUITests.swift` | **new** live suite (1 test, 3 notes) pinning identifier + exact title + "no text still says `rendered by the web app`" |

`searchWebFallback`, `savedWebFallback` and `activityWebFallback` are unchanged as the containers'
identifiers. Nothing about the *state* the notes describe changed: no tab hidden, no default flipped,
`nativeApprovedSurfaces`/`paneOwningSurfaces` untouched, `.composer` placeholder untouched, and the
three "Until T39-AV/T42-AV approves the flip …" header comments were left for the flip card
(`t_01afff4b`) to rewrite.

The bodies follow `t_aa211ff6` §6: they name the **surface** (`The `search` surface resolves `web`
for this run…`), never the pane's mode, so the same sentence is true under
`-surfaceMode channelView=web -surfaceMode search=web` as under the shipped pane.

## 2. Runs (all real, on this host)

| run | command | result |
|---|---|---|
| dual-render gates | `bash scripts/verify-dual-render-gates.sh --allow-approved-registry` | **RESULT: PASS**, 23 `ok` checks (`build/logs/ta7432eab-gates.log`) |
| whole unit target | `xcodebuild test … -only-testing:MattermostTests` on **iPhone 15 Pro / iOS 17.0** (`146D23D9-…`) | **1796 tests, 8 skipped, 0 failures — `** TEST SUCCEEDED **`** (`build/logs/ta7432eab-units-final.log`) |
| T39 live suite | same destination, `-only-testing:MattermostUITests/T39SearchUITests` | **4 run / 0 failed** (`build/logs/ta7432eab-ui2.log`) |
| T42 live suite | same destination, `-only-testing:MattermostUITests/T42ActivityUITests` | **4 run / 0 failed** (`build/logs/ta7432eab-ui2.log`) |
| the new copy suite | same destination, `-only-testing:MattermostUITests/TA7432FallbackCopyUITests` | **1 run / 0 failed** — the three notes are on screen with the new titles (`build/logs/ta7432eab-ui2.log`) |
| mutation check | Search's title reverted to `"Search is rendered by the web app"`, the new suite re-run, then reverted back | **2 assertions failed** (exact title + "no false claim"), `** TEST FAILED **` (`build/logs/ta7432eab-ui-mutant.log`) — the suite is not vacuous |

Gates 5 and 6, verbatim:

```
== 5. the -AV approval registry ==
  ok    nativeApprovedSurfaces is non-empty ([.auth, .calls, .sidebar, .channelView, .composer]) — allowed by flag
== 6. pane ownership is a subset of the -AV approval registry ==
  ok    paneOwningSurfaces ['channelView'] is a subset of nativeApprovedSurfaces ['auth', 'calls', 'channelView', 'composer', 'sidebar']
```

Live runs used the fixture account from `scripts/perf_seed.py` (`perfprobe`) against the server at
`127.0.0.1:8065`; each suite skips when those are absent.

## 3. What the tree said that the card did not

**F1 — no suite asserted these notes.** The card says "the UI suites that assert these notes
(`T39SearchUITests`, `T42ActivityUITests`, or whichever) still pass: they assert existence". Measured
on the branch base: `grep -rn "WebFallback" MattermostUITests MattermostTests` and
`grep -rn "rendered by the web app" MattermostTests MattermostUITests` are both **empty**. Both suites
drive the panes with `-surfaceMode search=native` / `activity=native`, so they never reach the fallback.
The notes were unverified copy — which is why this card adds `TA7432FallbackCopyUITests` instead of
only re-running the two suites. It launches with `search=web` **and** `activity=web` explicitly, so it
stays valid after the flip makes those surfaces native by default (post-flip, a `-surfaceMode …=web`
launch is the only way to reach the notes anyway).

**F2 — `savedWebFallback` was not addressable.** The Saved note carried
`.accessibilityElement(children: .contain)` **and** `.accessibilityIdentifier(…)` on the same `VStack`;
on this runtime that shape publishes no element for the note at all — the first run's accessibility
tree showed the note's two `StaticText`s hanging directly under `nativeSavedPane`, with no
`savedWebFallback` anywhere. The other two notes (identifier on the `VStack`, no `.contain`) resolve
fine, so the Saved note now uses their shape: `.accessibilityElement(children: .contain)` dropped, the
identifier kept, both texts still addressable (the suite asserts the identifier *and* the title).
This is the same class of finding C2 recorded for `savedPosts` (`docs/t_8f9f5449-c2-build-note.md` §6.4).

**F3 — a `Text` fed a literal is Markdown.** The Saved title first rendered as
`Saved messages are off for this run (search=web)` — the backticks were swallowed as inline-code
styling — while Search's and Mentions' titles kept them, because those pass the title as a `String`
variable (the `StringProtocol` initialiser, no Markdown). `Text(verbatim:)` on the Saved title makes
the three read the same, and the measured label now carries the backticks.

**F4 — the boots on this host collide.** The first whole-unit run (on the already-booted iPhone 16 Pro)
reported one failure, `MMStoreSizeTests.testEvictionReclaimsSpaceAfterTrim`, with
`Restarting after unexpected exit, crash, or test timeout` in the log. The cause was not this change:
another worker (`t_296843e5`, derived data `mattermost-ios-qa`) was running the same unit target on the
same simulator at that moment (`ps` shows it, `lstart 16:26:47`). The test passed 4/4 in isolation
(`build/logs/ta7432eab-storesize-rerun.log`, `before_free_pages=1030 posts_kept=50`) and the whole
target is green on a device nobody else is driving. Stated rather than hidden, because the first log
looks like a red suite.

**F5 — line numbers moved.** The card's `SearchView.swift:50`, `SavedPinnedViews.swift:48`,
`MentionsView.swift:38` are the pre-C2 numbers; after C2 the same hunks sit at `:50`, `:54` and `:38`
(the titles) with the identifiers at `:55`, `:68` and `:43`. Only the hunks named by the card changed.

## 4. Not this card

The **state** the copy describes — a shipped shell whose Search/Saved/Mentions tabs draw a note instead
of content — is the product decision on `t_39ea6115`'s escalation, and the flip itself is
`t_01afff4b`. This card changed no default, hid no tab, and touched no registry entry. It also left the
three view header comments ("Until T39-AV/T42-AV approves the flip the surface resolves `.web`") and
the `.composer` placeholder copy alone, per the card and `t_aa211ff6` §6.
