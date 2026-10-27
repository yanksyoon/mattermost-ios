# T45 — profile pictures in the native shell

Card: *Profile pictures never load in the native shell* (`t_7c7112ce`).
Base: `origin/main` `48888ef`. Branch: detached worktree `.worktrees/t_7c7112ce`.

## What was actually wrong

The report ("avatars render blank/initials everywhere") has two layers, and only the second one was
visible from the code:

1. **There was no image path at all.** `PostAvatarView` drew a coloured `Circle` and the author's
   initials. No request, no cache, no place a picture could come from — so on a server where every
   account has uploaded one, the app was indistinguishable from a server where nobody had.
2. **A view that reduces to `EmptyView` has no lifetime, so its `.task` never runs.** The first cut
   of `AvatarPicture` drew nothing until the picture arrived, which meant the `.task` that fetches
   the picture never fired. That is the same chicken-and-egg as the original bug, one level down:
   found by a live run — the post list rendered, the initials stayed, and the app's disk cache was
   empty while the server was answering `GET /users/{id}/image` with 943 bytes. The fix is a
   transparent, sized placeholder (`Color.clear`) so the view exists before there is anything to
   draw.

## What landed

* `Mattermost/UI/Native/Profile/AvatarImageStore.swift` — one store per server (created by
  `ChannelPaneCoordinator.avatarStore(for:)`), keyed by user id:
  * the request goes through `ChannelServing.userImage` → `APIClient.userImage` →
    `GET /api/v4/users/{id}/image` **with the vault's bearer token**. `AsyncImage` cannot do this, and
    the webview's `MMAUTHTOKEN` cookie is invisible to the native transport — that is why an
    `AsyncImage` on the plain URL draws nothing.
  * memory cache, 200 decoded faces, LRU.
  * `AvatarDiskCache` actor: `Caches/profile-images/<server id>/<user id>.img`, 24 MB per server,
    trimmed oldest-first. Written with the store's clock so staleness and the TTL (7 days) share one
    clock instead of two.
  * **the two kinds of absence are kept apart** — `404`/`403` is "this account has no picture" and is
    remembered for the session (a 200-row list must not fire 200 doomed requests); offline/timeout/5xx
    is "not now" and is retried after `retryWindow` (30 s). A stale picture on disk is drawn when a
    refresh fails, and a picture that later 404s is deleted from disk.
  * `AvatarPicture` — the overlay view every surface uses; draws nothing at all without a store, so
    previews, tests and a web-resolved surface keep exactly the initials.
* Wiring: the channel pane (`ChannelView`), the thread pane (`ThreadView`), the global threads pane
  (`GlobalThreadsView`), member rows (`ChannelMembersView`), the add-members list (`AddMembersView`)
  and the call tiles (`CallsSurfaceView`) — all reading the one per-server store through the
  environment. Reaction lists and the profile popover inherit it from the channel pane.
* `ChannelServing.userImage` defaults to `notFound`, so a fake service without avatars still
  compiles and honestly degrades to initials.
* Tests: `MattermostTests/AvatarImageStoreTests.swift` (13 tests: one request per face, shared
  in-flight request, 404 remembered, transient retried after the window, `clearFailures`, bounded
  memory, disk survives a relaunch, stale-and-failed-refresh still draws, permanent miss drops the
  bytes, non-image body is a failed fetch, disk trimmed by bytes, and the request's path + bearer
  token + 404 mapping at the transport seam).

## Evidence

Unit suite, whole `MattermostTests` target, isolated simulator (`iPhone 16 Pro Max`,
`BAFE0119-FD76-4DB9-97F3-600A481F0E40`, iOS 18.x) and its own derived data:

    python3 scripts/qa-test.py --platform ios --sim id=BAFE0119-... --only-testing MattermostTests \
      --derived-data ~/Library/Developer/Xcode/DerivedData/t-7c7112ce --label t45-full-units2
    tests: 1647 run, 6 skipped, 0 failed — ** TEST SUCCEEDED **

(An earlier whole-target run, `t45-full-units1`, was 1647 run / 2 failed, both
`SocketClientTests.testPongClearsTheMissedPongCount` — a 1 s wall-clock ping test that passes alone
(`t45-pong-alone`: 1 run, 0 failed) and passed in the re-run. The host was running another card's
Mac Catalyst build and a 32-iteration `SocketClientTests` loop at the time. Reported, not "fixed"
here: this card does not touch the socket.)

