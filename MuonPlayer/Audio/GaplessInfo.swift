import Foundation
import CFFmpeg

/// Apple's `iTunSMPB` gapless tag: encoder priming (leading samples to drop),
/// trailing padding, and the exact count of real samples in between.
///
/// FFmpeg's mov demuxer does not read this tag — it only honours edit lists.
/// Files written by XLD, older iTunes, and most Bandcamp/CD rippers carry
/// `iTunSMPB` alone, so we apply the trim ourselves.
struct GaplessInfo: Equatable {
    let priming: Int64
    let padding: Int64
    let validSamples: Int64

    var totalSamples: Int64 { priming + validSamples + padding }

    /// Tag value is space-separated hex:
    /// `<reserved> <priming> <padding> <valid-samples> …`
    init?(iTunSMPB tag: String) {
        let f = tag.split(separator: " ")
        guard f.count >= 4,
              let priming = Int64(f[1], radix: 16),
              let padding = Int64(f[2], radix: 16),
              let valid = Int64(f[3], radix: 16),
              valid > 0
        else { return nil }
        self.priming = priming
        self.padding = padding
        self.validSamples = valid
    }

    static func read(_ dicts: OpaquePointer?...) -> GaplessInfo? {
        for dict in dicts {
            guard let e = av_dict_get(dict, "iTunSMPB", nil, AV_DICT_IGNORE_SUFFIX),
                  let v = e.pointee.value,
                  let info = GaplessInfo(iTunSMPB: String(cString: v))
            else { continue }
            return info
        }
        return nil
    }

    /// Whether FFmpeg has already trimmed the stream for us. When an edit list
    /// is present the demuxer shortens the stream duration to the valid count
    /// and attaches skip-samples side data; without one, duration still spans
    /// priming + valid + padding and nothing is trimmed.
    func ffmpegAlreadyTrims(streamDurationInSamples: Int64) -> Bool {
        abs(streamDurationInSamples - totalSamples) > 2
    }
}
