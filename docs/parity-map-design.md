# Parity map — deterministic, content-addressed (design of record)

Status: **proposal for implementation**. Replaces the hand-typed prose in `docs/parity.md` /
`docs/native-inventory.md` with a machine-checked map. Everything below is verified against the
repo as of commit `3422d80`.

Repo: `~/Documents/yanks/code/mattermost-ios`. One writer per checkout at a time — this document
is written from a read-only pass; the parent owns the tree and should commit it.

---

## 0. What exists today (verified, not recalled)

| Artifact | Reality | Consequence for this design |
|---|---|---|
| `docs/component-map.md` | Pins live as prose: `M` = mattermost-mobile @ `162f2560d0e1df073220f7701d5a67cc17c8abeb`, `W` = mattermost @ `987e57120dca630dadbcd2638064ab66a02bb81e` (webapp at `webapp/channels/src/`). | No machine-readable pin file. Must be extracted once into data. |
| `docs/native-inventory.md` | 40 rows S01–S40, prose, with an evidence legend (`M:`/`R:`/`L:`/`W:`). | The *bridge seed* for the claims table. |
| `docs/parity.md` | 404 lines, one giant prose row per card T28–T46. Status is "native ✅ (Txx, repaired Txx-R)" typed by hand. | Not joined by any checker; a stale row and a real gap are indistinguishable. |
| `docs/inventory/screens.tsv` | 67 module names + **one junk line** (`refs/mattermost-mobile/app/screens` at line 52) — a hand-grep artifact. | The generator must skip path-shaped junk, and the key list must come from the pinned tree, not this file. |
| `docs/inventory/rest-endpoints.tsv` | 147 rows `module / verb / path`. | `REST:` key source. |
| `docs/inventory/websocket-events.md` | 113 `NAME -> event` lines, prose. | `WS:` key source. |
| `Mattermost/Core/RenderMode.swift` | The **approved registry**: `SurfaceDefaults.nativeApprovedSurfaces = [.auth, .calls, .sidebar, .channelView, .composer, .search, .activity]`, `paneOwningSurfaces = [.channelView]`, 8 `Surface` cases total. Approval ledger is a doc-comment table. | The `native` rung's ground truth. Parse this literal; do not invent a second registry. |
| Swift sources | **Zero** `// parity:` comments (grep = 0). No co-located claims today. | Claims must be backfilled; the bridge file stands in until then. |
| Verdicts | Prose `docs/tXX-av-verdict.md` with a `## VERDICT: FAIL/PASS-WITH-FINDINGS` line; evidence = build notes, `MattermostTests/T*Tests.swift` (1891 tests), `MattermostUITests/T*UITests.swift`, `docs/t*-shots/`, `build/logs/*.log`. | Verdict ledger must be *structured* (JSON); retrofit from these docs, marking stale ones. |
| `parity/` | Does not exist. No generator. | Greenfield. |

**The one structural fact this design hinges on:** the repo already has a machine-readable answer to
"is this surface native in a Release build?" — it is `SurfaceDefaults.nativeApprovedSurfaces`, and it
is enforced by `scripts/verify-dual-render-gates.sh`. The parity map must *parse that literal*, not
re-derive it, or the map and the shipped binary will disagree (they already did once — see failure
mode 3).

---

## 1. Identity and key scheme

### 1.1 The critique that motivates the scheme

The earlier proposal (and the skills that carry it) keys every upstream unit as
`M:app/screens/<module> @ <blob-sha>` — **the content hash inside the join key**. It claims this is
"content-addressed, so a rename that keeps content keeps the key, and the same path with new content
gets a new key."

That claim is wrong on both halves, for a reason worth stating plainly: **the path is also part of
the key**, so a rename changes the key regardless of content, *and* the sha is part of the key, so a
content change changes the key regardless of the fact that it is the same capability. The scheme is
fragile to both renames *and* content changes, while delivering the stability benefit of neither. On
every minor upstream bump — where most files change content but keep their path and their role — a
sha-in-key map produces a wall of `orphan (old sha) + absent (new sha)` pairs, and a ticket-writing
agent asks "is X implemented?" and gets "absent" for a capability that is fully implemented, which is
exactly the duplicated-effort failure this project is trying to kill.

### 1.2 The scheme: identity is the path, the content-address is a column

```
identity (the join key, stable)     content address (drift signal, a column)
───────────────────────────────     ──────────────────────────────────────────
M:<repo-relative path>              content_sha = tree-sha of a dir, blob-sha of a file
REST:<METHOD> <path>                (no content address; the pin is the version)
WS:<event>                          (no content address; the pin is the version)
X:<name>                            (project-owned unit; no upstream counterpart)
```

Rules:

