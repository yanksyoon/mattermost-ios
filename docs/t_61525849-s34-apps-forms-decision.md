# S34 — Apps forms and dialogs: whether v1 builds them, hatches them, or says no

**Card:** t_61525849 · **Status:** decided (`mmios-architect`) · 2026-11-05
**Pins:** M = `mattermost/mattermost-mobile` v2.45.0 @ `162f2560d0e1df073220f7701d5a67cc17c8abeb`;
W = `mattermost/mattermost` v12.0.1 @ `987e57120dca630dadbcd2638064ab66a02bb81e`.
**No application code changes in this card.** This document, four parity rows (three rewritten, one
split out of a conflated row), two claims rows and the record's vocabulary are the deliverable.

---

## 1. The question

`docs/parity/module-scan.tsv` carried three rows with no card: a plugin's interactive dialog had no
renderer, the Apps runtime was "not ported", and the capability was therefore either a webview or
nothing. The card asked which:

- **(a)** a native form renderer + dialog router,
- **(b)** a per-dialog webview hand-off,
- **(c)** defer with an explicit out-of-scope entry.

The answer is a split, not a single choice — because the two rows under `web-fallback` describe two
different things (a *dialog* runtime the client owns, and an *Apps* runtime the client does not), and
the third row (`channel-timeline / apps-bindings-and-interactive-attachments-inside-a-post`) conflates
the Apps half with a plain message-attachments gap that is not an Apps feature at all.

**Decision, in one line:** the interactive-dialog runtime is **v1, native, carded as t_e14483c8**
(option (a)); the Apps framework runtime is **out of scope for v1**, recorded as such; message
attachments are **carded separately as t_5dce3e67**; option (b) is **not implementable**, for a
reason that is mechanical and stated in §4.

---

## 2. What the upstream actually does at the pin

### 2.1 Three triggers, one renderer

Every path ends in the same `InteractiveDialogConfig` → `AppsFormComponent` render.

**(i) Command handshake — the path a native client can already reach.**
`POST /api/v4/commands/execute` answers with `trigger_id` (`app/actions/remote/command.ts:78-80`,
`IntegrationsManager.setTriggerId`). A plugin that wants a dialog then calls
`pluginAPI.OpenInteractiveDialog(trigger_id, …)`; the server pushes the WebSocket frame `open_dialog`.
`app/actions/websocket/integrations.ts:handleOpenDialogEvent` reads `msg.data.dialog` — **a JSON
string, not an object** — parses it, and hands it to `IntegrationsManager.setDialog`.

The two halves meet only on a matching id (`app/managers/integrations_manager.ts:41-62`):

```
setTriggerId(id)   → if storedDialog?.trigger_id === id  → showDialog()
setDialog(dialog)  → if triggerId === dialog.trigger_id  → showDialog()
showDialog()       → navigateToScreen(Screens.DIALOG_ROUTER, {title, config})
```

Either order works; a mismatch never shows. This is the whole correlation rule and it is why the
trigger id must be kept, not just parsed.

**(ii) Post action.** `POST /api/v4/posts/{post_id}/actions/{action_id}` answers
`{status, trigger_id?, goto_location?}` (`app/client/rest/posts.ts:208-226`); a `trigger_id` runs the
same handshake. This trigger is only reachable once message attachments are rendered — which they are
not, today (§3.3) — so it is a *consumer* of this work, not a precondition of it.

**(iii) Apps call.** `POST /plugins/com.mattermost.apps/api/v1/call` with an `AppCallRequest`; a
`{"type":"form"}` answer opens `Screens.APPS_FORM` (`app/screens/apps_form/index.tsx:70-83`). This is
the Apps runtime, not the dialog runtime, and it needs bindings + the call cycle (§2.5).

### 2.2 The dialog object (`types/api/integrations.d.ts:41-102,141-142`)

