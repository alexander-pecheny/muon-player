//
//  muon-albumartist — fold a family of album-artist strings into one.
//
//  A featured guest belongs in the *artist* tag, not the album-artist: writing
//  "SOULOUD feat. THOMAS MRAZ" into album_artist splits the artist's discography
//  into one entry per collaborator. This rewrites album_artist in the files
//  themselves for every track whose current album-artist starts with a prefix,
//  leaving the per-track artist tag untouched.
//
//  It must be compiled together with the app's tag writer, which does the
//  in-place edit without re-encoding:
//
//    swiftc -O scripts/muon-albumartist.swift MuonPlayer/Library/TagWriter.swift \
//      -o /tmp/muon-albumartist
//    /tmp/muon-albumartist --prefix SOULOUD            # dry run (default)
//    /tmp/muon-albumartist --prefix SOULOUD --apply
//
//  The library picks the change up on its next scan, because writing a file
//  changes its mtime.
//

import Foundation
import SQLite3

/// Mirrors the app's TagEdits; only `albumArtist` is ever set here. Declared
/// locally so this script needs no part of the app but TagWriter itself.
struct TagEdits: Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var trackNo: Int?
    var composer: String?
    var year: Int?
}

struct Options {
    var db: String = NSHomeDirectory()
        + "/Library/Containers/me.pecheny.muonplayer/Data/Library/Application Support/muon-library.sqlite"
    var prefix = ""
    /// What to write. Defaults to the prefix itself.
    var target: String?
    var apply = false
}

func parseOptions() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--prefix": o.prefix = it.next() ?? ""
        case "--set": o.target = it.next()
        case "--db": o.db = it.next() ?? o.db
        case "--apply": o.apply = true
        case "--dry-run": o.apply = false
        case "--help", "-h":
            print("""
            muon-albumartist — rewrite album_artist for every track whose album-artist
            starts with a prefix.

              --prefix TEXT   match album-artists starting with TEXT (required)
              --set TEXT      what to write (default: the prefix)
              --apply         write the tags (default: dry run)
              --db PATH       library database
            """)
            exit(0)
        default:
            FileHandle.standardError.write("unknown argument: \(arg)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    guard !o.prefix.isEmpty else {
        FileHandle.standardError.write("--prefix is required\n".data(using: .utf8)!)
        exit(2)
    }
    return o
}

/// Paths whose effective album-artist starts with `prefix`, with that album-artist.
///
/// "Effective" mirrors the app's own grouping: a user tag override wins, then the
/// file's album_artist, then its artist — which is what the Artists list shows and
/// therefore what the user asked to merge.
func matchingTracks(db path: String, prefix: String) -> [(path: String, albumArtist: String)] {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        FileHandle.standardError.write("cannot open database at \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    defer { sqlite3_close(handle) }

    let sql = """
    SELECT path, COALESCE(NULLIF(ov_album_artist,''), NULLIF(album_artist,''),
                          NULLIF(ov_artist,''), NULLIF(artist,''), '') AS aa
    FROM tracks WHERE aa LIKE ? || '%' ORDER BY aa, path
    """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
        FileHandle.standardError.write("query failed\n".data(using: .utf8)!)
        exit(1)
    }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, prefix, -1, unsafeBitCast(-1 as Int, to: sqlite3_destructor_type.self))

    var rows: [(String, String)] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
        rows.append((text(0), text(1)))
    }
    return rows
}

func short(_ p: String) -> String {
    let home = NSHomeDirectory()
    return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
}

@main
enum MuonAlbumArtist {
    static func main() {
        let options = parseOptions()
        let target = options.target ?? options.prefix
        let rows = matchingTracks(db: options.db, prefix: options.prefix)
        let changing = rows.filter { $0.albumArtist != target }

        print(options.apply ? "muon-albumartist — APPLYING"
                            : "muon-albumartist — dry run (no files will be written)")
        print("album artists starting with \"\(options.prefix)\" → \"\(target)\"\n")

        var byArtist: [String: Int] = [:]
        for row in changing { byArtist[row.albumArtist, default: 0] += 1 }
        for (artist, count) in byArtist.sorted(by: { $0.key < $1.key }) {
            print("  \(artist)  (\(count) track\(count == 1 ? "" : "s"))")
        }
        let alreadyRight = rows.count - changing.count
        print("\n\(changing.count) file(s) to rewrite across \(byArtist.count) album artist(s)"
              + (alreadyRight > 0 ? ", \(alreadyRight) already correct" : ""))

        guard options.apply else {
            print("\nDry run. Re-run with --apply to write the tags.")
            return
        }

        var written = 0
        var failed = 0
        for row in changing {
            let url = URL(fileURLWithPath: row.path)
            guard FileManager.default.fileExists(atPath: row.path) else {
                print("missing \(short(row.path))")
                failed += 1
                continue
            }
            var edits = TagEdits()
            edits.albumArtist = target
            do {
                try TagWriter.write(edits, to: url)
                written += 1
            } catch {
                print("FAILED \(short(row.path)) — \(error)")
                failed += 1
            }
        }
        print("\nwrote \(written) file(s)" + (failed > 0 ? ", \(failed) failed" : ""))
        print("Rescan the library (relaunch the app) to see the merge.")
    }
}
