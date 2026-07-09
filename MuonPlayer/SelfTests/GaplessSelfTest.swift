import Foundation

/// A launch-time self-test used to empirically verify gapless playback. Gated by
/// the MUON_SELFTEST environment variable so it never runs in normal use.
///
/// It records the real mixer output to a file while playing two sample-adjacent
/// tracks back-to-back, so the capture can be analyzed for a gap/discontinuity
/// at the track boundary.
@MainActor
enum GaplessSelfTest {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["MUON_SELFTEST"] != nil }
    static var ext: String { ProcessInfo.processInfo.environment["MUON_SELFTEST_EXT"] ?? "flac" }

    static func run(player: Player, library: LibraryStore) async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let ext = ext.lowercased()
        NSLog("SELFTEST: starting for .\(ext)")

        let all = await library.allTracks()
        // Match the two probe files by name (tA.<ext>, tB.<ext>) so this works
        // even when the encoder wrote no title/album metadata.
        func track(_ name: String) -> Track? {
            all.first { $0.url.lastPathComponent.lowercased() == "\(name).\(ext)" }
        }
        let pair = [track("ta"), track("tb")].compactMap { $0 }

        guard pair.count >= 2 else {
            NSLog("SELFTEST: need 2 tracks, found \(pair.count)")
            try? "no-tracks".write(to: docs.appendingPathComponent("selftest.done"), atomically: true, encoding: .utf8)
            return
        }

        let capture = docs.appendingPathComponent("capture-\(ext).caf")
        try? FileManager.default.removeItem(at: capture)

        let total = (pair[0].duration ?? 3) + (pair[1].duration ?? 3)
        player.startCapture(to: capture)
        player.play(track: pair[0], context: [pair[0], pair[1]])

        // Let both tracks play through, plus a tail.
        try? await Task.sleep(for: .seconds(total + 1.5))

        player.stop()
        player.stopCapture()

        let boundary = pair[0].duration ?? 3
        let report = "ext=\(ext)\nboundary=\(boundary)\ntotal=\(total)\ncapture=\(capture.lastPathComponent)\n"
        try? report.write(to: docs.appendingPathComponent("selftest.done"), atomically: true, encoding: .utf8)
        NSLog("SELFTEST: done, capture at \(capture.path)")
    }
}
