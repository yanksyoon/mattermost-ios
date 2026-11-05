import Parity.Basic

/-!
# F5 — the join key is injective and carries no content address

Three theorems, and what each one does and does not say:

* `join_key_injective` — two identities that differ in either field get different keys. The join
  never collapses two distinguishable upstream units onto one row (which would silently share a
  claim between two capabilities).
* `join_key_ignores_content` — a row's key is unchanged when its content address changes, because
  the address is not an argument of `joinKey`. This is F5 stated as a property of the accepted
  scheme.
* `sha_in_key_is_not_a_function_of_identity` — the *negative* half, which is what gives the property
  teeth: no scheme that puts the address in the key can be a function of identity at all, because
  two rows of the same capability with different addresses must then share a key while the scheme
  gives them two. This is the exact contradiction that produced F5.

Scope: these are statements about *this model*. That `parity/generate.py` implements the same key
grammar is **tested** (`scripts/differential.py`, `parity/generate.py --self-test`), never proved
here. The boundary is stated in `docs/parity-verification-design.md` §4 and must not be softened.
-/

namespace Parity

/-- **The theorem this card exists for.** Distinct identities never share a join key: the join is
injective on identity, so it cannot collapse two distinguishable upstream units onto one row. -/
theorem join_key_injective : Function.Injective joinKey := by
  intro a b h
  cases a with
  | mk ns1 id1 =>
  cases b with
  | mk ns2 id2 =>
  change Key.mk ns1 id1 = Key.mk ns2 id2 at h
  injection h with hns hid
  cases hns
  cases hid
  rfl

/-- **F5, positively:** changing a row's content address does not change its key. The address is a
column of the record; the key is not a function of it, because it is not in scope for `joinKey`. -/
theorem join_key_ignores_content (a : Addressed) (s : ContentSha) :
    joinKey { a with sha := s }.id = joinKey a.id := rfl

/-- Same identity, same key — for any two rows, whatever their addresses. -/
theorem same_identity_same_key (a b : Addressed) (h : a.id = b.id) :
    joinKey a.id = joinKey b.id := by
  rw [h]

/-- The design's own example, spelled out: the thread screen before and after an upstream bump keeps
one key. -/
theorem upstream_bump_keeps_the_key :
    joinKey (Addressed.mk threadIdentity shaBefore).id
      = joinKey (Addressed.mk threadIdentity shaAfter).id := rfl

/-- **F5, negatively — and with teeth.** No assignment of keys to *identities* can reproduce a
sha-in-key scheme: such a scheme gives the same capability two keys depending on its content, so it
is not a function of identity at all. `scripts/reference.py` and `parity/generate.py` encode the
accepted scheme; this theorem is why the rejected one cannot be smuggled back in without changing a
type, and a type change is visible in a diff. -/
theorem sha_in_key_is_not_a_function_of_identity :
    ¬ ∃ j : Identity → ShaKey, ∀ a : Addressed, j a.id = shaKey a := by
  intro ⟨j, hj⟩
  have h1 : j threadIdentity = shaKey ⟨threadIdentity, shaBefore⟩ :=
    hj ⟨threadIdentity, shaBefore⟩
  have h2 : j threadIdentity = shaKey ⟨threadIdentity, shaAfter⟩ :=
    hj ⟨threadIdentity, shaAfter⟩
  rw [h1] at h2
  have hne : shaBefore ≠ shaAfter := by decide
  apply hne
  change ShaKey.mk Namespace.M "app/screens/thread" shaBefore
      = ShaKey.mk Namespace.M "app/screens/thread" shaAfter at h2
  injection h2 with _hns _hid hsha
  exact hsha

end Parity
