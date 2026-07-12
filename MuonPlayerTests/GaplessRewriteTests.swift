import Foundation
import Testing
@testable import MuonPlayer

/// `no-xing.mp3` is the fixture tone encoded with no Xing/LAME header at all — which is
/// what most of a broken library looks like. Nothing in it says where the music starts or
/// stops, so FFmpeg decodes the encoder's delay and padding as if they were music, and at
/// an album seam that silence is the gap you hear.
///
/// This is the destructive path: it rewrites the user's file. So it is tested on a copy,
/// end to end — measure, rewrite, decode the result.
@Suite("Gapless MP3 rewrite")
struct GaplessRewriteTests {
    var fixture: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/no-xing.mp3")
    }

    /// A copy of the fixture and a scratch backup directory, both thrown away after.
    func withCopy(_ body: (String, URL) throws -> Void) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let copy = dir.appendingPathComponent("track.mp3")
        try FileManager.default.copyItem(at: fixture, to: copy)
        try body(copy.path, dir.appendingPathComponent("backups"))
    }

    func silence(_ path: String) throws -> (lead: Int, trail: Int) {
        let decoder = try EdgeDecoder(path: path)
        let head = try #require(decoder.head(ms: 500))
        let tail = try #require(decoder.tail(ms: 500))
        return (SeamScan.bounds(head).lead, SeamScan.bounds(tail).trail)
    }

    @Test func theFixtureIsActuallyBroken() throws {
        let before = try silence(fixture.path)
        #expect(before.lead > 500)      // encoder delay, decoded as if it were music
        #expect(before.trail > 500)     // ...and the padding
    }

    /// After the rewrite the file carries its own delay/padding, so FFmpeg — and every
    /// other player — trims it and the silence is simply gone.
    @Test func rewritingClosesTheSilence() throws {
        try withCopy { path, backups in
            let before = try silence(path)
            let done = GaplessMaintenance.rewriteMP3(
                at: path, trim: GaplessTrim(head: before.lead, tail: before.trail),
                backupsIn: backups, GaplessLog(name: "test-gapless.log"))
            #expect(done)

            let after = try silence(path)
            #expect(after.lead < 16)
            #expect(after.trail < 16)
        }
    }

    /// The audio itself is untouched: only the header frame is rewritten, so what the file
    /// now plays is exactly the music that was always in it, with nothing lost off either
    /// end. (The fixture's tone runs to full amplitude at both edges once trimmed.)
    @Test func theMusicSurvives() throws {
        try withCopy { path, backups in
            let before = try silence(path)
            GaplessMaintenance.rewriteMP3(
                at: path, trim: GaplessTrim(head: before.lead, tail: before.trail),
                backupsIn: backups, GaplessLog(name: "test-gapless.log"))

            let decoder = try EdgeDecoder(path: path)
            let head = try #require(decoder.head(ms: 200))
            let tail = try #require(decoder.tail(ms: 200))
            #expect((head.samples.prefix(64).map(abs).max() ?? 0) > 0.1)
            #expect((tail.samples.suffix(64).map(abs).max() ?? 0) > 0.1)
        }
    }

    /// The original is kept whole before a byte is written — the header frame shifts
    /// everything behind it, so there is nothing smaller worth keeping.
    @Test func theOriginalIsBackedUp() throws {
        try withCopy { path, backups in
            let original = try Data(contentsOf: URL(fileURLWithPath: path))
            let before = try silence(path)
            GaplessMaintenance.rewriteMP3(
                at: path, trim: GaplessTrim(head: before.lead, tail: before.trail),
                backupsIn: backups, GaplessLog(name: "test-gapless.log"))

            let saved = try FileManager.default.contentsOfDirectory(atPath: backups.path)
            #expect(saved.count == 1)
            let kept = try Data(contentsOf: backups.appendingPathComponent(saved[0]))
            #expect(kept == original)
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) != original)  // it did change
        }
    }
}
