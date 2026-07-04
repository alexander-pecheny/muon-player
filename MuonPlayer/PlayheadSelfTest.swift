import Foundation

/// Launch-time self-test for the normal-mode playhead. Reproduces: start a track
/// from an album that sorts *after* another album in the same artist folder, and
/// confirm "Next Up" is the album's own next track — not the artist folder's
/// second track. Guards the regression where the anchor was matched by value
/// (random-id) equality and never found, snapping the playhead to index 0.
///
/// Gated by MUON_PLAYHEADTEST.
@MainActor
enum PlayheadSelfTest {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["MUON_PLAYHEADTEST"] != nil }

    static func run(player: Player, library: LibraryStore) async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let all = await library.allTracks()

        // The "Drifter" album is the anchor's album; "1993" sorts before it in the
        // artist folder, so a broken playhead would surface a 1993 track as next.
        let drifter = all.filter { $0.album == "Drifter" }
            .sorted { ($0.trackNo ?? 0) < ($1.trackNo ?? 0) }
        guard let anchor = drifter.first, drifter.count >= 2 else {
            try? "missing Drifter tracks (found \(drifter.count) of ≥2)"
                .write(to: docs.appendingPathComponent("playhead.done"), atomically: true, encoding: .utf8)
            return
        }
        let expectedNext = drifter[1]

        player.mode = .normal
        // Context is a *separate* fetch (as the album view would pass) — different
        // Track instances than artistFolderTracks returns.
        player.play(track: anchor, context: drifter)
        // Let the async rebuildTimeline (artist-folder upgrade) settle.
        try? await Task.sleep(for: .seconds(2))
        let next = player.nextUpTrack
        player.stop()

        let pass = next?.url == expectedNext.url
        let report = """
        mode=normal
        anchor=\(anchor.title) (album=\(anchor.album ?? "?"))
        expected next=\(expectedNext.title) (album=\(expectedNext.album ?? "?"))
        actual   next=\(next?.title ?? "nil") (album=\(next?.album ?? "?"))
        RESULT=\(pass ? "PASS" : "FAIL")

        """
        try? report.write(to: docs.appendingPathComponent("playhead.done"), atomically: true, encoding: .utf8)
        NSLog("PLAYHEADTEST:\n\(report)")
    }
}
