# Post authors read "Unknown user" — the profile batch that could lose a whole page

Card: `t_70b41028` (reported against the installed native build).
Tree: `main` @ `5749cc2` + this card's commit. Verified on the local throwaway server
(Mattermost 9.11.19, `127.0.0.1:8065`, account `perfprobe`) and on `iPhone 16 Pro / iOS 18.3.1`.

## 1. What the reader saw

Every author in a channel read **"Unknown user"**. The rule that draws a name
(`PostListDerivation.author(for:users:)`, `PostListModels.swift:443`) falls back to
`post.props["username"]` and then to the literal `"Unknown user"` when the pane's
`userID -> MMUser` map has no entry — so the rows were honest: the map was empty.

`ChannelViewModel.loadProfiles` was the only thing that filled it, in five lines:

```swift
let missing = userIDs.filter { users[$0] == nil }
guard !missing.isEmpty else { return }
let loaded = (try? await service.users(ids: missing)) ?? []      // error swallowed
for user in loaded { users[user.id] = user }
```

Three defects lived in those five lines:

1. **No empty-id filter.** A post's `user_id` can be `""` (system/join messages on some servers,
   bot/plugin posts). The sibling path `scheduleProfileLoad` guarded `!userID.isEmpty`; this one
   did not, so `""` went into the `POST /users/ids` body.
2. **No chunking.** Every distinct author id went into one body; a long-lived channel with many
   authors produced one large request whose failure was all-or-nothing.
3. **Errors were invisible.** `(try? …) ?? []` made a refused request, a 401 and a timeout
   indistinguishable from "nobody to load" — which is why the symptom had never shown up in a
   diagnostic, and why "Unknown user" was the first evidence of it.

The same five lines existed, with the same three defects, in four other panes: the thread
(`ThreadViewModel`), the global threads list (`GlobalThreadsViewModel`), search results
(`PostCollectionViewModel`) and a second copy in the sidebar's `DirectLabelResolver`.

## 2. What the server actually does with those two bodies (measured, not assumed)

This matters for the card's theory, so it is recorded as measured rather than as believed.
`POST /users/ids` on the pinned 9.11.19 fixture, with **real** ids from `#off-topic`:

| body | status | answered |
|---|---|---|
| the page's 15 authors + `""` | 200 | 15 (the empty id is ignored) |
| `[""]` alone | 200 | 0 |
| 15 real ids repeated to 100 / 101 / 400 / 1000 elements | 200 | 15 (deduped) |

So on **this** server an empty id does not refuse the batch and a 1000-id body is not rejected —
the card's "highest-probability cause" (one empty id kills the whole request) is **not
reproducible here**. The three defects are still defects (the API's contract is a list of user
ids; the endpoint is not obliged to absorb either malformed shape, and the frozen tests model a
server that refuses them — see `T70AuthorProfilesTests.testAServerRefusesAProfileRequestThatCarriesAnEmptyID`),
but they were not demonstrated to be *this* report's trigger on this server, and this note does
not claim they were. What the repair does guarantee, and what the live run below shows, is that a
profile load now reports `requested` / `cached` / `sent` / `resolved` / `failed` / `err`, so the
next occurrence of an empty map names its own cause instead of hiding behind `try?`.

## 3. The repair

One loader, not five copies: **`Mattermost/Core/MM/ProfileBatch.swift`**.

```swift
let report = await ProfileBatch.load(ids, cache: profiles,
                                     fetch: { try await service.users(ids: $0) },
                                     onProfiles: { users in /* merge + republish */ })
```

* `ProfileBatch.clean` drops empty ids and duplicates **before** anything is asked.
* `UserProfileCache` (the per-server cache added by `t_c0e42801`) is consulted first; a profile the
  channel timeline or the sidebar already fetched costs no request.
* The rest are fetched **≤100 ids per request** (`ProfileBatch.size`, the same number
  `APIClient.usersBatchSize` uses). `APIClient.users(ids:)` also chunks, but a caller-side split is
  what makes **one failed chunk cost only its own ids** — a chunk that throws is counted and
  skipped, and the authors another chunk named stay named.
* The outcome is a `ProfileBatchReport`, whose `line(pane:)` is
  `<pane> profiles requested=… cached=… sent=… resolved=… chunks=… failed=… err=…`.

Call sites now share it and log the line at `.info` (the app's default level gate drops `.debug`,
so a debug line would repeat the original blindness):

| pane | file | category |
|---|---|---|
| channel timeline | `ChannelViewModel.loadProfiles` | `ChannelProfiles` |
| thread | `ThreadViewModel.loadProfiles` | `ThreadProfiles` |
| global threads | `GlobalThreadsViewModel.loadProfiles` | `ThreadProfiles` |
| search results | `PostCollectionViewModel.loadProfiles` | `SearchProfiles` |
| sidebar DM/GM labels | `DirectLabelResolver.resolve` | `SidebarProfiles` |