1. **`M:` keys name a path under the pin's `path_prefix`** (`app/` for mobile, `webapp/channels/src/`
   for webapp). A *module* key names a directory (`M:app/screens/thread`); a *component* key names a
   single file (`M:app/screens/channel/header/header.tsx`). You never key a screen on "S13" or a card
   id — `S13`/`T36`/`t_…` are alias columns only, because renumbering must not re-point work.
2. **`content_sha` is `git rev-parse <commit>:<path>`** — the tree sha for a directory, the blob sha
   for a file. One primitive, and it gives a Merkle address: *any* change inside the module moves the
   tree sha, so "upstream moved under me" is detected at exactly the granularity the claim is made at.
3. **`REST:` and `WS:` keys carry no content address** — the API contract is versioned by the pin
   itself. Their `content_sha` column is `-`. (`REST:` keys are normalized to drop `?{params}` —
   `GET /channels/{id}/posts?{params}` and `GET /channels/{id}/posts` are one key.)
4. **`X:` keys must never name an upstream path.** A project-owned unit (accessibility pass,
   notification input layer) gets an `X:` row; an `X:` row carrying an upstream path is a mapping lie
   and fails the checker (same rule as the skills).

### 1.3 Why this is stable

- **Across upstream minor bumps:** a bump changes `content_sha` values but not `key`s. The diff is
  one line per *changed capability* — `M:app/screens/thread: 14e2e7eb → 9f3a…` — and the claim stays
  attached to the same key, so the ticket agent reads "implemented, but upstream moved — re-verify",
  not "absent". The key list itself is regenerated only on a pin bump, so the steady-state gate never
  re-resolves upstream.
- **Across refactors of our own files:** a native refactor moves
  `UI/Native/Thread/ThreadView.swift` → `UI/Native/Thread/Pane/ThreadPane.swift`. The *key*
  (upstream identity) is untouched; only the `native_paths` column of the claim moves. The generator's
  content-identity match (same `git hash-object` content at a new path) emits a `MOVE` finding and
  offers to re-point, instead of a `STALE` finding that reads like "the feature was deleted".
- **Content-addressing still holds where it matters:** identity + `content_sha` together pin exactly
  "this capability at this version", and the pin file pins the whole upstream snapshot by commit sha.
  Nothing is keyed on a human alias.

---

## 2. Record schema (exact columns, every file)

All files live under `parity/`. Every file is a **TSV** (tab-separated, first line a `#`-prefixed
header) except the verdict ledger (JSON). TSV because it diffs cleanly, sorts cleanly, and the
existing `docs/inventory/*.tsv` already established the convention. All files are tracked — the record
lives in the repo and is diffable by construction.

### 2.1 `parity/pins.tsv` — the pins, once, as data

```
# alias	repo	tag	commit	path_prefix	license
M	mattermost/mattermost-mobile	v2.45.0	162f2560d0e1df073220f7701d5a67cc17c8abeb	app/	Apache-2.0
W	mattermost/mattermost	v12.0.1	987e57120dca630dadbcd2638064ab66a02bb81e	webapp/channels/src/	Apache-2.0
```

This is the single machine-readable pin source. `docs/component-map.md` keeps its prose; the generator
reads only this file. `--bootstrap` writes it; after that it changes only on a deliberate pin bump.

### 2.2 `parity/upstream-keys.tsv` — the key list (generated, checked in)

```
# key	namespace	path	content_sha	kind	anchor_of
M:app/screens/thread	M	app/screens/thread	9f3a8…	dir	thread
M:app/screens/channel/header/header.tsx	M	app/screens/channel/header/header.tsx	4cc0a…	file	channel-header
REST:GET /posts/{post_id}/thread	REST	posts.ts	-	rest	threads
WS:thread_updated	WS	websocket.ts	-	ws	threads
X:notification-input	X	-	-	internal	notifications
```

| column | meaning |
|---|---|
| `key` | the join key (§1.2). Globally unique. |
| `namespace` | `M` / `REST` / `WS` / `X`. |
| `path` | repo-relative path (or `-` for `REST`/`WS`/`X`). |
| `content_sha` | `git rev-parse <commit>:<path>`, or `-`. |
| `kind` | `dir` / `file` / `rest` / `ws` / `internal`. |
| `anchor_of` | the human module name this key is the anchor for (feeds `--query`). |

Generated by `git ls-tree -r <commit> <path_prefix>` over the pin, plus the REST/WS lists extracted
from `docs/inventory/rest-endpoints.tsv` and `docs/inventory/websocket-events.md`. **Checked in so the
gate runs offline** — regenerated only on a pin bump.

### 2.3 `parity/claims.tsv` — the bridge (hand-authored once, then generator-owned)