```
InteractiveDialogConfig { app_id, trigger_id, url,
  dialog { callback_id, title, introduction_text, icon_url?, elements[],
           submit_label, notify_on_cancel, state, source_url? } }
DialogElement { display_name, name, type, subtype?, default, placeholder, help_text,
                optional, min_length, max_length, data_source, data_source_url?,
                options[{text,value}], multiselect?, refresh?,
                min_date?, max_date?, time_interval?, datetime_config? }
DialogSubmission { url, callback_id, state, user_id, channel_id, team_id,
                   submission{field: string}, cancelled }
```

Element types: `text | textarea | select | radio | bool | date | datetime` (seven). Text subtypes:
`email | number | tel | url | password` (five). Note `submission` is **all strings** — booleans become
`"true"`/`"false"`, multi-selects are comma-joined values (`app/screens/dialog_router/dialog_router.tsx:71-93`).

### 2.3 Endpoints

| call | route | file |
|---|---|---|
| submit | `POST /api/v4/actions/dialogs/submit` | `app/client/rest/integrations.ts:56-61` |
| lookup (dynamic select) | `POST /api/v4/actions/dialogs/lookup` | `:63-68` |
| post action (trigger id) | `POST /api/v4/posts/{post_id}/actions/{action_id}` | `app/client/rest/posts.ts:208-226` |
| app call (Apps only) | `POST /plugins/com.mattermost.apps/api/v1/call` | `app/client/rest/apps.ts:14-28` |

Submit answers `{type:"ok"|"error"|"form"}`: `form` is the next step of a multiform dialog; `error`
may carry field-level messages; `dialog_router.tsx:104-192` merges accumulated values across steps.

### 2.4 The "integration selector" is a dialog *field picker* — the scan row was wrong

`docs/parity/module-scan.tsv` described it as "the picker that binds a channel to an integration".
Read the file at the pin (`app/screens/integration_selector/integration_selector.tsx:40-52`): it
declares

```
VALID_DATASOURCES = [DATA_SOURCE_CHANNELS, DATA_SOURCE_USERS, DATA_SOURCE_DYNAMIC]
```

and clears `SettingsStore.removeIntegrationsSelectCallback()` on close. It is the picker behind a
**dialog/apps-form select field with a data source** — channels, users, or a dynamic lookup — not a
channel-binding screen, and not an Apps-only surface. So it is not a third thing to decide; it belongs
to the renderer in (a) and is carded with it.

### 2.5 What is genuinely Apps-only

| piece | why it is not the dialog runtime |
|---|---|
| `GET /plugins/com.mattermost.apps/api/v1/bindings` | channel/team/user-scoped binding list; needs a native surface to render (inline post bindings, embedded bindings) |
| `POST …/api/v1/call` | the Apps protocol: context creation, `selected_field`, `track_as_submit` |
| `AppCommandParser` (`app/components/autocomplete/slash_suggestion/app_command_parser/`) | parses `/app-name subcommand` into a call |
| `Screens.APPS_FORM` submit/refresh/lookup against `currentForm.submit/source` | a form *delivered by a call*, not by a dialog |
| `embedded_bindings/`, `interactive_messages/` | Apps rendering inside a post |

None of it is a URL and none of it is a dialog.

---

## 3. What our tree has today (verified, not recalled)

**3.1 The trigger half already ships.** The composer runs slash commands
(`Mattermost/UI/Native/Composer/ComposerViewModel.swift:860-905`) and `ComposerCommandResponse`
already decodes `trigger_id` (`Composer/ComposerCommands.swift:238-264`). The field is stored —
`lastCommandResponse` (`ComposerViewModel.swift:154`, set at `:896`) — and **nothing consumes it**. The
comment at `:150-153` says exactly why it is kept: "a later screen (a plugin dialog, `goto_location`)
has the payload without asking the server twice". The later screen was never built.

