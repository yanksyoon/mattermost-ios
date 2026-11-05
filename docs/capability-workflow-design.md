# Capability map + ticket workflow — design (prevents duplicate work and false "done")

**Status:** design proposal, not implemented. No generator, query tool, or CI parity job
exists today; this doc is the plan for one.
**Date:** 2026-11-05
**Scope:** the workflow layer on top of a *deterministic* capability map. Concrete
commands, file paths, output samples. Small illustrative snippets only — no production code.

---

## 0. Problem restated (what this must kill)

1. **Duplicate effort** — cards are created for capabilities that already ship
   (`t_0230e17e "Parity scan v2"` re-proposes work the T25 inventory already did).
2. **False completion** — workers mark cards `done` while the feature does not work in the
   running app. Live examples on this board: `t_1617a61c` (thread pane, no back button),
   `t_05caa678` (channel header never visible), `t_6a2b0fb4` (notifications accepted by the
   OS, never presented).
3. **Reviews cost more than the work** — a reviewer must re-derive, from prose
   (`docs/parity.md`, 404 lines; `docs/native-inventory.md`, 397 lines), what the card was
   supposed to prove.

The root cause is structural, not cultural: the current materials are **prose and TSV with no
status column, no card linkage, and no machine-checkable evidence**. Nothing a script can run
distinguishes "implemented and proven" from "a worker said so". This design makes the map the
single queried truth and makes every status transition a script-checkable predicate.

---

## 1. The capability map — one deterministic file

**New authoritative file:** `docs/capability-map.tsv` (tab-separated, one row per capability).

| column | meaning | values |
|---|---|---|
| `capability` | stable id, reuses the existing S-numbers | `S01`…`S40` |
| `surface` | human name | `thread RHS + global threads` |
| `disposition` | what the ADR says the surface *should* be | `native` \| `hybrid` \| `webview` \| `dropped` |
| `status` | how far the implementation has been proven | `absent` \| `claimed` \| `tested` \| `native` (and `webview`/`dropped` as terminal) |
| `claim_card` | last board card that advanced this row | `t_e73f31ce` |
| `test` | the single test that backs `tested`/`native` | `T36-ThreadsUITests/testThreadReplyRoundTrip` |
| `native_card` | card that proved native rendering | `t_<8hex>` |
| `evidence` | comma-separated repo-relative artifact paths | `docs/t36-build-note.md` |
| `updated_at` | ISO date | `2026-10-26` |

Example rows:

```
capability	surface	disposition	status	claim_card	test	native_card	evidence	updated_at
S13	thread RHS + global threads	native	tested	t_e73f31ce	T36-ThreadsUITests/testThreadReplyRoundTrip		docs/t36-build-note.md	2026-10-26
S22	channel info + add members	native	claimed	t_05caa678			docs/t40-build-note.md	2026-11-04
S35	notifications (local + push)	native	claimed	t_6a2b0fb4				docs/t43-build-note.md	2026-11-04
S29	system console	webview	webview				docs/native-inventory.md	2026-10-24
```

`disposition` and the surface list come **unchanged** from `docs/native-inventory.md` §1/§4;
`status`/`claim_card`/`test`/`native_card`/`evidence` are the new columns this workflow
maintains. `docs/inventory/screens.tsv` (67 screens) and `docs/inventory/rest-endpoints.tsv`
(147 endpoints) stay as the upstream catalog; the map references them, it does not duplicate
them.

**Determinism guarantee:** `scripts/cap.py gen` derives `docs/capability-map.json` from the
TSV. Same TSV → same bytes. CI asserts `gen` is a no-op, so a drift between the two files is
impossible to commit silently. The TSV is the only thing humans/workers edit; the JSON is a
build artifact checked in for consumers.

MVP covers the **40 surface capabilities only**. Protocol coverage (REST endpoint /
WS-event rows) is a v2 extension — see §8 cutline.

---

## 2. The pre-card query — "is capability X implemented? show me the evidence"

**Tool:** `scripts/cap.py query <needle>` — fuzzy-matches capability id, surface name, or a
card-title fragment. It reads the committed TSV **and** the live board DB
(`~/.hermes/kanban/boards/mattermost-ios/kanban.db`, read-only) to answer the second half of
the question: *is someone already working on this?*

**Exact command (run before creating any card):**

```bash
cd /Users/yangsooyoon/Documents/yanks/code/mattermost-ios
./scripts/cap.py query threads
```

**Sample output — implemented but not yet native (the honest gap):**

