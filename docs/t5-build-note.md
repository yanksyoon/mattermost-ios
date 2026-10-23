# T5 — Server-info fetch & validation for the add-server form (Phase 1)

Build note for kanban task `t_093dabb4`. Design doc §4c (`serverInfo`/`serverAPI` → URLSession +
Codable) and §5 item 10 ("Server info fetch (`/api/v4/system/ping`, name probe) for the add-server
form"). Verified on macOS/Xcode via `xcodebuild` (iPhone 16 Pro Max / iOS 18.5 simulator).

## What was built

Native ports of the desktop add-server validation path, used by the add/edit-server form to
validate a URL against the server **before** saving:

- `Core/ServerAPI.swift` — native counterpart of `src/main/server/serverAPI.ts` (`getServerAPI`).
  Thin `URLSession` GET shim; keeps HTTP status + derives the desktop `errorReason` hints
  (401+`WWW-Authenticate: Basic` → needsBasicAuth, 403+`X-Reject-Reason: pre-auth` → needsPreAuth,
  TLS client-cert transport error → needsClientCert). Header lookup is case-insensitive.
- `Core/ServerInfo.swift` — counterpart of `src/main/server/serverInfo.ts`. `pingServer()` →
  GET `/api/v4/system/ping`; `fetchConfigData()` → GET `/api/v4/config/client?format=old` decoded
  as `ClientConfig`/`RemoteInfo` (`Version`, `SiteURL`, `SiteName`, …). Maps transport/status
  failures onto `ServerProbeError` (badStatus / notMattermost / preAuth / basicAuth / clientCert).
- `Core/ServerURLValidator.swift` — direct port of `ServerHub.handleServerURLValidation` +
  `testRemoteServer` (`src/app/serverHub.ts`): normalize-to-https, duplicate check, probe secure
  URL then http fallback, map auth/tls signals, name-probe decode → `serverName` (falling back to
  the host label when SiteName == "Mattermost"), SiteURL reconciliation (URL_NOT_MATCHED /
  URL_UPDATED), path-pruning retry for NOT_MATTERMOST, insecure http-only flag, MagicLink. Ships
  the `URLValidationStatus` enum + `URLValidationResult` (12 states, raw values match desktop
  `URLValidationStatus`). Includes the ported `parseURL` (slash-collapse, NUL/`%00`/length guards).
- `Core/ServerStore.swift` — added `lookupServer(by:ignoringScheme:)`, port of desktop
  `ServerManager.lookupServerByURL` (host + path-prefix, optional scheme ignore), used by the validator.
- `Core/ServerFormModel.swift` — `@MainActor ObservableObject` counterpart of desktop
  `ServerHub` validation state + `NewServerModal` validation UI state: 1s-debounced URL validation,
  exposes `URLValidationResult` + `urlMessage(tone:text)` per status, auto-fills the display name from
  the probed site name, and gates `canSave`.
- `UI/ServerFormView.swift` — rewired to drive the form off `ServerFormModel`: Save disabled until
  validated; name auto-filled from the probe; inline status message; belt-and-suspenders duplicate
  guard; URL saved uses the validated/normalized URL.
- `MattermostTests/ServerInfoTests.swift`, `MattermostTests/ServerURLValidatorTests.swift` —
  23 tests over a stubbed `URLProtocol` mock session (fully offline).

## Verification (real output)

- `xcodebuild build` → **BUILD SUCCEEDED**.
- `xcodebuild test` → **TEST SUCCEEDED**, `Executed 79 tests, with 0 failures` (the 23 new
  ServerAPI/ServerInfo/Validator/ServerFormModel tests + the 24 from T3 + T4's bridge/deep-link tests).
- New tests cover: ping 200/non-200; config name-probe decode; notMattermost on junk body; pre-auth
  (403) / basic-auth (401) / client-cert detection at the API layer; validator OK with name probe,
  generic-name→host-label fallback, URL_EXISTS duplicate (+ edit-mode exemption), MISSING/INVALID,
  NOT_MATTERMOST, HTTPS→HTTP insecure fallback, PREAUTH/BASTICAUTH required, URL_NOT_MATCHED and
  URL_UPDATED, magicLink path check; ported `parseURL` edge cases; `ServerStore.lookupServer` host/
  scheme/path semantics; `ServerFormModel` auto-fill + canSave gating + messages.

## Files written this run

- Mattermost/Core/ServerAPI.swift (new)
- Mattermost/Core/ServerInfo.swift (new)
- Mattermost/Core/ServerURLValidator.swift (new)
- Mattermost/Core/ServerFormModel.swift (new)
- Mattermost/Core/ServerStore.swift (added `lookupServer(by:ignoringScheme:)`)
- Mattermost/UI/ServerFormView.swift (rewired onto ServerFormModel)
- MattermostTests/ServerInfoTests.swift (new)
- MattermostTests/ServerURLValidatorTests.swift (new)
- Mattermost.xcodeproj/project.pbxproj (registered the 4 core + 2 test files)
- docs/parity.md, docs/t5-build-note.md (this file)

## Collision-hotspot flag (PROTOCOL)

`Mattermost.xcodeproj/project.pbxproj` — this repo (`/Users/yangsooyoon/mattermost-ios`) was edited
**concurrently** by sibling task `t_4e9ddee0` (T4 Bridge + DeepLinkRouter, worker pid 77650) while
T5 ran (pid 77646). Both workers hand-edit the single shared project file; the pbxproj was rewritten
out from under each other during this run and at one point contained duplicate object IDs. I
re-registered my files into the current state and verified a clean build + 79/79 tests, but the
concurrent-writer hazard on this file remains: the orchestrator should decompose `project.pbxproj`
(serialize T4/T5 or give each a worktree) before further work lands on it.