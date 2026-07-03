import Testing
import Foundation
@testable import MuonPlayer

/// Tests the foobar2000-style queue semantics in QueueCore.
@Suite("QueueCore Tests")
struct QueueCoreTests {

    private func album(_ name: String, _ count: Int) -> [Track] {
        (1...count).map { i in
            Track(url: URL(fileURLWithPath: "/Music/\(name)/track\(i).mp3"),
                  title: "\(name) Track \(i)", album: name, trackNo: i)
        }
    }

    @Test("Plain advance walks the context in order")
    func advanceInOrder() {
        let q = QueueCore()
        let a1 = album("ALBUM1", 3)
        _ = q.setContext(a1, startIndex: 0)
        #expect(q.advance()?.title == "ALBUM1 Track 2")
        #expect(q.advance()?.title == "ALBUM1 Track 3")
        #expect(q.advance() == nil)
    }

    @Test("foobar rule: after a queued track, playback continues from that track's album")
    func foobarContinuation() {
        let q = QueueCore()
        let a1 = album("ALBUM1", 5)
        let a2 = album("ALBUM2", 8)

        // Playing ALBUM1 / TRACK1, queue ALBUM2 / TRACK5.
        _ = q.setContext(a1, startIndex: 0)
        q.enqueue(a2[4], context: a2, index: 4) // ALBUM2 Track 5

        // After TRACK1, the queued ALBUM2/TRACK5 plays.
        #expect(q.advance()?.title == "ALBUM2 Track 5")
        // Then — foobar style — ALBUM2/TRACK6, not back to ALBUM1/TRACK2.
        #expect(q.advance()?.title == "ALBUM2 Track 6")
        #expect(q.advance()?.title == "ALBUM2 Track 7")
    }

    @Test("Queue is consumed FIFO before continuing context")
    func queueFIFO() {
        let q = QueueCore()
        let a1 = album("ALBUM1", 3)
        let a2 = album("ALBUM2", 3)
        _ = q.setContext(a1, startIndex: 0)
        q.enqueue(a2[0], context: a2, index: 0)
        q.enqueue(a1[2], context: a1, index: 2)

        #expect(q.advance()?.title == "ALBUM2 Track 1")
        #expect(q.advance()?.title == "ALBUM1 Track 3") // context moved to ALBUM1 idx2
        #expect(q.advance() == nil)                       // idx3 is out of range
    }

    @Test("previous walks back within context")
    func previous() {
        let q = QueueCore()
        let a1 = album("ALBUM1", 3)
        _ = q.setContext(a1, startIndex: 2)
        #expect(q.previous()?.title == "ALBUM1 Track 2")
        #expect(q.previous()?.title == "ALBUM1 Track 1")
        #expect(q.previous() == nil)
    }

    @Test("peekNext does not mutate")
    func peek() {
        let q = QueueCore()
        let a1 = album("ALBUM1", 3)
        _ = q.setContext(a1, startIndex: 0)
        #expect(q.peekNext()?.title == "ALBUM1 Track 2")
        #expect(q.peekNext()?.title == "ALBUM1 Track 2")
        #expect(q.advance()?.title == "ALBUM1 Track 2")
    }
}
