#!/bin/bash
# Builds a lean audio-only FFmpeg (libav*) for Apple platforms and for Android.
#
#   scripts/build-ffmpeg.sh [apple|android|all]     (default: apple)
#
# Apple slices (iOS-simulator arm64, iOS-device arm64, macOS arm64) are assembled
# into xcframeworks under Vendor/FFmpeg. Android slices are static .a per ABI under
# Vendor/FFmpeg/android/<abi>, which the Swift package links into its own .so.
# Native opus/vorbis/mp3/aac/flac/wavpack/ape decoders — no external codec
# libraries, and nothing GPL-only (all of these are LGPL in FFmpeg).
#
# The --enable-decoder/--enable-demuxer allowlists below must cover every
# extension in AudioFormat.supportedExtensions. A format listed there but missing
# here is scanned into the library and then silently fails to play.
# Already-built slices under .ffmpeg-build are reused; delete one to force a rebuild.
set -euo pipefail

MODE="${1:-apple}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.ffmpeg-build"
SRC="$WORK/FFmpeg"
OUT="$ROOT/Vendor/FFmpeg"          # xcframeworks land here
FFMPEG_TAG="release/7.1"
MINVER=17.0
MACMINVER=14.0
ANDROID_API=28
SWIFT_ANDROID_SDK="${SWIFT_ANDROID_SDK:-swift-6.3.3-RELEASE_android}"

LIBS="libavcodec libavformat libavutil libswresample"

# Everything that is not platform or toolchain: the codec allowlist, and the
# switches that strip FFmpeg down to audio decoding.
COMMON_CONFIGURE=(
  --enable-static --disable-shared
  --enable-pic
  --disable-programs --disable-ffmpeg --disable-ffplay --disable-ffprobe
  --disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages
  --disable-debug
  --disable-avdevice --disable-postproc --disable-avfilter --disable-swscale
  --disable-network
  --disable-everything
  --enable-avcodec --enable-avformat --enable-avutil --enable-swresample
  --enable-decoder=vorbis,opus,mp3,mp3float,aac,aac_latm,alac,flac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f32be,pcm_s16be,pcm_u8,wmav1,wmav2,ac3,eac3,wavpack,ape
  --enable-parser=vorbis,opus,mpegaudio,aac,aac_latm,flac,ac3
  --enable-demuxer=ogg,matroska,mov,mp3,aac,flac,wav,aiff,caf,asf,ac3,eac3,wv,ape
  --enable-protocol=file
  --disable-asm
)

mkdir -p "$WORK"

# --- fetch source ---
if [ ! -d "$SRC" ]; then
  echo ">>> cloning FFmpeg $FFMPEG_TAG"
  git clone --depth 1 -b "$FFMPEG_TAG" https://github.com/FFmpeg/FFmpeg.git "$SRC"
fi

build_slice () {
  local sdk="$1" arch="$2" target="$3" name="$4"
  local prefix="$WORK/$name"
  local sdkpath
  sdkpath="$(xcrun --sdk "$sdk" --show-sdk-path)"

  if [ -f "$prefix/lib/libavutil.a" ]; then
    echo ">>> reusing slice: $name"
    return
  fi

  echo ">>> building slice: $name ($sdk / $arch)"
  cd "$SRC"
  make distclean >/dev/null 2>&1 || true

  ./configure \
    --prefix="$prefix" \
    --enable-cross-compile \
    --target-os=darwin \
    --arch="$arch" \
    --cc="xcrun --sdk $sdk clang" \
    --as="xcrun --sdk $sdk clang" \
    --sysroot="$sdkpath" \
    --extra-cflags="-arch $arch -target $target" \
    --extra-ldflags="-arch $arch -target $target" \
    "${COMMON_CONFIGURE[@]}"

  make -j"$(sysctl -n hw.ncpu)"
  make install
}

# The NDK that ships inside the Swift Android SDK, so FFmpeg and the Swift code
# that links it are built against one sysroot.
# The sysroot the Swift Android SDK links against, which is not the NDK's own copy.
android_ndk_sysroot () {
  echo "$HOME/Library/org.swift.swiftpm/swift-sdks/${SWIFT_ANDROID_SDK}.artifactbundle/swift-android/ndk-sysroot"
}

android_ndk () {
  local bundle="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.3-RELEASE_android.artifactbundle/swift-android"
  if [ -n "${ANDROID_NDK_HOME:-}" ]; then echo "$ANDROID_NDK_HOME"; return; fi
  find "$bundle" -maxdepth 1 -name 'android-ndk-*' | head -1
}

