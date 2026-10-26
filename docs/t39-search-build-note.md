# T39 — native search, saved messages and pinned posts

Behaviour reference: `mattermost/mattermost-mobile` **v2.45.0**, commit
`162f2560d0e1df073220f7701d5a67cc17c8abeb` (`app/screens/home/search/`, `app/screens/saved_posts/`,
`app/screens/pinned_messages/`, `app/utils/markdown/index.ts`, `app/actions/remote/search.ts`,
`app/actions/local/team.ts`, `app/client/rest/posts.ts`). Every new file pins that reference in its
own header; the repo-level attribution entry is `docs/THIRD_PARTY_NOTICES.md` §16.

The card's four surfaces — the search screen (S19), its result rows (S20) and the channel's pinned
messages (S21), plus the Saved list that shares their lookup group — are rendered natively, behind the
existing `search` surface switch in `SurfaceModeResolver`, so a run with `search=web` still gets the
web app and says so.

## 1. What shipped

| File | Lines | What it is |
|---|---:|---|
| `Mattermost/UI/Native/Search/SearchGrammar.swift` | 380 | The query grammar: the five documented modifiers (`from:`, `in:`, `before:`, `after:`, `on:`), the `-` exclusion prefix, quoted phrases, the trailing-`*` wildcard, the `YYYY-MM-DD` date rule, whitespace/curly-quote normalisation, and the reader-facing sentences for what cannot be sent |
| `Mattermost/UI/Native/Search/SearchHighlighter.swift` | 193 | Which characters a result marks: terms from the query (modifiers and negations dropped), word boundaries, the CJK branch, prefix terms, longest-first overlap resolution, and the ranges on an `AttributedString` |
| `Mattermost/UI/Native/Search/SearchResults.swift` | 245 | `MMSearchResults` decoding, the paged result window (`merge`, dedupe, `has_next`/page-length rule), the row builder and every line of copy the screen shows |
| `Mattermost/UI/Native/Search/RecentSearches.swift` | 135 | The per-server, per-team recent list (`MAX_TEAM_SEARCHES = 15`, case-insensitive dedupe, newest spelling kept) and its `UserDefaults` store |
| `Mattermost/UI/Native/Search/SearchAPI.swift` | 119 | The endpoints: `POST /teams/{id}/posts/search`, `GET /users/me/posts/flagged`, `GET /channels/{id}/pinned`, `POST /posts/{id}/pin|unpin`, the preference writes that save/unsave a post, `POST /teams/{id}/channels/ids`, `GET /posts/{id}` |
| `Mattermost/UI/Native/Search/SearchService.swift` | 110 | The `SearchServing` seam (faked by the unit suite) and its session-backed implementation |
| `Mattermost/UI/Native/Search/SearchViewModel.swift` | 302 | Search state: validate-then-send, generation-guarded answers, paging, row context (authors + channel names in batches), recent-search recording, `SearchJump` |
| `Mattermost/UI/Native/Search/PostCollectionViewModel.swift` | 286 | The Saved and pinned lists: load/page, unsave/unpin **in place** (no refetch), and the socket's `preference_changed`/`post_edited`/`post_deleted` patches |
| `Mattermost/UI/Native/Search/SearchCoordinator.swift` | 125 | One model per server+team, the service factory, and the socket/auth fan-out |
| `Mattermost/UI/Native/Search/SearchView.swift` | 436 | The search screen: field, submit, validation banner, modifier chips, recent searches, result list, Load more, window note, empty and failed states |
| `Mattermost/UI/Native/Search/SavedPinnedViews.swift` | 252 | The Saved tab and the pinned-messages sheet, both on one reusable `PostCollectionView` |

Hosting changes (each small and local):

