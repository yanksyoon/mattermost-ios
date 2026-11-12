# t_43277d0a — the newest build installed, then every other Mattermost artifact removed

Owner's rule for this machine: exactly **one** official client and **one** native build, nothing
else. This card ran after `t_93eca948` (unread counts) landed, installed the newest build, proved it
runs, and only then swept. Measured on `MacBook-Pro-6.local`, 2026-11-12 22:16–22:56 HKT.

## 1. Before state (recorded before touching anything)

`python3 scripts/disk_audit_mattermost.py` — exit 1:

```
## summary
delete rows: 71   reclaimable: 72.6G
unknown rows: 0
app bundles found: 6 (expected 2, both in /Applications)
  kept: /Applications/Mattermost.app  version=6.3.1 (383788041691)  (official Mattermost client)
  kept: /Applications/Mattermost(ios).app  version=0.72.5 (195)  (native build installed by t_e8c5ee86)
free space: /dev/disk3s1s1   926Gi    12Gi   171Gi     7%    455k  1.8G    0%   /
RESULT: DIRTY -- 71 artifact(s) still present; 6 app bundle(s) found, expected exactly 2
```

```
$ ls -1 /Applications | grep -i mattermost
Mattermost(ios).app
Mattermost.app
$ pgrep -fl Mattermost | head -2
10575 /Applications/Mattermost.app/Contents/MacOS/Mattermost
76498 /Applications/Mattermost(ios).app/Contents/MacOS/Mattermost
$ df -h /System/Volumes/Data
/dev/disk3s5   926Gi   721Gi   171Gi    81%   /System/Volumes/Data
```

Also measured: `~/Library/Developer/Xcode/DerivedData` **83G**, **65** registered git worktrees,
**16** simulators still carrying `com.mattermost.ios`.

## 2. The version: 0.76.0 (400)

`MARKETING_VERSION` was the hard-coded `0.1.7` and `CURRENT_PROJECT_VERSION` `8` in both app-target
configurations (`FA…0003` Debug, `FA…0004` Release), so every local build reported the same version.
CI stamps the tag over it at package time (`docs/releasing.md` § *Stage 3*); a local build does not.

The ladder is the source of truth, and on this commit it says:

```
$ python3 scripts/release_version.py --dry-run --format json
current=v0.75.0 head_tags=[] bump=minor commits=2 next=v0.76.0
```