build_android_slice () {
  local abi="$1" arch="$2" triple="$3"
  local prefix="$WORK/android-$abi"

  if [ -f "$prefix/lib/libavutil.a" ]; then
    echo ">>> reusing slice: android-$abi"
    return
  fi

  local ndk bin
  ndk="$(android_ndk)"
  [ -d "$ndk" ] || { echo "!! no Android NDK found; set ANDROID_NDK_HOME" >&2; exit 1; }
  bin="$ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin"

  echo ">>> building slice: android-$abi ($triple, API $ANDROID_API)"
  cd "$SRC"
  make distclean >/dev/null 2>&1 || true

  ./configure \
    --prefix="$prefix" \
    --enable-cross-compile \
    --target-os=android \
    --arch="$arch" \
    --sysroot="$ndk/toolchains/llvm/prebuilt/darwin-x86_64/sysroot" \
    --cc="$bin/${triple}${ANDROID_API}-clang" \
    --cxx="$bin/${triple}${ANDROID_API}-clang++" \
    --ar="$bin/llvm-ar" \
    --nm="$bin/llvm-nm" \
    --ranlib="$bin/llvm-ranlib" \
    --strip="$bin/llvm-strip" \
    "${COMMON_CONFIGURE[@]}"

  make -j"$(sysctl -n hw.ncpu)"
  make install
}

write_modulemap () {
  cat > "$1/module.modulemap" <<'EOF'
module CFFmpeg {
    header "libavcodec/avcodec.h"
    header "libavformat/avformat.h"
    header "libavutil/avutil.h"
    header "libavutil/opt.h"
    header "libavutil/channel_layout.h"
    header "libavutil/samplefmt.h"
    header "libavutil/imgutils.h"
    header "libswresample/swresample.h"
    export *
}
EOF
}

build_apple () {
  build_slice iphonesimulator arm64 "arm64-apple-ios${MINVER}-simulator" sim-arm64
  build_slice iphoneos        arm64 "arm64-apple-ios${MINVER}"           ios-arm64
  build_slice macosx          arm64 "arm64-apple-macos${MACMINVER}"      macos-arm64

  # --- assemble xcframeworks (one per lib, libraries only, no embedded headers) ---
  echo ">>> assembling xcframeworks"
  for lib in $LIBS; do
    rm -rf "${OUT:?}/${lib}.xcframework"
    xcodebuild -create-xcframework \
      -library "$WORK/sim-arm64/lib/${lib}.a" \
      -library "$WORK/ios-arm64/lib/${lib}.a" \
      -library "$WORK/macos-arm64/lib/${lib}.a" \
      -output "$OUT/${lib}.xcframework" >/dev/null
    echo "    $OUT/${lib}.xcframework"
  done

  # --- headers (public headers are identical across slices) + module map ---
  echo ">>> staging headers + modulemap"
  rm -rf "$OUT/include"
  cp -R "$WORK/sim-arm64/include" "$OUT/include"
  write_modulemap "$OUT/include"
}

# abi | ffmpeg --arch | clang triple prefix | swift target triple.
#
# All three are built even though the APK ships arm64-v8a only (see abiFilters):
# Skip's gradle task runs `skip android build --arch automatic`, which in a release
# build compiles every architecture, and a leg with no FFmpeg to link against fails
# the whole build.
ANDROID_SLICES=(
  "arm64-v8a|aarch64|aarch64-linux-android|aarch64-linux-android"
  "x86_64|x86_64|x86_64-linux-android|x86_64-linux-android"
  "armeabi-v7a|arm|armv7a-linux-androideabi|arm-linux-androideabi"
)

build_android () {
  for slice in "${ANDROID_SLICES[@]}"; do
    IFS='|' read -r abi arch triple _ <<< "$slice"
    build_android_slice "$abi" "$arch" "$triple"
  done

  echo ">>> staging android libs + headers"
  for slice in "${ANDROID_SLICES[@]}"; do
    IFS='|' read -r abi _ _ _ <<< "$slice"
    rm -rf "${OUT:?}/android/$abi"
    mkdir -p "$OUT/android/$abi"
    for lib in $LIBS; do cp "$WORK/android-$abi/lib/${lib}.a" "$OUT/android/$abi/"; done
  done
  rm -rf "$OUT/android/include"
  cp -R "$WORK/android-arm64-v8a/include" "$OUT/android/include"
  write_modulemap "$OUT/android/include"

  # Install each slice into the NDK sysroot's own per-triple lib directory.
  #
  # Package.swift cannot choose a library path per architecture — linkerSettings
  # condition on platform, and a release build compiles every ABI, so one -L would
  # feed arm64 archives to the x86_64 link. `swift sdk configure
  # --library-search-path` looked like the answer but is keyed to the SDK id, and
  # Skip invokes swift build with a bare target triple, so it is never consulted.
  # These directories, on the other hand, are already on the link line the compiler
  # builds for each triple, which is the whole point of a sysroot.
  local sysroot="$(android_ndk_sysroot)"
  echo ">>> installing into $sysroot"
  for slice in "${ANDROID_SLICES[@]}"; do
    IFS='|' read -r abi _ _ sysdir <<< "$slice"
    for lib in $LIBS; do cp "$WORK/android-$abi/lib/${lib}.a" "$sysroot/usr/lib/$sysdir/"; done
    echo "    $sysdir ← $abi"
  done
}

mkdir -p "$OUT"
case "$MODE" in
  apple)   build_apple ;;
  android) build_android ;;
  all)     build_apple; build_android ;;
  *) echo "usage: $0 [apple|android|all]" >&2; exit 2 ;;
esac

echo ">>> DONE ($MODE). output in $OUT"
ls "$OUT"