- `NativeNavigation` — `NativeTab` gains `.search` and `.saved`.
- `NativeShellView` — the two new tabs in the compact layout, **and** a lookup sheet with Search/Saved
  actions in the regular (Pad/desktop) layout's detail toolbar: the split layout has no tab bar and
  `NativeTarget` has no search case, so without that a pad or Mac window could not open either screen.
- `ChannelViewModel` — `focus(postID:)` (scroll to a post the window holds, otherwise fetch it by id
  and merge it), `jumpTarget`/`focusedPostID`/`focusError`, `threadJumpRootID` for a reply (a reply is
  not a row of a thread-collapsed timeline, so its jump is its thread), and `applyPin(postID:isPinned:)`.
- `ChannelView` — the pinned button in the channel header + its sheet, the focused-row marker, and the
  `.onChange` that scrolls to a jumped-to post.
- `ChannelService` — `post(id:)` on the seam (default: `notFound`, so existing fakes keep compiling).
- `MarkdownView`/`MarkdownInlineText` — a `searchHighlightTerms` environment value applied by
  `MarkdownText.attributed(_:highlight:)`; scoped to the result row, so a channel's own rows are never
  marked by a search the reader has left behind.
- `MattermostApp` — `SearchCoordinator` bound like the other coordinators, fed by the rail's one
  socket, reset on an auth-phase change, and in the environment.
- `NativePanePlaceholders` — a route with a `postID` now passes it to the channel pane, so a permalink
  and a search result land on the same post (before this the pane opened at the newest message).

## 2. The measured server contract

Measured with `scripts/t39_search_probe.py` against the local throwaway server on **2026-10-26**
(Mattermost **9.11.19**, BuildNumber 16643067630). The full transcript is
`docs/t39-search-probe-2026-10-26.log`; the probe exits 0 when every fact below still holds.

| Request | Status | What the client does with it |
|---|---|---|
| `POST /teams/{team_id}/posts/search` | 200 | Sends `terms`, `is_or_search: false`, `time_zone_offset`, `page`, `per_page`, `include_deleted_channels: true`; reads `order`, `posts`, `matches`, `has_next` |
| `POST …/posts/search` with `page=1` | 200, **0 ids**, `has_next: false` | The database backend answers **one capped window**; the window's rule ("a short or empty page ends it") is built for exactly this |
| `POST …/posts/search` with `per_page` 3/10/200/500 | 200, **100 ids every time** | `per_page` is Elasticsearch-only; the client trusts the answer's length and says so at the measured cap |
| `POST …/posts/search` with `before:notadate`, `on:today`, `"unterminated`, `the(`, `x:whatever` | 200, empty or unrelated ids | The server does **not** reject a malformed query — the client owns every error sentence |
| `POST …/posts/search` with `terms: ""` | **400** `Invalid or missing terms in request body.` | Passed through verbatim |
| `POST …/posts/search` with `terms=the` | 200, **0 ids** | Stop words are dropped; "nothing matched" copy names the query instead of blaming the reader |
| `GET /users/me/posts/flagged?team_id=…` | 200 | **The** saved list path on 9.11.19 |
| `GET /users/me/teams/{team}/posts/saved…` | **404** | Kept only as a fallback for servers that answer it |
| `GET /teams/{team}/posts/flagged…` | **404** | Not used |
| `GET /channels/{id}/pinned` | 200 | The pinned sheet's source (same post-list envelope) |
| `POST /posts/{id}/pin`, `POST /posts/{id}/unpin` | 200 | Pin/unpin writes |
| `POST /posts/{id}/flag`, `POST /posts/{id}/unflag` | **404** | **Not used**: saving is a preference, not a post write |
| `PUT /users/{id}/preferences` (`flagged_post`) | 200 | Save; the flagged list sees it |
| `POST /users/{id}/preferences/delete` | 200 | Unsave; the flagged list drops it |
| `POST /teams/{team_id}/channels/ids` | 200 | One batched lookup for the result rows' channel subtitles |
| `GET /posts/{id}` | 200 | Jumping to a result older than the channel's newest page |

