# t_08826621 — what a slash command's answer carries (and why `/gif` "did nothing")

Card: kanban `t_08826621`. Branch: `fix/t_08826621` off `origin/main`.
Everything below is measured, not assumed: the fixture is the local Mattermost **9.11.19** container
(`mm-perf`, `http://127.0.0.1:8065`), and the two scripts named here are in the repo.

---

## 1. The complaint, and what is actually true

"Plugin commands like `/gif` do nothing when sent from the native composer."

Three separate facts, and only one of them was a client bug:

1. **There is no `/gif` command on this fixture.** `GET /commands?team_id=…` answers 37 rows and none
   is `gif`; the server's own autocomplete for `/gif` returns 0 rows
   (`scripts/t88_slash_plugin_probe.py`, `probe3.txt:17`). Sending it answers
   `404 api.command.execute_command.not_found.app_error` with the sentence
   *"Command with a trigger of 'gif' not found. …"* — which the composer already showed and already
   kept in the box. On a server with the GIF plugin installed, `/gif` is a **plugin** command and takes
   exactly the path in (2).
2. **Real plugin commands do execute** — `/call help`, `/playbook list` answer `200`, carry an
   `ephemeral_message` frame, and the pane already drew it. This part was not broken.
3. **Half of every answer was decoded and then dropped.** The composer read
   `ComposerCommandResponse` (which already had `trigger_id`, `goto_location`, `extra_responses`) and
   used only `text`. So:
   - a command that asks the server to open a **dialog** (`/call start` on a call-less server, any
     apps/plugin form) got its dialog frame and had nobody to hand it to;
   - a command that answers with **`goto_location`** never moved the reader;
   - a line that belongs to an **app binding** (upstream's `/gif` on an apps server) was posted to
     `POST /commands/execute` — the one thing upstream never does — where the server answers
     "Command with a trigger of 'gif' not found" *for a command the server has*.

## 2. The measured server contract

Probe: `python3 scripts/t88_slash_plugin_probe.py` (login → list commands → execute each kind → read
the socket frames). Stub integration: `scripts/t88_slash_stub.py` (host port 8099) + registers four
commands with `scripts/t88_slash_register.py`. The container reaches the host stub because
`ServiceSettings.AllowedUntrustedInternalConnections = host.docker.internal` (**dev fixture only**;
revert with `mmctl config set ServiceSettings.AllowedUntrustedInternalConnections ""`).

Exact bodies (from `probe3.txt`, trimmed to the interesting keys):

```
POST /commands/execute  {"channel_id":"64d95e7oipf4jjk9qrxp8ad93e","command":"/call help",
                         "team_id":"ocz148uck3r88dcjikj497bosh"}
200 {"attachments":null,"channel_id":"","extra_responses":null,"goto_location":"",
     "icon_url":"","props":null,"response_type":"ephemeral","skip_slack_parsing":false,
     "text":"Invalid subcommand: help","trigger_id":"4goh4mohfign5puquprmfwe19c",
     "type":"","username":""}
socket ephemeral_message: type='system_ephemeral' root='' message='Invalid subcommand: help'

POST /commands/execute  {"command":"/t88multi", …}
200 {… "extra_responses":[{"response_type":"ephemeral","text":"t88 multi: second (ephemeral)", …},
                          {"response_type":"in_channel","text":"t88 multi: third (in channel)", …}],
     "response_type":"ephemeral","text":"t88 multi: first (ephemeral)",
     "trigger_id":"parqsmnjy7nc8mthhyhnak3o1r", …}
socket ephemeral_message: message='t88 multi: first (ephemeral)'
socket ephemeral_message: message='t88 multi: second (ephemeral)'
socket posted:            message='t88 multi: third (in channel)'

POST /commands/execute  {"command":"/t88goto", …}
200 {… "goto_location":"http://127.0.0.1:8065/perf/channels/town-square",
     "text":"t88 goto: taking you to town-square","trigger_id":"rrwoxkwmr3bqbj88nc3aekid7y"}
socket ephemeral_message: message='t88 goto: taking you to town-square'      ← no location here

POST /commands/execute  {"command":"/t88dialog", …}
200 {… "text":"t88 dialog: asked the server to open one (HTTP 200)",
     "trigger_id":"66hktd5gpirap8aj9a1tow8kqw"}
socket open_dialog: trigger_id='66hktd5gpirap8aj9a1tow8kqw' title='T88 stub dialog'

POST /commands/execute  {"command":"/nosuchcommand", …}
404 {"id":"api.command.execute_command.not_found.app_error",
     "message":"Command with a trigger of 'nosuchcommand' not found. To send a message beginning
                with \"/\", try adding an empty space at the beginning of the message.", …}

POST /commands/execute  {"command":"/help", …}
200 {… "trigger_id":"", …}                       ← a built-in's answer carries NO trigger id
```

Four rules fall out of that, and each one is now a test:

1. **`trigger_id` is the dialog's key.** `open_dialog` carries exactly the id the answer carried, so the
   id has to survive the send. A built-in's is `""` and must not be presented.
2. **`goto_location` is in the answer only.** No socket frame repeats it — the client is the only thing
   that can navigate. Upstream follows it **except** for a line starting with `/leave`
   (`handle_send_message.ts:244`).
3. **`extra_responses` need no client code**: the server emits each one as its own `ephemeral_message`
   or `posted` frame. What the client must not do is *also* invent a row (it does not) or drop the
   second ephemeral frame.
4. **`parent_id` rides beside `root_id`** (upstream `command.ts:41-46`). A *custom* HTTP integration
   never sees either id — the server forwards a fixed field set — but a **plugin** command gets the
   whole `CommandArgs`, which is what `args.ParentId` reads.

Also measured, and the reason the apps split is written the way it is:

- `FeatureFlagAppsEnabled` is **`true`** on this fixture while `/plugins/com.mattermost.apps/api/v1/bindings`
  **404s** (no apps plugin installed). So the flag means "the framework is switched on", never "an app
  command exists" — and a 404 on bindings must read as "no app commands", not as a failure.
- `GET /commands` lists plugin commands (`call`, `playbook`) with `auto_complete: true`,
  `plugin_id: ""`, an empty `id` and an `autocomplete_data` block; custom integrations carry a real
  `id`. Both kinds are in the same list, so the `/` suggestion list needed no change.

## 3. What changed

| File | Change |
|---|---|
| `Mattermost/UI/Native/Composer/ComposerCommands.swift` | `ComposerCommandBody.parentId` (defaults to `rootId`, encoded only when present); `ComposerAppsPosture`; `ComposerCommandDestination`; `ComposerCommandRouting.destination(for:posture:)` (upstream's `isAppCommand`, trailing-space rule and longest-label win) and `ComposerCommandRouting.followsGotoLocation(_:)`; the sentence for an app line this client cannot run |
| `Mattermost/UI/Native/Composer/ComposerAPI.swift` | `clientConfigFlag(_:)` → `GET /config/client?format=old`; `appsCommandLabels(userID:channelID:teamID:)` → the apps bindings, walked as raw JSON so an unfamiliar shape cannot throw on the send path |
| `Mattermost/UI/Native/Composer/ComposerService.swift` | `appsPosture(...)` on the protocol (with a "no app commands" default) and the session implementation: config flag first, bindings second, every failure meaning "no app commands", cached for the life of the composer's service |
| `Mattermost/UI/Native/Composer/ComposerViewModel.swift` | `performCommand` classifies **before** sending (on the line as typed), refuses an app line with `ComposerCommandRouting.appRuntimeUnavailable` and **no request**, hands `triggerID` to `onTriggerID`, follows `gotoLocation` to `onGotoLocation` (not after `/leave`) |
| `Mattermost/UI/Native/Channel/ChannelPaneCoordinator.swift`, `Thread/ThreadCoordinator.swift` | `openCommandLocation` hook wired from both composers |
| `Mattermost/MattermostApp.swift` (`bindShellStores`) | `goto_location` → the app's `DeepLinkRouter` when the host is the server the command ran on (upstream's `matchDeepLink(location, serverUrl, SiteURL)`), otherwise `UIApplication.shared.open` for http(s) |
| `MattermostTests/T88SlashRoutingTests.swift` | 11 pure/API tests + 7 composer tests + 5 **live** tests (env-gated, skip without a fixture) |
| `MattermostTests/T34ChannelViewModelTests.swift` | one test: two `extra_responses` + the command's own text become three rows |
| `docs/THIRD_PARTY_NOTICES.md` | §27: the upstream read set and the measured contract above |
| `scripts/t88_slash_stub.py`, `t88_slash_register.py`, `t88_slash_plugin_probe.py` | the stub integration, its registration and the probe — the evidence harness, kept runnable |

Deliberately **not** done: the dialog itself. `onTriggerID` is a hook; nothing draws a dialog yet. That
is `t_e14483c8` (S34 interactive dialogs) — this card makes the id available to that presenter instead
of dropping it. The Apps **runtime** (forms, `call` actions) is still not ported (S34 D2), so an app
command gets an honest sentence rather than a request that would 404 with the wrong reason.

## 4. Verification (real runs)

```
# 1. the new tests + the two suites that share the files
python3 scripts/qa-test.py --sim "id=<iPhone 16 Pro>" --label t88-unit \
  --only-testing MattermostTests/T88CommandRoutingTests \
  --only-testing MattermostTests/T88ComposerCommandTests \
  --only-testing MattermostTests/T34ChannelViewModelTests
→ 49 tests, 0 failed

python3 scripts/qa-test.py … --label t88-t4e \
  --only-testing MattermostTests/T4eSlashCommandTests \
  --only-testing MattermostTests/T4eSlashAPITests \
  --only-testing MattermostTests/T4eSlashComposerTests
→ 40 tests, 0 failed

# 2. the live witness — the composer's own code against 9.11.19 + the stub integration
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
python3 scripts/qa-test.py … --label t88-live --only-testing MattermostTests/T88LiveSlashTests
→ 5 tests, 0 skipped, 0 failed

# 3. does the witness fail when the fix is reverted? (mutation, then restore)
#    both hooks stubbed out with `_ = … // MUTANT`
→ t88-live-mutant: 4 failures —
   testTheComposerFollowsALiveGotoLocation, testTheComposerHandsOnTheTriggerIdAPluginAnswerCarries,
   testAGotoLocationIsHandedToTheShell, testTheTriggerIdAnAnswerCarriesLeavesForTheDialogPresenter
   (the live id it saw: 79i7mgynjb8cxpkyeaeigawm6e)
→ restored, re-run green
```

The live class proves the parts a fake cannot: the real body decodes into our types (`trigger_id`
non-empty for a plugin/custom command, `goto_location` present for `/t88goto`, the 404's sentence
surfacing verbatim, the apps bindings 404 reading as "no app commands"), and the composer's hooks fire
with those real values.

## 5. Known limits (do not mistake these for done)

- **No dialog UI.** The id is handed on; nothing is drawn (t_e14483c8).
- **No Apps runtime.** `/gif` on an apps server is now *refused with a sentence*, not run. That is the
  honest state until S34 lands; the alternative was a 404 that misreports the reason.
- **No `apps_refresh_bindings` refresh.** The posture is cached for the composer's life, so a plugin
  installed mid-session appears on the next composer (channel switch / relaunch). Upstream refreshes on
  the socket event and on screen focus.
- **`goto_location` on the webview surface** goes through the same `DeepLinkRouter`; if the pane is the
  web app, the router hands the link to the webview rather than a native screen. Both are the one
  router, which is the point.
- The fixture setting `AllowedUntrustedInternalConnections=host.docker.internal` is **dev-only** and
  must not be copied to a real server.
