# t_9fe70579 — pasting files into the composer: build note

Owner-reported defect: *"I cannot copy paste the image in the input. The upstream Mattermost allows
copy pasting images on the input and uploads it. Check with upstream how this works and implement."*

## 1. What the app was missing

`ComposerInputTextView` was a plain `UITextView`. `UITextView`'s `paste:` inserts *text*; an image on
the pasteboard has no text representation, so the Paste menu item was not even enabled and Cmd+V did
nothing at all. Nothing in `Composer/` mentioned a file paste — the only "paste" hits were comments
about text.

The intake it should have used already existed: `ComposerViewModel.add(_ ComposerUpload:)` appends
the chip and starts the upload, exactly as the picker's call sites in `ComposerView` do.

## 2. Upstream behaviour (pinned mattermost/mobile `162f2560`, v2.45.0)

Composer side — `app/components/post_draft/post_input/post_input.tsx`:

| fact | source |
| --- | --- |
| the input is the paste-aware component | `:6` `import PasteableTextInput, {type PastedFile} from '@mattermost/react-native-paste-input'` |
| pasted **files** join the same `addFiles` pipeline as the picker | `:292-298` `onPaste = (error, files) => { if (error) showPasteFilesErrorDialog(intl); addFiles(await extractFileInfo(files)); }` |
| a paste error is surfaced, never swallowed | `:292-298` + copy ids `mobile.files_paste.error_title` ("Paste failed"), `_description`, `_dismiss` |
| copy/paste can be disabled by MDM managed config | `:170` `const disableCopyAndPaste = managedConfig.copyAndPasteProtection === 'true'` → `:383-399` `disableCopyPaste={disableCopyAndPaste}` |

