# T53 — video and audio playback

Branch `t53/media-playback` (worktree `.worktrees/t_bfbbcbed`), based on `origin/main` at `b4ff722`.
Behaviour reference: `mattermost/mattermost-mobile` **v2.45.0**, commit
`162f2560d0e1df073220f7701d5a67cc17c8abeb` — `app/components/files/video_file.tsx`,
`app/components/files/audio_file.tsx`, `app/client/rest/files.ts`. Server: the pinned fixture,
Mattermost **9.11.19** at `http://127.0.0.1:8065`. Device/simulator: iPhone 16 Pro, iOS 18.3.

The card's claim is about a **real post rendered by the running app**, so that is what the evidence
below is: a real mp4 and a real mp3 uploaded through `POST /files` to a real server, attached with
`POST /posts`, found by the app, played by AVFoundation, and read back through the app's own
accessibility values (a playback-state transition, not a screenshot and not a stub agreeing with
itself).

## 1. What shipped

| Surface | Behaviour | Where |
| --- | --- | --- |
| Video in a post | A 16:9 poster cell built from the file's **first frame**, a play badge, the duration when the metadata carries one, tap → the player sheet | `MediaViews.swift` (`VideoAttachmentCell`), `MediaPlayback.swift` (`VideoPosterStore`) |
| Video player sheet | AVKit surface (`AVPlayerViewController` as the SwiftUI view), play/pause, scrubber, position/total clock, full-screen presentation, PiP configured (see §5), close | `MediaViews.swift` (`VideoPreviewView`, `VideoPlayerSurface`) |
| Audio in a post | A compact row: play/pause in the row, a progress bar, a position line, the duration when known and the type label otherwise — **no sheet** | `MediaViews.swift` (`AudioAttachmentRowView`); `AudioPreviewView` for the sheet route |
| Classification | `FilePreviewKind.video` / `.audio`, reached through the existing controlled extension table; `mime_type` is still uploader-controlled input and can only *refuse*, never enable | `FileTypeMap.swift` |
| Bucketing | `AttachmentSection` gained `videos` and `audios`; a blocked media file is a row (refusal screen), not a cell | `AttachmentModels.swift`, `AttachmentViews.swift` |
| Duration | `PostListDerivation.mediaDuration` reads `metadata.duration` (seconds) or `metadata.duration_seconds`; absent → the row shows `Audio`. The pinned 9.11.19 sends **no** `metadata` for these uploads, so the fallback is the measured path | `PostListModels.swift` |
| Transport | Authenticated `GET /files/{id}` through a `URLSessionDownloadTask` into `Caches/media-playback`, never a URL handed to AVFoundation | `MediaPlayback.swift` (`MediaFileCache`) |
| Lifecycle | No autoplay with sound; one player at a time; pause on resign-active; **stop and release** on background; pause on audio interruption; release on dismiss | `MediaPlayback.swift` (`MediaPlaybackCenter`, `MediaPlaybackController`) |

Wiring: `ChannelPaneCoordinator.media(for:)` owns one `ChannelMedia` per server (staging cache + poster
store); `ChannelView` and `ThreadView` pass it into `ChannelPostListView`/`ThreadPostListView` →
`PostRowView` → `AttachmentSectionView` → `AttachmentPreviewView`. The preview sheet shares the same
cache, so the file a poster staged is the file its player opens — one download, not two. `clear()` on
sign-out drops every staged file with the session.

## 2. The transport measurement (why AVFoundation never sees the token)

`GET /api/v4/files/{id}` needs the vault's bearer token and `AVPlayer` cannot send one. Putting the
token in the URL is forbidden. Two candidates were measured against the live fixture with the same
8-second clip:

| Path | Result (live) |
| --- | --- |
| A. `AVURLAsset(url:options:[AVURLAssetHTTPHeaderFieldsKey: ["Authorization": "Bearer …"]])` | `isPlayable=true`, `duration=8.0 s`, played past 4 s (the measurement's cap) |
| B. authenticated download → local file → `AVPlayer(url: fileURL)` | played past 4 s, `engine.duration=8.0`, `player.currentItem` detached on release |

Recorded by `MattermostTests/T53MediaTransportTests` (re-runnable, skips without credentials):

```
T53MEASURE A header out-of-band: playable=true duration=8.0 playedTo=4.098489951 error=nil
T53MEASURE B download-then-play: staged=gwaprbihs7nqzfq9um1eazogbo-t53-clip.mp4 bytes=75022 duration=8.0 playedTo=4.102839324
```

**B ships.** A works, but it depends on an undocumented option key, hands the credential to a framework
with its own logging surface, and its loader knows nothing about this app's `CertTrust` (T28's
self-signed server is expected to refuse; that case was not exercised here). B costs one cached file
and keeps the credential inside the app's authenticated request — the only place it already lives.

A unit test enforces the shape of the decision: `testThePlayerIsNeverHandedANetworkURL` asserts every
URL given to the engine is a `file://` URL.

