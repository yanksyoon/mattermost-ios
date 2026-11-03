# T50 — edit profile, picture upload, custom profile attributes (S28, S39)

The parity gap this card closed: there was no surface at all on which the reader could change their
own name, position, nickname, email or picture, and no way to change the picture the client already
draws everywhere. `ProfileView` (T41) could show a profile and set presence; `AvatarImageStore` (T45)
could draw whatever the server served. The client could not write either. Custom profile attributes
(S39) had no code path — the string `custom_profile_attributes` did not appear in `Mattermost/`.

Behaviour reference: `mattermost/mattermost-mobile` at v2.45.0 —
`app/screens/edit_profile/edit_profile.tsx`, `app/screens/edit_profile/components/user_profile_picture.tsx`,
`app/screens/edit_profile/components/custom_profile_attributes/`, `app/client/rest/users.ts`
(`updateMe`, `uploadProfileImage`, `removeProfileImage`), `app/client/rest/custom_profile_attributes.ts`.
Behaviour ported with attribution (`docs/THIRD_PARTY_NOTICES.md` §18); no upstream source copied.

---

## 1. What shipped

| Surface | Native counterpart |
| --- | --- |
| The edit form: picture → first/last name → nickname → position → email → Save | `EditProfileView` (`EditProfileSheet`, `EditProfileContent`, `EditProfileForm`) |
| The pure draft/validation/patch derivation | `EditProfileModels.swift` (`ProfilePatchDraft`, `MMProfilePatch`) |
| The screen's state, the two writes, the errors | `EditProfileViewModel.swift` |
| The wire: user patch, image upload/remove, attribute fields/values | `EditProfileAPI.swift` (extension on `APIClient`) |
| Picture cache invalidation, memory **and** disk, plus a signal for rows already on screen | `AvatarImageStore.invalidate(_:)` + `AvatarPicture.onReceive` |
| Settings → **Account** → Edit profile (per signed-in server) | `SettingsView.accountSection` |
| The reader's own profile → **Edit profile** (a push, not a nested sheet) | `ProfileScreen` → `EditProfileContent` |
| The server's answer redrawn on the open profile without a re-read | `ProfileViewModel.applySavedProfile(_:avatar:)` |
| Custom profile attributes (S39), feature-gated | `CustomProfileAttributeSection`, `attributesSection` in the form |

New files:

```
Mattermost/UI/Native/Profile/EditProfileModels.swift     the draft, the limits, the patch, the attribute section
Mattermost/UI/Native/Profile/EditProfileAPI.swift        PUT /users/{id}/patch, POST|DELETE /users/{id}/image, the S39 routes
Mattermost/UI/Native/Profile/EditProfileViewModel.swift  load / save / upload / remove, the server's sentence
Mattermost/UI/Native/Profile/EditProfileView.swift       the form, its identifiers, the PhotosPicker
MattermostTests/T50EditProfileTests.swift                29 unit tests
MattermostUITests/T50EditProfileUITests.swift            3 live tests (position, picture, attribute gate)
scripts/t50_profile_probe.py                             the contract, measured (see §9)
scripts/t50_ui_fixture.py                                create-or-reuse the UI fixture account
```

Modified: `APIClient.swift` (a `put` that can decline to treat a 401 as session expiry; a multipart
POST whose answer is not decoded; the dead generic `patch` removed), `ProfileAPI.swift` (the picture
route, §7), `ProfileService.swift` (the `ProfileServing` additions and their refusing defaults),
`AvatarImageStore.swift` (invalidation), `ProfileViewModel.swift` (`applySavedProfile`,
`reloadAvatar`), `ProfileCoordinator.swift` (`profileService(for:)` so the form uses the coordinator's
test seam), `ProfileView.swift` (the entry point and the push), `SettingsView.swift` (the Account
section and the sheet), `MattermostTests/T41ProfileAPITests.swift` (the corrected route, §7).

