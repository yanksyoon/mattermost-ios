# T10 — SwiftUI Welcome/onboarding + server add/edit/remove screens (Phase 3)

Build note for kanban task `t_afa68821`. Design doc §§4d (`WelcomeScreen`/`Carousel` → SwiftUI
pager; `NewServerModal`/`ConfigureServer`/`RemoveServerModal` → native form/sheet/dialog) and
§5 items 18–19. Verified on macOS/Xcode via `xcodebuild` (iPhone 16 Pro / iOS 18.5 simulator).

## What was built

### Welcome/onboarding (the main new deliverable)
- `UI/WelcomeView.swift` — native port of the desktop renderer's onboarding cluster:
  - `WelcomeSlide` (title/subtitle/glyph) — counterpart of the desktop `WelcomeScreen` slide
    literals and `WelcomeScreenSlide`. The desktop uses raster illustrations (`ThreadsEmptyImage`,
    `CollaborateImage`, `CallsImage`, `ToolsImage`); iOS substitutes an SF Symbol glyph over a
    per-slide tint since those PNG assets aren't in the app bundle. Copy is identical to desktop.
  - `WelcomePagerModel` (`@MainActor ObservableObject`) — pure pager state machine porting
    `Carousel.tsx`'s index/`autoChange` logic: wrap-at-both-ends `goNext/goPrev/jump`, a 5 s
    auto-advance tick (`advanceAuto()`, mirrors `AUTO_CHANGE_TIME = 5000`), and manual
    navigation flips `autoAdvances` off (mirrors desktop `setAutoChange(false)`).
  - `WelcomeView` — `TabView(.page)` pager with hidden index + dot indicators (`WelcomePageDots`),
    prev/next chevrons (`CarouselButton`), and a "Get started" button. Auto-advance is a
    cancellation-aware `.task` loop (swapped in because `Timer.publish().autoconnect()` did not
    fire on the simulator — verified empirically). Accessibility identifiers: `getStartedWelcomeScreen`,
    `prev/nextCarouselButton`, `PaginationIndicatorN`, `welcomeView`.
- `UI/RootView.swift` —
  - first-run gate `onboardingOrEmptyState`: genuine first launch (`!hasEverConfiguredServers`)
    shows `WelcomeView`; once the user has ever configured a server, the plain empty state shows.
    "Get started" hands off to the add-server form.
  - toolbar swithcher/add chrome hidden while there are no servers (nothing to switch).
  - added a per-server **Edit `name`…** switcher row (opens `ServerFormView` in edit mode) so the
    edit path is reachable, alongside the existing Remove confirmation.

### Add / edit / remove server (already present from T3; refined)
- `ServerFormView` serves both `NewServerModal` (add) and `ConfigureServer`/`editServer` (edit) —
  driven by `ServerFormModel` + `ServerURLValidator` (T5). Remove stays a `.confirmationDialog`
  (port of `RemoveServerModal`): "Remove" clears the server's signed-in session.
- Edit reloads the webview only when the URL actually changed (name-only edits preserve the
  running session) — mirrors desktop `configureServer` re-launching with the new URL.
- Behavior decision: removed the first-run auto-seed of `community.mattermost.com` from
  `RootView.startUp()`. Desktop does not auto-add a server; the Welcome pager is the true entry
  point and auto-seeding immediately dismissed it. Users add their first server via Get started.

## Verification (real output)
- `xcodebuild build` → **BUILD SUCCEEDED**.
- `xcodebuild test` → **TEST SUCCEEDED**, `Executed 103 tests, 0 failures` (12 new
  `WelcomePagerModelTests`: initial index, next/prev, wrap both ends, manual↔auto-advance
  interplay, single-page no-wrap, `disableNavigation`, desktop slide copy).
- Simulator clean-install launch: OCR of the first frame reads "Welcome / Mattermost is a
  sovereign collaboration platform… / Get started" (the onboarding pager). Same-run screenshots
  9 s later read "Start secure calls instantly …", confirming the 5 s auto-advance works
  (`build/shots/t10-01-welcome.png`, `t10-t12.png`).
- Full suite count is 103 because sibling T6 (SecureVault) landed its 12 tests concurrently.

## Files written this run
- Mattermost/UI/WelcomeView.swift (new)
- Mattermost/UI/RootView.swift (onboarding gate + hidden empty toolbar + per-server Edit)
- Mattermost/UI/ServerFormView.swift (edit reloads webview on URL change)
- MattermostTests/WelcomeViewTests.swift (new; 12 `WelcomePagerModelTests`)
- Mattermost.xcodeproj/project.pbxproj (registered WelcomeView + WelcomeViewTests; deterministic
  IDs F2…20/F2…21 + F3…16/F4…0A; plutil-validated)
- docs/parity.md, docs/t10-build-note.md (this file)

## Collision-hotspot flag (PROTOCOL)
`Mattermost.xcodeproj/project.pbxproj` remains the shared-writer hotspot: T6 (SecureVault,
pid 84162) and T10 (this run) concurrently hand-edited it (T6 registered SecureVault +
SecureVaultTests while T10 registered WelcomeView + WelcomeViewTests). Both re-read fresh state
before editing; the file is plutil-valid with no duplicate object definitions and builds cleanly,
but the orchestrator should still decompose `project.pbxproj` or serialize UI-file registration
before the next phase-3 cards (T11+) land more SwiftUI files.