## 3. Bounds — memory is not proportional to the file

* **Before any bytes move**: `PreviewFetchDecision.decide(kind:byteCount:)` refuses a media file past
  `FileTypeMap.previewFetchByteLimit` (**32 MB**) using the post's own `metadata.files` size. The sheet
  says the same number in words; a 300 MB video is refused, not downloaded.
* **While the transfer runs**: the download delegate cancels when `totalBytesExpectedToWrite` exceeds
  the bound (a server that lies about the size, or reports none, is still stopped).
* **On disk, not in memory**: `URLSessionDownloadTask` writes to a `.part` file; the finished file is
  renamed into place so a half-written payload can never be handed to AVFoundation.
* **Cache**: 4 files / 96 MB, oldest-by-modification evicted; `clear()` on sign-out.
* **Footprint measurement** (`testAStagedPayloadIsWrittenToDiskRatherThanHeldInMemory`, 32 MB streamed
  through a `URLProtocol` stub): measured deltas across runs — 278528, 442432, 1228800 and 5374016 bytes;
  one whole-bundle run in a process already holding 217 MB of other tests measured 22347904. The
  allocator's prior state is the noise, so the guard is the payload size itself (a transport that held
  the body as one `Data` would grow by ≥ 32 MB); the exact assertion is that all 32 MB land on disk.

## 4. Lifecycle and cancellation

* **No autoplay with sound**: the video sheet prepares and stays at position 0; the live UI test reads
  `0` after 1.5 s before tapping Play. Audio stages on the play tap, not on scroll.
* **One player**: `MediaPlaybackCenter.activate` stops the previous controller (engine released);
  `testOnlyOnePlayerMakesSound`.
* **Resign active** (control centre, banner) → pause. **Background** → stop + release; the engine is
  deallocated (`testBackgroundingStopsAndReleasesThePlayer`). **Audio interruption** (a call) → pause,
  and playback does not resume by itself.
* **Dismiss/leaving the row**: `.onDisappear` → `stop()`; an in-flight staging is cancelled through
  `URLSession` (`testCancellingStagingReportsCancelledAndLeavesNoFile`).
* **Seek/scrub** clamps to `0...duration` (`testSeekClampsToTheFileAndNeverGoesNegative`).
* **Category**: `.playback` + `.moviePlayback` on play, so the silent switch does not mute a file the
  reader asked to hear (`testPlayingAsksForThePlaybackAudioCategory`).

## 5. Not shipped (stated so the next card can pick it up)

* **PiP** is *configured* (`allowsPictureInPicturePlayback` + automatic start from inline) but not
  exercised by a test: verifying it needs a real transition to background with a playing video, which
  the harness cannot assert on the simulator. Treat it as "should work", not "proved".
* **Lock-screen / Now Playing controls** (`MPNowPlayingInfoCenter`, remote command centre) are absent.
  The card did not ask for them; audio stops when the app is backgrounded, so a lock-screen control
  surface would be misleading.
* **Playback above 32 MB** is refused rather than streamed. Streaming would mean giving AVFoundation a
  network loader (see §2 A and its costs) or implementing a range-aware local HTTP server; neither is
  in this card's scope.
* **Poster for audio** — the row shows a symbol, name and duration; no waveform artwork.
* **Audio duration** comes from the post metadata only; when the server omits it the row says `Audio`.
  It is not probed from the staged file (that would require staging on scroll).
* **No server thumbnails for media**: Measured — `GET /files/{id}/thumbnail` answers `400` for both the
  mp4 and the mp3 on 9.11.19, so `has_thumbnail` is false and the poster is decoded client-side.

## 6. Verification (all run in this worktree, on the live fixture)