## 2. The rule: a patch is a diff, and a no-op save is no request

`ProfilePatchDraft.patch(comparedTo:)` answers a body containing **only** the fields that differ from
the profile the form read, or `nil` when nothing differs:

* a field the reader did not touch is **omitted**. Mattermost's `PUT /users/{id}/patch` treats a field
  it receives as "set this value", so echoing an unchanged field would overwrite a value another
  client changed between this form's read and its save. `MMProfilePatch`'s fields are optional and
  `Encodable` writes optionals with `encodeIfPresent`, so a nil field never reaches the wire — it is
  not sent as `null`, which the server reads as "empty". A unit test asserts the encoded JSON has no
  key at all (`testNilFieldsAreOmittedFromTheJSONNotSentAsNull`).
* a **no-op save sends no request**. The view model derives both halves (the field patch and the
  attribute values) and returns `true` before touching the service when both are empty; the fake
  service counts its calls (`testNoOpSaveSendsNoRequestAtAll`). Save is also disabled in the UI.
* the current password rides along **only** when the email changed (`testThePasswordRidesOnlyWithAnEmailChange`).

Limits are the server's, measured (§3), not invented: first name, last name and nickname 64
characters; position 128; email 128. The client counts `String.count` because the server counts
characters, not bytes — measured: a 128-character `position` built out of 127 'é' is accepted, 129 is
refused.

The server keeps the last word. A rejected field's own sentence (`"Invalid email."`) is drawn under
the form in `editProfile.error` — the T31 rule. The client's own checks exist only to refuse what it
can prove before spending a round trip.

## 3. Measured on the pinned 9.11.19 fixture

`scripts/t50_profile_probe.py` (contract) and `scratch/t50_probe_email.py` (the email rules with a
real password, and the picture with a real image). Re-run on 2026-11-03; both restore the account.

| Request | Answer |
| --- | --- |
| `PUT /users/{id}/patch` `{position:"…"}` | 200, the whole user |
| `PATCH /users/{id}/patch` | **404** `api.context.404.app_error` — the route is PUT |
| `{first_name: 64}` / `{first_name: 65}` | 200 / 400 `model.user.is_valid.first_name.app_error` "Invalid first name." |
| `{last_name: 64}` / `{last_name: 65}` | 200 / 400 `model.user.is_valid.last_name.app_error` "Invalid last name." |
| `{nickname: 64}` / `{nickname: 65}` | 200 / 400 `model.user.is_valid.nickname.app_error` "Invalid nickname." |
| `{position: 128}` / `{position: 129}` | 200 / 400 `model.user.is_valid.position.app_error` "Invalid position: must not be longer than 128 characters." |
| `{position: "p"+"é"×127}` (128 chars, 254 bytes) | 200 — characters, not bytes |
| `{email: 128 chars, password}` / `{email: 129 chars, password}` | 200 / 400 `model.user.is_valid.email.app_error` "Invalid email." |
| `{email: "not-an-email", password}` | 400 `model.user.is_valid.email.app_error` "Invalid email." |
| `{email: new, password: wrong}` | **401** `api.user.check_user_password.invalid.app_error` "Login failed because of invalid password." |
| `{email: new}` (no password) | 400 `api.context.invalid_body_param.app_error` "Invalid or missing password in request body." |
| `{nickname: "x"}` alone | 200; `position` and every other field **kept** |
| `{username: …}` | 400 `app.user.save.username_exists.app_error`; the username is unchanged (not writable here) |
| `POST /users/{id}/image` (part `image`) | 200 `{"status":"OK"}` |
| `POST /users/{id}/image` (part `image_file`) | 400 `api.user.upload_profile_user.no_file.app_error` "No file under 'image' in request." |
| `GET /users/{id}/image`, no picture | 200, **577 bytes** — the server's generated 128×128 initial |
| `GET /users/{id}/image` after uploading a 256×256 PNG | 200, **683 bytes**, different bytes (the server re-encodes) |
| `DELETE /users/{id}/image` then `GET` | 200 `{"status":"OK"}`, then **the same 577 bytes** as before the upload |
| `GET /users/{id}/profile_image` | **404 for every account**, with a picture and without |
| `GET /custom_profile_attributes/fields` | **404** `api.context.404.app_error` |
| `GET /users/{id}/custom_profile_attributes` | **404** |
| `PUT /users/{id}/custom_profile_attributes` | **404** |

