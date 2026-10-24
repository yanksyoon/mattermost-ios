# Parallel work — worktrees, file ownership and merge order (T30b)

- **Status:** delivered (T30b). Governs every card from **T31** (first screen card) through **T46**,
  plus the integration card that merges the parallel tracks.
- **Date:** 2026-10-24
- **Consumes:** `docs/component-map.md` (which screen goes where, §5 per-surface map),
  `docs/dual-render.md` (the render-policy gates), `docs/parity.md` (module→native mapping).
- **Enforced by:** `scripts/verify-dual-render-gates.sh` gates 8–10 (see §7).

---

## 1. The problem this solves

Until T30b every Swift file was registered by hand in
`Mattermost.xcodeproj/project.pbxproj`: one `PBXFileReference` plus one `PBXBuildFile` per file,
199 of them, **zero** `PBXFileSystemSynchronizedRootGroup`. Two workers adding files at the same time
is a text-level conflict in a file that cannot be merged by hand: the damage is not a merge conflict
but a **duplicate object id** — two entries with the same 24-hex id, of which Xcode silently keeps
one. The build stays green and a file quietly stops being compiled. That happened twice on this board
before T30b.

T30b removes the cause:

| Tree | How files are registered now |
|---|---|
| `Mattermost/UI/Native/` (all native screens) | `PBXFileSystemSynchronizedRootGroup` — the build reads the folder from disk |
| `MattermostTests/` (unit tests) | synchronized as well — a card ships tests with its screen |
| `MattermostUITests/` (UI tests) | synchronized as well |
| everything else under `Mattermost/` | unchanged: still per-file entries |

**A screen card never edits `project.pbxproj`.** Drop the file in the folder, it compiles. Proven,
not assumed: a throwaway file in each of the three trees was built/tested with the project file's
sha256 unchanged before and after (`docs/t30b-build-note.md` §3).

`Mattermost/` itself is **not** synchronized, on purpose: it mixes sources with `Info.plist`,
`Mattermost.entitlements`, `PrivacyInfo.xcprivacy` and `Assets.xcassets`, and those keep their
current handling. That is why the native tree is a dedicated folder.

---

## 2. Adding a file (the whole procedure)

1. Put the file where the manifest (§5) says, e.g. `Mattermost/UI/Native/Channel/PostListView.swift`.
   One type per file, file named after the type (Swift convention; it is also what makes the manifest
   checkable).
2. `git add` it. A synchronized folder can only pick up what is **in the working tree**; an untracked
   file is invisible to a fresh clone, and gate 8 fails a tree whose files are not tracked.
3. Build. Nothing else. No project-file edit, no Xcode "Add Files…", no `PBXBuildFile` id.
4. `scripts/verify-dual-render-gates.sh` must pass (§7 gate 10 fails any diff that adds a
   `PBXFileReference` for a source file).

Do **not** run Xcode's *Convert to Group* on these folders, and do not "fix" the missing file entries
by adding them back: gate 8 fails a synchronized tree that also has hand-written entries (that
combination compiles the file twice).

---

## 3. Worktrees: one per track

Every screen card that runs in parallel with another gets its own `git worktree`:

```
# created by the dispatcher when the card is created with
#   kanban_create(..., workspace_kind="worktree")
# the branch is deterministic: wt/<task-id> off main
git worktree add ~/Documents/yanks/code/mattermost-ios/.worktrees/<task-id> \
    -b wt/<task-id> main

# the card works, commits on its own branch, and does NOT merge:
cd .worktrees/<task-id> && git add -A && git commit -m "feat(native): … (T3x)"
```

Rules that make that safe:

1. **A card commits only on its own branch.** It never merges `main` into its branch and never pushes
   to `main`.
2. **A card never edits `project.pbxproj`,** and never edits `Mattermost/Core/Native/NativeNavigation.swift`
   (the navigation route table) — see §6.
3. **Build and test inside the worktree**, with derived data outside `~/Documents` (TCC; see
   `scripts/qa-test.py`, which refuses a TCC-unsafe path because a failing test there wedges):
   `scripts/qa-test.py --platform mac --label <card>-cat` from the worktree root.
4. **Run the gate from the worktree with an explicit base** so the diff check has something to audit:
   `scripts/verify-dual-render-gates.sh --base main`.

---

## 4. Merge order (fixed)

The integration card merges in exactly this order. The order is not a preference: each batch uses a
seam the batch before it lands, and the post row (batch 4) must exist before reactions, attachments
and options can hang off it.