**3.2 The socket drops the dialog.** `Mattermost/Core/MM/SocketEvent.swift:544-552`: an unknown frame
becomes `.unhandled(name:)`. `open_dialog` is not cased, so the frame is tolerated and **silently
discarded**. A reader presses a plugin's button; the plugin opens a dialog; nothing appears and
nothing is logged as an error.

**3.3 Message attachments are not rendered.** `MMPost.props` is carried
(`Core/MM/MMTypes.swift:31`) but `PostListModels.attachments(for:)` (`:551`) reads `metadata.files`
and falls back to `file_ids` — *files*, not attachments. `PostRowView.swift:562` therefore draws
markdown + files. There is no attachment block, so there is no attachment button, so trigger (ii)
cannot exist yet.

**3.4 No Apps client, no bindings, no picker.** `grep -rln "apps_form\|dialog_router" Mattermost` →
nothing; there is no `/plugins/com.mattermost.apps` route in the transport, no bindings fetch, no
data-source picker.

**3.5 The presentation seam exists.** `Mattermost/UI/Native/SheetHost.swift` is the one sheet host
(one sheet up, one queued, idempotent by route id) — the dialog is a `.sheetHost` route, not a new
presentation mechanism.

**3.6 The record's vocabulary could not express the outcome.** `module-scan.tsv` allowed
`parity|gap|owner-decision` and, for `ours`, `native|partial|webview|absent`. "The owner decided not
to build it" had no word: it rendered as *to be implemented — blocked on owner decision*, i.e. as if
undecided. §7 adds the fourth verdict `out-of-scope`.

---

## 4. Option (b), per-dialog webview: rejected, and why it is not a matter of taste

A webview hand-off needs one of two things, and there is no third:

1. **A URL that opens the dialog.** There is none at the pin. The dialog is not a route: it arrives
   either as a WebSocket frame (`data.dialog`, a JSON string keyed by `trigger_id`) or inside a
   command/post-action/Apps response. `IntegrationsManager` shows it by **navigation to a screen with
   the config as a parameter**, not by resolving a path.
2. **A supported call into the webapp's own client.** The webapp opens dialogs through Redux actions
   (`openInteractiveDialog`), which is application-private state, not an API. Reaching it from native
   code would mean `evaluateJavaScript` against a module path the webapp is free to rename in any
   release — and it would still need a webview to be *mounted and signed in* at the moment the frame
   arrives, which it is not: the web fallback is a presented destination
   (`UI/Native/Web/WebFallbackSurface.swift` — Boards, Playbooks, System Console, a plugin route),
   opened from the sidebar, not a background client following the channel pane.

A third reading of (b) — shipping our own bundled HTML form in a `WKWebView` — is (a) with the form
controls, keyboard avoidance, Dynamic Type and VoiceOver replaced by re-implementations in a second
language, and it would still need the native trigger plumbing above. It costs more and proves less.

**(b) is rejected. The choice is (a) or (c), and it is made per runtime below.**

---

## 5. Decision

### D1 — The interactive-dialog runtime is v1 scope, native, carded: **t_e14483c8**

Rationale, in the record's own terms:

- **Half of it already ships and is dead weight otherwise.** The command runs, the `trigger_id` is
  decoded and stored, and there is no consumer. That is the strongest evidence a capability is
  *intended* to be native; leaving it unbuilt means keeping dead state forever.
- **The failure is silent.** `open_dialog` → `.unhandled`. A plugin's dialog vanishes with no error,
  no log, no row. Silent absence is worse than a visible "not available", and the webview hatch
  cannot make it visible because there is nothing to hatch (§4).
- **It is bounded and fully specified by the pin**: 7 element types, 5 text subtypes, 2 endpoints, one
  correlation rule, one conversion table (§2). It is a form renderer, not a runtime.
- **It is a precondition, not a duplicate.** The post-action trigger (ii) and any future Apps binding
  need exactly this renderer; building it once is cheaper than a second renderer later.