One row per **upstream key**. This is the file the ticket-writing agent's question resolves against.

```
# key	native_paths	surface	test_refs	status_seed	card	note
M:app/screens/thread	Mattermost/UI/Native/Thread	channelView	MattermostTests/T36ThreadTests.swift	native	-	back affordance = the navigation stack; no in-content back button (thread.tsx calls goBack on a pushed screen)
M:app/screens/channel/header/header.tsx	Mattermost/UI/Native/Channel	channelView	MattermostTests/T34ChannelViewTests.swift;MattermostUITests/T34ChannelUITests.swift	native	-	title area is the tap target -> channel info; bookmarks bar lives in the header, not the info sheet
M:app/screens/calls	Mattermost/UI/Native/Calls	calls	MattermostTests/T44dCallsSurfaceTests.swift	native	-	Call surface (engine stays webview)
REST:GET /channels/{id}/posts	Mattermost/UI/Native/Channel	channelView	MattermostTests/T34ChannelViewTests.swift	native	-	first page + before/after cursor
WS:posted	Mattermost/UI/Native/Channel;Mattermost/UI/Native/Activity	channelView	MattermostTests/T34ChannelViewTests.swift;MattermostTests/T42MentionsTests.swift	native	-	shared socket echo
X:notification-input	Mattermost/UI/Native/Notification	auth	MattermostTests/T43NotificationInputTests.swift	native	-	no upstream counterpart
M:app/screens/channel_bookmark	-	channelInfo	-	absent	t_<id>	bookmark CRUD not yet native
```

| column | meaning |
|---|---|
| `key` | FK → `upstream-keys.tsv`. |
| `native_paths` | `;`-separated repo-relative paths of the native unit(s) that claim the key. `-` = nothing implements it. Real paths, because the checker `stat`s them. |
| `surface` | the `Surface` rawValue (`auth`/`sidebar`/`channelView`/`composer`/`search`/`activity`/`channelInfo`/`calls`) this capability rolls up into, for the `native` rung. `-` when none. |
| `test_refs` | `;`-separated paths of test files carrying a `// parity-test:` for this key. `-` = none. |
| `status_seed` | the prose's own vocabulary (`native`/`partial`/`absent`/`webview`) — the *seed* for the derived status, never the authority. |
| `card` | the open card that closes the gap, `-` when none (a gap without a card is the finding; see §4.3). |
| `note` | one line of the *decision/limit*, not a status. |

The `note` column is the home for exactly the kind of nuance the prose table carries today and the
map cannot derive — "the thread screen's back affordance is the navigation stack's, not an in-content
button" — so the knowledge survives the migration instead of being flattened to a status.

### 2.4 `parity/verdicts.json` — the verdict ledger

```json
{
  "M:app/screens/thread": {
    "card": "t_1ca87edd",
    "commit": "abc1234",
    "verdict": "PASS-WITH-FINDINGS",
    "findings": ["F1 repaired by t_cf23dcd7"],
    "evidence": [
      {"kind": "test",      "ref": "MattermostTests/T36ThreadTests.swift::testReplyCarriesRootID"},
      {"kind": "test",      "ref": "MattermostTests/T36ThreadTests.swift::testChannelComposerReturnsToNewPost"},
      {"kind": "observation","ref": "docs/t36-shots/thread-back.png"},
      {"kind": "log",       "ref": "build/logs/t36-av-live-1.log"}
    ]
  }
}
```

`evidence[]` entries are **typed proof, never "the file exists"**: a `test` ref names a *test case*
(`<File>::<func>`), an `observation` ref names a captured screenshot/a11y dump, a `log` ref names a
live-run log line. The `native_paths` column in `claims.tsv` is the *mechanism* (which files claim the
key); `evidence[]` is the *proof* (what asserts the behaviour or recorded the runtime). The hard rule
"evidence is a test or a recorded observation, never a file path" applies to `evidence[]` only — the
claim→mechanism mapping legitimately names files, and that is what lets the checker detect rot.

### 2.5 Generated artifacts (all sorted, all tracked)

| file | contents |
|---|---|
| `parity/out/inventory.tsv` | the join result: `key / surface / status / native_paths / test_refs / verdict / card` — one row per key, the derived status in §4.1. |
| `parity/out/gaps.tsv` | `key / status / card / surface` — every key that is `absent`, `claimed` or `tested` (i.e. not `validated`), grouped. |
| `parity/out/orphans.tsv` | `key / native_paths / finding` — claims whose key is not at the pin, and native units no claim covers. |
| `parity/out/findings.txt` | the human report: a status tally, then findings grouped by kind with counts (`[FAIL]` / `[note]` markers). |

---

## 3. Claim/evidence lifecycle

### 3.1 Making a claim

