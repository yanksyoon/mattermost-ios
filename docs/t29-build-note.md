# T29 build note — native local store: SQLite schema, migrations, repository layer

- **Status:** delivered 2026-10-24 (T29, `da6dec5`); repaired 2026-10-24 after adversarial validation
  (**T29-AV**, `t_b6f2124d`, nine findings F1–F9) by **T29-R** (`t_85a21546`). Every finding is closed
  by reference in §11; the sections it changed are marked *(revised T29-R)*. Re-validated by T29-AV's
  own probes: `scripts/qa-test.py` runs quoted in §9 are from the repair commit.
- **Card:** T29 (native local store — SQLite schema, migrations, repository layer), repaired under
  T29-R (store repair: thread-safe eviction, typed busy error, `server_api_version`, doc/test-count
  corrections).
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
| `Mattermost/Core/Store/MMSchema.swift` | 378 | The DDL (`v1`), the two additive steps this build ships (`v2`, `v3` — `post.metadata`/unread counters, then `server.server_api_version`), plus `MMMigration` — the ordered, named migration chain and its versions. |
| `Mattermost/Core/Store/MMMigrator.swift` | 91 | Wraps GRDB's `DatabaseMigrator` (which supplies the `grdb_migrations` ledger), mirrors the version into `PRAGMA user_version`, and owns the downgrade guard. |
| `Mattermost/Core/Store/MMStore.swift` | 337 | One SQLite file per server: WAL, busy timeout, the single writer, the read snapshot, `close`, `size()`, `checkpoint()`, `vacuum()`, the `SQLITE_BUSY`→`MMStoreError.storeBusy` mapping, and the `server_api_version` accessors. The only type that owns a connection. |
| `Mattermost/Core/Store/MMStoreModels.swift` | 424 | `MMRetentionPolicy`, `MMSyncCursor`/`MMSyncCursorScope`, `MMChannelUnread`, `MMUnreadTotals`, `MMStoreSize`, `MMCheckpointOutcome`, `MMStoreError` (now including `storeBusy`), and the team/team-member DTOs the schema needs. |
| `Mattermost/Core/Store/MMStoreRecords.swift` | 336 | Row ↔ DTO mapping: `FetchableRecord` conformances for the T28 DTOs (so transport and storage share one model), and `MMRowValues`, a column→value map that builds its own upsert so the SQL and its binds cannot drift. |
| `Mattermost/Core/Store/Repositories/PostRepository.swift` | 346 | `PostRepository` protocol + SQLite implementation: upsert with an `update_at` guard, edit/delete, reactions, files, channel/thread pages, the pinned read, and the eviction routine (window on unpinned posts, replies cascade with their root). |
| `Mattermost/Core/Store/Repositories/ChannelRepository.swift` | 250 | `ChannelRepository`: channel + membership upsert, `markRead`, unread counters, manual unread, channel delete (cascades posts/reactions/files), sidebar queries, and one-query badge totals (no N+1). |
| `Mattermost/Core/Store/Repositories/DraftRepository.swift` | 89 | `DraftRepository`: one draft per `(channel, root)`, list by recency, delete, count. |
| `Mattermost/Core/Store/Repositories/SyncCursorRepository.swift` | 104 | `SyncCursorRepository`: `(scope, scope_key) → cursor`, with the two typed conveniences the card names (last socket event id per server, last post id per channel). |
| `Mattermost/Core/Store/Repositories/PreferenceUserRepositories.swift` | 160 | `PreferenceRepository` + `UserRepository`. |
| `Mattermost/Core/Store/InMemoryStore.swift` | 679 | Dictionary-backed implementations of **all** the same protocols — the test double the card requires, now with the same eviction rules as SQL (pinned posts outside the window, replies cascade with their root) and the same pinned read. |
| `MattermostTests/T29TestSupport.swift` | 186 | `StoreHarness` (a file store in a temp dir), `MemoryHarness`, deterministic fixtures (`T29Fixtures`), `RepositorySet`. |
| `MattermostTests/RepositoryContractTests.swift` | 608 | The acceptance behaviours asserted against the **protocols**, then run twice: `SQLiteRepositoryContractTests` and `InMemoryRepositoryContractTests` (18 tests each). A disagreement between the two implementations fails the suite. |
| `MattermostTests/MMStoreTests.swift` | 303 (13 tests) | Schema version, table inventory, index inventory (17 indices in GRDB *and* `sqlite_master`), WAL, the self-describing `server` row, reopen, downgrade refusal, size reporting, `server_api_version` across a reopen, and both checkpoint branches (`TRUNCATE` and the `PASSIVE` fallback under a live reader). |
| `MattermostTests/MMStoreMigrationTests.swift` | 218 (5 tests) | A real v1 database (built from this build's own v1 step) and a v2 one, each upgraded to current: every row still there, new columns default correctly, the new columns accept writes, and `server_api_version` records/reads back across a reopen. |
| `MattermostTests/MMStoreConcurrencyTests.swift` | 297 (8 tests) | Writes leave the caller's thread, a main-thread read does not wait for an in-flight write, 100 concurrent writers all land, a throwing write rolls back whole, a second connection to the same file sees committed writes, a write *inside* the busy timeout waits and succeeds, a write *past* it throws the typed `storeBusy` error, eviction under concurrent inserts keeps the budget. |
| `MattermostTests/MMStoreSizeTests.swift` | 233 (4 tests) | The measured size note in executable form (§5): a 10k-post fixture, the shipping retention policy, what eviction does to the file, and the 100-channel shipping-shape measurement. |
| `MattermostTests/PostRepositoryTests.swift` | 229 (12 tests) | Post-specific edge cases on top of the contract: retention on write, zero orphan reply rows after eviction (raw SQL), pinned posts surviving write-time eviction, orphan cleanup for reactions/files, query plans. |
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

### 3.2 Indices, and the query each one exists for *(revised T29-R — F7)*

Seventeen indices, in two groups. Group 1 is reached by a statement in `Repositories/` **today**.
Group 2 is reserved: the access path for a query a named later card runs against this same table
shape. T29-AV F7 found this table listing fifteen while the DDL created seventeen (missing
`idx_team_name`, `idx_team_member_user`) and the old sentence "No speculative indices" contradicted by
`idx_reaction_user` ("screen card T40+"). The correction: the two undocumented indices are documented
here, the denial is replaced by the honest split, and `MMStoreTests.testIndicesTheQueriesNeedExist`
now asserts all seventeen by name *and* asserts the total, so note, test and DDL cannot drift again.

**Queried today (14)**

| Index | Query it serves |
|---|---|
| `idx_post_channel_window(channel_id, create_at DESC, id DESC)` | `PostRepository.posts(inChannel:before:limit:)` — the channel page |
| `idx_post_root_window(root_id, create_at DESC)` | `posts(inThread:limit:)`, and the `root_id IN (doomed)` reply cascade in `evict` |
| `idx_post_user(user_id, create_at DESC)` | a user's posts; `user_updated` reconciliation |
| `idx_channel_team(team_id)` | `ChannelRepository.channels(teamID:)` |
| `idx_channel_name(name)` | channel switcher prefix search |
| `idx_channel_last_post(last_post_at DESC)` | "recent channels" ordering |
| `idx_channel_member_recent(user_id, last_viewed_at DESC)` | `recentChannels(userID:limit:)` |
| `idx_channel_member_unread(user_id, is_unread)` | `unreadByChannel(userID:)` (the badge, no N+1) |
| `idx_reaction_post(post_id, emoji_name)` | `reactions(postID:)`; the eviction cascade |
| `idx_file_post(post_id)` | `files(postID:)`; the eviction cascade |
| `idx_user_username(username)` | @-autocomplete prefix search |
| `idx_draft_update_at(update_at DESC)` | `drafts(limit:)` |
| `idx_preference_lookup(user_id, category)` | `preferences(userID:category:)` |
| `idx_server_url(url)` (unique) | one file per server; a duplicate URL is a bug, not a duplicate row |

**Reserved, with the access path each is for (3)**

| Index | The query it is for | Why it ships now |
|---|---|---|
| `idx_team_name(name)` | team-by-name resolution — `GET /api/v4/teams/name/{name}`, a deep link, or a link arriving from another server: "is this team already in the store" | T30's sidebar owns the teams repository; without the index that lookup is a full scan of a table that grows with the server's team count. Dropping and re-adding an index later is a migration; keeping it costs one page. |
| `idx_team_member_user(user_id)` | "the teams this user belongs to" — the team switcher | The PK is `(team_id, user_id)`, so a lookup by `user_id` alone would scan. Same card as above. |
| `idx_reaction_user(user_id)` | "reactions I have made" — the profile/activity surface | T40+. This is the one that made the old "no speculative indices" claim false; it is listed as forward-looking rather than denied. |

### 3.3 Migration chain (deviation from "v1 only", on purpose) *(revised T29-R — F5)*

`v1_initial_schema` → `v2_post_metadata_and_unread` → `v3_server_api_version`.

v2 is **purely additive** and exists because the card requires *"a migration test proves an older
schema upgrades without data loss"* — a chain with one step cannot test an upgrade. The step is not
invented: upstream added `post.metadata` with custom post attributes (`table_schemas/post.ts`) and
`MyChannel` gained `manually_unread` / `urgent_mention_count` after its first release, which is why
`Database+Channels.swift` ships a runtime probe literally named
`hasMyChannelUrgentMentionCountColumn(_:)`. v2 adds exactly those three columns, with defaults, no
row rewrite: the kind of change a real client actually ships.

**v3 — `server.server_api_version` (the ADR §5 requirement, and the choice I made in T29-R).**
`docs/path-b-adr.md` §5 says: *"T29's SQLite layer records the server version it was written against
per model (a `server_api_version` column on the migration table)"*. T29 shipped without it and without
listing the gap (T29-AV F5). T29-R implements it as a third additive step:

```sql
ALTER TABLE server ADD COLUMN server_api_version TEXT NOT NULL DEFAULT ''
```

**Why a column on `server` and not on the migration ledger.** This client keeps **one SQLite file per
server** (`MMStore.open(at:serverID:)` takes exactly one identity), so the `server` row *is* the
per-model scope for the file: every row in it was written by a client talking to that one server. A
column on the ledger table would record "which version was current when each schema step ran", which
is a fact about the client build, not about the server — it could never change after v1 and would be a
constant pretending to be a version.

That is a **deliberate deviation from the ADR's parenthetical** ("a `server_api_version` column on the
migration table"), and it is the one the repair card allowed: *"a column on `server` is the minimum
that satisfies 'per server'; if you prefer the ADR's exact wording, record it on the migration ledger
instead — but pick one"*. The ADR's **purpose** is preserved: a later build can read the version the
data was written against and choose to re-sync rather than mutate rows in place — and unlike a ledger
column, this one can actually change when the server is upgraded, which is the only way that purpose
is ever exercised.

**Its consequence, stated plainly** (this is the cost of the choice):
- The granularity is **per file, not per row**. A post synced before a server upgrade and one synced
  after it are indistinguishable; the file records the *latest* version the client synced against.
- A file upgraded from v1/v2 has the column with `''`, and `MMStore.serverAPIVersion()` answers `nil`
  ("not recorded yet") rather than inventing a version. Nothing writes the column until a sync
  reports one (`recordServerAPIVersion(_:)`, called by the card that owns `/api/v4/config` — T28's
  transport already sees `X-Version`).
- If a later card needs row-level granularity, it adds a column to the table that needs it **on top
  of** this one; the ADR's minimum is met and is not claimed to be more than it is.

Test evidence: `MMStoreTests.testServerAPIVersionSurvivesAReopen` (record → reopen → read, and an
upgrade of the value), `MMStoreMigrationTests.testServerAPIVersionIsAddedByTheUpgradeAndSurvivesAReopen`
(v1 fixture → v3, `nil` before any sync, value survives), and
`MMStoreMigrationTests.testV2FixtureUpgradesToV3AndRecordsAVersion` (a v2 file has no such column, gets
it, records a version).

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

**Two rules the window needs to be safe *(added T29-R — F1, F6)***, both inside the same transaction
as the window selection (`SQLitePostRepository.evict`):

1. **A reply never outlives its root.** Replies are always newer than the root they answer, so
   "keep the newest N by `create_at`" deletes the root first and used to leave its replies behind:
   a whole channel page could be replies whose root no longer existed, and `posts(inThread:)`
   returned them with no root. T29-AV F1 reproduced it (root at `create_at: 1`, 200 replies after
   it, window 50 → `thread_has_root=false orphan_reply_rows=50`). Every post whose `root_id` is in
   the doomed set is now deleted with it — one level is enough, because a Mattermost reply has no
   children of its own. The cost, accepted deliberately: a channel dominated by one huge thread can
   be trimmed to nothing (the root leaves the window and takes its replies), and that channel
   re-fetches on the next sync. An empty channel heals; an orphaned page never does.
2. **Pinned posts are outside the window.** `WHERE is_pinned = 0` in the selection, so a channel
   holds its window *plus* its pinned posts, and `PostRepository.pinnedPosts(inChannel:limit:)` gives
   the Pinned screen something to render offline. Before T29-R, pinned posts were evicted like any
   other and there was no pinned read at all (F6: `pinned_post_survives_eviction=false`).

Both rules are mirrored in `InMemoryStore` and asserted against both backends in
`RepositoryContractTests` (`testEvictionNeverLeavesARepliesRootBehind`,
`testASurvivingRootKeepsItsNewestReplies`, `testPinnedPostsSurviveEviction`), plus a raw-SQL orphan
count in `PostRepositoryTests.testEvictionLeavesNoOrphanReplyRows` that would catch a repository
hiding its own orphans.

**The disk answer, from measurements rather than from arithmetic *(revised T29-R — F3)***:

- Marginal cost of a stored post (row + its index entries, ~140-byte message): **≈ 456 bytes**
  (§5.1, unchanged and reproduced byte-for-byte by two independent AV runs).
- **A 100-channel server at the shipping policy measured 8,163,328 bytes = 7.79 MB, i.e. 0.078 MB
  per channel** (`T29-SIZE channels=100 kept=200 file_bytes=8163328 mb=7.79 mb_per_channel=0.078`,
  §5.4). T29-AV measured the same shape independently at 7,118,848 B = 6.79 MB / 0.068 MB per
  channel; the difference is the fixture (mine trims 251 posts per channel, so the freelist the trim
  leaves is included). **The old note extrapolated "0.30 MB/channel → ≈ 30 MB for 100 channels"
  from a five-channel file, which is ~4.4× too high** — the per-channel figure there was amortising
  a fixed ~1 MB of overhead (schema, table roots, the `-wal`/`-shm` side cars) across only five
  channels. The measured answer is **≈ 8 MB, not ≈ 30 MB**, and it still stops growing: the file
  reaches its high-water mark (window + slack per channel) and then recycles freed pages — §5.3
  measures 1,030 pages returned to the freelist and reused, and sustained writes plateau at
  512,000 B for 3 channels.
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

### 5.4 The 100-channel shipping shape — the F3 measurement *(added T29-R)*

The five-channel file above is a fixture, not a server. T29-AV F3 pointed out that the note turned it
into a per-channel number (0.30 MB) and multiplied by 100, which is wrong by ~4.4× because a
five-channel file carries a fixed ~1 MB of overhead. `MMStoreSizeTests.testHundredChannelsAtTheShippingWindow`
now measures the shape the note actually quotes: **100 channels × 251 posts each** (window 200 +
slack 50 + 1, so every channel trims exactly once) through the production write path, 20 users, one
membership row each, the same deterministic ~140-byte bodies. Verbatim from the Catalyst and simulator
runs in §9 (both platforms print the same bytes):

```
T29-SIZE channels=100 kept=200 file_bytes=8163328 mb=7.79 mb_per_channel=0.078 seed_s=2.83
```

Reading it: **7.79 MB for a 100-channel server at the shipping window, 0.078 MB per channel**, and
the per-channel cost is *lower* than the five-channel fixture's because the fixed overhead is now
amortised over twenty times as many channels. The seed is 25,100 posts written, 20,000 kept, in
2.83 s. T29-AV's independent probe of the same shape (its own fixture, 250 posts per channel) measured
7,118,848 B = 6.79 MB / 0.068 MB per channel, which is the same answer within the fixture difference
(the freelist the trim leaves is included in `file_bytes`, and how much of it there is depends on how
far past the window the seed went). §4 quotes **≈ 8 MB**, not the old ≈ 30 MB.

Scaling that honestly: 1,000 channels at the shipping window ≈ 78 MB held flat; 5,000 channels ≈
390 MB, still flat, with the caveat in §10.4 that the window is per channel and no global budget
exists.

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

Proof, from `MMStoreConcurrencyTests` (8 tests, all green):

- `testWritesRunOffTheMainThread` — a write records `Thread.isMainThread` inside the block: false.
- `testAReadOnTheMainThreadDoesNotWaitForAnInFlightWrite` — with a write held open on the writer
  queue, a main-thread read returns immediately and sees the pre-write snapshot.
- `testManyConcurrentWritersAllLand` — 100 concurrent upserts through `TaskGroup`, all present.
- `testAThrowingWriteIsRolledBackWhole` — a write that throws mid-batch leaves zero rows.
- `testASecondConnectionToTheSameFileSeesCommittedWrites` — the "future notification extension"
  case; the 5 s busy timeout means it waits instead of failing.
- `testAWriteInsideTheBusyTimeoutWaitsAndSucceeds` *(added T29-R)* — a second connection's write
  against a held write lock waits ~0.4 s and then lands.
- `testAWritePastTheBusyTimeoutThrowsATypedStoreBusyError` *(added T29-R)* — past the timeout the
  caller gets `MMStoreError.storeBusy(path:reason:)`, never a raw GRDB `DatabaseError`, and the
  failed write leaves no row behind (§10.6).
- `testEvictionDuringConcurrentInsertsKeepsTheBudget` — concurrent inserts plus eviction never
  leaves a channel over its window.

## 7. Acceptance criteria → evidence

| Criterion | Where it is asserted | Result |
|---|---|---|
| Insert/update post (edit + delete) | `RepositoryContractTests` (both backends) `testPostInsertAndReadBack`, `testPostEdit`, `testStalePayloadDoesNotUndoAnEdit`, `testPostDelete`; `PostRepositoryTests` | pass |
| Channel unread counts | `RepositoryContractTests.testUnreadCounts`, `testMarkRead`, `testManualUnread`; `ChannelRepositoryTests` (totals, per-channel, no N+1) | pass |
| Draft persistence per channel | `RepositoryContractTests.testDrafts`; `DraftRepositoryTests` (channel vs thread isolation, overwrite, recency) | pass |
| Cursor round-trip | `RepositoryContractTests.testCursors`; `SyncCursorRepositoryTests` (per-server / per-channel isolation, clear) | pass |
| Eviction keeping the newest N | `RepositoryContractTests.testEviction` (both backends); `MMStoreSizeTests.testRetentionPolicyBoundsDiskForABusyServer`, `testEvictionReclaimsSpaceAfterTrim` | pass |
| Eviction keeps threads intact and pinned posts (T29-R) | `RepositoryContractTests.testEvictionNeverLeavesARepliesRootBehind`, `testASurvivingRootKeepsItsNewestReplies`, `testPinnedPostsSurviveEviction` (both backends); `PostRepositoryTests.testEvictionLeavesNoOrphanReplyRows` (raw SQL orphan count), `testPinnedPostSurvivesWriteTimeEviction` | pass |
| ADR §5 `server_api_version` recorded per server (T29-R) | `MMStoreTests.testServerAPIVersionSurvivesAReopen`; `MMStoreMigrationTests.testServerAPIVersionIsAddedByTheUpgradeAndSurvivesAReopen`, `testV2FixtureUpgradesToV3AndRecordsAVersion` | pass |
| Migration test proves an older schema upgrades without data loss | `MMStoreMigrationTests.testV1FixtureUpgradesToCurrentWithoutDataLoss` (real v1 database, every row and value re-read), `testUpgradedSchemaAcceptsWritesToTheNewColumns`, `testMigrationIsIdempotentAcrossReopens` | pass |
| A measured note on DB size for a seeded ~10k-post fixture | This note §5 + `MMStoreSizeTests.testTenThousandPostFixtureSizeAndLatency` (prints the numbers and asserts their bounds) | pass |
| Nothing in this card touches the UI | `git status`: T29's diff was `Mattermost.xcodeproj/project.pbxproj`, `docs/THIRD_PARTY_NOTICES.md` and the new `Core/Store` + `MattermostTests` files; T29-R's diff is the existing `Core/Store` sources, their tests and this note. No file under `Mattermost/UI` — no view, view model or SwiftUI file anywhere — is in either diff. | pass |

## 8. Defects found and fixed during implementation

Both were found by the suite failing, not by inspection, and both are recorded here because T29-AV
should re-derive them rather than trust this note.

### 8.1 `checkpoint()` threw `SQLite error 6: database table is locked` *(claim corrected in T29-R — F8)*

`MMStore.checkpoint()` originally ran `db.checkpoint(.truncate)` inside `writer.read { }`. GRDB wraps
a `read` block in a transaction, and `sqlite3_wal_checkpoint_v2` answers `SQLITE_LOCKED` when called
inside one — so every size test and every "free up space" action would have thrown. Fix: run the
checkpoint under `writeWithoutTransaction` (the writer connection, no transaction open), skip
databases that are not in WAL mode (the in-memory store), and degrade `TRUNCATE` to `PASSIVE` when a
reader is in the way instead of failing the caller.

**What this note used to claim, and what the code actually does.** The original text said checkpoint
"degrades `TRUNCATE` to `PASSIVE` when a reader holds a snapshot", and the code only caught
`.SQLITE_LOCKED`. T29-AV F8 measured the real behaviour with a live reader and a non-empty WAL:
**no throw at all** — SQLite waits on our 5 s busy timeout for the reader to finish, which blocked
the writer queue for **1768.9 ms** until the reader went away, and only past that wait does it answer
`SQLITE_BUSY`, not `SQLITE_LOCKED` (BUSY is the answer outside a transaction; LOCKED was the
in-transaction error the fix at the top of this section removed). The claim and the code disagreed
about both the branch and the cost.

T29-R makes it real and observable:

- `checkpoint(truncate:)` now returns `MMCheckpointOutcome` — `.truncated`, `.passive`, `.notWAL`, or
  `.passiveFallback(reason:)` — so the branch that ran is evidence, not a comment.
- The fallback catches **both** `.SQLITE_BUSY` and `.SQLITE_LOCKED`, so it is reachable outside a
  transaction, which is where it runs.
- The honest cost is documented here and in §10.6: a `TRUNCATE` checkpoint **waits** for readers up to
  the busy timeout before giving up, so a "clear space" action can block the writer queue for seconds
  while a screen holds a snapshot. `checkpoint(truncate: false)` is the non-blocking form for callers
  that do not want that.

Tests: `MMStoreTests.testCheckpointTruncatesTheWALWhenNothingElseReads` (the WAL is truncated to zero
bytes; the in-memory store answers `.notWAL`) and
`MMStoreTests.testCheckpointDegradesToPassiveWhenAReaderHoldsTheWAL` (a second connection holds a read
transaction open past a 0.2 s busy timeout; the outcome is `.passiveFallback`, the elapsed time shows
the wait, the WAL is still non-empty because `PASSIVE` cannot truncate it, and the data is intact).

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

T29 suites only, simulator *(revised T29-R — F4: these are the counts this repair run printed; the
old "52 tests, MMStore 11" counted `testT29DiagnosticProbe`, which was deleted before the commit)*.
The ten suites below are the eight store suites plus the two contract suites (18 tests each, the same
assertions against SQLite and against the in-memory double):

```
scripts/qa-test.py --label t29r-ios-t29 --sim id=81A7F251-8B31-4945-8783-5A264C14B8D5 \
  --only-testing MattermostTests/MMStoreTests \
  --only-testing MattermostTests/MMStoreMigrationTests \
  --only-testing MattermostTests/MMStoreConcurrencyTests \
  --only-testing MattermostTests/MMStoreSizeTests \
  --only-testing MattermostTests/PostRepositoryTests \
  --only-testing MattermostTests/ChannelRepositoryTests \
  --only-testing MattermostTests/DraftRepositoryTests \
  --only-testing MattermostTests/SyncCursorRepositoryTests \
  --only-testing MattermostTests/SQLiteRepositoryContractTests \
  --only-testing MattermostTests/InMemoryRepositoryContractTests
→ Executed 97 tests, with 0 failures (0 unexpected)   ** TEST SUCCEEDED **
  (MMStore 13, Post 12, Channel 7, Draft 7, Concurrency 8, SyncCursor 5, Size 4, Migration 5,
   SQLiteRepositoryContract 18, InMemoryRepositoryContract 18)
```

The same ten suites on Mac Catalyst (`--platform mac`, same `--only-testing` list) printed
`97 run, 0 skipped, 0 failed` — the store suites are platform-independent by construction (no
network, no Keychain, no UI), and the numbers agree: the `T29-SIZE` lines are byte-identical on the
two platforms (`file_bytes=8163328` for the 100-channel fixture, `4558848` for the 10k fixture).

Full scheme, Mac Catalyst:

```
scripts/qa-test.py --label t29r-full-catalyst --platform mac
→ Executed 555 tests, with 4 tests skipped and 0 failures   ** TEST SUCCEEDED **
```

Full scheme, iOS Simulator:

```
scripts/qa-test.py --label t29r-full-ios --sim id=81A7F251-8B31-4945-8783-5A264C14B8D5
→ MattermostTests: Executed 555 tests, with 3 tests skipped and 0 failures
→ MattermostUITests: Executed 13 tests, with 1 test skipped and 0 failures  (301.9 s)
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

T29 contributes 97 of the 555 (61 in the eight store suites, 36 in the two contract suites); the
remaining 458 are the pre-existing suites, which still pass — i.e. this card added one framework
dependency and did not disturb the transport, webview or shell. Before T29-R the numbers were 539
full-scheme / 81 T29 (T29-AV's re-derived count); T29-R adds 16 tests — 3 per contract suite, 2
concurrency, 2 migration + 1 migration-and-v2, 2 post, 1 size, 3 store — which is where 539 → 555 and
81 → 97 come from.

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
   each is ≈ 390 MB by §5.4's measured 0.078 MB/channel (the old note said ~1.5 GB, extrapolating the
   five-channel fixture — F3); a global budget would need a policy decision nobody has made yet, so
   the observable here is the per-channel window.
5. **No full-text search index.** Upstream has none in its SQLite either (search is a server API);
   adding FTS5 locally would be a search-feature card.
6. **One writer process assumed, and a second one waits — or fails with a typed error (§10.6).**
   A second process (a notification extension) waits on the busy timeout rather than being
   coordinated; nothing in this card creates a second writer. Both halves are now explicit:
   - **The wait**: if the lock is released inside the timeout, the write simply proceeds. The default
     is **5 s** (`MMStore.open(..., busyTimeout:)`, mirroring upstream's `defaultBusyTimeout`);
     `MMStoreConcurrencyTests.testAWriteInsideTheBusyTimeoutWaitsAndSucceeds` proves a 0.4 s hold is
     waited out rather than failed.
   - **The failure**: past that wait SQLite answers `SQLITE_BUSY` (or `SQLITE_LOCKED`), and the store
     boundary maps it to `MMStoreError.storeBusy(path:reason:)` — a typed error carrying the file and
     SQLite's own message — instead of letting a raw GRDB `DatabaseError: SQLite error 5: database is
     locked … BEGIN IMMEDIATE TRANSACTION` reach a caller that cannot tell it from a corrupt database
     (T29-AV F2 reproduced exactly that at 5.16 s). `testAWritePastTheBusyTimeoutThrowsATypedStoreBusyError`
     pins it with a two-connection hold. Nothing is half-applied: the failed transaction rolled back.
     The same mapping covers `read`, `readAsync`, `vacuum`, the migration path and the diagnostics
     paths, because it lives in `MMStore`, not in each repository.
   - Same story for maintenance: a `TRUNCATE` checkpoint **waits** for a live reader up to the busy
     timeout before degrading to `PASSIVE` (§8.1), so a "clear space" action can stall the writer queue
     for a few seconds.
7. **`MMStore` is `@unchecked Sendable`.** The `NSLock`-guarded `closed` flag and the GRDB writer are
   the reason; it is the only such annotation in the store and it is worth an AV question.
8. **A channel can hold more than its window: the pinned posts are extra, and a pinned reply dies with
   its root.** `WHERE is_pinned = 0` in the window means the budget is "200 unpinned posts plus pinned
   posts", so a channel with 500 pinned posts keeps 700 rows — the Pinned screen needs them, and raw
   server data that pins hundreds of posts in one channel would push that channel past the number in
   §4. Two edges follow from that, both accepted: a channel whose *pinned* count alone exceeds the
   write threshold (`maxPostsPerChannel + evictionSlack`) runs the eviction scan on every write and
   keeps no unpinned history at all, and a *pinned reply* is still deleted when its root is evicted
   (thread integrity wins over the pin, because a reply with no root has nothing to render in); the
   Pinned screen should render roots.
9. **`server_api_version` is per file, not per row** (§3.3) — it is set by a later card's sync and
   stays `nil` until then.

## 11. T29-AV findings and how each one was closed *(T29-R)*

T29-AV (`t_b6f2124d`) passed the card with nine findings. Every one is closed in the repair commit;
nothing here is deferred. The F-numbers are the auditor's, so a re-audit can go down the list.

| # | Severity | Finding | What changed | Where it is proved |
|---|---|---|---|---|
| F1 | MEDIUM | Eviction deleted a thread's root and kept its replies: `posts(inThread:)` returned replies with no root, and a channel page could be all orphans (AV: 50 orphan rows) | `evict` deletes every post whose `root_id` is in the doomed set, in the same transaction, one level (a reply has no children). The window is still on posts. Mirrored in `InMemoryStore`; the accepted cost (a one-thread channel can trim to empty and re-fetches) is written down in §4 | `SQLiteRepositoryContractTests`/`InMemoryRepositoryContractTests.testEvictionNeverLeavesARepliesRootBehind`, `.testASurvivingRootKeepsItsNewestReplies`; `PostRepositoryTests.testEvictionLeavesNoOrphanReplyRows` counts orphans in raw SQL |
| F2 | LOW/MED | A write past the 5 s busy timeout surfaced a raw GRDB `DatabaseError` (`SQLite error 5 … BEGIN IMMEDIATE TRANSACTION`) instead of a store error | `MMStoreError.storeBusy(path:reason:)`; `MMStore.mappingBusy` maps `SQLITE_BUSY`/`SQLITE_LOCKED` at the store boundary for `write`, `read`, `readAsync`, `vacuum`, `registerServer`; `busyTimeout:` is a parameter of `MMStore.open` (default 5 s). Both the wait and the failure are documented in §10.6 | `MMStoreConcurrencyTests.testAWritePastTheBusyTimeoutThrowsATypedStoreBusyError` (two-connection hold, typed error, no half-applied row), `.testAWriteInsideTheBusyTimeoutWaitsAndSucceeds` |
| F3 | LOW | "0.30 MB/channel → ≈ 30 MB for 100 channels" was ~4.4× too high; the per-channel figure came from a five-channel file | §4 now quotes a measured 100-channel number (8,163,328 B = 7.79 MB, 0.078 MB/channel), the extrapolation is explained and dropped, the unbounded comparison is kept, and a fourth size test reproduces the number | `MMStoreSizeTests.testHundredChannelsAtTheShippingWindow` prints `T29-SIZE channels=100 kept=200 file_bytes=8163328 mb=7.79 mb_per_channel=0.078`; §5.4 |
| F4 | LOW | "52 tests, MMStore 11" was stale — the committed log counted `testT29DiagnosticProbe`, deleted before the commit | §9 and §1 quote the counts this repair run printed: 61 in the eight store suites, 97 with the two 18-test contract suites, 555 / 4 skipped / 0 failed full-scheme Catalyst, the same suites plus the 13 UI tests on the simulator | §9, §1 |
| F5 | MEDIUM | ADR §5 requires a recorded `server_api_version`; nothing recorded it and §10 did not list the gap | New additive step `v3_server_api_version` (`ALTER TABLE server ADD COLUMN server_api_version TEXT NOT NULL DEFAULT ''`), `recordServerAPIVersion(_:)` / `serverAPIVersion()`, the choice and its consequence (per file, not per row) in §3.3, the limitation in §10.9 | `MMStoreTests.testServerAPIVersionSurvivesAReopen`; `MMStoreMigrationTests.testServerAPIVersionIsAddedByTheUpgradeAndSurvivesAReopen`, `.testV2FixtureUpgradesToV3AndRecordsAVersion` |
| F6 | LOW | Pinned posts were evicted like any other and there was no pinned read | Taken the "better" branch: `WHERE is_pinned = 0` in the window, `PostRepository.pinnedPosts(inChannel:limit:)` in both backends, and the extra-rows consequence in §10.8 | `RepositoryContractTests.testPinnedPostsSurviveEviction` (both backends); `PostRepositoryTests.testPinnedPostSurvivesWriteTimeEviction` |
| F7 | LOW | §3.2 listed 15 indices, the DDL has 17; "no speculative indices" contradicted by `idx_reaction_user` | §3.2 lists all 17 in two groups (queried today / reserved with the query each is for), the denial is replaced by that split, `MMSchema` carries the same split in its comment, and the test asserts all 17 by name plus the total | `MMStoreTests.testIndicesTheQueriesNeedExist` (17 names, plus `COUNT(*) = 17` from `sqlite_master`); §3.2 |
| F8 | LOW | §8.1's "degrades to PASSIVE" claim was not what the code did: with a live reader it blocked the writer queue 1768.9 ms, and the `.SQLITE_LOCKED` catch was unreachable outside a transaction | Made real: the fallback catches **BUSY and LOCKED**, `checkpoint` returns `MMCheckpointOutcome` so the branch is observable, and §8.1/§10.6 now say the truncating checkpoint *waits* for readers up to the busy timeout before degrading — a "clear space" action can wait | `MMStoreTests.testCheckpointDegradesToPassiveWhenAReaderHoldsTheWAL` (live reader, `.passiveFallback`, WAL still non-empty, data intact), `.testCheckpointTruncatesTheWALWhenNothingElseReads` |
| F9 | LOW | `XCTAssertGreaterThanOrEqual(size.megabytes, 0)` is always true | Replaced with real relationships: `usedBytes == (pageCount - freePageCount) * pageSize`, `usedBytes <= pageCount * pageSize`, `megabytes == fileBytes / 1 MiB`, and `fileBytes`/`pageCount` grow after 400 more 1 KB rows | `MMStoreTests.testStoreSizeReportsPagesAndFileBytes` |

Regressions checked by the same runs: the full Catalyst scheme and the full iOS scheme are green with
no new skips (§9), and the licence/secret rule still holds — no real workspace URL or token anywhere,
`bash scripts/t28-token-grep.sh` PASS.
