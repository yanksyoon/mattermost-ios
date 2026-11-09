# Parity verification — what is proved, what is tested, what is assumed

Status: **the Lean artefact is verified exclusively by CI job `lean` in
`.github/workflows/parity-lean.yml`**. No Lean toolchain is installed on the development host — that
is the expected state, not a missing step (owner decision on card `t_22c3f1ea`). `scripts/lean_check.sh`
prints that sentence and exits 0; it never installs a toolchain and never reports a proof it did not
compile.

The blocking local checks are unchanged and do not depend on Lean at all:

```
python3 parity/generate.py --self-test     # asserts + seven planted faults + two-run byte compare
python3 scripts/differential.py            # 128 status worlds + docstring ladder + 10 finding worlds vs reference.py
python3 scripts/mutate-test.py             # seven detector mutants, each must kill its own fault
python3 parity/generate.py --check --report
```

---

## 0. The question this document answers

Card `t_22c3f1ea` asked whether Lean can prove the parity checker
(`parity/generate.py`, `docs/parity-map-design.md`) correct. Two review rounds — a formalist and an
adversary — reached the same answer: **no**, and named the one property where a proof is worth more
than a test. This document records the answer, the property, and the boundary between them, so that a
future reader cannot mistake the green CI badge for a stronger claim than it is.

---

## 1. What the review established: the quantifier

A proof about `deriveStatus` and `findFindings` quantifies over a `World` that **git plumbing, the
filesystem, the Swift registry literal and the join key have already populated**. The theorem is about
what happens *after* the facts are known. Every historical failure of the parity record except one
lives in that population, i.e. before the proof begins:

| # | failure | where it lives | a proof about `World → Status` touches it? |
|---|---|---|---|
| F1 | a native screen is broken at runtime, status says `native` | the running app | no — no static tool reaches it; the live `-AV` suite does |
| F2 | a proof screenshot was pruned, the verdict still reads `ok` | evidence-resolution plumbing (does the ref still exist?) | no — the *rule* is modelled, the plumbing is not |
| F3 | the owner flips the registry literal, no verdict exists | the Swift literal ↔ verdict ledger join | no — the join is modelled as a Bool oracle |
| F4 | a refactor reads as "the feature was deleted" | path/rename handling in git | no — the ordering is modelled, the detection is not |
| **F5** | **a content sha inside the join key** | **inside a pure function — the join** | **yes. This is Lean's one job.** |

F5 is the earlier proposal `M:app/screens/<module> @ <blob-sha>` (`docs/parity-map-design.md` §1.1):
with the content address inside the key, every upstream bump orphans every claim whose file changed,
and the record answers "absent" for a capability that is fully implemented. It is a contradiction
that lives entirely in a function of the key, which is the one kind of claim a proof can settle.

Two things the adversary conceded, and this document adopts:

* **Fault witnesses decoupled from detectors are stronger than asserts co-located with them.** That
  is why `scripts/mutants/*.diff` exist: a mutant is a wrong implementation the detector must reject,
  not an assertion the detector carries about itself.
* **`selftest_detects` ("six faults are a complete witness set") is a truism** — six samples say
  nothing about fault seven. The Lean proofs below are held to the same standard: where a proof only
  restates a definition, it is labelled as such and is not counted as coverage.

---

## 2. The coverage matrix

Rows are the five failures. Columns are the instruments that exist today. "Lean" is the `lean/`
package in this change; the others are the blocking checks named at the top.

