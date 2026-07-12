//
//  muon-gapless — find the album transitions that are meant to be seamless, and the
//  ones that are meant to be but aren't.
//
//  The judging lives in the app (`SeamScan`), and so does the decoding (`EdgeDecoder`);
//  this is the front end that reads the library, fans the work out and prints a report.
//
//  Usage:
//    muon-gapless                       # report
//    muon-gapless --verbose             # list every clean seam too
//    muon-gapless --json | --html
//    muon-gapless --filter "Pink Floyd"
//

import Foundation
import SQLite3

// MARK: - Options

struct Options {
    var db: String = NSHomeDirectory()
        + "/Library/Containers/me.pecheny.muonplayer/Data/Library/Application Support/muon-library.sqlite"
    /// Scan a folder straight off the disk instead of the library — for a folder the app
    /// has never indexed, which is what a backup or a fresh rip is.
    var folder: String?
    var json = false
    var html = false
    var verbose = false
    /// Only look at tracks whose path contains this (case-insensitive).
    var filter: String?
    var t = SeamThresholds()
    var jobs = ProcessInfo.processInfo.activeProcessorCount
    /// Write a before/after pair of clips for every seam the repair would close.
    var demo: String?
    /// How much music either side of the seam a clip carries.
    var demoMs = 2500.0
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
        case "--folder": o.folder = it.next()
        case "--filter": o.filter = it.next()
        case "--loud-db": o.t.loudDb = Double(it.next() ?? "") ?? o.t.loudDb
        case "--silence-db": o.t.silenceDb = Double(it.next() ?? "") ?? o.t.silenceDb
        case "--min-edge-db": o.t.minEdgeDb = Double(it.next() ?? "") ?? o.t.minEdgeDb
        case "--gap-ms": o.t.gapMs = Double(it.next() ?? "") ?? o.t.gapMs
        case "--pad-ms": o.t.padMs = Double(it.next() ?? "") ?? o.t.padMs
        case "--dip-db": o.t.dipDb = Double(it.next() ?? "") ?? o.t.dipDb
        case "--click-ratio": o.t.clickRatio = Double(it.next() ?? "") ?? o.t.clickRatio
        case "--click-abs": o.t.clickAbs = Double(it.next() ?? "") ?? o.t.clickAbs
        case "--window-ms": o.t.windowMs = Double(it.next() ?? "") ?? o.t.windowMs
        case "--jobs", "-j": o.jobs = Int(it.next() ?? "") ?? o.jobs
        case "--demo": o.demo = it.next()
        case "--demo-ms": o.demoMs = Double(it.next() ?? "") ?? o.demoMs
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
              --folder PATH       read this folder off the disk instead of the library
              --gap-ms N          silence at a seam still counted as flowing (default 10)
              --pad-ms N          silence between hard cuts read as encoder padding (default 60)
              --silence-db N      below this a block is silence (default -60)
              --min-edge-db N     the music at a seam must be this loud (default -50)
              --dip-db N          drop in the join that is heard as a tick (default 12)
              --click-ratio N     step at the splice vs. the music's own steps (default 8)
              --click-abs N       smallest step worth calling a click, 0..1 (default 0.02)
              --window-ms N       audio decoded from each side of a seam (default 500)
              --jobs, -j N        parallel album workers
              --demo DIR          for every seam the repair would close, write the two
                                  clips that let you hear it: the seam as it plays now,
                                  and the seam once the silence is skipped
              --demo-ms N         music either side of the seam in a clip (default 2500)
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

struct SeamTrack {
    let path: String
    let title: String
    let artist: String
    let album: String
    let codec: String
    let disc: Int
    let number: Int

    var directory: String { (path as NSString).deletingLastPathComponent }
    var isLossy: Bool { !SeamTrack.lossless.contains(codec) }

    static let lossless: Set<String> = [
        "flac", "alac", "wavpack", "ape", "tta",
        "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "pcm_f32be", "pcm_s16be", "pcm_u8",
    ]
}

func readTracks() -> [SeamTrack] {
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

    var out: [SeamTrack] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
        out.append(SeamTrack(path: text(0), title: text(1), artist: text(2), album: text(3),
                         codec: text(4),
                         disc: Int(sqlite3_column_int64(stmt, 5)),
                         number: Int(sqlite3_column_int64(stmt, 6))))
    }
    return out
}

