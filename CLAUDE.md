# MuonPlayer — build / test / deploy notes

iOS **and macOS** music player. SwiftUI + AVAudioEngine, gapless playback via a
single player node, FFmpeg for decode/metadata, SQLite for the library. Bundle id
`me.pecheny.muonplayer`.

## Targets & code layout

Two app targets share everything but the UI:

| Path | Compiled into |
|---|---|
| `MuonPlayer/{Audio,Library,Models,Playback,Scanner,Scrobble,Shared,Resources}` | both |
| `MuonPlayer/{Views,App,SelfTests}` | iOS only |
| `MuonPlayerMac/` | macOS only |

Anything reused by both UIs (`ArtworkView`, `WaveformSeekBar`, `DominantColor`,
`TagEditModel`, `PlatformImage`) lives in `MuonPlayer/Shared/`. Put new shared
code there, not in `Views/`.

The library indexes a set of **root folders** (`LibraryRoot`). iOS has exactly
one (Documents); macOS has however many the user adds, persisted as
security-scoped bookmarks (`MuonPlayerMac/LibraryFolders.swift`). Folder-scoped
DB queries match on a root's absolute canonical path prefix — which is why iOS
still rewrites stored paths on launch (`normalizeContainerPaths`, the data
container UUID changes on every install).

## Project generation (XcodeGen)

The `.xcodeproj` is **generated and gitignored** — never edit it by hand.

```bash
xcodegen generate      # after adding/removing/renaming any source file
```

Sources under `MuonPlayer/` are auto-included, so adding a new `.swift` file just
needs a regenerate — no `project.yml` edit. `project.yml` is the source of truth
for targets/settings.

## Prerequisites (gitignored, must exist before first build)

1. **FFmpeg xcframeworks** — `Vendor/FFmpeg/*.xcframework` (+ `include/module.modulemap`,
   imported in Swift as `CFFmpeg`). Slices: `ios-arm64`, `ios-arm64-simulator`,
   `macos-arm64`. `Vendor/` is committed, so usually already present. Rebuild with
   `scripts/build-ffmpeg.sh` (a few minutes) if missing — it reuses any slice
   already built under `.ffmpeg-build/`, so delete a slice dir to force it.
2. **`MuonPlayer/Secrets.swift`** — `scripts/gen-secrets.sh` generates it from
   `.env` (Last.fm key/secret + username/password). Both `.env` and `Secrets.swift`
   are gitignored; a fresh checkout won't compile until this runs. Without valid
   creds, scrobbling still queues locally but won't submit.

## Build & test (simulator)

```bash
SIM='platform=iOS Simulator,name=iPhone 17'
xcodebuild -project MuonPlayer.xcodeproj -scheme MuonPlayer -sdk iphonesimulator \
  -destination "$SIM" -configuration Debug build

xcodebuild -project MuonPlayer.xcodeproj -scheme MuonPlayer \
  -destination "$SIM" test
```

Tests use **Swift Testing** (`@Test`/`#expect`), not XCTest. The XCTest summary
line prints `Executed 0 tests` — that's expected; the real results are the
`✔ Test …` / `✔ Test run with N tests in M suites passed` lines (currently
22 tests in 4 suites).

## Build & run the Mac app

```bash
xcodebuild -project MuonPlayer.xcodeproj -scheme MuonPlayerMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64' build

open ~/Library/Developer/Xcode/DerivedData/MuonPlayer-*/Build/Products/Debug/MuonPlayerMac.app
```

The Mac app is **sandboxed**: it can only read folders the user picked in the
open panel (Library → Add Folder to Library…, ⌘O). Its container is
`~/Library/Containers/me.pecheny.muonplayer/Data`.

> ⚠️ That container's `Music`, `Movies`, `Pictures` and `Downloads` are symlinks
> to the **real** home folders. Never write test fixtures there. Use
> `Data/Library/Application Support/…`, which is container-private.

`MacSelfTest` (env-gated by `MUON_MACTEST` + `MUON_MACTEST_FOLDER`) indexes a
folder, plays its first track and writes `mactest.done` into Application Support.
It sets `LibraryStore.roots` directly, bypassing the bookmark flow, so the folder
must already be readable by the sandbox.

