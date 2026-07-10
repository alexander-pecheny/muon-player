#!/usr/bin/env swift
//
//  muon-dedup — remove redundant copies of albums from the music library.
//
//  Two folders hold the same album when they carry the same album-artist/album
//  tags, the same number of tracks, and every track's duration lines up. That last
//  rule is what makes this safe to automate: a remaster, a live take or a different
//  edit shifts each track by its own amount. The lower-quality copy is removed and
//  the better one kept.
//
//  "Lines up" means bit-identical lengths — to within a sample — for two copies in
//  the same format. When the formats differ, one copy is a transcode of the other
//  and is uniformly longer by the encoder's priming delay: Opus prepends 312
//  samples of preskip, AAC 2112 of priming. So across formats the durations may
//  differ by a *shared* offset (up to --max-offset-ms), as long as every track
//  shares it (to within --offset-spread-ms). Two copies in the same format never
//  get that latitude, so a uniformly-longer remaster is still never touched.
//
//  Nothing is deleted without --apply, and even then folders go to the Trash, so
//  every decision is reversible.
//
//  Usage:
//    swift scripts/muon-dedup.swift                  # dry run (default)
//    swift scripts/muon-dedup.swift --apply          # move losers to the Trash
//    swift scripts/muon-dedup.swift --verbose        # show the kept copy too
//    swift scripts/muon-dedup.swift --max-offset-ms 0   # exact lengths only
//    swift scripts/muon-dedup.swift --db /path/to/muon-library.sqlite
//

import Foundation
import SQLite3

// MARK: - Options

struct Options {
    var db: String = NSHomeDirectory()
        + "/Library/Containers/me.pecheny.muonplayer/Data/Library/Application Support/muon-library.sqlite"
    var apply = false
    var verbose = false
    var json = false
    var rescueArt = false
    var toleranceSamples = 1.0
    var sampleRate = 44_100.0
    /// Largest shared offset two differently-encoded copies may have, in ms. Zero
    /// demands identical lengths of every copy, whatever its format.
    var maxOffsetMs = 100.0
    /// How much the per-track offsets of two differently-encoded copies may
    /// disagree, in ms. A real encoder delay is constant to the sample; this only
    /// absorbs the rounding in the durations the demuxers report.
    var offsetSpreadMs = 2.0
    /// Directories that must never be trashed, whatever the grouping says.
    var protected: [String] = []

    /// Two durations are "the same" within this many seconds.
    var tolerance: TimeInterval { toleranceSamples / sampleRate }
    var maxOffset: TimeInterval { maxOffsetMs / 1000 }
    var offsetSpread: TimeInterval { offsetSpreadMs / 1000 }
}

func parseOptions() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--apply": o.apply = true
        case "--dry-run": o.apply = false
        case "--verbose", "-v": o.verbose = true
        case "--json": o.json = true
        case "--rescue-art": o.rescueArt = true
        case "--db": o.db = it.next() ?? o.db
        case "--tolerance-samples": o.toleranceSamples = Double(it.next() ?? "") ?? o.toleranceSamples
        case "--sample-rate": o.sampleRate = Double(it.next() ?? "") ?? o.sampleRate
        case "--max-offset-ms": o.maxOffsetMs = Double(it.next() ?? "") ?? o.maxOffsetMs
        case "--offset-spread-ms": o.offsetSpreadMs = Double(it.next() ?? "") ?? o.offsetSpreadMs
        case "--protect": if let p = it.next() { o.protected.append(p) }
        case "--help", "-h":
            print("""
            muon-dedup — drop redundant copies of albums, keeping the best quality one.

              --dry-run              report only (default)
              --apply                move the redundant folders to the Trash
              --verbose              also show which copy is kept
              --json                 emit the plan as JSON (implies dry run)
              --rescue-art           copy cover art the keeper lacks before trashing
              --tolerance-samples N  same-format duration match tolerance (default 1)
              --sample-rate N        samples per second for the tolerance (default 44100)
              --max-offset-ms N      encoder delay allowed across formats (default 100, 0 disables)
              --offset-spread-ms N   how much per-track offsets may disagree (default 2)
              --db PATH              library database
              --protect PATH         never trash this directory (repeatable)
            """)
            exit(0)
        default:
            FileHandle.standardError.write("unknown argument: \(arg)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    return o
}

