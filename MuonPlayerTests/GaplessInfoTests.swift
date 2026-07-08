import Testing
@testable import MuonPlayer

@Suite("GaplessInfo")
struct GaplessInfoTests {
    // Real tag from "01 - (probably).m4a" (XLD), leading space included.
    let probably = " 00000000 00000840 000000CC 0000000000438EF4 00000000 00000000" +
                   " 00000000 00000000 00000000 00000000 00000000 00000000"

    @Test func parsesAppleTag() throws {
        let g = try #require(GaplessInfo(iTunSMPB: probably))
        #expect(g.priming == 2112)
        #expect(g.padding == 204)
        #expect(g.validSamples == 4_427_508)
        #expect(g.totalSamples == 4_429_824)
    }

    @Test func rejectsGarbage() {
        #expect(GaplessInfo(iTunSMPB: "") == nil)
        #expect(GaplessInfo(iTunSMPB: "00000000 00000840 000000CC") == nil)
        #expect(GaplessInfo(iTunSMPB: "0 840 CC 0") == nil)             // zero valid count
        #expect(GaplessInfo(iTunSMPB: "0 840 CC zzzz") == nil)
    }

    /// No edit list: stream duration still covers priming + padding, so FFmpeg
    /// hands us an untrimmed stream and we must trim it ourselves.
    @Test func detectsUntrimmedStream() throws {
        let g = try #require(GaplessInfo(iTunSMPB: probably))
        #expect(g.ffmpegAlreadyTrims(streamDurationInSamples: 4_429_824) == false)
        #expect(g.ffmpegAlreadyTrims(streamDurationInSamples: 4_427_508) == true)
    }
}
