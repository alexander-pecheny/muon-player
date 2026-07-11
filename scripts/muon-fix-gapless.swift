//
//  muon-fix-gapless — repair the MP3s whose gapless transitions are broken, by
//  giving them the encoder delay/padding they should have carried all along.
//
//  It takes the plan `muon-gapless --json` writes, and for every GAP seam in it
//  fixes the two files that meet at the seam: the one before it gets its trailing
//  padding declared, the one after it its encoder delay. Only the Xing/Info header
//  frame is rewritten — every audio frame, and every ID3 tag, is copied through
//  byte for byte (TagWriter does the writing, atomically).
//
//  Only MP3 is repairable this way. The m4a files in a library carry their gapless
//  data already — an edit list, or Apple's iTunSMPB — and FFmpeg ignores the tail
//  trim in both, so those seams are fixed in the player, not in the file. FLAC,
//  Opus and Vorbis gaps are real silence in the audio, which no tag can take back.
//
//  The values are derived, not assumed. Each file is decoded and measured, and the
//  measurement is read against whatever FFmpeg already trims for the file today —
//  so a header that is simply missing and a header that is present but lying are
//  both handled, and neither ends up double-counted.
//
//  Nothing is written without --apply, every touched file is copied into a backup
//  tree first, and each write is verified by decoding the result: a file that does
//  not come back clean is restored from its backup on the spot.
//
//  Usage:
//    swiftc -O scripts/muon-fix-gapless.swift MuonPlayer/Library/TagWriter.swift \
//      -o /tmp/muon-fix-gapless
//    /tmp/muon-gapless --json > /tmp/plan.json
//    /tmp/muon-fix-gapless --plan /tmp/plan.json                 # dry run (default)
//    /tmp/muon-fix-gapless --plan /tmp/plan.json --apply
//    /tmp/muon-fix-gapless --restore ~/.muon-gapless-backups/<stamp>
//

import Foundation

/// Mirrors the app's TagEdits so this script needs no part of the app but TagWriter.
struct TagEdits: Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var trackNo: Int?
    var composer: String?
    var year: Int?
}

// MARK: - Options

struct Options {
    var plan: String?
    var apply = false
    var verbose = false
    var restore: String?
    var backupRoot = NSHomeDirectory() + "/.muon-gapless-backups"
    /// The decoder's own delay, which every writer of the LAME field has already
    /// taken off: FFmpeg skips `delay + 529`.
    let decoderDelay = 529
    /// Silence longer than this at a seam is not encoder padding — it is silence
    /// somebody meant to be there, and it is left alone. The 12-bit LAME fields
    /// cannot express more than 4095 samples anyway.
    var maxPadSamples = 4095
    /// A seam is left alone when closing it would still leave the sound dropping this
    /// far away in the join — a tick in place of a hiccup is not a repair. Raise it to
    /// close those seams anyway: the dip is always shorter than the gap it replaces.
    var dipDb = 12.0
    var jobs = ProcessInfo.processInfo.activeProcessorCount
}

func parseOptions() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--plan": o.plan = it.next()
        case "--apply": o.apply = true
        case "--dry-run": o.apply = false
        case "--verbose", "-v": o.verbose = true
        case "--restore": o.restore = it.next()
        case "--backup-dir": o.backupRoot = it.next() ?? o.backupRoot
        case "--dip-db": o.dipDb = Double(it.next() ?? "") ?? o.dipDb
        case "--jobs", "-j": o.jobs = Int(it.next() ?? "") ?? o.jobs
        case "--help", "-h":
            print("""
            muon-fix-gapless — write the missing/wrong encoder delay into broken MP3s.

              --plan FILE       the JSON `muon-gapless --json` wrote  (required)
              --apply           write; without it, only report
              --restore DIR     put every file in a backup directory back
              --backup-dir DIR  where backups go (default ~/.muon-gapless-backups)
              --dip-db N        refuse a seam that would still dip this far (default 12;
                                raise it to close a gap at the price of a short dip)
              --verbose         show the files that need no change
              --jobs, -j N      parallel workers
            """)
            exit(0)
        default:
            FileHandle.standardError.write("unknown argument: \(arg)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    return o
}

let opts = parseOptions()
let fm = FileManager.default

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - Restore

struct BackupEntry: Codable {
    let path: String
    let backup: String
    let delayBefore: Int
    let paddingBefore: Int
    let delayAfter: Int
    let paddingAfter: Int
}

