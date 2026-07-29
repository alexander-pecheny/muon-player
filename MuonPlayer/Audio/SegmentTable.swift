import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// One track's span in the continuous scheduled sample stream.
struct Segment {
    let track: Track
    let startFrame: AVAudioFramePosition
    let startOffset: TimeInterval   // seconds into the track at startFrame (for seeks)
    var length: AVAudioFramePosition?   // known once the track is fully scheduled
    let duration: TimeInterval
}

/// Thread-safe list of scheduled segments. Written on the feed queue, read from
/// the main-actor ticker.
final class SegmentTable: @unchecked Sendable {
    private let lock = NSLock()
    private var segments: [Segment] = []

    func reset() {
        lock.lock(); defer { lock.unlock() }
        segments.removeAll()
    }

    func append(_ segment: Segment) {
        lock.lock(); defer { lock.unlock() }
        segments.append(segment)
    }

    func finalizeLast(endFrame: AVAudioFramePosition) {
        lock.lock(); defer { lock.unlock() }
        guard var last = segments.last else { return }
        last.length = endFrame - last.startFrame
        segments[segments.count - 1] = last
    }

    /// The segment covering `frame` (the track currently audible).
    func segment(atFrame frame: AVAudioFramePosition) -> Segment? {
        lock.lock(); defer { lock.unlock() }
        var match: Segment?
        for seg in segments where seg.startFrame <= frame {
            if let len = seg.length {
                if frame < seg.startFrame + len { match = seg; break }
            } else {
                match = seg // last, open-ended segment
            }
        }
        return match
    }

    func segment(withID id: UUID) -> Segment? {
        lock.lock(); defer { lock.unlock() }
        return segments.last { $0.track.id == id }
    }

    func lastEndFrame() -> AVAudioFramePosition {
        lock.lock(); defer { lock.unlock() }
        guard let last = segments.last else { return 0 }
        return last.startFrame + (last.length ?? 0)
    }
}
