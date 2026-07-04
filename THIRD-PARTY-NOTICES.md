# Third-Party Notices

MuonPlayer's own source is released under the [MIT License](LICENSE). It also
links against third-party software, listed below.

## FFmpeg

MuonPlayer statically links a lean, audio-only build of the FFmpeg libraries
(`libavcodec`, `libavformat`, `libavutil`, `libswresample`).

- **Version:** FFmpeg `release/7.1`
- **License:** GNU Lesser General Public License, version 2.1 or later (LGPL-2.1-or-later)
- **Upstream:** <https://ffmpeg.org> / <https://github.com/FFmpeg/FFmpeg>
- **Full license text:** [`MuonPlayer/Resources/LGPL-2.1.txt`](MuonPlayer/Resources/LGPL-2.1.txt)
  (also viewable in-app under Settings → About → Licenses)

The build enables **only** the LGPL feature set — it is configured **without**
`--enable-gpl` and **without** `--enable-nonfree`, so the resulting binaries are
LGPL, not GPL. No external codec libraries (x264, etc.) are linked.

### Enabled components

- **Decoders:** vorbis, opus, mp3, mp3float, aac, aac_latm, alac, flac,
  pcm_s16le, pcm_s24le, pcm_s32le, pcm_f32le, pcm_f32be, pcm_s16be, pcm_u8,
  wmav1, wmav2, ac3, eac3
- **Parsers:** vorbis, opus, mpegaudio, aac, aac_latm, flac, ac3
- **Demuxers:** ogg, matroska, mov, mp3, aac, flac, wav, aiff, caf, asf, ac3, eac3
- **Protocols:** file

### LGPL compliance — how to relink

The LGPL requires that you be able to run MuonPlayer against a modified version
of FFmpeg. Because this project is fully open source, that is straightforward:

1. Clone this repository.
2. Modify FFmpeg however you like (or point `scripts/build-ffmpeg.sh` at your
   own FFmpeg source tree / tag).
3. Rebuild the xcframeworks: `./scripts/build-ffmpeg.sh`
4. Rebuild the app: `xcodegen generate && xcodebuild ...` (see the README).

The exact FFmpeg source used is FFmpeg `release/7.1` from the upstream Git
repository, built with the unmodified `scripts/build-ffmpeg.sh` in this repo.
