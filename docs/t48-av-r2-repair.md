# T48-AV-R2 — Copy Link stops naming the route's team when the channel-team name read fails

Card: `t_9acf2b1c`. Parent: `t_531f894e` (T48-AV). Finding repaired: **F4** from
`docs/t48-av-build-note.md` §F4 — "the route's team name survives a failed channel-team name read".

Base: `da171b4` (origin/main at the start of this run). Host: macOS 26.3.1, Xcode 26, simulator
`iPhone 16 Pro` (`81A7F251-8B31-4945-8783-5A264C14B8D5`). Every number below is from a run on this
host, in a dedicated worktree (`.worktrees/t_9acf2b1c`) and a dedicated derived-data directory, not
from the AV note.

---

## 1. The defect, in one paragraph

`PostOptionsViewModel.activate` used the route's team for two things: `teamID` (corrected from
`GET /channels/{id}`) and `teamName` (never corrected). It seeded `teamName = suppliedTeamName` on
its first line. When the channel's `team_id` came back as another team, the activation then read the
channel team's *name*; if that read threw, the `else if … teamName == nil` fallback saw a name
already set (the route's) and left it. `PostPermalink.string` then built `{server}/{route}/pl/{post}`
— a link to a channel that does not exist in that team. The server cannot tell the two links apart
(`/perf/pl/…` and `/ops/pl/…` both answer 200 with the same bytes, measured in the AV note), so the
client's string is the only claim in play.

## 2. What changed

`Mattermost/UI/Native/Channel/PostOptionsViewModel.swift`, `activate` only:

* **Nothing is pre-seeded.** `teamName` is reset to `nil` when the activation starts, so no Copy Link
  row is offered from the route's name while the reads are in flight (the sheet can be drawn, and
  tapped, between the awaits — a link withdrawn mid-load is still a link this device offered).
* **The supplied name is classified, not trusted.** It is only a candidate while
  `channelTeamID == nil` (the channel's team could not be read: a deep link, offline during
  activation) **or** `channelTeamID == teamID` (the channel belongs to the team the route named).
* **Resolution happens once, at the end.** A non-empty answer from `service.teamName(teamID:)` wins;
  otherwise the candidate is applied only when it may describe the channel's team; otherwise
  `teamName` stays `nil` and `PostOptionsCapabilities.derive` withholds Copy Link (its own rule:
  `offersCopyLink` requires a non-empty name).

No view, no service, and no derivation rule changed. The fallback is kept for the case it was
written for — a shell route is the only team a deep link or an offline activation can offer — and it
is dropped only when the channel's own team is known to be a different team.

## 3. The tests

`MattermostTests/T48PostOptionsAVTests.swift`:

* `testAFailedTeamNameReadMustNotLeaveTheRoutesTeamInThePermalink` — the finding's repro. Its
  `expectKnownDefect` marker is **removed** (that is the acceptance): the test now asserts
  `options.teamName != "ops"`, no `.copyLink` row, and no link from `perform(.copyLink)`.
* `testAnUnreadableChannelTeamStillUsesTheRoutesName` (new) — the boundary of the repair: when
  `GET /channels/{id}` throws, the route's team and name are all there is; the link must still be
  `…/ops/pl/<post>`, not withheld.
* `testAMatchingChannelTeamKeepsTheRoutesNameWhenTheNameReadFails` (new) — the other boundary: the
  channel's team *was* read and is the route's, so a failed name read still uses the route's name.
* `FakeService` grew `channelTeamIDFails`, so the two failure modes (team id unreadable vs name
  unreadable) are steered independently instead of through one shared `failure`.

`MattermostTests/T48PostOptionsTests.swift` is untouched: `testTheChannelsOwnTeamNamesThePermalinkNotTheRoutesTeam`
still pins the team-id half (it asserts `teamNameRequests == ["team-of-the-channel"]` and the
`perf` name), and `testActivationReadsTheStateTheRowsCannotKnowByIdempotently` still pins the
per-`(channel, team)` idempotency.

## 4. Runs

All three runs are `scripts/qa-test.py` from this worktree, derived data
`~/.hermes/profiles/mmios-ios/cache/scratch/t48avr2-dd-mac`, logs under `build/logs/`.

| Run | Command | Result |
|---|---|---|
| AV suite, repaired tree | `--platform mac --only-testing MattermostTests/T48PostOptionsAVTests` | **8 run / 0 failures (0 unexpected)**, `** TEST SUCCEEDED **` — `testAFailedTeamNameReadMustNotLeaveTheRoutesTeamInThePermalink` unmarked and green; the two F5 tests are still `Expected failure` (the marker was not loosened, only F4's was removed) |
| T48 units (no regression) | `--platform mac --only-testing MattermostTests/T48PostOptionsTests` | **23 run / 0 failures**, `** TEST SUCCEEDED **` |
| Red proof: product change reverted, test kept | `--platform mac --only-testing MattermostTests/T48PostOptionsAVTests/testAFailedTeamNameReadMustNotLeaveTheRoutesTeamInThePermalink` | **1 run / 3 failures**, `** TEST FAILED **` — `("Optional("ops")") is equal to ("Optional("ops")")`, `Copy Link must be absent, not wrong`, and `a link was produced …: http://127.0.0.1:8065/ops/pl/post0000000000000000000001`. The same three assertions, now red on the old code and green on the new. |

The patch was then reapplied (`git apply`) and the AV suite re-run to leave the tree in the state
that produced the green line above (8 run / 0 failures again). The commit was rebased onto
`af33b3d` (T48-AV-R4, which also edits `PostOptionsViewModel.facts` and this test file) and both
suites were re-run on the merged tree: **AV 8 run / 0 failures**, **T48 units 26 run / 0 failures**
(the suite grew from 23 to 26 in R4's commit), `** TEST SUCCEEDED **` for both.

The iOS-simulator run of the same suite did not produce a verdict on this host: two attempts
(`--sim id=81A7F251…`, then a freshly created `iPhone 16 Pro` / iOS 18.3 device) sat at
`builtin-swiftStdLibTool` for 6–17 minutes with `xcodebuild` at 0.1 % CPU while six sibling
`xcodebuild` runs shared the host (load average measured at 244–1002). Both were killed rather than
counted; the Catalyst destination — which the AV pass also used for its numbers — is the record
above. This is the same environment limitation the AV note records for its UI suite, not a claim
about the product.

## 5. What is not proven

* No live server run: the repair is a state-machine change with a deterministic fake, and the AV
  pass measured the wire behaviour it depends on (`GET /channels/{id}` answers `team_id`,
  `GET /users/me/teams` answers the URL name). A live cross-client permalink check would not add a
  signal the server can produce — both links answer 200.
* The sheet's rendering of "Copy Link absent" is the derivation's, already covered by the T48 unit
  suite; no UI run was attempted here (the host was at load 660–1000 with six sibling test runs, and
  the AV pass recorded the same environment blocking its UI suite).
