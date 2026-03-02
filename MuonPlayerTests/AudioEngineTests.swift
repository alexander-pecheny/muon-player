import Testing
import Foundation
@testable import MuonPlayer

@Suite("AudioEngine Tests")
@MainActor
struct AudioEngineTests {

    private func makeTracks(count: Int) -> [Track] {
        (0..<count).map { i in
            Track(url: URL(fileURLWithPath: "/Music/track\(i).mp3"), title: "Track \(i)")
        }
    }

    @Test("Engine starts in idle state")
    func initialState() {
        let engine = AudioEngine()
        #expect(engine.currentTrack == nil)
        #expect(engine.isPlaying == false)
        #expect(engine.duration == 0)
        #expect(engine.playlist.isEmpty)
    }

    @Test("Next at last track stops playback")
    func nextAtEnd() {
        let engine = AudioEngine()
        let tracks = makeTracks(count: 3)

        engine.loadPlaylist(tracks, startingAt: 2)

        engine.next()

        #expect(engine.isPlaying == false)
        #expect(engine.currentTrack == nil)
    }

    @Test("Previous at first track stays at first track")
    func previousAtStart() {
        let engine = AudioEngine()
        let tracks = makeTracks(count: 3)

        engine.loadPlaylist(tracks, startingAt: 0)

        // Previous at start with currentTime < 3 should restart first track
        engine.previous()

        #expect(engine.currentIndex == 0)
    }

    @Test("Stop resets all state")
    func stopResetsState() {
        let engine = AudioEngine()
        engine.stop()

        #expect(engine.currentTrack == nil)
        #expect(engine.isPlaying == false)
        #expect(engine.duration == 0)
    }
}
