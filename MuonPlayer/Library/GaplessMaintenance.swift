import Foundation

/// Whether a repair is also written into the files themselves.
///
/// Trimming at playback fixes the seam for Muon and nothing else. Writing the header
/// fixes the file for every player there is — at the cost of the app rewriting the
/// user's music unasked, and it can only ever work for MP3 (see CLAUDE.md: m4a already
/// carries the truth, and a FLAC/Opus gap is real silence no header takes back).
enum GaplessFixMode: String, CaseIterable, Sendable {
    case playbackOnly       // default: trim at decode, never touch a file
    case rewriteSourceFiles // ...and write the LAME header into MP3s, so other players get it too

    static let key = "gaplessFixMode"

    static var current: GaplessFixMode {
        Prefs.string(forKey: key).flatMap(GaplessFixMode.init) ?? .playbackOnly
    }

    var label: String {
        switch self {
        case .playbackOnly: return "Fix during playback"
        case .rewriteSourceFiles: return "Also repair the files"
        }
    }
}

/// Finds the album seams that are broken and closes them.
///
/// Runs after the library scan, off the main actor: the scan is what the user is waiting
/// for, and this is not. A track is measured once — the file's mtime is recorded against
/// it — so an ordinary relaunch does nothing at all, and only a file that actually changed
/// is looked at again. A first pass over a 12.7k-track library takes ~13 s.
///
/// Not `.background`, which sounds right and is not: that QoS is confined to the
/// efficiency cores, and it turned those 13 seconds into nine minutes.
enum GaplessMaintenance {
    struct Album {
        let directory: String
        let tracks: [Database.SeamTrack]
    }

    /// A run of files that play one after another: one directory, one album tag, one
    /// disc. Cross-disc seams are not a thing, and a directory holding two albums is two
    /// runs, not one. (The same grouping the `MuonGapless` CLI uses.)
    static func albums(from tracks: [Database.SeamTrack]) -> [Album] {
        var groups: [String: [Database.SeamTrack]] = [:]
        for t in tracks {
            let dir = (t.path as NSString).deletingLastPathComponent
            groups["\(dir)\u{1}\(t.album)\u{1}\(t.disc)", default: []].append(t)
        }
        return groups.values.compactMap { group in
            guard group.count >= 2, let first = group.first else { return nil }
            let sorted = group.sorted {
                if $0.number != $1.number, $0.number > 0, $1.number > 0 { return $0.number < $1.number }
                return $0.path < $1.path
            }
            return Album(directory: (first.path as NSString).deletingLastPathComponent,
                         tracks: sorted)
        }
    }

    /// An album is stale if any of its files has changed since the seam scan last looked
    /// — a retagged track shifts nothing, but a re-ripped one moves the seam either side
    /// of it, so the whole run is measured again rather than the one file.
    static func isStale(_ album: Album) -> Bool {
        album.tracks.contains { t in
            guard let checked = t.checkedMtime else { return true }
            return abs(checked - t.mtime) >= 1
        }
    }

    static func seams(of album: Album) -> [(from: Int, to: Int)] {
        let n = album.tracks.count
        var out = (0 ..< n - 1)
            .filter { i in
                let a = album.tracks[i], b = album.tracks[i + 1]
                if a.number > 0, b.number > 0 { return b.number == a.number + 1 }
                return true
            }
            .map { (from: $0, to: $0 + 1) }
        if n >= 3 { out.append((from: n - 1, to: 0)) }   // an album written to loop
        return out
    }

    // MARK: - Run

