# T4f — the typing indicator ("X is typing…")

Behaviour reference: mattermost/mattermost-mobile @ v2.45.0
(`162f2560d0e1df073220f7701d5a67cc17c8abeb`) — `app/components/post_draft/typing/index.tsx`,
`app/components/post_draft/post_input/post_input.tsx`, `app/actions/websocket/users.ts`,
`app/client/websocket/index.ts`, `app/constants/websocket.ts`. Licence Apache-2.0; no upstream source
copied. Attribution entry: `docs/THIRD_PARTY_NOTICES.md` §24.

## What the server does (measured, not assumed)

`scripts/t4f_typing_probe.py` against the 9.11.19 fixture (`127.0.0.1:8065`), output kept in
`build/logs/t4f-live-5.log`'s sibling probe run; the facts:

| call / frame | result |
|---|---|
| `GET /config/client?format=old` (authenticated) | `EnableUserTypingMessages = "true"`, `TimeBetweenUserTypingUpdatesMilliseconds = "5000"`, `MaxNotificationsPerChannel = "1000"` — **all strings**, not numbers |
| the same read unauthenticated | the typing keys are **absent** (no defaults to be had by asking) |
| buddy sends `user_typing {channel_id, parent_id: ""}` | every *other* account in the channel receives `typing` with **`broadcast.channel_id`** = the channel; `data` carries only `parent_id` and `user_id` |
| the sender's own socket | **omitted** (`broadcast.omit_users` names the typist) — a client never has to guess whether "you are typing" is itself |
| `parent_id` omitted by the sender | the server normalises it to `""` in the broadcast |
| buddy sends `user_typing {channel_id, parent_id: <root>}` | the root is echoed verbatim in `data.parent_id` |
| any client sends anything else | there is **no** "stopped typing" action; the measured set is `user_typing` only |

The first column's third line is the one that decided the design of the receive path: a frame is a
**heartbeat**, not a state change, and its expiry is the receiver's own timer.

## The implementation

- `Mattermost/Core/MM/MMTypingSettings.swift` (new) — the three keys, decoded from string, number or
  bool spellings; documented server defaults used **only** where a key is absent.
- `Mattermost/UI/Native/Composer/TypingIndicator.swift` (new) — one pane's row: the typist list,
  per-frame expiry with a generation guard (a superseded frame's timer cannot clear a newer one),
  `accepts(_:)` addressing by channel **and** `parent_id`, `retarget(channelID:)` for a thread opened
  from a permalink with no channel id, `rename(userID:name:)` for the lazy profile load, and
  `TypingLabel.sentence(_:)` — upstream's two i18n strings and its three-name cap
  (`splice(3)` + `pop` ⇒ "Ana, Bo and Cy are typing...").
- `Mattermost/UI/Native/Composer/ComposerTypingTransport.swift` (new) — `ComposerTypingTransporting`
  (settings + one frame) and `SessionComposerTypingTransport`, which reads `/config/client` once per
  composer (a failed read is **not** cached and answers `nil`), sends on the rail's existing socket,
  and never opens a second connection.
- `ComposerViewModel.swift` — `typing:` seam, the announce gate inside `textChanged`, and
  `resetTypingAnnouncement()` after send, cancel-edit, load-for-edit, leave-edit and clear.
- `ComposerView.swift` — `typing:` / `typingRowIdentifier:` parameters and `TypingRow`, an
  `@ObservedObject` row above the input that draws nothing at all when nobody is typing (upstream's
  `StatusIndicator(visible:)`). The row carries the **pane's** identifier (`channelComposer.typing` by
  default, `threadComposer.typing` in a thread): both panes can be mounted at once on a wide layout, and
  one identifier for both would make "the row exists" true because of the *other* pane.
- `ChannelView.swift` / `ThreadView.swift` — each pane hands its own `model.typing` to its composer;
  the thread pane also passes `threadComposer.typing`.
- `ChannelViewModel.swift` / `ThreadViewModel.swift` — `typing` indicator, `EventOutcome.typing`, the
  self-filter, the `parent_id` match (`""` for the channel, `rootID` for the thread), a one-shot
  `/config/client` read for the row's window, and a lazy `loadProfiles` so an unnamed frame becomes a
  name without a per-frame REST call.
- `ChannelPaneCoordinator.swift` / `ThreadCoordinator.swift` — one `SessionComposerTypingTransport` per
  server, shared by the pane and its composer, cleared on `deactivate`.
- `TeamSidebarCoordinator.swift` — `sendTyping(for:channelID:parentID:)` on the server's one socket
  (no connection is opened for a typing frame).
- `Mattermost/Core/MM/SocketEvent.swift` — **the decode fix** below.
- `Mattermost.xcodeproj/project.pbxproj` — `MMTypingSettings.swift` added to the `Core/MM` group and
  the Sources phase (that group is not file-system-synchronised; the `UI/Native` ones are).

### The send gate (upstream's four conditions)

`post_input.tsx:271-279` is:

```ts
newValue && lastTypingEventSent.last + interval < Date.now()
         && membersInChannel < maxNotificationsPerChannel && enableUserTypingMessage
```