## Run in the simulator

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData/MuonPlayer-*/Build/Products/Debug-iphonesimulator -maxdepth 1 -name MuonPlayer.app | head -1)
xcrun simctl install booted "$APP"
xcrun simctl launch booted me.pecheny.muonplayer
xcrun simctl io booted screenshot /tmp/shot.png
```

Load test audio into the app's Documents dir (rescanned on launch):
```bash
DOCS=$(xcrun simctl get_app_container booted me.pecheny.muonplayer data)/Documents
```
Clean up stray `.caf` capture files there — they get rescanned as "Unknown Album".

Env-gated launch self-tests (`GaplessSelfTest`, `SwitchNoiseSelfTest`,
`SkipScrobbleSelfTest`, `PlayheadSelfTest`, `ScrobbleSelfTest`, `ArtworkSelfTest`)
are triggered with `SIMCTL_CHILD_`-prefixed env vars, e.g.
`SIMCTL_CHILD_MUON_PLAYHEADTEST=1 xcrun simctl launch booted me.pecheny.muonplayer`.
Each writes a `*.done` report into Documents.

## Driving the simulator UI (idb)

`idb` lives in a Python 3.11 venv (fb-idb breaks on 3.14); companion via brew.
```bash
IDB=~/idbenv/bin/idb          # setup: brew install facebook/fb/idb-companion
                              #        uv venv --python 3.11 ~/idbenv && uv pip install --python ~/idbenv/bin/python fb-idb
UDID=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)
$IDB ui tap  --udid $UDID X Y
$IDB ui swipe --udid $UDID X1 Y1 X2 Y2 --duration 0.4
$IDB ui text --udid $UDID "query"
```
**Coordinates are in POINTS, not pixels.** iPhone 17 is 402×874 pt; screenshots
are 3× (1206×2622 px) — divide screenshot pixel coords by 3. `$IDB describe`
prints `width_points`/`height_points`.

## Deploy to a physical iPhone

Device UDID for `xcodebuild` comes from `xctrace`/`-showdestinations`, **not**
`devicectl` (they differ). Signing team is `B5T934YFU5` (personal team,
ap@pecheny.me); automatic signing.

```bash
DEV_UDID=$(xcrun xctrace list devices 2>&1 | grep -v Simulator | grep -i iphone | grep -oE '\([0-9A-F-]{25,}\)' | tr -d '()' | head -1)
xcodebuild -project MuonPlayer.xcodeproj -scheme MuonPlayer -configuration Debug \
  -destination "platform=iOS,id=$DEV_UDID" \
  -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=B5T934YFU5 build

# install (devicectl uses its OWN device id — `xcrun devicectl list devices`)
APP=$(find ~/Library/Developer/Xcode/DerivedData/MuonPlayer-*/Build/Products/Debug-iphoneos -maxdepth 1 -name MuonPlayer.app | head -1)
xcrun devicectl device install app --device "$(xcrun devicectl list devices | grep -i 'iphone' | grep connected | awk '{print $3}')" "$APP"
```

## Library maintenance

`scripts/muon-dedup.swift` removes redundant copies of an album, keeping the
best-quality one. It reads the Mac app's SQLite library (no FFmpeg needed) and
treats two folders as the same album only when the tags agree, the track counts
agree, and every duration matches **to within one sample** — a remaster or a
different edit differs by tens of milliseconds, which is why that rule is safe to
automate.

```bash
swift scripts/muon-dedup.swift                     # dry run (default)
swift scripts/muon-dedup.swift --apply --rescue-art
python3 scripts/test-muon-dedup.py                 # synthetic correctness suite
```

Multi-disc releases collapse to the album folder (discs are kept or dropped
together); two sibling rips do not, since they are what we compare. Deletions go
to the Trash, and `--rescue-art` copies any cover the survivor lacks before the
loser is removed.

## App icon

Both apps share `MuonPlayer/Assets.xcassets/AppIcon.appiconset`
(`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`). iOS uses the single
`AppIcon-1024.png`; macOS needs the classic ten-slice `mac` idiom set
(`AppIcon-mac-*.png`), downsampled from that same 1024 art with `sips`. Without
those slices the Mac app silently builds with **no icon at all**.

The 1024 master is generated:

```bash
cd design/icon
python3 gen_icon.py                         # tunables at top; writes icon.svg
rsvg-convert -w 1024 -h 1024 icon.svg -o /tmp/raw.png   # brew install librsvg
python3 -c "from PIL import Image; Image.open('/tmp/raw.png').convert('RGB').save('/tmp/AppIcon-1024.png')"  # strip alpha (iOS requires opaque)
cp /tmp/AppIcon-1024.png ../../MuonPlayer/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png

# then regenerate the macOS slices from it
python3 scripts/gen-mac-icon.py
```

The icon: a schematic front-on speaker driver flanked by radiating waves shaped
like `(((((o))` — the arcs also spell "muon" (m + u, the driver as o, n).