## 3. The rules that follow (and where they are pinned)

1. **A malformed query never becomes a request.** `SearchViewModel.submit` validates first, so
   `before:notadate` produces a sentence naming the field and `YYYY-MM-DD`, and the result list is not
   drawn at all — the card forbids "silently empty". Pinned by
   `testMalformedQueriesProduceReadableSentencesInsteadOfRequests`,
   `testSubmitRefusesAMalformedQueryWithoutCallingTheServer`, `testTheDateGrammarIsTheDocumentedOne`.
2. **The query string is the server's, not the client's.** Only curly quotes are straightened and
   runs of whitespace outside quotes collapsed; modifiers, `-`, `*` and phrases are sent exactly as
   typed. Pinned by `testEachDocumentedModifierIsParsedComposedAndSentVerbatim`,
   `testQuotedPhrasesArePreservedAndSmartQuotesAreNormalised`, `testTheRequestBodyCarriesEveryDocumentedField`.
3. **Highlighting is derived when the server sends no `matches`** (measured: it never does on this
   backend), with upstream's term rules: word boundaries, no end boundary for a prefix, no boundaries
   for CJK, longest-first, and the server's map preferred when present *and* the query has no quoted
   phrase. Pinned by `testMatchingRespectsWordBoundariesCaseAndPrefixes`,
   `testCJKTermsMatchWithoutWordBoundaries`, `testOverlappingTermsResolveToTheEarliestLongestMatch`,
   `testServerMatchesWinUnlessTheQueryHasAPhrase`, and — for the paint itself —
   `testTheMarkdownRendererMarksTheMatchedCharacters`.
4. **Paging never lies.** `has_next` is authoritative; without it a full page means "ask again"; an
   empty page is exhaustion; at the measured 100 cap the screen says the server returns one window
   per query instead of offering a Load more that cannot work. Pinned by
   `testAPageAppendsNewPostsAndDeduplicatesRepeats`, `testTheDatabaseBackendWindowIsReportedExhausted`,
   `testAFullPageWithoutHasNextKeepsAsking`, `testTheWindowNoteOnlyAppearsAtTheMeasuredCap`.
5. **Unsave/unpin are in-place, then verified.** The row leaves the list on success (no refetch, no
   flicker) and a failure leaves it in place with a sentence. Pinned by
   `testUnpinningRemovesTheRowInPlaceWithoutARefetch`, `testUnsavingWritesThePreferenceAndDropsTheRow`,
   `testAPinnedListFailureIsASentence`.
6. **The lists are live.** `preference_changed` removes an unsaved row immediately and asks for a
   reload when a post was saved elsewhere (the row cannot be invented); `post_edited`/`post_deleted`
   patch in place. Pinned by `testSocketPreferenceChangesPatchTheSavedList`,
   `testSocketPostEditedPatchesARowInPlace`.
7. **Recent searches are per server+team, deduped case-insensitively, capped at 15** — upstream's
   `MAX_TEAM_SEARCHES`. Pinned by `testRecentSearchesAreDedupedNewestFirstAndCapped`,
   `testTheStoreRoundTripsThroughItsKey`, `testTheDefaultsKeyIsScopedToServerAndTeam`.
8. **A jump lands on the message.** A root post scrolls into place (fetched first if the window does
   not hold it); a reply opens its thread, because a reply is not a timeline row. Pinned by
   `testAJumpTargetIsAChannelForARootAndAThreadForAReply` and exercised live in
   `T39SearchUITests.testSearchRendersTheServersMatchAndOpensItAtThePost`.

## 4. Reachability

- **Compact (iPhone):** `Search` and `Saved` are tabs beside `Channels` and `Threads`.
- **Regular (iPad / Mac):** the detail column's toolbar carries `Search` and `Saved`, each presenting
  the same pane in a sheet. This is deliberate: the split layout has no tab bar and `NativeTarget`
  names only home/channel/threads, so without it the two screens would exist but be unreachable.
