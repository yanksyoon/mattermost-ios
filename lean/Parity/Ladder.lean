import Parity.Basic

/-!
# The ladder and the per-row detectors

Transcribed from `docs/parity-map-design.md` §3.2 (the status ladder), §3.3 (the finding table) and
§5.1 (MOVE before STALE), as amended by the implementation deltas that the differential forced:

* **Delta 5** — the ladder is monotone: each rung adds proof, so `validated` requires `tested` as
  well as the three verdict clauses. A fresh verdict on a key that no test names reads `claimed`.
  This is the one place where the paragraph in `scripts/reference.py` and its own table disagree;
  the table (and `parity/generate.py`) are authoritative, and the disagreement is recorded as a
  finding on the card, not fixed by editing the reference in passing.
* **Delta 6** — `UNCARDED-GAP` fires for a key with no claim, or a claim naming no native path, and
  no card. A key with paths but no fresh verdict is a validation gap, surfaced by
  `VALIDATED-BUT-NOT-APPROVED`.

Every fact the ladder reads is a `Bool` oracle on a `Row`: git ancestry, `stat`, the registry parse
and the evidence resolution were computed by the Python tool. **Nothing here proves anything about
git, the filesystem or Swift** — that is the boundary (`docs/parity-verification-design.md` §4). What
is proved is that the *rules* do what the design says they do, on the facts a detector supplies.

`F1` (a native screen broken at runtime) is outside this file by construction: no Boolean the
checker can compute is true exactly when a screen works.
-/

namespace Parity

/-- The five rungs of design §3.2, in order. -/
inductive Status where
  | absent
  | claimed
  | tested
  | validated
  | native
  deriving DecidableEq, BEq, Repr

/-- The ladder's order, made explicit: every step up adds proof. Nothing below is monotone *in
evidence* — `STALE-EVIDENCE` must be able to demote a `validated` key — only the ladder's own order
is fixed. (`deriveStatus_monotone` is deliberately **not** proved; see the design doc §3.) -/
def Status.rank : Status → Nat
  | .absent => 0
  | .claimed => 1
  | .tested => 2
  | .validated => 3
  | .native => 4

/-- Where a claim's native paths are. `missing` is "named but not on disk": STALE territory. -/
inductive PathState where
  | none
  | missing
  | present
  deriving DecidableEq, BEq, Repr

def PathState.isPresent : PathState → Bool
  | .present => true
  | _ => false

def PathState.isMissing : PathState → Bool
  | .missing => true
  | _ => false

def PathState.isNone : PathState → Bool
  | .none => true
  | _ => false

/--
The facts the ladder reads, and only these — `scripts/reference.py`'s fact tuple, collapsed to the
five facts the ladder actually branches on (`ancestor ∧ clean ∧ evidence` is one: a verdict that is
fresh by all three clauses).
-/
structure Facts where
  claimed : Bool
  pathPresent : Bool
  tested : Bool
  /-- `ancestor ∧ clean ∧ evidence`: a verdict that is fresh by every clause of design §3.2. -/
  freshVerdict : Bool
  approved : Bool
  deriving DecidableEq, Repr

/-- The status ladder. Derived, never typed: this is the only place a status is produced. -/
def ladder (f : Facts) : Status :=
  if f.claimed && f.pathPresent then
    if !f.tested then
      .claimed
    else if !f.freshVerdict then
      .tested
    else if f.approved then
      .native
    else
      .validated
  else
    .absent

/-- One row of the join: a claim, the detectors' verdict on its paths, tests, verdict and registry
membership, plus the two bookkeeping facts the findings need. -/
structure Row where
  claim : Bool
  path : PathState
  test : Bool
  ancestor : Bool
  clean : Bool
  evidence : Bool
  approved : Bool
  hasVerdict : Bool
  hasCard : Bool
  /-- The key is in `upstream-keys.tsv` (a claim naming a key that is not is `ORPHAN`). -/
  keyed : Bool
  /-- Content identity found the same bytes at a surviving path (`MOVE`). -/
  moved : Bool
  /-- The row's `content_sha` differs from the pin's (`UPSTREAM-MOVED`). -/
  upstreamMoved : Bool
  deriving DecidableEq, Repr