| Batch | Cards | Why this position |
|---|---|---|
| 0 | **T30b** (this card) | the unlocked file layout everything after inherits; lands alone |
| 1 | **T31** auth (S01–S04, S06, S37) | first screen; also the first authenticated fixtures the rest test against |
| 2 | **T32** team sidebar (S07, S08-team), then **T33** channel sidebar (S08-channel, S09, S10) | the sidebar is where a native channel gets selected; T33 reads T32's team model |
| 3 | **T34** channel view + post list (S11, S38) | owns `PostRowView` — the shared row the next batch decorates |
| 4 | **T35** composer (S14, S15, S26, S40) → **T36** threads (S12, S13) → **T37** reactions + emoji (S16, S17) → **T38** attachments (S18) | this order only: composer and thread land before the row decorations, so the row's seams are already exercised |
| 5 | **T39** search/saved/pinned (S19–S21) → **T40** channel info (S22, S23) → **T41** profile/settings (S24, S27, S28, S39) → **T42** activity (S25) | independent of each other; sequential only because they all add tabs/routes |
| 6 | **T43** notifications (S35, S36) → **T44** Calls (S33) → **T46** webview escape hatch (S29–S33) | system-level; needs the full route table |
| 7 | **T45** accessibility (Dynamic Type, VoiceOver) | a whole-tree pass; it cannot start before the tree exists |

Within a batch, cards may run in parallel. **Between** batches, the earlier batch is merged and `main`
is green before the next starts.

Each `-AV` card (`T31-AV` … `T46-AV`) audits the card it names **after** that card's merge, from a
detached worktree with the main tree untouched — that is the existing pattern (see T30-AV) and the
integration card does not merge an `-AV` branch, it only reads its verdict.

---

## 5. File manifest and per-card ownership

Convention: one type per file, `Mattermost/UI/Native/<Area>/<TypeName>.swift`; tests
`MattermostTests/<Card>-<Area>Tests.swift` (one test file per card per area keeps ownership
unambiguous). The names below come from the *Decomposition* lines of `docs/component-map.md` §5 — a
card creates exactly the files it owns, and no file that is not in its row.

