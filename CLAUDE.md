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
80 tests in 18 suites).

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

## TestFlight

```bash
scripts/testflight.sh ios     # or: mac
```

It archives Release, exports, validates and uploads. `DEVELOPMENT_TEAM`,
`ASC_KEY_ID` and `ASC_ISSUER_ID` come from `.env`; the API key itself lives in
`~/.appstoreconnect/private_keys/AuthKey_<id>.p8`, where `altool` finds it.

The Mac target is pinned to `ARCHS: arm64`. A Release **archive** builds every
architecture rather than just the active one, and `Vendor/FFmpeg` ships only a
`macos-arm64` slice, so an unpinned archive dies at `Ld ... x86_64`. Debug builds
never hit it. Building the x86_64 slice would lift the pin and let the app run on
Intel Macs.

The build number is `git rev-list --count HEAD` unless `CURRENT_PROJECT_VERSION`
overrides it — App Store Connect rejects a re-used one, and a commit count only
ever goes up. Both `Info.plist`s read `$(MARKETING_VERSION)`/
`$(CURRENT_PROJECT_VERSION)`, set in `project.yml`, so the version lives in one
place.

`MuonPlayer/PrivacyInfo.xcprivacy` sits in the shared source dir and so ships in
**both** bundles. It declares `UserDefaults` (`CA92.1`) and the file-timestamp
reads the scanner does (`C617.1` for the iOS Documents container, `3B52.1` for
the folders a Mac user picks). Without it the upload is rejected by email before
review ever sees it. It declares **no** collected data, and App Store Connect has
to keep saying the same: a scrobble is transmitted to the user's own Last.fm
account under their own credentials, so neither we nor a partner of ours can
reach it, and with no login the app never contacts Last.fm at all. Apple's test
is whether *you or your third-party partners* gain access — not whether bytes
leave the device.

Never let a credential reach `Secrets.swift` beyond the Last.fm API key/secret —
string literals are readable in the shipped binary. The login self-test takes
`MUON_LOGIN_TEST_USER`/`MUON_LOGIN_TEST_PASSWORD` from the environment for that
reason.

## Android