Two forms, both recognized, both kept in sync by the generator:

1. **Co-located (target steady state).** In the implementing Swift file:
   ```swift
   // parity: M:app/screens/thread
   // parity-surface: channelView
   ```
   and in a test file:
   ```swift
   // parity-test: M:app/screens/thread
   ```
   The claim dies in the same commit as the code it describes — the strongest de-rotting. The
   `// parity:` comment may appear once per key; a file claiming several keys carries several lines.
2. **Bridge (the migration stage).** A row in `parity/claims.tsv`. Hand-authored once via
   `--bootstrap` from `native-inventory.md`/`parity.md`, then the generator treats it as the claim.
   The orphan/`UNMAPPED` checks are identical in both forms, so co-located comments can be rolled in
   incrementally, file by file, without changing the checker.

### 3.2 The status ladder (derived, never typed)

```
absent      no claim row, and no // parity: comment, for the key
claimed     a claim exists and names >=1 real native path
tested      >=1 test file carries // parity-test: for the key
validated   a verdict entry exists AND verdict.commit is an ancestor of HEAD
            AND no commit after verdict.commit touched the claimed files
            AND every evidence[] ref resolves against the tree
native      validated AND the key's surface ∈ SurfaceDefaults.nativeApprovedSurfaces
```

The two new clauses versus the earlier proposal:

- **"every evidence ref resolves"** — a verdict citing `docs/t36-shots/thread-back.png` whose file
  has since been pruned is demoted even though its `commit` is still an ancestor and no Swift file
  moved. This is the failure mode the earlier ancestry-only rule missed (failure mode 2).
- **`native` = validated ∧ surface ∈ registry**, where the registry is the *parsed* Swift literal,
  not a second list. `paneOwningSurfaces` is read too: a surface that is pane-owning but not approved
  is a hard `FAIL` (the subset invariant `scripts/verify-dual-render-gates.sh` already enforces).

### 3.3 Drift rules (what invalidates a claim, and the finding it emits)

| trigger | finding | severity |
|---|---|---|
| `native_paths` names a path that no longer exists | `STALE` | fail |
| a claim's `key` is not in `upstream-keys.tsv` | `ORPHAN` | fail |
| same content (`git hash-object`) appears at a new path, old path gone | `MOVE` (re-points the claim, then reports) | report |
| `key`'s `content_sha` differs from the pin's (pin bump, upstream moved) | `UPSTREAM-MOVED` | report (forces re-read) |
| verdict.commit not an ancestor, or a later commit touched claimed files | `STALE-VERDICT` | fail |
| verdict evidence ref does not resolve | `STALE-EVIDENCE` | fail |
| a native unit under `Mattermost/UI/Native/` no claim covers | `UNMAPPED` | fail |
| surface ∈ registry but no fresh verdict | `APPROVED-WITHOUT-VERDICT` | report (named, allowed) |
| fresh verdict but surface ∉ registry | `VALIDATED-BUT-NOT-APPROVED` | report (named, allowed) |
| key with no claim and no card | `UNCARDED-GAP` | report (the one that matters) |

### 3.4 Rename handling (deterministic)

- **Our side:** `git hash-object` of the file, matched against surviving paths. Same content at a new
  path = `MOVE`; the generator re-points `native_paths` and emits a report line. No heuristic, no
  model — a content-identity match is a byte comparison.
- **Upstream side:** the bump diff (§5) maps `old content_sha → new key` and emits
  `UPSTREAM-MOVED` rows grouped by the claim that referenced them. Because identity is the path and
  the sha is a column, a rename upstream is reported once as "the module `thread` was renamed" rather
  than as a delete + an add that orphans the claim.
- **Never silent:** a `MOVE` re-points only `native_paths`; it never rewrites the `key`, and it never
  updates a verdict. A renamed-and-changed file (new content) is a plain `STALE` + new claim, which is
  correct — the implementation moved *and* changed, so the claim must be re-read.

### 3.5 Severity split (why gaps don't fail the build)

```
fatal (exit 1)   MALFORMED ROW, DUPLICATE KEY, INTERNAL-WITH-UPSTREAM (X: naming an upstream path),
                 STALE, ORPHAN, UNMAPPED, MAP-INCOMPLETE (key with no row),
                 STALE-VERDICT, STALE-EVIDENCE, PANE-NOT-APPROVED
report (exit 0)  GAP (no native paths), UNCARDED-GAP, MOVE, UPSTREAM-MOVED,
                 APPROVED-WITHOUT-VERDICT, VALIDATED-BUT-NOT-APPROVED
```

Exit 0 with gaps outstanding is the correct steady state — 25 unported screens is the metric, not a
failure. Exit 1 means the *mapping itself* is lying.