Live, against the fixture server at `http://127.0.0.1:8065` (Mattermost 9.11 in Docker, seeded by
`scripts/t34_post_seed.py`; `perfprobe` has an uploaded picture: 943 bytes, blue field, white "P"):

    TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
    TEST_RUNNER_MM_AUTH_PASSWORD=<fixture> python3 scripts/qa-test.py --platform ios \
      --sim id=BAFE0119-... --only-testing MattermostUITests/T45AvatarUITests --label t45-live-avatars8
    tests: 1 run, 0 skipped, 0 failed — PASS (41 s)

Three artefacts, all from that run:

* `t45-shots/t45-avatars-before-initials.png` — before the placeholder fix: the row's avatar is the
  green fallback with "PP", i.e. the picture never arrived.
* `t45-shots/t45-avatars-after-picture.png` — after: the same row draws the server's picture (blue
  field, white "P") clipped to a circle.
* the app's own **disk cache**, written by that run:

      Library/Caches/profile-images/0C6F44AB-B90A-46A7-9E61-CD276AF97483/jruqqzxtobg7tn4wehwmwjjo5c.img
      943 bytes, sha256 d61a28b409b18f50969c719b6567cf145bcebdc5af91e70ae1c0019297baeea7

  `curl`ing `GET /api/v4/users/<perfprobe>/image` from the host with a session token returns
  `t45-shots/perfprobe-server-avatar.png`, the **same** size and the **same** sha256. So the bytes in
  the app's cache are the server's own bytes: the request went out authenticated, came back, decoded,
  and was drawn — not a fixture the test painted.

The live test picks its channel from the server (fewest-posted open channel whose **newest regular**
post's author has a picture) instead of hardcoding one, because only a post group's *first* row draws
an avatar and a system post ("x joined the channel") draws an icon. It skips — never fails — when
`TEST_RUNNER_MM_AUTH_*` or the server is absent, like every live test in this tree.

## Rebase onto 0.1.5 build 6 (origin/main `20b7cc8`)

`origin/main` moved while this card ran: `48f70b1` / `79ddaf6` / `20b7cc8` brought the earlier,
simpler avatar work onto main (`AvatarImageStore` with a memory-only cache, `PostAvatarView` drawing
`@State picture` from its own `.task`, wiring in `ChannelView` only). So this commit is a
**supersession**, not an addition — the conflicts were resolved as:

* `AvatarImageStore.swift`, `AvatarImageStoreTests.swift` — ours (disk cache, the 404/transient split,
  the environment-injected `AvatarPicture`, 13 tests). The four behaviours main's suite pinned
  (fetched once, a missing picture asked once, `clearFailures`, bounded) are all covered by the new
  file with the same assertions.
* `ChannelService.swift`, `ChannelPaneCoordinator.swift` — ours; main's copy was the same feature
  without the disk cache.
* `ChannelView.swift` — ours for the avatar wiring, and main's unrelated bottom-spinner removal was
  kept (my base predates it; taking my file alone would have reverted it).
* `ChannelAPI.swift`, `PostRowView.swift` — the merge left **both** copies of `userImage` and both
  fetch paths in `PostAvatarView`; the duplicates were removed so there is one request per face and
  one picture-drawing path (`AvatarPicture`).
* `Mattermost.xcodeproj/project.pbxproj` is untouched by this commit: the 0.1.5 / build 6 bump is
  main's, and the new files are picked up by `PBXFileSystemSynchronizedRootGroup`.

Gates re-run at the rebased commit `4458361`:

    t45-rebased-units: 1649 run, 8 skipped, 0 failed
    t45-rebased-live:  1 run, 0 skipped, 0 failed
    app cache after the live run:
      .../Library/Caches/profile-images/<server>/jruqqzxtobg7tn4wehwmwjjo5c.img
      sha256 d61a28b4… — the server's own bytes, as above.

## Not done here

* The unread/threads work in the sibling card (`t_4dfdf856`) is untouched.
* Group-message/DM "channel icons" in the sidebar are not avatars in this client's sidebar at all;
  that is a separate parity row, not this regression.
* No APNs/push-proxy dependency, so nothing was faked there.