    static func run(database: Database, mode: GaplessFixMode = .current) async {
        let log = GaplessLog.shared
        let all = await database.seamTracks()
        let stale = albums(from: all).filter(isStale)

        guard !stale.isEmpty else { return }
        log.log("scan: \(stale.count) album(s) to check of \(all.count) tracks — mode \(mode.rawValue)")

        let thresholds = SeamThresholds()
        var checked = 0, broken = 0

        // A sliding window, not a barrier per batch: albums differ wildly in length, and
        // waiting for the slowest of each group before starting the next left most lanes
        // idle. `.utility` rather than `.background` — the latter is confined to the
        // efficiency cores, which turned a 9-second job into a nine-minute one.
        let lanes = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        var next = stale.makeIterator()
        var pending: [(path: String, trim: GaplessTrim, mtime: Double)] = []

        await withTaskGroup(of: [(path: String, trim: GaplessTrim, mtime: Double)].self) { group in
            for _ in 0 ..< lanes {
                guard let album = next.next() else { break }
                group.addTask { measure(album, thresholds, log) }
            }

            while let result = await group.next() {
                checked += result.count
                broken += result.filter { !$0.trim.isEmpty }.count
                pending.append(contentsOf: result)

                // Written as we go, so a run cut short by a quit still counts: the tracks
                // it did measure carry their mtime and are not measured again.
                if pending.count >= 512 {
                    await database.setGaplessTrims(pending)
                    pending.removeAll(keepingCapacity: true)
                }

                if Task.isCancelled { break }
                if let album = next.next() {
                    group.addTask { measure(album, thresholds, log) }
                }
            }
        }
        if !pending.isEmpty { await database.setGaplessTrims(pending) }

        let trims = await database.gaplessTrims()
        GaplessTrims.shared.replaceAll(trims)
        log.log("scan: \(checked) tracks measured, \(broken) need a trim; "
            + "\(trims.count) track(s) now trimmed at playback")

        if mode == .rewriteSourceFiles {
            await rewriteMP3s(database: database, trims: trims, log)
        }
    }

    /// Measure one album: decode each track's two edges once, judge every seam, and turn
    /// the broken ones into per-track trims. Every track of the album comes back, trim or
    /// no trim — a track measured and found clean must be recorded as such, or it would
    /// be measured again on every launch forever.
    private static func measure(_ album: Album, _ t: SeamThresholds,
                                _ log: GaplessLog) -> [(path: String, trim: GaplessTrim, mtime: Double)] {
        var heads: [Int: EdgeAudio] = [:], tails: [Int: EdgeAudio] = [:]

        for (i, track) in album.tracks.enumerated() {
            do {
                // Untrimmed on purpose: the measurement is of the file as it is, not as a
                // previous run decided to play it.
                let decoder = try EdgeDecoder(path: track.path)
                if let h = decoder.head(ms: t.windowMs), h.frames > 0 { heads[i] = h }
                if let tl = decoder.tail(ms: t.windowMs), tl.frames > 0 { tails[i] = tl }
            } catch {
                log.log("decode failed: \(track.path) — \(error)")
            }
        }

        var trims: [String: GaplessTrim] = [:]
        for track in album.tracks { trims[track.path] = GaplessTrim(head: 0, tail: 0) }

        for seam in seams(of: album) {
            guard let tail = tails[seam.from], let head = heads[seam.to] else { continue }
            let a = album.tracks[seam.from], b = album.tracks[seam.to]

            guard let verdict = SeamScan.judge(tail: tail, head: head,
                                               tailLossy: isLossy(a.codec), headLossy: isLossy(b.codec),
                                               codec: a.codec, t),
                  verdict.kind == .gap
            else { continue }

            switch SeamScan.repair(tail: tail, head: head, t) {
            case .trim(let tailTrim, let headTrim):
                trims[a.path]?.tail = tailTrim
                trims[b.path]?.head = headTrim
                log.log(String(format: "gap %.0f ms — trim %d from tail of %@, %d from head of %@",
                               verdict.gapMs, tailTrim, name(a.path), headTrim, name(b.path)))
            case .refused(let why):
                log.log("gap left alone between \(name(a.path)) and \(name(b.path)): \(why)")
            }
        }

        return album.tracks.compactMap { track in
            guard let trim = trims[track.path] else { return nil }
            return (path: track.path, trim: trim, mtime: track.mtime)
        }
    }

    private static func isLossy(_ codec: String) -> Bool {
        !["flac", "alac", "wavpack", "ape", "tta"].contains(codec)
            && !codec.hasPrefix("pcm_")
    }