---

## 4. The generator

`parity/generate.py`, **stdlib-only Python 3** (`argparse`, `csv`, `hashlib`, `json`, `os`, `re`,
`subprocess`). The only external command it invokes is `git`, which is already a repo prerequisite
(the pins are git shas). No network in the check path.

### 4.1 Command surface

```
python3 parity/generate.py                     # regenerate parity/out/* from pins + claims + verdicts + registry
python3 parity/generate.py --check             # regen into a temp dir, diff against checked-in artifacts, exit 1 on drift
python3 parity/generate.py --self-test         # plant faults, assert every detector fires, run twice and byte-compare
python3 parity/generate.py --query <name|key|surface> [--json]   # resolve one capability question
python3 parity/generate.py --bootstrap         # one-shot: write pins.tsv + seed claims.tsv from the prose docs
python3 parity/generate.py --bump M <old-sha> <new-sha>          # (later) upstream-moved worklist
```

Path overrides for testing (defaults in brackets): `--pins`, `--upstream-keys`, `--claims`,
`--verdicts`, `--native-root [Mattermost/]`, `--registry [Mattermost/Core/RenderMode.swift]`,
`--out [parity/out]`.

### 4.2 `--query` — the ticket-writing agent's interface

`generate.py --query "thread" --json` resolves a name/key/surface to one or more rows and prints:

```json
{"key": "M:app/screens/thread", "surface": "channelView", "status": "native",
 "implemented": true,
 "evidence": [
   {"kind": "test",       "ref": "MattermostTests/T36ThreadTests.swift::testReplyCarriesRootID"},
   {"kind": "observation", "ref": "docs/t36-shots/thread-back.png"}],
 "verdict": {"commit": "abc1234", "verdict": "PASS-WITH-FINDINGS"},
 "card": null}
```

This is the yes/no + evidence the hard requirement asks for. `implemented` is `status ∈ {validated,
native}`. The evidence array is empty unless `tested` or better — so "claimed" returns `implemented:
false` even though a row exists, and the agent can't mistake a claim for a proof.

### 4.3 Determinism self-test (`--self-test`)

Builds a throwaway git repo with fake pins, keys, claims and verdicts, plants these faults, and
asserts each fires with its own finding kind:

1. a claim pointing at a non-existent native path → `STALE`
2. a claim naming a key not in the key list → `ORPHAN`
3. a stray native directory no claim covers → `UNMAPPED`
4. a verdict whose commit is not an ancestor of HEAD → `STALE-VERDICT`
5. a verdict citing a deleted screenshot → `STALE-EVIDENCE`
6. a registry entry with no fresh verdict → `APPROVED-WITHOUT-VERDICT`

Then it runs the generator **twice and byte-compares** the two outputs. Determinism means: sorted
output, no timestamps in the artifact body (stamp a hash of the inputs instead), no clock, no random,
no model in the loop. Same pins + claims + verdicts ⇒ same bytes. The two-run byte-compare is the
assertion; the fault-planting proves the checker is non-vacuous. A checker that only ever prints PASS
is the same defect as the hand-typed table it replaced.

### 4.4 CI gate (report mode first)

`generate.py --check` runs on the cheap ubuntu job, before any platform build, with no network (the
key list is checked in). Order matters: pin + key list first, then claims, then the gate — a hard gate
over an empty claim set fails every build on day one and gets disabled. Start the gate in report mode
(exit 0) while claims are partial; flip `UNCARDED-GAP`, `STALE-VERDICT` and `STALE-EVIDENCE` to
`fatal` only once the backfill is complete.

---

## 5. Three failure modes of this design, and how each is detected

These are *this* design's failure modes — the ways it can be wrong even when implemented as written —
not generic parity bugs.

### 5.1 "Delete + add" masquerading as continuity loss (rename misread)

A refactor moves `UI/Native/Thread/ThreadView.swift` to a new path. The `STALE` detector alone sees
the old path vanish and reports the feature as deleted; a ticket agent then re-creates it. **Detection:**
the `MOVE` detector (content-identity match: same `git hash-object` at a surviving path) runs *before*
the `STALE` verdict is finalized, re-points `native_paths`, and reports `MOVE` rather than `STALE`.
The `--self-test` plants a pure rename (identical bytes, new path) and asserts the finding kind is
`MOVE`, not `STALE`. Without this ordering, the map converts a refactor into a false "not implemented"
answer — the exact failure the project is migrating away from.

### 5.2 Evidence rot that the ancestry rule can't see