// MARK: - Library model

struct Track {
    let path: String
    let duration: TimeInterval
    let codec: String
    let bitrate: Int
    let albumArtist: String
    let album: String
}

/// One physical copy of an album: a directory whose entire audio subtree belongs
/// to a single album (so a multi-disc release is one unit, not one per disc).
struct AlbumCopy {
    let directory: String
    let tracks: [Track]
    let albumArtist: String
    let album: String

    var durations: [TimeInterval] { tracks.map(\.duration).sorted() }
    var codecs: Set<String> { Set(tracks.map(\.codec)) }
    var isLossless: Bool { tracks.allSatisfy { Self.losslessCodecs.contains($0.codec) } }
    var averageBitrate: Double {
        let rates = tracks.map { Double($0.bitrate) }
        return rates.isEmpty ? 0 : rates.reduce(0, +) / Double(rates.count)
    }
    var codecSummary: String { Set(tracks.map(\.codec)).sorted().joined(separator: "/") }

    static let losslessCodecs: Set<String> = [
        "flac", "alac", "wavpack", "ape", "tta",
        "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "pcm_f32be", "pcm_s16be", "pcm_u8",
    ]

    /// Higher is better: lossless wins outright, then bitrate. Ties break on path
    /// so a run is deterministic.
    func isBetterThan(_ other: AlbumCopy) -> Bool {
        if isLossless != other.isLossless { return isLossless }
        if abs(averageBitrate - other.averageBitrate) > 1 { return averageBitrate > other.averageBitrate }
        return directory < other.directory
    }
}

// MARK: - Database

func readTracks(db path: String) -> [Track] {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        FileHandle.standardError.write("cannot open database at \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    defer { sqlite3_close(handle) }

    // Mirror the app's override-aware grouping (ov_* columns hold user tag edits).
    let sql = """
    SELECT path, duration, COALESCE(codec,''), COALESCE(bitrate,0),
           COALESCE(NULLIF(ov_album_artist,''), NULLIF(album_artist,''),
                    NULLIF(ov_artist,''), NULLIF(artist,''), '') AS aa,
           COALESCE(NULLIF(ov_album,''), NULLIF(album,''), '') AS al
    FROM tracks
    WHERE duration IS NOT NULL AND duration > 0
    """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
        FileHandle.standardError.write("query failed\n".data(using: .utf8)!)
        exit(1)
    }
    defer { sqlite3_finalize(stmt) }

    var tracks: [Track] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        func text(_ i: Int32) -> String {
            sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
        }
        tracks.append(Track(path: text(0),
                            duration: sqlite3_column_double(stmt, 1),
                            codec: text(2),
                            bitrate: Int(sqlite3_column_int64(stmt, 3)),
                            albumArtist: text(4),
                            album: text(5)))
    }
    return tracks
}

// MARK: - Grouping

typealias AlbumKey = String
func key(_ artist: String, _ album: String) -> AlbumKey { artist + "\u{1}" + album }

/// What it takes to decide whether two piles of audio are the same recordings:
/// how long each track is, and what it was encoded with.
struct Shape {
    let durations: [TimeInterval]
    let codecs: Set<String>
}

/// The rule for "these two hold the same recordings", and the only place the
/// duration tolerances are interpreted.
struct MatchRule {
    let tolerance: TimeInterval
    let maxOffset: TimeInterval
    let spread: TimeInterval

    /// Same track count, and the sorted durations line up.
    ///
    /// Copies sharing a format must agree to within `tolerance` — two rips of one
    /// CD are the same length to the sample. Copies in *different* formats are a
    /// transcode and its source, and a lossy encoder prepends the same priming
    /// delay to every track, so they may differ by one shared offset instead.
    /// Withholding that latitude from same-format pairs is what keeps a uniformly
    /// longer remaster from being mistaken for a copy.
    func sameRecordings(_ a: Shape, _ b: Shape) -> Bool {
        guard a.durations.count == b.durations.count, !a.durations.isEmpty else { return false }
        let deltas = zip(a.durations, b.durations).map { $0 - $1 }
        let lo = deltas.min()!, hi = deltas.max()!

        guard a.codecs != b.codecs, maxOffset > 0 else { return max(hi, -lo) <= tolerance }
        return hi - lo <= spread && abs((lo + hi) / 2) <= maxOffset
    }
}

