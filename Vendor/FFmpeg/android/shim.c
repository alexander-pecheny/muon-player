// Nothing to compile: this target exists so SwiftPM treats Vendor/FFmpeg/android/include
// as a real C target's public header path and propagates -I to everything that
// imports CFFmpeg. A systemLibrary target does not propagate it, and avcodec.h
// includes <libavutil/samplefmt.h> by path.
