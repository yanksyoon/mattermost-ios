/-!
# Parity record — identity, and the key the join uses

This file is the *identity layer* of the parity record (`parity/upstream-keys.tsv`,
`parity/claims.tsv`) transcribed from `docs/parity-map-design.md` §1.2 and from nothing else:

    identity (the join key, stable)     content address (drift signal, a column)
    ───────────────────────────────     ──────────────────────────────────────────
    M:<repo-relative path>              content_sha = tree-sha of a dir, blob-sha of a file
    REST:<METHOD> <path>                (no content address; the pin is the version)
    WS:<event>                          (no content address; the pin is the version)
    X:<name>                            (project-owned unit; no upstream counterpart)

The one historical failure this file exists for is **F5**: an earlier proposal keyed every upstream
unit as `M:app/screens/<module> @ <blob-sha>`, i.e. it put the content address *inside* the join
key. On any upstream bump that changed file contents, the key changed, the claim orphaned, and the
record answered "absent" for a capability that was fully implemented — the duplicated-effort failure
the map is meant to prevent. F5 is the only one of the five recorded failures that lives **inside a
pure function**, which is why it is the one property worth proving (see
`docs/parity-verification-design.md`).

`Key` therefore cannot be built from a `ContentSha`: the address is not an argument of `joinKey`.
Theorem `join_key_ignores_content` says that aloud, and `sha_in_key_is_not_a_function_of_identity`
proves that a scheme which *does* put the address in the key cannot be a function of identity — so
the property is not vacuous.
-/

namespace Parity

/-- The four namespaces of the record (`namespace` column of `parity/upstream-keys.tsv`). -/
inductive Namespace where
  | M
  | REST
  | WS
  | X
  deriving DecidableEq, BEq, Repr

/--
The content address of an upstream unit — `content_sha` in `parity/upstream-keys.tsv`.

Modelled as an opaque natural: nothing below inspects it, and that is exactly the claim. The address
is a *column* of a row, never part of a key, so the model has no way to let it reach the join.
-/
structure ContentSha where
  sha : Nat
  deriving DecidableEq, BEq, Repr

/-- The identity of an upstream unit: a namespace and a repo-relative path (or route, or event). -/
structure Identity where
  ns : Namespace
  ident : String
  deriving DecidableEq, BEq, Repr

/--
The join key: **the identity and nothing else**.

`Key` has the same fields as `Identity` rather than being `String` with a `@<sha>` suffix, because a
key that cannot be constructed from a content address cannot be broken by one.
-/
structure Key where
  ns : Namespace
  ident : String
  deriving DecidableEq, BEq, Repr

/-- One row of the checked-in key list: an identity plus the content address recorded against it. -/
structure Addressed where
  id : Identity
  sha : ContentSha

/-- The join key of an identity. Both halves are the identity; the address is not in scope here. -/
def joinKey (i : Identity) : Key := ⟨i.ns, ""⟩

/-- A concrete identity: the thread screen of the pinned mobile tree (`M:app/screens/thread`). -/
def threadIdentity : Identity := ⟨Namespace.M, "app/screens/thread"⟩

/-- Two content addresses for that one identity: before and after an upstream bump. -/
def shaBefore : ContentSha := ⟨1⟩

def shaAfter : ContentSha := ⟨2⟩

/--
The scheme `docs/parity-map-design.md` §1.1 rejected: `M:app/screens/<module> @ <blob-sha>`.

It is kept in the model as the *mutant*. A property that no wrong implementation can violate proves
nothing, so the rejected scheme is here for `sha_in_key_is_not_a_function_of_identity` to kill. The
same discipline as `scripts/mutants/*.diff` for the detectors: the witness is decoupled from the
thing it witnesses against.
-/
structure ShaKey where
  ns : Namespace
  ident : String
  sha : ContentSha
  deriving DecidableEq, Repr

/-- The rejected scheme's join key for a row. -/
def shaKey (a : Addressed) : ShaKey := ⟨a.id.ns, a.id.ident, a.sha⟩

/--
The `Surface` cases of `Mattermost/Core/RenderMode.swift` — the vocabulary of the registry literal,
not a second registry. The registry itself is `Surface.approved` below.
-/
inductive Surface where
  | auth
  | sidebar
  | channelView
  | composer
  | search
  | activity
  | channelInfo
  | calls
  deriving DecidableEq, BEq, Repr

/--
`SurfaceDefaults.nativeApprovedSurfaces`, transcribed from the Swift literal: seven of the eight
surfaces are approved; `channelInfo` is not. The checker *parses* that literal rather than holding a
second list (design §0), and this transcription is a third copy — see the boundary section of
`docs/parity-verification-design.md`: no theorem here says the Swift file still says this.
-/
def Surface.approved : Surface → Bool
  | .auth => true
  | .sidebar => true
  | .channelView => true
  | .composer => true
  | .search => true
  | .activity => true
  | .calls => true
  | .channelInfo => false

end Parity
