# The three lookup screens: approve the defaults (option 1, both keys, one commit)

Card: **`t_aa211ff6`** (`mmios-architect`), filed by `t_39ea6115`
(`docs/t_39ea6115-surface-catalogue-dispositions.md` §5.2, §5.4, §6.3). Date: 2026-10-29.
Measured against `main` = `0922d55`; the app code is unchanged from `cfc9cb5` apart from the two
files `t_cdcc1f38`/`t_39ea6115` do not own (`Mattermost/Core/Calls/CallsEngine.swift`,
`MattermostTests/T44CCallsMediaTeardownQueueTests.swift`, dirty in the shared checkout from another
worker and not compiled here).

---

## 1. The decision

**Option 1 — approve the lookup defaults — for `both` keys, in one labelled commit, followed by one
ship-shaped QA round whose subject is a Release build with no launch arguments.**

Concretely: `SurfaceDefaults.nativeApprovedSurfaces` gains `.search` and `.activity`
(`RenderMode.swift:104`, `[.auth, .calls, .sidebar, .channelView, .composer]` → seven entries).
`paneOwningSurfaces` is **not** touched (`RenderMode.swift:120` stays `[.channelView]`), so the
webview release policy (`docs/dual-render.md` §12.1) does not move: the lookup screens render beside
no webview for exactly the reason §11 states, and this decision does not change that.

The two entries are **two independent claims** and the commit must say so in its body (§4). They
land together because the shell that this card exists to fix is the *sum* of them: leaving
`.activity` web while `.search` flips would leave one dead tab of five and the reader would have to
know which regions were approved when. The 2026-10-27 workspace flip
(`t_c93b8337`, `docs/tc93b-build-note.md`) is the precedent for landing a set of surface approvals
behind one post-edit QA round, and that is the shape used here.

**A fresh `-AV` is not required, and this is not an owner-policy exception.** `docs/dual-render.md`
§5 is mechanical: *a screen card may only switch its own surface to native-by-default when its paired
`-AV` adversarial validator has passed.* Both have a passing verdict on the code that is on `main`
today (§3). The 2026-10-27 owner decision was needed because those validators **deferred** the flip
in their own verdict; neither of these did.

## 2. Why not 2, and why not 3

**Option 2 (stop offering the tab/button while the surface resolves `web`) is a capability loss, and
it is the worst of the three for a shipped reader.** The native screens exist, are validated and are
tested: 50 T39 unit tests (45 + 5 API) and a 7/7 live run in the T55-AV-R re-validation
(search/saved/pinned), 46 T42 unit tests and 4/4 live (mentions).
Hiding the entry points while `.channelView` is pane-owning would leave search, saved, pinned and
mentions **unreachable in a Release build** — the web app's own screens live in a webview that
`RootView.releaseIfNeeded` destroys (§12.2), and the only way back to it is "Use web view", which
gives up the native workspace to get search back. Option 2 is honest about the note and dishonest
about the product: it ships a shell with no search.

It is also *the same edit as option 1 plus a gate*. Removing five mount points
(`NativeShellView.swift:227, 236, 242` and the three toolbar items at `:149, :157, :168`) and then
removing the gates again after a flip is two changes to the same code for one outcome. If a reader
must see the note in a `web` configuration, that configuration is a DEBUG one
(`-surfaceMode search=web`, §8) — and a DEBUG reader has the inspector, not a tab bar.

**Option 3 (accept the notes as a stated limit) puts the dead direction on the shipped default.** The
programme's own refinement (§1.1 of the dispositions doc) says a case is a switch only if flipping
it can change the screen in at least one direction; `search` and `activity` pass that test *only
because their native direction works*. Option 3 would ship the configuration in which the working
direction is unreachable and the documented one changes nothing on screen — the defect the `-AV`
discipline exists to prevent, written into §11 as policy. Rejected.

## 3. The evidence, as each verdict actually reads

The card asks whether the parity rows' evidence (*"native ✅ behind the flag"*) suffices. Measured
from the board, not from the parity prose — which is thinner than the record:

