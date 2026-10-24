# T29 build note — native local store: SQLite schema, migrations, repository layer

- **Status:** delivered 2026-10-24. Handed to **T29-AV** (adversarial validation).
- **Card:** T29 (native local store — SQLite schema, migrations, repository layer).
- **Program anchor:** `docs/path-b-adr.md` §4 (Path B), `~/.hermes/plans/2026-10-08_mattermost-desktop-ios-migration.md`
  §1 (Path B) and §4 (module map: `Store` sits under `Core`, beside `Core/MM`).
- **Consumers:** every screen card after T30 reads and writes through the repository protocols; no
  screen ever sees SQL, a `Database`, or a table name. Nothing in this card touches the UI, by
  design and by diff (see §9: the only modified tracked files are the Xcode project, the notices
  file and the new sources).
- **Upstream pin for schema shapes and query structure:** `mattermost/mattermost-mobile`
  `v2.45.0` @ `162f2560d0e1df073220f7701d5a67cc17c8abeb` (Apache-2.0). Attribution and the exact
  read set are in `docs/THIRD_PARTY_NOTICES.md` §6.

## 1. What was built (all new)

| File | Lines | What it is |
|---|---|---|
| `Mattermost/Core/Store/MMSchema.swift` | 333 | The DDL (`v1`) and the one additive step this card ships (`v2`), plus `MMMigration` — the ordered, named migration chain and its versions. |
| `Mattermost/Core/Store/MMMigrator.swift` | 91 | Wraps GRDB's `DatabaseMigrator` (which supplies the `grdb_migrations` ledger), mirrors the version into `PRAGMA user_version`, and owns the downgrade guard. |
| `Mattermost/Core/Store/MMStore.swift` | 241 | One SQLite file per server: WAL, busy timeout, the single writer, the read snapshot, `close`, `size()`, `checkpoint()`, `vacuum()`. The only type that owns a connection. |
| `Mattermost/Core/Store/MMStoreModels.swift` | 403 | `MMRetentionPolicy`, `MMSyncCursor`/`MMSyncCursorScope`, `MMChannelUnread`, `MMUnreadTotals`, `MMStoreSize`, `MMStoreError`, and the team/team-member DTOs the schema needs. |
| `Mattermost/Core/Store/MMStoreRecords.swift` | 336 | Row ↔ DTO mapping: `FetchableRecord` conformances for the T28 DTOs (so transport and storage share one model), and `MMRowValues`, a column→value map that builds its own upsert so the SQL and its binds cannot drift. |
| `Mattermost/Core/Store/Repositories/PostRepository.swift` | 287 | `PostRepository` protocol + SQLite implementation: upsert with an `update_at` guard, edit/delete, reactions, files, channel/thread pages, and the eviction routine. |
| `Mattermost/Core/Store/Repositories/ChannelRepository.swift` | 250 | `ChannelRepository`: channel + membership upsert, `markRead`, unread counters, manual unread, channel delete (cascades posts/reactions/files), sidebar queries, and one-query badge totals (no N+1). |
| `Mattermost/Core/Store/Repositories/DraftRepository.swift` | 89 | `DraftRepository`: one draft per `(channel, root)`, list by recency, delete, count. |
| `Mattermost/Core/Store/Repositories/SyncCursorRepository.swift` | 104 | `SyncCursorRepository`: `(scope, scope_key) → cursor`, with the two typed conveniences the card names (last socket event id per server, last post id per channel). |
| `Mattermost/Core/Store/Repositories/PreferenceUserRepositories.swift` | 160 | `PreferenceRepository` + `UserRepository`. |
| `Mattermost/Core/Store/InMemoryStore.swift` | 655 | Dictionary-backed implementations of **all** the same protocols — the test double the card requires. |
| `MattermostTests/T29TestSupport.swift` | 184 | `StoreHarness` (a file store in a temp dir), `MemoryHarness`, deterministic fixtures (`T29Fixtures`), `RepositorySet`. |
| `MattermostTests/RepositoryContractTests.swift` | 493 | The acceptance behaviours asserted against the **protocols**, then run twice: `SQLiteRepositoryContractTests` and `InMemoryRepositoryContractTests`. A disagreement between the two implementations fails the suite. |
| `MattermostTests/MMStoreTests.swift` | 157 | Schema version, table inventory, index inventory (GRAM + `sqlite_master`), WAL, the self-describing `server` row, reopen, downgrade refusal, size reporting. |
| `MattermostTests/MMStoreMigrationTests.swift` | 174 | A real v1 database (built from this build's own v1 step) upgraded to current: every row still there, new columns default correctly, and the new columns accept writes. |
| `MattermostTests/MMStoreConcurrencyTests.swift` | 193 | Writes leave the caller's thread, a main-thread read does not wait for an in-flight write, 100 concurrent writers all land, a throwing write rolls back whole, a second connection to the same file sees committed writes, eviction under concurrent inserts keeps the budget. |
| `MattermostTests/MMStoreSizeTests.swift` | 175 | The measured size note in executable form (§5): a 10k-post fixture, the shipping retention policy, and what eviction does to the file. |
| `MattermostTests/PostRepositoryTests.swift` | 155 | Post-specific edge cases on top of the contract: stale page vs edit, delete drops content, thread ordering, cursor paging boundaries. |
| `MattermostTests/ChannelRepositoryTests.swift` | 105 | Unread/mention math, manual unread, badge totals, channel delete cascade. |
| `MattermostTests/DraftRepositoryTests.swift` | 85 | Per-channel and per-thread draft isolation, overwrite, recency order. |
| `MattermostTests/SyncCursorRepositoryTests.swift` | 75 | Cursor round-trip, per-server/per-channel isolation, clear. |

Modified (not new):

| File | Change |
|---|---|
| `Mattermost.xcodeproj/project.pbxproj` | GRDB product dependency (app **and** test target), the 11 store sources, the 10 test files. |
| `docs/THIRD_PARTY_NOTICES.md` | §6: the T29 upstream read set (Apache-2.0) and the GRDB (MIT) dependency. |
| `Mattermost.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` | New file, committed on purpose: it pins GRDB to `7.11.1` (`b83108d1…`). An unpinned package graph would make an AV run against a different library than the one measured here. |

## 2. Library choice: GRDB 7.11.1 (MIT), and why not something already in the tree

The tree had **no** persistence library to reuse — the Path A shell kept state in
`UserDefaults`/Keychain and the webview owned all message history. So the card's "unless an existing
tested library in the tree already does the job" branch was empty, and the choice was between
Apple's persistence frameworks and a SQLite wrapper.

**Chosen: `GRDB.swift` 7.11.1, MIT, declared as `upToNextMajorVersion` from `7.0.0`.** Licence
verified 2026-10-24 with `gh api repos/groue/GRDB.swift/license --jq '.license.spdx_id'` → `MIT`.
No GRDB source is vendored; it is a SwiftPM package dependency, so the MIT text ships in the normal
SwiftPM way and is listed in the app's Licences screen.

Why it, specifically — each reason is tied to a requirement of this card, not to general taste:

1. **`DatabasePool` + WAL gives the read model the card asks for.** "All writes off the main actor,
   reads on the calling context" needs a reader that does not queue behind the writer. GRDB's
   `DatabasePool` keeps a pool of reader connections over WAL, so a channel page renders from a
   snapshot while a socket batch is being written. `MMStoreConcurrencyTests
   .testAReadOnTheMainThreadDoesNotWaitForAnInFlightWrite` asserts exactly that with a write held
   open on the writer queue.
2. **A migration ledger with names, not integers.** `DatabaseMigrator` records applied steps in
   `grdb_migrations` and is idempotent; the card asks for "a versioned chain" and a test that an
   older schema upgrades. A named ledger is also what makes a support report actionable
   (`migrationFailed(name:)`).
3. **Value types, no managed-object context.** The DTOs are the T28 `MMTypes` structs. Core Data /
   SwiftData would force `NSManagedObject` subclasses (or a second model layer) and drag
   `@MainActor`-ish context rules into a store whose entire point is to stay off the main actor.
4. **Raw SQL is the deliverable.** The card says "port the upstream query shapes". Upstream's
   Gekidou storage is explicit SQL; GRDB lets those statements be ported and reviewed literally,
   which Core Data/SwiftData cannot express and `SQLite.swift` expresses in a DSL that would have to
   be re-derived from upstream SQL.

Rejected, with the reason:

| Option | Why not |
|---|---|
| SwiftData | iOS 17+ is fine, but it is an object graph with no migration ledger and no way to port upstream's SQL; its concurrency model is main-actor biased, against §6 of the card. |
| Core Data | Same object-graph objection plus a binary store this repo could not inspect with `sqlite3`, and no stable way to assert "index X exists". |
| `SQLite.swift` | Typed DSL means every upstream statement is rewritten rather than ported; last release cadence is slower than GRDB's and its `DatabasePool`-equivalent (WAL reader pooling) is not the same thing. |
| `FMDB` | Objective-C, no async, no migration harness. |
| `randomsnowflake/MattermostSwift` | Already evaluated and rejected in T28 (`docs/t28-build-note.md` §2): needs iOS 18/macOS 15 + Swift 6 (this app targets iOS 17/macOS 13) and ships a competing cache. |

Cost of the dependency, stated plainly: a third-party package in the app, one C-adjacent SQLite
dependency to keep pinned (`Package.resolved` is committed), and an AV surface of its own. The
alternative — hand-rolling WAL reader pooling and a migration ledger — is more code than this card
had budget for and would have been untested by anyone but us.

## 3. Schema

### 3.1 Tables (v1)

`server`, `team`, `team_member`, `channel`, `channel_member`, `user`, `post`, `post_reaction`,
`file_info`, `draft`, `sync_cursor`, `preference` — the twelve the card lists plus `team_member`,
which the sidebar needs and upstream also carries.

### 3.2 Indices, and the query each one exists for

No speculative indices: each one below is reached by a statement in `Repositories/`.

| Index | Query it serves |
|---|---|
| `idx_post_channel_window(channel_id, create_at DESC, id DESC)` | `PostRepository.posts(inChannel:before:limit:)` — the channel page |
| `idx_post_root_window(root_id, create_at DESC)` | `posts(inThread:limit:)` |
| `idx_post_user(user_id, create_at DESC)` | a user's posts; `user_updated` reconciliation |
| `idx_channel_team(team_id)` | `ChannelRepository.channels(teamID:)` |
| `idx_channel_name(name)` | channel switcher prefix search |
| `idx_channel_last_post(last_post_at DESC)` | "recent channels" ordering |
| `idx_channel_member_recent(user_id, last_viewed_at DESC)` | `recentChannels(userID:limit:)` |
| `idx_channel_member_unread(user_id, is_unread)` | `unreadByChannel(userID:)` (the badge, no N+1) |
| `idx_reaction_post(post_id, emoji_name)` | `reactions(postID:)`; the eviction cascade |
| `idx_reaction_user(user_id)` | "my reactions" (screen card T40+) |
| `idx_file_post(post_id)` | `files(postID:)`; the eviction cascade |
| `idx_user_username(username)` | @-autocomplete prefix search |
| `idx_draft_update_at(update_at DESC)` | `drafts(limit:)` |
| `idx_preference_lookup(user_id, category)` | `preferences(userID:category:)` |
| `idx_server_url(url)` (unique) | one file per server; a duplicate URL is a bug, not a duplicate row |

### 3.3 Migration chain (deviation from "v1 only", on purpose)

`v1_initial_schema` → `v2_post_metadata_and_unread`.

v2 is **purely additive** and exists because the card requires *"a migration test proves an older
schema upgrades without data loss"* — a chain with one step cannot test an upgrade. The step is not
invented: upstream added `post.metadata` with custom post attributes (`table_schemas/post.ts`) and
`MyChannel` gained `manually_unread` / `urgent_mention_count` after its first release, which is why
`Database+Channels.swift` ships a runtime probe literally named
`hasMyChannelUrgentMentionCountColumn(_:)`. v2 adds exactly those three columns, with defaults, no
row rewrite: the kind of change a real client actually ships.

`PRAGMA user_version` mirrors the chain so an external `sqlite3` session can tell what it is looking
at, and `MMMigrator.guardAgainstDowngrade` refuses a file written by a newer build rather than
reading columns it does not know.

### 3.4 Divergences from upstream (all deliberate)

1. **WatermelonDB bookkeeping columns dropped** (`_status`, `_changed`, `_deleted`): one native
   writer, not an ORM with a sync protocol.
2. **Upstream's `MyChannel` merged into `channel_member`**: the unread state *is* the membership
   row; two tables would be a join on every sidebar render.
3. **Upstream's `System` key/value table replaced by `sync_cursor`**: a cursor is a single
   `(scope, scope_key) → value` fact; one explicit table can be asked "what did I already apply?"
   without scanning post windows.
4. **Timestamps are INTEGER milliseconds**; upstream stores Double milliseconds.
5. **A column exists only if something writes it.** Upstream columns this client cannot fill yet
   (presence, roles beyond membership, custom status, optimistic-send ids) are added by a later
   step when their owning card lands, instead of sitting at a default that lies. The alternative —
   copying upstream's 60-column tables — would mean tests asserting NULLs nobody wrote.

## 4. Retention / eviction policy, and "how much disk does a busy server cost"

`MMRetentionPolicy` is the whole policy, one value, immutable for a store's lifetime:

- `maxPostsPerChannel` — **default 200** (`nil` = unbounded, for tests and an explicit opt-out).
- `evictionSlack` — **default 50**: a channel is left alone until it is 250 posts deep, so a busy
  channel does not run the eviction scan on every socket event.
- `evictOnWrite` — **default true**: a post write that pushes a channel past the threshold trims it
  back to 200 in the same transaction. `false` means only an explicit `evict(...)` call trims, which
  is what a screen-driven "free up space" action uses.

Why posts are the only capped table: channels, users, teams and preferences are bounded by the
server's own inventory; drafts are bounded by the number of channels; reactions and files are
bounded by the posts they hang off. Posts are the one table with no natural cap, so the window is
the budget, and eviction deletes the reactions and file rows of evicted posts in the same
transaction (no orphans).

**The disk answer, from §5's measurements rather than from arithmetic:**

- Marginal cost of a stored post (row + its index entries, ~140-byte message): **≈ 456 bytes**.
- With the shipping 200-post window: 5 channels held **1.52 MB**, i.e. **≈ 0.30 MB per channel**
  (which includes the freelist high-water mark, not just live rows).
- Therefore a **100-channel server with the shipping policy ≈ 30 MB**, and it **stops growing**: the
  file reaches its high-water mark (window + slack per channel) and then recycles freed pages —
  §5.3 measures 1,030 pages returned to the freelist and reused.
- The same server with retention turned off: 5 channels of 2,000 posts each measured 4.56 MB
  (≈ 0.91 MB per channel of history), so 100 channels ≈ 91 MB **and growing without limit**. That
  comparison is what makes the window worth having, and `testRetentionPolicyBoundsDiskForABusyServer`
  asserts the bounded file is less than half the unbounded one.

`VACUUM` exists for an explicit "clear space" action only. Eviction does not shrink the file (by
design — shrinking rewrites the database), and §5.3 asserts that honestly rather than pretending
the file got smaller.

## 5. The measurement (`MMStoreSizeTests`, seeded ~10k posts)

Fixture: 5 channels × 2,000 posts = 10,000 posts, 20 users, 1,000 reactions (10 % of posts carry
two), 500 files (5 % of posts), deterministic message bodies (~140 bytes, seeded LCG — no `UUID()`,
no compressible randomness). Seeds through the repositories, i.e. through the production write path.
Verbatim from `docs/t29-store-suite-2026-10-24.log`:

```
T29-SIZE fixture=unbounded posts=10000 channels=5 file_bytes=4558848 used_bytes=4526080 mb=4.35 bytes_per_post=456 page_query_ms=1.04 seed_s=1.18
T29-SIZE retention unbounded_bytes=4558848 bounded_bytes=1589248 mb=1.52 posts_kept_per_channel=200 max=200
T29-SIZE eviction before_bytes=4558848 after_bytes=4558848 before_free_pages=0 after_free_pages=1030 posts_kept=50
```

Reading them:

1. **Unbounded**: 4.35 MB on disk for 10,000 posts (4,526,080 bytes of *used* pages, the rest is
   the header/freelist), **456 bytes per post**, a 50-post channel page at **1.04 ms**, and the
   whole 10k seed written in **1.18 s** (8,500 posts/s through a single transaction per batch).
2. **Shipping policy**: the same seed with `maxPostsPerChannel = 200` settles at **1.52 MB** with
   exactly 200 posts kept per channel — 3.5× smaller, and flat with respect to history.
3. **Eviction**: trimming 2,000 → 50 posts per channel leaves the file **the same size** (4.56 MB)
   and moves **1,030 pages (≈ 4.0 MB) to the freelist**, ready to be reused by new posts. This is
   the documented SQLite behaviour and the reason §4 quotes the window, not a post-eviction file
   size, as the budget.

Assertions around the numbers are deliberately loose (bytes-per-post between 100 and 2,000; page
query < 25 ms) so a SQLite page-layout change does not fail the suite, while a 10× regression does.

## 6. Thread safety: how §6 of the card is enforced, not just intended

`MMStore` exposes exactly three access paths, and there is no fourth:

- `write(_:) async` → GRDB's writer queue (a private dispatch queue). **There is no synchronous
  write API on `MMStore`**, so a screen cannot run a write on the main actor even by accident. This
  is enforced by the type, not by a code review rule.
- `read(_:) throws` → the calling context, against a WAL snapshot (never waits for the writer).
- `readAsync(_:) async` → for call sites that should not block their thread either.

No `@MainActor`, no `DispatchQueue.main`, no `Task.detached` in the store, and no repository holds
state that would need isolation (they are `final class` wrappers over the store, all `Sendable` by
argument). `MMStore` itself is `@unchecked Sendable` with an `NSLock` around the one mutable field
(`closed`) — the `@unchecked` is the price of holding a `DatabaseWriter`, and it is the only such
annotation in the store.

Proof, from `MMStoreConcurrencyTests` (6 tests, all green):

- `testWritesRunOffTheMainThread` — a write records `Thread.isMainThread` inside the block: false.
- `testAReadOnTheMainThreadDoesNotWaitForAnInFlightWrite` — with a write held open on the writer
  queue, a main-thread read returns immediately and sees the pre-write snapshot.
- `testManyConcurrentWritersAllLand` — 100 concurrent upserts through `TaskGroup`, all present.
- `testAThrowingWriteIsRolledBackWhole` — a write that throws mid-batch leaves zero rows.
- `testASecondConnectionToTheSameFileSeesCommittedWrites` — the "future notification extension"
  case; the 5 s busy timeout means it waits instead of failing.
- `testEvictionDuringConcurrentInsertsKeepsTheBudget` — concurrent inserts plus eviction never
  leaves a channel over its window.

## 7. Acceptance criteria → evidence

| Criterion | Where it is asserted | Result |
|---|---|---|
| Insert/update post (edit + delete) | `RepositoryContractTests` (both backends) `testPostInsertAndReadBack`, `testPostEdit`, `testStalePayloadDoesNotUndoAnEdit`, `testPostDelete`; `PostRepositoryTests` | pass |
| Channel unread counts | `RepositoryContractTests.testUnreadCounts`, `testMarkRead`, `testManualUnread`; `ChannelRepositoryTests` (totals, per-channel, no N+1) | pass |
| Draft persistence per channel | `RepositoryContractTests.testDrafts`; `DraftRepositoryTests` (channel vs thread isolation, overwrite, recency) | pass |
| Cursor round-trip | `RepositoryContractTests.testCursors`; `SyncCursorRepositoryTests` (per-server / per-channel isolation, clear) | pass |
| Eviction keeping the newest N | `RepositoryContractTests.testEviction`; `MMStoreSizeTests.testRetentionPolicyBoundsDiskForABusyServer`, `testEvictionReclaimsSpaceAfterTrim` | pass |
| Migration test proves an older schema upgrades without data loss | `MMStoreMigrationTests.testV1FixtureUpgradesToCurrentWithoutDataLoss` (real v1 database, every row and value re-read), `testUpgradedSchemaAcceptsWritesToTheNewColumns`, `testMigrationIsIdempotentAcrossReopens` | pass |
| A measured note on DB size for a seeded ~10k-post fixture | This note §5 + `MMStoreSizeTests.testTenThousandPostFixtureSizeAndLatency` (prints the numbers and asserts their bounds) | pass |
| Nothing in this card touches the UI | `git status`: the only tracked modifications are `Mattermost.xcodeproj/project.pbxproj`, `docs/THIRD_PARTY_NOTICES.md` and the new `Core/Store` + `MattermostTests` files. No file under `Mattermost/UI` — no view, view model or SwiftUI file anywhere — is in the diff. | pass |

## 8. Defects found and fixed during implementation

Both were found by the suite failing, not by inspection, and both are recorded here because T29-AV
should re-derive them rather than trust this note.

### 8.1 `checkpoint()` threw `SQLite error 6: database table is locked`

`MMStore.checkpoint()` originally ran `db.checkpoint(.truncate)` inside `writer.read { }`. GRDB wraps
a `read` block in a transaction, and `sqlite3_wal_checkpoint_v2` answers `SQLITE_LOCKED` when called
inside one — so every size test and every "free up space" action would have thrown. Fix: run the
checkpoint under `writeWithoutTransaction` (the writer connection, no transaction open), skip
databases that are not in WAL mode (the in-memory store), and degrade `TRUNCATE` to `PASSIVE` when a
reader holds a snapshot instead of failing the caller. Evidence: the four size/store tests that
failed with error 6 before the fix pass after it (`docs/t29-store-suite-2026-10-24.log`).

### 8.2 The first read after an upgrade could see the pre-migration schema

`MMStore.init` ran `MMMigrator.guardAgainstDowngrade(writer)` — and that takes a `DatabaseReader`, so
a `DatabasePool` opened a **reader connection before the DDL existed**. SQLite's schema cache is
per connection, and the connection is only told the schema cookie moved when it prepares its next
statement; the first read after an upgrade therefore ran against the old schema. Two failures
with the same signature and one cause:

- `MMStoreMigrationTests.testUpgradedSchemaAcceptsWritesToTheNewColumns` — a post written with
  `metadata` read back as `nil` from a v1→v2 upgraded file.
- `MMStoreTests.testIndicesTheQueriesNeedExist` — `db.indexes(on: "channel")` returned `[]` for the
  alphabetically first table on a brand-new file, while `sqlite_master` in the very next statement
  listed all three indices (and every later table in the same loop was fine).

The probe that isolated it (`MMStoreTests.testT29DiagnosticProbe`, run and then deleted — see the
transcript in `docs/t29-probe-2026-10-24.log`) showed on a **fresh** store that the write path stored
`metadata` as TEXT (`typeof=text quote='{"priority":{"priority":"urgent"}}'`) and read it back
intact, and that `db.indexes(on: "channel", in: "main")` returned all four indices once any plain
query had already run on that connection. So neither the SQL nor the schema was wrong; the
connection was. Fix: the guard now runs on the writer connection
(`MMMigrator.guardAgainstDowngrade(in: db)` inside `writeWithoutTransaction`), so no reader exists
until the schema is current. This is a **production** bug, not a test artifact: on a fresh install
the very first repository read could have missed a newly added column.

## 9. Verification (commands and the runner's own verdict)

Run through `scripts/qa-test.py` (T14b's guarded runner: derived data outside the TCC-protected
folders, stall detection, exit 124 on a wedge), not raw `xcodebuild`. Simulator is `iPhone 16 Pro`
iOS 18.3.1 by explicit id (`81A7F251-8B31-4945-8783-5A264C14B8D5`) — the host also has a 26.5
runtime with no `iPhone 16 Pro` in it, so the runner's default `name=` spec cannot resolve; that is
a host fact, recorded here so the next card does not re-hit it.

T29 suites only (52 tests):

```
scripts/qa-test.py --label t29-store2 --sim id=81A7F251-8B31-4945-8783-5A264C14B8D5 \
  --only-testing MattermostTests/MMStoreTests \
  --only-testing MattermostTests/MMStoreMigrationTests \
  --only-testing MattermostTests/MMStoreConcurrencyTests \
  --only-testing MattermostTests/MMStoreSizeTests \
  --only-testing MattermostTests/PostRepositoryTests \
  --only-testing MattermostTests/ChannelRepositoryTests \
  --only-testing MattermostTests/DraftRepositoryTests \
  --only-testing MattermostTests/SyncCursorRepositoryTests
→ Executed 52 tests, with 0 failures (0 unexpected)   ** TEST SUCCEEDED **
  (MMStore 11, Post 10, Channel 7, Draft 7, Concurrency 6, SyncCursor 5, Size 3, Migration 3)
```

Full scheme, Mac Catalyst:

```
scripts/qa-test.py --label t29-full-catalyst --platform mac
→ Executed 539 tests, with 4 tests skipped and 0 failures   ** TEST SUCCEEDED **
```

Full scheme, iOS Simulator:

```
scripts/qa-test.py --label t29-full-ios --sim id=81A7F251-8B31-4945-8783-5A264C14B8D5
→ MattermostTests: Executed 539 tests, with 3 tests skipped and 0 failures
→ MattermostUITests: Executed 13 tests, with 1 test skipped and 0 failures  (302 s)
→ ** TEST SUCCEEDED **
```

(The Catalyst invocation passes `-only-testing:MattermostTests` — that is what `scripts/qa-test.py
--platform mac` does — so the 13 UI tests run on the simulator only. They are untouched by this
card and were run to prove that: the app still launches, the shell still navigates.)

The skips are pre-existing and named in the log, none of them T29's:
`CertTrustTests.testKeychainSetOverwritesAnExistingItem` (ad-hoc Catalyst host has no keychain
entitlement, −34018), `MentionPollerTests.testLiveMentionsFetch_optIn` (opt-in live server),
`SelfSignedTrustTests` × 2 (gated on `scripts/t28-selfsigned-check.sh`'s fixture). The Catalyst run
skips one more than the simulator because of the keychain entitlement.

T29 contributes 52 of the 539; the remaining 487 are the pre-existing suites, which still pass —
i.e. this card added one framework dependency and did not disturb the transport, webview or shell.

## 10. Limitations (stated, not hidden)

1. **Nothing is wired into the UI yet.** No screen reads the store; this card is the layer, per its
   own scope. The repository protocols are the seam cards T30+ sit on.
2. **The database is not encrypted at rest.** Message bodies are plaintext in the app container,
   exactly like upstream's SQLite. Tokens are *not* here (they stay in the existing `SecureVault`),
   but a post's text is. SQLCipher is a real option and a real decision; it is not in this card, and
   pretending otherwise would be worse than saying it. If a later card wants it, `MMStore.open` is
   the one place it has to change.
3. **`preference.value` and `post.props` are JSON text, not queryable.** Deliberate: nothing in this
   client filters on them yet, and SQLite's JSON1 could be used later without a schema change.
4. **Eviction is per channel, not per team or global.** A server with 5,000 channels at 200 posts
   each is §4's arithmetic (~1.5 GB); a global budget would need a policy decision nobody has made
   yet, so the observable here is the per-channel window.
5. **No full-text search index.** Upstream has none in its SQLite either (search is a server API);
   adding FTS5 locally would be a search-feature card.
6. **One writer process assumed.** A second process (a notification extension) waits on the 5 s busy
   timeout rather than being coordinated; nothing in this card creates a second writer.
7. **`MMStore` is `@unchecked Sendable`.** The `NSLock`-guarded `closed` flag and the GRDB writer are
   the reason; it is the only such annotation in the store and it is worth an AV question.
