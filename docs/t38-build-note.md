# T38 — native attachments, gallery and file previews (S18)

The read surface for a post's files: inline image thumbnails in a grid, the full-screen gallery, the
file row with its type icon/name/size, the PDF and text readers, the refusal screen for a hostile
type, and **save** through the shell's existing download path. Everything here draws bytes the app
fetched itself through `APIClient`; nothing in this surface is handed to a webview or an interpreter.

Companion rows: `docs/parity.md` (T38), `docs/THIRD_PARTY_NOTICES.md` §15 (the upstream read set),
`docs/t38-file-probe-2026-10-26.log` (the server measurements), `docs/t38-shots/` (the screens from
the live run), and `docs/t38-mem-probe-2026-10-26.csv` + `docs/t38-mem-fold-2026-10-26.txt` (the
bounded-load measurement in §3.1).

## 1. Files

| File | What it owns |
|---|---|
| `Mattermost/UI/Native/Files/AttachmentModels.swift` | `PostAttachment` (decoded from `metadata.files`), `AttachmentSection` (images first, then files), `AttachmentGallery` (one post's images + the tapped index), `AttachmentImageGrid` (1/2/3 columns; every image is drawn — there is **no** `+N` remainder, see §8), `AttachmentDownloadState` (the row's second line), `AttachmentPreviewTarget` / `AttachmentGalleryTarget` |
| `Mattermost/UI/Native/Files/FileTypeMap.swift` | the classifier and the refusal list; `FileCategory`, `FilePreviewKind`, the row's symbol/type label, `textPreviewByteLimit`, `previewFetchByteLimit` (§8) |
| `Mattermost/UI/Native/Files/AttachmentImageStore.swift` | `ChannelImageStore`: bounded previews, one request per file id, cancellation, LRU |
| `Mattermost/UI/Native/Files/AttachmentViews.swift` | `AttachmentSectionView`, `AttachmentImageCell`, `AttachmentFileRowView`, `PostRowAttachmentActions` |
| `Mattermost/UI/Native/Files/ImageViewer.swift` | `AttachmentGalleryView` (paging, counter, zoom, share, save), `AttachmentGalleryPage`, `ZoomableImageView` |
| `Mattermost/UI/Native/Files/FilePreviewView.swift` | `AttachmentPreviewView` (image/text/PDF/refusal), `TextPreview`, `PDFKitView` |
| `Mattermost/UI/Native/Files/AttachmentDownloads.swift` | `AttachmentDownloads` (the row ↔ journal binding), `AttachmentShare`, `ActivityView` |
| `Mattermost/Core/DownloadWorker.swift` | (changed) `download(request:suggestedFilename:)`, `install(downloadedFileAt:…)`, `occupiedNames(in:excluding:)`, `task(for:)`, and the `resume()` the transfer needed |
| `Mattermost/Core/MM/APIClient.swift` | (changed) `authorizedRequest` — an authenticated request the caller can hand to the transfer engine without exposing the token to it |
| `Mattermost/UI/Native/Channel/ChannelService.swift` | (changed) `fileDownloadRequest(fileID:)` |
| `Mattermost/UI/Native/Channel/ChannelPaneCoordinator.swift` | (changed) one `AttachmentDownloads` per server |
| `Mattermost/UI/Native/Channel/PostRowView.swift`, `ChannelView.swift`, `Thread/ThreadView.swift` | (changed) the section, and one item-bound sheet per window for the gallery and the preview |
| `Mattermost/UI/DownloadsView.swift` | (changed) `downloadStatus-<name>` on the size/state line, so "did it land?" is addressable |
| `MattermostTests/T38AttachmentTests.swift` | 70 unit tests (eleven classes) |
| `MattermostUITests/T38AttachmentsUITests.swift` | 4 live UI tests |
| `MattermostUITests/T38HeavyScrollProbeUITests.swift` | the memory probe (§3.1) — a harness, not a suite member: it skips unless `#t38-heavy` and `MM_AUTH_*` exist |
| `scripts/t38_attachment_seed.py`, `scripts/t38_file_probe.py` | the fixture and the server probe |
| `scripts/t38_heavy_seed.py`, `scripts/t38_mem_sample.py`, `scripts/t38_mem_fold.py` | the media-heavy fixture, the RSS/footprint sampler and the fold behind §3.1 |

## 2. The rules, and what the server actually does

