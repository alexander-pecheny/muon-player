#!/bin/bash
# Builds a lean audio-only FFmpeg (libav*) as an xcframework for iOS + macOS.
# Slices: iOS-simulator arm64, iOS-device arm64, macOS arm64.
# Native opus/vorbis/mp3/aac/flac decoders — no external codec libraries.
# Already-built slices under .ffmpeg-build are reused; delete one to force a rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.ffmpeg-build"
SRC="$WORK/FFmpeg"
OUT="$ROOT/Vendor/FFmpeg"          # xcframeworks land here
FFMPEG_TAG="release/7.1"
MINVER=17.0
MACMINVER=14.0

LIBS="libavcodec libavformat libavutil libswresample"

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
    --enable-static --disable-shared \
    --enable-pic \
    --disable-programs --disable-ffmpeg --disable-ffplay --disable-ffprobe \
    --disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages \
    --disable-debug \
    --disable-avdevice --disable-postproc --disable-avfilter --disable-swscale \
    --disable-network \
    --disable-everything \
    --enable-avcodec --enable-avformat --enable-avutil --enable-swresample \
    --enable-decoder=vorbis,opus,mp3,mp3float,aac,aac_latm,alac,flac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f32be,pcm_s16be,pcm_u8,wmav1,wmav2,ac3,eac3 \
    --enable-parser=vorbis,opus,mpegaudio,aac,aac_latm,flac,ac3 \
    --enable-demuxer=ogg,matroska,mov,mp3,aac,flac,wav,aiff,caf,asf,ac3,eac3 \
    --enable-protocol=file \
    --disable-asm

  make -j"$(sysctl -n hw.ncpu)"
  make install
}

build_slice iphonesimulator arm64 "arm64-apple-ios${MINVER}-simulator" sim-arm64
build_slice iphoneos          arm64 "arm64-apple-ios${MINVER}"           ios-arm64
build_slice macosx            arm64 "arm64-apple-macos${MACMINVER}"      macos-arm64

# --- assemble xcframeworks (one per lib, libraries only, no embedded headers) ---
echo ">>> assembling xcframeworks"
rm -rf "$OUT"
mkdir -p "$OUT"
for lib in $LIBS; do
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

cat > "$OUT/include/module.modulemap" <<'EOF'
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

echo ">>> DONE. xcframeworks in $OUT"
ls -la "$OUT"