func restore(from dir: String) -> Never {
    let manifest = URL(fileURLWithPath: dir).appendingPathComponent("manifest.json")
    guard let data = try? Data(contentsOf: manifest),
          let entries = try? JSONDecoder().decode([BackupEntry].self, from: data)
    else { fail("no manifest at \(manifest.path)") }

    var restored = 0
    for e in entries {
        do {
            // Copied back, not moved: `replaceItemAt` would consume the backup, leaving
            // the directory a manifest with nothing behind it — and a backup you can
            // only use once is a trap, not a safety net.
            let original = try Data(contentsOf: URL(fileURLWithPath: e.backup))
            try original.write(to: URL(fileURLWithPath: e.path), options: .atomic)
            restored += 1
        } catch {
            print("FAILED \(e.path) — \(error)")
        }
    }
    print("restored \(restored)/\(entries.count) files from \(dir)")
    exit(0)
}

// MARK: - The plan

struct Seam: Decodable {
    let kind: String
    let from: String
    let to: String
    let artist: String
    let album: String
    let codec: String
}

/// Only a seam whose two files are both MP3 can be closed by a header — and only the
/// end a seam actually implicates is ever trimmed, so a track whose head follows a
/// real pause keeps its leading silence, whatever the encoder put there.
func readPlan() -> (seams: [Seam], otherFormats: Int) {
    guard let planPath = opts.plan else { fail("need --plan (the JSON from muon-gapless --json)") }
    guard let planData = try? Data(contentsOf: URL(fileURLWithPath: planPath)),
          let all = try? JSONDecoder().decode([Seam].self, from: planData)
    else { fail("cannot read the plan at \(planPath)") }

    func isMP3(_ p: String) -> Bool { p.lowercased().hasSuffix(".mp3") }

    // A hole is repaired the same way a gap is — by trimming what the encoder left
    // behind. It is only a different verdict because it is heard differently.
    let broken = all.filter { $0.kind == "gap" || $0.kind == "hole" }
    let mine = broken.filter { isMP3($0.from) && isMP3($0.to) }
    return (mine, broken.count - mine.count)
}

// MARK: - Decoding

/// Only the half-second at one end of a file is ever needed: the trim is the silence
/// there, and the tag values follow from it without the length of the whole file.
let windowSeconds = 0.5

/// Foundation leaves the parent's end of the pipe to the autorelease pool, so a tight
/// loop of spawns runs the process out of file descriptors and `run()` starts throwing
/// EBADF. A pool per call, both ends closed by hand, and a retry — a decode that
/// silently did not happen would leave a file unfixed and unreported.
/// Both channels, kept apart. A click can live in one of them and all but vanish in a
/// mono mixdown — which is how three of them once slipped past the check below and
/// into the library.
let channels = 2

func decodeEdge(_ path: String, tail: Bool) -> [Float]? {
    let seconds = String(format: "%.3f", windowSeconds)
    var args = ["ffmpeg", "-v", "error", "-nostdin"]
    args += tail ? ["-sseof", "-\(seconds)", "-i", path] : ["-i", path, "-t", seconds]
    args += ["-map", "0:a:0", "-ac", "\(channels)", "-f", "f32le", "-"]

    for attempt in 0 ..< 3 {
        let data: Data? = autoreleasepool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            defer {
                try? out.fileHandleForReading.close()
                try? out.fileHandleForWriting.close()
            }
            guard (try? p.run()) != nil else { return nil }
            let d = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return d
        }
        guard let data else { usleep(50_000 << attempt); continue }
        guard data.count >= 4 else { return nil }
        return data.withUnsafeBytes { raw in
            (0 ..< data.count / 4).map {
                Float(bitPattern: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))
            }
        }
    }
    return nil
}

/// How far the sound would drop away in the join once both edges are trimmed, against
/// the music either side of it.
///
/// Trimming the padding cannot conjure back audio the split threw away. Some rippers
/// fade a few ms in at the cut, and that fade is in the samples: trim up to it and the
/// seam still dips, which in loud music is heard as a tick. Closing a gap only to
/// leave a hole is not a repair, so this is measured before anything is written.
func joinDip(tail: [Float], trail: Int, head: [Float], lead: Int) -> Double {
    let block = 44                                            // 1 ms
    let endFrame = tail.count / channels - trail
    guard endFrame > 40 * block, lead + 40 * block < head.count / channels else { return 0 }

    func levels(_ x: [Float], from: Int, count: Int) -> [Double] {
        (0 ..< count).map { i in
            var sum = 0.0
            for f in (from + i * block) ..< (from + (i + 1) * block) {
                for c in 0 ..< channels {
                    let v = Double(x[f * channels + c])
                    sum += v * v
                }
            }
            return (sum / Double(block * channels)).squareRoot()
        }
    }

    let before = levels(tail, from: endFrame - 40 * block, count: 40)
    let after = levels(head, from: lead, count: 40)
    let music = (before + after).sorted()[(before.count + after.count) / 2]
    let atJoin = (before.suffix(3) + after.prefix(3)).min() ?? 0
    guard music > 1e-9 else { return 0 }
    return 20 * log10(music) - 20 * log10(max(atJoin, 1e-9))
}

