import Foundation

/// Launch-time self-test verifying that abandoning a track via a user action
/// (Next / Stop) still emits `onTrackFinished` with the real played time — the
/// event that queues a scrobble. Regression guard for the bug where manual skips
/// dropped the scrobble because only gapless/end-of-queue finishes reported.
///
/// Gated by MUON_SKIPTEST so it never runs in normal use.
@MainActor
enum SkipScrobbleSelfTest {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["MUON_SKIPTEST"] != nil }

    static func run(player: Player, library: LibraryStore) async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        NSLog("SKIPTEST: starting")

        let all = await library.allTracks()
        func track(_ name: String) -> Track? {
            all.first { $0.url.lastPathComponent.lowercased() == "\(name).m4a" }
        }
        guard let a = track("ta"), let b = track("tb"), let c = track("tc") else {
            try? "missing-tracks".write(to: docs.appendingPathComponent("skip.done"), atomically: true, encoding: .utf8)
            return
        }
        let ctx = [a, b, c]

        var finished: [String] = []
        let previous = player.onTrackFinished
        player.onTrackFinished = { t, played in
            finished.append("\(t.url.lastPathComponent) played=\(String(format: "%.2f", played))s")
        }

        // Explicit play() calls keep the outgoing track deterministic (unlike
        // next(), which walks the auto-built queue in folder order).
        player.play(track: a, context: ctx)
        try? await Task.sleep(for: .milliseconds(1500))
        player.seek(to: 3.0)                            // seek within A — must NOT report
        try? await Task.sleep(for: .milliseconds(1500))
        player.play(track: b, context: ctx)             // switch A→B → one ta event
        try? await Task.sleep(for: .seconds(2))
        player.play(track: c, context: ctx)             // switch B→C → one tb event
        try? await Task.sleep(for: .seconds(2))
        player.stop()                                   // stop during C → one tc event
        try? await Task.sleep(for: .milliseconds(300))

        player.onTrackFinished = previous
        let report = "onTrackFinished events (expect exactly ta, tb, tc in order — seek adds none):\n"
            + finished.joined(separator: "\n") + "\n"
        try? report.write(to: docs.appendingPathComponent("skip.done"), atomically: true, encoding: .utf8)
        NSLog("SKIPTEST: done\n\(report)")
    }
}
