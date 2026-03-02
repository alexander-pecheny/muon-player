import Testing
import Foundation
@testable import MuonPlayer

@Suite("Track Tests")
struct TrackTests {

    @Test("Track initializes with display name from URL filename")
    func trackDisplayNameFromURL() {
        let url = URL(fileURLWithPath: "/Music/Artist/Album/My Song.mp3")
        let track = Track(url: url)

        #expect(track.title == "My Song")
        #expect(track.artist == nil)
        #expect(track.duration == nil)
        #expect(track.format == .mp3)
    }

    @Test("Track uses provided title over filename")
    func trackExplicitTitle() {
        let url = URL(fileURLWithPath: "/Music/track01.m4a")
        let track = Track(url: url, title: "Custom Title", artist: "Custom Artist", duration: 180)

        #expect(track.title == "Custom Title")
        #expect(track.artist == "Custom Artist")
        #expect(track.duration == 180)
        #expect(track.format == .m4a)
    }

    @Test("Track detects all supported formats", arguments: [
        ("file.mp3", AudioFormat.mp3),
        ("file.m4a", AudioFormat.m4a),
        ("file.aac", AudioFormat.aac),
        ("file.aif", AudioFormat.aif),
        ("file.aiff", AudioFormat.aiff),
        ("file.wav", AudioFormat.wav),
        ("file.caf", AudioFormat.caf),
    ])
    func trackFormats(filename: String, expected: AudioFormat) {
        let url = URL(fileURLWithPath: "/Music/\(filename)")
        let track = Track(url: url)
        #expect(track.format == expected)
    }

    @Test("Track has unique ID")
    func trackUniqueID() {
        let url = URL(fileURLWithPath: "/Music/song.mp3")
        let track1 = Track(url: url)
        let track2 = Track(url: url)
        #expect(track1.id != track2.id)
    }

    @Test("Display name strips path extension")
    func displayNameStripsExtension() {
        let url = URL(fileURLWithPath: "/path/to/song.name.mp3")
        let name = Track.displayName(from: url)
        #expect(name == "song.name")
    }
}
