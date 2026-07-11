#!/usr/bin/env swift
//
//  muon-gapless — find the album transitions that are meant to be seamless,
//  and the ones that are meant to be but aren't.
//
//  A transition is seamless when the music runs straight from one file into the
//  next: the tail of track N is still sounding at its last sample and track N+1
//  is already sounding at its first. That is the only case reported. The usual
//  boundary — a fade to silence, then a beat of nothing before the next track
//  starts — is not a gapless transition and is skipped, which is what keeps the
//  report short enough to read.
//
//  Two ways such a transition can be broken, and both are reported:
//
//    CLICK  The two halves don't line up. Decoded end-to-end, the waveform makes
//           a step at the splice far bigger than any step within the music around
//           it, and you hear a tick. This is what a lossy encode does when the
//           priming samples were trimmed by hand, or by a tool that cut on a
//           whim rather than on the encoder's own delay.
//
//    GAP    Both files are cut off mid-note, yet the decoder puts a few ms of
//           silence between them. That silence is the encoder's delay/padding
//           surviving into playback (mp3 without a LAME/Xing header ≈ 25 ms, AAC
//           without iTunSMPB ≈ 48 ms), so the seam the album wanted is audible
//           as a hiccup.
//
//  Decoding goes through the ffmpeg CLI, the same library the app plays through,
//  so a click found here is a click you would hear.
//
//  Usage:
//    swift scripts/muon-gapless.swift                    # report
//    swift scripts/muon-gapless.swift --verbose          # list every clean seam too
//    swift scripts/muon-gapless.swift --json
//    swift scripts/muon-gapless.swift --filter "Pink Floyd"
//

import Foundation
import SQLite3

// MARK: - Options

struct Options {
    var db: String = NSHomeDirectory()
        + "/Library/Containers/me.pecheny.muonplayer/Data/Library/Application Support/muon-library.sqlite"
    var json = false
    var html = false
    var verbose = false
    /// Only look at tracks whose path contains this (case-insensitive).
    var filter: String?

    /// A block of audio quieter than this is silence.
    var silenceDb = -60.0
    /// The music on each side of the seam must be at least this loud, so that a
    /// fade-out that merely stops short of digital zero isn't read as a hard cut.
    var minEdgeDb = -50.0
    /// Silence at the seam up to this long still counts as "the music flows".
    var gapMs = 10.0
    /// Silence between two hard-cut edges up to this long is encoder padding, not
    /// an intended pause. Covers AAC's 2112 priming samples (48 ms at 44.1k).
    var padMs = 60.0
    /// A seam whose quieter side reaches this is a *loud* one — two tracks running
    /// into each other at full tilt, which is the transition worth knowing about. The
    /// rest are real seams too, but a pair of ambient tails touching is a quieter
    /// thing than the album's big joins.
    var loudDb = -25.0
    /// The step at the splice must be this many times the largest step the music
    /// itself makes nearby before it counts as a click.
    var clickRatio = 8.0
    /// ...and this big in absolute terms, so a click in near-silence, which nobody
    /// can hear, isn't reported.
    var clickAbs = 0.02
    /// How much audio to pull from each side of the seam.
    var windowMs = 500.0
    var jobs = ProcessInfo.processInfo.activeProcessorCount
}