implemented as: non-empty, not in edit mode (upstream wires typing from `post_draft` only), the
server's `EnableUserTypingMessages` **once known** (`nil` answer ⇒ silence, retried on the next
keystroke), and at most one frame per `TimeBetweenUserTypingUpdatesMilliseconds`. The send is
**leading-edge**: the first keystroke of a message goes out at once, then the interval throttles.

The one gate this client cannot evaluate yet is `membersInChannel < MaxNotificationsPerChannel`: no
member count is modelled anywhere (`grep memberCount` ⇒ nothing; `MMChannel` has no `member_count`),
and this client does not read one just to decide whether to announce. The value is parsed and carried
on `MMTypingSettings` so the gate has somewhere to land when a count exists; today it is inert and is
recorded as a limit rather than pretended away. (The fixture channel has two members; the threshold is
1000.)

### The bug the live suite found

`SocketEvent.swift` decoded a `typing` frame's channel from **`frame.data["channel_id"]`**. The real
frame — measured, and the reason upstream reads `msg.broadcast.channel_id` — carries the channel only
in `broadcast`, so every frame decoded `channelID == ""`, the active-team scope refused an
unattributable channel, and the row never appeared. The first live run failed on exactly that
(`build/logs/t4f-live-1.log`, `testAnotherUsersFrameDrawsTheRowAboveTheComposerAndExpires`), the
decode now reads `data.channel_id` first and falls back to `broadcast.channel_id`, and
`testTheServerNamesTheChannelInTheBroadcastNotInData` pins the measured JSON verbatim.

## Evidence

Verified in an **isolated worktree** (`git worktree`, HEAD `de59f71` + only this card's hunks), because
six other cards were editing the shared checkout at the same time and its app target did not compile
(their half-finished `ChannelInfo`/`ConvertGM` work). The worktree is what these runs built:

- Unit: `MattermostTests/T4fTypingTests.swift` — **23 tests, 0 failures**
  (`build/logs/t4f-final-unit.log`, xcresult in `~/Library/Developer/Xcode/DerivedData/mattermost-ios-t4f`):
  the send gate (first keystroke, burst inside the interval, the server's 30 s value, disabled, no
  answer yet, failed read then retry, reply parent, edit silence, send/clear reset), the sentence (one
  name, two names in arrival order, re-appearance moves the typist last, three-name cap, unnamed ⇒
  "Someone", rename in place), the expiry (fires on the server's interval; a newer frame survives the
  older timer), the addressing (channel vs thread, retarget), the wire shape (measured frame verbatim),
  and both panes (a frame reaches the right row, another thread's frame does not).
- Live: `MattermostUITests/T4fTypingUITests.swift` — **3 tests, 0 failures, 0 skipped**
  (`build/logs/t4f-final-live.log`) against Mattermost **9.11.19** at `127.0.0.1:8065`, with `t43buddy`
  on the other end of the socket:
  1. typing in the channel composer reaches `t43buddy` as a `user_typing` frame naming the channel,
     with an empty `parent_id`, and a burst inside the interval adds no second frame;
  2. a frame from `t43buddy` draws "Terry Buddy is typing..." (the name read back from `/users/{id}`
     and compared with the pane's own display rule), a **thread**-addressed frame does not draw in
     the channel pane, and the row clears itself on the server's window;
  3. typing in a thread pane sends `parent_id` = the thread root, **and** a frame from `t43buddy` with
     that root draws the thread's own row (`threadComposer.typing`) named "Terry Buddy is typing...".
- Regression: the isolated build compiles the whole app and both test bundles. The composer/socket
  suites (`T35*`, `T34*`, `T36*`, `T37*`, `T43*`, `T4e*`, `T54*`) were not re-run as a batch in this
  card — the only shared surface touched is `SocketEvent.typing`'s decode, whose previous behaviour was
  `""` for every real frame (i.e. never delivered), pinned by the new unit case.

## Limits that stay

- **Member-count gate** as above: parsed, not applied.
- **Display name**: the row uses `PostListDerivation.displayName` (nickname → first+last → username),
  the rule every post row in this client uses. Upstream resolves the name through
  `displayUsername(…, teammateNameDisplay, …)`, i.e. the server's `TeammateNameDisplay` setting; this
  client does not read that setting anywhere, so the row follows the app's own rule consistently and
  would differ from upstream on a server configured to show usernames. Recorded as a gap, not a choice.
- **No localization catalogue**: the iOS repo has no `.strings`/`.xcstrings` resources, so the two
  sentences are composed in Swift exactly as upstream's `en.json` spells them ("...", and the
  three-name join with ", " and " and "). A localized build would need the catalogue first.
- **First keystroke vs. the socket handshake**: a frame sent while the rail's socket is still
  connecting is dropped by design (`SocketClient.send`), and upstream has the same characteristic
  (`client?.sendUserTypingEvent`). The live send test therefore retries once, which is what a reader's
  next word does.
- **Timing**: expiry is the server's interval, not a client constant, but the row appears at the
  sender's leading edge — measured end-to-end at roughly 0.3–1 s on loopback.