/--
Design §5.1: **MOVE is evaluated before STALE is finalised**. A path that is missing, on a row whose
content identity was found at a surviving path, is read as present — so a refactor is not reported as
a deletion. Everything downstream (`ladder`, `findFatal`) reads this function, not `r.path`.
-/
def resolvePath (r : Row) : PathState :=
  match r.path with
  | .missing => if r.moved then .present else .missing
  | p => p

/-- The ladder's view of a row. -/
def Row.facts (r : Row) : Facts :=
  { claimed := r.claim,
    pathPresent := (resolvePath r).isPresent,
    tested := r.test,
    freshVerdict := r.ancestor && r.clean && r.evidence,
    approved := r.approved }

/-- Fatal findings: the mapping itself is lying (design §3.5, exit 1). -/
inductive FatalFinding where
  | stale
  | orphan
  | unmapped
  | mapIncomplete
  | staleVerdict
  | staleEvidence
  | paneNotApproved
  deriving DecidableEq, Repr

/-- Report findings: legal states that must be named (design §3.5, exit 0). -/
inductive ReportFinding where
  | gap
  | uncardedGap
  | move
  | upstreamMoved
  | approvedWithoutVerdict
  | validatedButNotApproved
  deriving DecidableEq, Repr

/-- A finding, tagged by severity, because the exit code is a function of the tag. -/
inductive Finding where
  | fatal : FatalFinding → Finding
  | report : ReportFinding → Finding
  deriving DecidableEq, Repr

def fatalIf (b : Bool) (f : FatalFinding) : List FatalFinding :=
  if b then [f] else []

def reportIf (b : Bool) (f : ReportFinding) : List ReportFinding :=
  if b then [f] else []

/-- The per-row fatal detectors (design §3.3). -/
def findFatal (r : Row) : List FatalFinding :=
  fatalIf (r.claim && (resolvePath r).isMissing) .stale
  ++ fatalIf (r.claim && !r.keyed) .orphan
  ++ fatalIf (r.hasVerdict && !(r.ancestor && r.clean)) .staleVerdict
  ++ fatalIf (r.hasVerdict && !r.evidence) .staleEvidence

/-- The per-row report detectors (design §3.3, narrowed by Delta 6). `APPROVED-WITHOUT-VERDICT` is
surface-level (one finding per approved surface with no native key), so it is not a row finding and
is not emitted here; `UNMAPPED` and `MAP-INCOMPLETE` are key-list-level for the same reason. -/
def findReport (r : Row) : List ReportFinding :=
  reportIf (r.claim && (resolvePath r).isNone) .gap
  ++ reportIf ((!r.claim || (resolvePath r).isNone) && !r.hasCard) .uncardedGap
  ++ reportIf r.moved .move
  ++ reportIf r.upstreamMoved .upstreamMoved
  ++ reportIf (ladder r.facts == .validated && !r.approved) .validatedButNotApproved

/--
The record as a join: a `World` maps a key to its row. The `World` is *populated* elsewhere — by git
plumbing, the filesystem, the Swift registry literal and the join key itself. Every historical
failure except F5 lives in that population; the theorems below therefore quantify over a `World`
that is assumed, not constructed. This type is the boundary, drawn in code.
-/
structure World where
  row : Key → Row

def deriveStatus (w : World) (k : Key) : Status :=
  ladder (w.row k).facts

def findFindings (w : World) (k : Key) : List Finding :=
  (findFatal (w.row k)).map Finding.fatal ++ (findReport (w.row k)).map Finding.report

/-! ## The properties, each closed by exhaustive evaluation of five Booleans