```
S13  thread RHS + global threads        disposition=native   status=TESTED
  claim card:  t_e73f31ce  (done)
  test:        T36-ThreadsUITests/testThreadReplyRoundTrip
  evidence:    docs/t36-build-note.md   → "FAILURES: 0"   (2026-10-26)
  native:      NOT PROVEN — surface not in nativeApprovedSurfaces;
               no native-pane runtime proof on record
  open cards:  none
  VERDICT: IMPLEMENTED+TESTED. Do NOT create an implementation card.
           The only legitimate next card closes the 'native' gap:
           verify-dual-render-gates.sh + a native-pane runtime proof (G10).
```

**Sample output — already claimed by an open card (the duplicate guard):**

```
./scripts/cap.py query "channel header"
S22  channel info + add members        disposition=native   status=CLAIMED
  claim card:  t_05caa678  (ready)   ← OPEN, not done
  open cards:  t_05caa678  "Channel screen: header, channel info and bookmarks
               are not visible"
  VERDICT: IN-PROGRESS. Do NOT create a card. A card already owns this capability.
```

**Sample output — genuinely absent:**

```
./scripts/cap.py query S33
S33  calls (voice/video/screen share)  disposition=webview   status=webview
  VERDICT: OUT OF SCOPE (webview-only by ADR §2.3, T44). Do NOT create a native card;
           reopen the disposition decision first.
```

