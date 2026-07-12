import Foundation

/// What a seam between two tracks turns out to be.
///
/// Only a transition where *both* files are still sounding at the seam is judged at
/// all — the usual fade-to-silence boundary is not a gapless transition and returns
/// nil, which is what keeps a report of a whole library short enough to read.
enum SeamKind: String {
    case flow      // seamless, and it sounds seamless
    case click     // seamless, but the splice ticks
    case hole      // seamless, but a millisecond of near-nothing sits in the join
    case gap       // meant to be seamless; encoder padding got in the way
}

/// Every threshold the verdict turns on. Defaults are the tuned ones.
struct SeamThresholds {
    /// A block of audio quieter than this is silence.
    var silenceDb = -60.0
    /// The music on each side must be at least this loud, so that a fade-out that
    /// merely stops short of digital zero isn't read as a hard cut.
    var minEdgeDb = -50.0
    /// Silence at the seam up to this long still counts as "the music flows".
    var gapMs = 10.0
    /// Silence between two hard-cut edges up to this long is encoder padding, not an
    /// intended pause. Covers AAC's 2112 priming samples (48 ms at 44.1k).
    var padMs = 60.0
    /// A seam whose quieter side reaches this is a *loud* one.
    var loudDb = -25.0
    /// The sound may drop away this far in the join before the seam is heard to tick.
    var dipDb = 12.0
    /// The step at the splice must be this many times the largest step the music itself
    /// makes nearby before it counts as a click.
    var clickRatio = 8.0
    /// ...and this big in absolute terms, so a click in near-silence isn't reported.
    var clickAbs = 0.02
    /// How much audio to pull from each side of the seam.
    var windowMs = 500.0
    /// Silence longer than this at a seam is silence somebody meant to be there, and is
    /// never trimmed. Also the most the 12-bit LAME delay/padding fields can express
    /// (4095 samples ≈ 93 ms at 44.1k), which is what makes it writable to an MP3 header.
    var maxPadMs = 92.0
}

struct SeamVerdict {
    let kind: SeamKind
    let tailDb: Double
    let headDb: Double
    let gapMs: Double
    let ratio: Double
    let step: Double
    let note: String

    /// How loud the seam is: the quieter of its two sides, since a transition is only
    /// as striking as its weaker half. A song crashing straight into the next one is a
    /// different thing from two ambient outros touching, and it is the one worth
    /// hearing — so the two are told apart rather than piled together.
    var levelDb: Double { min(tailDb, headDb) }
    func isLoud(_ t: SeamThresholds) -> Bool { levelDb >= t.loudDb }
}

enum SeamScan {
    static func dB(_ rms: Double) -> Double { rms <= 1e-9 ? -120 : 20 * log10(rms) }

    /// RMS of each 1 ms block.
    private static func blocks(_ a: EdgeAudio, from: Int, count: Int?) -> [Double] {
        let size = max(1, a.rate / 1000)
        let end = count.map { min(from + $0 * size, a.frames) } ?? a.frames
        guard from < end else { return [] }
        return a.samples.withUnsafeBufferPointer { s -> [Double] in
            stride(from: from, to: end, by: size).map { start in
                let stop = min(start + size, end)
                var sum = 0.0
                for f in start ..< stop {
                    for c in 0 ..< a.channels {
                        let v = Double(s[f * a.channels + c])
                        sum += v * v
                    }
                }
                let n = Double((stop - start) * a.channels)
                return n > 0 ? (sum / n).squareRoot() : 0
            }
        }
    }

    struct Edge {
        /// Silence at the seam-facing end of the window, in ms.
        let silenceMs: Double
        /// Loudness of the 20 ms of music sitting against that silence — or against the
        /// file boundary, when there is none. This tells a hard cut from a fade-out.
        let levelDb: Double
    }

    static func analyse(_ audio: EdgeAudio, tail: Bool, _ t: SeamThresholds) -> Edge {
        // Walk from the seam inwards. Reversing the tail's blocks means "index 0 is the
        // sample nearest the seam" for both sides, and the rest needn't care which side
        // it is on.
        let ms = blocks(audio, from: 0, count: nil)
        let inward = tail ? Array(ms.reversed()) : ms

        let silent = inward.prefix { dB($0) < t.silenceDb }.count
        let level = inward.dropFirst(silent).prefix(20)
        let rms = level.isEmpty ? 0
            : (level.map { $0 * $0 }.reduce(0, +) / Double(level.count)).squareRoot()
        return Edge(silenceMs: Double(silent), levelDb: dB(rms))
    }

