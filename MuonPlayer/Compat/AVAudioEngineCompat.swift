#if os(Android)
import Foundation
import CAAudio

// Player.swift is the gapless engine — the segment table, the fades, the playhead
// accounting — and none of that is Apple-specific. What is Apple-specific is the
// handful of AVAudioEngine calls underneath it, so those get an AAudio backend
// here instead of a second Player for Android.
//
// AAudio is pull-based: the device asks for N frames on a real-time thread and we
// interleave them out of the queued planar buffers. AVAudioPlayerNode is
// push-based, which is why the queue lives here rather than in the stream.

public enum AVAudioPlayerNodeCompletionCallbackType: Sendable {
    case dataConsumed
}

public final class AVAudioTime: @unchecked Sendable {
    public let sampleTime: AVAudioFramePosition
    public let sampleRate: Double
    public init(sampleTime: AVAudioFramePosition, atRate sampleRate: Double) {
        self.sampleTime = sampleTime
        self.sampleRate = sampleRate
    }
}

public final class AVAudioMixerNode: @unchecked Sendable {
    private let lock = NSLock()
    private var _outputVolume: Float = 1

    public var outputVolume: Float {
        get { lock.lock(); defer { lock.unlock() }; return _outputVolume }
        set { lock.lock(); _outputVolume = max(0, min(1, newValue)); lock.unlock() }
    }
}

public final class AVAudioPlayerNode: @unchecked Sendable {
    private struct Pending {
        let buffer: AVAudioPCMBuffer
        let completion: (AVAudioPlayerNodeCompletionCallbackType) -> Void
        var consumed: AVAudioFrameCount = 0
    }

    private let lock = NSLock()
    private var queue: [Pending] = []
    private var framesRendered: AVAudioFramePosition = 0
    private var running = false
    /// Completions are invoked off the audio thread — the handler feeds the
    /// decoder, and blocking the AAudio callback on that underruns the stream.
    private let completionQueue = DispatchQueue(label: "com.muonplayer.nodecompletion")

    public init() {}

    public var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    public func scheduleBuffer(_ buffer: AVAudioPCMBuffer,
                               completionCallbackType: AVAudioPlayerNodeCompletionCallbackType,
                               completionHandler: @escaping (AVAudioPlayerNodeCompletionCallbackType) -> Void) {
        lock.lock()
        queue.append(Pending(buffer: buffer, completion: completionHandler))
        lock.unlock()
    }

    public func play() {
        lock.lock(); running = true; lock.unlock()
    }

    public func pause() {
        lock.lock(); running = false; lock.unlock()
    }

    /// Drops everything queued and rewinds the node's own timeline, which is what
    /// AVAudioPlayerNode.stop() does and what Player relies on when it restarts a
    /// track: the segment table it maps positions through is reset alongside.
    public func stop() {
        lock.lock()
        let dropped = queue
        queue.removeAll()
        framesRendered = 0
        running = false
        lock.unlock()
        completionQueue.async { dropped.forEach { $0.completion(.dataConsumed) } }
    }

    public var lastRenderTime: AVAudioTime? {
        lock.lock(); defer { lock.unlock() }
        guard running || framesRendered > 0 else { return nil }
        return AVAudioTime(sampleTime: framesRendered, atRate: CanonicalAudio.sampleRate)
    }

    public func playerTime(forNodeTime nodeTime: AVAudioTime) -> AVAudioTime? { nodeTime }

    /// Fill `out` (interleaved stereo float) from the queued planar buffers.
    /// Runs on the AAudio callback thread.
    fileprivate func render(into out: UnsafeMutablePointer<Float>, frames: Int, gain: Float) {
        var written = 0
        var finished: [(AVAudioPlayerNodeCompletionCallbackType) -> Void] = []

        lock.lock()
        if running {
            while written < frames, !queue.isEmpty {
                let take = min(frames - written,
                               Int(queue[0].buffer.frameLength - queue[0].consumed))
                if take <= 0 {
                    finished.append(queue.removeFirst().completion)
                    continue
                }
                if let planes = queue[0].buffer.floatChannelData {
                    let offset = Int(queue[0].consumed)
                    let left = planes[0], right = planes[1]
                    for i in 0..<take {
                        out[(written + i) * 2] = left[offset + i] * gain
                        out[(written + i) * 2 + 1] = right[offset + i] * gain
                    }
                }
                queue[0].consumed += AVAudioFrameCount(take)
                written += take
                if queue[0].consumed >= queue[0].buffer.frameLength {
                    finished.append(queue.removeFirst().completion)
                }
            }
            framesRendered += AVAudioFramePosition(written)
        }
        lock.unlock()

        // An underrun is silence, not stale audio: whatever the device handed us
        // is uninitialised memory.
        if written < frames {
            (written * 2..<frames * 2).forEach { out[$0] = 0 }
        }
        if !finished.isEmpty {
            completionQueue.async { finished.forEach { $0(.dataConsumed) } }
        }
    }
}