| failure | Lean (`lean/`) | `reference.py` + `differential.py` | mutation (`mutate-test.py`) | `--self-test` asserts | live `-AV` suite | residual hole |
|---|---|---|---|---|---|---|
| **F1** runtime breakage while status says `native` | **no** — by construction; no Boolean the checker can compute is true exactly when a screen works | no | no | no | **yes** — the only instrument that touches a running app | a screen must be driven to be judged; nothing static closes this |
| **F2** evidence pruned, verdict still fresh | the **rule** is proved (`ladder` cannot reach `validated`/`native` with `freshVerdict = false`) — one of the five facts in `Facts` | **yes** — world `verdict-evidence-missing` → `STALE-EVIDENCE`; assert 5 asserts the demotion | **yes** — `scripts/mutants/stale_evidence.diff` | **yes** — fault 5 (deleted screenshot) fires alone | no | the *plumbing* (does this ref resolve **to the case it names**?) is only exercised by fixture worlds; a ref resolving to a different case would pass |
| **F3** registry flip with no verdict | the **join** is proved: `native_implies_approved`, and `native` requires every earlier rung, so approval alone cannot upgrade a key | partly — `VALIDATED-BUT-NOT-APPROVED` in the finding worlds; `APPROVED-WITHOUT-VERDICT` is surface-level and outside the per-row table | **yes** — `approved_without_verdict.diff` | **yes** — fault 6; assert 3 parses the literal and checks pane-owning ⊆ approved | partly (an owner decision is a human act) | the Swift literal is *parsed*, and the parse is asserted only to succeed — not that it parsed the same list it parsed yesterday |
| **F4** refactor reads as "feature deleted" | the **ordering rule** is proved: `moved_is_never_missing`, `moved_stale_guard_is_false` — a moved row can never be `missing`, and the STALE guard reads that function | no — MOVE is not in the status or finding tables | **yes** — `scripts/mutants/move.diff` disables the before-STALE resolution, so a planted rename reports `STALE` and the set kills it (t_93d9cafb) | **yes** — fault 7 (`MOVE`) asserts the *emitted finding kind*, not just rename detection assert 4 | no | the detector's heuristics (`git log --follow`, then content identity) are still exercised only by fixtures; the ordering claim is now pinned by a mutant |
| **F5** content sha inside the join key | **YES — the only theorem with teeth.** `join_key_injective`, `join_key_ignores_content`, and the negative `sha_in_key_is_not_a_function_of_identity` | no | no | **yes** — assert 1 asserts the sha *shape* (`M:app/screens/thread@9f3a8c1`), and `key_is_well_formed` refuses an M: key whose last `@`-segment is 7–40 lowercase hex (t_93d9cafb; `scripts/probe_key_grammar.py`) | no | the grammar now forbids the shape, so a key built with a sha would be a `MALFORMED ROW` at load time; what is still unproved about the tool is that *nothing prevents a future grammar widening* except that probe |

Reading the table honestly: **Lean adds coverage on exactly one row (F5), strengthens one rule on F2
and F3, and closes nothing on F1 or the F4 plumbing.** Its value is that F5 now has a statement with a
proof and a counterexample, in a place where four other instruments are silent.

---

## 3. The model (`lean/`)

Self-contained Lake package, **no Mathlib**, toolchain pinned in `lean/lean-toolchain`. No
dependencies at all — a dependency bump is how a proof rots, and a proof that needs Mathlib would be
cut in scope instead.

| file | contents |
|---|---|
| `lean/Parity/Basic.lean` | `Namespace`, `ContentSha`, `Identity`, `Key`, `Addressed`, `ShaKey` (the rejected scheme, kept as the mutant), `Surface` + `Surface.approved` |
| `lean/Parity/Join.lean` | F5: the join-key theorems |
| `lean/Parity/Ladder.lean` | `Status` + `rank`, `PathState`, `Facts`, `ladder`, `Row`, `resolvePath`, `FatalFinding`/`ReportFinding`/`Finding`, `findFatal`/`findReport`, `World`, `deriveStatus`, `findFindings`, the ladder theorems |
| `lean/Parity.lean` | imports |

`World` is `Key → Row`, and every fact a `Row` carries is a `Bool` (or a three-valued `PathState`):
ancestry, cleanliness, evidence resolution, registry membership. **The oracles are the boundary drawn
in code** — the model does not contain, and cannot reason about, how they were computed.