/// How hard the waveform steps where the two trimmed edges would meet, measured
/// against how hard the music steps either side of it — the same test, channel by
/// channel, that the scanner uses to call a seam clicky. The worst channel decides.
func joinStep(tail: [Float], trail: Int, head: [Float], lead: Int) -> (ratio: Double, step: Double)? {
    let look = 882                                            // 20 ms
    let endFrame = tail.count / channels - trail
    guard endFrame > look, lead + look < head.count / channels else { return nil }

    var worstRatio = 0.0, worstStep = 0.0
    for c in 0 ..< channels {
        let left = ((endFrame - look) ..< endFrame).map { tail[$0 * channels + c] }
        let right = (lead ..< (lead + look)).map { head[$0 * channels + c] }
        guard let last = left.last, let first = right.first else { continue }

        var deltas: [Double] = []
        for side in [left, right] {
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

func sampleRate(_ path: String) -> Int? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["ffprobe", "-v", "error", "-select_streams", "a:0",
                   "-show_entries", "stream=sample_rate", "-of", "csv=p=0:nk=1", path]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return Int(String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: CharacterSet(charactersIn: ", \n\r")))
}

/// Where the music starts and ends inside a decoded stream, to the sample.
///
/// It has to be to the sample. Two tracks that meet at a hard cut only sound joined
/// if the waveform is continuous across the join, and at full level a third of a
/// millisecond of slop is already a step of ~0.08 — an audible click. Trimming a
/// block at a time trades the gap for a tick.
///
/// Encoder padding is not digital silence but the encoder's ringing around it, which
/// stays under about -60 dB, while the music at such a seam comes in at full level
/// within a sample or two. So the edge is the first sample clear of that ringing.
/// Erring low only leaves a little padding behind, which is the harmless direction —
/// erring high would cut into the music.
func bounds(_ x: [Float], floor absolute: Float = 1.5e-3) -> (lead: Int, trail: Int) {
    let frames = x.count / channels
    func peak(_ f: Int) -> Float {
        (0 ..< channels).map { abs(x[f * channels + $0]) }.max() ?? 0
    }
    func edges(_ floor: Float) -> (Int, Int)? {
        guard let first = (0 ..< frames).first(where: { peak($0) > floor }),
              let last = (0 ..< frames).reversed().first(where: { peak($0) > floor })
        else { return nil }
        return (first, frames - (last + 1))
    }
    guard let (leadAbs, trailAbs) = edges(absolute) else { return (frames, frames) }

    // Encoder padding is not silence. It is the encoder's decay ringing around
    // silence, and in loud music that ringing still clears -56 dBFS — so trimming to
    // an absolute floor stops early and leaves a millisecond of near-nothing wedged
    // between two loud tracks. That hole is not a step, so no click test sees it, and
    // it is exactly what a "slight click" at a seam turns out to be.
    //
    // So the floor is set against the music instead: 30 dB below it. What that can
    // cost is the first or last few ms of a genuinely soft intro or outro, so the
    // relative floor is only allowed to reach a little past where the absolute one
    // stopped — ringing dies out in a millisecond or two, an intro does not.
    let blockFrames = 44                                     // 1 ms
    let peaks = stride(from: 0, to: max(frames - blockFrames, 1), by: blockFrames).map { s in
        (s ..< min(s + blockFrames, frames)).map(peak).max() ?? 0
    }.sorted()
    guard !peaks.isEmpty else { return (leadAbs, trailAbs) }

    let music = peaks[Int(Double(peaks.count) * 0.9)]        // the loud part of this window
    let relative = max(absolute, music * 0.0316)             // -30 dB below it
    guard let (leadRel, trailRel) = edges(relative) else { return (leadAbs, trailAbs) }

    let reach = 441                                          // at most 10 ms further in
    return (min(leadRel, leadAbs + reach), min(trailRel, trailAbs + reach))
}

// MARK: - What each seam needs

/// One end of one file: the silence to be trimmed there, and what the file's header
/// says about that end today.
struct Edge {
    let samples: [Float]
    let silence: Int                 // samples of it, at the seam-facing end
    let tag: TagWriter.MP3Gapless?

    /// What FFmpeg already takes off this end today. Reading the measurement against
    /// it is what makes a header that is present and lying get corrected rather than
    /// added to.
    func alreadyTrimmed(_ head: Bool) -> Int {
        guard let tag else { return 0 }
        if head { return tag.delay + opts.decoderDelay }
        return tag.frames > 0 ? max(0, tag.padding - opts.decoderDelay) : 0
    }
}

func edge(_ path: String, tail: Bool) -> Edge? {
    guard let x = decodeEdge(path, tail: tail), x.count > 2048 else { return nil }
    let data = (try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)) ?? Data()
    let (lead, trail) = bounds(x)
    return Edge(samples: x, silence: tail ? trail : lead, tag: TagWriter.readMP3Gapless(data))
}

