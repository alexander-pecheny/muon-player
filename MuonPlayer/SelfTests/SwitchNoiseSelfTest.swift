import Foundation

/// Launch-time self-test that reproduces the *manual* track-switch path
/// (tapping one track after another, i.e. `player.play(track:context:)` →
/// `beginPlayback`) while recording the real mixer output. The capture can then
/// be analysed for the "white noise" burst the user reports at each switch.
///
/// Gated by MUON_SWITCHTEST so it never runs in normal use.
@MainActor
enum SwitchNoiseSelfTest {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["MUON_SWITCHTEST"] != nil }

    static func run(player: Player, library: LibraryStore) async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        NSLog("SWITCHTEST: starting")

        let all = await library.allTracks()
        func track(_ name: String) -> Track? {
            all.first { $0.url.lastPathComponent.lowercased() == "\(name).m4a" }
        }
        guard let a = track("ta"), let b = track("tb"), let c = track("tc") else {
            NSLog("SWITCHTEST: missing ta/tb/tc, found \(all.count) tracks")
            try? "missing-tracks".write(to: docs.appendingPathComponent("switch.done"), atomically: true, encoding: .utf8)
            return
        }
        let ctx = [a, b, c]

        let capture = docs.appendingPathComponent("switch.caf")
        try? FileManager.default.removeItem(at: capture)
        player.startCapture(to: capture)

        // ~1s of silence first so the capture has a clean noise floor to compare against.
        try? await Task.sleep(for: .milliseconds(1000))
        player.play(track: a, context: ctx)              // start
        try? await Task.sleep(for: .milliseconds(1500))
        player.play(track: b, context: ctx)              // manual switch #1
        try? await Task.sleep(for: .milliseconds(1500))
        player.play(track: c, context: ctx)              // manual switch #2
        try? await Task.sleep(for: .milliseconds(1500))
        player.play(track: a, context: ctx)              // manual switch #3
        try? await Task.sleep(for: .milliseconds(1500))

        player.stop()
        player.stopCapture()
        try? "capture=switch.caf\napprox_switches_s=1.0,2.5,4.0,5.5\n"
            .write(to: docs.appendingPathComponent("switch.done"), atomically: true, encoding: .utf8)
        NSLog("SWITCHTEST: done at \(capture.path)")
    }
}