    /// How violently the waveform jumps when the two files are played back to back,
    /// measured against how violently the music is already jumping either side of the
    /// seam. Music full of transients earns a bigger allowance than a sustained note.
    static func splice(_ a: EdgeAudio, _ b: EdgeAudio) -> (ratio: Double, step: Double)? {
        guard a.rate == b.rate, a.channels == b.channels, a.frames > 64, b.frames > 64
        else { return nil }
        let look = min(a.rate / 50, min(a.frames, b.frames))          // 20 ms

        var worstRatio = 0.0, worstStep = 0.0
        for c in 0 ..< a.channels {
            let left = a.channel(c).suffix(look), right = b.channel(c).prefix(look)
            guard let last = left.last, let first = right.first else { continue }

            var deltas: [Double] = []
            deltas.reserveCapacity(2 * look)
            for side in [Array(left), Array(right)] {
                for i in 1 ..< side.count { deltas.append(abs(Double(side[i] - side[i - 1]))) }
            }
            deltas.sort()
            let p99 = deltas[min(deltas.count - 1, Int(Double(deltas.count) * 0.99))]

            let step = abs(Double(first - last))
            let ratio = step / max(p99, 1e-5)
            if ratio > worstRatio { worstRatio = ratio; worstStep = step }
        }
        return (worstRatio, worstStep)
    }

    /// How far the sound drops away at the join, against the music either side of it.
    ///
    /// A seam can be continuous — no silence to speak of, no step in the waveform — and
    /// still tick, because a millisecond of near-nothing is wedged into it. That is what
    /// is left when a trim stops at an absolute silence floor while the encoder's decay
    /// ringing, which in loud music clears that floor easily, plays on. It is not a gap
    /// and not a step, so neither of those tests sees it; in loud music it is heard as a
    /// click all the same.
    static func dip(_ tail: EdgeAudio, _ head: EdgeAudio) -> Double {
        guard tail.rate == head.rate, tail.channels == head.channels else { return 0 }
        let size = max(1, tail.rate / 1000)

        let before = blocks(tail, from: max(0, tail.frames - 40 * size), count: 40)
        let after = blocks(head, from: 0, count: 40)
        guard before.count >= 6, after.count >= 6 else { return 0 }

        let music = (before + after).sorted()[(before.count + after.count) / 2]    // median
        let atJoin = (before.suffix(3) + after.prefix(3)).min() ?? 0
        guard music > 0 else { return 0 }
        return dB(music) - dB(atJoin)
    }

    /// Where the music starts and ends inside a window, to the sample.
    ///
    /// It has to be to the sample. Two tracks meeting at a hard cut only sound joined if
    /// the waveform is continuous across the join, and at full level a third of a
    /// millisecond of slop is already a step of ~0.08 — an audible click. Trimming a
    /// block at a time trades the gap for a tick.
    ///
    /// Encoder padding is not silence: it is the encoder's decay ringing *around*
    /// silence, and in loud music that ringing clears an absolute −56 dBFS floor easily.
    /// Trimming to an absolute floor therefore stops early and leaves a millisecond of
    /// near-nothing wedged between two loud tracks — heard as a click, though it is
    /// neither a gap nor a step. So the floor is set 30 dB below the music instead, and
    /// may only reach a little past where the absolute floor stopped: ringing dies in a
    /// millisecond or two, a soft intro does not.
    static func bounds(_ a: EdgeAudio, absolute: Float = 1.5e-3) -> (lead: Int, trail: Int) {
        let frames = a.frames
        guard frames > 0 else { return (0, 0) }

        func peak(_ f: Int) -> Float {
            var m: Float = 0
            for c in 0 ..< a.channels { m = max(m, abs(a.samples[f * a.channels + c])) }
            return m
        }
        func edges(_ floor: Float) -> (Int, Int)? {
            guard let first = (0 ..< frames).first(where: { peak($0) > floor }),
                  let last = (0 ..< frames).reversed().first(where: { peak($0) > floor })
            else { return nil }
            return (first, frames - (last + 1))
        }
        guard let (leadAbs, trailAbs) = edges(absolute) else { return (frames, frames) }

        let block = max(1, a.rate / 1000)                        // 1 ms
        let peaks = stride(from: 0, to: max(frames - block, 1), by: block).map { s in
            (s ..< min(s + block, frames)).map(peak).max() ?? 0
        }.sorted()
        guard !peaks.isEmpty else { return (leadAbs, trailAbs) }

        let music = peaks[min(peaks.count - 1, Int(Double(peaks.count) * 0.9))]
        let relative = max(absolute, music * 0.0316)             // −30 dB below the music
        guard let (leadRel, trailRel) = edges(relative) else { return (leadAbs, trailAbs) }

        let reach = block * 10                                   // at most 10 ms further in
        return (min(leadRel, leadAbs + reach), min(trailRel, trailAbs + reach))
    }