A verdict's `commit` is still an ancestor of HEAD and no claimed Swift file changed since, but the
proof file it cites (`docs/t36-shots/thread-back.png`, a `build/logs/*.log`) was pruned or overwritten
during cleanup. The earlier ancestry-only rule keeps the verdict green; the proof is gone. **Detection:**
`STALE-EVIDENCE` — the verdict validator resolves every `evidence[]` ref against the tree and demotes
the verdict when a ref 404s. This is a distinct detector from `STALE-VERDICT`, which watches only the
*code* files, not the *evidence* files. Planted in `--self-test` as fault 5.

### 5.3 Two registries disagreeing about "native"

The shipped truth is `SurfaceDefaults.nativeApprovedSurfaces`, but the map has its own notion of
status. Two silent lies are possible: (a) a surface is in the registry via an owner decision with no
`-AV` verdict — this repo did exactly that for `.sidebar`/`.channelView` (`t_c93b8337`) — and the map,
if it only reads the ladder, reports "not native" for a shipped-native surface; or (b) a surface has a
fresh verdict but was never appended to the registry, and the map reports "native" for a surface that
still ships webview. **Detection:** the generator *parses the Swift literal* (one parser, the same one
`verify-dual-render-gates.sh` would read) and joins claims × registry, emitting
`APPROVED-WITHOUT-VERDICT` and `VALIDATED-BUT-NOT-APPROVED` as named findings. Both are legal states
but must be surfaced, never collapsed into a derived `native`/`not-native` that disagrees with the
binary. Planted in `--self-test` as fault 6; and the `native` rung is defined as
`validated ∧ surface ∈ registry`, so a registry flip without a verdict can never silently upgrade a
surface.

---

## 6. MVP vs later

### MVP — ship in ≤ 2 days of agent time

1. `parity/pins.tsv` — extract the two pins from `docs/component-map.md` prose (30 min, mechanical).
2. `parity/generate.py` — key-list generation from the pinned tree (checked in as
   `parity/upstream-keys.tsv`), the join/checker with the §3.5 severity split, `--check`,
   `--self-test`, `--query` (incl. `--json`).
3. `parity/claims.tsv` — the bridge, seeded once from `docs/native-inventory.md` S01–S40 +
   `docs/parity.md` T28–T46 via `--bootstrap`, then hand-corrected. This is the one round of
   authorship; the generator owns it afterward.
4. `parity/verdicts.json` — retrofit from the existing `docs/tXX-av-verdict.md` docs; verdicts whose
   `commit` predates a later repair land `STALE-VERDICT` immediately — that is the mechanism working,
   reported, not softened.
5. `parity/generate.py --check` on the cheap CI job, **report mode** (exit 0).
6. `--query` wired so the ticket-writing agent asks before opening a card.

### Explicitly NOT in the MVP

- **Co-located `// parity:` comments** in every Swift file. The `claims.tsv` bridge stands in; the
  orphan/`UNMAPPED` checks are identical, and comments are rolled in file-by-file later. (This repo is
  single-writer-per-checkout, so co-located claims are viable and are the *target*, but backfilling
  hundreds of files is not a 2-day job.)
- **Vocabulary/constants extraction** (emoji aliases, permission ids, limits, error keys, preference
  key sets) — the separate class that catches the "surface renders for the ten names someone typed"
  defect. A later `parity/extract-vocab.py` diffs upstream data files against a generated snapshot and
  asserts equality in tests. Not the parity map's job.
- **`--bump` worklist** — the pins are stable; the bump stays manual until the first real one, then
  becomes `--bump M <old> <new>`.
- **Full-tree content addressing** — only the anchor files/`content_sha` needed to detect drift are
  computed; every upstream file need not be hashed.
- **Recorded-transcript replay / behavioural differential** — the one mechanical oracle that could
  settle "does it dismiss the way upstream's does". Deterministic coverage ends where behaviour begins;
  the adversarial `-AV` round keeps that, now fed the generated row set instead of the builder's own
  description.
- **Demoting the prose docs** — `docs/parity.md` keeps decisions/limits/history (the `note` column is
  their new home); the status columns are stripped only after the generated artifacts are trusted.
- **Parsing Swift to verify a test actually asserts behaviour** — the generator cannot read
  assertions; "does this test prove the behaviour, not just touch the file" stays a validator
  judgement, recorded in `evidence[]` as a `test` ref with a case name, not derived.
```

---

## 7. Refactor order (what breaks if reordered)

1. pins as data + key list (independent of everything else)
2. claims bridge backfill — the only serialized step (touches the widest surface)
3. verdict ledger retrofit from prose
4. generator + `--self-test` + CI gate in report mode
5. co-located `// parity:` comments rolled in behind the gate
6. demote the prose; promote `--check` to fatal where §4.4 says

Steps 1, 3, 4 are independent. Gate before claims fails every build on day one; prose demotion before
the generated artifact exists leaves no truth at all.

