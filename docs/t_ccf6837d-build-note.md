# t_ccf6837d — the gallery's zoom and share, proven live

Closes the parity gap `files-attachments / zoom-and-share-an-image` (found by the v2 scan,
`t_0230e17e`): the code existed (`ZoomableImageView`, `AttachmentShare`, `SharePayload`) but nothing
in T38 named zoom or the share sheet, so the row was `partial / gap`.

This card is the proof, and the two seams that make proof possible. It changes no product behaviour
except one thing that was wrong to leave unstated: the share path's refusal copy now lives next to the
staging code as a value (`AttachmentShareRefusal`), so "a blocked file is refused with the existing
copy" is a testable statement rather than a string inside a view.

## 1. What was added

| File | Change |
|---|---|
| `Mattermost/UI/Native/Files/ImageViewer.swift` | `AttachmentGalleryDiagnostics` (`-uiTestExposeGalleryDiagnostics`); the gallery page is an addressable AX container (`attachmentGallery.page.<fileID>`, `.accessibilityElement(children: .contain)`); two diagnostic seams (`.zoom` on the page, `.share.staged` in the header); `ZoomableImageView` publishes zoom changes (`scrollViewDidZoom`/`scrollViewDidEndZooming`) and takes an AX id for its scroll view; `shareCurrent()` now goes through `AttachmentShareFlow` |
| `Mattermost/UI/Native/Files/AttachmentDownloads.swift` | `AttachmentShare.Staged` (url + sanitised name + byte count + digest), `AttachmentShare.stage(named:data:)`, `AttachmentShare.digest(of:)`; `AttachmentShareRefusal` (the two existing sentences, moved not reworded); `AttachmentShareFlow.stage(_:from:)` — the gallery's Share action as a `Result` |
| `MattermostTests/T38AttachmentTests.swift` | new class `T38AttachmentShareTests` (5 cases) |
| `MattermostUITests/T38AttachmentsUITests.swift` | two live cases + the `t38-share` fixture plumbing, `fileBytes(_:)` (the server's bytes as the oracle), `digest(of:)`, and the seam readers |
| `scripts/t38_attachment_seed.py` | third fixture post `props.t38_key = t38-share`: one **2560×1600** PNG (`t38-panorama.png`, 188,252 bytes as stored). Also removes a dead duplicate `main()` the file had carried |
| `docs/parity/module-scan.tsv` | the row: `partial`/`gap` → `native`/`parity`, citing the two live cases and the four unit cases |

Nothing here is new UI: the seams are four-point clear squares gated on a launch argument, the same
shape `ScrollGeometrySeam` (`ChannelScrollDiagnostics.swift`) and `EditProfileView.digest` already use.
A shipping build reads `ProcessInfo` once and draws nothing; the per-frame zoom reporting is `nil`
unless the flag is present.

## 2. Why the fixture needed a third post

The gallery draws every image at a **2048 px** long edge (`ChannelImageStore.galleryMaxPixel`) and
shares the file's **own** bytes (`originalData`). On the existing 640×480 fixtures those two payloads
have the same pixel size, so "shared the original" and "shared the bitmap on screen" would both look
plausible — a wrong implementation could pass. `t38-panorama.png` is 2560×1600, so the draw bitmap is
a genuine reduction and the two payloads differ in byte count and digest.

Measured on the seeded fixture (`GET /api/v4/files/m3xugfjptiboz8hb6dpg4fo65e`):

- the file: **188,252 bytes**, 2560×1600;
- the share seam reported `name=t38-panorama.png bytes=188252 sha256=<first 8 bytes of SHA-256>`, which
  is exactly `sha256(file)` computed by the test from the server's own bytes;
- the sheet that came up (screenshot `t38-17-share-presented` in the xcresult) is
  `UIActivityViewController` carrying a **document named `t38-panorama.png`** with Copy / Save to
  Files / Print / Assign to Contact / Add to Shared Album / Create Watch Face / Reminders / More — the
  file-type activities, not the image-only set a `UIImage` item would produce.

## 3. The cases

Live (`MattermostUITests/T38AttachmentsUITests.swift`, iPhone 16 Pro / iOS 18.3, the board's live
device id `81A7F251-…`, against the local 9.11.19 fixture):

1. `testDoubleTapAndPinchZoomToTheCapAndTheSecondDoubleTapRestores`
   - at rest the page's seam reads `current=1.00 peak=1.00`;
   - `pinch(withScale: 3)` → `current > 1.5`;
   - `doubleTap()` while zoomed → back under `1.1` (the "and restores" half);
   - `doubleTap()` at rest → `current > 3.8 && peak > 3.8`, i.e. the 4× cap `ZoomableImageView` sets;
   - `doubleTap()` again → back under `1.1`.
   Two numbers, not one: a zoom is animated, so a single sample read at the wrong instant says nothing
   about where it went. `peak` is kept in the scroll view's coordinator (not in SwiftUI state) for the
   same reason. Screenshots `t38-12…t38-15` are attached in the xcresult; `t38-14-zoom-at-cap` shows
   the image visibly magnified, not the whole gradient.
2. `testTheShareControlHandsTheSheetTheFilesOwnBytesNotTheDownsampledBitmap`
   - downloads the fixture file through the API as an independent oracle and hashes it;
   - requires the image to exceed the 2048 draw cap (otherwise the case would prove nothing);
   - taps `attachmentGallery.share` and requires the seam to report exactly
     `name=… bytes=<server size> sha256=<server digest>`;
   - requires a sheet to be on screen.

Unit (`MattermostTests/T38AttachmentTests.swift`, class `T38AttachmentShareTests`):

3. `testAStagedShareIsTheFilesOwnBytesAndNotItsGalleryBitmap` — stages a 2560×1600 file, asserts the
   staged file on disk is byte-identical to the original, its byte count and digest are the file's,
   and its digest differs from a PNG re-encode of the gallery bitmap;
4. `testSharingABlockedFileIsRefusedWithTheExistingCopyAndAsksNobody` — `.bytesUnavailable`, copy
   "This image could not be loaded to share.", `service.requested.isEmpty` (the refusal costs no
   request: `originalData` returns nil for a blocked file before fetching);
5. `testAFileWhoseBytesCannotBeFetchedGetsTheSameRefusalAndHadBeenAskedFor` — same copy, but the
   fetch *was* attempted, which is what makes the blocked case special;
6. `testAHostileNameCannotEscapeTheShareDirectory` — `../../../../etc/passwd.png` stages as
   `passwd.png` inside `attachment-share/`.

## 4. The blocked-file share is unit-only, and why

`is_blocked` is set by the server's file scanner (ClamAV/plugin), not by anything this fixture server
has, and it cannot be patched through `PATCH /config` or the file API. So a live case cannot produce a
blocked file to share. What a live run *can* prove is the branch the blocked case takes
(`originalData` → nil → the refusal), and that branch is pinned twice: at the store
(`testOriginalBytesAreAvailableForTheFileReadersAndRefusedForABlockedFile`, pre-existing) and at the
share decision (case 4, and case 5 for the same branch reached by a failed fetch). The card asked for
"the existing copy" and got it unchanged: `AttachmentShareRefusal.bytesUnavailable` is the sentence the
gallery has shown since T38 was built.

## 5. Limits

- Blocked-file **share** is unit-only (above). No APNs, no licensed features — not touched here.
- Zoom is asserted through a seam, not by measuring pixels: the app publishes its own scale
  (`current`/`peak`), and the screenshot is the human-readable cross-check. A bug that reported a
  scale it did not apply would not be caught by the seam alone; the two screenshots at rest and at
  cap are what covers that.
- The share case proves the staged payload's bytes by digest. It does not drive a *receiving* app
  ("save to Files" and read it back), which would need a second process and a document picker the
  simulator cannot script reliably.
- `AttachmentShare.temporaryFile` still leaves files in `tmp/attachment-share/`: the OS reclaims the
  directory, and a share overwrites the same sanitised name.

## 6. How to reproduce

```
python3 scripts/t38_attachment_seed.py --url http://127.0.0.1:8065     # adds the t38-share post
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
python3 scripts/qa-test.py --platform ios --sim "id=81A7F251-8B31-4945-8783-5A264C14B8D5" \
  --only-testing "MattermostUITests/T38AttachmentsUITests" --label t_ccf6837d-live-t38
python3 scripts/qa-test.py --only-testing MattermostTests/T38AttachmentShareTests --label t_ccf6837d-unit-share
python3 parity/check_scan.py        # after a full unit run into build/logs/parity-scan-unit.log
```

## 7. Runs

Run logs are in `build/logs/` (untracked, as with every other card):

| log | what | result |
|---|---|---|
| `t_ccf6837d-live-zoom.log` | case 1 alone | **1 run, 0 skipped, 0 failed** (55.7 s) |
| `t_ccf6837d-live-share.log` | case 2 alone | **1 run, 0 skipped, 0 failed** (70 s) |
| `t_ccf6837d-pair-1..3.log` | cases 1+2 together, three consecutive runs | **2 run, 0 skipped, 0 failed** each |
| `t_ccf6837d-unit-share.log` | `T38AttachmentShareTests` | **5 run, 0 failed** |
| `parity-scan-unit.log` | full `MattermostTests` at this tree (`qa-test.py --only-testing MattermostTests --label parity-scan-unit`) | **2413 run, 8 skipped (opt-in), 0 failed, xcodebuild rc=0** |
| `parity/check_scan.py` | the record re-validated against that log | `rows: 159 across 16 modules; 331 evidence refs checked` → **OK** |
| `parity/generate.py --self-test` | generator break-proofing | **PASS** (6/6 planted faults, 6 artifacts byte-identical) |

`parity/generate.py --check` reports **0 artifact drift** and **1 fatal finding**
(`VALIDATED-BUT-NOT-APPROVED X:web-fallback`), which is **not** from this card: re-running the check
with `docs/parity/module-scan.tsv` stashed reports the same finding. It lives in
`parity/claims.tsv`'s `X:web-fallback` surface and belongs to that owner decision.

So the two live cases are green on the acceptance device, and green six more times in three paired
runs; the whole unit suite is green, which is what `parity/check_scan.py` needed.

### 7.1 One honest caveat: whole-class runs are unstable on this host

The class run (all six T38 live cases back-to-back, `t_ccf6837d-live-t38*.log`) is **not** green, and
the failure moves:

| class run | outcome |
|---|---|
| `-live-t38` | 6 run, 1 failed: `testSavingAGalleryImageShowsItInTheDownloadsScreen`, "Lost connection to the application" while the gallery opened |
| `-live-t38b` | 6 run, 1 failed: `testTheFileRowsNameTheirTypeAndEachOpensOnlyItsOwnReader`, "application is not running" mid-way through the readers |
| `-live-t38c` | 6 run, 1 failed: `testDoubleTapAndPinchZoomToTheCapAndTheSecondDoubleTapRestores`, "Lost connection" on the first zoom-seam read, 5 s after the gallery opened |
| `-live-t38-baseline` (this card's diff stashed, i.e. the four pre-existing cases only) | 4 run, 0 failed |

What the failures have in common: the **app process disappears** at a point unrelated to the
assertion. Two produced no crash report at all (silent termination — the shape of a jetsam kill); one
produced `Mattermost-2026-11-05-135743.ips`, a SIGSEGV inside XCTest's own snapshot machinery
(`-[XCElementSnapshot value]` → `runtime_issue_os_log_fault_callback` → `_platform_strcmp`), i.e. the
automation framework, not app code. The host had **six booted simulators** and 16.7 GB of process RSS
at the time.

It is not attributable to these two cases as such: they ran 8 times in isolation without a failure and
passed in two of the three class runs (the third killed the zoom case before it made its first
gesture). But it is a real observation about this suite on this host and is carded separately rather
than buried: `t_8d093748` (T38 whole-class live run terminates the app at random points).

## 8. Pointers kept honest

- The gallery page now carries `attachmentGallery.page.<fileID>` as an accessibility **container**
  (`.accessibilityElement(children: .contain)`), so the page is addressable by the server's file id.
  That is the one change on the always-on accessibility path; the zoom/share seams next to it exist
  only with `-uiTestExposeGalleryDiagnostics`.
- `ZoomableImageView` deliberately does **not** make its `UIScrollView` an accessibility element (an
  earlier draft set an id on it): a container that also claims to be an element adds an AX node to
  every snapshot for no test's benefit, and the page container is the better address anyway.

