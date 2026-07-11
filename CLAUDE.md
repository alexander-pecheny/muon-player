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
58 tests in 13 suites).

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

`xcodebuild` and `devicectl` name the same phone by **different ids**, and neither
can be grepped out of the plain-text listings by device name (the phone is called
`pecheny17`, so `grep -i iphone` finds nothing). Take both from one JSON dump —
`udid` is what `-destination` wants, `identifier` is what `devicectl` wants.
Signing team is `B5T934YFU5` (personal team, ap@pecheny.me); automatic signing.

```bash
xcrun devicectl list devices --json-output /tmp/dev.json >/dev/null
eval "$(python3 -c "
import json
p = [d for d in json.load(open('/tmp/dev.json'))['result']['devices']
     if d['hardwareProperties']['platform'] == 'iOS'][0]
print(f\"DEV_UDID={p['hardwareProperties']['udid']}; DEV_ID={p['identifier']}\")")"

xcodebuild -project MuonPlayer.xcodeproj -scheme MuonPlayer -configuration Debug \
  -destination "platform=iOS,id=$DEV_UDID" \
  -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=B5T934YFU5 build

APP=$(find ~/Library/Developer/Xcode/DerivedData/MuonPlayer-*/Build/Products/Debug-iphoneos -maxdepth 1 -name MuonPlayer.app | head -1)
xcrun devicectl device install app --device "$DEV_ID" "$APP"
```

## Library maintenance

`scripts/muon-dedup.swift` removes redundant copies of an album, keeping the
best-quality one. It reads the Mac app's SQLite library (no FFmpeg needed) and
treats two folders as the same album only when the tags agree, the track counts
agree, and every duration lines up.

"Lines up" depends on the formats. Two copies **in the same format** must match
to within one sample. Two copies in **different** formats are a transcode and its
source, and a lossy encoder prepends the same priming delay to every track (Opus
312 samples ≈ 6.5 ms, AAC 2112), so they may differ by a *shared* offset — up to
`--max-offset-ms` (100), with the per-track offsets agreeing to within
`--offset-spread-ms` (2). Withholding that latitude from same-format pairs is what
keeps a uniformly-longer remaster from being read as a copy; `--max-offset-ms 0`
restores the old exact-lengths-only rule.

```bash
swift scripts/muon-dedup.swift                     # dry run (default)
swift scripts/muon-dedup.swift --apply --rescue-art
python3 scripts/test-muon-dedup.py                 # synthetic correctness suite
```

Multi-disc releases collapse to the album folder (discs are kept or dropped
together); two sibling rips do not, since they are what we compare. Deletions go
to the Trash, and `--rescue-art` copies any cover the survivor lacks before the
loser is removed.

`scripts/muon-albumartist.swift` folds a family of album-artist strings into one,
so that "SOULOUD feat. X" and "SOULOUD, Y" stop splitting a discography into an
entry per collaborator. It rewrites `album_artist` in the files (the per-track
`artist` tag is left alone) and so must be compiled against the app's TagWriter,
which edits tags in place without re-encoding:

```bash
swiftc -O scripts/muon-albumartist.swift MuonPlayer/Library/TagWriter.swift \
  -o /tmp/muon-albumartist
/tmp/muon-albumartist --prefix SOULOUD             # dry run (default)
/tmp/muon-albumartist --prefix SOULOUD --apply
```

`scripts/muon-gapless.swift` finds the album transitions meant to be seamless, and
the ones that are meant to be but aren't. It reads the library DB, then decodes the
last and first 500 ms of each adjacent pair through the `ffmpeg` CLI — the same
decoder the app plays through, so a defect it finds is one you would hear.

```bash
swiftc -O scripts/muon-gapless.swift -o /tmp/muon-gapless && /tmp/muon-gapless
/tmp/muon-gapless --html > ~/Desktop/muon-gapless.html          # the readable report
swift scripts/muon-gapless.swift --json --filter "Pink Floyd"   # slow: unoptimized
python3 scripts/test-muon-gapless.py                            # synthetic suite
```

Seams are split into **loud** and **quiet** by the level of their *quieter* side
(`--loud-db`, default −25). Most seams are quiet — two hushed outros touching — and a
song crashing straight into the next one is a different thing worth picking out.