| Card | Screens (component map) | Owns — files it may create / edit |
|---|---|---|
| **T31** | S01 login, S02 MFA, S03 SSO, S04 signup/forgot, S06 ToS, S37 welcome/join | `Auth/LoginView.swift`, `Auth/LoginViewModel.swift`, `Auth/MFAView.swift`, `Auth/MFAViewModel.swift`, `Auth/SSOView.swift`, `Auth/SSOViewModel.swift`, `Auth/SignupView.swift`, `Auth/ForgotPasswordView.swift`, `Auth/TermsOfServiceView.swift`, `Auth/TOSViewModel.swift`, `Auth/JoinTeamView.swift`, `Auth/AuthCoordinator.swift`, `MattermostTests/T31-AuthTests.swift` |
| **T32** | S07 team selection, S08 (team sidebar) | `Sidebar/SelectTeamView.swift`, `Sidebar/SelectTeamViewModel.swift`, `Sidebar/TeamSidebarView.swift`, `Sidebar/TeamSwitchViewModel.swift`, `MattermostTests/T32-TeamSidebarTests.swift` |
| **T33** | S08 (channel list, categories), S09 find/browse, S10 create/edit channel | `Sidebar/ChannelSidebarView.swift`, `Sidebar/ChannelSidebarViewModel.swift`, `Sidebar/ChannelListRowView.swift`, `Sidebar/ChannelIconView.swift`, `Sidebar/FindChannelsView.swift`, `Sidebar/FindChannelsViewModel.swift`, `Sidebar/ChannelFormView.swift`, `Sidebar/ChannelFormViewModel.swift`, `MattermostTests/T33-ChannelSidebarTests.swift` |
| **T34** | S11 channel view + post list, S38 post options | `Channel/ChannelView.swift`, `Channel/ChannelViewModel.swift`, `Channel/PostListView.swift`, `Channel/PostListViewModel.swift`, **`Channel/PostRowView.swift`**, `Channel/PostHeaderView.swift`, `Channel/PostBodyView.swift`, `Channel/PostBodyViewModel.swift`, `Channel/PostFooterView.swift`, `Channel/DateSeparatorView.swift`, `Channel/NewMessageLineView.swift`, `Channel/MoreMessagesView.swift`, `Channel/SystemMessageView.swift`, `Channel/PostOptionsView.swift`, `Channel/PostOptionsViewModel.swift`, `MattermostTests/T34-ChannelViewTests.swift` |
| **T35** | S14 composer, S15 autocomplete, S26/S40 drafts + scheduled | `Composer/ComposerView.swift`, `Composer/ComposerViewModel.swift`, `Composer/AutocompleteView.swift`, `Composer/AutocompleteViewModel.swift`, `Composer/EditPostView.swift`, `Composer/GlobalDraftsView.swift`, `Composer/ScheduledPostOptionsView.swift`, `Composer/RescheduleDraftView.swift`, `MattermostTests/T35-ComposerTests.swift` |
| **T36** | S12 permalink, S13 thread RHS + global threads | `Threads/ThreadView.swift`, `Threads/ThreadViewModel.swift`, `Threads/GlobalThreadsView.swift`, `Threads/GlobalThreadsViewModel.swift`, `Threads/PermalinkResolverView.swift`, `MattermostTests/T36-ThreadsTests.swift` |
| **T37** | S16 reactions, S17 emoji picker | `Reactions/ReactionBarView.swift`, `Reactions/ReactionsView.swift`, `Reactions/ReactionsViewModel.swift`, `Reactions/EmojiPickerView.swift`, `Reactions/EmojiPickerViewModel.swift`, `MattermostTests/T37-ReactionsTests.swift` |
| **T38** | S18 files, gallery, PDF/code/table viewers | `Files/FileRowView.swift`, `Files/ImageFileView.swift`, `Files/AudioFileView.swift`, `Files/VideoFileView.swift`, `Files/DocumentFileView.swift`, `Files/FileIconView.swift`, `Files/GalleryView.swift`, `Files/PDFViewerView.swift`, `Files/FileViewModel.swift`, `MattermostTests/T38-FilesTests.swift` |
| **T39** | S19 search, S20 saved, S21 pinned | `Search/SearchView.swift`, `Search/SearchViewModel.swift`, `Search/SavedMessagesView.swift`, `Search/PinnedMessagesView.swift`, `MattermostTests/T39-SearchTests.swift` |
| **T40** | S22 channel info/add members, S23 member list/invite/DM | `ChannelInfo/ChannelInfoView.swift`, `ChannelInfo/ChannelInfoViewModel.swift`, `ChannelInfo/MemberListView.swift`, `ChannelInfo/MemberListViewModel.swift`, `ChannelInfo/InviteView.swift`, `ChannelInfo/CreateDirectMessageView.swift`, `MattermostTests/T40-ChannelInfoTests.swift` |
| **T41** | S24 profile popover + status, S27 settings sections, S28 edit profile, S39 custom attributes | `Profile/UserProfileView.swift`, `Profile/UserProfileViewModel.swift`, `Profile/CustomStatusView.swift`, `Profile/EditProfileView.swift`, `Profile/CustomProfileFieldsView.swift`, `Profile/SettingsSectionsView.swift`, `MattermostTests/T41-ProfileTests.swift` |
| **T42** | S25 mentions inbox + in-app toast | `Activity/MentionsView.swift`, `Activity/MentionsViewModel.swift`, `Activity/InAppNotificationOverlay.swift`, `MattermostTests/T42-ActivityTests.swift` |
| **T43** | S35 notifications, S36 deep links/share extension | `Mattermost/Core/Native/NativeNotificationService.swift`, `Mattermost/Core/Native/NativeShareExtensionView.swift`, `MattermostTests/T43-NotificationsTests.swift` — plus the existing `Core/NotificationWorker.swift` |
| **T44** | S33 Calls (webview or native spike) | `Calls/CallsSurfaceView.swift` **only if** the spike decides native; otherwise no file, the surface stays webview (T46) |
| **T45** | cross-cutting accessibility pass | **no new files.** It edits every screen file — see §6, it is the one card allowed to touch all of them |
| **T46** | S29–S33 webview escape hatch | `Mattermost/UI/Native/EscapeHatch/UnportedSurfaceNoticeView.swift`, `MattermostTests/T46-EscapeHatchTests.swift` — plus the existing `UI/UnportedSurfaceView.swift` |
| **integration** | merging, not features | `Mattermost.xcodeproj/project.pbxproj`, `Mattermost/Core/Native/NativeNavigation.swift`, `Mattermost/UI/Native/NativeShellView.swift`, `Mattermost/UI/RootView.swift`, `Mattermost/UI/Native/SheetHost.swift`, `docs/parity.md` |

---

## 6. Shared files — one owner, no exceptions