Scope of D1: `DialogRouter` (correlation, multiform, refresh, submit/cancel, error mapping) + the
form renderer + the data-source picker (`integration_selector`). **Not** in D1: Apps (§D2), message
attachments (§D4).

### D2 — The Apps framework runtime is **out of scope for v1**

Reasons, each falsifiable:

1. **No surface can host a binding.** Bindings render inline in a post (`embedded_bindings/`,
   `interactive_messages/`) or in channel-header menus; the post-body half needs message attachments
   first (§D4), which are themselves unported.
2. **The call cycle is a protocol, not a screen**: context construction, `track_as_submit`,
   `selected_field`, app lookups, and a form component that is *driven by a call* rather than by a
   dialog config. That is an order of magnitude larger than D1 and would need its own decision.
3. **It cannot be verified on this host.** The pinned 9.11.19 fixture has no `com.mattermost.apps`
   plugin installed; every path in §2.5 would be claimed without a live witness — the exact thing the
   parity record refuses.
4. **The escape hatch covers the plugin's own UI** when it is reachable as a route (`/plugins/<id>`),
   which is what a reader actually needs most of the time. The Apps *API* has no route, so a plugin
   that needs a form still gets D1's dialog — the plugin author can open a dialog.

Recorded as `out-of-scope` on the rows that name it, with this document as the reason.

### D3 — The "integration selector" is part of D1, not a screen of its own

It is the select-field picker (§2.4). It ships inside t_e14483c8 as `DialogPickerView`, reusing the
member and channel pickers the shell already has. No separate card, no separate parity row state.

### D4 — Message attachments are a plain parity gap, carded: **t_5dce3e67**

`props.attachments` is decoded and unread (§3.3). This is not an Apps feature and must not be hidden
inside the Apps decision: plugin attachments (fields, buttons, selects, images, footers) are ordinary
Mattermost chat UI that the desktop shell renders. It also restores trigger (ii) for D1. The scan row
that named it was written as one capability (`apps-bindings-and-interactive-attachments-inside-a-post`);
it is split in §7.

### Non-goals

- No `/api/v4/actions/dialogs/open` client path (upstream does not use it; dialogs are pushed).
- No dialog on a web (`.webview`) surface: the webapp already renders its own; a native sheet must not
  stack on top of it.
- No offline queueing of a dialog: a dialog is a live correlation with a `trigger_id` the server has
  probably already expired. It is presented while the session that produced it is current, and
  dropped on server switch.

---

## 6. The spec handed to the builder

The complete specification (field→control mapping, correlation state machine, conversion table,
multiform/refresh rules, cancel semantics, file layout, unit + live verification gate, and the
record updates that count as done) is in the card body of **t_e14483c8**. Nothing in this document
overrides it; if they disagree, the card is newer.

The one architectural constraint worth repeating here: the renderer is **config-driven and knowable
offline**. A dialog is a tree of values the client draws; no dialog field may fetch a URL it invents
(`data_source_url` and `source_url` are server-supplied and go to the two endpoints in §2.3, through
the existing `APIClient`, so auth, retries and typed errors are T28's, not a new transport).

---

## 7. Record changes made by this card

`docs/parity/module-scan.tsv`

| row | before | after |
|---|---|---|
| `web-fallback / apps-interactive-dialog-forms` | absent / gap / card `t_61525849 (new card: S34 decision)` | absent / **gap** / **t_e14483c8**; the capability text now names the real mechanism (trigger_id + `open_dialog`, submit/lookup) |
| `web-fallback / apps-integration-selector` | absent / owner-decision | absent / **gap** / **t_e14483c8**; description corrected to the field picker (§2.4) |
| `channel-timeline / apps-bindings-and-interactive-attachments-inside-a-post` | absent / owner-decision | split: `apps-bindings-inside-a-post` → absent / **out-of-scope** (D2); new row `message-attachments-fields-and-action-buttons` → absent / **gap** / **t_5dce3e67** |

`parity/claims.tsv`: `M:app/screens/dialog_router` gains the card id **t_e14483c8**;
`M:app/screens/apps_form` gains this document's §5 D2 (out of scope — no card, because nothing is
planned) and loses the "webview escape hatch" note that was never true. Status stays `absent` in both:
the claim record states implementation, not intent.