Native side — `@mattermost/react-native-paste-input@2.0.1` (npm `gitHead` `671378e2`, MIT, © 2020 Elias
Nahum; a fork of luisfcofv's library), read from the 2.0.1 tree:

| fact | source |
| --- | --- |
| `paste:` and `canPerformAction:` are swizzled onto every text input | `ios/PasteInputModule.mm:325-386` |
| the intercepted `paste:` reads files, and only calls `super` when there are **none** | `:431-495` (`getCopiedFiles` at `:453`; `files.count == 0 → super` at `:455-462`) |
| Paste is enabled when the pasteboard holds a file, even with no text | `:498-525` (`hasContent` at `:514-521`) |
| the MDM flag greys the item out | `:501-511` (`disableCopyPaste`) |
| every item of every representation is read, in pasteboard order | `ios/UIPasteboard+GetImageInfo.m:16-82` |
| an image wider than 6048 or taller than 4032 is fitted into 2048×2048 | `:94` |
| PNG when the image has alpha, JPEG otherwise | `:98-102` |

So the gesture is `paste:`/`canPerformAction:` on the text view, files go into the ordinary upload
path, and failures are shown. That is what this card implements.

## 3. Implementation

* `Mattermost/UI/Native/Composer/ComposerPaste.swift` (new) — the whole paste layer, no UIKit
  subclassing: `ComposerPasteboard` (a snapshot of `itemProviders` / `images` / `urls` / `string`),
  `ComposerPaste.read(_:)` → `(attachments, text, failures)` in pasteboard order, image → PNG/JPEG
  with the upstream downscale guard, file URLs read under a security scope, `pasted-image-<epoch-ms>`
  naming, UTType-derived MIME for real files, and `ErrorCopy` for the messages.
* `Mattermost/UI/Native/Composer/PasteAwareTextView.swift` (new) — `ComposerInputTextView` subclass
  with `paste(_:)`, `canPerformAction(_:withSender:)`, a `pasteTask` handle and `onPasteFailure`.
* `ComposerInputHeight.swift` — `ComposerInputTextView` is no longer `final`, so the subclass above can
  exist; the comment records why.
* `ComposerView.swift` — builds a `PasteAwareTextView`, forwards the attachments to
  `model.add(ComposerUpload(...))` (the picker's path) and the failures to `model.pasteDidFail`.
* `ComposerViewModel.swift` — `pasteDidFail(_:)` puts the message in the existing `statusNote`
  surface, cleared by the existing 4 s timer.
* `MattermostTests/T35PasteTests.swift` (new, 15 cases).
* `MattermostUITests/T35-ComposerUITests.swift` — one live case (see §5).
* `docs/THIRD_PARTY_NOTICES.md` §26 — the library whose behaviour was mirrored.

Decisions worth knowing:

* **Text-only paste is still the system's.** `hasAttachableContent` is false when no item carries a
  file or image representation, and then `super.paste` runs — so `ComposerCommands`' dash/newline/tab
  normalisation is untouched (requirement 5).
* **A file URL wins over the image conversion.** A Finder/Preview copy offers the same file as both a
  URL and raw image bytes; taking the URL keeps the file's own name and type (requirement 3's second
  sentence) instead of renaming it `pasted-image-*`. Non-image files (PDF, zip) are accepted the same
  way (requirement 4).
* **Files *and* text in one gesture**: both are handled. The files go to the intake, and the text is
  inserted through `super.paste` — except when that "text" is the copied file's own path, which is
  what a Finder copy publishes (typing `file:///…/shot.png` into the draft would be inventing words
  the person never wrote). Measured: UIKit inserts only the string of a mixed pasteboard, not an
  `NSTextAttachment` (T4 asserts the text is exactly `caption`), so there is no duplicate image and no
  need for the fragile path the card allowed me to document instead.
* **The menu asks for metadata, never for data.** `canPerformAction` must answer "is Paste
  enabled?" on iOS 16+ without touching the clipboard's *contents*: `string`/`images`/`urls` are
  permissioned reads that block the main thread on the system paste prompt, and asking for them while
  UIKit builds the edit menu froze the app for as long as the prompt stood (measured on the
  simulator: a long press on the composer left the app answering no accessibility query for 30 s).
  `Pasteboard.declaresAttachableContent()` therefore reads only `itemProviders`' registered types and
  `hasImages`, and the data is loaded inside `paste:` — on the person's gesture.
* **No client-side size limit** (requirement 7). The upstream guard is a *conversion* at
  `UIPasteboard+GetImageInfo.m:94`, not a refusal; an oversized paste is downscaled and uploaded, and
  the server's own refusal still lands in the per-attachment `.failed` state like a picked file.
* **The gate is one flag.** `PasteAwareTextView.pasteAllowed` (default `true`) greys out Paste and,
  when called anyway, refuses with a message. The app has no MDM/managed-config source yet, so nothing
  reads it: upstream's `copyAndPasteProtection` is recorded here as the documented divergence rather
  than scattered through the paste code.

## 4. Tests (unit, no server)

`MattermostTests/T35PasteTests.swift`, 15 cases. The pasteboard is injected as a `ComposerPasteboard`
value, and the view is a real `PasteAwareTextView` hosted in a `UIWindow`, so `paste:` and
`canPerformAction:` are exercised on the real UIKit seam.

| case | what it proves |
| --- | --- |
| T1 `testAPastedPNGBecomesOneChipAndTheSendPostsItsFileID` | one `ComposerUpload`, `image/png`, one chip, and the send posts that file id |
| T2 `testTwoImagesBecomeTwoUploadsInPasteboardOrder` | two images → two uploads, order preserved |
| T3 `testATextOnlyPasteTakesNoAttachmentAndLeavesTheTextToTheSystemPaste` | no attachment, no failure, Paste stays enabled |
| T4 `testAnImagePastedWithTextTakesBothAndAttachesTheImageOnce` | image + text: text inserted, image attached exactly once |
| T5 `testAnUnsupportedPayloadSaysWhyAndAttachesNothing` | unsupported payload → message, zero attachments |
| T5b `testAnUnreadableFileURLSaysWhichFileAndAttachesNothing` | the file is named in the message, nothing attached |
| T6 `testACopiedImageFileKeepsItsNameAndItsType` | `Screenshot ….png` keeps its name and gets `image/png` from UTType |
| T6b `testACopiedFileOfAnyTypeIsAttachedNotJustImages` | a PDF is attached too |
| T7 `testPastingInAThreadComposerAttachesToTheReply` | the reply took it, the channel draft did not, and the send carries `root_id` + the file id |
| T8 `testTheGateClosedRefusesThePasteAndSaysWhy` | gate closed → Paste disabled, nothing attached, message |
| AV `testPastingAnImageDoesNotTouchTheTextAlreadyInTheDraft` | text and caret unchanged |
| — `testTheFilesOwnPathIsNotTypedIntoTheDraft` | a Finder copy's path is not inserted as text; words copied with an image are |
| — `testAnImageWithoutAlphaIsEncodedAsJPEG` / `…WithAlphaIsEncodedAsPNG` | the conversion rule |
| — `testAnOversizedPastedImageIsFittedBeforeEncoding` | 6048×4032 → fitted into 2048×2048 |

Results on this host:

* `T35PasteTests` — 15 run, 0 failures (`build/logs/t9fe70579-paste6.log`, taken *after* the last
  change to `canPerformAction`).
* Full unit target, for regressions — 2478 run, 8 skipped, 0 failures
  (`build/logs/t9fe70579-unit-full.log`; taken just before the metadata-only `canPerformAction`
  change, which the paste class re-covers above).
* Mac Catalyst — 15 run, 0 failures (`build/logs/t9fe70579-paste-mac-catalyst.log`). The shared scheme's
  test action also builds `MattermostUITests`, which this host cannot run on Catalyst (its macOS
  deployment target is 26.5, the host is 26.3.1) and which does not compile for Catalyst
  (`XCUIElement.pinch` in T38); a throwaway unit-only scheme was used for the run and deleted after.
* **AV revert** — with `paste(_:)` deleted from `PasteAwareTextView`, T1 fails (no upload, no chip) and
  nothing else changes (`build/logs/t9fe70579-av-revert2.log`). Restored immediately; the class is
  green again.

One honest limit of the *unit* harness: a **text-only** paste into a plain `UITextView` hosted by this
test bundle does not insert. That was measured directly (a plain `UITextView`, first responder in a key
window, five pasteboard shapes — no insertion), and it is why T3 asserts the *decision* (no attachment,
no failure, delegation taken) while the insertion of text is proven by T4, where the same call inserts
`caption` exactly. In the app itself text paste is the system's and is covered by the existing live
suite (T49 pastes text into the login form for real).

## 5. Live evidence (Cmd+V, real server)

`MattermostUITests/T35-ComposerUITests.swift::testAPastedImageUploadsAndIsSentWithThePost` — **passed**,
98.7 s (`build/logs/t9fe70579-paste-ui8.log`), against the dev server on `127.0.0.1:8065`:

1. the test puts a PNG on the simulator's **real** pasteboard (`public.png`, the type Preview/Screenshot
   publish), then launches the app and signs in as the fixture account;