A third app, built from the same `MuonPlayer/{Audio,Library,Models,Playback,Scanner,
Scrobble}` sources. [Skip](https://skip.dev) compiles the Swift natively with the
Swift 6.3 Android SDK and renders the SwiftUI in `Sources/MuonSkip` as Jetpack
Compose, so the library, scanner, tag writer, decoder and gapless engine are the
same code the Apple apps run — not a reimplementation.

```bash
scripts/android-run.sh                                 # build, install, launch
scripts/android-run.sh --music ~/Music_shared/Some/Album   # …and push an album

# or by hand:
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
export PATH="$HOME/.swiftly/bin:$PATH"
swift build --target MuonCore --swift-sdk aarch64-unknown-linux-android28  # core only
skip android build                                     # core + UI → libMuonSkip.so
(cd Android && gradle assembleDebug)                   # → .build/Android/app/outputs/apk/debug
emulator -avd muon-test -no-window -no-audio -no-snapshot &
```

An Android build leaves a Gradle daemon and a Kotlin compile daemon resident, both
`-Xmx4g`, and the Kotlin one idles for two hours before it gives up. With an
emulator alongside they are enough to make everything else on the machine feel
slow, so after Android work:

```bash
gradle --stop && pkill -f KotlinCompileDaemon && adb emu kill
```

`android-run.sh` works the same for a phone over USB (Developer options → USB
debugging, accept the RSA prompt) and for the emulator. It rescans MediaStore after
pushing music, because a direct-path read of shared storage goes through
MediaStore's view of the disk and `adb push` does not update it.

The gapless machinery works: on a real library the seam pass measured 36 tracks,
found a 17 ms gap at a *Somewhere City* transition and trimmed 725 samples, and
playing across that seam keeps **one** AAudio stream open the whole way (grep
logcat for `AAudioStreamBuilder_openStream` — more than one means it is not
gapless any more).

`MuonPlayer/Compat/` holds what Android has no answer for, all `#if os(Android)`:
an `AVAudioEngine`/`AVAudioPlayerNode` pair backed by **AAudio** (the NDK's C API,
so Swift reaches it the way it reaches FFmpeg, no JNI), the PCM buffer the decoder
fills, `NWPathMonitor`, and `PlatformImage` — which on Android keeps artwork
*encoded* so BitmapFactory can do the downsampling ImageIO does on Apple.
`MUON_APPLE_UI` (set in `project.yml`, never by the package) gates the parts of
`Player` that reach into `MuonPlayer/Shared`.

Traps, each of which cost hours:

- **Skip caches the staged `Package.swift`.** It copies the manifest into
  `.build/plugins/outputs/.../src/main/swift/` and does not notice when yours
  changes, so a manifest edit silently does nothing. After editing `Package.swift`:
  `rm -rf .build/plugins .build/Android .build/aarch64-unknown-linux-android28`,
  then `skip android build`, then gradle **twice** — the Kotlin bridge is emitted
  by gradle's *iOS* pre-build, and until it exists `Main.kt` fails on
  `Unresolved reference 'MuonSkipRootView'`.
- **That pre-build uses Xcode's Swift, not swiftly's.** So the manifest must
  type-check under both (it is written as plain statements for that reason), it
  must *link* for iOS (hence the FFmpeg xcframeworks as binary targets), and you
  must never run `swift build --triple arm64-apple-ios` with the swiftly toolchain
  — it poisons `.build/arm64-apple-ios` with 6.3 modules Xcode's 6.2 cannot read.
- **The SQLite amalgamation has no FTS5 unless asked.** `Vendor/SQLite/sqlite3-muon.c`
  sets `SQLITE_ENABLE_FTS5` and includes `sqlite3.c`; the define lives in the source
  because when it is missing nothing fails loudly — `CREATE VIRTUAL TABLE tracks_fts`
  quietly does nothing, the triggers that write to it are still created, and then
  every `INSERT INTO tracks` fails with `no such table: main.tracks_fts` and the
  library just stays empty.
- **`@State` cannot be `private`** in a view Skip bridges, and `import skip.lib.*`
  in `Main.kt` shadows `arrayOf` (use `kotlin.arrayOf`).
- A C target propagates its public header path to importers; a `systemLibrary`
  does not. That is why `CFFmpeg` is a `.target` with a one-line `shim.c`.

There is no console: `print` goes nowhere a device can show. `LibraryBridge.probe`
and `.diagnose` walk the scan pipeline stage by stage and return the result *to the
UI*, and `Database.selfTest()` reports why a write failed in SQLite's own words.
Reach for those first.

Storage is direct filesystem paths, not the Storage Access Framework: SAF hands
back `content://` URLs and `FileScanner` walks a filesystem. So the picker browses
real directories and the app asks for `READ_MEDIA_AUDIO`.

**`UserDefaults` does not survive a relaunch on Android** — that is corelibs
Foundation's own implementation, not Skip's, and `synchronize()` does not help.
Nothing errors; the value is simply gone next launch, which silently un-persisted
the player's volume and repeat mode, the gapless fix mode, and the Last.fm session
key. So the core reads and writes those through **`Library/Prefs.swift`**, which is
`UserDefaults` on Apple and a JSON file in Application Support on Android. Use it
for anything new that has to persist; `diagnose` prints
`persisted prefs=true userdefaults=false` from inside one process if you doubt it.

Still missing: a Media3 MediaSession (no lock-screen controls — `MUON_APPLE_UI`
compiles the `MPNowPlayingInfoCenter` code out), artwork in the UI, and the rest of
the iOS screens.

### Shipping it

`Android/fastlane` already has a `release` lane (`bundleRelease` +
`upload_to_play_store`), so Play internal testing is the intended path — the
Android analogue of `scripts/testflight.sh ios`. Three things are in the way:

- **`gradle assembleRelease` does not work yet.** Skip's generated task hardcodes
  `--arch automatic`, which in release fans out to aarch64 + armv7 + x86_64, while
  `Package.swift` has one `-L` pointing at `Vendor/FFmpeg/android/arm64-v8a` — so
  the x86_64 leg dies on `incompatible with elf_x86_64`. Fixing it means building
  the other slices (`ANDROID_ABIS=all scripts/build-ffmpeg.sh android`) *and*
  making the library path arch-aware, which SwiftPM cannot express with
  `.when(platforms:)`; it needs an env var the per-arch build sets.
- **It signs with the debug key.** `app/build.gradle.kts` falls back to it when
  `Android/app/keystore.properties` is absent. Play rejects that.
- **Size.** The debug APK is 229 MB because the generated packaging block sets
  `keepDebugSymbols.add("**/*.so")` — 148 MB of that is unstripped native libs.
  Stripping `libMuonSkip.so` alone takes it from 26 MB to 6.4 MB, so dropping that
  line is the single biggest lever, at the cost of native crash symbolication.

`abiFilters` is pinned to `arm64-v8a` in `defaultConfig.ndk`. Without it the
package advertised the ABIs androidx ships, and a 32-bit or x86_64 device would
install an app that dies in `dlopen` looking for `libMuonSkip.so`.

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

### In the app: the seam scan runs itself

Every library scan is followed by a **seam pass** (`Library/GaplessMaintenance.swift`),
detached and off the main actor, so the fast scan is never held up by it. It measures the
silence stranded at each album transition, records it per track, and the decoder skips it
from then on. A track carries the mtime it was measured at (`tracks.gapless_mtime`), so an
ordinary relaunch measures nothing; only a file that actually changed is looked at again.
A first pass over 12.7k tracks takes ~13 s.

> Not `.background` priority, which sounds right and is not — that QoS is confined to the
> efficiency cores, and it turned those 13 seconds into **nine minutes**. `.utility`, and a
> sliding window rather than a barrier per batch.

What it does with a broken seam is `GaplessFixMode` (Settings → Gapless):

- **`playbackOnly`** (default) — the measurement goes into `tracks.gapless_head/_tail` and
  `FFmpegDecoder` trims it at decode, exactly as it already trims from `iTunSMPB`. No file
  is touched. This is the only fix that works for **every** format: a gap in a FLAC or an
  Opus is real silence in the audio that no tag could ever take back, but the decoder can
  simply not play it. On a real library: 55 seams closed of 181, across aac/mp3/vorbis/
  opus/flac.
- **`rewriteSourceFiles`** — additionally writes the LAME header into the MP3s, so other
  players get the fix too. Originals are copied whole into Application Support first, each
  write is verified by decoding it back, and anything that does not come back clean is
  restored on the spot.

The tail trim cannot be a `targetOutputFrames` cap: a file that needs measuring is a file
whose declared duration is a guess (a Xing-less VBR mp3 has only a bitrate estimate). So
the decoder runs `holdOutputFrames` behind itself and drops what is left at EOF.

Everything it judges and every file it touches goes to **`Application Support/gapless.log`**
on both platforms — the logic changes what you hear and, in one mode, what is on disk, so
"did we touch this file, and what did we think we measured?" has to stay answerable.

### The CLI

The **`MuonGapless`** target finds the album transitions meant to be seamless, and the
ones that are meant to be but aren't. The judging is app code — `Audio/GaplessScan.swift`
(the verdicts) on top of `Audio/EdgeDecoder.swift` (the last and first 500 ms of a file,
at its native rate) — so a defect it reports is one the player would play. `MuonGapless/`
is just the front end: read the DB, fan out, print.

```bash
xcodebuild -project MuonPlayer.xcodeproj -scheme MuonGapless -configuration Release \
  -destination 'platform=macOS,arch=arm64' build
G=$(find ~/Library/Developer/Xcode/DerivedData/MuonPlayer-*/Build/Products/Release \
  -maxdepth 1 -name muon-gapless | head -1)

"$G"                                        # the report
"$G" --html > ~/Desktop/muon-gapless.html   # the readable one
"$G" --json --filter "Pink Floyd"
python3 scripts/test-muon-gapless.py        # synthetic suite (builds the target itself)
```

Seams are split into **loud** and **quiet** by the level of their *quieter* side
(`--loud-db`, default −25). Most seams are quiet — two hushed outros touching — and a
song crashing straight into the next one is a different thing worth picking out.

It decodes **in-process**, through the FFmpeg the app links. It used to shell out to the
`ffmpeg` CLI, which cost 27 ms of process startup to do 2 ms of work — 25k spawns, and
~100% of a 132 s scan was fork/exec. In-process the same library takes **9 s**. Work is
fanned out one album per core, and a track's two windows come from a single open of the
file (its head is wanted by the seam before it, its tail by the seam after).

> The lesson from the CLI era, still true of anything that shells out per file
> (`muon-cloud-sync`): open the `Process` inside an `autoreleasepool` and close both ends
> of the `Pipe` by hand. Foundation leaves the parent's copy of the pipe to the pool, so a
> tight concurrent loop of spawns runs the process out of descriptors and `run()` starts
> throwing EBADF. An early version of this scanner swallowed those failures and silently
> skipped two thirds of the library while reporting a clean bill of health — which is why
> a failed decode is counted and shouted about instead.

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
"$G" --json > /tmp/plan.json
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

> A trap that bit both the player and the scanner: when FFmpeg drops a codec's priming
> itself (Opus's 312-sample pre-skip, AAC's 64), it shrinks the frame but leaves the pts
> **negative** — it warns "Could not update timestamps for skipped samples" and means it.
> Take that pts at face value while working out how much priming is left to skip and you
> skip it twice, eating the first 6.5 ms of every Opus track. So a pts-derived sample
> cursor is clamped at 0 (`FFmpegDecoder.consumeSkip`, `EdgeDecoder.pump`); a negative one
> only ever means *already trimmed*. `OpusPreskipTests` guards it.

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
