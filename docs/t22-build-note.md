# T22 — Non-Keychain fallback store for credentials + cert trust on the ad-hoc Mac build

Date: 2026-10-23 · Host: macOS 26.3.1, Xcode 26.6 at `/Applications/Xcode.app`. Work tree:
`/Users/yangsooyoon/Documents/yanks/code/mattermost-ios` (moved from `~/mattermost-ios` during run 2).

## Problem

T20 proved an ad-hoc-signed Mac Catalyst build **cannot use the OS Keychain at all**: every
`SecItem*` call fails with `errSecMissingEntitlement` (-34018) because a Catalyst process always
uses the data-protection keychain, which requires the `application-identifier` entitlement that
only a signing team can issue. Measured on the Catalyst harness: 256 tests / 15 failures
(10 `SecureVaultTests` + 5 `CertTrustTests`), all -34018. `kSecUseDataProtectionKeychain=false`
does not help.

Impact on the prebuilt Mac app: the per-server token vault and the self-signed cert trust bag
cannot persist; `CertPrompt` re-asks every launch; `Settings → Run diagnostics` shows the
Keychain step failing (accurate). Signing with any Apple ID fixes it, but a no-Apple-account path
should exist.

## Design (the choice, in `docs/parity.md` T22 section)

Introduce a `SecretPersisting` protocol — a store addressed by `(service, account)`, exactly the
primary key of a `kSecClassGenericPassword` item — with three backends:

| Backend | File | When it is used |
|---|---|---|
| `KeychainSecretPersisting` | `Mattermost/Core/SecretStore.swift` | The primary; iOS (simulator + device) and any team-signed Mac build. |
| `EncryptedFileSecretPersisting` | `Mattermost/Core/EncryptedFileSecretStore.swift` | Encrypted-file fallback, used ONLY when the Keychain is refused. |
| `FallbackSecretPersisting` | `Mattermost/Core/SecretStore.swift` | The production composite: Keychain first, file only on -34018. |

`SecretStore.makeDefault()` returns the composite, and `SecureVault()` / `CertTrust()` now take an
injectable `secureStore: SecretPersisting?` so tests can force either backend and real callers
stay on the default.

### Encrypted-file store (the fallback)

AES-GCM (CryptoKit) sealed JSON dictionary `service → account → base64 value` under
`~/Library/Application Support/Mattermost/`:

- `vault-secrets.json.enc` — the payload, sealed with AES-256-GCM
- `vault-secrets.key` — the 256-bit key, `0600`, written once then reused

Both written atomically (`Data.write(.atomic)`) owner-read/write-only (0600). **Honest security
note** (documented in the source and parity): without a Keychain there is no hardware-backed key
on this machine, so the key sits in a `0600` file next to the data — malware as the same user
could read both. That is the unavoidable tradeoff of an ad-hoc-signed binary with no entitlement,
and it mirrors Electron `safeStorage`'s Linux fallback (which is plaintext with a warning).
Team-signed builds never touch this store.

### The difficult read path (measured, not guessed)

A plain "try Keychain, catch -34018, fall back" composite **silently fails relaunch persistence
on Catalyst** because the Keychain does not fail symmetrically — verified in the securityd log
during this ticket:

- **Writes** (`SecItemAdd`/`SecItemUpdate`/`SecItemDelete`) fail **-34018** → the composite
  correctly routes to the file.
- **Reads** (`SecItemCopyMatching`) do **NOT** throw -34018; they return `errSecItemNotFound`
  (the keychain looks "successfully empty"). So a naive composite's `get` would read nil forever
  and never reach the value an earlier -34018 write had put in the file.

`FallbackSecretPersisting.get` therefore **reads through**: it asks the Keychain, and when the
Keychain reports "not found" it also consults the fallback file (only latching `fallbackEngaged`
when the fallback actually returns a value). On iOS / a team-signed Mac the fallback is never
written, so this second probe is a no-op read of an absent store. Genuine Keychain failures
still propagate; only `keychainUnavailable` routes to the file.

### iOS unchanged

On iOS the Keychain always works, `keychainUnavailable` never fires, and the fallback file is
never created — verified: iOS suite is 290/290 green (the same 256 baseline the tree shipped with,
plus the 34 new fallback tests), and `testWorkingPrimaryNeverTouchesFallbackFile` explicitly
asserts the fallback directory is untouched while the Keychain works.

## What changed