The verdict line is the only thing a worker/steward is required to act on. A query that
returns anything other than `ABSENT` **must not** produce a new card. `query` is also what the
steward runs before proposing (so it can't propose a duplicate), and what a worker runs at
claim time (so it can't implement a duplicate).

---

## 3. Card ↔ capability linkage

### 3.1 At creation — the marker line and idempotency key

A card that implements/repairs a capability **must** carry one marker line in its body:

```
CAPABILITY: S13
```

and be created with a capability-scoped idempotency key so a re-run of the propose step
returns the existing card instead of duplicating it:

```bash
hermes kanban --board mattermost-ios create \
  --title "S13: thread reply round-trip against the live server" \
  --body "... CAPABILITY: S13 ..." \
  --idempotency-key "cap:S13"
```

The `idempotency_key` column already exists in `tasks`; `cap:S13` is the convention. (For a
repair/validator on the same surface, use `cap:S13:repair` — a distinct key, but still
routing to the same capability row.)

### 3.2 At finish — what the worker must write

The worker's definition of done is now a **promote** that a script can later re-check:

```bash
# 1. code + tests committed (verification-before-completion: commit first, then test)
# 2. run the gate, capture the verdict line
./scripts/qa-test.py --only-testing "T36-ThreadsUITests/testThreadReplyRoundTrip"   # exit 0

# 3. record the claim in the map (this updates the TSV, regenerates the JSON, commits)
./scripts/cap.py promote S13 tested \
  --card t_e73f31ce \
  --test  T36-ThreadsUITests/testThreadReplyRoundTrip \
  --evidence docs/t36-build-note.md

# 4. close the card with machine-readable metadata
hermes kanban --board mattermost-ios complete t_e73f31ce \
  --result "thread reply round-trip proven against live server" \
  --summary "..." \
  --metadata '{"capability":"S13","promoted_to":"tested","test":"T36-ThreadsUITests/testThreadReplyRoundTrip","failures":0}'
```

`promote` refuses to run if the evidence does not exist, contains no verdict marker (§6 A3),
or another open card already carries `CAPABILITY: S13` (§6 A6). The worker cannot mark the
card done with a `promoted_to` that the map does not also record.

### 3.3 At review — what the reviewer reads

The reviewer does **not** re-derive intent from prose. Three reads, each mechanical:

1. Card result + attached artifact, and `--metadata` matches the run's printed counts
   (existing rule).
2. `./scripts/cap.py query S13` — the map row plus live board cross-check.
3. `./scripts/cap.py gate S13` — re-run every promotion precondition for the claimed status
   (§4/§6). Non-zero = the row's status is a lie and the review fails.

Then, independently, the adversarial checks already in use (revert test, mutation test via
`scripts/qa-mutants.py`, diff the test for a softened assertion or skip).

---

## 4. Promotion rules — claimed → tested → native, as checks a script runs

Ladder: `absent → claimed → tested → native`. `webview`/`dropped` are terminal and skip the
ladder. Every gate below is implemented by `cap.py gate <cap>` and `cap.py promote` re-validates
them before accepting a transition. **`gate` exit 0 iff the row's stated status is justified by
the evidence on disk.**

### `absent → claimed` (a worker finished, nothing independently proven)

- **G1** — a board card with `CAPABILITY: <cap>` and status `done` exists, or `claim_card` is
  set and that card is `done`.
- **G2** — `evidence` path exists **and** carries a build/verdict marker (§6 A3).

### `claimed → tested` (an automated test proves the behaviour)

- **G3** — `test` resolves to a real `Class/func test<Name>` in the test bundle
  (checked by locating `func test<Name>` in the class file).
- **G4** — the named test method contains no `XCTSkip`/`XCTSkipUnless`/`throw XCTSkip` (§6 A1).
- **G5** — the named test asserts delivered behaviour, not mock call counts (§6 A2).
- **G6** — the test passes **fresh**: `./scripts/qa-test.py --only-testing "<test>"` exits 0.
- **G7** — red-green proven: evidence includes a red run (the test's own failing output) for
  the same selector, or `--revert <commit>` was given and `gate` observed the test fail on the
  reverted tree. A test that passes before and after the fix proves nothing.

### `tested → native` (the running app renders it native, not web)

- **G8** — `./scripts/verify-dual-render-gates.sh` exits 0.
- **G9** — the surface is present in the approved native registry
  (`SurfaceDefaults.nativeApprovedSurfaces`) — this is the same check the dual-render gate
  already enforces for pane-owning surfaces.
- **G10** — a runtime proof that the native pane is the one shown: a UI test in
  `MattermostUITests/` (the `T93BNativeByDefaultUITests` family) or a probe artifact asserting
  the native root view is in the hierarchy **and no `WKWebView` hosts this surface**. This is
  the structural fix for the "native rows that render web" false completion.

`native` is the **only** status that certifies "works in the running app". `tested` means
"behaviour proven by a real assertion"; `claimed` means "a worker says so, nothing proven".

---

## 5. CI gate — what it fails on, warns on, and why it won't be ignored

New job `parity` in `.github/workflows/` (wired into or beside `release.yml`), running a single
deterministic command: `./scripts/cap.py ci-check`. It is **repo-only** — it does not read the
board DB, so a red is always a real inconsistency in the committed tree, never transient board
state.

**Fails (hard, blocks merge/release):**

- **C1** — `docs/capability-map.tsv` parses: unique `capability` ids, `status` ∈ allowed set,
  `disposition` ∈ allowed set.
- **C2** — `cap.py gen` is a no-op: the committed `docs/capability-map.json` matches the TSV
  (drift = fail).
- **C3** — every `tested`/`native` row's `evidence` files exist **and** contain a verdict
  marker (§6 A3).
- **C4** — every `native` row passes `verify-dual-render-gates.sh` (the approved registry).
- **C5** — every capability id appears in `docs/inventory/screens.tsv` (no orphan rows).

**Warns (GitHub annotation, non-blocking):**

- **W1** — a `claimed` row whose `updated_at` is older than 14 days ("stale claim — promote or
  demote").
- **W2** — a `tested`/`native` test file that gained an `XCTSkip` since the row was last
  updated (diff-based).

**How it avoids becoming another red build nobody reads:**

- One job, one command, no network, no board — a red is always actionable in the repo.
- Every failure prints exactly one fix line, e.g.:
  `S13: evidence missing docs/t36-build-note.md → cap.py promote S13 tested --evidence <path>`.
- Everything board-dependent (stale-claim enforcement against reopen, live card status) lives
  in the **steward's hourly job**, not CI — CI never goes red on a card being reopened.
- The hard-rule set is frozen small (schema + gen-sync + evidence-exists + dual-render). Adding
  a rule is itself a reviewed change, so the gate can't accrete noise.

---

## 6. Anti-gaming rules (script-checkable)

**A1 — No XCTSkip behind a promotion.** A test named by a `tested`/`native` row must not
contain `XCTSkip`, `XCTSkipUnless`, or `throw XCTSkip` in its method body. `gate` greps the
method. Skips are legitimate for live-gated tests (no server / no APNs — the repo has ~365
`XCTSkip` sites across 10 files), but a skipped test can back **`claimed` only**, never
`tested`/`native`. Check: parse the method body, match `XCTSkip.*` / `throw XCTSkip`.

**A2 — No assertion on mock call counts instead of delivered payloads.** `gate` parses the test
method's assertions and flags count-only patterns — `XCTAssertEqual(x.count, …)`,
`XCTAssertTrue(calls == …)`, `verify(…, count: …)`, `.callCount`, `.toHaveBeenCalledTimes`. It
requires **at least one assertion on concrete output**: a returned-value equality, a persisted
row's contents, or a UI element's `.exists`/`.label`. Integration/UI tests are exempt (they
assert on real UI/network). The check is a heuristic over the method source; the authoritative
judgement stays with the reviewer, but the flag makes a count-only test fail `gate` out of the
box.

**A3 — No "file exists" as evidence.** Evidence files must contain a verdict marker — one of
`FAILURES: 0`, `TEST SUCCEEDED`, `PASS:`, `ok `, or (for screenshots) the native-pane marker —
not merely exist. `promote` and `gate` reject evidence whose content has no marker. This kills
the `ls`/`test -f` evidence pattern.

**A4 — No vacuous regression tests.** `tested`/`native` require red-green (G7). A test that
passes both before and after the change validates nothing; the evidence must include the red
run.

**A5 — No "native" without a runtime proof.** `native` requires G10 (a UI/runtime assertion
that the native pane is shown). A source-file grep that finds a SwiftUI view is **not** native
evidence; the dual-render gate + G10 close the "native row renders web" class.

**A6 — No claiming a capability with an open card.** `promote` refuses when a non-`done` card
already carries `CAPABILITY: <cap>`. This is the duplicate-effort guard at write time.

**A7 — Demotion honesty.** `gate` checks the *highest* claim is still true. If the cited card
was reopened or the backing test was deleted, the row is reported stale and must be demoted
(`cap.py promote S13 claimed …` or lower). CI can't see the board, so the steward runs this.

---

## 7. How the steward uses the map to propose work without duplicating

Steward's job (hourly or nightly):

1. **`./scripts/cap.py plan`** — emits capabilities where `disposition ∈ {native, hybrid}`,
   `status ∈ {absent, claimed}`, and **no open card** carries their `CAPABILITY:` marker.
   (The "no open card" join against the board DB is what stops the `t_0230e17e` re-scan class.)
2. **Propose** — for each candidate, create a card with `CAPABILITY: <cap>` in the body and
   `--idempotency-key "cap:<cap>"`, parented/scheduled per the existing single-tree
   serialisation rules. Re-running the job returns the same card (idempotency key), never a
   second one.
3. **Post-completion verify** — when a card lands `done`, run `./scripts/cap.py gate <cap>`.
   Non-zero → the promotion was false; open a **repair card** (linked to the capability), not a
   duplicate feature card. Zero → the row stands and `plan` stops proposing it.

The steward never creates a card for a capability whose `query` verdict is anything but
`ABSENT`, and never for one with an open card. Deduplication is now a property of the query,
not of the steward remembering.

---

## 8. MVP cutline (agent-days)

| Work item | Size |
|---|---|
| Author `docs/capability-map.tsv` (40 rows) from `native-inventory.md` §1/§4 + `component-map.md` | 0.5 |
| `scripts/cap.py` core: `gen`, `query`, `status`, `promote`, `gate`, `plan`, `ci-check` | 1.5–2 |
| Anti-gaming linters A1/A2/A3 + gates G4/G5/G7 (grep/parse over Swift test sources) | 1 |
| CI `parity` job + wire into `release.yml` | 0.5 |
| Steward cron (plan/propose + post-completion `gate`) | 0.5–1 |
| **Backfill** existing `done` capabilities to the new evidence standard | 2–4 |
| **Total** | **~6–9** |

The backfill is the real cost: ~40 surfaces already exist, most lack a recorded `test` and
red-green evidence. Cutline strategy: backfill everything at **`claimed`** (cheap — card id +
build note), then promote to `tested`/`native` opportunistically as the relevant test exists.
That caps the initial investment while immediately making `query` honest about what is and is
not proven.

**Explicitly out of MVP (v2):** protocol capabilities (REST endpoint / WS-event rows in the
map); auto-hooking `qa-mutants.py` into `gate`; auto re-run of `gate` when a card is reopened
(A7 enforcement by cron, not by the dispatcher); cross-surface dependency inference.

---

## 9. Failure modes this design is checked against

| Symptom (today) | Mechanism that prevents it |
|---|---|
| Duplicate card (`t_0230e17e`) | `query` verdict ≠ ABSENT → no card; `promote` A6; steward `plan` excludes open-card capabilities |
| Thread pane, no back button (`t_1617a61c`) | `native` requires G10 runtime proof; `claimed` alone never certifies "works" |
| Channel header never visible (`t_05caa678`) | same as above — a `claimed`/`tested` row still shows `native: NOT PROVEN` in `query` |
| Notifications accepted, never presented (`t_6a2b0fb4`) | `tested` requires G4 (no skip) + G6 (fresh pass) + G7 (red-green); a skipped or count-only test can't advance it |
| "Native" rows render web | G8/G9 dual-render gate + G10 native-pane runtime assertion |
| Reviewer re-derives intent | §3.3 three mechanical reads; `gate` re-runs the promotion predicates |
| CI red nobody reads | §5 single deterministic command, one-line fixes, board-dependent checks moved to steward |