- **Pinned:** the channel header's pin button, opening the sheet. Gated on the same `search` surface.
- Both screens say what to do when the surface resolves to web (`search=web`) or when no team is
  selected, rather than drawing an empty screen.

## 5. Verification

- **Unit suite:** `MattermostTests/T39SearchTests.swift` — 35 tests, all passing. The whole unit
  target was run too (the edits touch `ChannelView`, `ChannelViewModel`, `MarkdownView`,
  `NativeShellView`, `NativeNavigation` and `MattermostApp`), and it is clean:

      xcodebuild -project Mattermost.xcodeproj -scheme Mattermost \
        -destination 'platform=macOS,variant=Mac Catalyst' \
        -derivedDataPath ~/Library/Developer/Xcode/DerivedData/t39-build \
        test -only-testing:MattermostTests
      → Executed 35 tests, with 0 failures …          (T39SearchTests)
      → Executed 1233 tests, with 4 tests skipped and 0 failures … ** TEST SUCCEEDED **

- **Server probe:** `python3 scripts/t39_search_probe.py` → `RESULT: PASS — measured on Mattermost
  9.11.19 (BuildNumber 16643067630)`; transcript in `docs/t39-search-probe-2026-10-26.log`. The two
  measured oddities (`page=1` empty, `per_page` ignored) are asserted as the *shape the client is
  built for*, not wished away; `flag`/`unflag` are recorded as absent so nobody routes the client
  back onto them.
- **Live UI suite:** `MattermostUITests/T39SearchUITests.swift` against the local server
  (Mattermost 9.11.19) on an iPhone 17 Pro simulator (iOS 26.5):

      TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
      TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
      TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
      python3 scripts/qa-test.py --platform ios --sim id=6B6991BF-6816-44EE-8FEA-284712F6ECBB \
        --only-testing MattermostUITests/T39SearchUITests

  Result: **4 tests, 4 passing** —
  the query reaches the server's search and its match renders with the server's own message text
  (`t39-1-search-results`), a result opens its post (`t39-2-focus-on-post`), a malformed query is
  explained instead of answering an empty list (`t39-3-invalid-query`), unsaving removes the row and
  the server's `flagged_post` preference is gone (`t39-4-saved-list`, `t39-5-saved-after-unsave`),
  and unpinning removes the row with `is_pinned: false` on the server (`t39-6-pinned-sheet`,
  `t39-7-pinned-after-unpin`). The test's oracle is the server itself, read back through the same
  account the app signs in as; every test skips rather than fails when the server or the fixture is
  missing.
- **Catalyst note:** the UI-test bundle's Catalyst deployment target is macOS 26.5 while this host is
  macOS 26.3.1, so XCUITest cannot run on Catalyst here (`Cannot test target "MattermostUITests" on
  "My Mac"`). The app itself builds and the unit suite runs on Catalyst; the live UI suite runs on the
  iOS 26.5 simulator, which is the platform the tests target anyway.

## 6. Known limits (stated, not hidden)

- **No true result paging on a database backend.** The request carries `page`/`per_page` (correct for
  Elasticsearch); this server answers one capped window. The screen says so at the cap. A server with
  Elasticsearch will page and the same code follows `has_next`.
- **No server-side highlight map to lean on** on this backend, so the marks come from the query's own
  terms (upstream's fallback, same order).
- **Search is one team at a time** (the shell's current team), as upstream's screen is.
- **No channel/file result tabs**, no `is_or_search` toggle as a control, and no deep-link into a
  prefilled search — the shell's routing names channels, posts and threads. All three are listed in
  `docs/THIRD_PARTY_NOTICES.md` §16 as not ported by this card.
- **Nothing here needs APNs or a push proxy.** Socket-driven updates ride the existing rail socket;
  a real push proxy remains out of scope for this host.