/// Read a folder off the disk, with the app's own scanner and tag reader — so a folder
/// the library has never seen is grouped into albums exactly as the library would.
func readFolder(_ path: String) -> [SeamTrack] {
    let files = FileScanner(roots: [URL(fileURLWithPath: path)]).findAudioFiles()
    var out = [SeamTrack?](repeating: nil, count: files.count)

    out.withUnsafeMutableBufferPointer { buffer in
        let slots = DispatchSemaphore(value: opts.jobs)
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            slots.wait()
            defer { slots.signal() }

            let url = files[i]
            let m = FFmpegMetadata.read(url: url, includeArtwork: false)
            guard let duration = m.duration, duration > 0 else { return }
            buffer[i] = SeamTrack(
                path: url.path,
                title: m.title ?? url.deletingPathExtension().lastPathComponent,
                artist: m.albumArtist ?? m.artist ?? "",
                album: m.album ?? "",
                codec: m.codec ?? "",
                disc: m.discNo ?? 1,
                number: m.trackNo ?? 0)
        }
    }
    return out.compactMap { $0 }
}

/// A run of files that play one after another: one directory, one album tag, one disc.
/// Cross-disc seams are not a thing, and a directory holding two albums is two runs.
struct Album {
    let directory: String
    let artist: String
    let album: String
    let disc: Int
    let tracks: [SeamTrack]
}

func albums(from tracks: [SeamTrack]) -> [Album] {
    var groups: [String: [SeamTrack]] = [:]
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

/// Two tracks play back to back when they sit next to each other in the album and their
/// numbers agree with that (a folder missing track 4 has no 3→5 seam).
func isAdjacent(_ a: SeamTrack, _ b: SeamTrack) -> Bool {
    if a.number > 0, b.number > 0 { return b.number == a.number + 1 }
    return true
}

/// Every pair that can play back to back — including last→first, which an album written
/// to loop (Origami Angel's *Somewhere City*) joins as carefully as any seam inside it.
func seams(of album: Album) -> [(from: Int, to: Int, wrap: Bool)] {
    let n = album.tracks.count
    var out = (0 ..< n - 1)
        .filter { isAdjacent(album.tracks[$0], album.tracks[$0 + 1]) }
        .map { (from: $0, to: $0 + 1, wrap: false) }
    if n >= 3 { out.append((from: n - 1, to: 0, wrap: true)) }
    return out
}

// MARK: - Failures

/// Decodes that never happened. A scan that quietly skips a file reports a clean
/// library, which is worse than no scan at all, so this is counted and shouted about at
/// the end rather than swallowed.
final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    private(set) var last = ""

    func record(_ error: String) {
        lock.lock(); count += 1; last = error; lock.unlock()
    }
}
let failures = Failures()

// MARK: - Run

struct Finding {
    let album: Album
    let from: SeamTrack
    let to: SeamTrack
    let wrap: Bool
    let verdict: SeamVerdict

    var kind: SeamKind { verdict.kind }
    var isLoud: Bool { verdict.isLoud(opts.t) }
}

let all = (opts.folder.map(readFolder) ?? readTracks()).filter { t in
    guard let f = opts.filter else { return true }
    return t.path.range(of: f, options: .caseInsensitive) != nil
}
let library = albums(from: all)
guard !library.isEmpty else {
    FileHandle.standardError.write("no albums to scan\n".data(using: .utf8)!)
    exit(0)
}

// One unit of work per album, not per seam: a track's head is wanted by the seam before
// it and its tail by the seam after it, so decoding per album gets both from a single
// open of the file. Only an album's own windows are ever held at once, which is what
// keeps the whole library's worth of them from having to fit in memory.
let lock = NSLock()
var findings: [Finding] = []
var done = 0
let isTTY = isatty(FileHandle.standardError.fileDescriptor) == 1
let slots = DispatchSemaphore(value: opts.jobs)

DispatchQueue.concurrentPerform(iterations: library.count) { i in
    slots.wait()
    defer { slots.signal() }

    let album = library[i]
    let wanted = seams(of: album)
    var heads = [Int: EdgeAudio](), tails = [Int: EdgeAudio]()

    for (t, track) in album.tracks.enumerated() {
        let needsHead = wanted.contains { $0.to == t }
        let needsTail = wanted.contains { $0.from == t }
        guard needsHead || needsTail else { continue }
        do {
            let decoder = try EdgeDecoder(path: track.path)
            if needsHead, let h = decoder.head(ms: opts.t.windowMs), h.frames > 0 { heads[t] = h }
            if needsTail, let t2 = decoder.tail(ms: opts.t.windowMs), t2.frames > 0 { tails[t] = t2 }
        } catch {
            failures.record("\(track.path): \(error)")
        }
    }

    var found: [Finding] = []
    for seam in wanted {
        guard let tail = tails[seam.from], let head = heads[seam.to] else { continue }
        let a = album.tracks[seam.from], b = album.tracks[seam.to]
        guard let verdict = SeamScan.judge(tail: tail, head: head,
                                           tailLossy: a.isLossy, headLossy: b.isLossy,
                                           codec: a.codec, opts.t)
        else { continue }
        found.append(Finding(album: album, from: a, to: b, wrap: seam.wrap, verdict: verdict))
    }

    lock.lock()
    findings.append(contentsOf: found)
    done += 1
    if isTTY, !opts.json, !opts.html, done % 8 == 0 {
        FileHandle.standardError.write("\r\u{1B}[K[\(done)/\(library.count)] \(album.album)"
            .data(using: .utf8)!)
    }
    lock.unlock()
}
if isTTY, !opts.json, !opts.html { FileHandle.standardError.write("\r\u{1B}[K".data(using: .utf8)!) }