    private static func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    // MARK: - Writing the repair into the files

    /// FFmpeg's own mp3 decoder delay, which a LAME header's `delay` is understood to sit
    /// on top of. It skips `delay + 529` at the head.
    private static let decoderDelay = 529

    /// Write the measured trim into each MP3's Xing/LAME header, so that every player —
    /// not just this one — hears the seam closed. Audio frames and ID3 tags are copied
    /// byte for byte; only the header frame is rewritten (`TagWriter.writeMP3Gapless`).
    ///
    /// A file that now carries its own trim must stop being trimmed again at playback, or
    /// the second trim would cut into the music. So a rewritten file's measurement is
    /// cleared the moment the write is verified.
    private static func rewriteMP3s(database: Database, trims: [String: GaplessTrim],
                                    _ log: GaplessLog) async {
        let targets = trims.filter { path, trim in
            !trim.isEmpty && (path as NSString).pathExtension.lowercased() == "mp3"
        }
        guard !targets.isEmpty else { return }

        let backups = backupDirectory()
        log.log("rewrite: \(targets.count) MP3(s); backups in \(backups.path)")

        for (path, trim) in targets {
            guard rewriteMP3(at: path, trim: trim, backupsIn: backups, log) else { continue }

            // A file that now carries its own trim must stop being trimmed again at
            // playback, or the second trim would cut into the music.
            let mtime = (try? URL(fileURLWithPath: path)
                .resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate?.timeIntervalSince1970) ?? 0 ?? 0
            await database.clearGaplessTrim(path: path, mtime: mtime)
            GaplessTrims.shared.set(GaplessTrim(head: 0, tail: 0), for: path)
        }
    }

    /// Rewrite one MP3's header to carry `trim`, backing the original up first and putting
    /// it straight back if the result does not decode the way it was promised to.
    /// Returns whether the file now carries the trim.
    @discardableResult
    static func rewriteMP3(at path: String, trim: GaplessTrim,
                           backupsIn backups: URL, _ log: GaplessLog) -> Bool {
        let url = URL(fileURLWithPath: path)
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let existing = TagWriter.readMP3Gapless(data)

            // Read against what FFmpeg *already* takes off this file, so a header that is
            // present and lying gets corrected rather than added to.
            let alreadyHead = existing.map { $0.delay + decoderDelay } ?? 0
            let alreadyTail = existing.map { $0.frames > 0 ? max(0, $0.padding - decoderDelay) : 0 } ?? 0

            let delay = alreadyHead + trim.head - decoderDelay
            let padding = alreadyTail + trim.tail + decoderDelay
            guard (0 ... 4095).contains(delay), (0 ... 4095).contains(padding) else {
                log.log("rewrite skipped \(name(path)): delay \(delay) / padding \(padding) out of range")
                return false
            }

            // The header frame shifts everything behind it, so there is nothing smaller
            // than the whole file worth keeping.
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
            let backup = backups.appendingPathComponent(UUID().uuidString + ".mp3")
            try FileManager.default.copyItem(at: url, to: backup)

            try TagWriter.writeMP3Gapless(delay: delay, padding: padding, to: url)

            // Verify by decoding the result: the silence we just described should be gone.
            // Anything else and the file goes back exactly as it was.
            guard let check = try? EdgeDecoder(path: path),
                  let head = check.head(ms: 200), let tail = check.tail(ms: 200),
                  SeamScan.bounds(head).lead < 16, SeamScan.bounds(tail).trail < 16
            else {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.copyItem(at: backup, to: url)
                log.log("rewrite FAILED, restored: \(name(path))")
                return false
            }

            log.log("rewrote \(name(path)): delay \(delay), padding \(padding) "
                + "(was \(existing.map { "\($0.delay)/\($0.padding)" } ?? "no header")); "
                + "backup \(backup.lastPathComponent)")
            return true
        } catch {
            log.log("rewrite failed \(name(path)): \(error)")
            return false
        }
    }

    private static func backupDirectory() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return support.appendingPathComponent("GaplessBackups/\(stamp)", isDirectory: true)
    }
}