The ladder is transcribed from `docs/parity-map-design.md` §3.2 as amended by **Delta 5** (the ladder
is monotone: `validated` requires `tested`) and **Delta 6** (`UNCARDED-GAP` only for real gaps). It was
transcribed from the *design*, not from `generate.py`, exactly as `scripts/reference.py` was — a model
copied from the implementation would make every agreement between them a tautology.

### The theorems, and what each does not say

| theorem | plain English | what it does **not** say |
|---|---|---|
| `join_key_injective` | two identities that differ in either field get different keys; the join never collapses two distinguishable upstream units onto one row | that `generate.py` uses this grammar — that is tested, not proved |
| `join_key_ignores_content` | a row's key is unchanged when its content address changes | same |
| `same_identity_same_key`, `upstream_bump_keeps_the_key` | the same capability before and after an upstream bump keeps one key | same |
| `sha_in_key_is_not_a_function_of_identity` | **the negative half**: no scheme that puts the address in the key can be a function of identity, because the same capability would then have two keys | that the rejected scheme was ever shipped — it was not; it is here so the property has a witness that violates it |
| `no_claim_is_absent`, `no_path_is_absent` | `absent` is earned, not a default a stale row falls into | that a claim's absence was detected correctly |
| `native_implies_every_rung` | `native` requires claim, path, test, fresh verdict and approval — no rung is skipped | that those five facts are true |
| `verdict_cannot_lift_untested` | **Delta 5 as a theorem**: a verdict cannot lift a key no test names | that the differential's table matches this (it does — that is tested) |
| `native_implies_approved` | a registry flip alone cannot upgrade a key | that the Swift literal says what `Surface.approved` says |
| `moved_is_never_missing`, `moved_stale_guard_is_false` | **MOVE excludes STALE** at the function level: a moved row's resolved path is never `missing`, and the STALE branch's guard is false | that `generate.py` calls the resolution *before* it finalises `STALE` |
| `records_agree` | the answer is a function of the row: two records that agree on every field a detector reads derive the same status and the same findings | that the row was populated correctly |

### Deliberately not attempted: `deriveStatus_monotone`

Monotonicity of status over an evidence set is the **wrong property**. The ladder must **demote** a
key on `STALE-EVIDENCE`, and monotonicity over a set that still contains the stale evidence is
compatible with the very bug it would be claimed to exclude. A proof of the wrong property is worse
than no proof: it reads as coverage. What is proved instead is the *ordering of the rungs*
(`native_implies_every_rung`) and the *Delta 5 gate* (`verdict_cannot_lift_untested`), neither of
which forbids demotion.

---

## 4. The boundary — read this before quoting a theorem

1. **Git plumbing is an assumption.** Ancestry, "no commit after the verdict touched the claimed
   files", the file's existence, `git hash-object` content identity: none of it is proved, all of it
   is `Bool` inputs. A theorem about `World` says "if the detector computed these booleans, the ladder
   does this". It says nothing about whether the detector computed them correctly.
2. **The transcription is unsigned.** The Lean model was written by hand from the design document,
   not generated from `parity/generate.py`. A green build means *the proof is valid*, not *the model
   is the tool*. **Python and the Lean model agreeing is TESTED (`scripts/differential.py` against the
   hand-authored `scripts/reference.py`), never proved.** That sentence is the point of this
   document and must not be softened in later edits.
3. **The registry literal is a third copy.** `Surface.approved` in `lean/Parity/Basic.lean` is
   transcribed from `Mattermost/Core/RenderMode.swift`, which `generate.py` parses. Three copies
   exist; no theorem relates them.
4. **F1 is out of reach by construction.** A screen that renders and misbehaves has no static
   witness. The live `-AV` suite is the instrument, and it is not replaceable by any of this.
5. **A green CI job is not a required check on unrelated paths.** See §5: the Lean job is skipped
   when nothing it describes has changed, and a skipped job satisfies the required check. That is
   deliberate — a proof job that runs on every PR becomes background noise and is eventually ignored.

---

## 5. Where this runs (CI only)

