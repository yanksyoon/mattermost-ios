# Component map — official-repo source files → SwiftUI decomposition (T25b)

- **Status:** delivered (T25b). Consumed by T26 dual-render, T28 transport, T29 local store,
  and every T31–T45 screen card. The 16 screen cards are **not** reopened by this document; it
  only decides, per surface, what gets ported and from where.
- **Date:** 2026-10-24
- **Pins (record once, cite everywhere):**
  - `M` = `mattermost/mattermost-mobile` @ **v2.45.0** = commit **`162f2560d0e1df073220f7701d5a67cc17c8abeb`**
  - `W` = `mattermost/mattermost` monorepo @ **v12.0.1** = commit **`987e57120dca630dadbcd2638064ab66a02bb81e`**,
    webapp tree at `webapp/channels/src/` (Apache-2.0 per `LICENSE.txt` line 15)
- **Licence:** all paths below are Apache-2.0 (mobile `app/` + Gekidou, webapp `webapp/channels/src/`),
  MIT/BSD for the supporting libs — see `docs/THIRD_PARTY_NOTICES.md` (verified 2026-10-24). Every
  ported file carries the §3 attribution header.
- **Consumer contract:** `docs/parity.md` remains the module→native mapping for the desktop shell;
  this doc is the per-surface source-file map for the Path B chat client.

---

## 1. Translation rules — how a React/RN component becomes SwiftUI

Translating React is a **reinterpretation**, not a mechanical transpile. A
`useEffect`+`memo`+virtualized-render tree does not map onto SwiftUI's diffing. These rules are
the shared convention so 16 screen cards don't each invent their own.

| React/RN concept | SwiftUI counterpart | Notes |
|---|---|---|
| Component + props | `View` struct + value-type config | Re-render on prop change ↔ `Equatable`/`Identifiable` value structs drive SwiftUI diffing |
| `useState` / `useReducer` | `@State` / `@Observable` view model | Screen-level owned state lives in an `@Observable` VM; transient UI state in `@State` |
| Context / Redux store selectors | `@Observable` app/store model + computed properties | See T29 store; `useSelector`-style derived values become computed props |
| `useEffect(fn, [deps])` | `.task(id:)`, `.onChange(of:)`, `.onAppear/.onDisappear` | Subscription lifecycle maps to `task` + cancellation; WS/DB subscriptions live in the store, not views |
| `useMemo` / `memo()` | Computed properties on value types / `@Observable` | Memoization is SwiftUI's job; don't hand-roll caches unless hot-path |
| `FlatList`/FlashList `renderItem` + windowing | `List` / `LazyVStack` with an **explicit window** | Port the window math (offset → loaded range) into the VM; row = `Identifiable` |
| `Pressable`/`TouchableOpacity` | `Button`, `onTapGesture`, `contextMenu` | Long-press post menu → `contextMenu` (S38) |
| Modal / bottom-sheet (`@gorhom/bottom-sheet`) | `.sheet(item:)` + `presentationDetents` | Sheet host pattern lives in `UI/SheetHost.swift` (shared) |
| Navigation (`expo-router`, 133 route files) | `NavigationStack` + route value enum | Route table in `Navigation/AppRoute.swift`; deep links map through `Core/DeepLinkRouter.swift` (T4) |
| `StyleSheet` + theme | `Theme` struct + view modifiers | Theme keys map from server `theme` preference (S27); no CSS parsing |
| `Intl`/date formatting | `Date.FormatStyle`, own `Date+Extensions` port | Gekidou `Date+Extensions.swift` is Apache-2.0 and taken as-is (T28) |
| i18n strings | `String(localized:)` + a generated strings catalog | Transliteration from the RN i18n keys; do not copy the whole locale tree — start en-US and audit |
| `Animated`/`Reanimated` | `withAnimation`, `withSpring`, `.animation` | Physics → SwiftUI animations; only where parity matters (e.g. thread RHS) |

**Windows and pagination rule (all lists):** every `List`/`LazyVStack` surface ports the upstream
`loadMore/before/after` offsets into an `@Observable` `*ListViewModel` that owns `PageState`
(`items`, `isLoadingMore`, `hasMore`, cursor). Views render `items`; they never own pagination.

**Reuse carve-outs:** shared UI that already exists in this repo stays native and is not
re-ported from RN — `SettingsView` (T11), `WelcomeView` (T10), `DeepLinkRouter` (T4),
`ServerFormView`+`ServerURLValidator` (T5), `NotificationWorker`+`SessionStore` badge (T8),
download plumbing (T7).

---

## 2. Gekidou — take as-is vs reimplement (mobile @ `162f2560`)

The iOS tree `ios/Gekidou/Sources/Gekidou/` (50 Swift files, Apache-2.0) is the official native
layer. Take it **as-is** (vendored, with the §3 header) wherever it does not depend on the RN
bridge:

**Take as-is (build target `Gekidou`, module import):**
- `Networking/Network.swift`, `Network+*` (Category, Channel, Posts, Team, Thread, Users) — REST
  client + typed endpoints. Extend/augment for T28's AuthSession instead of rewriting.
- `Storage/Database.swift`, `Database+*` (Categories, Channels, Mentions, Posts, Preferences,
  System, Team, Thread, Users) — SQLite schema + repositories. Becomes T29's store foundation.
- `Keychain.swift`, `Preferences.swift`, `Constants.swift` — credentials + settings (align with
  existing `SecureVault`).
- `Cache/ImageCache.swift`, `ImageCache+Get.swift`, `ImageCache+InsertRemove.swift`,
  `ImageCacheType.swift` — disk/memory image cache (S18 attachments).
- `PushNotification/PushNotification.swift`, `+FetchData.swift`, `+ProfileImage.swift`,
  `+Signature.swift` — APNs handling incl. signature verification (T43 push path).
- `DataTypes/*` (`Channel`, `Post`, `PostResponse`, `PostThread`, `Team`, `User`, …) — models +
  `Codable`; the `JSONDecode+Extension.swift` decode helper.
- `Date+Extensions.swift`, `String+Extensions.swift`, `Bundle+Extensions.swift`, `Logger.swift`.
- `SessionAttributes/SessionAttributesOutboundHeader.swift` — session attributes (T28).

**Reimplement (do not vendor):**
- `Networking/ShareExtension+Delegate.swift`, `ShareExtension.swift`,
  `ShareExtension+Post.swift` — they bind to the RN app extension; reimplement against our own
  share target (S36) using the same endpoints.
- `PushNotification+Category.swift`, `AckNotification.swift` — adapt to this app's notification
  categories (T43), keep the signature verification verbatim.
- Anything in `GekidouWrapper.swift` — dependency-injection glue for the RN side; not needed.

**Test-first candidates from Gekidou:** `Date+Extensions.swift`, `Storage/Database+*` repository
queries, `PushNotification/PushNotification+Signature.swift` — port as unit-tested Swift modules
before the screens that consume them.

---

## 3. Attribution rule (referenced by the ADR and screen cards)

Every ported file must carry the header from `docs/THIRD_PARTY_NOTICES.md` §3, naming upstream
repo, pinned tag, short SHA, file path, and licence. Behaviour-only references get the lighter
one-line note. **Nothing from AGPL/commercial server trees is ported; no AGPL text enters this
repo.** Reviewers check per `docs/path-b-adr.md` §3 checklist.

---

## 4. Pure-logic port-first list (unit tests before any UI)

These files are deterministic, dependency-light logic. Port them first as testable Swift so the
screen cards inherit verified behaviour:

| Logic | Source path (`M` mobile / `W` webapp, both pinned) | Notes |
|---|---|---|
| Markdown AST transform | `M app/components/markdown/transform.ts` | The core renderer pipeline (commonmark AST → Mattermost entities: mentions, links, hashtags, phone, CJK combining). Port with the same tests (`transform.test.ts` has 400+ cases in-tree). |
| Markdown parsing | `@mattermost/commonmark@0.31.2-0` (BSD-2-Clause) | AST walker in Swift (or a BSD-compatible Swift commonmark port); `mattermost/commonmark-react-renderer` semantics in `M app/components/markdown/markdown.tsx` |
| Block attachment parser | `M app/utils/message_attachment.ts` | Parses `metadata`/attachments into display structs — unit-testable. |
| OpenGraph parser | `M app/utils/opengraph.ts` | URL previews (S11). |
| Date helpers | `M ios/Gekidou/Sources/Gekidou/Date+Extensions.swift` (as-is), `M app/utils/datetime.ts`, `M app/utils/date_utils.ts` | Relative/absolute timestamps, separators (S11, S13, S26). |
| Post list sort/merge | `M app/utils/post_list/index.ts`, `W webapp/channels/src/packages/mattermost-redux/src/utils/post_list.ts` | `combinePost`-style ordering the channel list and threads rely on. |
| Channel compare/sort | `M app/utils/categories.ts`, `M app/utils/channel/index.ts` | Sidebar category order, channel sort (S08). |
| Thread utilities | `M app/utils/thread/index.ts` | Unread/follow math (S13). |
| Emoji | `M app/utils/emoji/helpers.ts`, `M app/utils/emoji/index.ts`, `W webapp/channels/src/utils/emoji.ts` | Name→skin-tone, regexes; emoji JSON data (`app/utils/emoji/emoji.json`) as a bundled resource. |
| Mention parsing | `M app/utils/markdown/index.ts` + `M app/utils/post/index.ts` | Mention keys, `highlightWithoutNotification` (S25). |
| Message attachment types | `M app/client/websocket/index.ts` event handling shapes + `M app/utils/message_attachment.ts` | WS→model mapping (T28). |
| URL  deep-link parse | `M app/utils/deep_link/*`, `M app/actions/remote/permalink.ts` | Permalinks (S12). |
| Phone number | `M app/utils/phone_number.ts` | Linkable phone numbers in markdown. |
| Error model | `M app/client/rest/error.ts` | API error → typed error (T28). |
| Client config | `M app/client/rest/general.ts` (config/license/brand calls) | Config fetch shapes (T28). |

