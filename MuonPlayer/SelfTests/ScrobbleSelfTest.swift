import Foundation

/// Launch-time self-test for the scrobble pipeline: inserts a scrobble into
/// SQLite, flushes to Last.fm, and confirms the row flips to is_scrobbled only
/// after acceptance. Gated by MUON_SCROBBLE_TEST.
@MainActor
enum ScrobbleSelfTest {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["MUON_SCROBBLE_TEST"] != nil }

    static func run(scrobbler: ScrobbleService, database: Database) async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let title = ProcessInfo.processInfo.environment["MUON_SCROBBLE_TITLE"] ?? "Muon Probe"
        let ts = Int(Date().timeIntervalSince1970) - 60

        let before = await database.pendingScrobbleCount()
        await database.insertScrobble(artist: "Muon Test", album: "Gapless Test",
                                      title: title, timestamp: ts, duration: 200)
        NSLog("SCROBBLETEST: inserted '\(title)' ts=\(ts), pending before=\(before)")

        scrobbler.flush()

        // Wait for the pending count to drop back (row accepted → is_scrobbled=1).
        var accepted = false
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(500))
            let pending = await database.pendingScrobbleCount()
            if pending <= before { accepted = true; break }
        }

        let report = "title=\(title)\naccepted=\(accepted)\npending_after=\(await database.pendingScrobbleCount())\n"
        try? report.write(to: docs.appendingPathComponent("scrobble.done"), atomically: true, encoding: .utf8)
        NSLog("SCROBBLETEST: accepted=\(accepted)")
    }
}