* **Job**: `lean` in `.github/workflows/parity-lean.yml`. `lake build` on `ubuntu-latest`, toolchain
  from `lean/lean-toolchain` (elan via `leanprover/lean-action@v1`), cache of `~/.elan` and
  `lean/.lake` keyed on the sha256 of `lean-toolchain`.
* **Relevant paths**: `lean/**`, `parity/**`, `.github/workflows/parity-lean.yml`. A change to the
  parity record is a change to the thing the model claims to describe, so it re-runs the proof job.
  On a pull request the relevance is computed over the **whole PR diff**, so every push to a PR that
  touches `lean/` runs the gate even when that particular push is only a doc edit — intended, and it
  is why the PR carrying this document shows the `lean` job on its last commit too.
* **The workflow must exist on the base ref.** A workflow file that lives only on a feature branch
  does not run for a PR opened against `main`: `pull_request` workflows are taken from the merge ref
  of base and head, and a branch based on `main` does not contain `lean/`'s workflow file. Before
  this landed, a probe PR off `main` produced **no run at all** (PR #2, closed unmerged) — not a skip,
  no run. The filter was therefore verified with the Lean branch as the PR base instead (run
  `41942231351`, §8).
* **Why the relevance decision is a job and not a trigger filter.** The card asked for
  `on: pull_request: paths: [...]` **and** for the check to be required. Those cannot coexist: a
  required check that never reports leaves every unrelated pull request at "Expected — waiting for
  status to be reported", forever. So `pull_request` is unfiltered, a ~10s `changes` job computes the
  same path relevance with `git diff`, and the `lean` job is skipped when nothing relevant changed
  (a skipped job satisfies a required check). Relevant change ⇒ a real gate; unrelated change ⇒ not in
  the way. Pushes to `main` keep the trigger-level path filter — a push needs no required check, and a
  push that cannot have changed the proof should not spend a run.
* **Local**: no toolchain, and none is installed. `scripts/lean_check.sh` prints
  `Lean is verified in CI only: .github/workflows/parity-lean.yml (see docs/parity-verification-design.md)`
  and exits 0. If a toolchain does happen to be present it runs the same `lake build` and nothing else.

### What is deliberately not done yet, and why

* **The PR is green and unmerged.** Its head commit has a green `lean` run, but the branch sits on the
  local `main`, which is three commits ahead of `origin/main` — and those three commits are other
  cards' work that their own handoffs declared *local-only* (`69c7bf4` the parity record, `12e244f`
  the capability scan, `8ab30cf` a WebSession fix). Merging would publish them. That is a decision for
  the owner, not a side effect of a proof card; and rebasing this branch onto `origin/main` alone
  would leave this document describing a `parity/` record that is not on `main`.
* **The `lean` check is not registered as required yet.** It cannot be, in the only order that does
  not break other work: a ruleset that requires `lean` on `refs/heads/main` *before* the workflow
  exists there makes every unrelated PR wait for a check that can never be reported — the mirror image
  of the trap in §5. An attempt to register it non-blockingly was rejected by the plan:
  `gh api -X POST repos/yanksyoon/mattermost-ios/rulesets` with `"enforcement": "evaluate"` returns
  `422 Enforcement evaluate option is not supported on this plan`. So the order is: land the branch,
  then create the rule in `active` mode. The exact body is in §8; the check name to require is `lean`
  (the job name, not the workflow name).


---

## 6. Findings recorded while building this (not softened)