`parity/generate.py` + `parity/check_scan.py`: the verdict vocabulary gains **`out-of-scope`** — an
accepted absence that is neither a gap nor an open owner decision. It renders in `docs/PARITY.md`
§Out of scope as "accepted out of scope — <card>", so the five-section view stops claiming these rows
are "to be implemented". Without the word, every future "we decided not to build this" either lies
(`webview`) or stays permanently "blocked on owner decision".

`docs/component-map.md` §S34: rewritten to D1/D2/D3 (the old text listed `IntegrationSelectorView` as
a *screen* — it is a picker — and implied all three views were planned).

### 7.1 The record's own gates, run on this change

```
python3 parity/check_scan.py
  rows: 160 across 16 modules; 331 evidence refs checked
  OK: columns, vocabulary, refs and the HEAD run all agree          rc=0

python3 parity/generate.py --check
  check: 0 artifact(s) drifted, 1 fatal finding(s), 272 report finding(s)
  [FAIL] STALE-VERDICT M:app/screens/create_or_edit_channel — 2 commit(s) after de59f71ba679
         touched the claimed files
```

The one fatal finding is **pre-existing**: the same `create_or_edit_channel` STALE-VERDICT fires on
the parent commit without this change (it is carded by the parent scan as a stale verdict, t_2fc694a9).
This card adds no fatal finding and no drift. `python3 parity/generate.py --self-test` still prints
`self-test: PASS` (6/6 planted faults, 6 artifacts byte-identical across two runs).

The record's arithmetic moved exactly as intended: 159 → 160 capabilities, **out of scope 6 → 7**
(the Apps-bindings row), **owner decisions 13 → 11** (the two rows this card decided), implemented and
partial unchanged.

---

## 8. Risks

1. **Thin live coverage.** The dialog's real-world trigger (a plugin calling `OpenInteractiveDialog`)
   needs a plugin fixture the host does not have. The card's gate is therefore a loopback WS replay of
   the exact frame plus a stub `/actions/dialogs/submit`; that proves our half, and the build note must
   say so rather than implying a plugin was exercised.
2. **A dialog can arrive at any time**, including while a sheet is already up (`SheetHost` queues one)
   and after the trigger's screen is gone (the reader ran the command in channel A, then switched).
   The presenter is session-scoped, not screen-scoped, for that reason.
3. **`notify_on_cancel` is a promise to the plugin.** Submitting `cancelled:true` when the flag is
   absent would post "cancelled" to integrations that never asked; the card treats it as a strict
   condition.
4. **No App Store / ATS risk.** Everything here is same-origin HTTPS through the existing client, no
   new entitlement, no new webview, no third-party code. The dialogs are server-supplied *values*;
   they are drawn by SwiftUI, so a plugin cannot inject markup into the app (the `introduction_text`
   and `help_text` go through the existing markdown renderer, which draws raw HTML as text).

---

## 9. What would reopen this decision

- A live fixture with the Apps plugin installed, which would make D2 verifiable (D2 becomes a "how
  much", not a "whether").
- A product requirement that a specific shipped plugin's binding must work natively — that reopens
  D2 and pulls t_5dce3e67 forward as its prerequisite.
- A pin bump where `open_dialog` or the dialog element model changes shape (§2.2 is the contract this
  decision is written against).

---

## Appendix — how each fact above was obtained

- Upstream sources read at the pin over `raw.githubusercontent.com/.../<sha>/…` (files named inline);
  directory contents at the pin over the GitHub contents API.
- "Absent here" claims are `grep`/read against this checkout at `196958d` plus the working tree, with
  the file and line cited in §3. Nothing about our tree is inferred from the component map.