These files cross card boundaries. A card that does not own one **does not edit it**; it leaves a
`kanban_comment` on the owning card (or creates a follow-up card assigned to the owner). The
integration card resolves them at merge time.

| File | Owner | Rule |
|---|---|---|
| **`Mattermost/UI/Native/Channel/PostRowView.swift`** | **T34** | **Shared by T34, T37 and T38.** T34 owns the file. T37 renders reactions *under* the row through `ReactionBarView`, and T38 renders files *inside* the body through `FileRowView`; neither edits `PostRowView.swift`. T34 must therefore expose two seams in it — a `footer` slot and a `body` accessory — and T37/T38 pass their views in from `RootView`'s composition (integration card wires the call sites). If a seam is missing, that is an **integration-card** edit to `PostRowView.swift`, made once, after both cards' branches are in. |
| `Mattermost/Core/Native/NativeNavigation.swift` | integration | the navigation route table (deep links, funnel, `NativeLocation`). T31–T46 add *routes* only through it; the edit is serialised by the integration card so two tracks cannot both add a case to the same enum on the same day. |
| `Mattermost/UI/Native/NativeShellView.swift` | integration | the composition root: which pane renders which screen. Every screen card needs one line here; they are applied together, in merge order, by the integration card. |
| `Mattermost/UI/RootView.swift` | integration | the shell chrome, the push destination and the sheet wiring. Same rule. |
| `Mattermost/UI/Native/SheetHost.swift` | integration | the shared sheet host (component map §1). Screen cards *use* `.sheetHost(_:)` with their own `SheetRoute` ids; they do not change the model. |
| `Mattermost.xcodeproj/project.pbxproj` | integration | a screen card never touches it (that is the whole point of T30b). The integration card is the only writer, and gate 10 audits its diff. |
| `docs/parity.md` | integration | every card appends its own row, so the file always conflicts textually even when the changes are harmless. Cards put their row in their card body/handoff; the integration card appends them. |
| `Mattermost/UI/ErrorStateView.swift`, `UI/WelcomeView.swift`, `UI/SettingsView.swift`, `UI/ServerFormView.swift`, `UI/DownloadsView.swift` | existing owners | reuse as-is; adding a parameter is an integration-card change (T30 already had to add `title`/`detail` to `ErrorStateView` — do not repeat that per card). |

**Why the post row is the sharpest case.** It is the one view all three of T34, T37 and T38 must
change for the feature to look right, it is the most-edited file in the whole tree, and every edit is
a merge conflict with a sibling's WIP. Hence the seams: T34 writes it once with slots, T37/T38 supply
their own views, and only the integration card joins them.

**Hotspot protocol.** If a card's branch keeps colliding with a sibling in one file, it must say so —
`kanban_comment` starting `hotspot: <path> — <reason>` — and repeat it in the completion metadata,
instead of resolving the collision by editing the other card's file.

---

## 7. What the gate enforces

`scripts/verify-dual-render-gates.sh` (all of it must pass before a card is handed to review):

| Gate | Claim | Fails when |
|---|---|---|
| 8 | the three native trees are still synchronized folders, registered on their targets, with git-tracked content, and no source file in them has a hand-written project entry | someone reverts a tree to hand-registered files, drops a target registration, adds a file only to disk, or double-registers a file |
| 9 | `project.pbxproj` defines every object id exactly once and no group names an undefined id | the duplicate-id defect of two concurrent editors, or a half-applied edit |
| 10 | this card's diff adds no `PBXFileReference` outside the one allowance (the four non-source resources, and only with `--allow-pbxproj-resource-entry`) | a card registers a `.swift` file by hand instead of dropping it in the synchronized folder |

Run it as `scripts/verify-dual-render-gates.sh` on `main`, and
`scripts/verify-dual-render-gates.sh --base main` inside a card worktree.

---

## 8. Deliberate limits

1. **The synchronized trees are the app's screen source and both test bundles.** If a later card needs
   a new *tree* (a second module, an app extension), that is an integration-card change: add the
   folder, seed it with a tracked file, add the group — and extend gate 8's `SYNC_TREES` in the same
   commit.
2. **The gate's diff check sees `git diff <base>...HEAD` plus the working tree.** A card that never
   commits is not audited by gate 10; the merge is, which is why the integration card runs it too.
3. **Ownership is a convention enforced by review, not by the compiler.** Gates 8–10 enforce the
   *mechanical* half (no hand registration, no duplicate ids). A card editing another card's view
   file compiles fine; the merge-order table and the `-AV` cards are what catch it.