| Verdict | Card | What it actually returned |
|---|---|---|
| **T39-AV** | `t_3c83d5e7` | **FAIL**, nine findings, F1 blocking (`time_zone_offset` sent in minutes against an API that reads seconds: `on:`/`before:`/`after:` were evaluated against a UTC day — `in:t34-showcase on:2026-10-26` = 3 in the app, 1 in the web client) |
| **T39-R** | `t_37a4545b` | closes F1–F9; the unit and live pins name each finding (`docs/t39-search-build-note.md:7-23`) |
| **T55-AV-R** | `t_6059f7ce` | **`.search` PASS-WITH-FINDINGS** at `634afd9`, re-derived in a detached worktree: six one-line mutations producing 17 unit + 11 live assertions of red *including the exact T39 "3 vs 1" day-boundary mismatch*; T39 live **7/7** |
| **T39-R2** | `t_c3957991` | the harness only — no `Mattermost/` or `MattermostTests/` change; makes the 7/7 falsifiable (cookie-free `restSession`, fixture-anchored offset day) |
| **T42-AV** | `t_af5a4d3b` | **PASS-WITH-FINDINGS** at `5f90ea9`: Catalyst 1,425 run / 4 skipped / 0 failures (T42's 46 none skipped), shipped live suite 4/4 + its own UI probe 1/1, a live probe showing the feed equals the server's window (88==88) and the badge equals the server's mention total (7==7) |
| **T42-R** | `t_b483a58d` | closes F1–F5; the AV itself called them *"documentation and test-strength only"* (`docs/t42-build-note.md:110,157,167,170,175,182`) |

So the parity rows under-state the record: `.search` carries **two** verdicts (a FAIL and then a
repair plus a re-validation inside a *pane-owning* shell), and `.activity` carries a clean
PASS-WITH-FINDINGS whose findings never touched production behaviour.

**Is the code that was validated the code that ships?** Checked, because a verdict on a stale tree is
not evidence:

```
$ git log --oneline 634afd9..HEAD -- Mattermost/UI/Native/Search Mattermost/UI/Native/Activity \
                                Mattermost/Core/RenderMode.swift
(no commits)                      # the validated files are byte-identical on main
$ git log --oneline 5f90ea9..HEAD -- Mattermost/UI/Native/Activity
00cd217 feat(posts): the post options menu offers what v2.45.0 offers (t_37f27c09)
```

The one change since is `00cd217`, which touches the **shared** `PostRowView` that search results and
mention rows draw — a menu gained, nothing removed. That is not a reason to re-open a verdict, but it
**is** a reason the post-flip QA round must open a row's options menu in both lookups (§7).

**One limit recorded, not hidden:** neither verdict was issued while the surface resolved native *by
default* — both were measured with `-surfaceMode …=native`. That is exactly the gap the flip commit
is, and it is why the flip is not complete until the ship-shaped measurement in §7 exists. It is not
a reason to ask a validator for a third opinion: the flag path and the registry path reach the same
`resolvedMode(for:)` value, and the registry path is the *simpler* one (no launch tier at all).

## 4. The two claims, separately

**`.search` — S19 search, S20 saved, S21 pinned.** What the flip makes reachable on every shipped
build: the Search tab (`NativeShellView.swift:222-228`) and the iPad toolbar sheet (`:149`), the
Saved tab (`:238-243`) and its sheet (`:157`), and the channel header's pinned button
(`ChannelView.swift:1008-1017`), all three gated on this one key (`SearchView.swift:36`,
`SavedPinnedViews.swift:32,69`, `ChannelView.swift:1008`).

*The surface's §4 row also names **S26 Drafts**, and the drafts *list* is not ported.* That is not a
claim this flip makes and not a hole this flip opens: a draft is written and restored per channel by
the composer (`ComposerDraftStore`, `ComposerViewModel.restoreDraftIfNeeded()`), but
`allDrafts(limit:)` has **no production caller** — there is no drafts screen and no route to one,
today or in a shipped build, because the webview that would draw it is released. S26's screen is
`t_e1ac98d8` (T51). The `docs/dual-render.md` §4 row must say so in one clause so the approval is not
read as "drafts ship".

**`.activity` — S25 mentions inbox.** What the flip makes reachable: the Mentions tab
(`NativeShellView.swift:231-237`) and the toolbar sheet (`:168`), gated at `MentionsView.swift:32`.

Approving this approves the inbox's stated limits into the product, and that is deliberate: the
window is a mentions-only `POST /posts/search`; a busy account on a database backend sees one window
with no "load more"; the header's unread count and the app badge are **two numbers on purpose**
(measured 17 vs 7); a single reply's "mark read" moves the header and no badge number. The readers
who get the alternative (no mentions at all, because the webview is released) get strictly less, and
the web client's own Recent Mentions screen uses the same window with the same mentions-only scope.

## 5. What the flip does not change

* `paneOwningSurfaces` stays `[.channelView]` — no lookup screen may release a webview (§12.1, gate 6).
* `paneHostSurface` stays `.channelView`.
* The release policy, the escape hatch (`forceWebForThisRun` is per-surface and writes `.web` only —
  `SurfaceModeResolver.swift:199-206`) and every debug tier are untouched.
* No view gains or loses a branch: the panes' gates are already correct, they simply stop being true
  by default.
* No copy is edited by the flip commit (`t_a7432eab` owns the note strings, §6).

## 6. What the flip does to the F5′ copy card

After the flip, `searchWebFallback` / `savedWebFallback` / `activityWebFallback` become **DEBUG-only**
in practice: a Release build has no tier that can resolve those two surfaces `web` (no launch, no
persisted row, no remote producer — `docs/dual-render.md` §5's table, gates 2–4), so the notes are
reachable only under a `-surfaceMode …=web` launch or the inspector.

That collides with **one clause** of the copy `t_39ea6115` §5.3 specified: *"This pane is native, so
the web app is not mounted to draw it."* In the DEBUG configuration `-surfaceMode channelView=web
-surfaceMode search=web` the pane is **not** native, so that causal clause is false. The titles
("… is off for this run (`search=web`)") are true in every configuration and land as specified.

The requirement is amended for the copy card, **before it runs** (it is in `todo`), by a comment on
`t_a7432eab`: keep the three titles verbatim; make the bodies name the *surface*, not the pane —
e.g. *"The `search` surface resolves `web` for this run, so the native screen is off; the web app
draws search only while the workspace itself renders web."* One wording, true in every state, and no
second pass needed when the flip lands.

## 7. What ships

**A. `mmios-ios` build card — the flip (`docs/t_aa211ff6-build-note.md`).** One commit,
`feat(render): the lookup surfaces are native by default — search, saved+pinned and the mentions
inbox (t_aa211ff6)`:

1. `RenderMode.swift:104` — append `.search, .activity`; ledger doc comment gains their two rows
   (`docs/dual-render.md` §5 table is the same content, keep them identical):

   | Surface | Approved by | Evidence |
   |---|---|---|
   | `.search` | T39-AV (`t_3c83d5e7`, FAIL) → T39-R (`t_37a4545b`) → **T55-AV-R (`t_6059f7ce`, `.search` PASS-WITH-FINDINGS)** → T39-R2 (`t_c3957991`, harness only) | `docs/t39-search-build-note.md`, `docs/t55-revalidation-build-note.md` §3/§6 (mutation-checked closures, T39 live 7/7), `docs/t39-r2-build-note.md` (the 7/7 made falsifiable) |
   | `.activity` | T42-AV (`t_af5a4d3b`, `PASS-WITH-FINDINGS`) + T42-R (`t_b483a58d`, findings F1–F5 closed — documentation and test strength only) | `docs/t42-build-note.md`, `docs/parity.md` T42 row (46 unit, 4/4 live, 4/4 again after T42-R) |

2. **Tests** (the pins that must move, measured):
   * `SurfaceModeResolverTests.swift:43-46` and `ViewStoreTests.swift:284-286` — the two exact-set
     literals, 5 → 7 entries, and the doc comment above `:43` ("It holds five entries").
   * `SurfaceModeResolverTests.swift:95` — the "everything else stays web" loop: `.search` and
     `.activity` come out; after `t_6d420e01` the loop is `.channelInfo` alone.
   * `SurfaceModeResolverTests.swift:138-161` (`testPersistedOverrideRoundTrips…`,
     `testTogglingBackToDefaultClearsOverride`) and `:466` (`testClearAllOverrides…`) use `.search`
     as *the web-by-default surface*. After the flip, `setOverride(.web, for: .search)` no longer
     clears the row (`.web` is not its default) and a cleared override resolves `.native`. Move those
     three tests onto `.channelInfo`, which is the only unapproved survivor.
   * `testNativeByDefaultRequiresApproval` keeps `.threads` as its "unapproved really is web" pin
     until `t_cdcc1f38` retires it; do not re-point it at `.search`.
3. **Gate 5** — run `bash scripts/verify-dual-render-gates.sh --allow-approved-registry` **in this
   commit**. Baseline measured today on `0922d55`: without the flag gate 5 alone fails
   (`nativeApprovedSurfaces is non-empty ([.auth, .calls, .sidebar, .channelView, .composer]) without
   -AV evidence`), with it all ten gates PASS (`RESULT: PASS`). The flag is the audit signal for
   exactly this commit; gate 6 must still print `['channelView'] is a subset`.
4. **Stale comments that assert the old state** (they are the *only* reason the flip touches view
   files; coordinate with `t_a7432eab`'s copy, which is a different hunk):
   `SearchView.swift:11-14`, `SavedPinnedViews.swift` (same header), `MentionsView.swift:9-11`
   ("Until T42-AV approves the flip the surface resolves `.web`"), and
   `ContentView.swift:34-39` if `t_a7432eab` did not already correct it.
5. **Docs**: `docs/dual-render.md` — §3 bullet 4 (`:77-78`, "that registry holds …"), `:80-82`
   ("still falls back to the webview for every unapproved surface"), §4's `.search` row (add the
   "S26 Drafts is T51's, not this approval's" clause), §5's ledger table, §10's
   `testOnlyTheApprovedRegistryDefaultsToNative` row, §11's **"Native surfaces: five"** (`:479`) →
   seven and the §11 bullet at `:461-478` (the `.search`/`.activity` "gated inside their own panes"
   clause now describes DEBUG only); `docs/parity.md` rows **T39** (`:113`) and **T42** (`:116`) —
   "behind the flag" becomes "native by default since `t_aa211ff6`", with the registry entry named.
6. **Acceptance**: whole unit target green (state counts); gate run above quoted verbatim; a grep
   proving no remaining production comment says the surface resolves `web` by default.

**B. `mmios-qa` ship-shaped QA card — "what a reader sees with no flags" (child of A).** Extends the
existing `MattermostUITests/T93BNativeByDefaultUITests.swift` pattern (*launch with
`app.launchArguments = []`, Release build, seeded container, skip when unseeded) and must report
from a **Release** build:

* iPhone/compact: five tabs; tapping Search draws `nativeSearchPane` + `searchField`, Saved draws
  `savedPosts`, Mentions draws `activity.list`; **no** `searchWebFallback` / `savedWebFallback` /
  `activityWebFallback` exists anywhere.
* iPad/regular: `shellSearchButton` / `shellSavedButton` / `shellActivityButton` open sheets that
  draw the same native screens, and `nativeChannelPinnedButton` exists in a channel header and opens
  `pinnedSheet`.
* A row's **options menu** opens in both a search result and a mention row (`00cd217` is newer than
  both verdicts — §3).
* Escape hatch: "Use web view" returns the workspace to a loaded webview **and** the lookup tabs
  still draw native screens (the app must not show a note in that state).
* Badge: with the native feed mounted, the app badge still equals the server's summed
  `mention_count` (no double count with `MentionPoller`).

If B finds a FAIL, the verdict is *not* "revert the flip silently": the flip commit is one line and
one revert, and B's finding is the missing `-AV` round this decision says the flip must carry.

## 8. Ordering and the hotspot this decision creates

The flip is parented on **`t_6d420e01`** (`t_39ea6115`'s retirement card) **and `t_a7432eab`** (the
F5′ copy), because all three edit overlapping ground:

* `RenderMode.swift` — `t_6d420e01` rewrites the catalogue and `unhostedSurfaces` in the same file.
* `SurfaceModeResolverTests.swift` — `t_6d420e01` retires three cases and moves the
  "unapproved surface" stand-in; the flip moves it again if both touch `:95`. One edit, not two.
* `SearchView.swift` / `SavedPinnedViews.swift` / `MentionsView.swift` — `t_a7432eab` edits the note
  strings, `t_6d420e01` drops the `profileSurface:` argument, the flip corrects the header comments.

**Correction issued to `t_6d420e01`** (comment on that card, before it runs): do not substitute
`.search` — or `.activity` — as the resolver suite's unapproved surface. Its correction from
`t_39ea6115` §8.5 says `.channelInfo` "then `.search`"; after this decision `.search` is *approved*
and inverts every test that uses it as a web-by-default stand-in. Use `.channelInfo` only; the
"everything else stays web" loop ends at `[.channelInfo]`; leave the two pinned registry literals
alone (the flip moves them 5 → 7).

**Hotspot:** `MattermostTests/SurfaceModeResolverTests.swift` — three cards edit it in sequence.
Flagged on the board, not silently absorbed.

## 9. What was measured here, and what was not

Measured on this tree (not inherited): the registry and pane-ownership literals
(`RenderMode.swift:104,120`); the five mount points and their three gates (§4); the pinned button's
gate (`ChannelView.swift:1008`); both exact-set test pins; the three tests that use `.search` as the
web stand-in; the gate baseline in both modes (§7.3); `git log` proof that the validated Search/ and
Activity/ files are unchanged on `main`; the absence of any drafts route.

**Not** measured here: a Release-build UI run. This card is a decision and does not build; the
shipped-build measurement is §7-B's deliverable and its acceptance criterion, and it is the one thing
that would make this decision wrong if it comes back red.

## 10. Sources

* `docs/t_39ea6115-surface-catalogue-dispositions.md` §5.2 (reachability), §5.3 (copy), §6.3 (this
  card), §8.5 (the `.search` substitution correction).
* `docs/dual-render.md` §3 (resolution order), §4 (surfaces + the three-part switch test), §5 (the
  `-AV` gate and the approval ledger), §10 (test map), §11 (known limits), §12.1/§12.2 (pane
  ownership and destroy-not-park).
* `docs/parity.md` T39 (`:113`) and T42 (`:116`) rows.
* Board: `t_3c83d5e7` (T39-AV, FAIL), `t_37a4545b` (T39-R), `t_6059f7ce` (T55-AV-R, `.search`
  PASS-WITH-FINDINGS), `t_c3957991` (T39-R2), `t_af5a4d3b` (T42-AV, PASS-WITH-FINDINGS),
  `t_b483a58d` (T42-R), `t_c93b8337` (the 2026-10-27 owner decision this is *not* modelled on).
* Code: `Mattermost/Core/RenderMode.swift:104,120`, `Mattermost/UI/Native/NativeShellView.swift:146-174,220-242`,
  `Mattermost/UI/Native/Search/SearchView.swift:36`, `Mattermost/UI/Native/Search/SavedPinnedViews.swift:32,69`,
  `Mattermost/UI/Native/Activity/MentionsView.swift:32`, `Mattermost/UI/Native/Channel/ChannelView.swift:1008`,
  `Mattermost/Core/SurfaceModeResolver.swift:199-206`.
