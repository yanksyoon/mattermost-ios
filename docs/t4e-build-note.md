# T4e — slash commands in the native composer

Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (`162f2560d0e1df073220f7701d5a67cc17c8abeb`)
— `app/components/autocomplete/slash_suggestion/*`, `app/actions/remote/command.ts`,
`app/client/rest/integrations.ts`, `app/hooks/handle_send_message.ts`, `app/actions/websocket/event.ts`.
Licence Apache-2.0; no upstream source copied.

## What the server does (measured, not assumed)

`scripts/t4e_slash_probe.py` against the 9.11.19 fixture (`127.0.0.1:8065`), printed in full:

| call | result |
|---|---|
| `GET /commands?team_id=<id>` | 200, **bare array**, 33 records (`trigger`, `auto_complete`, `auto_complete_hint`, `auto_complete_desc`, `display_name`) |
| `GET /commands?team_id=` (empty) | **400** "Invalid or missing team_id in request body." |
| `POST /commands/execute` `/help` | 200 `{"response_type":"ephemeral","text":…}`; **nothing is stored** — the channel's newest posts are unchanged |
| socket | `ephemeral_message`, `data.post` a **JSON string**, `type=system_ephemeral`, `broadcast.user_id` = the caller, `seq` present |
| `POST /commands/execute` `/nosuchcommand` | **404**, body `"Command with a trigger of 'nosuchcommand' not found. To send a message beginning with \"/\", try adding an empty space at the beginning of the message."` |

The last row is why `APIClient.perform` no longer collapses every 404 to `MMError.notFound` when a
caller asks for the server's message: for a command, the 404 body **is** the answer shown to the
reader.

## The implementation

- `ComposerCommands.swift` (new) — `MMCommand`, `ComposerCommandList` (`offered`, `suggestions`,
  `command(in:)`, argument rules), `SlashCommandCatalogue` (one fetch per team, process-wide,
  concurrent callers coalesce, failures are not cached).
- `ComposerModels.swift` — `ComposerTrigger.Kind.slash` (only at the start of the first word, only
  outside edit mode) and `ComposerSuggestion.hint` for the server's argument placeholder.
- `ComposerViewModel.swift` — `/` routes `send()` to command execution instead of a post; a failed
  command keeps the text and the server's sentence; `PendingCommand.slash` makes Retry re-run the
  **command**, not the text it has since become; an edit box never offers or runs commands.
- `ComposerView.swift` — rows carry the trigger, the hint and the description; the command glyph.
- `ComposerAPI.swift` / `ComposerService.swift` — `GET /commands`, `POST /commands/execute`.
- `SocketEvent.swift` — `.ephemeralMessage(MMPost)`; `ChannelViewModel` appends it as a row,
  `PostListModels` marks it `isEphemeral` (markdown body, not the one-line system notice),
  `PostRowView` draws it with "Only visible to you", and `TeamSocketScope` scopes it by channel.

Hidden-on-mobile triggers (`collapse`, `expand`, `logout`, `shortcuts`, `search`, `settings`) are
filtered out, matching upstream: a row that can only answer "not found" is worse than no row.

## Evidence

- Unit: `MattermostTests/T4eSlashCommandsTests.swift` — 70 tests (parser, completion, list decode,
  cache, execute encoding, 404 sentence, socket frame, view-model send/retry/drafts/autocomplete,
  channel row insertion). Regression batch over the composer/socket/sidebar suites: 161 tests,
  0 failures.
- Live: `MattermostUITests/T4eSlashCommandUITests.swift` — 3 tests, **3 run / 0 skipped / 0 failed**
  against the real server: the list opens with the server's hint, `/invite` completes to `/invite `
  without sending, `/help` executes and its answer appears as an ephemeral row (with the socket
  proved live by a REST-posted probe message first), and `/nosuchcommand` shows the server's own
  sentence with the words kept and no post created.

## Known limitation (deliberate, measured)

The answer is appended at the bottom of the timeline; with the keyboard still up it can sit below the
fold, and the pane scrolls to it only when the reader is already at the bottom. The live test nudges
the list before asserting, so the behaviour is visible rather than hidden. Bringing a command's
answer into view automatically is a separate change to the scroll policy, not to slash commands.