Two facts change what the client looks like, so they are stated rather than buried:

* **A 401 from the patch is not session expiry.** It is the server rejecting the *current password in
  the body*. `APIClient.put` therefore gained `sessionExpiryOnUnauthorized` (default `true`), and
  `updateProfile` passes `false`, so a mistyped password is a sentence under the field rather than a
  sign-out (`testAWrongPasswordIsASentenceNotASignOut`).
* **"No picture" is an image, not an absent one.** The route answers a generated PNG, so the client
  draws what the server serves and the store's `nil` means "the read failed", not "there is no
  picture". `docs` said otherwise before this card (§7).

## 4. Custom profile attributes: the gate, and what is withheld

The feature is license-gated. On this fixture (Team Edition) all three routes answer 404, so no
section is drawn — which is also the answer for an older server, a licence without the feature, and a
read that failed. Fields and values are read **together**; the section exists only when both answer
and at least one field is drawable (`CustomProfileAttributeSection.make`). An empty form is never
shown.

Field types this build renders: `text` (a text field) and `select` (a picker from `attrs.options`,
tolerant of both `["one"]` and `[{"name":"one"}]` shapes). Types it does **not** render —
`multiselect`, `boolean`, `date`, and anything the server adds later — are:

* not drawn;
* counted, and named in the section footer ("N profile fields use a type this app cannot edit yet.
  Edit it in the web app.") so a reader is never shown a silently incomplete profile;
* listed here, in this build note, as the card requires.

A write sends only the values that changed (`dirtyValues`), so echoing an untouched field is not a
rewrite. A deactivated field (`delete_at != 0`) is not drawn.

**Live-tested only if the fixture has fields.** It does not: the fixture answers 404, so the live test
`testTheCustomAttributeSectionIsAbsentWhenTheServerHasNoFeature` asserts the *absence* (no
`editProfile.attribute.*` element, no "Profile fields" header) and skips on a server that does answer.
The rendering and the diff are covered by unit tests against the documented shapes; they are **not**
claimed as measured on a live server, and this note says so rather than implying otherwise.

## 5. `user_updated` keeps the reader's own name consistent

`ProfileViewModel` already re-read a profile on `user_updated` (T41); T50 adds the write side. When a
save answers with the server's user object, `applySavedProfile(_:avatar:)` installs it (and the
picture bytes the form already fetched) so the open profile screen redraws without a second read — the
answer *is* the server's record, so re-reading would only race it. A `user_updated` that arrives
afterwards is still handled by the existing re-read, so the shell converges whichever arrives first.

## 6. Live results

`MattermostUITests/T50EditProfileUITests` on iPhone (iOS 26.5 simulator) against the pinned
`http://127.0.0.1:8065` (mm-perf, 9.11.19), account `t50ui`:

```
Test Case 'testTheCustomAttributeSectionIsAbsentWhenTheServerHasNoFeature' passed (26.812 seconds)
Test Case 'testThePictureChangesThePostRowAndRemovingItRestoresTheInitial' passed (98.804 seconds)
Test Case 'testThePositionReachesTheServerAndSurvivesARelaunch' passed (53.074 seconds)
Executed 3 tests, with 0 failures (0 unexpected) in 178.690 seconds
```

What each verdict rests on:

* **Position** — typed into the form, Save enabled, `editProfile.save` tapped; the server's own
  `GET /users/{id}` then reports the typed value, and after `app.terminate()` + a relaunch the form
  draws the same value while the shell's memory is gone. The verdict is the server's record, not the
  app's.
* **Picture** — the account is first reset to no picture; `GET /users/{id}/image` serves the
  server's generated initial (603 B). After Change picture the server serves different bytes (683 B,
  re-encoded), the **post row's** screenshot digest changes, and after Remove picture the server
  again serves exactly the same 603 B and the row's digest returns to its pre-upload value. Both
  oracle reads are cache-busted (measured: URLSession served the previous picture from its own HTTP
  cache, which made an upload the app had drawn look like a no-op).
* **Attribute gate** — `GET /custom_profile_attributes/fields` answers 404 on this fixture, the form
  is scrolled to its Save row (so a section below the fold cannot hide), and no
  `editProfile.attribute.*` element and no "Profile fields" header exist. On a server that does
  answer, the test skips.

Two UI defects were found by these runs and fixed in the app (not worked around in the test):

1. **Remove picture was inert.** As a `Label` button sharing a Form row with Change picture it drew,
   reported `isEnabled == true` / `isHittable == true`, and swallowed the tap — three taps (element,
   label text, coordinate) produced no request and no error, and the server kept the old bytes. It
   now occupies its own row; the same tap deletes and the form redraws.
2. **The picker tile could not be pressed** (§8) — which is why the bytes arrive through the seam.

Units, whole target, at the committed tree: `Executed 1979 tests, with 8 tests skipped and 0
failures` (`MattermostTests`, 53.0 s) — 29 of them T50's own (`T50EditProfileTests`).


## 7. Corrections this card made to earlier work

1. **`/users/{id}/profile_image` does not exist on 9.11.19.** T41's `ProfileAPI.userProfileImagePath`
   used it, so the profile sheet never showed a face on this server and T41's API test asserted the
   404 as correct behaviour. The route is now `/users/{id}/image`, and `T41ProfileAPITests` was
   corrected (a 404 assertion became a 200-with-bytes assertion plus a transport-failure test).
2. **`APIClient.patch` had no caller and PATCH is not the update verb.** Removed; the measured verb
   is PUT.
3. **A nested sheet is T40's measured failure mode** (the confirmation action never ran). The form is
   a sheet when it comes from Settings and a **push** when it comes from the reader's own profile.

## 8. Limits of this evidence

* Custom-profile-attribute rendering, select options, withheld-type footer and the dirty-values write
  are exercised by unit tests against the documented shapes only — the fixture cannot answer them
  (§4). This is the card's "record the gate honestly" branch.
* The server re-encodes any uploaded picture, so the bytes served are never the uploaded file. The
  live test therefore compares the **bytes the server serves** before/after and the **pixels the row
  draws** before/after, not the file that was picked.
* **The system photo picker cannot be pressed by XCUITest on this host.** Measured on iOS 26.5: the
  picker runs as its own process (`com.apple.mobileslideshow.photospicker`), its grid is queryable
  (`Image, identifier: 'PXGGridLayout-Info'`, real frames), but every synthesised tap — element tap
  (not hittable), element-relative coordinate, app-window coordinate — leaves the sheet up with
  nothing selected. The live test therefore supplies the "picked" bytes through a **DEBUG-only**
  seam (`MM_UITEST_AVATAR_PNG_BASE64`, `EditProfileView.changePictureControl`) and taps the same
  **Change picture** button a reader taps. Everything after the pick — the multipart
  `POST /users/{id}/image`, the cache invalidation, the server re-read, the row redraw, the `DELETE`
  — is the product path. `pickFirstPhoto` stays in the test file, unused, with the measurement, so
  the next person does not rediscover it. This is the one place where the live evidence is weaker
  than "the reader pressed the picker"; it is stated here rather than implied away.

## 9. Publish

Filled at commit time: see the closing comment on the card for the SHA and the `ls-remote` assertion.