---

## Appendix — implementation deltas (2026-11-05, t_e56d2589)

This appendix is written by the implementation, not by the design above. Where the code and §0–§7
differ, this is what shipped and why. The design text above is left as written.

### Delta 1 — the pins are not in this repo's object database

`parity/pins.tsv` carries both pins (`M` = mattermost-mobile `v2.45.0` @ `162f2560…`, `W` =
mattermost `v12.0.1` @ `987e5712…`), but neither commit exists locally (`git cat-file -e` fails; there
is no `refs/mattermost-mobile`). `content_sha` is therefore `-` for every `M:` key, and the drift
checks that need the pin (`UPSTREAM-MOVED`, key re-derivation) are inert until the objects arrive.

To complete the content address, fetch the two upstreams into this repo and re-seed the key list:

```
git fetch https://github.com/mattermost/mattermost-mobile refs/tags/v2.45.0:refs/parity/M
git fetch https://github.com/mattermost/mattermost refs/tags/v12.0.1:refs/parity/W
python3 parity/generate.py --bootstrap --force --keys-only
```

Nothing in the record pretends the sha was computed: a `-` is honest, and `UPSTREAM-MOVED` stays
silent rather than inventing a comparison.

### Delta 2 — the key list comes from the checked-in extracts, plus the S-rows' own paths

`--bootstrap` builds `parity/upstream-keys.tsv` from `docs/inventory/screens.tsv` (the 67 modules,
minus the hand-grep junk line at `screens.tsv:52`), `docs/inventory/rest-endpoints.tsv` (normalised:
`?{params}` dropped, trailing `/` dropped, deduped) and `docs/inventory/websocket-events.md`. It adds
the upstream paths the S-rows name that the 67-module extract does not carry (`app/screens/search`,
`app/screens/mentions`, `app/components/post_draft`, `…/post_list`, `…/autocomplete`,
`app/products/{boards,playbooks,calls}`) and the project-owned `X:` units. Result: 311 keys — 74 `M:`,
141 `REST:`, 86 `WS:`, 10 `X:`.

### Delta 3 — `MOVE` is reported, never auto-applied

§3.4 says the generator re-points `native_paths`. It does not: a generator that rewrites its own
input cannot be `--check`ed, and a silent rewrite of the claim is exactly the change a reviewer must
see. `MOVE` names the old path, the surviving path and the finding, and the edit is one deliberate
line in `claims.tsv`.

Detection order is `git log --follow --diff-filter=R` first (the recorded rename), then content
identity via the blob/tree sha at the last commit that contained the path (the refactor that was
never recorded as a rename, §5.1). It still runs before `STALE` is finalised.

### Delta 4 — `MAP-INCOMPLETE` is defined as a key whose namespace has no pin

§3.5 lists the finding but not its trigger. It fires when `upstream-keys.tsv` names a namespace
(`M`/`W`) that `pins.tsv` does not pin — the key could never be drift-checked. The unused `W` pin is
not a finding: the MVP maps the mobile tree, and `docs/component-map.md` keeps the webapp pin's prose
until a `W:` key exists.

### Delta 5 — the ladder is monotone, decided by the differential

The exhaustive table in `scripts/reference.py` exposed an ambiguity in §3.2: `validated`'s four
clauses do not mention the test ref, so a verdict whose only evidence was an observation could read
as `validated` on a key no test names. Decided: **a rung adds proof**, so `validated` requires
`tested`. World `claim=1 path=1 test=0 ancestor=1 clean=1 evidence=1 approved=0` is `claimed`, not
`validated`; `… approved=1` with `test=1` is `validated`; `… approved=1` with `test=0` is `claimed`.
Two rows of `scripts/reference.py` were corrected when the differential disagreed — the correction is
in that file's changelog, and the differential (not the implementation) is what found them.

### Delta 6 — `UNCARDED-GAP` is for real gaps only

It fires for a key with no claim, or a claim that names no native path, and no card. A key that has
paths but no fresh verdict is a *validation* gap, not an implementation card; it is surfaced by
`APPROVED-WITHOUT-VERDICT` / `VALIDATED-BUT-NOT-APPROVED`. `APPROVED-WITHOUT-VERDICT` is
surface-level (one finding per approved surface with no `native` key), because several keys share one
surface and one native key is enough.

### Delta 7 — `--render-md` (owner scope addition), and why the file is not `docs/PARITY.md`