`SessionChannelService.users` and `SessionThreadService.users` no longer swallow: they `throw`, and
their callers catch into the report. `ChannelViewModel` also sums every load into
`profileTotals`/`lastProfileLoad` and exposes `profileDiagnostics`; `ChannelPaneCoordinator` gained
`diagnosticSummary(for:)`, printed by the `-shellSnapshot` dump as a `channels=` line next to
`sidebar=` and `auth=`.

The `"Unknown user"` fallback is untouched: it is the honest last resort for an author the server
genuinely will not name (deleted account). The bug was that it fired for people who were simply
never fetched.

### The regression that made this hard to see

`#off-topic`'s newest page carries **27 system posts** and **15 distinct authors**, and the fixture
account is a member of a workspace whose channel list is 18,842 pt tall. The UI probe's first two
versions failed on the *test*, not the app: the channel row was outside the lazy list's realised
window. It now opens the channel the way a person does on a long list — the quick switcher — which
is also what the T39 jump suite does.

## 4. Live evidence (the card's attachment)

`MattermostUITests/T70AuthorNamesUITests` on the local server, one invocation:

```
PROBE-T70 channel=off-topic id=re4jed6wti8e8g9jt8aza9ewye posts=57 authors=15 system=27
PROBE-T70 unknown-user rows=0 authors=15
RESULT: PASS   (1 run, 0 skipped, 0 failed, 50.6 s)
```

Screenshot: `docs/t_70b41028-author-names.png` (the pane with every author named, taken by the test).

The diagnostics line from the same run (`log show --info --predicate 'subsystem == "com.mattermost.ios"'`):

```
[com.mattermost.ios:ChannelProfiles] channel=re4jed6wti8e8g9jt8aza9ewye profiles \
    requested=15 cached=3 sent=12 resolved=15 chunks=1 failed=0 err=-
[com.mattermost.ios:SidebarProfiles] labels profiles requested=4 cached=0 sent=4 \
    resolved=4 chunks=1 failed=0 err=-
```

`requested=15 resolved=15` is the page's authors, all named; `cached=3` is the cache doing its job
(three of those profiles had already been fetched by the sidebar load); `failed=0 err=-` says no
request was refused. Before this card that line did not exist.

## 5. Tests

`MattermostTests/T70AuthorProfilesTests` — 11 tests, all green:

* `testAPageWithAnEmptyUserIdStillNamesEveryOtherAuthor` — **the regression test**: a page with a
  `user_id: ""` system post plus two ordinary authors resolves *both* authors, and the fake refuses
  any body carrying `""`.
* `testAServerRefusesAProfileRequestThatCarriesAnEmptyID` — the falsifier for the line above: the
  fake's refusal is real, so the first test would fail on the old code.
* `testA400LeavesKnownAuthorsNamedAndTheRestOnTheirPropsUsername` — a refused batch leaves the
  cached author named and the other on its `props.username`, never "Unknown user", and the report
  carries `failed=1` + an error.
* `testAPageWithMoreThanOneHundredAuthorsIsResolvedInChunks` — 250 authors → request sizes
  `100/100/50`, all 250 named.
* `testAFailedChunkKeepsTheAuthorsTheOtherChunksNamed` — the middle chunk is refused: `resolved=150`,
  `failed=100`, 150 rows named.
* plus the cache-hit, diagnostics, `clean`, `chunks` and error-report unit cases.

Runs:

```
python3 scripts/qa-test.py --platform ios --sim id=81A7F251-… --only-testing MattermostTests
  → 1776 run, 8 skipped, 0 failed   (RESULT: PASS)
  → focused: T70AuthorProfilesTests 11/11 + T33DmLabelResolutionTests 14/14
python3 scripts/qa-test.py … --only-testing MattermostUITests/T70AuthorNamesUITests
  → 1 run, 0 skipped, 0 failed      (RESULT: PASS, live server)
```

## 6. Not claimed

* **The original trigger is not identified.** On this server neither an empty id nor a 1000-id body
  is refused (§2), and the live pane names every author. Whatever produced the report on the user's
  install (a transient 401/timeout is the remaining candidate) would now be visible as
  `failed>0 err=…` in the `ChannelProfiles` line rather than as a silent "Unknown user".
* **No live >100-id page.** `#off-topic`'s newest page has 15 authors; chunking is proven in the
  unit tests with a 250-author page, not against the server.
* `UserProfileCache` is in-process only and has no eviction (unchanged from `t_c0e42801`); a relaunch
  pays the request again, now chunked and with an empty-id filter.
* The `-shellSnapshot` **`.txt`** dump did not land in the manual relaunch on this host (the probe's
  task is cancelled while it polls for a webview — a pre-existing seam limitation, not this card's
  change); the `channels=` line it prints is the same string as `ChannelProfiles` above, which was
  captured from the live log instead.