The proofs are `decide` over the 32 possible fact tuples (2⁵). Exhaustive because the fact space is
finite and tiny — the same reason `scripts/reference.py` can be a hand-typed 128-row table, and the
reason a *proof* here is cheap while a proof about git is not.
-/

/-- `absent` is not a default that a stale row falls into: no claim means no row at all. -/
theorem no_claim_is_absent (f : Facts) : f.claimed = false → ladder f = .absent := by
  rcases f with ⟨c, p, t, v, a⟩
  cases c <;> cases p <;> cases t <;> cases v <;> cases a <;> decide

/-- A claim that names nothing that exists reads `absent`, whatever else is true about it. -/
theorem no_path_is_absent (f : Facts) : f.pathPresent = false → ladder f = .absent := by
  rcases f with ⟨c, p, t, v, a⟩
  cases c <;> cases p <;> cases t <;> cases v <;> cases a <;> decide

/-- **The rungs are ordered by proof.** `native` implies every earlier rung's evidence is present:
a claim, a real path, a test, a fresh verdict, and the registry. Nothing reaches the top by a route
that skips a rung. -/
theorem native_implies_every_rung (f : Facts) :
    ladder f = .native →
      (f.claimed = true ∧ f.pathPresent = true ∧ f.tested = true
        ∧ f.freshVerdict = true ∧ f.approved = true) := by
  rcases f with ⟨c, p, t, v, a⟩
  cases c <;> cases p <;> cases t <;> cases v <;> cases a <;> decide

/-- **Delta 5, as a theorem.** A verdict cannot lift a key that no test names: `validated` requires
`tested`. This is the rule the differential forced and the one that keeps an observation-only
verdict from reading as proof. -/
theorem verdict_cannot_lift_untested (f : Facts) :
    ladder f = .validated → f.tested = true := by
  rcases f with ⟨c, p, t, v, a⟩
  cases c <;> cases p <;> cases t <;> cases v <;> cases a <;> decide

/-- `native` is the conjunction, not a rung reachable another way: no row is `native` unless its
surface is in the parsed registry. A registry flip without a verdict cannot upgrade a key. -/
theorem native_implies_approved (f : Facts) : ladder f = .native → f.approved = true := by
  rcases f with ⟨c, p, t, v, a⟩
  cases c <;> cases p <;> cases t <;> cases v <;> cases a <;> decide

/-- **MOVE excludes STALE.** On a row whose content identity was found at a surviving path, the
resolved path is never `missing`. The ordering claim — that the Python tool calls this resolution
*before* it finalises STALE — is a claim about `parity/generate.py`, not proved here. -/
theorem moved_is_never_missing (r : Row) (h : r.moved = true) :
    (resolvePath r).isMissing = false := by
  cases hp : r.path with
  | missing => simp [resolvePath, PathState.isMissing, hp, h]
  | none => simp [resolvePath, PathState.isMissing, hp]
  | present => simp [resolvePath, PathState.isMissing, hp]

/-- The STALE branch's own guard is false on a moved row, so `findFatal` cannot emit `STALE` for a
refactor: the detector reads exactly this condition. -/
theorem moved_stale_guard_is_false (r : Row) (h : r.moved = true) :
    (r.claim && (resolvePath r).isMissing) = false := by
  rw [moved_is_never_missing r h]
  simp

/-- **Two records that agree on every field a detector reads derive the same status and the same
findings.** The design's phrase "derived, never typed" made checkable: nothing outside `World.row`
can influence an answer, so a disagreement between two runs is a disagreement about facts, never a
difference of clock, ordering or state. -/
theorem records_agree (w v : World) (k : Key) (h : w.row k = v.row k) :
    deriveStatus w k = deriveStatus v k ∧ findFindings w k = findFindings v k := by
  unfold deriveStatus findFindings
  rw [h]
  exact ⟨rfl, rfl⟩

end Parity