These were found by building the model, not by looking for them; they are reported rather than fixed
here, because each one belongs to the parity record, not to the proof. Card `t_93d9cafb` (the parity
record's own repair card) has since fixed all three; each entry keeps its original text and records
the repair under it.

1. **`scripts/reference.py`'s prose contradicts its own table.** The docstring states the ladder as
   `otherwise -> native if approved else validated`, which makes the world `1 1 0 1 1 1 1` `native`;
   the table itself (and Delta 5, and `generate.py`) say `claimed`. The table is right; the paragraph
   is stale since the Delta 5 correction that the same file's changelog records. The reference is a
   file whose own header says a diff needs a second reviewer, so it is reported here rather than
   edited in passing.
   *Repair (t_93d9cafb):* the paragraph now reads `otherwise -> claimed if not test; else native if
   approved else validated`, and `scripts/differential.py` check 2 reads that paragraph back and
   diffs it against all 128 rows, so prose and table cannot diverge again. Run before the fix, that
   check failed on exactly the two `test=0` worlds (`1 1 0 1 1 1 0`, `1 1 0 1 1 1 1`). A changelog
   line records the edit; a second reviewer is still required by the file's header.
2. **The key grammar accepts the F5 shape.** `assert 1` in `--self-test` prints "a sha in the key is
   rejected", but its only check is `not key_is_well_formed("S13")` — a malformed *namespace*.
   `M:app/screens/thread@9f3a8c1` passes `KEY_PATTERNS["M"]` (the class includes `@`), verified with
   `python3 scripts/probe_key_grammar.py`. So F5's shape is currently excluded only by the fact that
   `generate.py` never appends a sha when building keys — nothing tests that either. This is the
   strongest argument for the Lean theorem in this change and the strongest argument for a follow-up
   on the record.
   *Repair (t_93d9cafb):* `key_is_well_formed` now also refuses the shape — an `M:` key whose last
   `@`-segment is 7–40 lowercase hex (`key_carries_content_sha`) — `assert 1` asserts
   `M:app/screens/thread@9f3a8c1` is rejected, and `scripts/probe_key_grammar.py` fails if either
   fact moves. `@` stays in the M class (measured first: `grep -c '@' parity/upstream-keys.tsv` is
   0), and no live key changed, so `parity/out/*` needed no regeneration.
3. **No mutant covers MOVE-before-STALE.** The six mutants are `stale`, `orphan`, `unmapped`,
   `stale_verdict`, `stale_evidence`, `approved_without_verdict`. Design §5.1 says `--self-test` plants
   a pure rename and asserts the finding kind is `MOVE`, not `STALE`; assert 4 asserts rename
   *detection* only.
   *Repair (t_93d9cafb):* fault 7 of `--self-test` plants a pure rename and asserts the emitted kind
   is `MOVE`, and `scripts/mutants/move.diff` disables the before-STALE resolution so that rename
   reports `STALE` — the set kills it, 7/7. While adding the assert it turned out MOVE never fired at
   all: the survivor substitution made `paths_state` `present`, so the `STALE`-to-`MOVE` conversion
   was unreachable. MOVE now emits from the recorded moves directly, after the resolution and before
   the findings are sorted.

---

## 7. What would make Lean worth more (and why it is still the right cut)

The next real step is not a bigger proof; it is **a smaller gap between the model and the tool**:
extract the pure core of `parity/generate.py` (`derive_status`, `find_row_findings`, the key grammar)
into a form both the Python tool and the Lean model are generated from, or into a pure function the
tool calls and a property test pins. Today the two are kept honest by testing
(`differential.py`, `mutate-test.py`), and that is the honest state: a proof about a hand transcription
of a tool is a proof about the transcription.

The cut taken here — one theorem with a counterexample, on the one failure that lives inside a pure
function — is the part of the question that has an answer. Everything else in the table above is
covered by running something, and the document says which thing.

---

## 8. Iteration record (measured, not remembered)

Environment: GitHub-hosted `ubuntu-latest`, Lean from `lean/lean-toolchain` (`v4.15.0`) installed by
`leanprover/lean-action@v1`. **Nothing was compiled on the development host** — no toolchain exists
there, by owner decision — so every number below is a runner's.

| cycle | run | outcome | what it forced |
|---|---|---|---|
| 1 | [41941054594](https://github.com/yanksyoon/mattermost-ios/actions/runs/41941054594) | red | `lean-action` refuses to configure without `lake-manifest.json`. The manifest is now committed (the package has zero dependencies) and `lake update` regenerates it in the build step, so a hand-written manifest cannot become a stale-format trap |
| 2 | [41941189898](https://github.com/yanksyoon/mattermost-ios/actions/runs/41941189898) | red | three real Lean errors: core Lean exports no `Function.Injective` (the theorem is stated as the implication it is); `injection … with` already closed the goal, so the following `exact` had nothing to solve; and `decide` over the 12-field `Row` literal fails with "expected type must not contain free variables", so the two MOVE lemmas were restated over `cases` on the path |
| 3 | [41941487416](https://github.com/yanksyoon/mattermost-ios/actions/runs/41941487416) | **green** at commit `1a91635` | `✔ [2/6] Built Parity.Basic`, `✔ [3/6] Built Parity.Join`, `✔ [4/6] Built Parity.Ladder`, `✔ [5/6] Built Parity`, `Build completed successfully.` — `join_key_injective` compiles, along with the rest of the package |
| 4 | [41941696516](https://github.com/yanksyoon/mattermost-ios/actions/runs/41941696516) | **red on purpose** | the gate is not green by vacuity. One-line mutation `joinKey (i) := ⟨i.ns, ""⟩` — the F5 failure shape, every path in a namespace collapsing onto one key — and `join_key_injective` fails to elaborate at `Parity/Join.lean:35` (`'change' tactic failed`). The branch `lean/mutation-check-t_22c3f1ea` is kept as the witness and must never be merged |
| 5 | [41942231351](https://github.com/yanksyoon/mattermost-ios/actions/runs/41942231351) | **skipped** | the path filter decides. An empty commit on top of the Lean branch, PR'd against the Lean branch (a workflow must exist on the base ref to run at all — the probe against `main`, PR #2, produced *no run*, which is why the base here is `lean/t_22c3f1ea`): `relevant-paths` success, `relevant=false`, job `lean` **skipped**. An unrelated change is not in the way, and a required check still reports |

Wall clock: first push `00:24:13Z` → first green `00:28:19Z` = **4m06s**, three runs, none of them
local. Measured build: the `lake build` step is **2 s** with the toolchain cache warm (four modules,
no Mathlib); the `lean` job is 23 s and the whole workflow 36 s, so the cost is runner overhead, not
the proof. A cold run pays the elan + toolchain download once (~200–400 MB); the cache key is
sha256(`lean/lean-toolchain`), so exactly a toolchain change invalidates it.

Cycle count against the card's budget: **3 red/green cycles to land, 1 deliberate red to falsify the
gate, 1 skip to check the filter** — well inside the 10–30 expected for a first proof, and no cycle
was spent weakening a statement.

The head of this branch carries its own green run — the PR's checks are the record, and the first
green (on the commit that first compiled all four modules) is
[41941487416](https://github.com/yanksyoon/mattermost-ios/actions/runs/41941487416) at `1a91635`.

### Landing it (the exact commands, for whoever decides to publish)

```
# Fast-forward the branch onto main. Local main is 3 ahead / 0 behind origin/main, so this publishes
# the branch's seven commits as they are — a squash would fold four cards into one commit.
git push git@github.com:yanksyoon/mattermost-ios.git lean/t_22c3f1ea:main

# Then, only once parity-lean.yml is on main, make the check required (job name `lean`):
gh api -X POST repos/yanksyoon/mattermost-ios/rulesets --input parity-lean-ruleset.json
#   {"name": "parity-lean: required when it exists",
#    "target": "branch",
#    "enforcement": "active",
#    "conditions": {"ref_name": {"include": ["refs/heads/main"]}},
#    "rules": [{"type": "required_status_checks",
#               "parameters": {"strict_required_status_checks_policy": false,
#                              "required_status_checks": [{"context": "lean"}]}}]}
```

`git push` over HTTPS fails on this checkout — `origin` embeds a token GitHub now rejects
(`remote: Invalid username or token`); the SSH remote (`git@github.com:yanksyoon/…`) works and is what
every command in this section assumes.