public final class AVAudioEngine: @unchecked Sendable {
    public let mainMixerNode = AVAudioMixerNode()

    private let lock = NSLock()
    private var stream: OpaquePointer?
    private var node: AVAudioPlayerNode?

    public init() {}

    public func attach(_ node: AVAudioPlayerNode) {
        lock.lock(); self.node = node; lock.unlock()
    }

    public func connect(_ node: AVAudioPlayerNode, to mixer: AVAudioMixerNode, format: AVAudioFormat?) {}

    public func prepare() {}

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let stream else { return false }
        return AAudioStream_getState(stream) == aaudio_stream_state_t(AAUDIO_STREAM_STATE_STARTED)
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        if stream == nil { try openStream() }
        guard let stream else { throw AudioEngineError.streamUnavailable }
        let rc = AAudioStream_requestStart(stream)
        guard rc == aaudio_result_t(AAUDIO_OK) else { throw AudioEngineError.aaudio(rc) }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let stream else { return }
        AAudioStream_requestStop(stream)
        AAudioStream_close(stream)
        self.stream = nil
    }

    public enum AudioEngineError: Error {
        case streamUnavailable
        case aaudio(aaudio_result_t)
    }

    private func openStream() throws {
        var builder: OpaquePointer?
        var rc = AAudio_createStreamBuilder(&builder)
        guard rc == aaudio_result_t(AAUDIO_OK), let builder else { throw AudioEngineError.aaudio(rc) }
        defer { AAudioStreamBuilder_delete(builder) }

        AAudioStreamBuilder_setFormat(builder, aaudio_format_t(AAUDIO_FORMAT_PCM_FLOAT))
        AAudioStreamBuilder_setChannelCount(builder, Int32(CanonicalAudio.channelCount))
        AAudioStreamBuilder_setSampleRate(builder, Int32(CanonicalAudio.sampleRate))
        AAudioStreamBuilder_setPerformanceMode(builder, aaudio_performance_mode_t(AAUDIO_PERFORMANCE_MODE_NONE))
        AAudioStreamBuilder_setSharingMode(builder, aaudio_sharing_mode_t(AAUDIO_SHARING_MODE_SHARED))
        AAudioStreamBuilder_setUsage(builder, aaudio_usage_t(AAUDIO_USAGE_MEDIA))
        AAudioStreamBuilder_setContentType(builder, aaudio_content_type_t(AAUDIO_CONTENT_TYPE_MUSIC))
        AAudioStreamBuilder_setDataCallback(builder, { _, userData, audioData, numFrames in
            guard let userData else { return aaudio_data_callback_result_t(AAUDIO_CALLBACK_RESULT_CONTINUE) }
            let engine = Unmanaged<AVAudioEngine>.fromOpaque(userData).takeUnretainedValue()
            engine.renderCallback(audioData.assumingMemoryBound(to: Float.self), Int(numFrames))
            return aaudio_data_callback_result_t(AAUDIO_CALLBACK_RESULT_CONTINUE)
        }, Unmanaged.passUnretained(self).toOpaque())

        var opened: OpaquePointer?
        rc = AAudioStreamBuilder_openStream(builder, &opened)
        guard rc == aaudio_result_t(AAUDIO_OK) else { throw AudioEngineError.aaudio(rc) }
        stream = opened
    }

    /// Deliberately does not take the engine lock: it runs on the real-time audio
    /// thread, where blocking behind start()/stop() would drop frames.
    private func renderCallback(_ out: UnsafeMutablePointer<Float>, _ frames: Int) {
        guard let node else {
            (0..<frames * Int(CanonicalAudio.channelCount)).forEach { out[$0] = 0 }
            return
        }
        node.render(into: out, frames: frames, gain: mainMixerNode.outputVolume)
    }
}
#endif