/// What one broken seam asks of the two files that meet at it.
struct SeamFix {
    let seam: Seam
    let padding: Int?       // for the track before the seam
    let delay: Int?         // for the track after it
    let trimmed: Int        // samples of silence the two trims take out between them
    let refused: String?    // why the seam was left alone, if it was
}

func consider(_ s: Seam, opts: Options) -> SeamFix? {
    guard let before = edge(s.from, tail: true), let after = edge(s.to, tail: false) else { return nil }

    let padding = before.alreadyTrimmed(false) + before.silence + opts.decoderDelay
    let delay = after.alreadyTrimmed(true) + after.silence - opts.decoderDelay

    func refuse(_ why: String) -> SeamFix {
        SeamFix(seam: s, padding: nil, delay: nil, trimmed: 0, refused: why)
    }

    // Silence too long to be padding is silence somebody meant to be there.
    guard (0 ... opts.maxPadSamples).contains(padding), (0 ... opts.maxPadSamples).contains(delay) else {
        return refuse("the silence here is too long to be encoder padding")
    }

    // First, do no harm. If the two edges do not actually meet once the padding is
    // gone, closing the seam does not make it seamless — it trades a gap you can hear
    // for a click you can hear. That happens when the split lost samples rather than
    // merely padding them, and no header can put those samples back.
    // Refused a little below the level at which the scanner would call it a click, so
    // that a seam sitting right on the line does not sneak across it.
    if let join = joinStep(tail: before.samples, trail: before.silence,
                           head: after.samples, lead: after.silence),
       join.ratio >= 6, join.step >= 0.02 {
        return refuse(String(format: "the edges do not meet — closing it would step %.1f× (%.3f), a click",
                             join.ratio, join.step))
    }

    let dip = joinDip(tail: before.samples, trail: before.silence,
                      head: after.samples, lead: after.silence)
    if dip >= opts.dipDb {
        return refuse(String(format: "the split faded the audio — closing it would still dip %.0f dB, a tick",
                             dip))
    }

    return SeamFix(seam: s, padding: padding, delay: delay,
                   trimmed: before.silence + after.silence, refused: nil)
}

/// The header a file ends up with, once every seam it takes part in has had its say.
struct Plan {
    let path: String
    let before: TagWriter.MP3Gapless?
    let delay: Int
    let padding: Int
    let headTrim: Int
    let tailTrim: Int

    /// Under half a millisecond of residual silence is the encoder's ringing, not a
    /// gap, and rewriting a file to shave it off buys nothing.
    var changes: Bool { max(headTrim, tailTrim) >= 16 }
}

func name(_ p: String) -> String { (p as NSString).lastPathComponent }
func ms(_ samples: Int) -> String { String(format: "%.0f ms", Double(samples) / 44_100 * 1000) }

@main
enum MuonFixGapless {
    static func main() {
        if let dir = opts.restore { restore(from: dir) }

        let (seams, otherFormats) = readPlan()
        guard !seams.isEmpty else {
            print("no MP3 seams to fix (\(otherFormats) gap seams are in other formats)")
            exit(0)
        }

        let lock = NSLock()
        var fixes: [SeamFix] = []
        let slots = DispatchSemaphore(value: opts.jobs)

        DispatchQueue.concurrentPerform(iterations: seams.count) { i in
            slots.wait()
            defer { slots.signal() }
            guard let f = consider(seams[i], opts: opts) else { return }
            lock.lock(); fixes.append(f); lock.unlock()
        }

        // Each end of a file belongs to exactly one seam, so the two verdicts never
        // fight over the same field: the seam before a track sets its delay, the seam
        // after it sets its padding.
        var plans: [String: Plan] = [:]
        func amend(_ path: String, delay: Int? = nil, padding: Int? = nil, trim: Int) {
            let data = (try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)) ?? Data()
            let existing = plans[path]
            let before = existing?.before ?? TagWriter.readMP3Gapless(data)
            plans[path] = Plan(
                path: path, before: before,
                delay: delay ?? existing?.delay ?? before?.delay ?? 0,
                padding: padding ?? existing?.padding ?? before?.padding ?? 0,
                headTrim: delay != nil ? trim : (existing?.headTrim ?? 0),
                tailTrim: padding != nil ? trim : (existing?.tailTrim ?? 0))
        }