/// The shape of the audio directly in each leaf folder under `dir`.
func leafShapes(under dir: String, byLeaf: [String: [Track]]) -> [Shape] {
    byLeaf.compactMap { leaf, ts in
        guard leaf == dir || leaf.hasPrefix(dir + "/") else { return nil }
        return Shape(durations: ts.map(\.duration).sorted(), codecs: Set(ts.map(\.codec)))
    }
}

/// The highest ancestor of `directory` whose whole audio subtree is still this one
/// album — but never one that has swallowed two *copies* of it.
///
/// A `Disc 1` / `Disc 2` pair must collapse to the album folder above them, so the
/// discs are always kept or dropped together. Two sibling rips of the same album
/// must not: they are exactly what we are here to compare. The two cases are told
/// apart by their durations — discs hold different recordings, copies hold the
/// same ones.
func albumUnit(for directory: String,
               key wanted: AlbumKey,
               keysUnder: [String: Set<AlbumKey>],
               byLeaf: [String: [Track]],
               rule: MatchRule) -> String {
    var unit = directory
    while true {
        let parent = (unit as NSString).deletingLastPathComponent
        guard parent != unit, parent != "/", !parent.isEmpty else { return unit }
        guard let keys = keysUnder[parent], keys == [wanted] else { return unit }

        let leaves = leafShapes(under: parent, byLeaf: byLeaf)
        var holdsTwoCopies = false
        for i in leaves.indices {
            for j in leaves.indices where j > i {
                if rule.sameRecordings(leaves[i], leaves[j]) { holdsTwoCopies = true }
            }
        }
        if holdsTwoCopies { return unit }
        unit = parent
    }
}

func buildCopies(_ tracks: [Track], rule: MatchRule) -> [AlbumCopy] {
    // Untitled albums are not a single album — never fold them together.
    let usable = tracks.filter { !$0.album.isEmpty && !$0.albumArtist.isEmpty }

    var keysUnder: [String: Set<AlbumKey>] = [:]
    for t in usable {
        var dir = (t.path as NSString).deletingLastPathComponent
        let k = key(t.albumArtist, t.album)
        while !dir.isEmpty, dir != "/" {
            keysUnder[dir, default: []].insert(k)
            dir = (dir as NSString).deletingLastPathComponent
        }
    }
    // Directories holding files from more than one album can never be a copy, and
    // must not be climbed into.
    var byLeaf: [String: [Track]] = [:]
    for t in usable {
        byLeaf[(t.path as NSString).deletingLastPathComponent, default: []].append(t)
    }

    var unitTracks: [String: [Track]] = [:]
    for (leaf, ts) in byLeaf {
        guard let keys = keysUnder[leaf], keys.count == 1, let k = keys.first else { continue }
        let unit = albumUnit(for: leaf, key: k, keysUnder: keysUnder,
                             byLeaf: byLeaf, rule: rule)
        unitTracks[unit, default: []].append(contentsOf: ts)
    }

    return unitTracks.compactMap { dir, ts in
        guard let first = ts.first else { return nil }
        return AlbumCopy(directory: dir, tracks: ts,
                         albumArtist: first.albumArtist, album: first.album)
    }
}

func isSameRecording(_ a: AlbumCopy, _ b: AlbumCopy, rule: MatchRule) -> Bool {
    rule.sameRecordings(Shape(durations: a.durations, codecs: a.codecs),
                        Shape(durations: b.durations, codecs: b.codecs))
}

// MARK: - Filesystem

func directorySize(_ path: String) -> (bytes: Int64, files: Int) {
    let url = URL(fileURLWithPath: path)
    guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
    else { return (0, 0) }
    var bytes: Int64 = 0
    var files = 0
    for case let f as URL in e {
        let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if v?.isRegularFile == true {
            bytes += Int64(v?.fileSize ?? 0)
            files += 1
        }
    }
    return (bytes, files)
}

