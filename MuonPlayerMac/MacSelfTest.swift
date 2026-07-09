import Foundation

/// Launch-time self-test for the macOS library + playback stack. Indexes the
/// folder named by `MUON_MACTEST_FOLDER`, plays its first track, and reports what
/// the scanner and the player actually produced.
///
/// It sets the library's roots directly rather than going through
/// `LibraryFolders`, because the security-scoped bookmark it persists can only be
/// minted from a folder the user picked in the open panel. The folder therefore
/// has to live somewhere the sandbox already allows — the app's own container.
///
/// Gated by MUON_MACTEST.
@MainActor
enum MacSelfTest {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["MUON_MACTEST"] != nil }

    static var folder: URL? {
        ProcessInfo.processInfo.environment["MUON_MACTEST_FOLDER"].map { URL(fileURLWithPath: $0) }
    }

    static func run(player: Player, library: LibraryStore) async {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let report = support.appendingPathComponent("mactest.done")

        guard let folder else {
            try? "no MUON_MACTEST_FOLDER".write(to: report, atomically: true, encoding: .utf8)
            return
        }

        await library.setRoots([LibraryRoot(folder)])
        let tracks = await library.allTracks()

        guard let first = tracks.first else {
            try? "indexed 0 tracks from \(folder.path)".write(to: report, atomically: true, encoding: .utf8)
            return
        }

        player.play(track: first, context: tracks)
        try? await Task.sleep(for: .seconds(3))

        let playing = player.isPlaying
        let time = player.currentTime
        let waveform = await WaveformStore.shared.waveform(for: first.url, duration: first.duration ?? 0)
        let folderScoped = await library.artistFolderTracks(for: first)
        // MUON_MACTEST_KEEP leaves a track loaded and playing, so the UI (and the
        // Space key monitor) can be driven afterwards.
        if ProcessInfo.processInfo.environment["MUON_MACTEST_KEEP"] == nil { player.stop() }

        let text = """
        folder=\(folder.path)
        indexed=\(tracks.count) tracks, \(library.albums.count) albums
        first=\(first.title) [\(first.formatDescription)]
        playing=\(playing) currentTime=\(String(format: "%.2f", time))
        waveformBars=\(waveform.count)
        artistFolderTracks=\(folderScoped.count)
        nextUp=\(player.nextUpTrack?.title ?? "nil")
        RESULT=\(playing && time > 0.5 && !waveform.isEmpty ? "PASS" : "FAIL")

        """
        try? text.write(to: report, atomically: true, encoding: .utf8)
        NSLog("MACTEST:\n\(text)")

        if keepPlaying { logPlaybackState(player: player, to: support) }
    }

    private static var keepPlaying: Bool {
        ProcessInfo.processInfo.environment["MUON_MACTEST_KEEP"] != nil
    }

    /// Continuously mirror `isPlaying` into a file so a UI test driving the
    /// keyboard can observe what the player actually did.
    private static func logPlaybackState(player: Player, to dir: URL) {
        let state = dir.appendingPathComponent("playstate.txt")
        Task { @MainActor in
            while true {
                let line = player.isPlaying ? "playing" : "paused"
                try? line.write(to: state, atomically: true, encoding: .utf8)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
}