2. it walks to `#t35-composer` through the quick switcher (the sidebar `List` does not keep off-screen
   rows in the accessibility tree — see the note at the end of this section), taps the composer, and
   types **⌘V** at the focused text view;
3. an attachment chip with the `channelComposer.attachment.pasted-image-*` identifier appears, and its
   accessibility value reaches `uploaded <fileID>` — the server's own answer, not a progress bar that
   went away;
4. the test types a message, taps Send, and finds the post by reading `GET /channels/{id}/posts` back;
   the post's `file_ids` is exactly the file the chip uploaded, and the row is in the list;
5. `GET /files/{id}/info` reports `image/png`, a name starting `pasted-image-`, and non-zero size.

The size is the *encoder's* (248 B for the 70 B 1×1 fixture), because a paste arrives as a `UIImage`
and is re-encoded — requirement 3's conversion, not a bug.

Two environment notes, both pre-existing and neither caused by this card:

* The rest of the T35 UI suite is currently red against this fixture: `channelSidebar.channel.<id>` for
  `#t35-composer` is never in the tree because the account is a member of ~306 `t8g-probe-*` channels
  that flood the sidebar `List`. Reproduced with an untouched test
  (`build/logs/t9fe70579-baseline-ui.log:297`, `testSendingAMessageAppearsOnceAndCarriesTheServersID`),
  which is why this case navigates by the quick switcher instead of `openChannel`.
* The first read of another app's pasteboard on this simulator is gated by the system's paste prompt;
  the test answers it (`allowPasteIfAsked`) the way a person taps "Allow Paste". Before the
  metadata-only fix in §3, that prompt appeared while the *menu* was being built and left the app
  unresponsive — the reason the first attempts at this test looked like "nothing happened at all".

## 6. Out of scope

**Drag and drop of files onto the composer is a different gesture** (`UIDropInteraction` /
`NSItemProvider` drop), not `paste:`; it is not implemented here and stays a separate card. The intake
was written so that card can reuse it without a second upload path: `ComposerPaste.read` takes an
explicit `ComposerPasteboard`, so a drop would pass `ComposerPasteboard(itemProviders: session.items)`
and get the same attachments, naming and failures.

Not claimed: the Catalyst Edit ▸ Paste *menu* was exercised only through `canPerformAction` (the action
the menu validates with), not by driving the menu itself.