---

## 5. Per-surface map (S01–S40 — one section per inventory surface)

Path shorthand in this section: `M:<path>` = mobile path at `162f2560…`; `W:<path>` = webapp path
at `987e5712…`; "decomposition" always follows §1 rules.

### S01 Login — `native` (T31)
- Sources: `M app/screens/login/`, `M app/constants/websocket.ts`, `M app/client/rest/users.ts`
  (`POST /users/login`, `POST /users/login/type`); boot calls in `M app/client/rest/general.ts`,
  `M app/client/rest/plugins.ts`, `M app/client/rest/properties.ts`. Webapp cross-check:
  `W webapp/channels/src/components/login/`, `W …/components/login/guest_magic_link_card.tsx`,
  `W …/components/login/login.tsx` (behaviour only — this repo's login is native).
- Decomposition: `LoginView` (SwiftUI form) + `LoginViewModel` (`@Observable`: submit, error,
  FIPS/mfa routing). `ServerFormView` (T5) reused for server selection. Desktop interstitial
  (`View in Desktop App / View in Browser`) is a WKWebView hosting the real `{server}/login` — keep
  per inventory S01.
- Logic-first: `M app/utils/helpers.ts` (validation helpers), `M app/client/rest/error.ts`.
- As-is: Gekidou `Networking/Network+Users.swift`. Not ported: none.

### S02 MFA — `native` (T31)
- Sources: `M app/screens/mfa/`, `M app/client/rest/users.ts` (`POST /users/mfa`).
- Decomposition: `MFAView` + `MFAViewModel` (code input, verify, switch-method).
- Logic-first: TOTP check helper if any (server validates; client just formats).
- Not ported: none.

### S03 SSO — `native` (T31); escape hatch if IdP fragile
- Sources: `M app/screens/sso/`, `M app/client/rest/users.ts` (`POST /users/login/sso/code-exchange`).
- Decomposition: `SSOView` (interstitial + redirect orchestration) + `SSOViewModel`; the redirect
  itself can hand off to a webview per ADR.
- Logic-first: `M app/utils/saml_challenge.ts` if needed.

### S04 Signup + forgot/reset — `native` (T31)
- Sources: `M app/screens/forgot_password/`, `M app/screens/onboarding/`, `M app/client/rest/users.ts`,
  `M app/client/rest/tos.ts`.
- Decomposition: `ForgotPasswordView`, `SignupView`, plus `WelcomeView` reuse (T10).
- Not ported: none.

### S05 Server add/edit/select — `native` (already, T5)
- Sources: `M app/screens/server/`, `M app/screens/edit_server/`.
- Decomposition: already-native `ServerFormView`/`ServerURLValidator`; only extend with
  categories/preferences fetch per inventory.
- As-is: existing T5 code (not RN). Not ported: none.

### S06 Terms of service gate — `native` (T31)
- Sources: `M app/screens/terms_of_service/`, `M app/client/rest/tos.ts`.
- Decomposition: `TermsOfServiceView` + `TOSViewModel` (accept/decline).

### S07 Team selection — `native` (T32)
- Sources: `M app/screens/select_team/`, `M app/client/rest/teams.ts`; webapp
  `W webapp/channels/src/components/select_team/`.
- Decomposition: `SelectTeamView` + `SelectTeamViewModel` (`GET /users/{id}/teams`, join).

### S08 Channel sidebar — `native` (T32 rail / T33 list)
- Sources: `M app/screens/home/` (sub-tabs incl. `channel_list`),
  `M app/components/team_sidebar/`, `M app/components/channel_list_row/`,
  `M app/components/channel_item/` (`channel_item.tsx`, `channel_body.tsx`),
  `M app/components/channel_icon/`, `M app/components/custom_status/`,
  `M app/actions/remote/category.ts`, `M app/actions/remote/channel.ts`,
  `M app/client/rest/categories.ts`, `M app/utils/categories.ts`, `M app/utils/channel/index.ts`;
  webapp `W webapp/channels/src/components/sidebar/` (cross-check).
- Decomposition: `SidebarView` (`List` of categories, unread dots, mention badges, mute) +
  `ChannelListViewModel` (incremental sync `last_delete_at`, WS reconcile, category order).
  `ChannelListRowView`, `ChannelIconView`, `TeamSidebarView` maps 1:1 from the RN components.
- Logic-first: `M app/utils/categories.ts`, `M app/utils/channel/index.ts`, status math
  (`M app/utils/user/index.ts`).
- As-is: Gekidou `Storage/Database+Categories.swift`, `Database+Channels.swift`, `Database+Users.swift`.
- Not ported: none.
- **Delivered:** T32 = the team rail (`TeamSidebarView`/`TeamSwitchViewModel`, S07/S08-rail);
  T33 = the channel list (`ChannelSidebarView` + `ChannelSidebarModels`/`Service`/`Coordinator`,
  the quick switcher, favourites, mute, the aggregate footer). See `docs/t33-build-note.md`. On the
  pinned server the layout authority is `/users/{uid}/teams/{tid}/channels/categories` (the sidebar
  is not stored as a `Preferences` row there). Still open on this surface: drag-and-drop reorder
  (T33 writes the same `PUT` from a context menu), category create/rename/delete (S10), and the
  `custom_status` rendering on a row (T34, with the post list's status dot).

### S09 Find / browse channels — `native` (T33)
- Sources: `M app/screens/find_channels/` (`index.tsx`, `filtered_list/`, `unfiltered_list/`,
  `quick_options/`), `M app/screens/browse_channels/`, `M app/client/rest/channels.ts`; webapp
  `W webapp/channels/src/components/browse_channels/browse_channels.tsx`,
  `W …/components/channel_selector_modal/`.
- Decomposition: `FindChannelsView` (search field + result `List`) + `FindChannelsViewModel`
  (autocomplete query debounce, join action).
- Logic-first: channel name filtering (in `M app/utils/channel/index.ts`).

### S10 Create/edit/convert channel — `native` (T33)
- Sources: `M app/screens/create_or_edit_channel/`, `M app/screens/channel_configuration/`,
  `M app/screens/convert_gm_to_channel/`, `M app/client/rest/channels.ts`; webapp
  `W …/components/convert_gm_to_channel_modal/`, `W …/components/channel_name_form_field.tsx`.
- Decomposition: forms as SwiftUI `Form` + per-field VMs.

### S11 Channel view (post list) — `native` (T34) — **core, L/high risk**
- Sources: `M app/screens/channel/` (`channel.tsx`, `channel_content.tsx`,
  `channel_post_list/channel_post_list.tsx`, `channel_post_list/intro/*`),
  `M app/components/post_list/` (`config.ts`, `date_separator/`, `new_message_line/`,
  `more_messages/`, `post/avatar/`, `post/body/body.tsx`, `post/body/content/*`,
  `combined_user_activity/`), `M app/components/markdown/**` (full tree incl. `transform.ts`),
  `M app/utils/post_list/index.ts`, `M app/actions/remote/post.ts`,
  `M app/client/rest/posts.ts`; webapp cross-check `W …/components/channel_view.tsx`,
  `W …/components/post_view/`, `W …/components/markdown/index.ts`, `W …/components/markdown_image/`,
  `W …/components/date_separator*` (behaviour), `W …/components/new_replies_banner/`,
  `W …/components/channel_intro_message/`, `W …/components/combined_system_message/`,
  `W …/components/combined_user_activity_post.tsx`.
- Decomposition: `ChannelView` (header + post list) → `PostListView` (`List` with explicit window,
  §1 rule) → row stack: `PostRowView` (`PostHeaderView`, `PostBodyView`, `PostFooterView`),
  `DateSeparatorView`, `NewMessageLineView`, `MoreMessagesView`, `SystemMessageView`.
  `ChannelViewModel` owns posts, pagination cursor (`before/after/since`), WS insert/delete/update
  ordering, unread marker, jump-to-newest. `PostBodyViewModel` derives rendered blocks from the
  ported markdown AST.
- Logic-first: `transform.ts` port + `message_attachment.ts`, `opengraph.ts`, `post_list/index.ts`,
  `datetime.ts`, `date_utils.ts` — all from §4.
- As-is: Gekidou `Storage/Database+Posts.swift`, `Networking/Network+Posts.swift`,
  `Cache/ImageCache*` (attachments).
- Reimplement: markdown→SwiftUI rendering, windowing, WS reconcile. If latex/table parity is not
  met by release, those exotic renderers fall back to webview (inventory §4, ADR §6.6).
- Not ported: `embedded_bindings/`, `interactive_messages/` Apps plumbing until S34 is built in.

### S12 Permalink — `native` (T36)
- Sources: `M app/screens/permalink/`, `M app/actions/remote/permalink.ts`,
  `M app/utils/deep_link/`, `M app/routes/+native-intent.ts`.
- Decomposition: `PermalinkView` + existing `DeepLinkRouter` (T4); resolves to server/channel/post.
- Logic-first: `M app/utils/permalink_sync.ts`, deep-link parsing.

### S13 Thread RHS + global threads — `native` (T36)
- Sources: `M app/screens/thread/`, `M app/screens/thread_options/`, `M app/screens/global_threads/`,
  `M app/actions/remote/thread.ts`, `M app/client/rest/threads.ts`, `M app/utils/thread/index.ts`;
  webapp `W …/components/rhs_thread/`, `W …/components/threading/thread_viewer/`,
  `W …/components/threading/global_threads/`.
- Decomposition: `ThreadView` (reply panel beside channel or pushed) + `ThreadViewModel`
  (follow/read state, WS `thread_*` reconcile); `GlobalThreadsView` + `GlobalThreadsViewModel`
  (list pagination `since/before/after/page_size/unread/totalsOnly/deleted`).
- Logic-first: `M app/utils/thread/index.ts`; post_list merge (shared with S11).
- As-is: Gekidou `Storage/Database+Thread.swift`, `Networking/Network+Thread.swift`.

### S14 Composer + S15 Autocomplete — `native` (T35)
- Sources: `M app/components/post_draft/` (`post_draft.tsx`, `draft_input/draft_input.tsx`,
  `post_input/`, `send_button/`, `send_handler/`, `quick_actions/`, `uploads/`, `typing/`,
  `archived/`, `read_only/`, `draft_handler/`, `custom_emoji_picker/`),
  `M app/components/autocomplete/` (`autocomplete.tsx`, `at_mention/`, `at_mention_group/`,
  `at_mention_item/`, `channel_mention/`, `emoji_suggestion/`, `slash_suggestion/` incl.
  `slash_suggestion/app_command_parser/`), `M app/screens/edit_post/`, `M app/screens/global_drafts/`,
  `M app/actions/remote/post.ts`, `M app/client/rest/posts.ts`, `M app/client/rest/files.ts`,
  `M app/client/rest/integrations.ts`; webapp `W …/components/advanced_create_comment.tsx`,
  `W …/components/advanced_create_post.tsx`, `W …/components/composer_placeholder.ts`,
  `W …/components/draft_actions/`, `W …/components/draft_row.tsx`, `W …/components/drafts_list/`.
- Decomposition: `ComposerView` (input + toolbar + uploads) + `ComposerViewModel` (draft
  persistence, send/edit/delete, markdown toolbar, scheduled posts, slash commands, `POST /posts`,
  `POST /files` multipart). `AutocompleteView` + `AutocompleteViewModel` (multi-source async race:
  users/channels/emojis/commands; debounce). `EditPostView`, `GlobalDraftsView`.
- Logic-first: slash command parser (`M app/components/autocomplete/slash_suggestion/app_command_parser/app_command_parser.ts`),
  mention/channel regexes (§4).
- As-is: Gekidou `Storage/Database+Posts.swift` (drafts table patterns), `Networking/Network+Posts.swift`.
- Reimplement: keyboard handling (reuse if any existing), attachment upload queue.
- Not ported: burn-on-read editor bits only when disabled (`M app/utils/bor.ts` logic port with feature gate).

### S16 Reactions — `native` (T37)
- Sources: `M app/screens/reactions/`, `M app/components/common_post_options/` (base_option/…),
  `M app/actions/remote/reactions.ts`, `M app/client/rest/posts.ts` (reaction endpoints).
- Decomposition: `ReactionsView` (summary popover w/ avatars) + `ReactionBarView` on posts;
  `ReactionsViewModel` (add/remove, WS `reaction_added/removed`).

### S17 Emoji picker + custom emoji — `native` (T37)
- Sources: `M app/screens/emoji_picker/`, `M app/components/emoji_category_bar/`,
  `M app/components/emoji/` (`emoji.tsx`, `index.tsx`), `M app/utils/emoji/` (`emoji.json`,
  `helpers.ts`, `index.ts`, `prefetch.ts`), `M app/actions/remote/custom_emoji.ts`,
  `M app/client/rest/emojis.ts`; webapp `W …/components/emoji_picker/`, `W …/components/emoji_list/`.
- Decomposition: `EmojiPickerView` (grid + search + frequent row) + `EmojiPickerViewModel`
  (custom emoji fetch/cache, recent-emojis preference writes).
- Logic-first: `M app/utils/emoji/helpers.ts`; emoji JSON as bundled resource (§4).

### S18 File/image viewer + gallery — `native` (T38)
- Sources: `M app/screens/gallery/`, `M app/screens/pdf_viewer/`, `M app/screens/code/`,
  `M app/screens/table/`, `M app/screens/latex/`, `M app/components/files/` (`file.tsx`,
  `image_file.tsx`, `audio_file.tsx`, `video_file.tsx`, `document_file.tsx`, `file_icon.tsx`,
  `files.tsx`, `file_info.tsx`, `file_options_icon.tsx`, `image_file_overlay.tsx`,
  `file_filter.tsx`), `M app/client/rest/files.ts`, `M app/utils/file/`, `M app/utils/gallery/`;
  Gekidou `Cache/ImageCache*`; webapp `W …/components/file_attachment/`,
  `W …/components/file_attachment_list/`, `W …/components/file_preview_modal/`,
  `W …/components/file_info_preview.tsx`, `W …/components/file_search_result_item.tsx`,
  `W …/components/files/`.
- Decomposition: `GalleryView` (paging), `PDFViewer` (native `PDFKit`), `FileRowView`,
  `ImageFileView`, `AudioFileView`, `VideoFileView`, `DocumentFileView`, `FileIconView`;
  `FileViewModel` (signed-URL download, cache via ImageCache, share/open external).
- Logic-first: `M app/utils/files.tsx` (file icon/type mapping), `M app/utils/document/*` (extension
  → type). Reimplement: PDF/code/table/latex renderers; exotic renderers may stay webview per
  inventory §4.

### S19 Search — `native` (T39)
- Sources: `M app/screens/home/search/`, `M app/components/search/`, `M app/actions/remote/search.ts`,
  `M app/client/rest/posts.ts` (`/posts/search`), `M app/utils/search/`; webapp
  `W …/components/search/`, `W …/components/search_bar/`, `W …/components/search_results/`.
- Decomposition: `SearchView` + `SearchViewModel` (query DSL `in:/from:/before:`, recent searches,
  results list reuse S12 permalink navigation for jumping to results).
- Logic-first: search param builder (from `app/utils/search/`), flagged fetch
  (`M app/client/rest/posts.ts` `/users/{id}/posts/flagged`).

### S20 Saved messages — `native` (T39)
- Sources: `M app/screens/home/saved_messages/`, `M app/client/rest/preferences.ts`
  (`grouped_saved_post_<id>`), `M app/actions/remote/preference.ts`.
- Decomposition: `SavedMessagesView` (flagged list) + `SavedMessagesViewModel` (flag set/clear via
  preferences, WS `preference_changed`).

### S21 Pinned messages — `native` (T39)
- Sources: `M app/screens/pinned_messages/`, `M app/client/rest/posts.ts` (`/channels/{id}/pinned`).
- Decomposition: `PinnedMessagesView` + `PinnedMessagesViewModel` (pin/unpin, WS `post_edited`).

### S22 Channel info + add members — `native` (T40)
- Sources: `M app/screens/channel_info/` (large tree incl. tabs),
  `M app/screens/channel_add_members/`, `M app/screens/channel_notification_preferences/`,
  `M app/screens/channel_share/`, `M app/screens/channel_bookmark/`,
  `M app/client/rest/channels.ts`, `M app/client/rest/channel_bookmark.ts`,
  `M app/actions/remote/channel_bookmark.ts`; webapp `W …/components/channel_info_rhs.tsx`,
  `W …/components/channel_bookmarks/`, `W …/components/channel_notifications_modal/`,
  `W …/components/channel_members_modal/`.
- Decomposition: `ChannelInfoView` (header info + member list + files + settings tabs) +
  `ChannelInfoViewModel` (stats, member paging, notification prefs, bookmark CRUD).

### S23 Members / member list + manage — `native` (T40)
- Sources: `M app/screens/manage_channel_members/`, `M app/screens/invite/`,
  `M app/screens/join_team/`, `M app/screens/create_direct_message/`,
  `M app/client/rest/channels.ts` (members endpoints), `M app/client/rest/teams.ts`,
  `M app/client/rest/users.ts`; webapp `W …/components/channel_members_rhs.tsx`,
  `W …/components/member_list_channel/`, `W …/components/member_list_team/`,
  `W …/components/invitation_modal/`.
- Decomposition: `MemberListView` + `MemberListViewModel` (search, roles, remove), `InviteView`,
  `CreateDirectMessageView`.

### S24 Profile popover + status + custom status — `native` (T41)
- Sources: `M app/screens/user_profile/`, `M app/screens/custom_status/`,
  `M app/screens/custom_status_clear_after/`, `M app/components/custom_status/`,
  `M app/client/rest/users.ts` (status/custom), `M app/actions/remote/user.ts`; webapp
  `W …/components/user_profile/`, `W …/components/profile_popover/`, `W …/components/custom_status/`.
- Decomposition: `UserProfileView` (sheet) + `UserProfileViewModel` (bio/roles/common channels,
  custom status set/clear with duration), `CustomStatusView`.
- Logic-first: `M app/utils/user/index.ts` status helpers.

### S25 Mentions inbox — `native` (T42)
- Sources: `M app/screens/home/recent_mentions/`, `M app/actions/remote/notifications.ts`,
  `M app/utils/post/index.ts` (mention key matching), `M app/constants/websocket.ts`.
- Decomposition: `MentionsView` + `MentionsViewModel` (local aggregation of WS `posted` with
  mention filter + `post_unread`); in-app notification toast (`M app/screens/in_app_notification/`,
  `M app/screens/snack_bar/`) as `OverlayView` reused app-wide.

### S26 Drafts + scheduled posts — `native` (T35/T36)
- Sources: `M app/screens/global_drafts/`, `M app/screens/draft_scheduled_post_options/`,
  `M app/screens/scheduled_post_options/`, `M app/screens/reschedule_draft/`,
  `M app/actions/remote/scheduled_post.ts`, `M app/client/rest/scheduled_post.ts`,
  `M app/utils/scheduled_post/`, `M app/utils/draft/`; webapp `W …/components/drafts_and_schedule_posts*`,
  `W …/components/draft_row.tsx`, `W …/components/draft_actions/`.
- Decomposition: `GlobalDraftsView` + `ScheduledPostOptionsView` + VMs (recurrence pickers).
- Logic-first: `M app/utils/scheduled_post/index.ts` (recurrence math).
- As-is: drafts table patterns from Gekidou `Database+Posts.swift`.

### S27 User settings — `native` (already + T41)
- Sources: `M app/screens/settings/` (full tree: `settings.tsx`, `display*`, `notification*`,
  `advanced`, `about`, `report_problem`), `M app/client/rest/preferences.ts`,
  `M app/client/rest/users.ts`, `M app/actions/remote/preference.ts`;
  webapp `W …/components/user_settings/` cross-check (behaviour only).
- Decomposition: keep existing native `SettingsView` (T11); add sections per mobile settings tree.
- As-is: existing T11 code. Not ported: none (settings stay native per ADR §6.5).

### S28 Edit profile — `native` (T41)
- Sources: `M app/screens/edit_profile/`, `M app/client/rest/users.ts` (profile/image),
  `M app/actions/remote/user.ts`, `M app/utils/custom_profile_attribute.ts`,
  `M app/client/rest/custom_profile_attributes.ts`.
- Decomposition: `EditProfileView` + VM (name/username/email/roles, picture, custom attributes).

### S29 System Console — `webview (T46) always`
- Sources: none ported. Disposition: webview-only (ADR §2.3; absent from the mobile client by
  design). Not ported: **entirely**.

### S30 Plugin screens — `webview (T46) always`
- Sources: none ported (mobile has no generic plugin renderer; plugins ship web UIs). The Apps
  framework screens below are the only native-adjacent subset (S34).

### S31 Boards — `webview (T46) always`
- Not ported: `M app/products/boards` (plugin client) stays out of the native surface. The webview
  renders it. No files ported.

### S32 Playbooks — `webview (T46) always`
- Not ported: `M app/products/playbooks` stays out of the native surface. No files ported.

### S33 Calls — `webview (T46) always, may cut for v1`
- Not ported: `M app/products/calls` (WebRTC VoIP, broadcast extension) stays webview-only (T44/T16).

### S34 Apps framework — `hybrid` (native where feasible, webview fallback)
- Sources: `M app/screens/apps_form/`, `M app/screens/dialog_router/`,
  `M app/screens/integration_selector/`, `M app/components/autocomplete/slash_suggestion/app_command_parser/app_command_parser.ts`,
  `M app/utils/apps.ts`, `M app/utils/dialog_utils.ts`, `M app/utils/dialog_conversion.ts`,
  `M app/utils/interactive_dialog_adapter.ts`, `M app/client/rest/apps.ts`,
  `M app/client/rest/integrations.ts`; webapp `W …/components/apps_form/*` (cross-check).
- Decomposition: `AppsFormView` (message-attachment-style form), `DialogRouterView`,
  `IntegrationSelectorView`, each with a VM (bindings/call, dialog submit/lookup).
- Not ported: full Apps runtime; unknown `custom_*` plugin events tolerated, not modeled (§2 WS).

### S35 Notifications (local + push) — `native` (T43)
- Sources: `M app/screens/in_app_notification/`, `M app/actions/remote/notifications.ts`,
  `M app/utils/push_proxy.ts`, `M app/utils/notification/`; Gekidou `PushNotification/*` as-is
  (incl. `+Signature.swift`); this repo's `Core/NotificationWorker.swift` (T8) stays.
- Decomposition: `PushNotificationService` (APNs payload → deep link), `LocalNotificationManager`
  (mention/unread), badge via `SessionStore` (T8). Real APNs blocked on host — gated tests.

### S36 Deep links / share extension — `native` (already + T43)
- Sources: `M app/routes/+native-intent.ts`, `M app/routes/+native-intent.test.ts`,
  `M share_extension/` (repo-root share extension tree, `share_extension/components/channel_item/`,
  etc.); existing `Core/DeepLinkRouter.swift` (T4) stays.
- Decomposition: extend `DeepLinkRouter` with remaining routes; `ShareExtensionView` reimplemented
  against Gekidou share-network endpoints (`Networking/ShareExtension+Post.swift` as reference,
  reimplemented per §2).

### S37 Onboarding / welcome + join team — `native` (already + T31)
- Sources: `M app/screens/onboarding/`, `M app/screens/join_team/`, `M app/client/rest/teams.ts`;
  existing `UI/WelcomeView.swift` (T10) stays.
- Decomposition: `WelcomeView` reuse; add `JoinTeamView` + VM (invite links, `POST /teams/members`).

### S38 Post options (long-press menu) — `native` (T34/T37)
- Sources: `M app/screens/post_options/`, `M app/components/common_post_options/`,
  `M app/actions/remote/post.auxiliary.ts`, `M app/client/rest/posts.ts` (burn/ack/translate),
  `M app/utils/bor.ts`, `M app/screens/show_translation/`.
- Decomposition: `PostOptionsView` via `contextMenu` on `PostRowView` + `PostOptionsViewModel`
  (copy/edit/delete/pin/flag/mark unread/translate/reply; burn-on-read variants feature-gated).
- Logic-first: `M app/utils/bor.ts`, `M app/utils/mix.ts`.

### S39 Custom profile attributes — `native` (T41), feature-gated
- Sources: `M app/screens/edit_profile/` (custom attributes), `M app/actions/remote/custom_profile.ts`,
  `M app/client/rest/custom_profile_attributes.ts`, `M app/utils/custom_profile_attribute.ts`,
  `M app/client/rest/properties.ts` (fields fetch).
- Decomposition: `CustomProfileFieldsView` + VM; gate on server feature/probe (ADR §5).

### S40 Scheduled posts (separate) — `native` (T35)
- Sources: `M app/actions/remote/scheduled_post.ts`, `M app/client/rest/scheduled_post.ts`,
  `M app/utils/scheduled_post/`, screens `M app/screens/scheduled_post_options/`,
  `M app/screens/reschedule_draft/`; WS `scheduled_post_*` in `M app/constants/websocket.ts`.
- Decomposition: `ScheduledPostOptionsView` + `RescheduleDraftView` + VMs (create/recurrence,
  list from `GET /posts/scheduled/team/{team_id}`).

---

## 6. Explicitly NOT ported (stands for every surface above)

- **Server** (Go) code from `mattermost/mattermost` `server/`, `enterprise/` — AGPL/commercial;
  never copied, per ADR §3.
- **System Console (S29), generic plugin screens (S30), Boards (S31), Playbooks (S32), Calls (S33)** —
  webview-only (T46); no native port, no files ported.
- **Apps framework runtime (S34)** — hybrid only: native forms/dialogs where listed; the Apps
  protocol/bindings machinery itself is not ported (REST calls flow through T28 as plain
  `/plugins/com.mattermost.apps/api/v1/*`).
- **`marked`** (webapp parser) and **`dynamic-virtualized-list`** — not used by the pinned mobile
  client; the Swift layer ports `@mattermost/commonmark` AST semantics and uses SwiftUI windoiwng
  (§4, THIRD_PARTY_NOTICES §2 correction).
- **RN bridge / `GekidouWrapper.swift` / `react-native-*` libraries** — the RN runtime itself is not
  ported; Gekidou's pure Swift files are (see §2).

---

## 7. Evidence — pinned-tree resolution spot-checks

Verified 2026-10-24 via `gh api repos/<org>/<repo>/contents/<path>?ref=<sha>` at the pinned SHAs:

| Row citing | Path | Resolves at pin |
|---|---|---|
| §4 markdown transform | `mattermost/mattermost-mobile` `app/components/markdown/transform.ts` @ `162f2560…` | yes (sha `14e2e7ebf8e7179b65c45bf27aecb83b69621e49`, 16754 B) |
| §5 S11 | `mattermost/mattermost-mobile` `app/screens/channel/channel.tsx` @ `162f2560…` | yes (tree listing has 41 files under `app/screens/channel/`) |
| §5 S01 | `mattermost/mattermost` `webapp/channels/src/utils/markdown/index.ts` @ `987e5712…` | yes (sha `3bafce8b4ec8feaaae2fe5d7b605546b744ad057`, 1883 B) |
| §2 Gekidou | `mattermost/mattermost-mobile` `ios/Gekidou/Sources/Gekidou/PushNotification/PushNotification+Signature.swift` @ `162f2560…` | yes (sha `4cc0ac3a3678e86d4913010f0fa1b82ccde6a691`, 9294 B) |

Full-tree validation: every `M:` path cited above exists in the recursive tree of the mobile pin
(5398 entries), every `W:` path in the monorepo pin tree (18080 entries); verified by script
against the pinned git trees, not by memory (T25b run log).