`commits=2` = the un-released `feat` at `1c28200` plus this card's commit. **0.76.0** is therefore
the number this content carries. `CURRENT_PROJECT_VERSION = 400` is above both bundle versions seen
on disk (0.72.5 carried 195; the card's 0.71.1 carried 372), so the installed app is distinguishable
from every earlier copy.

The first push (`a12c107`) guessed `0.76.1` on the assumption that `1c28200` would publish as
`v0.76.0` first. It did not — release run **202** on `1c28200` went red on the *catalyst* leg
(`T46WebFallbackTests.testTwentyFallbacksLeaveNoWebViewAlive` failed on assertions; the run's own
annotation calls it a product failure, not runner noise) — so no tag was cut and `v0.75.0` is still
the top of the ladder. Commit `5c44456` settles on `0.76.0` and the installed build was **rebuilt
from it**, not stamped over the earlier one.

## 3. Build

Throwaway worktree at the pushed commit, Release, Catalyst, own DerivedData:

```
git worktree add /tmp/mm-final-wt 5c444564dd426ae1f3093d01a0f51e0bf6986ff2
cd /tmp/mm-final-wt
xcodebuild build -project Mattermost.xcodeproj -scheme Mattermost \
  -configuration Release -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /tmp/mm-final-dd \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES ONLY_ACTIVE_ARCH=NO
** BUILD SUCCEEDED **      (BUILD_EXIT=0)
```

```
CFBundleShortVersionString  0.76.0
CFBundleVersion             400
CFBundleIdentifier          com.mattermost.ios
lipo -archs                 x86_64 arm64
LSMinimumSystemVersion      14.0
du -sh                      106M
```

## 4. Install (proven sequence, official client untouched)

```
kill 70075                                  # the old native app only; official pid 10575 kept running
mv "/Applications/Mattermost(ios).app" /tmp/mm-old-ios.app     # restore point, deleted after step 5
ditto /tmp/mm-final-dd/Build/Products/Release-maccatalyst/Mattermost.app \
      "/Applications/Mattermost(ios).app"                      # DITTO_OK
codesign --force --deep -s - "/Applications/Mattermost(ios).app"
      → "/Applications/Mattermost(ios).app: replacing existing signature"
find "/Applications/Mattermost(ios).app" -exec xattr -d com.apple.quarantine {} +   # no -r on BSD xattr
/…/LaunchServices.framework/Versions/A/Support/lsregister -f "/Applications/Mattermost(ios).app"
open -n "/Applications/Mattermost(ios).app"                     # never plain `open`
```

The ad-hoc re-sign is mandatory: without it the bundle fails with
`Library not loaded: @rpath/WebRTC.framework/WebRTC … different Team IDs`.

## 5. Proof it runs

```
$ /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "/Applications/Mattermost(ios).app/Contents/Info.plist"
0.76.0                       (CFBundleVersion 400)
$ codesign -dv "/Applications/Mattermost(ios).app"
Identifier=com.mattermost.ios
Format=app bundle with Mach-O universal (x86_64 arm64)
CodeDirectory v=20400 … flags=0x2(adhoc)
Signature=adhoc   TeamIdentifier=not set
$ codesign --verify --deep --strict "/Applications/Mattermost(ios).app"   → SEAL_OK
$ open -n "/Applications/Mattermost(ios).app"; sleep 8; pgrep -fl "Mattermost(ios)"
78749 /Applications/Mattermost(ios).app/Contents/MacOS/Mattermost
```

A window, not just a process — `scripts/t295_launch_snapshot.sh` (the `-shellSnapshot` seam) wrote
both frames and the shell diagnostics from the same install:

```
location=NativeLocation(… channelName: Optional("github-actions-self-hosted-runner"), pane: channel)
sidebar=team=sqmc4sz45prypmkfctwynm5yjr phase=loaded stage=loaded 11 groups, … channels=348 err=-
auth=Canonical:signedIn(username: "charlie4284", …):token=true
```

* `docs/t_43277d0a-shots/installed-0.76.0-late.png` — the settled window: sidebar categories with
  the unread numbers this content carries (PFE **16**, NINJA **13**, FAVORITES **18**, SPRINTS **533**,
  Threads **1**), i.e. `t_93eca948` is in the installed binary.
* `docs/t_43277d0a-shots/installed-0.76.0-window.png` — the frame 5 s after launch.
* `docs/t_43277d0a-shots/launch-diagnostics.txt` / `-late.txt` — the diagnostics above, verbatim.

The official client was not touched: version still `6.3.1 (383788041691)`,
`codesign --verify --deep --strict` → `OFFICIAL_SEAL_OK`, pid 10575 still its main process.

## 6. What went

Every deletion was driven by the audit's own `delete` rows (`scripts/disk_audit_mattermost.py` is the
verdict list; a script re-ran it and refused anything not in it, including both keepers).

| what | count | measured |
|---|---|---|
| Mattermost-owned DerivedData trees (`mattermost-ios-*`, `Mattermost-*`) | 34 | **73.8G** |
| `Mattermost*.app` bundles outside `/Applications` (2 profile caches, `.Trash`, 1 UITest runner) | 4 | **312.4M** |
| fixture leftovers (`/tmp/mm_tree.json`, `T34-fixed.swift.bak`) | 2 | **1.7M** |
| `/tmp` build dirs (`mm-final-dd`, `mm-old-ios.app`) | 2 | **1.5G** |
| `/tmp` run files (`mm_final_snap.*`, `mm_final_build.log`, `mm-crop.png`) | 6 | **~7M** |
| registered git worktrees, branch merged into `origin/main` | 49 | **~8.9G** |
| stale worktree registrations whose directory was gone (`git worktree prune`) | 6 | — |
| simulator installs of `com.mattermost.ios` / `…UITests.xctrunner` | 27 across 16 devices | — |