    /// The two trims that would close a seam, in samples at each file's own rate — or
    /// why the seam is better left alone.
    ///
    /// Three rules keep this from making a library worse. Silence too long to be encoder
    /// padding is silence somebody *meant*. A seam is only closed if the two edges
    /// actually meet: if trimming would leave a step big enough to hear, it is refused,
    /// because a click is no improvement on a gap — that happens when the split lost
    /// samples rather than merely padding them, and no trim puts those back. And it is
    /// refused if closing it would still leave a **hole**, which is what a ripper's short
    /// fade at the split leaves: a tick in place of a hiccup is not a repair.
    enum Repair: Equatable {
        case trim(tail: Int, head: Int)
        case refused(String)
    }

    static func repair(tail: EdgeAudio, head: EdgeAudio, _ t: SeamThresholds) -> Repair {
        let trail = bounds(tail).trail
        let lead = bounds(head).lead

        let maxTail = Int(Double(tail.rate) * t.maxPadMs / 1000)
        let maxHead = Int(Double(head.rate) * t.maxPadMs / 1000)
        guard trail <= maxTail, lead <= maxHead else {
            return .refused("the silence here is too long to be encoder padding")
        }
        guard trail > 0 || lead > 0 else { return .refused("nothing to trim") }

        let a = drop(tail, trailing: trail)
        let b = drop(head, leading: lead)

        // Refused a little below the level at which a seam is *called* a click, so one
        // sitting right on the line does not sneak across it.
        if let join = splice(a, b), join.ratio >= 6, join.step >= t.clickAbs {
            return .refused(String(format: "the edges do not meet — closing it would step %.1f× (%.3f), a click",
                                   join.ratio, join.step))
        }
        let drop = dip(a, b)
        if drop >= t.dipDb {
            return .refused(String(format: "the split faded the audio — closing it would still dip %.0f dB, a tick",
                                   drop))
        }
        return .trim(tail: trail, head: lead)
    }

    private static func drop(_ a: EdgeAudio, trailing: Int) -> EdgeAudio {
        EdgeAudio(rate: a.rate, channels: a.channels,
                  samples: Array(a.samples.prefix((a.frames - trailing) * a.channels)))
    }

    private static func drop(_ a: EdgeAudio, leading: Int) -> EdgeAudio {
        EdgeAudio(rate: a.rate, channels: a.channels,
                  samples: Array(a.samples.dropFirst(leading * a.channels)))
    }

    /// nil when the two tracks do not run into each other — an ordinary boundary, with a
    /// fade on one side or a real pause between them.
    static func judge(tail: EdgeAudio, head: EdgeAudio,
                      tailLossy: Bool, headLossy: Bool, codec: String,
                      _ t: SeamThresholds) -> SeamVerdict? {
        let tailEdge = analyse(tail, tail: true, t)
        let headEdge = analyse(head, tail: false, t)

        guard tailEdge.levelDb > t.minEdgeDb, headEdge.levelDb > t.minEdgeDb
        else { return nil }

        let gap = tailEdge.silenceMs + headEdge.silenceMs
        var note = ""
        var kind: SeamKind
        var ratio = 0.0, step = 0.0

        if gap <= t.gapMs {
            kind = .flow
            if tail.rate != head.rate || tail.channels != head.channels {
                note = "\(tail.rate)/\(tail.channels)ch → \(head.rate)/\(head.channels)ch, not compared"
            } else if let s = splice(tail, head) {
                ratio = s.ratio
                step = s.step
                if ratio >= t.clickRatio, step >= t.clickAbs { kind = .click }
            }
            if kind == .flow {
                let drop = dip(tail, head)
                if drop >= t.dipDb {
                    kind = .hole
                    note = String(format: "the sound drops %.0f dB for a moment in the join", drop)
                }
            }
        } else if gap <= t.padMs {
            kind = .gap
            note = tailLossy || headLossy ? "\(codec) encoder padding" : "\(codec), cut short"
        } else {
            return nil
        }

        return SeamVerdict(kind: kind, tailDb: tailEdge.levelDb, headDb: headEdge.levelDb,
                           gapMs: gap, ratio: ratio, step: step, note: note)
    }
}