        for f in fixes where f.refused == nil {
            guard let padding = f.padding, let delay = f.delay else { continue }
            amend(f.seam.from, padding: padding, trim: f.trimmed)
            amend(f.seam.to, delay: delay, trim: f.trimmed)
        }

        let refused = fixes.filter { $0.refused != nil }
        let work = plans.values.filter(\.changes).sorted { $0.path < $1.path }

        for p in work {
            let was = p.before.map { "delay \($0.delay), pad \($0.padding)" } ?? "no Xing header"
            var trims: [String] = []
            if p.headTrim >= 16 { trims.append("\(ms(p.headTrim)) off the head") }
            if p.tailTrim >= 16 { trims.append("\(ms(p.tailTrim)) off the tail") }
            print("  \(name(p.path))\n      \(was)  →  delay \(p.delay), pad \(p.padding)"
                  + (trims.isEmpty ? "" : "   [\(trims.joined(separator: ", "))]"))
        }

        if !refused.isEmpty {
            print("\nleft alone:")
            for f in refused {
                print("  \(f.seam.artist) — \(f.seam.album)  \(name(f.seam.from)) → \(name(f.seam.to))"
                      + "\n      \(f.refused!)")
            }
        }

        print("\n\(work.count) MP3s to rewrite, closing \(fixes.count - refused.count) of "
              + "\(fixes.count) seams"
              + (otherFormats == 0 ? "" :
                 "; \(otherFormats) gap seams are not MP3 and are the player's to fix"))

        guard opts.apply else {
            print("dry run — nothing written. Pass --apply.")
            exit(0)
        }
        guard !work.isEmpty else { exit(0) }
        apply(work)
    }

    static func apply(_ work: [Plan]) {
        // The whole file is backed up, not just the header: the header frame shifts
        // everything behind it, so there is no smaller thing to keep.
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let backupDir = URL(fileURLWithPath: opts.backupRoot).appendingPathComponent(stamp)
        var entries: [BackupEntry] = []
        var written = 0, reverted = 0

        for p in work {
            let backup = backupDir.appendingPathComponent("files" + p.path)
            do {
                try fm.createDirectory(at: backup.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.copyItem(at: URL(fileURLWithPath: p.path), to: backup)
                try TagWriter.writeMP3Gapless(delay: p.delay, padding: p.padding,
                                              to: URL(fileURLWithPath: p.path))
            } catch {
                print("FAILED \(name(p.path)) — \(error)")
                continue
            }

            // Decode what was just written. A file that does not come back clean goes
            // straight back to how it was — the fix is not worth a damaged library.
            let tolerance = 64                                  // ~1.5 ms
            let headOK = p.headTrim < 16
                || (decodeEdge(p.path, tail: false).map { bounds($0).lead <= tolerance } ?? false)
            let tailOK = p.tailTrim < 16
                || (decodeEdge(p.path, tail: true).map { bounds($0).trail <= tolerance } ?? false)

            if headOK, tailOK {
                entries.append(BackupEntry(path: p.path, backup: backup.path,
                                           delayBefore: p.before?.delay ?? 0,
                                           paddingBefore: p.before?.padding ?? 0,
                                           delayAfter: p.delay, paddingAfter: p.padding))
                written += 1
            } else {
                _ = try? fm.replaceItemAt(URL(fileURLWithPath: p.path), withItemAt: backup)
                reverted += 1
                print("REVERTED \(name(p.path)) — it did not come back clean after writing")
            }
        }

        if !entries.isEmpty {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(entries).write(to: backupDir.appendingPathComponent("manifest.json"))
        }

        print("""

        wrote \(written) file\(written == 1 ? "" : "s")\(reverted > 0 ? ", reverted \(reverted)" : "")
        backups: \(backupDir.path)
        roll back with:  muon-fix-gapless --restore \(backupDir.path)
        """)
    }
}
