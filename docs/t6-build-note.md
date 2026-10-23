# T6 — SecureVault: per-server credentials in Keychain (Phase 2)

Build note for kanban task `t_92d4a09b`. Design doc §4c (`secureStorage`/safeStorage →
Keychain, `kSecClassGenericPassword`, service per server) and §5 item 12. Verified on
macOS/Xcode 26.6 via `xcodebuild` on the booted iPhone 16 Pro / iOS 18.5 simulator
(`id=BC680916-3B8A-4B9F-9417-88DC86CAC79A`).

## What was built

### `Mattermost/Core/SecureVault.swift` (new) — parity desktop `src/main/secureStorage.ts`
The native replacement for Electron `safeStorage`'s encrypted secrets file. On iOS the OS
Keychain is the durable, hardware-backed encrypted store, so `SecureVault` maps the desktop's
`setSecret/getSecret/hasSecret/deleteSecret` surface onto one `kSecClassGenericPassword` item
per `(server, key)`:

- **Service per server**: `kSecAttrService` = `"<bundle-id>.vault.<canonicalURL>"`, where
  `canonicalServerURL` mirrors desktop `SecureStorage.normalizeUrl` (parseURL → origin +
  formatted path): collapses default ports (`:443`/`:80`) and the bare-root trailing slash,
  keeps non-default ports and sub-path instances distinct (`…/mattermost-dev` vs
  `…/mattermost-prod`), exactly how desktop keys its secrets file.
- **Account = credential name**: `Key` enum — `authToken` (the task's headline item, the
  persistent Mattermost session token), `userID`, `preauth` (desktop `SECURE_STORAGE_KEYS`).
- **Survives relaunch**: values live as on-disk Keychain items; a fresh vault instance (or a
  relaunched app) re-derives the same item from the same namespace.
- **Readable only via the vault**: value is stored only as a Keychain `Data` payload — never in
  `UserDefaults`, plists or a plaintext file — and only `getSecret(key:serverURL:)` (plus
  `hasSecret`) exposes it in-process. `Key` names and the canonical URL are logged, never the
  secret value. `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` keeps the token off backups.
- **Security boundary**: `SecureVault` is shell-only (`Core`). It is **not** reachable through
  `Bridge`/`window.desktop`, mirroring how the desktop preload never ships raw `safeStorage` to
  arbitrary page JS.
- **Empty-value semantics**: `setSecret("", …)` deletes the key (desktop parity). `have/has`
  uses `SecItemCopyMatching`; add-with-existing falls back to `SecItemUpdate` (idempotent).
- `deleteAllSecrets(for:)` sweeps every `Key` (+ legacy `token` alias) for server removal.

### `MattermostTests/SecureVaultTests.swift` (new) — 12 tests
Each test forges a unique `serviceNamespace` so items are isolated from stored user data and
from other tests. Coverage:
- round-trip + the **token never escapes into UserDefaults** assertion (the "readable only via
  the vault" deliverable);
- **relaunch persistence**: value written by one vault instance is read back by a *fresh*
  instance in the same namespace (Keychain item is on-disk, not held in memory), then deleted;
- per-server isolation (no cross-leak between two servers);
- sub-path instances distinct on one domain (desktop parity);
- empty-value-deletes / delete / delete-not-present-no-op / delete-all (per server only);
- separate `account`s within a server don't collide;
- `canonicalServerURL` edge cases (default-port + bare-root collapse, non-default port + sub-path
  preserved).

## Verification (real output)

- `xcodebuild build` → **BUILD SUCCEEDED**.
- `xcodebuild test` → **TEST SUCCEEDED**, `Executed 103 tests, with 0 failures` (12 new
  SecureVault + prior T3/T4/T5 suite). One SecureVault edge-case test failed first
  (`https://a.example:443/` wasn't collapsing its bare root `/`); fixed `canonicalServerURL`,
  re-ran → all green.

## Files written this run

- Mattermost/Core/SecureVault.swift (new)
- MattermostTests/SecureVaultTests.swift (new)
- Mattermost.xcodeproj/project.pbxproj (registered 1 core + 1 test file)
- docs/parity.md (secureStorage row native ✅ T6; Phase 2 status), docs/t6-build-note.md

## Notes / flags

- The Keychain item for a server is indexed by *canonical URL*, not the server's `ServerConfig`
  UUID, so it is stable across config edits that don't change the URL and matches desktop
  keying. If the shell later needs to key by UUID instead, the mapping lives entirely inside
  `SecureVault`'s `service(for:)` — a one-line change.
- Collision hotspot (existing, unchanged this run): `Mattermost.xcodeproj/project.pbxproj` is
  hand-edited by sibling workers; I only appended my two file refs into the current on-disk
  state and verified a clean build + 103/103 tests, but the shared-writer hazard from prior
  build notes remains for the orchestrator to decompose.