The classifier is one pure function of (name, MIME type): **the extension decides; the MIME type only
speaks when the name has none.** That is deliberately the opposite of "trust the server's
`mime_type`", because `mime_type` is an upload claim: a `.png` that is served as `text/html` is
refused, and an `.html` that is served as `image/png` is refused too. Both directions are unit-pinned
(`testTheExtensionDecidesEvenWhenTheServerClaimsAnImageMimeType`, and the refusal list's own test).

Measured on the local server (v9.11.19, `scripts/t38_file_probe.py` →
`docs/t38-file-probe-2026-10-26.log`):

- `GET /files/{id}/thumbnail` answers a **120×90 PNG in 250 bytes** for a 640×480, 103,980-byte
  original (75×100 for a 480×640 one, 170 bytes for a 400×100 one). At the ~300 pt bubble width that
  is a blurred preview, so the inline path fetches the **original** and downsamples locally to
  600 px. Thumbnails are not used anywhere in this card.
- `/thumbnail` answers **400** for a non-image (text, PDF, zip) — there is nothing to fall back to,
  which is the second reason the store never asks for one.
- The server **normalises** the stored `mime_type`: an `image/png` upload whose body is HTML comes
  back as `text/html; charset=utf-8`. So the hostile fixture is hostile by name *and* by the type the
  server reports; the "forged MIME" case is covered by a unit test instead of a fixture that the
  server would not keep.
- `POST /posts` refuses more than **10** file ids (`400 model.post.is_valid.file_ids.app_error`,
  "uploads are limited to 10 files maximum"). It is a product limit, not a setting: `PATCH /config`
  with `FileSettings.MaxFileCount` answered 200 and changed nothing. **A single post cannot carry 10
  images and 6 other files**, so the fixture is two posts and the 14-attachment case exists only as a
  unit test decoding a 14-file `metadata.files` payload.
- No file in the fixture was blocked by the server, so the "the server blocked this file" branch is
  unit-only (`isBlocked` from the API's own flag).

## 3. The image store

`ChannelImageStore` is one per server (held by `ChannelPaneCoordinator`), `@MainActor`, and bounded on
purpose:

- inline previews are downsampled to ≤600 px, gallery images to ≤2048 px, during decode
  (`CGImageSource` thumbnail options), so a 4000-px photo never becomes a 4000-px bitmap in memory;
- at most one request per file id is in flight however many cells ask (a 10-image grid on a scroll
  and a gallery page for the same file share one download);
- a cell that scrolls away cancels its request when no other cell wants it;
- two caches, each with a count **and** a byte budget (`AttachmentImageStore`'s own constants):
  **previews** — `previewLimit` 40 decoded bitmaps / `previewByteLimit` 24 MB of estimated decoded
  bytes (a 600² RGBA bitmap is 1.4 MB, so the byte budget is usually the first to bite); **originals**
  — `originalLimit` 6 whole payloads / `originalByteLimit` 48 MB, for the gallery's share and save
  path. Gallery display bitmaps are separately capped at `galleryBitmapLimit` 3. (Earlier revisions of
  this section said "40 entries/32 MB", which is neither of the two budgets — T38-AV F7.)
- a failed fetch is **not** cached as a broken image (the cell shows a retry, and the next appearance
  refetches);
- the store never writes to disk, so a relaunch refetches (stated as a limit in the parity row).

### 3.1 Bounded, and measured (the card's memory criterion)

The criterion is *"image loading is cancellable and bounded … measure it with the T27 probe."* The
cancellation half is unit-pinned (`testACancelledRowCancelsTheRequestAndCachesNothing`,
`testTwoRowsAskingForOneFileShareASingleRequest`); the bound is measured the way T27 measured the
webview — sample the process from outside while a real channel scrolls — because a cache only shows
itself under real pixels.

Fixture: `scripts/t38_heavy_seed.py` → `#t38-heavy` in team `perf`, 4 posts × 10 images, 1024×768
**noisy** PNGs, **83,042,276 bytes** in total, 2,075,541..2,076,496 bytes each. A flat-colour PNG
downloads in a few hundred bytes and would measure nothing, which is why the pixels do not repeat.

Run (repo root, 2026-10-26 03:52–03:55 PDT; simulator `023B9070-…`, iPhone 17 Pro / iOS 26.0,
`--derived-data ~/Library/Developer/Xcode/DerivedData/t38-ios`):

```
python3 scripts/t38_mem_sample.py 600 > build/logs/t38-mem-probe-1.csv &
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<local fixture password> \
python3 scripts/qa-test.py --platform ios --sim "id=023B9070-…" \
  --derived-data ~/Library/Developer/Xcode/DerivedData/t38-ios \
  --label t38-heavy-probe-1 --only-testing MattermostUITests/T38HeavyScrollProbeUITests
python3 scripts/t38_mem_fold.py build/logs/t38-mem-probe-1.csv \
  1793011904.387795 1793012073.729881 1793011937.656174 1793011962.756376 \
  1793011987.955987 1793012013.139639 1793012038.339583 1793012063.7201
```

`run : t38-heavy-probe-1 · 1 run, 0 skipped, 0 failed · 231 s · RESULT: PASS`
(`build/logs/t38-heavy-probe-1.log`). The sampler watches the app; the test only drives it and prints
its own `PROBE-START` / `PROBE-PASS-<n>` / `PROBE-END` epoch markers, which are the window and pass
boundaries given to the fold. Window 1793011904..1793012074 (169 s), **151 one-second samples**,
one pid:

```
rss MB      : first=454.7 last=366.9 min=366.9 max=459.9 mean=402.4
rss thirds  : t1=449.5 t3=375.4 delta=-74.1 MB
footprint MB: first=144.0 last=151.7 min=144.0 max=151.7 (n=9)
pass peaks  : 459.9 452.6 416.6 380.1 380.2 379.1 MB
```

Read it as a **plateau with re-fetch churn, not growth**: RSS falls 74.1 MB across the six passes and
the per-pass peaks stop climbing after the second (459.9 → 452.6 → 416.6, then 380.1 / 380.2 / 379.1),
while physical footprint moves 144.0 → 151.7 MB and peaks there. `previewLimit` 40 with
`previewByteLimit` 24 MB is smaller than one pass of ten 2 MB images decoded at 600², so every pass
evicts and refetches — the state in which an unbounded cache would climb pass after pass. The CSV and
the fold's own output are `docs/t38-mem-probe-2026-10-26.csv` and `docs/t38-mem-fold-2026-10-26.txt`.

What this measurement is **not**: one run, one host, a simulator rather than a device, `ps`-RSS rather
than Instruments, 40 images rather than hundreds, and it cannot see a leaked *request* — only that the
bitmap and byte caches stay bounded (§8.1). T38-AV measured the same shape independently on its own
fixture (40 × ~2 MB, six passes: RSS first third 461.3 → last third 409.6 MB, footprint 142.1 →
150.4 MB), which is why the criterion is answered with two runs rather than one.

## 4. The download path: one worker, and `done` means on disk

A save does **not** have a second download path. The row calls
`ChannelService.fileDownloadRequest(fileID:)`, which builds the request through
`APIClient.authorizedRequest` (the bearer token stays inside the API client; `DownloadWorker` only
transfers a `URLRequest`), then `DownloadWorker.download(request:suggestedFilename:)` journals it and
`DownloadWorker.install(downloadedFileAt:…)` moves the session's temporary file into
`URL.downloadsDirectory` under the sanitised, de-duplicated name. The row's state is
`DownloadHistory`'s state, so a row and the Downloads screen cannot disagree.

## 5. What the live run forced (all measured, all repaired)

1. **The transfer never started.** `startDownload` created a `URLSessionDownloadTask` and returned —
   without `resume()`. The journal row existed, the Downloads screen drew it, and it sat at
   **"0 B · Progressing"** forever with no delegate callback and no file
   (`docs/t38-shots/t38-11-downloads-row.png`, from the first live green run — which passed only
   because it asserted the row *existed*). Repair: `task.resume()` in `startDownload` and in `retry`,
   plus `DownloadWorker.task(for:)` so a test can assert the task is not `.suspended`
   (`testAStartedDownloadIsActuallyRunning`). The mutation check is
   `build/logs/t38-mutation-resume.log`: with the `resume()` deleted the test fails by name and
   nothing else does.
2. **Every save landed as `name (2).ext`.** The name de-duplication read the journal *including the
   record that was landing*, which is already there when its bytes arrive — measured on disk:
   `Downloads/t38-shot-01 (2).png` for the first save of that file. Repair:
   `DownloadWorker.occupiedNames(in:excluding:)` counts only records that **landed** and never the one
   landing now (`testTheRecordBeingLandedDoesNotReserveItsOwnName`).
3. **"Did it land?" was not addressable.** `downloadRow-<name>`'s accessibility label resolves to the
   thumbnail's label ("Photo"), so a UI test could only ask whether the row existed — the weak
   assertion that let (1) pass. Repair: the row is one container element
   (`.accessibilityElement(children: .contain)`) whose **value** is the size/state line, so the live
   test can require **Downloaded** and a non-zero size, and the row's own menu stays reachable.
4. **The first real transfer killed the app** (`signal kill`, reproduced with the save test alone).
   `DownloadFlow` is main-actor isolated (nested in the `@MainActor` worker, mutating the journal the
   Downloads screen draws) while `URLSession` invokes its delegate on a private background queue —
   the runtime traps the first time a callback arrives, which is exactly when `resume()` starts
   working. Repair: `delegateQueue: .main` on the flow's session (the work in the callbacks is a
   rename inside the container plus a journal write).
5. **A landed row read "0 B · Downloaded".** `didWriteData` is not guaranteed even once for a small
   response, so `totalBytes` stayed 0. Repair: the landing step takes the byte count from the file it
   just moved, which is the only honest source for "how many bytes landed".

The first point is the one that matters for the card's claim: before these repairs the surface could
show a row for a file that was never saved, and every test above it would still have been green.

## 6. Hostile and unreadable types

`FileTypeMap` refuses to preview a type whose bytes a renderer would act on — the extensions
`html, htm, xhtml, xht, shtml, svg, svgz, xml, xsl, xslt, wasm, app, exe, msi, com, scr, vbs, jse,
wsf, hta, swf, jar, pkg, command, tool, terminal, mobileconfig, mobileprovision, scpt, applescript,
webloc, url, desktop, cgi, asp, aspx, jsp` — and the MIME types that claim them (`text/html`,
`application/xhtml+xml`, `image/svg+xml`, `text/xml`, `application/xml`, `application/x-executable`,
`application/x-msdownload`, `application/x-apple-diskimage`, `application/x-command`,
`application/x-shockwave-flash`, `application/java-archive`,
`application/x-www-form-urlencoded`). A
refused file is drawn as an ordinary row — the reader still sees the server's name, type and size —
and opening it shows the refusal screen with its own download, share and close controls and the
sentence explaining *why*. The bytes are never written to a temporary file for a webview, never
opened in Safari, never handed to `WKWebView`, `AVPlayer` or `QLPreviewController`. The live suite
asserts the HTML fixture's marker text never appears anywhere in the app and that the app has
**zero** `webViews` at that moment.

Text and code are read as text: UTF-8 first, then ISO-8859-1 (every byte valid, which is what makes a
legacy export readable instead of mojibake), capped at 256 KB with a "showing the first N" note
(`attachmentPreview.text.truncated`). PDFs go to `PDFKit`, whose own sandbox does the parsing.

## 7. Evidence

Unit suite — 70 tests, eleven classes, all green on Mac Catalyst:

```
python3 scripts/qa-test.py --platform mac \
  --derived-data ~/Library/Developer/Xcode/DerivedData/t38-unit --label t38r-unit-1 \
  --only-testing=MattermostTests/T38FileTypeClassificationTests \
  --only-testing=MattermostTests/T38AttachmentSectionTests \
  --only-testing=MattermostTests/T38AttachmentDecodingTests \
  --only-testing=MattermostTests/T38TextPreviewTests \
  --only-testing=MattermostTests/T38DownloadLandingTests \
  --only-testing=MattermostTests/T38LandedNameTests \
  --only-testing=MattermostTests/T38PreviewFetchLimitTests \
  --only-testing=MattermostTests/T38AttachmentDownloadStateTests \
  --only-testing=MattermostTests/T38AuthorizedRequestTests \
  --only-testing=MattermostTests/T38ChannelImageStoreTests \
  --only-testing=MattermostTests/T38AttachmentDownloadsTests
```

`tests: 70 run, 0 skipped, 0 failed` → `RESULT: PASS` (`build/logs/t38r-unit-1.log`, 28 s
incremental). The 62-test run this card inherited is `build/logs/t38-unit-10.log`; the eight tests
added by the T38-AV repair are `T38LandedNameTests` (3, the `Saved as …` line and the de-duplicated
landing) and `T38PreviewFetchLimitTests` (5, the 32 MB whole-file fetch bound).

Live UI suite against the real server (`http://127.0.0.1:8065`, account `perfprobe`, iPhone 17 Pro /
iOS 26.0 simulator):

```
export TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
       TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
       TEST_RUNNER_MM_AUTH_PASSWORD=<local fixture password>
python3 scripts/qa-test.py --platform ios \
  --sim "id=023B9070-CAD0-409B-BFD0-78FF5CA5EACC" \
  --derived-data ~/Library/Developer/Xcode/DerivedData/t38-ios \
  --label t38-live-5 --only-testing MattermostUITests/T38AttachmentsUITests
```

```
run        : t38-live-5
outcome    : finished (xcodebuild rc=0, ~150 s)
tests      : 4 run, 0 skipped, 0 failed
RESULT: PASS          # ** TEST SUCCEEDED **, 4 tests in 132.7 s
```

Re-run after the T38-AV repairs (the `tooLarge` preview branch, the `Saved as …` Downloads line, the
new unit classes): label `t38r-live-1`, `4 run, 0 skipped, 0 failed`, 154 s, `RESULT: PASS`
(`build/logs/t38r-live-1.log`) — the repair touches two views, so the live suite was re-derived rather
than assumed.

`build/logs/t38-live-5.log`. What the four tests assert, all against the server's own API rather than a
mock:

1. `testATenImagePostDrawsEveryThumbnailAndTheGalleryPagesThroughAllOfThem` — the ten-image post from
   `GET /channels/{id}/posts` draws ten cells (`post.<id>.attachment.<fileID>` for each id the server
   returned), tapping the first opens the gallery at "1 of 10", swiping walks to "10 of 10", and
   closing returns to the list.
2. `testTheFileRowsNameTheirTypeAndEachOpensOnlyItsOwnReader` — each row names the server's file name
   and its type; `.txt` opens the text reader **with the file's actual content**, the PDF opens
   `attachmentPreview.pdf`, the zip opens the refusal screen (its own bytes are never rendered) and
   the log opens the text reader **with the truncation note** (421 KB file, 256 KB cap).
3. `testAnHTMLAttachmentIsRefusedAndItsScriptNeverRuns` — the `.html` row opens the refusal screen, the
   page's marker text appears nowhere in the app, and the app has **zero** `webViews` at that moment.
4. `testSavingAGalleryImageShowsItInTheDownloadsScreen` — saving from the gallery makes the Downloads
   screen show a row for the server's file name whose state is **Downloaded** with a real size (not
   "0 B · Progressing"). Verified on disk outside the test as well: the simulator's app container holds
   `Downloads/t38-shot-01.png`, **103,980 bytes** — exactly the original's size from
   `docs/t38-file-probe-2026-10-26.log` (`docs/t38-shots/t38-11-downloads-row.png` reads
   "103.98 kB • Downloaded"). The `t38r-live-1` re-run saved again with the earlier files still in
   Downloads, so it landed as `t38-shot-01 (3).png` while the row kept the server's name and drew the
   repair's second line: `docs/t38-shots/t38-12-downloads-saved-as.png` reads
   "t38-shot-01.png / 103.98 kB • Downloaded / **Saved as t38-shot-01 (3).png**" — the landed name is
   the one on disk (`ls` of the container agrees), which is F6 fixed and seen in the running app.

`docs/t38-shots/t38-01…11` are exported from this run's `xcresult` by
`scripts/t37_export_shots.py` (the same exporter the earlier cards use); `t38-12-downloads-saved-as.png`
is the same export from the `t38r-live-1` re-run's attachment.

## 8. Limits that stay

- Audio, video, tables and LaTeX have **no reader**: they land on the refusal screen rather than in a
  player. That is the safe branch, not a placeholder that pretends to work.
- A post carries at most 10 attachments (server limit, measured in §2), so "10 images and 6 files in
  one post" cannot exist on a real server.
- The inline preview downloads the **original** bytes (the server's thumbnail is 120 px wide, §2), so
  a large photo costs its full size in transfer.
- Previews are memory-only; a save re-downloads rather than reusing the preview's bytes.
- A **text or PDF file larger than `FileTypeMap.previewFetchByteLimit` (32 MB)** is not previewed in
  place: the sheet says the file is too large and offers Download instead
  (`PreviewFetchDecision` → `attachmentPreview.tooLarge`). The readers need the whole payload
  (`PDFDocument(data:)`, `TextPreview.decode`), so the bound has to be on the **fetch**, and it is
  decided from the `metadata.files` size the post already carries — before any bytes arrive. Before
  this repair (`T38-AV` F5) a 100 MB log became a 100 MB `Data` and the 256 KB text cap only bounded
  what was drawn. An image is **not** gated by this rule: the gallery fetches the file and downsamples
  during decode, bounded by pixel count, so a large photo still costs its full transfer size (§2).
- The Downloads screen's own **Retry** re-sends the stored source URL without a bearer token, so it
  cannot recover a private attachment. The row's Retry (which rebuilds the authenticated request)
  is the working one. Fixing the screen's Retry would mean persisting a credential next to a journal
  row, which this client does not do; the limit is written down instead.
- Sharing is `UIActivityViewController` and nothing beyond it (no "open in another app" plumbing).
- Text previews are plain selectable text, capped at 256 KB — no syntax highlighting.
- The gallery pages images only, in the order the server lists them.
- No part of this surface works offline.
- The inline grid draws **every** image, in the 1/2/3-column layout above. There is no `+N` remainder
  chip (upstream collapses a long set); earlier revisions of this note and the parity row claimed one
  — T38-AV F4, corrected rather than implemented.

### 8.1 What "verified" excludes (T38-AV F8)

Written down so the next reader knows what the green runs do **not** cover. Every item here is a
deliberate, honest gap, not a hidden failure:

- **Thread-pane attachments have no test at all** — neither unit nor live. `ThreadView` draws the same
  `AttachmentSectionView` and presents the same item-bound `.gallery` / `.preview` sheets as
  `ChannelView`, but only the channel pane's are exercised (the live suite never opens a thread).
- **The `.csv` row is drawn and never opened.** `csv` classifies as `.text` (so it gets the text
  reader), and the live suite opens `.txt`, `.pdf`, `.log` and `.zip` — never a `.csv`.
- **Audio and video refusal, and the server-blocked (`isBlocked`) branch, are unit-only.** No fixture
  file was blocked by the server (§2) and the live suite deliberately does not play media, so those
  two branches are pinned by `T38FileTypeClassificationTests` / `T38AttachmentDecodingTests` alone.
- **The Downloads screen's own Retry is documented as broken and never demonstrated.** §8 says it
  re-sends the stored URL without a bearer token; no test proves it fails (and none should start
  passing by accident).
- **Inline-preview cancellation is unit-fakes-only.** `T38ChannelImageStoreTests` proves the store
  drops the waiter and cancels the request when its caller is cancelled; the real `.task`-on-scroll-away
  path is not asserted anywhere. What *is* measured on a real scroll is the bound: §3.1's probe scrolls
  40 images × ~2 MB six times and folds the sampler's RSS/footprint, which would expose an unbounded
  cache — it cannot, however, see one leaked request.
- **The remainder chip absence and the `tooLarge` refusal** are pinned by unit tests and the source
  text respectively; no live fixture has a >32 MB attachment (the server's own upload limit is lower
  than the fetch limit on this host), so `attachmentPreview.tooLarge` has never been drawn by a test
  on a device.
- **The memory probe is a harness, not a suite member.** `MattermostUITests/T38HeavyScrollProbeUITests`
  skips unless the heavy fixture (`scripts/t38_heavy_seed.py`) and the `MM_AUTH_*` environment exist,
  so it is not part of the 4-test live suite and does not contribute to its "0 skipped".

## 9. Identifiers

`post.<postID>.attachments` (the section), `post.<postID>.attachment.<fileID>` (an image cell or a
file row) with `.download` / `.progress` / `.saved`, `attachmentGallery` + `.counter` /
`.page.<fileID>` (+ `.loading` / `.error` / `.retry`) / `.save` / `.share` / `.close` / `.empty` /
`.error`, `attachmentPreview` + `.title` / `.subtitle` / `.image` / `.pdf` / `.text` (+ `.truncated`)
/ `.unsupported` (+ `.download`) / `.download` / `.share` / `.close` / `.loading` / `.error` /
`.retry`, `attachmentPreview.tooLarge` (+ `.download`, the >32 MB refusal), and the Downloads screen's
`downloadRow-<name>`, `downloadStatus-<name>` and `downloadLandedName-<name>` (present only when
de-duplication landed the bytes under a different name).

## 10. Fixture

`scripts/t38_attachment_seed.py` creates two posts in the channel `t38-files` (team `perf`), keyed by
`props.t38_key` so a rerun reuses them (`--reset` deletes and recreates):

- `t38-images` — ten PNGs at different sizes and aspect ratios (640×480, 480×640, 300×300, 1024×768,
  1600×900, …), generated by the script so no binary lives in the repo;
- `t38-files` — `t38-notes.txt`, `t38-report.pdf` (a real 1-page PDF), `t38-bundle.zip`,
  `t38-dump.log` (421 KB, past the 256 KB text cap), `t38-payload.html` (its script would set
  `document.title` if anything ever ran it);

`scripts/t38_file_probe.py` prints the bytes/size/thumbnail facts the classifier and the store are
built on.