> Anything that shells out per file must open its `Process` inside an
> `autoreleasepool` and close both ends of the `Pipe` by hand. Foundation leaves the
> parent's copy of the pipe to the pool, so a tight concurrent loop of spawns runs the
> process out of descriptors and `run()` starts throwing EBADF. An early version of
> this scanner swallowed those failures and silently skipped two thirds of the library
> while reporting a clean bill of health — which is why a failed decode is now counted
> and shouted about instead.

Compile it — in `swift`'s interpreter the per-sample loops are ~10× slower. Work is
fanned out one seam per core (a seam's two decodes are shared with no other seam);
a 12.7k-track library takes under a minute.

Only a transition where **both** files are still sounding at the seam is reported —
the usual fade-to-silence boundary is skipped, which is what keeps the report short.
Of those, three verdicts:

- **flow** — the music runs straight through.
- **CLICK** — the waveform steps at the splice by far more than the music itself
  steps nearby (`--click-ratio`, default 8× the local 99th-percentile sample delta).
  A mistrimmed lossy encode, or a rip split at a non-zero crossing.
- **HOLE** — no silence to speak of and no step, yet the sound drops away for a
  millisecond or two in the join (`--dip-db`, default 12 dB below the surrounding
  music). In a loud seam that is heard as a click. It is what a ripper's short fade at
  the split leaves behind, and — being audio, not padding — no header can undo it.
- **GAP** — both files are cut off mid-note, yet the decoder still puts 10–60 ms of
  silence between them (`--gap-ms`…`--pad-ms`). That is the encoder delay surviving
  into playback: mp3 with no LAME/Xing header ≈ 25 ms, AAC with no iTunSMPB ≈ 48 ms.

The thresholds all have flags; `--min-edge-db` (default −50) is the one that keeps a
fade-out that merely stops short of digital zero from being read as a hard cut. The
last→first seam is checked too — an album written to loop (Origami Angel's
*Somewhere City*) joins it as carefully as any seam inside it.

`scripts/muon-fix-gapless.swift` repairs the **MP3** side of what the scan finds, by
writing the encoder delay/padding the files should have carried. It takes the
scanner's JSON, and for each GAP seam gives the track before it a trailing padding
and the track after it a delay. Only the Xing/Info header frame is rewritten; audio
frames and ID3 tags are copied byte for byte (`TagWriter.writeMP3Gapless`).

```bash
swiftc -O scripts/muon-fix-gapless.swift MuonPlayer/Library/TagWriter.swift \
  -o /tmp/muon-fix-gapless
/tmp/muon-gapless --json > /tmp/plan.json
/tmp/muon-fix-gapless --plan /tmp/plan.json                    # dry run (default)
/tmp/muon-fix-gapless --plan /tmp/plan.json --apply
/tmp/muon-fix-gapless --restore ~/.muon-gapless-backups/<stamp>
```

Only MP3 is repairable by tag, and the reason is worth knowing before reaching for
any of this:

- **MP3** carries its gapless data in the LAME extension of the Xing/Info header — an
  MPEG frame in front of the audio, not a tag — and FFmpeg honours it (`delay + 529`
  skipped at the head, `padding` at the tail; the 529 is the decoder's own). Most
  broken files have no such header at all; some have one that lies. Both are handled:
  the measurement is read against whatever FFmpeg *already* trims, so an existing
  header is corrected rather than added to.
- **m4a/AAC** files are almost never the problem. They already carry the truth — an
  edit list, or Apple's `iTunSMPB` — and FFmpeg applies the *head* trim from it while
  ignoring the tail (`mov.c` reads only `priming` from iTunSMPB, and never trims to
  the edit-list duration). That is fixed in the player, not the file, by
  `FFmpegDecoder`'s `targetOutputFrames`. Writing tags into these files would achieve
  nothing.
- **FLAC/Opus/Vorbis** gaps are real silence in the audio. No tag takes that back.

Three rules keep it from making a library worse. Silence longer than the 12-bit LAME
fields can express (4095 samples ≈ 93 ms) is silence somebody *meant*, and is left
alone. A seam is only closed if the two edges actually meet: if trimming the padding
would leave a step big enough to hear, the seam is refused, because a click is no
improvement on a gap — that happens when the split lost samples rather than merely
padding them. And a seam is refused if closing it would still leave a **hole**
(`--dip-db`), which is what a ripper's fade at the split leaves: a tick in place of a
hiccup is not a repair. Raise `--dip-db` to close those anyway — the dip is always
shorter than the gap it replaces.

Encoder padding is not silence: it is the encoder's decay ringing *around* silence,
and in loud music that ringing clears an absolute -56 dBFS floor easily. Trimming to
an absolute floor therefore stops early and leaves a millisecond of near-nothing
wedged between two loud tracks — heard as a click, though it is neither a gap nor a
step. So the trim floor is set 30 dB below the music instead, and may only reach a
little past where the absolute floor stopped (ringing dies in a millisecond or two; a
soft intro does not).

The trim is measured to the sample, which it has to be: at full level a third of a
millisecond of slop is already a step of ~0.08, i.e. an audible tick. Every touched
file is copied whole into `~/.muon-gapless-backups/<stamp>` first (the header frame
shifts everything behind it, so there is nothing smaller to keep), each write is
verified by decoding the result, and anything that does not come back clean is
restored on the spot. `--restore` puts a whole run back, byte for byte.

`scripts/muon-cloud-sync.swift` re-encodes any FLAC that is not 16-bit (halving
the rate inside its own family: 96k→48k, 88.2k→44.1k) and uploads whatever the
rclone remote does not already hold.

```bash
swift scripts/muon-cloud-sync.swift                 # dry run; writes the manifest
swift scripts/muon-cloud-sync.swift --apply --log /tmp/rclone.log
python3 scripts/test-muon-cloud-sync.py             # synthetic suite (fake remote)
```

A file is identified by the MD5 of its **decoded audio**, which FLAC stores in
STREAMINFO, so a copy is recognised wherever it is filed — filename is not
identity (a real library had 38 same-named files holding different recordings).
Re-encoding changes the bytes, so a file whose original was already on the remote
is written *over* that object rather than beside it; the mapping is resolved
before any re-encode, and replacements run before the bulk upload.

> Homebrew's `ffmpeg` is **not** built with `libsoxr`. The script detects that and
> falls back to `swr` with `triangular_hp` dither — reducing 24-bit to 16-bit by
> truncation would add quantisation distortion. It also uses `-map 0 -c:v copy`
> (not `-vn`) so embedded cover art survives. ffmpeg still renames `COMMENT` to
> `DESCRIPTION`; do **not** try to fix that with `metaflac --remove-all-tags
> --import-tags-from`, whose tag export cannot round-trip multiline fields like
> `UNSYNCEDLYRICS` and which removes the tags before it finds out.

Tests run the whole flow against a local directory as the "remote" — rclone treats
a bare path as one — so nothing touches a cloud account.

## App icon

Both apps share `MuonPlayer/Assets.xcassets/AppIcon.appiconset`
(`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`). iOS uses the single
`AppIcon-1024.png`; macOS needs the classic ten-slice `mac` idiom set
(`AppIcon-mac-*.png`), downsampled from that same 1024 art with `sips`. Without
those slices the Mac app silently builds with **no icon at all**.

The 1024 master is generated from `design/icon/icon.js`, which holds the geometry
and the tuned defaults. It is the only source: the CLI and the live tuner both
import it. Needs `deno`, `rsvg-convert` (librsvg) and `magick` (imagemagick).

```bash
cd design/icon
deno task icon                  # writes icon.svg + icon.png, installs AppIcon-1024.png
deno task icon --cone 0 --tint '#00aafd'   # override any knob from RANGES/COLORS
deno task lab                   # http://localhost:8000/lab.html — sliders, live preview
python3 ../../scripts/gen-mac-icon.py      # then regenerate the macOS slices
```

The lab is served rather than opened as a `file://` URL because browsers refuse
ES-module imports from `file://`. Its **Copy SVG** button and the URL hash round-trip
a tuning; paste the hash values into `RANGES`/`COLORS` in `icon.js` to make them the
new defaults.

The icon: a schematic front-on speaker driver flanked by radiating waves that
flare outwards (the `cone` knob; 0 makes them parallel `)))`). The arcs also
spell "muon" (m + u, the driver as o, n). They are painted with a radial
gradient centred on the driver plus `feTurbulence` grain — set the three stops
equal and `grain` to 0 for a flat tint.

Two traps in there. `grainSize` is a speckle width, so it is fed to
`feTurbulence` as `1/grainSize` (that filter wants a frequency, where bigger
means finer). And every `<defs>` id is `muon-`prefixed: the lab turns each
`RANGES`/`COLORS` key into an element id, and a `url(#grain)` clashing with
`<input id="grain">` silently resolves to the input, killing the filter.