`generate.py --render-md [--out PATH]` renders `parity/out/inventory.tsv` as the six-column table in
the card note. The owner named the target `docs/PARITY.md`; **on this host `docs/PARITY.md` IS
`docs/parity.md`** — APFS is case-insensitive, and the first run of the renderer silently replaced the
404-line hand-written prose doc with the generated table. The prose doc was restored from HEAD, the
default output is now `docs/PARITY-table.md` (a distinct file on any filesystem), and `--out` refuses
(exit 2) any path that case-collides with an existing file, naming it. Prose demotion in
`docs/parity.md` stays out of the MVP, as the card says; when it happens, the prose doc and this table
are two names for two files or the collision guard decides the name.

`Implemented` is derived (`yes` = validated|native, `partial` = tested|claimed, `no` = absent).
`Evidence` is the first resolving `<File>::<case>`, else a verdict's observation with the
`observation: ` prefix, else `-`. `To be implemented` is the card id, `owner decision (<blocker>)`
when the claim note carries `blocker=…`, else `-`. One row per capability (upstream key), grouped by
the module the key's `anchor_of` names and sorted by key. The footer is one line: pin tags + SHAs and
the row count. A hand edit is a `--check` drift finding, like `parity/out/*`. The default run writes
it too, so the owner's table and the machine record cannot disagree.

The MVP keys at upstream-module granularity, so a module currently holds one row per key it owns; the
"~9 rows for the thread module" needs sub-capability keys inside one upstream module, which is a
later cut, not a rendering problem.

### Delta 8 — `scripts/cap.py` is a wrapper, and B's verbs are honoured

`scripts/cap.py` forwards to the one tool and maps B's verbs: `query <n>` → `--query`, `gen` → render,
`ci-check` → `--check --report`; `plan`, `promote`, `gate` and `claim` are `generate.py` subcommands.
`promote <alias> <status> …` accepts B's positional status but writes it to `status_seed` only — the
derived status still follows the artifacts (the card's reconciliation). `gate <cap>` exits 1 when the
seed claims more than the artifacts support, which is B's promotion check without a status column.

### Delta 9 — verification: the differential and the mutants are primary

`--self-test` is no longer the main guarantee. It runs six runtime asserts, the six planted faults and
a two-run byte compare; `scripts/differential.py` (128 status worlds + 10 finding worlds, against the
hand-authored `scripts/reference.py`) and `scripts/mutate-test.py` (six detector mutations as data in
`scripts/mutants/*.diff`) are the blocking checks. All four run in the `parity` CI job.

### Delta 10 — the protocol rows are mapped but not claimed

`REST:`/`WS:` keys are in the record (they are the upstream catalogue the client implements) and are
`absent` until a claim names them; B §8 puts protocol coverage in v2, so `plan` defers them by
default (`--protocol` includes them) and `findings.txt` reports the count separately. They are not
card proposals, and their absence is not a failure.

### Delta 11 — the `// parity:` comment scan is not in this cut

The ladder's `absent` rung reads "no claim row **and no `// parity:` comment**". This cut derives from
claims only. Two `// parity:` occurrences exist in the tree and neither is the machine form
(`// parity: <key>`): `MattermostTests/SurfaceModeResolverTests.swift:183` is prose inside a test and
`MattermostTests/T44DCallsSurfaceTests.swift:7` is a prose provenance line naming an upstream path, not
a key. MVP step 6 is where the comments get rolled in file by file, which is also when the parser must
stop treating `// parity:` as free text; until then the scan would have nothing to read, so the record
does not pretend to read it. When step 6 starts, the scan lands in `Record._load` beside the claim read
and gets a self-test assert (a `// parity: <key>` comment with no claim row must read `claimed`, not
`absent`).

### Provenance of each decision (A vs B)

| Decision | Source |
|---|---|
| identity = path, `content_sha` a column, `M:/REST:/WS:/X:` grammar | A §1 |
| one record under `parity/`, TSV + JSON verdict ledger, generated `parity/out/*` | A §2 |
| status derived from artifacts, never a column; `promote` records evidence | A §3.2 + the card's reconciliation of B's `cap.py promote` |
| five-rung ladder, `native` = validated ∧ approved surface | A §3.2, B §4 (G8/G9/G10 collapsed into the parsed registry) |
| findings, severity split, exit 0 with gaps | A §3.3/3.5 |
| MOVE before STALE; content identity + recorded rename | A §3.4/§5.1 |
| `--query` as the ticket agent's interface, `implemented` only for validated/native | A §4.2 |
| report-mode CI first, fatal later | A §4.4 |
| card `CAPABILITY: <key>` marker + `--idempotency-key cap:<key>` | B §3.1 |
| anti-gaming: no skip behind a promotion, delivered-payload assertions, no "file exists" evidence | B §6 (enforced where a script can: typed evidence, `::case` required) |
| `plan` as the steward's proposal view, board cross-check, repo-only CI | B §7, B §5 |
| test refs must name a case; evidence typed test/observation/log | A §2.4, card note |