func humanBytes(_ b: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: b)
}

/// Guard rails: refuse to trash anything shallow, a home-directory child, a
/// protected path, or a directory holding a file we mean to keep.
///
/// The keeper may legitimately sit *above* the folder being trashed — a nested
/// duplicate of a single, say — so it is not the directory paths that matter but
/// whether any surviving file lives inside the doomed one.
func isSafeToTrash(_ dir: String, keeper: AlbumCopy, protected: [String]) -> String? {
    let home = NSHomeDirectory()
    if dir == home { return "is the home directory" }
    if (dir as NSString).deletingLastPathComponent == home { return "is a top-level folder in $HOME" }
    if (dir as NSString).pathComponents.count < 4 { return "is too shallow" }
    if protected.contains(where: { dir == $0 || dir.hasPrefix($0 + "/") }) { return "is protected" }
    if keeper.directory == dir { return "is the copy we would keep" }
    if keeper.tracks.contains(where: { $0.path.hasPrefix(dir + "/") }) {
        return "holds tracks belonging to the copy we would keep"
    }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
        return "no longer exists"
    }
    return nil
}

/// Images inside `dir` (ignoring AppleDouble `._` sidecars).
func images(in dir: String) -> [URL] {
    let exts: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "bmp"]
    let url = URL(fileURLWithPath: dir)
    guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
    else { return [] }
    var found: [URL] = []
    for case let f as URL in e {
        guard (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              !f.lastPathComponent.hasPrefix("._"),
              exts.contains(f.pathExtension.lowercased()) else { continue }
        found.append(f)
    }
    return found
}

/// Copy any cover art the keeper does not already have, so trashing the
/// redundant folder never loses the only copy of an album's artwork. Existing
/// files are never overwritten.
@discardableResult
func rescueArt(from drop: String, to keep: String) -> [String] {
    let existing = Set(images(in: keep).map { $0.lastPathComponent.lowercased() })
    var copied: [String] = []
    for art in images(in: drop) where !existing.contains(art.lastPathComponent.lowercased()) {
        let dest = URL(fileURLWithPath: keep).appendingPathComponent(art.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: dest.path) else { continue }
        do {
            try FileManager.default.copyItem(at: art, to: dest)
            copied.append(dest.lastPathComponent)
        } catch {
            print("  art copy FAILED \(art.lastPathComponent): \(error.localizedDescription)")
        }
    }
    return copied
}

// MARK: - Main

let options = parseOptions()
let rule = MatchRule(tolerance: options.tolerance,
                     maxOffset: options.maxOffset,
                     spread: options.offsetSpread)
let tracks = readTracks(db: options.db)
let copies = buildCopies(tracks, rule: rule)

var byAlbum: [AlbumKey: [AlbumCopy]] = [:]
for c in copies { byAlbum[key(c.albumArtist, c.album), default: []].append(c) }

struct Removal {
    let keep: AlbumCopy
    let drop: AlbumCopy
    let bytes: Int64
    let files: Int
    let extraFiles: Int
}

var removals: [Removal] = []
var skipped: [(String, String)] = []

for (_, group) in byAlbum where group.count > 1 {
    // Partition the copies of this album into sets that are the same recording.
    var remaining = group.sorted { $0.directory < $1.directory }
    while let head = remaining.first {
        remaining.removeFirst()
        var cluster = [head]
        remaining.removeAll { candidate in
            if isSameRecording(head, candidate, rule: rule) {
                cluster.append(candidate)
                return true
            }
            return false
        }
        guard cluster.count > 1 else { continue }

        // max(by:) wants "is ordered before", i.e. "is worse than".
        let keeper = cluster.max(by: { a, b in b.isBetterThan(a) })!
        for loser in cluster where loser.directory != keeper.directory {
            if let reason = isSafeToTrash(loser.directory, keeper: keeper, protected: options.protected) {
                skipped.append((loser.directory, reason))
                continue
            }
            let (bytes, files) = directorySize(loser.directory)
            removals.append(Removal(keep: keeper, drop: loser, bytes: bytes, files: files,
                                    extraFiles: max(0, files - loser.tracks.count)))
        }
    }
}