func parseOptions() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--json": o.json = true
        case "--html": o.html = true
        case "--verbose", "-v": o.verbose = true
        case "--db": o.db = it.next() ?? o.db
        case "--filter": o.filter = it.next()
        case "--loud-db": o.loudDb = Double(it.next() ?? "") ?? o.loudDb
        case "--silence-db": o.silenceDb = Double(it.next() ?? "") ?? o.silenceDb
        case "--min-edge-db": o.minEdgeDb = Double(it.next() ?? "") ?? o.minEdgeDb
        case "--gap-ms": o.gapMs = Double(it.next() ?? "") ?? o.gapMs
        case "--pad-ms": o.padMs = Double(it.next() ?? "") ?? o.padMs
        case "--click-ratio": o.clickRatio = Double(it.next() ?? "") ?? o.clickRatio
        case "--click-abs": o.clickAbs = Double(it.next() ?? "") ?? o.clickAbs
        case "--window-ms": o.windowMs = Double(it.next() ?? "") ?? o.windowMs
        case "--jobs", "-j": o.jobs = Int(it.next() ?? "") ?? o.jobs
        case "--help", "-h":
            print("""
            muon-gapless — find seamless album transitions, and the broken ones.

              --verbose, -v       list clean seams as well as broken ones
              --json              emit the findings as JSON
              --html              emit the findings as a standalone HTML report
              --loud-db N         a seam this loud on its quieter side is a loud one
                                  (default -25)
              --filter TEXT       only tracks whose path contains TEXT
              --db PATH           library database
              --gap-ms N          silence at a seam still counted as flowing (default 10)
              --pad-ms N          silence between hard cuts read as encoder padding (default 60)
              --silence-db N      below this a block is silence (default -60)
              --min-edge-db N     the music at a seam must be this loud (default -50)
              --click-ratio N     step at the splice vs. the music's own steps (default 8)
              --click-abs N       smallest step worth calling a click, 0..1 (default 0.02)
              --window-ms N       audio decoded from each side of a seam (default 500)
              --jobs, -j N        parallel album workers
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

// MARK: - Library

struct Track {
    let path: String
    let title: String
    let artist: String
    let album: String
    let codec: String
    let disc: Int
    let number: Int

    var directory: String { (path as NSString).deletingLastPathComponent }
    var isLossy: Bool { !Track.lossless.contains(codec) }

    static let lossless: Set<String> = [
        "flac", "alac", "wavpack", "ape", "tta",
        "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "pcm_f32be", "pcm_s16be", "pcm_u8",
    ]
}

func readTracks() -> [Track] {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(opts.db, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        FileHandle.standardError.write("cannot open database at \(opts.db)\n".data(using: .utf8)!)
        exit(1)
    }
    defer { sqlite3_close(handle) }

    let sql = """
    SELECT path,
           COALESCE(NULLIF(ov_title,''), title, ''),
           COALESCE(NULLIF(ov_album_artist,''), NULLIF(album_artist,''),
                    NULLIF(ov_artist,''), NULLIF(artist,''), ''),
           COALESCE(NULLIF(ov_album,''), NULLIF(album,''), ''),
           COALESCE(codec,''),
           COALESCE(disc_no, 1),
           COALESCE(NULLIF(ov_track_no,0), track_no, 0)
    FROM tracks
    WHERE duration IS NOT NULL AND duration > 0
    """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
        FileHandle.standardError.write("query failed\n".data(using: .utf8)!)
        exit(1)
    }
    defer { sqlite3_finalize(stmt) }

    var out: [Track] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
        out.append(Track(path: text(0), title: text(1), artist: text(2), album: text(3),
                         codec: text(4),
                         disc: Int(sqlite3_column_int64(stmt, 5)),
                         number: Int(sqlite3_column_int64(stmt, 6))))
    }
    return out
}

/// A run of files that play one after another: one directory, one album tag, one
/// disc. Cross-disc seams are not a thing, and a directory holding two albums is
/// two runs, not one.
struct Album {
    let directory: String
    let artist: String
    let album: String
    let disc: Int
    let tracks: [Track]
}

func albums(from tracks: [Track]) -> [Album] {
    var groups: [String: [Track]] = [:]
    for t in tracks {
        guard FileManager.default.fileExists(atPath: t.path) else { continue }
        groups["\(t.directory)\u{1}\(t.album)\u{1}\(t.disc)", default: []].append(t)
    }
    return groups.values.compactMap { group -> Album? in
        guard group.count >= 2, let first = group.first else { return nil }
        let sorted = group.sorted {
            if $0.number != $1.number, $0.number > 0, $1.number > 0 { return $0.number < $1.number }
            return $0.path < $1.path
        }
        return Album(directory: first.directory, artist: first.artist, album: first.album,
                     disc: first.disc, tracks: sorted)
    }.sorted { ($0.artist, $0.album, $0.disc) < ($1.artist, $1.album, $1.disc) }
}

/// Two tracks play back to back when they sit next to each other in the album and
/// their numbers agree with that (a folder missing track 4 has no 3→5 seam).
func isAdjacent(_ a: Track, _ b: Track) -> Bool {
    if a.number > 0, b.number > 0 { return b.number == a.number + 1 }
    return true
}

/// Every pair of tracks that can play back to back — including last→first, which an
/// album that is written to loop (Origami Angel's *Somewhere City*) joins as
/// carefully as any seam inside it. On repeat that seam is heard, so it is checked.
struct Seam {
    let album: Album
    let from: Int
    let to: Int
    /// The last→first seam, heard only when the album repeats.
    let wrap: Bool
}

func seams(of album: Album) -> [Seam] {
    let n = album.tracks.count
    var out = (0 ..< n - 1)
        .filter { isAdjacent(album.tracks[$0], album.tracks[$0 + 1]) }
        .map { Seam(album: album, from: $0, to: $0 + 1, wrap: false) }
    if n >= 3 { out.append(Seam(album: album, from: n - 1, to: 0, wrap: true)) }
    return out
}

// MARK: - Decoding

struct Audio {
    let rate: Int
    let channels: Int
    /// Interleaved float samples.
    let samples: [Float]

    var frames: Int { channels > 0 ? samples.count / channels : 0 }

    func channel(_ c: Int) -> [Float] {
        stride(from: c, to: samples.count, by: channels).map { samples[$0] }
    }
}

/// Decodes that never happened. A scan that quietly skips a file reports a clean
/// library, which is worse than no scan at all, so this is counted and shouted about
/// at the end rather than swallowed.
final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    private(set) var last = ""

    func record(_ error: String) {
        lock.lock(); count += 1; last = error; lock.unlock()
    }
}
let failures = Failures()

/// Foundation hands the child its end of the pipe and leaves the parent's copy for
/// the autorelease pool to clean up. Spawn ffmpeg twenty thousand times from a tight
/// concurrent loop and the file descriptors pile up until `Process.run()` starts
/// throwing EBADF — which is exactly how an earlier version of this script came to
/// drop two thirds of the library and call it a clean bill of health. So: a pool per
/// call, both ends closed by hand, and a retry for good measure.
func run(_ args: [String]) -> Data {
    for attempt in 0 ..< 3 {
        let result: Data? = autoreleasepool {
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
            do { try p.run() } catch {
                if attempt == 2 { failures.record("\(error)") }
                return nil
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return data
        }
        if let result { return result }
        usleep(50_000 << attempt)
    }
    return Data()
}

/// ffmpeg piping WAV can't backfill the chunk sizes, so they arrive as 0xFFFFFFFF
/// and the payload is simply the rest of the stream.
func parseWav(_ data: Data) -> Audio? {
    let b = [UInt8](data)
    guard b.count > 44,
          b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,          // RIFF
          b[8] == 0x57, b[9] == 0x41, b[10] == 0x56, b[11] == 0x45         // WAVE
    else { return nil }

    func u32(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }
    func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }

    var off = 12, rate = 0, channels = 0
    while off + 8 <= b.count {
        let id = String(bytes: b[off ..< off + 4], encoding: .ascii) ?? ""
        var size = u32(off + 4)
        let body = off + 8
        if size < 0 || size > b.count - body { size = b.count - body }

        if id == "fmt ", size >= 16 {
            channels = u16(body + 2)
            rate = u32(body + 4)
        } else if id == "data" {
            guard rate > 0, channels > 0 else { return nil }
            let count = size / 4
            var samples = [Float](repeating: 0, count: count)
            data.withUnsafeBytes { raw in
                let base = raw.baseAddress!.advanced(by: body)
                for i in 0 ..< count {
                    samples[i] = Float(bitPattern: base.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
                }
            }
            return Audio(rate: rate, channels: channels, samples: samples)
        }
        off = body + size + (size % 2)
    }
    return nil
}

/// mp4 declares where its music ends — in an edit list, or in iTunSMPB — and the
/// FFmpeg CLI ignores that at the tail, decoding the encoder's padding along with
/// the music. MuonPlayer does not (`FFmpegDecoder`, `targetOutputFrames`), so a scan
/// that trusted the CLI would report a gap the app does not actually play. Seeking to
/// `duration - window` and taking exactly one window reproduces what the app hears.
func declaredDuration(_ path: String) -> Double? {
    let ext = (path as NSString).pathExtension.lowercased()
    guard ["m4a", "mp4", "m4b", "alac"].contains(ext) else { return nil }
    let out = run(["ffprobe", "-v", "error", "-select_streams", "a:0",
                   "-show_entries", "stream=duration", "-of", "csv=p=0:nk=1", path])
    return Double(String(decoding: out, as: UTF8.self)
        .trimmingCharacters(in: CharacterSet(charactersIn: ", \n\r")))
}

/// The first or last `windowMs` of a file, decoded at its native rate — resampling
/// would round off the very discontinuity we are looking for.
func decodeEdge(_ path: String, tail: Bool) -> Audio? {
    let window = opts.windowMs / 1000
    let seconds = String(format: "%.3f", window)
    var args = ["ffmpeg", "-v", "error", "-nostdin"]
    if tail {
        if let duration = declaredDuration(path), duration > window {
            args += ["-ss", String(format: "%.6f", duration - window), "-i", path, "-t", seconds]
        } else {
            args += ["-sseof", "-\(seconds)", "-i", path]
        }
    } else {
        args += ["-i", path, "-t", seconds]
    }
    args += ["-map", "0:a:0", "-c:a", "pcm_f32le", "-f", "wav", "-"]

    if let audio = parseWav(run(args)), audio.frames > 0 { return audio }
    guard tail else { return nil }

    // -sseof needs a seekable, duration-carrying container. When it comes back
    // empty, decode the file and keep the end.
    guard let whole = parseWav(run(["ffmpeg", "-v", "error", "-nostdin", "-i", path,
                                    "-map", "0:a:0", "-c:a", "pcm_f32le", "-f", "wav", "-"]))
    else { return nil }
    let want = min(whole.frames, Int(opts.windowMs / 1000 * Double(whole.rate)))
    let from = (whole.frames - want) * whole.channels
    return Audio(rate: whole.rate, channels: whole.channels, samples: Array(whole.samples[from...]))
}

// MARK: - What the edge of a file looks like

struct Edge {
    let audio: Audio
    /// Silence at the seam-facing end of the window, in ms.
    let silenceMs: Double
    /// Loudness of the 20 ms of music that sits against that silence — or against
    /// the file boundary, when there is none. This is what tells a hard cut from
    /// a fade-out.
    let levelDb: Double
}

func dB(_ rms: Double) -> Double { rms <= 1e-9 ? -120 : 20 * log10(rms) }

func analyse(_ audio: Audio, tail: Bool) -> Edge {
    let blockFrames = max(1, audio.rate / 1000)                 // 1 ms
    let blocks = stride(from: 0, to: audio.frames, by: blockFrames).map { start -> Double in
        let end = min(start + blockFrames, audio.frames)
        var sum = 0.0
        for f in start ..< end {
            for c in 0 ..< audio.channels {
                let v = Double(audio.samples[f * audio.channels + c])
                sum += v * v
            }
        }
        let n = Double((end - start) * audio.channels)
        return n > 0 ? (sum / n).squareRoot() : 0
    }
    // Walk from the seam inwards. Reversing the tail's blocks means "index 0 is
    // the sample nearest the seam" for both sides, and the rest of the function
    // needn't care which side it is on.
    let inward = tail ? Array(blocks.reversed()) : blocks

    let silent = inward.prefix { dB($0) < opts.silenceDb }.count
    let musicStart = silent
    let level = inward.dropFirst(musicStart).prefix(20)          // 20 ms of music
    let rms = level.isEmpty ? 0 : (level.map { $0 * $0 }.reduce(0, +) / Double(level.count)).squareRoot()

    return Edge(audio: audio, silenceMs: Double(silent), levelDb: dB(rms))
}

/// How violently the waveform jumps when the two files are played back to back,
/// measured against how violently the music is already jumping either side of the
/// seam. Music full of transients earns a bigger allowance than a sustained note.
func splice(_ a: Audio, _ b: Audio) -> (ratio: Double, step: Double)? {
    guard a.rate == b.rate, a.channels == b.channels, a.frames > 64, b.frames > 64 else { return nil }
    let look = min(a.rate / 50, min(a.frames, b.frames))         // 20 ms

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

// MARK: - Verdict

enum Kind: String {
    case flow                 // seamless, and it sounds seamless
    case click                // seamless, but the splice ticks
    case gap                  // meant to be seamless; encoder padding got in the way
}

struct Finding {
    let album: Album
    let from: Track
    let to: Track
    let wrap: Bool
    let kind: Kind
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
    var isLoud: Bool { levelDb >= opts.loudDb }
}

func judge(_ seam: Seam, tail: Audio, head: Audio) -> Finding? {
    let album = seam.album
    let a = album.tracks[seam.from], b = album.tracks[seam.to]
    let tailEdge = analyse(tail, tail: true)
    let headEdge = analyse(head, tail: false)

    let hardCut = tailEdge.levelDb > opts.minEdgeDb && headEdge.levelDb > opts.minEdgeDb
    guard hardCut else { return nil }                        // a fade either side: an ordinary boundary

    let gap = tailEdge.silenceMs + headEdge.silenceMs
    var note = ""
    var kind: Kind
    var ratio = 0.0, step = 0.0

    if gap <= opts.gapMs {
        kind = .flow
        if tail.rate != head.rate || tail.channels != head.channels {
            note = "\(tail.rate)/\(tail.channels)ch → \(head.rate)/\(head.channels)ch, not compared"
        } else if let s = splice(tail, head) {
            ratio = s.ratio
            step = s.step
            if ratio >= opts.clickRatio, step >= opts.clickAbs { kind = .click }
        }
    } else if gap <= opts.padMs {
        kind = .gap
        note = a.isLossy || b.isLossy ? "\(a.codec) encoder padding" : "\(a.codec), cut short"
    } else {
        return nil                                           // a real pause between the tracks
    }

    return Finding(album: album, from: a, to: b, wrap: seam.wrap, kind: kind,
                   tailDb: tailEdge.levelDb, headDb: headEdge.levelDb,
                   gapMs: gap, ratio: ratio, step: step, note: note)
}

// MARK: - Run

let all = readTracks().filter { t in
    guard let f = opts.filter else { return true }
    return t.path.range(of: f, options: .caseInsensitive) != nil
}
let library = albums(from: all)
guard !library.isEmpty else {
    FileHandle.standardError.write("no albums to scan\n".data(using: .utf8)!)
    exit(0)
}

// One unit of work per seam, not per album: a seam's two decodes are needed by no
// other seam, so a flat fan-out keeps every core busy to the last file instead of
// trailing a single long album.
let work = library.flatMap(seams(of:))

let lock = NSLock()
var findings: [Finding] = []
var done = 0
let isTTY = isatty(FileHandle.standardError.fileDescriptor) == 1
let slots = DispatchSemaphore(value: opts.jobs)

DispatchQueue.concurrentPerform(iterations: work.count) { s in
    slots.wait()
    defer { slots.signal() }

    let seam = work[s]
    let a = seam.album.tracks[seam.from], b = seam.album.tracks[seam.to]

    var finding: Finding?
    if let tail = decodeEdge(a.path, tail: true), let head = decodeEdge(b.path, tail: false),
       tail.frames > 0, head.frames > 0 {
        finding = judge(seam, tail: tail, head: head)
    }

    lock.lock()
    if let finding { findings.append(finding) }
    done += 1
    if isTTY, !opts.json, done % 8 == 0 {
        FileHandle.standardError.write("\r\u{1B}[K[\(done)/\(work.count)] \(seam.album.album)"
            .data(using: .utf8)!)
    }
    lock.unlock()
}
if isTTY, !opts.json { FileHandle.standardError.write("\r\u{1B}[K".data(using: .utf8)!) }

// A scan that skipped files silently would report a library cleaner than it is.
if failures.count > 0 {
    FileHandle.standardError.write("""
    WARNING: \(failures.count) of \(work.count * 2) decodes did not run (\(failures.last)).
    The report below is INCOMPLETE — those seams were never looked at.

    """.data(using: .utf8)!)
}

// MARK: - Report

func label(_ t: Track) -> String {
    t.number > 0 ? String(format: "%02d", t.number) : (t.path as NSString).lastPathComponent
}

// MARK: - HTML report

func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

/// One page, no assets, opens anywhere. Albums are ranked by their loudest seam,
/// because that is the order in which a person would want to hear them.
func html(_ findings: [Finding], albums: Int) -> String {
    let groups = Dictionary(grouping: findings) { "\($0.album.directory)\u{1}\($0.album.disc)" }
        .values
        .map { $0.sorted { ($0.from.number, $0.from.path) < ($1.from.number, $1.from.path) } }
        .sorted { a, b in
            let (la, lb) = (a.contains(where: \.isLoud), b.contains(where: \.isLoud))
            if la != lb { return la }
            return (a[0].album.artist, a[0].album.album) < (b[0].album.artist, b[0].album.album)
        }

    let loud = findings.filter(\.isLoud)
    let broken = findings.filter { $0.kind != .flow }
    let loudAlbums = groups.filter { $0.contains(where: \.isLoud) }.count
    func percent(_ n: Int) -> String {
        albums == 0 ? "—" : String(format: "%.0f%%", Double(n) / Double(albums) * 100)
    }

    var rows = ""
    for group in groups {
        let a = group[0].album
        let isLoud = group.contains(where: \.isLoud)
        let chips = group.map { f -> String in
            let cls = f.kind == .click ? "click" : f.kind == .gap ? "gap" : (f.isLoud ? "loud" : "quiet")
            let arrow = f.wrap ? "↻" : "→"
            let no = { (t: Track) in t.number > 0 ? String(t.number) : "•" }
            let detail = f.kind == .gap
                ? String(format: "%.0f ms of silence", f.gapMs)
                : String(format: "step %.1f×", f.ratio)
            let title = String(format: "%@ %@ %@  —  %.0f dB, %@%@",
                               escape(f.from.title), arrow, escape(f.to.title),
                               f.levelDb, detail, f.note.isEmpty ? "" : ", \(escape(f.note))")
            return "<span class=\"chip \(cls)\" title=\"\(title)\">\(no(f.from))\(arrow)\(no(f.to))</span>"
        }.joined()

        let codecs = Set(group.map(\.from.codec)).sorted().joined(separator: "/")
        rows += """
        <tr data-loud="\(isLoud)" data-broken="\(group.contains { $0.kind != .flow })">
          <td class="artist">\(escape(a.artist.isEmpty ? "—" : a.artist))</td>
          <td class="album">\(escape(a.album.isEmpty ? "—" : a.album))\(a.disc > 1 ? " <em>disc \(a.disc)</em>" : "")
              <div class="path">\(escape(a.directory))</div></td>
          <td class="seams">\(chips)</td>
          <td class="codec">\(escape(codecs))</td>
        </tr>

        """
    }

    return """
    <!doctype html>
    <meta charset="utf-8">
    <title>Gapless transitions</title>
    <style>
      :root { color-scheme: light dark; --bg:#fff; --fg:#1a1a1a; --dim:#767676; --line:#e3e3e3;
              --loud:#8b2fc9; --quiet:#9a9a9a; --gap:#b26a00; --click:#c62828; --card:#fafafa; }
      @media (prefers-color-scheme: dark) {
        :root { --bg:#16161a; --fg:#e8e8ea; --dim:#8e8e96; --line:#2c2c33;
                --loud:#c58af9; --quiet:#70707a; --gap:#e2a03f; --click:#ff6b6b; --card:#1d1d22; }
      }
      body { margin:0; padding:2.5rem 1.5rem; background:var(--bg); color:var(--fg);
             font:15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
      main { max-width:1100px; margin:0 auto; }
      h1 { font-size:1.5rem; margin:0 0 .25rem; }
      .sub { color:var(--dim); margin:0 0 1.5rem; }
      .stats { display:flex; gap:.75rem; flex-wrap:wrap; margin-bottom:1.5rem; }
      .stat { background:var(--card); border:1px solid var(--line); border-radius:10px;
              padding:.6rem .9rem; min-width:5.5rem; }
      .stat b { display:block; font-size:1.35rem; }
      .stat i { font-style:normal; color:var(--dim); font-size:.95rem; }
      .stat span { color:var(--dim); font-size:.8rem; }
      .controls { margin-bottom:1rem; color:var(--dim); font-size:.9rem; }
      .controls label { margin-right:1rem; }
      table { width:100%; border-collapse:collapse; }
      th { text-align:left; font-size:.75rem; text-transform:uppercase; letter-spacing:.06em;
           color:var(--dim); border-bottom:1px solid var(--line); padding:.5rem .6rem; font-weight:600; }
      td { padding:.6rem; border-bottom:1px solid var(--line); vertical-align:top; }
      .artist { font-weight:600; white-space:nowrap; }
      .album em { color:var(--dim); font-style:normal; font-size:.85em; }
      .path { color:var(--dim); font-size:.72rem; margin-top:.15rem; word-break:break-all; }
      .codec { color:var(--dim); font-size:.8rem; white-space:nowrap; }
      .seams { line-height:2; }
      .chip { display:inline-block; padding:.05rem .45rem; margin:0 .25rem .25rem 0; border-radius:999px;
              font:600 12px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace; cursor:help;
              border:1px solid transparent; }
      .chip.loud  { background:color-mix(in srgb, var(--loud) 16%, transparent); color:var(--loud);
                    border-color:color-mix(in srgb, var(--loud) 35%, transparent); }
      .chip.quiet { color:var(--quiet); border-color:var(--line); }
      .chip.gap   { background:color-mix(in srgb, var(--gap) 16%, transparent); color:var(--gap);
                    border-color:color-mix(in srgb, var(--gap) 40%, transparent); }
      .chip.click { background:color-mix(in srgb, var(--click) 16%, transparent); color:var(--click);
                    border-color:color-mix(in srgb, var(--click) 40%, transparent); }
      .legend { margin-top:2rem; color:var(--dim); font-size:.85rem; }
      .legend .chip { cursor:default; }
      tr.hide { display:none; }
    </style>
    <main>
      <h1>Gapless transitions</h1>
      <p class="sub">Where one track runs straight into the next — \(albums) albums scanned.
         Hover a seam for its level and detail.</p>

      <div class="stats">
        <div class="stat"><b>\(albums)</b><span>albums in the library</span></div>
        <div class="stat"><b>\(groups.count) <i>\(percent(groups.count))</i></b><span>with any seam</span></div>
        <div class="stat"><b>\(loudAlbums) <i>\(percent(loudAlbums))</i></b><span>with a loud seam</span></div>
        <div class="stat"><b>\(loud.count)</b><span>loud seams</span></div>
        <div class="stat"><b>\(findings.count - loud.count)</b><span>quiet seams</span></div>
        <div class="stat"><b>\(broken.count)</b><span>broken</span></div>
      </div>

      <div class="controls">
        <label><input type="checkbox" id="onlyLoud"> only albums with a loud seam</label>
        <label><input type="checkbox" id="onlyBroken"> only albums with a broken seam</label>
      </div>

      <table>
        <thead><tr><th>Artist</th><th>Album</th><th>Transitions</th><th>Format</th></tr></thead>
        <tbody>
    \(rows)    </tbody>
      </table>

      <p class="legend">
        <span class="chip loud">3→4</span> loud — both sides at \(Int(opts.loudDb)) dB or above, the ones you notice &nbsp;
        <span class="chip quiet">3→4</span> quiet — a real seam, but a gentle one &nbsp;
        <span class="chip gap">3→4</span> broken by encoder padding &nbsp;
        <span class="chip click">3→4</span> the edges do not meet: a click &nbsp;
        <span class="chip quiet">10↻1</span> the album's loop back to track one
      </p>
    </main>
    <script>
      const rows = [...document.querySelectorAll('tbody tr')];
      const loud = document.getElementById('onlyLoud');
      const broken = document.getElementById('onlyBroken');
      const apply = () => rows.forEach(r => r.classList.toggle('hide',
        (loud.checked && r.dataset.loud !== 'true') ||
        (broken.checked && r.dataset.broken !== 'true')));
      loud.onchange = broken.onchange = apply;
    </script>
    """
}

if opts.json {
    let rows = findings.map { f -> [String: Any] in
        [
            "kind": f.kind.rawValue,
            "artist": f.album.artist, "album": f.album.album, "directory": f.album.directory,
            "from": f.from.path, "to": f.to.path,
            "fromNo": f.from.number, "toNo": f.to.number,
            "fromTitle": f.from.title, "toTitle": f.to.title,
            "disc": f.album.disc,
            "wrap": f.wrap,
            "codec": f.from.codec,
            "tailDb": f.tailDb, "headDb": f.headDb,
            "levelDb": f.levelDb, "loud": f.isLoud,
            "gapMs": f.gapMs, "stepRatio": f.ratio, "step": f.step,
            "note": f.note,
        ]
    }
    let data = try! JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    exit(0)
}

if opts.html {
    print(html(findings, albums: library.count))
    exit(0)
}

let byAlbum = Dictionary(grouping: findings) { "\($0.album.directory)\u{1}\($0.album.disc)" }
var albumsWithSeams = 0

for key in byAlbum.keys.sorted() {
    let group = byAlbum[key]!.sorted { $0.from.path < $1.from.path }
    let broken = group.filter { $0.kind != .flow }
    guard opts.verbose || !broken.isEmpty else { albumsWithSeams += 1; continue }
    albumsWithSeams += 1

    let a = group[0].album
    print("\n\(a.artist) — \(a.album)  [\(a.directory)]")
    for f in group where opts.verbose || f.kind != .flow {
        let tag: String
        switch f.kind {
        case .flow: tag = "flow "
        case .click: tag = "CLICK"
        case .gap: tag = "GAP  "
        }
        var line = String(format: "  %@ %@ %@ %@   tail %.0f dB  head %.0f dB",
                          tag, label(f.from), f.wrap ? "↻" : "→", label(f.to), f.tailDb, f.headDb)
        if f.kind == .gap {
            line += String(format: "  silence %.0f ms", f.gapMs)
        } else if f.ratio > 0 {
            line += String(format: "  step %.1f× (%.3f)", f.ratio, f.step)
        }
        if !f.note.isEmpty { line += "  — \(f.note)" }
        print(line)
    }
}

let clicks = findings.filter { $0.kind == .click }.count
let gaps = findings.filter { $0.kind == .gap }.count
let loudCount = findings.filter(\.isLoud).count
let loudAlbums = Set(findings.filter(\.isLoud).map { "\($0.album.directory)\u{1}\($0.album.disc)" }).count
func percent(_ n: Int) -> String {
    library.isEmpty ? "—" : String(format: "%.0f%%", Double(n) / Double(library.count) * 100)
}
print("""

\(library.count) albums — \(albumsWithSeams) (\(percent(albumsWithSeams))) have a seam, \
\(loudAlbums) (\(percent(loudAlbums))) have a loud one
\(findings.count) seamless transitions: \(loudCount) loud, \(findings.count - loudCount) quiet — \
\(clicks) with a click, \(gaps) broken by encoder padding
""")
if !opts.verbose, clicks + gaps == 0 { print("(nothing broken; --verbose lists the clean seams)") }
