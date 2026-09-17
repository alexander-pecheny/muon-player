#!/bin/bash
# Builds a lean audio-only FFmpeg (libav*) as an xcframework for iOS + macOS.
# Slices: iOS-simulator arm64, iOS-device arm64, macOS arm64.
# Native opus/vorbis/mp3/aac/flac/wavpack/ape decoders — no external codec
# libraries, and nothing GPL-only (all of these are LGPL in FFmpeg).
#
# The macOS slice additionally carries the Opus *encoder*, for Send to iPhone
# (Opus). That one does need an external library: FFmpeg's own Opus encoder is
# experimental and audibly worse than libopus at the same bitrate. libopus is
# built here rather than taken from Homebrew, whose copy is compiled for the
# current macOS (minos 26) and so cannot be linked into a 14.0 deployment target.
#
# The --enable-decoder/--enable-demuxer allowlists below must cover every
# extension in AudioFormat.supportedExtensions. A format listed there but missing
# here is scanned into the library and then silently fails to play.
# Already-built slices under .ffmpeg-build are reused; delete one to force a rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.ffmpeg-build"
SRC="$WORK/FFmpeg"
OPUS_SRC="$WORK/opus"
OUT="$ROOT/Vendor/FFmpeg"          # xcframeworks land here
FFMPEG_TAG="release/7.1"
OPUS_TAG="v1.5.2"
MINVER=17.0
MACMINVER=14.0

LIBS="libavcodec libavformat libavutil libswresample"

mkdir -p "$WORK"

# --- fetch source ---
if [ ! -d "$SRC" ]; then
  echo ">>> cloning FFmpeg $FFMPEG_TAG"
  git clone --depth 1 -b "$FFMPEG_TAG" https://github.com/FFmpeg/FFmpeg.git "$SRC"
fi

# The fifth argument is extra configure flags. Only the macOS slice gets an
# encoder: transcoding to Opus happens in the Mac app on the way to the phone,
# and the phone itself has nothing to encode.
# libopus, static, for one slice. CMake rather than autotools: the release
# tarballs ship a configure script but the git tree does not, and cmake is
# already a dependency of nothing else here.
build_opus () {
  local name="$1" sysname="$2" minver="$3"
  local prefix="$WORK/$name"

  if [ -f "$prefix/lib/libopus.a" ]; then
    echo ">>> reusing libopus: $name"
    return
  fi

  if [ ! -d "$OPUS_SRC" ]; then
    echo ">>> cloning libopus $OPUS_TAG"
    git clone --depth 1 -b "$OPUS_TAG" https://github.com/xiph/opus.git "$OPUS_SRC"
  fi

  echo ">>> building libopus: $name"
  rm -rf "$OPUS_SRC/build-$name"
  cmake -S "$OPUS_SRC" -B "$OPUS_SRC/build-$name" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_SYSTEM_NAME="$sysname" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$minver" \
    -DBUILD_SHARED_LIBS=OFF \
    -DOPUS_BUILD_PROGRAMS=OFF \
    -DOPUS_BUILD_TESTING=OFF >/dev/null
  cmake --build "$OPUS_SRC/build-$name" -j"$(sysctl -n hw.ncpu)" >/dev/null
  cmake --install "$OPUS_SRC/build-$name" >/dev/null
}

build_slice () {
  local sdk="$1" arch="$2" target="$3" name="$4" extra="${5:-}"
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

  PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
  ./configure \
    --prefix="$prefix" \
    --enable-cross-compile \
    --target-os=darwin \
    --arch="$arch" \
    --cc="xcrun --sdk $sdk clang" \
    --as="xcrun --sdk $sdk clang" \
    --sysroot="$sdkpath" \
    --extra-cflags="-arch $arch -target $target -I$prefix/include" \
    --extra-ldflags="-arch $arch -target $target -L$prefix/lib" \
    --enable-static --disable-shared \
    --enable-pic \
    --disable-programs --disable-ffmpeg --disable-ffplay --disable-ffprobe \
    --disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages \
    --disable-debug \
    --disable-avdevice --disable-postproc --disable-avfilter --disable-swscale \
    --disable-network \
    --disable-everything \
    --enable-avcodec --enable-avformat --enable-avutil --enable-swresample \
    --enable-decoder=vorbis,opus,mp3,mp3float,aac,aac_latm,alac,flac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f32be,pcm_s16be,pcm_u8,wmav1,wmav2,ac3,eac3,wavpack,ape \
    --enable-parser=vorbis,opus,mpegaudio,aac,aac_latm,flac,ac3 \
    --enable-demuxer=ogg,matroska,mov,mp3,aac,flac,wav,aiff,caf,asf,ac3,eac3,wv,ape \
    --enable-protocol=file \
    --disable-asm \
    $extra

  make -j"$(sysctl -n hw.ncpu)"
  make install
}

build_slice iphonesimulator arm64 "arm64-apple-ios${MINVER}-simulator" sim-arm64
build_slice iphoneos          arm64 "arm64-apple-ios${MINVER}"           ios-arm64
# Only the Mac transcodes, so only the Mac slice carries an encoder and libopus.
build_opus macos-arm64 Darwin "$MACMINVER"
build_slice macosx            arm64 "arm64-apple-macos${MACMINVER}"      macos-arm64 \
  "--enable-libopus --enable-encoder=libopus --enable-muxer=opus,ogg"

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

xcodebuild -create-xcframework \
  -library "$WORK/macos-arm64/lib/libopus.a" \
  -output "$OUT/libopus.xcframework" >/dev/null
echo "    $OUT/libopus.xcframework"

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