**DerivedData actually reclaimed: 73.8G** (the previous cleanup on this box freed 93G, so this one is
smaller, as the card expected).

Two mechanics worth recording:

* `xcrun simctl uninstall` answers `rc=149 Unable to lookup in current state: Shutdown` for a shutdown
  device, so each of the 16 devices was booted, both bundles uninstalled (`rc=0` ×27), and the device
  shut down again. No device was left booted.
* `git worktree remove` was tried **without** `--force` first. Six worktrees had untracked files only
  and were then removed with `--force` (their commits are all in `origin/main`); five were refused
  with tracked modifications and are **left in place** — `git worktree remove --force` would have
  destroyed 148–604 lines of uncommitted work that exists nowhere else:

  | worktree | uncommitted |
  |---|---|
  | `…/workspaces/t_3042a50f/av` | `MattermostUITests/T35-ComposerUITests.swift` +604 |
  | `…/workspaces/t_3e6ddccf/probe` | `NativeNavigationTests.swift` +221, `MattermostUITests.swift` +135 |
  | `…/workspaces/t_c941e3d3/repo` | 3 files, +148/−13 |
  | `.worktrees/t_295b0a32` | 3 files, +191/−59 |
  | `.worktrees/t_560103f6` | `T33-ChannelSidebarUITests.swift` +157 |

Four worktrees still hold commits that are **not** on `origin/main` and were left alone and reported
as the card requires: `t_3d753264/repo` (`e75b3d50`), `.worktrees/t_0484a564` (`c9842ebc`),
`~/worktrees/t_5dce3e67` (`988ae637`), `~/worktrees/t_e14483c8` (`f133657d`).

`pgrep -f mm_stub.py` was empty before the sweep, so no stub server had to be killed.

## 7. After state — the gate is green

```
$ python3 scripts/disk_audit_mattermost.py ; echo EXIT=$?
## summary
delete rows: 0   reclaimable: 0B
unknown rows: 0
app bundles found: 2 (expected 2, both in /Applications)
  kept: /Applications/Mattermost.app  version=6.3.1 (383788041691)  (official Mattermost client)
  kept: /Applications/Mattermost(ios).app  version=0.76.0 (400)  (native build installed by t_e8c5ee86)
free space: /dev/disk3s1s1   926Gi    12Gi   249Gi     5%    455k  2.6G    0%   /
RESULT: CLEAN -- two apps in /Applications, nothing else
EXIT=0
```

(The `native build installed by t_e8c5ee86` label is the audit script's own static text for that
path; the bundle there is the one this card installed.)

```
$ ls -1 /Applications | grep -i mattermost      → Mattermost(ios).app, Mattermost.app
$ df -h /System/Volumes/Data
/dev/disk3s5   926Gi   644Gi   249Gi    73%   /System/Volumes/Data
```

**Net: 171Gi → 249Gi available (+78 GiB)**, against 74.1G of audit rows + 1.5G of `/tmp` +
~8.9G of worktrees; the difference is what the two Release builds and the simulator boots put back
in the same window.

`git worktree list` is now 10 entries: the shared checkout, 4 with unmerged commits, 5 with
uncommitted changes (above). Nothing was rewritten; no history was touched.

## 8. Repo state

```
$ git rev-list --count origin/main..HEAD        → 0
$ git log -1 --format='%H %s' origin/main       → 5c444564dd426ae1f3093d01a0f51e0bf6986ff2
                                                  build(release): settle on 0.76.0, … (t_43277d0a)
```

`5c44456` carries the `MARKETING_VERSION = 0.76.0` / `CURRENT_PROJECT_VERSION = 400` bump for both
app-target configurations; the installed app was built from it. The commit after it adds only this
note and the four evidence files under `docs/t_43277d0a-shots/`, so the installed binary is the tip
build in everything but the docs.

Open, not this card's to fix: release run **202** (`1c28200`) and any later push stay red on
`T46WebFallbackTests.testTwentyFallbacksLeaveNoWebViewAlive` in the catalyst leg, which by this
repo's own rule means **no release is published** for that push — the version above is the ladder's
number for the content, predicated on that test going green.