```
# fixture
python3 scripts/t53_media_seed.py            # -> /tmp/t53seed.json
# 75,022 B t53-clip.mp4, 48,500 B t53-tone.mp3, post 11bbcko8838fi8iinbohxdur3a in #t53-media

# 1. the whole unit bundle (regression surface: 2,102 tests)
python3 scripts/qa-test.py --platform ios --sim "id=81A7F251-…" \
  --only-testing MattermostTests --label t53-fullunits5 -- -parallel-testing-enabled NO
# -> 2102 run, 10 skipped, 0 failed

# 2. T53's own units (49 tests: classification, decision, bucketing, duration, time,
#    staging cache against URLProtocol, controller against a fake engine, footprint)
# -> 49 run, 0 skipped, 0 failed
#    (controller class alone, after the audio-session change: 13 run, 0 failed)

# 3. the live transport measurement (2 tests, needs TEST_RUNNER_MM_AUTH_*)
# -> 2 run, 0 failed; T53MEASURE lines in §2

# 4. the live UI proof of the card's claim (2 tests, real post, real server)
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
TEST_RUNNER_MM_AUTH_LOGIN=… TEST_RUNNER_MM_AUTH_PASSWORD=… \
python3 scripts/qa-test.py --platform ios --sim "iPhone 16 Pro" \
  --only-testing MattermostUITests/T53MediaPlaybackUITests --label t53-live6
# -> 2 run, 0 failed; 98.835 s + 38.442 s (a warm simulator run of the same tests: 32.745 s + 26.221 s)
#    testAVideoPlaysPastOneSecondAndReleasesWhenDismissed:
#      waits for the poster (value stops saying "Loading poster." and never says "Poster unavailable"),
#      opens the sheet, asserts position 0 after 1.5 s (no autoplay), taps Play, then reads
#      attachmentPreview.video.time's accessibility value until it reports ≥ 1 s.
#    testTheAudioPlayerAdvancesInsideTheRowWithoutTakingOverTheScreen:
#      taps the row's play button, reads the row's position line until ≥ 1 s, asserts no
#      attachmentPreview sheet appeared, and asserts the button toggles back to "Play …".

# 5. token hygiene (the card's "no MMAUTHTOKEN in any URL or log line, t28 grep stays green")
bash scripts/t28-token-grep.sh
# -> PASS — no static path from the native transport layer to a logged credential
#    (124 log files scanned, no credential-shaped value)

# 6. the attachment UI suite that shares this surface (regression)
python3 scripts/qa-test.py --platform ios --sim "iPhone 16 Pro" \
  --only-testing MattermostUITests/T38AttachmentsUITests --label t53-t38-regression2
# -> 4 run, 0 failed
```

Logs: `build/logs/t53-fullunits5.log`, `t53-units-final2.log`, `t53-transport.log`, `t53-live6.log`,
`t53-t38-regression2.log`. Test attachments (screenshots) are inside the matching `.xcresult` bundles
in `~/Library/Developer/Xcode/DerivedData/mmios-t53/TestResults/`.

## 7. Tests added or changed

* new `MattermostTests/T53MediaPlaybackTests.swift` — 47 tests in six classes: classification (the
  refusal list did not grow a playback exception), the fetch decision, section bucketing, duration
  decoding, time labels, the staging cache (success/reuse, declared-too-large with **zero requests**,
  a server sending past the bound, cancellation, eviction, clear, 32 MB footprint), and the controller
  (prepare stages a *file* URL, no autoplay, play/pause/refresh, seek clamps, end-of-file, release on
  stop, one player, background stop, resign pause, interruption pause, refused size never stages,
  playback category).
* new `MattermostTests/T53MediaTransportTests.swift` — the re-runnable live measurement (§2); skips
  without credentials.
* new `MattermostUITests/T53MediaPlaybackUITests.swift` — the two live UI proofs (§6.4); skips without
  the fixture.
* `MattermostTests/T38AttachmentTests.swift` — **changed**: `clip.mp4`/`voice.m4a` were in the
  "downloadable but not previewed" list. T53 gives them a player, so they moved to
  `testVideoAndAudioLeftTheNoReaderListWhenThePlayerLanded`. This is the only product expectation T53
  changed, and it is the card's point.
* `MattermostUITests/T38AttachmentsUITests.swift` — **changed (test helper only)**: the shared local
  fixture server now carries hundreds of channels from other cards, so the lazy sidebar no longer
  materialises `#t38-files`; `openChannel` falls back to the quick switcher (the app's own "find a
  channel" path) before the sidebar row. The T38 suite passes again (4/4). Flagged for the orchestrator
  in case that file is a collision hotspot.
* `docs/THIRD_PARTY_NOTICES.md` — new §23 (T53 upstream read set); §15's "not ported" line now points
  to it.

## 8. Flags / risks

* `Mattermost/UI/Native/Files/MediaPlayback.swift` and `MediaViews.swift` are new files; no other card
  owns them.
* `MattermostUITests/T38AttachmentsUITests.swift` was touched for navigation only — potential hotspot
  if another card edits the same helper.
* The audio session is set globally on first play and not deactivated afterwards; the next card that
  needs a recording session (a future voice-message recorder) must set its own category, or this file's
  activation must move behind a shared audio-session owner.
* PiP and full-screen are configured but not asserted (see §5).

## 9. Publish

Committed on `t53/media-playback` (worktree `.worktrees/t_bfbbcbed`) from `origin/main` `b4ff722` and
fast-forwarded onto `main`; pushed. `git ls-remote origin refs/heads/main` was asserted equal to local
`HEAD` after the push:

```
9ecd9c3dbc231b7df260a72d3876bea34f034137  refs/heads/main
9ecd9c3dbc231b7df260a72d3876bea34f034137  HEAD
```

This publish section is a docs-only commit on top of `9ecd9c3`, so the branch tip after it is one
commit further; the card's closing comment names the final `ls-remote`-verified SHA.

Staged by `git add -A` in the worktree; the tree contained only this card's paths (13 modified, 7 new),
with no build artefacts — `build/logs/` and the derived data live outside the repository.