- `Mattermost/Core/SecretStore.swift` — **new**: `SecretPersisting` protocol,
  `SecretStoreError` (distinguishes `keychainUnavailable` from `keychainFailure`),
  `KeychainPlatform` (moved here from `SecureVault.swift`), `KeychainSecretPersisting` backend,
  `FallbackSecretPersisting` composite, `SecretStore.makeDefault()`.
- `Mattermost/Core/EncryptedFileSecretStore.swift` — **new**: the AES-GCM sealed-file fallback.
- `Mattermost/Core/SecureVault.swift` — refactored to route through `SecretPersisting`
  (`secureStore` injectable); `KeychainPlatform` shim moved out to `SecretStore.swift`;
  `VaultError.storeFailed` wraps backend failures; reads stay non-throwing on the public surface.
- `Mattermost/Core/CertTrust.swift` — same refactor: `secureStore` injectable, `CertTrustError
  .storeFailed`, persistence routed through `SecretPersisting`.
- 4 new test files (34 tests): `FallbackSecretStoreTests`, `EncryptedFileSecretStoreTests`,
  `SecureVaultFallbackTests`, `CertTrustFallbackTests` — including `UnavailableKeychainStub`
  (reproduces -34018) and `OtherKeychainFailureStub` (proves non--34018 failures are NOT silently
  routed to the file).
- `Mattermost.xcodeproj/project.pbxproj` — registered the 6 new files across app + test targets.
- `PushProxy/mmpush_check.py` — path fix for the repo move (already in the stash).

## Verification (all measured on this host)

```sh
# iOS — full unit suite (26.5 simulator)
xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
  -destination "platform=iOS Simulator,id=81A7F251-8B31-4945-8783-5A264C14B8D5" \
  -derivedDataPath build/ddata -only-testing:MattermostTests
# → 290 tests, 0 failures, ** TEST SUCCEEDED ** (docs/t22-full-suite-ios-2026-10-23.log)

# Mac (Catalyst) — full unit suite, ad-hoc signed
xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
  -destination "platform=macOS,variant=Mac Catalyst" \
  -derivedDataPath build/ddata-mac-test -only-testing:MattermostTests
# → 290 tests, 0 failures, ** TEST SUCCEEDED ** (docs/t22-catalyst-unit-2026-10-23.log)
```

Before this ticket the Catalyst suite could only reach 236 green by **skipping**
`SecureVaultTests` + `CertTrustTests` (+ `CertTrustDebugTests`). Now **all** of those pass too:
`SecureVaultTests`, `CertTrustTests`, and the 4 new fallback suites are green on Catalyst with no
skipping — the fallback store transparently persists to the encrypted file, so the previously
-34018-broken credential vault and cert-trust bag work on the prebuilt Mac build. The `-34018`
write failures and the `errSecItemNotFound` read quirk are confirmed in the securityd log entries
captured during the run (see screen/sample notes in the ticket).

## Notes / caveats

- The isolated `CertTrustTests` Catalyst run (`docs/t22-catalyst-certtrust-isolated-2026-10-23.log`)
  is the cleanest proof of the read-through fix: 7/7 pass in ~0.02s after it landed, where the
  pre-fix run failed 7 with `XCTAssertTrue` (writes landed in the file, reads never reached it).
- Two early Catalyst runs stalled (app at 0% CPU, foreground timeout / background hang at the same
  `CertTrustTests` test). The 0%-CPU stalls coincided with the shared Application-Support fallback
  file from a prior partially-killed run; the isolated re-runs after the read-through fix are fast
  and deterministic. The read-through was the substantive fix; each re-run now completes in
  ~2.4s.
- iOS behavior unchanged: `EncryptedFileSecretStoreTests` (temp-dir file store) + all fallback
  suites + the Keychain-backed suites pass on the iOS 26.5 simulator; `testWorkingPrimaryNeverTouches
  FallbackFile` guards the Keychain-primary guarantee.

## Deliverables

- Working fallback store wired through `SecureVault` + `CertTrust` (`SecretStore.swift`,
  `EncryptedFileSecretStore.swift`), unit-tested on both iOS and Catalyst.
- Suite logs: `docs/t22-full-suite-ios-2026-10-23.log`,
  `docs/t22-catalyst-unit-2026-10-23.log`,
  `docs/t22-catalyst-certtrust-isolated-2026-10-23.log`.
- This note · `docs/parity.md` T22 section · README "Known limitation" update.