// A scan that skipped files silently would report a library cleaner than it is.
if failures.count > 0 {
    FileHandle.standardError.write("""
    WARNING: \(failures.count) files did not decode (\(failures.last)).
    The report below is INCOMPLETE — those seams were never looked at.

    """.data(using: .utf8)!)
}

// MARK: - Demo clips

/// A seam you can hear, twice: as it plays today, and as it plays once the stranded
/// silence is skipped. Nothing is written to the music — the repair is applied to the
/// decoded samples, which is exactly what the player does at playback.
///
/// The pair is deliberately the *same* audio, cut the same way, differing only by the
/// samples the trim takes out. Anything else and the demo would be arguing for itself.
enum Demo {
    /// 16-bit PCM. The clips are for a web page, where a float WAV is a needless doubling.
    static func wav(_ a: EdgeAudio, to url: URL) throws {
        var body = Data()
        body.reserveCapacity(a.samples.count * 2)
        for s in a.samples {
            let v = Int16(max(-32768, min(32767, (s * 32767).rounded())))
            withUnsafeBytes(of: v.littleEndian) { body.append(contentsOf: $0) }
        }

        var out = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }

        let channels = UInt16(a.channels), rate = UInt32(a.rate)
        out.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + body.count))
        out.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16)
        u16(1); u16(channels); u32(rate)
        u32(rate * UInt32(channels) * 2); u16(channels * 2); u16(16)
        out.append(contentsOf: Array("data".utf8)); u32(UInt32(body.count))
        out.append(body)
        try out.write(to: url)
    }

    static func join(_ a: EdgeAudio, _ b: EdgeAudio) -> EdgeAudio {
        EdgeAudio(rate: a.rate, channels: a.channels, samples: a.samples + b.samples)
    }

    static func dropTail(_ a: EdgeAudio, _ n: Int) -> EdgeAudio {
        EdgeAudio(rate: a.rate, channels: a.channels,
                  samples: Array(a.samples.prefix(max(0, a.frames - n) * a.channels)))
    }

    static func dropHead(_ a: EdgeAudio, _ n: Int) -> EdgeAudio {
        EdgeAudio(rate: a.rate, channels: a.channels,
                  samples: Array(a.samples.dropFirst(min(n, a.frames) * a.channels)))
    }

    /// The last `ms` of a window / the first `ms` of one — so the measurement is taken on
    /// exactly the 500 ms the scan uses, while the clip keeps the seconds around it.
    static func lastMs(_ a: EdgeAudio, _ ms: Double) -> EdgeAudio {
        let n = min(a.frames, Int(ms / 1000 * Double(a.rate)))
        return EdgeAudio(rate: a.rate, channels: a.channels,
                         samples: Array(a.samples.suffix(n * a.channels)))
    }

    static func firstMs(_ a: EdgeAudio, _ ms: Double) -> EdgeAudio {
        let n = min(a.frames, Int(ms / 1000 * Double(a.rate)))
        return EdgeAudio(rate: a.rate, channels: a.channels,
                         samples: Array(a.samples.prefix(n * a.channels)))
    }

    static func slug(_ s: String, _ limit: Int = 40) -> String {
        let ok = s.lowercased().map { c -> Character in
            c.isLetter || c.isNumber ? c : "-"
        }
        var out = String(ok)
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(out.prefix(limit)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

if let dir = opts.demo {
    let root = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let gaps = findings.filter { $0.kind == .gap }
    var manifest: [[String: Any]] = []
    var written = 0

    for f in gaps {
        // The long windows carry the seconds a listener needs; the scan's own 500 ms
        // windows are sliced back out of them, so the measurement is the same one the
        // player would make.
        guard let dA = try? EdgeDecoder(path: f.from.path),
              let dB = try? EdgeDecoder(path: f.to.path),
              let longTail = dA.tail(ms: opts.demoMs), let longHead = dB.head(ms: opts.demoMs),
              longTail.rate == longHead.rate, longTail.channels == longHead.channels
        else { continue }

        let tail = Demo.lastMs(longTail, opts.t.windowMs)
        let head = Demo.firstMs(longHead, opts.t.windowMs)

        guard case .trim(let tailTrim, let headTrim) = SeamScan.repair(tail: tail, head: head, opts.t),
              tailTrim + headTrim > 0
        else { continue }

        let name = "\(Demo.slug(f.album.artist))--\(Demo.slug(f.album.album))"
            + String(format: "--%02d-%02d", f.from.number, f.to.number)

        let before = Demo.join(longTail, longHead)
        let after = Demo.join(Demo.dropTail(longTail, tailTrim), Demo.dropHead(longHead, headTrim))

        do {
            try Demo.wav(before, to: root.appendingPathComponent("\(name)--before.wav"))
            try Demo.wav(after, to: root.appendingPathComponent("\(name)--after.wav"))
        } catch {
            FileHandle.standardError.write("demo write failed for \(name): \(error)\n".data(using: .utf8)!)
            continue
        }
        written += 1

        let rate = Double(longTail.rate)
        manifest.append([
            "id": name,
            "artist": f.album.artist, "album": f.album.album,
            "fromTitle": f.from.title, "toTitle": f.to.title,
            "fromNo": f.from.number, "toNo": f.to.number,
            "codec": f.from.codec,
            "silenceMs": f.verdict.gapMs,
            "levelDb": f.verdict.levelDb, "loud": f.isLoud,
            "trimmedTailSamples": tailTrim, "trimmedHeadSamples": headTrim,
            "trimmedMs": Double(tailTrim + headTrim) / rate * 1000,
            "sampleRate": longTail.rate,
            "before": "\(name)--before.wav", "after": "\(name)--after.wav",
        ])
    }

    let data = try! JSONSerialization.data(withJSONObject: manifest,
                                           options: [.prettyPrinted, .sortedKeys])
    try? data.write(to: root.appendingPathComponent("manifest.json"))
    FileHandle.standardError.write(
        "\(written) seam(s) rendered to \(dir) (of \(gaps.count) gap seams)\n".data(using: .utf8)!)
}

// MARK: - Report

func label(_ t: SeamTrack) -> String {
    t.number > 0 ? String(format: "%02d", t.number) : (t.path as NSString).lastPathComponent
}

func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

/// One page, no assets, opens anywhere. Albums are ranked by their loudest seam, because
/// that is the order in which a person would want to hear them.
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
            let cls = f.kind == .click || f.kind == .hole ? "click"
                : f.kind == .gap ? "gap" : (f.isLoud ? "loud" : "quiet")
            let arrow = f.wrap ? "↻" : "→"
            let no = { (t: SeamTrack) in t.number > 0 ? String(t.number) : "•" }
            let detail = f.kind == .gap
                ? String(format: "%.0f ms of silence", f.verdict.gapMs)
                : String(format: "step %.1f×", f.verdict.ratio)
            let title = String(format: "%@ %@ %@  —  %.0f dB, %@%@",
                               escape(f.from.title), arrow, escape(f.to.title),
                               f.verdict.levelDb, detail,
                               f.verdict.note.isEmpty ? "" : ", \(escape(f.verdict.note))")
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
        <span class="chip loud">3→4</span> loud — both sides at \(Int(opts.t.loudDb)) dB or above, the ones you notice &nbsp;
        <span class="chip quiet">3→4</span> quiet — a real seam, but a gentle one &nbsp;
        <span class="chip gap">3→4</span> broken by encoder padding &nbsp;
        <span class="chip click">3→4</span> a click: the edges do not meet, or the sound drops away in the join &nbsp;
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
            "tailDb": f.verdict.tailDb, "headDb": f.verdict.headDb,
            "levelDb": f.verdict.levelDb, "loud": f.isLoud,
            "gapMs": f.verdict.gapMs, "stepRatio": f.verdict.ratio, "step": f.verdict.step,
            "note": f.verdict.note,
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
        case .hole: tag = "HOLE "
        case .gap: tag = "GAP  "
        }
        var line = String(format: "  %@ %@ %@ %@   tail %.0f dB  head %.0f dB",
                          tag, label(f.from), f.wrap ? "↻" : "→", label(f.to),
                          f.verdict.tailDb, f.verdict.headDb)
        if f.kind == .gap {
            line += String(format: "  silence %.0f ms", f.verdict.gapMs)
        } else if f.verdict.ratio > 0 {
            line += String(format: "  step %.1f× (%.3f)", f.verdict.ratio, f.verdict.step)
        }
        if !f.verdict.note.isEmpty { line += "  — \(f.verdict.note)" }
        print(line)
    }
}

let clicks = findings.filter { $0.kind == .click }.count
let holes = findings.filter { $0.kind == .hole }.count
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
\(clicks) with a click, \(holes) with a hole, \(gaps) broken by encoder padding
""")
if !opts.verbose, clicks + gaps == 0 { print("(nothing broken; --verbose lists the clean seams)") }
