import Foundation
import Testing
@testable import MuonPlayer

/// The fixture's Vorbis header declares its nominal bitrate as −2, meaning "unset".
/// FFmpeg reads the field unsigned and reports 4,294,967,294 b/s for the stream.
@Suite("Vorbis bitrate")
struct VorbisBitrateTests {
    @Test func ignoresAnUnsetNominalBitrate() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/unset-bitrate.ogg")
        let bitrate = try #require(FFmpegMetadata.read(url: fixture).bitrate)
        #expect((30_000...100_000).contains(bitrate))
    }
}
