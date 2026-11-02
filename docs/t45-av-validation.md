# T45-AV — adversarial validation of the accessibility pass

Card `t_7de91bcf`, auditing T45 (card `t_4f60b3af`) at **`0329aff79fd99450121ea89665d5188fee385d38`**,
which is what `git ls-remote origin refs/heads/main` reported on 2026-11-02 20:07 and what the whole
run below executed. Nothing in the tree was changed: the probe suite used for the captures was
deleted before this note was committed.

## VERDICT: FAIL

Criterion 2 ("no truncated or clipped text at AX3+ in sidebar, channel view, composer, thread and
settings") does **not** hold on the shipped commit, and it is not a documentation gap: at AX5 the
channel's own name is not drawn at all, at AX3 it is cut to `T8 G pr…`, and Apple's accessibility
audit (`XCUIApplication.performAccessibilityAudit`) reports `Text clipped` on four of the five
surfaces. Criterion 3 (a VoiceOver daily-use path) has no test of any kind, and the unit test that
cites the missing test file is on `main`.

## Findings

Each finding has a reproduction command. Findings F1–F4 need a repair; F5–F7 are the evidence and
gate defects that let F1–F4 ship green.

### F1 — the channel title is clipped at AX3 and absent at AX5 (criterion 2)

`channel-ax5.png` in the implementer's own evidence shows only the `#` and the four header glyphs —
no title. That is reproducible on `0329aff`, not a stale capture:

```
xcrun simctl ui <udid> content_size accessibility-extra-extra-extra-large
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<fixture> python3 scripts/qa-test.py --platform ios --sim id=<udid> \
  --only-testing MattermostUITests/T45AVProbeUITests/testAX5DailyUsePath
```

`docs/t45-av-shots/ax5-channel.png`: the header row draws `#` and the glyphs, **no channel name**.
At AX3 (`docs/t45-av-shots/ax3-channel.png`) the same title is drawn `T8` / `G` / `pr…` — three
lines, the last one ellipsised. Apple's audit on the same screen, both sizes:

```
XCUIAccessibilityAuditType(rawValue: 131072) | Text clipped | element=nativeChannelTitle | label=T8G probe 0071
```

The pass's F2 fixed one name ("Off-Topic"); a longer name in the same header still loses its text.
The header is `HStack { title.layoutPriority(1); Spacer(minLength: 8); four glyph buttons }`
(`Mattermost/UI/Native/Channel/ChannelView.swift:971-1014`): priority decides an *infinite* line
budget, not the width the glyphs leave.

### F2 — the sidebar is not captured at any size, and the files named `sidebar-*.png` are not the sidebar

All five `docs/t45-a11y-shots/sidebar-*.png` (`default`, `ax1`, `ax3`, `ax5`,
`increase-contrast`) are the same screen: the channel pane stuck on
`NativePanePlaceholders`' "Resolving this channel…". None of them draws the team rail, the
WORKSPACE block, a channel row or the tab bar. The build note's table (§5) and the `docs/parity.md`
T45-A11y row both describe them as "the channel list at the system default / AX1 / AX3 / AX5", and
§4's F4 claim ("Verified in `sidebar-ax3.png` — 'PE' fully legible, '2' below it") cannot be checked
against an image that contains no rail at all.

```
python3 -c "..."   # or open the eight PNGs; measured with the vision pass, 2026-11-02
md5 docs/t45-a11y-shots/*.png
```

Consequence: the sidebar has **no** AX evidence, and the file offered for the team-rail fix shows
nothing of it. The sidebar's real AX5 state (captured for this card, `ax5-channel-list.png`):
`Local Matterm…` (ellipsis), `WORK-/SPACE`, `Thre/ads` — truncated and mid-word broken.

### F3 — the settings surface's value is clipped, and the offered "Increase Contrast" shot shows none of the three contrast targets

`sidebar-increase-contrast.png` is the same placeholder frame, so it contains neither the date
separator, the quote bar nor the code-block border — the only three places T45 draws contrast as a
value (`grep -c colorSchemeContrast` = 3). At AX3 the real Settings screen
(`docs/t45-av-shots/ax3-settings.png`, reached by `settingsToolbarButton`) is flagged by the audit:

```
XCUIAccessibilityAuditType(rawValue: 131072) | Text clipped | element= | label=/Users/yangsooyoon/Library/…/Downloads/
```

and its "Download Location" heading renders `Down-/load/Location` mid-word.

### F4 — the runtime control labels are not all named (criterion 1, runtime half)

The source has **0** icon-only controls without `accessibilityLabel` (my own scan: 54 glyph-button
statements, 0 unnamed; the one hit is a `Label(title, systemImage:)`, which names itself). But at AX3
XCUITest reports Buttons with an empty `label` on every surface:

```
LABELS ax3-01-channel-list buttons=25 unnamed=1   id= frame=(47.0, 56.3, 184.0, 44.0)
LABELS ax3-02-channel      buttons=19 unnamed=2   id= frame=(109.7, 772.3, 56.7, 54.7)
LABELS ax3-05-thread       buttons=25 unnamed=2   id= frame=(48.7, 56.3, 184.0, 44.0)
LABELS ax3-06-settings     buttons=22 unnamed=1   id= frame=(61.7, 113.8, 169.4, 40.5)
```

The `(47, 56)` one is the `.principal` toolbar item (the server-switcher `Menu`); whether that is a
Menu-wrapper artefact or a genuinely unlabelled element needs triage, and it is the reason F4 is
reported as a *finding* rather than folded into F1. The `(109.7, 772.3)` one is a composer glyph in
the control row. Not counted here: the thread's `post.<id>.author` button, which is a separate,
already-filed defect — see F8.

### F5 — the scan that is supposed to pin the label rule cannot see the shape the app uses

`scripts/t45_a11y_inventory.py`'s `unnameable_buttons()` reads the slice between the first `{` after
`Button` and its matching `}` — i.e. the **action** closure — so a control written
`Button { … } label: { Image(systemName: …) }` (the shape of every toolbar glyph in this app,
`RootView.swift:66-92` included) is never inspected. Measured, on a copy of the tree:

```
# a new file, Mattermost/UI/Native/Composer/T45ShapeOne.swift:
Button {
} label: {
    Image(systemName: "paperplane")
}
$ python3 scripts/t45_a11y_inventory.py --check
unnamed glyph buttons          0
RESULT: PASS
```

The scan does catch the two other shapes (`Button { Image }` and `Button {} content: { Image }` — 2
findings in a probe file), so the gap is specific and silent. The manifest test
(`T45A11yInventoryTests`) asserts the checked-in JSON, not the tree, so no suite run closes it.

### F6 — Reduce Motion and the line cap are reported, never gated

`--check` fails on four things only (unexplained fonts, unowned fonts, unnamed buttons, stale
exemptions). A probe file adding both an animation that ignores `accessibilityReduceMotion` and a
bare `.lineLimit(1)` on scaling text produced:

```
bare lineLimit(1) left         4
animation sites                5 (4 consult reduce motion)
RESULT: PASS
```

So a new unguarded animation, or a new one-line cap on text that now scales, ships green through
both the scan and the unit suite. The policy functions are well tested; the *call sites* are not
covered by anything that fails.

### F7 — the "VoiceOver daily-use path" has no test, and a shipped comment points at a file that does not exist

`MattermostTests/T45A11yTests.swift:9` says "the live UI assertions in
`MattermostUITests/T45A11yUITests.swift`". `ls MattermostUITests/T45A11yUITests.swift` →
`No such file or directory`; the commit's file list has no such file. No VoiceOver run exists
anywhere in the card. A VoiceOver pass cannot be driven from this host (there is no supported way to
read the spoken output back from a headless simulator), so criterion 3 is **not validated**, and the
comment claiming a live suite is a false reference that should not survive.

The closest thing measured here is the walk itself: with the probe suite, signing in, opening a
channel, sending a message (`channelComposer.input` → `channelComposer.send`), opening a thread and
opening Settings all succeed at AX3 and AX5 by identifier and label alone
(`build/logs/t45av-ax3d.log`, `t45av-ax5d.log`).

### F8 — (already filed) a thread reply's author is a 0×0, unlabelled button

Reproduced at AX3 on `0329aff`:

```
LABELS ax3-05-thread … UNNAMED id=post.k931z3n3if8ezqc6axti5p68fo.author frame=(58.0, 594.7, 0.0, 14.0)
```

Already tracked as `t_e73f31ce` — reported here for the measurement, not as a new repair.

## Evidence table (T45's acceptance criteria)

| Criterion | Verdict | Evidence |
|---|---|---|
| XCUITest identifier coverage intact | **PASS** | `git grep -o accessibilityIdentifier d5e964d -- Mattermost \| wc -l` = 465, at `0329aff` = 465; T45's diff removes 0 identifiers and 0 labels |
| Every interactive control has a label | **PASS (source) / FINDING (runtime)** | own scan: 54 glyph buttons, 0 unnamed; runtime XCUITest: 1–2 empty-label Buttons per surface at AX3/AX5 (F4); the shipped scan cannot see the shape (F5) |
| No truncated/clipped text at AX3+ (sidebar, channel, composer, thread, settings) | **FAIL** | §F1 (title clipped at AX3, absent at AX5), §F2 (sidebar shots are not the sidebar; the real AX5 list truncates `Local Matterm…` and breaks `Thre/ads`), §F3 (settings path clipped, `Down-/load`), and the thread's `Replying to T36…` (audit: `Text clipped | Replying to T36 Reply`) |
| VoiceOver can complete read → thread → send | **FAIL (not validated)** | no VoiceOver run; the cited live suite does not exist (F7); the label-driven walk succeeds (proxy only) |
| Reduce Motion disables non-essential animation | **PASS (structural)** | `grep -c accessibilityReduceMotion` 0 → 4; 4/4 animation sites consult it; 20 policy tests; not observed at runtime, and not gated by `--check` (F6) |
| DoD: unit tests green on Catalyst | **PASS** | `Executed 1866 tests, with 9 tests skipped and 0 failures (0 unexpected) in 88.751 s`, `** TEST SUCCEEDED **`, from a never-built derived-data path; T45 classes 20 + 11 = 31, 0 failures, 0 skipped |
| DoD: screenshot proving real server data | **PARTIAL** | channel pane shots show the fixture's real posts; the sidebar shots show the unresolved-deep-link placeholder (F2) |
| DoD: parity rows updated | **PASS (with a false claim)** | `docs/parity.md:125` exists and repeats the sidebar-screenshot claim |
| DoD: commit in `type(scope)` with the card id, on the remote | **PASS** | `0329aff` `feat(shell): … (t_4f60b3af)`; local HEAD = `git ls-remote origin refs/heads/main` |

## Negative space (what the card does not cover, and is not documented as uncovered)

* **VoiceOver itself.** Labels are asserted; no screen is ever read by VoiceOver, no rotor/order/
  hint work, `accessibilitySortPriority` 0 hits, 4 hints total.
* **Settings is substituted.** The criterion names "settings"; the inventory's `SURFACES` maps
  `settings` to `Mattermost/UI/Native/Profile`, but the app's settings screen is
  `Mattermost/UI/SettingsView.swift` (the gear). The pass never says the substitution was made.
* **Catalyst.** The card's Scope includes "keyboard/pointer support on Catalyst". Nothing in the
  diff addresses it (`grep -c "keyboardShortcut|onHover|pointerStyle" Mattermost/UI` = 1, and it is
  the pre-existing quick-switcher shortcut). The build note records only that Catalyst ignores the
  forced `dynamicTypeSize` — not that keyboard/pointer support was left out.
* **Other text at a fixed point.** 34 sites remain, all glyphs under the pass's own definitions
  (spot-checked: `Image(systemName:)` in fixed controls, avatar initials, one `Text(glyph)` emoji
  cell). That claim holds; the *glyph* sizes still do not scale, which is a deliberate choice but
  means the rail's initials and the toolbar glyphs stay put at AX5.
* **Increase Contrast** is three value sites and no capture of any of them (F3).

## Commands run for this card

```
git rev-parse HEAD                                        # 0329aff79fd99450121ea89665d5188fee385d38
git ls-remote origin refs/heads/main                      # same SHA
xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/mmios-t45-av-200738 \
  -clonedSourcePackagesDirPath ~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa/SourcePackages \
  -only-testing:MattermostTests
python3 scripts/t45_a11y_inventory.py --check
python3 scripts/t45_a11y_inventory.py --json
xcrun simctl ui 81A7F251-8B31-4945-8783-5A264C14B8D5 content_size accessibility-extra-large
xcrun simctl ui 81A7F251-8B31-4945-8783-5A264C14B8D5 content_size accessibility-extra-extra-extra-large
python3 scripts/qa-test.py --platform ios --sim id=81A7F251-… \
  --only-testing MattermostUITests/T45AVProbeUITests/testAX3DailyUsePath
python3 scripts/qa-test.py --platform ios --sim id=81A7F251-… \
  --only-testing MattermostUITests/T45AVProbeUITests/testAX5DailyUsePath
```

Logs (outside the repo, this profile's evidence dir):
`~/.hermes/profiles/mmios-qa/t45av-evidence/catalyst-full.log`,
`ax3d-run.log`, `ax5d-run.log`, and the exported `.xcresult` attachments in `ax3d-att/`, `ax5-att/`.
The simulator was restored to `content_size = large` and Increase Contrast left off.

## Licence and secrets

No AGPL source, no `mattermost-webapp` file, and no URL, token or credential in the commit's added
lines (`git show 0329aff --format= --unified=0 | grep '^+'` matched none of
`http(s)://|token|secret|password|AGPL|copyright`). The new files are SwiftUI + Python of this
repo's own authorship.
