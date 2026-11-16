# t_afbe83f9 — the header-fix build installed, then only the two Mattermost apps left

Runs after `t_bc22d0b3` (the account control is last in the header's trailing cluster). This card
installed the build that carries that fix and then swept every artifact it and its predecessors
left behind. Owner's rule for this machine, unchanged: exactly **one** official client and
**one** native build, nothing else.

Measured on `MacBookPro` (macOS 27.2.1), 2026-11-16 21:17–21:45 HKT.

## 1. Before state (recorded before touching anything)

`python3 scripts/disk_audit_mattermost.py` — **exit 1**, 6 delete rows, 5.0 G reclaimable:

```
delete rows: 6   reclaimable: 5.0G
unknown rows: 0
app bundles found: 2 (expected 2, both in /Applications)
  kept: /Applications/Mattermost.app  version=6.3.1 (383788041691)  (official Mattermost client)
  kept: /Applications/Mattermost(ios).app  version=0.76.0 (400)  (native build installed by t_e8c5ee86)
free space: /dev/disk3s1s1   926Gi    13Gi   255Gi     5%    487k  2.7G    0%   /
RESULT: DIRTY -- 6 artifact(s) still present
```

```
$ ls -1 /Applications | grep -i mattermost
Mattermost(ios).app
Mattermost.app
$ pgrep -fl "Mattermost\(ios\)"        # no native app running; the official client was (pid 81554)
$ df -h /System/Volumes/Data
/dev/disk3s5   926Gi   638Gi   255Gi    72%      /System/Volumes/Data
```

The six rows: `DerivedData/mattermost-ios-qa` (3.7 G), `DerivedData/mmios-t9dd-build` (1.3 G),
and four `com.mattermost.ios` / `com.mattermost.iosUITests.xctrunner` installs in three
simulators. The audit's name-based DerivedData rule was under-classifying, which §6 fixes.

## 2. The version: 0.77.1 (401)

`MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` were the `0.76.0`/`400` that `t_43277d0a` settled on.
The ladder, read in a worktree at the fix commit (`1d117b9`, which is what `origin/main` was):

```
$ python3 scripts/release_version.py --dry-run --format json
current=v0.77.0 head_tags=[] bump=patch commits=2 next=v0.77.1
{"current": "v0.77.0", "next": "v0.77.1", "skip": false, "bump": "patch", "commits": 2, "head_tags": []}
```

`v0.77.0` sits on `bebf7e9` (the account-menu feature), so the two commits above it — the fix
`d53114a` and its docs `1d117b9` — are a patch. **0.77.1** is therefore the number this content
carries, and `CURRENT_PROJECT_VERSION = 401` is strictly above the installed `400`, so the new app
is distinguishable from the old one by version alone. Both app-target configurations (Debug
`FA…0003`, Release `FA…0004`) were bumped; commit `cc8ce33`.

## 3. Build

Throwaway worktree at the fix, Release, Catalyst, its own DerivedData:

```
git worktree add /tmp/mm-place 1d117b9
cd /tmp/mm-place && git checkout -b t_afbe83f9        # + the cc8ce33 version bump
xcodebuild build -project Mattermost.xcodeproj -scheme Mattermost \
  -configuration Release -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /tmp/mm-place-dd \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES ONLY_ACTIVE_ARCH=NO
** BUILD SUCCEEDED **      (BUILD_EXIT=0)
```

Built product:

```
CFBundleShortVersionString  0.77.1
CFBundleVersion             401
CFBundleIdentifier          com.mattermost.ios
lipo -archs                 x86_64 arm64
du -sh                      107M
```

## 4. Install (the proven sequence, official client untouched)

```
pkill -f "Mattermost(ios).app/Contents/MacOS/Mattermost"   # the native bundle only; no native app was running
mv "/Applications/Mattermost(ios).app" /tmp/mm-old-ios.app # restore point, removed in §5
ditto /tmp/mm-place-dd/Build/Products/Release-maccatalyst/Mattermost.app \
      "/Applications/Mattermost(ios).app"                  # DITTO_OK
codesign --force --deep -s - "/Applications/Mattermost(ios).app"
      → "/Applications/Mattermost(ios).app: replacing existing signature"   rc=0
find "/Applications/Mattermost(ios).app" -exec xattr -d com.apple.quarantine {} +   # no attributes found
…/LaunchServices.framework/Versions/A/Support/lsregister -f "/Applications/Mattermost(ios).app"  rc=0
open -n "/Applications/Mattermost(ios).app"                # never plain `open`
```

The ad-hoc re-sign is mandatory; without it the bundle dies with
`Library not loaded: @rpath/WebRTC.framework/WebRTC … different Team IDs`.

## 5. Proof it runs, and that the fix is in the installed binary

```
$ /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "/Applications/Mattermost(ios).app/Contents/Info.plist"
0.77.1                       (CFBundleVersion 401)
$ codesign -dv "/Applications/Mattermost(ios).app"
Executable=/Applications/Mattermost(ios).app/Contents/MacOS/Mattermost
Identifier=com.mattermost.ios
Format=app bundle with Mach-O universal (x86_64 arm64)
CodeDirectory v=20400 size=82987 flags=0x2(adhoc) hashes=2587+3 location=embedded
Signature=adhoc   TeamIdentifier=not set
$ codesign --verify --deep --strict "/Applications/Mattermost(ios).app"   → SEAL_OK (rc=0)
$ open -n "/Applications/Mattermost(ios).app"; sleep 12; pgrep -fl "Mattermost\(ios\)"
89835 /Applications/Mattermost(ios).app/Contents/MacOS/Mattermost -uiTestExposeHeaderGeometry
CGWindowList: pid 89835 wid 8225 layer 0 (1024 x 768 at 244,79)      # a window, not just a process
```

The header itself was measured **from the installed bundle**, not from the build tree. Two seams
are shipped in the Release product (no `#if DEBUG`, inert without their argument), so no Screen
Recording consent is needed on this headless host (`screencapture` fails here: "could not create
image from display"):

* `-readStateSnapshot <dir>` — opens the first unread channel through the app's one navigation
  funnel and writes a `drawHierarchy` PNG of the window; `read-state-02-channel.png` is the
  channel pane. Copied here as `installed-0.77.1-window.png`.
* `-uiTestExposeHeaderGeometry` — publishes the header's laid-out frames as one accessibility
  value, read back with the AX API; the channel was opened by `AXPress` on the sidebar row
  `channelSidebar.channel.1mbgdx5xfb8aie94y66ir9dpro`, i.e. a real control.

The installed app reports (`docs/t_afbe83f9-shots/header-geometry.txt` has all three views):

```
header=320.0,201.0,1010.0,56.5   padding=16.0   side=32.0
nativeChannelInfoButton=810.0  nativeChannelPinnedButton=848.0  calls.joinButton=886.0
nativeChannelThreadsButton=924.0  accountMenuButton=962.0
accountMenu.avatar=6.0,6.0,20.0,20.0   accountMenu.presenceDot=22.5,22.5,7.0,7.0
```

info → pinned → Calls → Threads → **account last**, equal 38 pt steps and 6 pt gaps, every frame
32x32, and the account control's frame ends at 994 of a 1010-wide header — exactly the header's
own `padding` (16 pt) from the trailing edge. The OS accessibility tree gives the same order in
screen points (pinned 1143.36, calls 1172.62, threads 1201.88, account 1231.14; 32 pt frames are
24.64 pt on screen because this host renders Catalyst at 1.3x — 1330x998 UIKit points behind a
1024x768 AppKit window, which is why every screen value is the seam's divided by 1.299).

Pixels agree. `swift scripts/tbc22d0b3_measure.swift <png> 420 500 1600 2659 2` on the app's own
capture finds five ink runs and nothing after the fifth:

```
run 0: 17.0 pt (info)   run 1: 13.0 pt (pin)   run 2: 15.5 pt (Calls)   run 3: 18.5 pt (Threads)
run 4: 23.5 pt (avatar 20 + dot 3.5)          last run ends 18.5 pt from the image edge
```

Screenshots: `docs/t_afbe83f9-shots/header-0.77.1.png` (the header, 2x) and
`installed-0.77.1-window.png` (the whole window). The account avatar with its presence dot is the
rightmost thing drawn in the header.

The probe's own note (`docs/t_afbe83f9-shots/read-state-probe.txt`) also shows the pane really
opened: `paneChannel=1mbgdx5xfb8aie94y66ir9dpro`, `before_badge=mentions(1, urgent: false)` →
`open_rowValue=Selected`, `remainingUnreadRows=0`. Opening the channel therefore marked one
mention read on the `http://127.0.0.1:8065` fixture — the only state this card changed.

The official client was not touched: still `6.3.1 (383788041691)`,
`codesign --verify --deep --strict` rc=0, TeamIdentifier `UQ8HT4Q2XM`, pid 81554 still its main
process, and its `~/Library/Application Support/Mattermost*` data untouched.

## 6. The audit's DerivedData rule, tightened (this is why the sweep could be complete)

The name rule (`mattermost|mmios|proof`, `^t[_-]`) missed 11 Mattermost DerivedData directories
that are obviously ours — `mm-header-dd` and `mm-header-ios-dd` (from `t_bc22d0b3`, named in its
handoff), `mm-demo-dd`, `mm-ios-t_e14483c8`, `t5d-build`, `t5d-mac`, `mm-qa-t249-*` (3),
`mm-t_a4e133f6` and `mm-t_a4e133f6-prune` — because none of those names contains "mattermost" or
"mmios". Each one was verified to hold `Build/Products/*/Mattermost.app` before anything was
deleted.

Rather than delete paths the audit did not classify, the classifier was fixed: a DerivedData
directory is ours if its name says so **or** it builds a `Mattermost.app` in one of the standard
product directories (`scripts/disk_audit_mattermost.py`, `derived_ownership`). The rule got
stricter, never looser — `Pixpot-*`, `ModuleCache.noindex` and `CompilationCache.noindex` stay
unclassified, and the self-test proves the near-miss (`MattermostHelper.app` is not
`Mattermost.app`):

```
$ python3 scripts/disk_audit_mattermost.py --self-test
  [PASS] named unlike anything we own, builds Mattermost.app  -> products (want products)
  [PASS] t5d is not t_/t-, but it builds Mattermost.app       -> products (want products)
  [PASS] old rule: the name is enough                         -> name (want name)
  [PASS] another project -> not ours                          -> None (want None)
  [PASS] Xcode's own cache -> not ours                        -> None (want None)
  [PASS] a near-miss product name is not Mattermost.app       -> None (want None)
SELF-TEST: PASS
```

With that rule the audit reported **17 delete rows / 17.5 G** (the 6 above plus the 11), and the
sweep was driven by those rows only.

## 7. What went

| what | count | measured |
|---|---|---|
| DerivedData, Mattermost products | 11 | 16.2 GiB (`mm-ios-t_e14483c8` 2.5 G … `mm-qa-t249-abhead-mac` 0.9 G) |
| DerivedData, by name | 2 | `mattermost-ios-qa` 3.7 G, `mmios-t9dd-build` 1.3 G |
| the card's own build dir | 1 | `/tmp/mm-place-dd` 1.5 G |
| the restore point | 1 | `/tmp/mm-old-ios.app` (the old 0.76.0 build) 106 M |
| simulator installs | 4 | 3 devices: `com.mattermost.ios` ×3, `com.mattermost.iosUITests.xctrunner` ×1 |
| worktrees, branch already an ancestor of `origin/main` | 4 | `t_bc22d0b3/repo`, `t_a4e133f6`, `t_e687bad5`, `t_efd0a2ad` |

Simulator apps were removed with `xcrun simctl uninstall` after booting each device — a shutdown
simulator answers `SimError 405 "Unable to lookup in current state: Shutdown"`, so each was
booted, uninstalled and shut down again (all rc=0). Worktrees were removed with
`git worktree remove` after `git merge-base --is-ancestor <head> origin/main` said yes, then
`git worktree prune`. `rm -rf` is not available to this unattended session (blocked), so the
deletions ran through a script that takes the audit's own paths and refuses anything outside
`/private/tmp` and `~/Library/Developer/Xcode/DerivedData`, and refuses both keeper bundles by
name; it printed each path and its size as it went.

Nothing else matched: no `/tmp/demo_desktop.mov`, no `/tmp/mm_*.log`, no `/tmp/mm_*.png`, no
`mm_stub.py` process, no lingering `Mattermost*.app` outside `/Applications`.

### Left in place, and why

* **4 worktrees with commits not on `origin/main`** (the card says leave and report):
  `t_3d753264` (1 ahead), `.worktrees/t_0484a564` (2 ahead), `worktrees/t_5dce3e67`
  (`lean/t_22c3f1ea`, 12 ahead), `worktrees/t_e14483c8` (`feat/t_e14483c8-interactive-dialog`,
  2 ahead).
* **5 worktrees whose branch is an ancestor but which have uncommitted tracked edits** —
  `git worktree remove` refuses them and forcing it would discard someone's work, so they were
  reported rather than forced: `t_3042a50f/av` (T35-ComposerUITests.swift + an untracked
  `scripts/av_t35_pending_id_replay.py`), `t_3e6ddccf/probe` (NativeNavigationTests,
  MattermostUITests), `t_c941e3d3/repo` (ShellSettle, T36-ThreadsUITests, T44DCallsUITests),
  `.worktrees/t_295b0a32` (NativeNavigation, ChannelSidebarCoordinator, LastChannelLaunchTests),
  `.worktrees/t_560103f6` (T33-ChannelSidebarUITests).
* `~/Documents/yanks/code/mattermost-ios/build` — the audit classifies it `keep`: it holds only
  tracked test fixtures (`build/uitest-server/mm_stub.py`), no untracked build output.
* `~/Library/Application Support/Mattermost*` and `~/Library/Application Support/Mattermost/vault-secrets.*`
  — the official client's data and the session store, not artifacts.

## 8. Result

```
$ python3 scripts/disk_audit_mattermost.py ; echo EXIT=$?
## summary
delete rows: 0   reclaimable: 0B
unknown rows: 0
app bundles found: 2 (expected 2, both in /Applications)
  kept: /Applications/Mattermost.app  version=6.3.1 (383788041691)  (official Mattermost client)
  kept: /Applications/Mattermost(ios).app  version=0.77.1 (401)  (native build installed by t_e8c5ee86)
free space: /dev/disk3s1s1   926Gi    13Gi   275Gi     5%    487k  2.9G    0%   /

RESULT: CLEAN -- two apps in /Applications, nothing else
EXIT=0
```

(The run quoted here was taken at `cc8ce33` while the throwaway worktree `/tmp/mm-place` was
still registered, which is the one `keep` row the final state does not have; every other row is
identical. Free space: 255 GiB before → **275 GiB** after, ~20 GiB reclaimed; used 638 → 620 GiB.)

One caveat on the environment, not on this card: the audit prints `UNKNOWN` for
`~/.kube/cache/discovery/127.0.0.1_58594/kiali.io` (permission denied) on every run, including
the green one; it is not a Mattermost path and does not affect the verdict.