removals.sort { $0.bytes > $1.bytes }

if options.json {
    func obj(_ c: AlbumCopy) -> [String: Any] {
        ["dir": c.directory, "tracks": c.tracks.count, "codecs": c.codecSummary,
         "lossless": c.isLossless, "bitrate": Int(c.averageBitrate),
         "durations": c.durations, "paths": c.tracks.map(\.path).sorted()]
    }
    let plan: [String: Any] = [
        "tolerance_seconds": options.tolerance,
        "max_offset_seconds": options.maxOffset,
        "offset_spread_seconds": options.offsetSpread,
        "removals": removals.map { r -> [String: Any] in
            ["album": r.drop.album, "album_artist": r.drop.albumArtist,
             "bytes": r.bytes, "files": r.files, "extra_files": r.extraFiles,
             "drop": obj(r.drop), "keep": obj(r.keep)]
        },
        "skipped": skipped.map { ["dir": $0.0, "reason": $0.1] },
        "total_bytes": removals.reduce(Int64(0)) { $0 + $1.bytes },
    ]
    let data = try! JSONSerialization.data(withJSONObject: plan, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    exit(0)
}

let home = NSHomeDirectory()
func short(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }

print(options.apply ? "muon-dedup — APPLYING (folders go to the Trash)" : "muon-dedup — dry run (nothing will be deleted)")
print("database: \(short(options.db))")
print(String(format: "match rule: same album tags, same track count, every duration within %.1f sample(s) (%.1f µs)",
             options.toleranceSamples, options.tolerance * 1e6))
if options.maxOffsetMs > 0 {
    print(String(format: "            across formats, a shared offset up to %.0f ms (spread ≤ %.1f ms) is allowed",
                 options.maxOffsetMs, options.offsetSpreadMs))
}
print("albums scanned: \(byAlbum.count), album copies on disk: \(copies.count)\n")

if removals.isEmpty {
    print("No redundant copies found.")
} else {
    for r in removals {
        print("\(r.drop.albumArtist) — \(r.drop.album)")
        print("  drop  \(short(r.drop.directory))")
        print("        \(r.drop.tracks.count) tracks · \(r.drop.codecSummary) · \(Int(r.drop.averageBitrate / 1000)) kbps · \(humanBytes(r.bytes))"
              + (r.extraFiles > 0 ? " · +\(r.extraFiles) non-audio file(s)" : ""))
        if options.verbose {
            let (kb, _) = directorySize(r.keep.directory)
            print("  keep  \(short(r.keep.directory))")
            print("        \(r.keep.tracks.count) tracks · \(r.keep.codecSummary) · \(Int(r.keep.averageBitrate / 1000)) kbps · \(humanBytes(kb))")
        }
    }
    print("")
}

if !skipped.isEmpty {
    print("Skipped (safety):")
    for (dir, why) in skipped { print("  \(short(dir)) — \(why)") }
    print("")
}

let total = removals.reduce(Int64(0)) { $0 + $1.bytes }
print("\(removals.count) folder(s), \(removals.reduce(0) { $0 + $1.files }) file(s), \(humanBytes(total)) reclaimable")

guard options.apply else {
    print("\nDry run. Re-run with --apply to move these folders to the Trash.")
    exit(0)
}

var trashed = 0
var freed: Int64 = 0
for r in removals {
    // Re-check right before acting: the dry run may have been long ago.
    if let reason = isSafeToTrash(r.drop.directory, keeper: r.keep, protected: options.protected) {
        print("skip \(short(r.drop.directory)) — \(reason)")
        continue
    }
    if options.rescueArt {
        let copied = rescueArt(from: r.drop.directory, to: r.keep.directory)
        if !copied.isEmpty {
            print("  rescued art -> \(short(r.keep.directory)): \(copied.joined(separator: ", "))")
        }
    }
    do {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: r.drop.directory), resultingItemURL: nil)
        trashed += 1
        freed += r.bytes
        print("trashed \(short(r.drop.directory))")
    } catch {
        print("FAILED \(short(r.drop.directory)) — \(error.localizedDescription)")
    }
}
print("\nmoved \(trashed) folder(s) to the Trash, \(humanBytes(freed)) freed")
