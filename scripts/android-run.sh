#!/bin/bash
# Build the Android app and put it on a device — a phone over USB, or the emulator.
#
#   scripts/android-run.sh                        # build, install, launch
#   scripts/android-run.sh --music ~/Music_shared/Artist/Album
#   scripts/android-run.sh --device <serial>      # when more than one is attached
#
# On a phone: enable Developer options (tap Build number seven times) and USB
# debugging, plug it in, and accept the RSA prompt. `adb devices` should list it
# before running this. The build is debug-signed, which is all a sideload needs.
#
# The app is arm64-v8a only (see Vendor/FFmpeg/android), which every Android phone
# since ~2019 is. `adb install` refuses rather than installing something broken.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export JAVA_HOME="${JAVA_HOME:-$(brew --prefix openjdk)}"
export PATH="$HOME/.swiftly/bin:/opt/homebrew/bin:$PATH"
ADB="$ANDROID_HOME/platform-tools/adb"

APPID=me.pecheny.muonplayer
ACTIVITY="$APPID/muon.skip.MainActivity"
MUSIC=""
DEVICE=()
adb_() { "$ADB" ${DEVICE[@]+"${DEVICE[@]}"} "$@"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --music)  MUSIC="$2"; shift 2 ;;
    --device) DEVICE=(-s "$2"); shift 2 ;;
    *) echo "usage: $0 [--music DIR] [--device SERIAL]" >&2; exit 2 ;;
  esac
done

attached=$("$ADB" devices | grep -cw device || true)
if [ "$attached" -eq 0 ]; then
  echo "!! no device. Plug in a phone with USB debugging on, or start the emulator:" >&2
  echo "   $ANDROID_HOME/emulator/emulator -avd muon-test -no-window &" >&2
  exit 1
fi
if [ "$attached" -gt 1 ] && [ ${#DEVICE[@]+${#DEVICE[@]}} -eq 0 ]; then
  "$ADB" devices -l >&2
  echo "!! more than one device; pass --device <serial>" >&2
  exit 1
fi

echo ">>> building"
(cd "$ROOT/Android" && gradle assembleDebug --console=plain -q)

APK="$ROOT/.build/Android/app/outputs/apk/debug/app-debug.apk"
echo ">>> installing $(du -h "$APK" | cut -f1)"
adb_ install -r "$APK"

if [ -n "$MUSIC" ]; then
  dest="/sdcard/Music/$(basename "$MUSIC")"
  echo ">>> pushing $MUSIC → $dest"
  adb_ shell mkdir -p "\"$dest\""
  adb_ push "$MUSIC/." "$dest/" >/dev/null
  # Direct-path reads of shared storage go through MediaStore's view of the disk,
  # and files copied by adb are not in it until something rescans.
  adb_ shell cmd media rescan --directory /sdcard/Music >/dev/null 2>&1 || true
fi

# Saves tapping through the runtime prompt; the app asks for it on launch anyway.
adb_ shell pm grant "$APPID" android.permission.READ_MEDIA_AUDIO 2>/dev/null || true

echo ">>> launching"
adb_ shell am force-stop "$APPID"
adb_ shell am start -n "$ACTIVITY" >/dev/null
echo ">>> up. Library → Folder → browse to your music, then Index this folder."
