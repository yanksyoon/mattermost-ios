# t_03411e94 — the composer's archived / read-only banners: the state, the copy, and the refusal

Status: implemented. Unit cases pin the derivation and the local refusal; two live cases run against
the 9.11.19 fixture (archive-while-open and open-while-archived). The parity row
`composer / archived-and-read-only-banners` still reads `absent` in
`docs/parity/module-scan.tsv`; re-deriving it needs a full unit run at this head (see §6).

## 1. The defect

`Mattermost/UI/Native/Composer/ComposerView.swift`'s header said it outright: upstream's
`post_draft/archived/` and `post_draft/read_only/` were "read and **not** drawn — this build has no
archived-channel or read-only-membership state". So a reader in an archived channel, or a member whose
scheme withholds `create_post`, got a normal input, a normal Send button, and a request the server
refused into the generic failure banner. Every other part of the client already *kept* the fact: the
sidebar filters archived channels, `ChannelInfoCapabilities` refuses to archive twice, and
`PostOptionsViewModel` treats `delete_at != 0` as "no writes here". Only the composer did not ask.

## 2. Upstream's rule (pinned mobile v2.45.0 @162f2560)

`app/components/post_draft/index.ts` derives four props and `post_draft.tsx` draws one of three
surfaces, in this order:

| where | rule |
| --- | --- |
| `post_draft/index.ts:49` | `canPost = observePermissionForChannel(database, channel, user, Permissions.CREATE_POST, true)` — the union of the user's roles, the team membership's roles and the channel membership's roles; `true` is the default *only* while the channel or user is not loaded |
| `post_draft/index.ts:53-56` | `channelIsArchived = c.deleteAt !== 0` (an `undefined` emission is filtered so the banner cannot flicker during the archive modal's dismissal) |
| `post_draft/index.ts:58` | `channelIsReadOnly = observeIsReadOnlyChannel(...)` = `isDefaultChannel && !isSystemAdmin && ExperimentalTownSquareIsReadOnly` (`app/queries/servers/channel.ts:806-813`) |
| `post_draft/index.ts:60-77` | `deactivatedChannel`: a DM whose other participant has `delete_at != 0`, or whose participant cannot be read at all |
| `post_draft.tsx:78-88` | `if (channelIsArchived \|\| deactivatedChannel) return <Archived deactivated={deactivatedChannel} />` — **the whole composer, draft handler included, is not mounted** |
| `post_draft.tsx:90-97` | `if (channelIsReadOnly \|\| !canPost) return <ReadOnly />` |
| `archived/index.tsx:61-68` | copy: `You are viewing an **archived channel**. New messages cannot be posted.` / `You are viewing an archived channel with a deactivated user.` |
| `read_only/index.tsx:62-68` | a `glasses` icon and `This channel is read-only.` |

Two consequences worth stating, because they are what the card is actually about: the banner is
**precedence-ordered** (an archived channel draws the archived copy even for an administrator whose
roles would allow posting), and the state is answered **before** any input exists, so there is no
window in which a send can be attempted.

## 3. The repair

### 3.1 The state is a pure derivation (`Mattermost/UI/Native/Composer/ComposerPosting.swift`, new)

```swift
enum ComposerPostingState { case open, archived, readOnly }   // canPost / message / glyph / identifier
struct ComposerPostingFacts { var channel: MMChannel; var permissions: Set<String>? }
static func derive(_ facts: ComposerPostingFacts) -> ComposerPostingState {
    if facts.channel.deleteAt != 0 { return .archived }
    guard let permissions = facts.permissions else { return .open }
    return permissions.contains(ChannelPermissionID.createPost) ? .open : .readOnly
}
```

- `ChannelPermissionID.createPost` (`ChannelInfoModels.swift:104`) is the id upstream asks for; it is
  named in the same enum as every other `what may I do in this channel?` id. No role *name* is
  inspected anywhere (T40's rule: a scheme can be rewritten).
- `message` is **one** string: the banner's copy and the refusal's reason. Upstream's two banners are
  the only place the sentence exists, so there is nothing else to keep in step.
- `permissions == nil` is "the server did not answer" and reads `.open`. The header of the file argues
  the choice: this client has no wired local role store, so a failed `POST /roles/names` is not a
  denial, and a composer that went read-only on a dropped request would refuse to write where the
  server would have accepted — the same defect with the sign flipped.

### 3.2 One read, four calls (`SessionComposerPostingPolicy`)

`ComposerPostingPolicyServing.facts(channelID:teamID:)` is the seam; the production implementation
fans in exactly what `ChannelInfoViewModel.refreshPermissions` fans in — `GET /channels/{id}`,
`GET /users/me`, `GET /channels/{id}/members/me`, `GET /teams/{tid}/members/{uid}`, then
`POST /roles/names` over the three role sources. A membership row that cannot be read contributes no
names (a DM opened from a permalink may have no team membership); **no role came back** is `nil`
permissions, i.e. "no answer", not "no permissions".

### 3.3 The composer (`ComposerViewModel.swift`)

- `@Published private(set) var posting: ComposerPostingState = .open`, and `canSend` starts with
  `guard posting.canPost else { return false }`.
- `refreshPostingState()` (fire-and-forget, cancels an earlier ask so answers cannot land out of
  order) and `resolvePostingState()` (the worker a test awaits). Asked once per view appearance.
- `handle(_ event:)` follows the channel's life: `channel_deleted` and a `channel_updated` with a
  non-zero `delete_at` patch the facts **without a request** (the frame carries the fact);
  `channel_restored` re-reads (9.11.19's frame names only the id); my own membership row changing
  (`channel_member_updated`, `user_added`, `user_removed`) re-reads the union.
- `send()` refuses **before** `canSend` — a guard that would otherwise swallow the attempt silently —
  and sets `phase = .failed(posting.message)`, i.e. the same sentence the banner draws. The text,
  attachments and draft are untouched. `retry()` holds the same guard: a retry is a second write.

### 3.4 The view (`ComposerView.swift`)

`body` is now `if model.posting.canPost { composerBody } else { postingBanner }`, so the input, the
toolbar, the send button and the autocomplete are **not drawn** — upstream's early return, in
SwiftUI. The banner carries `channelComposer.archivedBanner` / `channelComposer.readOnlyBanner`, its
`accessibilityLabel` is the sentence, and `.task` asks for the state after restoring the draft (the
words stay in the model and on disk, they are simply not sendable).

### 3.5 Wiring

`ChannelPaneCoordinator.postingPolicy(for:)` is one policy per server (test seam:
`postingPolicyFactory`), passed to every channel composer and borrowed by `ThreadCoordinator` for its
reply composers. `ChannelPaneCoordinator.handle(_:serverID:)` and `ThreadCoordinator.handle(_:serverID:)`
now forward each socket event to the warm composers of that server, which is the only route by which
a composer that is already on screen learns the channel was archived.

## 4. Deliberate divergences, stated rather than implied

1. **No "Close Channel" button** on the archived banner. Upstream's is a navigation affordance for a
   pushed screen; this pane's header already carries Back.
2. **The copy is drawn without upstream's markdown emphasis.** `**archived channel**` in a plain
   `Text` is read out with the asterisks by VoiceOver.
3. **The deactivated-DM copy is not drawn.** Deciding it needs the *other* participant's `delete_at`,
   a third read on a DM's composer open; a deactivated DM's channel is not archived, so nothing is
   drawn there (the channel stays writable, as the server allows).
4. **`ExperimentalTownSquareIsReadOnly` is not read as a config flag**, but its effect is still
   reproduced: with the flag on, the server removes `create_post` from `channel_user`, so `.readOnly`
   is derived from the permission the server actually enforces.
5. **A moment of `.open` before the first answer.** The read is four round trips; blocking the input
   for it would blank every healthy channel's composer. If the reader types in that window the words
   land in the draft and the send is refused by the guard, so no request can escape.

## 5. Tests

Unit — `MattermostTests/T4gPostingStateTests.swift` (13 cases, no network, no clock):

| case | what it pins |
| --- | --- |
| `testAnArchivedChannelDerivesTheArchivedStateAndUpstreamsCopy` | `delete_at != 0` → `.archived`, upstream's exact sentence, the banner's identifier |
| `testAMembershipWithoutCreatePostDerivesTheReadOnlyState` | an answered union without `create_post` → `.readOnly` + `This channel is read-only.` |
| `testCreatePostAmongTheRolesLeavesTheComposerOpen` | the ordinary channel stays writable |
| `testAnArchivedChannelIsArchivedEvenWhenTheRolesWouldAllowPosting` | upstream's precedence |
| `testAnUnansweredPermissionLookupIsNotADenial` | `nil` permissions → `.open` |
| `testAnAnsweredLookupWithoutCreatePostIsTheOnlyReadOnlyAnswer` | an empty answered union *is* a denial |
| `testTheStateIsAppliedFromThePolicyAndReachesTheViewThroughCanSend` | the model applies facts; `canSend` false |
| `testAnAnsweredReadOnlyRoleSetIsAppliedToo` | read-only reaches the model |
| `testANoAnswerLeavesTheComposerOpenAndTheTextSendable` | a failed read does not brick the composer |
| `testTheFireAndForgetRefreshAppliesTheAnswer` | the view's `.task` entry point |
| `testAnArchivedSendIsRefusedLocallyWithTheBannersOwnSentence` | **no create/patch/delete reached the service**, `phase == .failed(message)`, the words kept |
| `testAReadOnlySendIsRefusedWithTheReadOnlySentence` | the read-only sentence |
| `testARefusedSlashCommandIsNotExecutedEither` | a `/command` is a write too |
| `testAnOpenChannelStillSendsNormally` | the guard costs a normal channel nothing |
| `testArchivingTheChannelOnTheSocketReplacesTheInputWithoutAskingAgain` | the `channel_deleted` frame patches without a second request |
| `testAChannelUpdateCarryingDeleteAtArchivesToo` | `channel_updated` |
| `testARestoreReReadsTheFactsAndBringsTheInputBack` | `channel_restored` re-reads and re-opens |
| `testAnotherChannelsLifecycleLeavesThisComposerAlone` | one channel's archive cannot close another's composer |

Live — `MattermostUITests/T4gPostingUITests.swift` (9.11.19 on 127.0.0.1:8065, team `perf`, account
`perfprobe`), run on a simulator with `build/logs/t4g-ui-full.log` (`TEST SUCCEEDED`, 108 s):

- `testAAArchivingTheOpenChannelReplacesTheComposerWithTheBanner` — **passes** (32 s): open a fresh
  channel through the sidebar, archive it over the API while the pane is on it, wait for
  `channelComposer.archivedBanner`, compare its label to upstream's copy, assert **no input, no send
  button, no failure banner**, assert the channel still has no authored post, then restore over the
  API and assert the input comes back. This is the socket path — `channel_deleted` arriving on the
  rail's live socket — measured end to end against a real server.
- `testBOpeningAnArchivedChannelDrawsTheBannerAndSendsNothing` — **skips, with a measured reason**:
  a channel that is already archived cannot be *reached* on this build. Measured on 9.11.19: a name
  lookup of an archived channel answers `404 app.channel.get_by_name.missing` (so a
  `/team/channels/<name>` link cannot open one), the team has more archived probe channels than one
  page of `GET /teams/{id}/channels/deleted` (page 0 held none of this card's channels), and a
  `/team/pl/<post>` link stalls on `nativePermalinkProgress` because the shell's permalink directory
  is not wired yet (S12/T36). The case states that and will assert the banner the day the directory
  lands; the state itself is pinned by the unit cases below.

`scripts/t4g_posting_probe.py` (live, exit 0) measures everything the derivation reads, and both
directions of the archive flag: the four reads answer, the union for this account carries
`create_post` (so an ordinary channel's composer stays writable — the guard is not over-eager),
`DELETE /channels/{id}` moves `delete_at` off zero, `POST /channels/{id}/restore` moves it back.

## 6. Record and follow-ups

- **The read-only path is not exercised live, and cannot be on this fixture.** A channel whose
  scheme withholds `create_post` needs a custom permission scheme, and `POST /schemes` on the 9.11.19
  fixture answers `501 api.scheme.create_scheme.license.error` ("Your license does not support
  creating permissions schemes"); `POST /roles` is not routed at all in this build. The alternative —
  patching the shared `channel_user` system role — would withhold `create_post` from every channel on
  a server other cards are testing against, so it was not done. What *is* measured live is the half
  that could be: the permission union answers and carries `create_post` for an ordinary member
  (`scripts/t4g_posting_probe.py`), which is the same read the read-only branch consumes. The
  read-only *branch* is pinned by unit cases.
- **A gap this card found but does not own:** an archived channel cannot be reached on this build.
  `GET /teams/{id}/channels/name/{name}` answers 404 for an archived channel (measured), so a
  `/team/channels/<name>` link cannot open one; `Browse channels` reads only the first page of
  `GET /teams/{id}/channels/deleted`; and `/team/pl/<post>` waits on the permalink directory that
  S12/T36 has not landed. That is navigation, not the composer — the composer is correct whenever
  such a channel *is* on screen (the live archive-while-open case proves the derivation runs on the
  same facts) — and it belongs to the permalink/navigation card rather than here.
- The parity row (`docs/parity/module-scan.tsv`, line 110) still reads
  `absent / MISSING`. `parity/check_scan.py` only accepts a unit case that appears as `passed` in
  `build/logs/parity-scan-unit.log`, the **full** suite run made at the parent scan's head; this
  card's run log is `build/logs/t4g-unit.log`. Re-deriving the row therefore belongs to the next full
  unit run (it would otherwise turn the gate red on a true claim). Evidence to cite then:
  `MattermostTests/T4gPostingStateTests.swift::testAnArchivedSendIsRefusedLocallyWithTheBannersOwnSentence`
  and `MattermostUITests/T4gPostingUITests.swift::testAAArchivingTheOpenChannelReplacesTheComposerWithTheBanner`.
- `docs/component-map.md` §3 (the composer's decomposition) should grow `ComposerPosting.swift`; left
  for the same owner so the map and the scan move together.
