import Foundation
import AVFoundation
import CFFmpeg

/// Canonical output format everything is resampled to. A single, fixed format
/// across all tracks is what makes gapless playback possible on one player node:
/// consecutive tracks' buffers can be scheduled back-to-back with no reconfigure.
enum CanonicalAudio {
    static let sampleRate: Double = 44_100
    static let channelCount: AVAudioChannelCount = 2

    static let format: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channelCount,
        interleaved: false
    )!
}

/// FFmpeg error helpers (the C macros don't import into Swift).
enum FFErr {
    static func tag(_ a: Character, _ b: Character, _ c: Character, _ d: Character) -> Int32 {
        let v = UInt32(a.asciiValue!) | (UInt32(b.asciiValue!) << 8)
            | (UInt32(c.asciiValue!) << 16) | (UInt32(d.asciiValue!) << 24)
        return -Int32(bitPattern: v)
    }
    static let eof: Int32 = tag("E", "O", "F", " ")
    static let eagain: Int32 = -35 // AVERROR(EAGAIN); EAGAIN == 35 on Darwin

    static func string(_ code: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        av_strerror(code, &buf, 128)
        return String(cString: buf)
    }
}

/// Decodes an audio file to canonical PCM (44.1kHz / stereo / float32 planar)
/// using FFmpeg's libav*. Pull-based: call `nextBuffer()` repeatedly until nil.
///
/// Not thread-safe; intended to be owned and driven by a single decode queue.
final class FFmpegDecoder {
    let url: URL
    private(set) var duration: TimeInterval = 0

    private var fmtCtx: UnsafeMutablePointer<AVFormatContext>?
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var swr: OpaquePointer?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var streamIndex: Int32 = -1
    private var inSampleRate: Int32 = 44_100
    private var timeBase: AVRational = AVRational(num: 1, den: 1)
    private var finished = false
    private var flushed = false
    private var targetOutputFrames: Int64?    // exact content length (canonical rate), if known
    private var emittedOutputFrames: Int64 = 0

    enum DecodeError: Error { case open(String), noAudioStream, codec(String), resampler }

    init(url: URL) throws {
        self.url = url
        try openInput()
    }

    deinit { close() }

    private func openInput() throws {
        var ctx: UnsafeMutablePointer<AVFormatContext>?
        let openResult = url.path.withCString { avformat_open_input(&ctx, $0, nil, nil) }
        guard openResult == 0, let ctx else { throw DecodeError.open(FFErr.string(openResult)) }
        fmtCtx = ctx

        guard avformat_find_stream_info(ctx, nil) >= 0 else {
            throw DecodeError.open("find_stream_info failed")
        }

        var decoder: UnsafePointer<AVCodec>?
        let idx = av_find_best_stream(ctx, AVMEDIA_TYPE_AUDIO, -1, -1, &decoder, 0)
        guard idx >= 0, let decoder else { throw DecodeError.noAudioStream }
        streamIndex = idx

        let stream = ctx.pointee.streams[Int(idx)]!
        timeBase = stream.pointee.time_base

        guard let cctx = avcodec_alloc_context3(decoder) else { throw DecodeError.codec("alloc") }
        codecCtx = cctx
        guard avcodec_parameters_to_context(cctx, stream.pointee.codecpar) >= 0 else {
            throw DecodeError.codec("params_to_context")
        }
        let openCodec = avcodec_open2(cctx, decoder, nil)
        guard openCodec == 0 else { throw DecodeError.codec(FFErr.string(openCodec)) }

        inSampleRate = cctx.pointee.sample_rate

        // Duration: prefer stream duration, fall back to container.
        if stream.pointee.duration > 0 {
            duration = Double(stream.pointee.duration) * av_q2d(timeBase)
        } else if ctx.pointee.duration > 0 {
            duration = Double(ctx.pointee.duration) / Double(AV_TIME_BASE)
        }

        // Gapless trimming. FFmpeg applies leading-priming skip for mp3/opus/
        // vorbis, and for AAC-in-MP4 tagged the ffmpeg way (edit lists) or the
        // Apple way (iTunSMPB). But for iTunSMPB it leaves the *trailing* padding
        // in place, which shows up as a gap at the next track. So if the file
        // declares an exact valid-sample count, cap output to it — this trims
        // trailing padding and is a no-op for formats already trimmed exactly.
        if let valid = validSampleCount(fmtMeta: ctx.pointee.metadata, streamMeta: stream.pointee.metadata) {
            targetOutputFrames = Int64((Double(valid) * CanonicalAudio.sampleRate / Double(inSampleRate)).rounded())
        }

        try setupResampler(cctx)

        packet = av_packet_alloc()
        frame = av_frame_alloc()
    }

    private func setupResampler(_ cctx: UnsafeMutablePointer<AVCodecContext>) throws {
        var outLayout = AVChannelLayout()
        av_channel_layout_default(&outLayout, Int32(CanonicalAudio.channelCount))
        defer { av_channel_layout_uninit(&outLayout) }

        var swrCtx: OpaquePointer?
        let rc = swr_alloc_set_opts2(
            &swrCtx,
            &outLayout, AV_SAMPLE_FMT_FLTP, Int32(CanonicalAudio.sampleRate),
            &cctx.pointee.ch_layout, cctx.pointee.sample_fmt, cctx.pointee.sample_rate,
            0, nil
        )
        guard rc == 0, let swrCtx, swr_init(swrCtx) == 0 else { throw DecodeError.resampler }
        swr = swrCtx
    }

    /// Seek to `time` seconds. Flushes decoder + resampler state.
    func seek(to time: TimeInterval) {
        guard let fmtCtx, let codecCtx else { return }
        let ts = Int64(time / av_q2d(timeBase))
        av_seek_frame(fmtCtx, streamIndex, ts, AVSEEK_FLAG_BACKWARD)
        avcodec_flush_buffers(codecCtx)
        if let swr { swr_convert(swr, nil, 0, nil, 0) } // drain
        finished = false
        flushed = false
        emittedOutputFrames = Int64((time * CanonicalAudio.sampleRate).rounded())
    }

    private var reachedTarget: Bool {
        if let target = targetOutputFrames { return emittedOutputFrames >= target }
        return false
    }

    /// Enforce the exact content length (trailing-padding trim) if declared.
    private func cap(_ buffer: AVAudioPCMBuffer?) -> AVAudioPCMBuffer? {
        guard let buffer, buffer.frameLength > 0 else { return nil }
        guard let target = targetOutputFrames else {
            return buffer
        }
        let remaining = target - emittedOutputFrames
        if remaining <= 0 { return nil }
        if Int64(buffer.frameLength) > remaining {
            buffer.frameLength = AVAudioFrameCount(remaining)
        }
        emittedOutputFrames += Int64(buffer.frameLength)
        return buffer
    }

    /// Returns the next chunk of canonical PCM, or nil at end of stream.
    /// Buffers are ~one decoded frame each (resampled).
    func nextBuffer() -> AVAudioPCMBuffer? {
        guard let codecCtx, let packet, let frame, let swr else { return nil }

        while true {
            // Try to pull a decoded frame first.
            let recv = avcodec_receive_frame(codecCtx, frame)
            if recv == 0 {
                let buf = convert(frame: frame, swr: swr)
                av_frame_unref(frame)
                if let out = cap(buf) { return out }
                if reachedTarget { return nil }
                continue
            } else if recv == FFErr.eof {
                return cap(flushResampler(swr: swr))
            } else if recv != FFErr.eagain {
                return nil // hard error
            }

            // Need more input: read a packet from our stream.
            if finished {
                avcodec_send_packet(codecCtx, nil) // enter draining mode
                let r2 = avcodec_receive_frame(codecCtx, frame)
                if r2 == 0 {
                    let buf = convert(frame: frame, swr: swr)
                    av_frame_unref(frame)
                    if let out = cap(buf) { return out }
                    if reachedTarget { return nil }
                    continue
                }
                return cap(flushResampler(swr: swr))
            }

            let rf = av_read_frame(fmtCtx, packet)
            if rf < 0 {
                finished = true
                continue
            }
            defer { av_packet_unref(packet) }
            if packet.pointee.stream_index == streamIndex {
                avcodec_send_packet(codecCtx, packet)
            }
        }
    }

    /// After EOF, drain whatever samples the resampler still holds.
    private func flushResampler(swr: OpaquePointer) -> AVAudioPCMBuffer? {
        guard !flushed else { return nil }
        flushed = true
        let remaining = swr_get_delay(swr, Int64(CanonicalAudio.sampleRate))
        guard remaining > 0 else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: CanonicalAudio.format,
                                            frameCapacity: AVAudioFrameCount(remaining)) else { return nil }
        var outPlanes = outPlanePointers(buffer)
        let written = outPlanes.withUnsafeMutableBufferPointer { out in
            swr_convert(swr, out.baseAddress, Int32(remaining), nil, 0)
        }
        guard written > 0 else { return nil }
        buffer.frameLength = AVAudioFrameCount(written)
        return buffer
    }

    /// Parse the exact valid-sample count from the Apple `iTunSMPB` gapless tag
    /// if present. Field layout (space-separated hex):
    /// `<reserved> <priming> <padding> <valid-samples> ...`.
    private func validSampleCount(fmtMeta: OpaquePointer?, streamMeta: OpaquePointer?) -> Int64? {
        func tag(_ dict: OpaquePointer?) -> String? {
            guard let e = av_dict_get(dict, "iTunSMPB", nil, AV_DICT_IGNORE_SUFFIX), let v = e.pointee.value
            else { return nil }
            return String(cString: v)
        }
        guard let smpb = tag(fmtMeta) ?? tag(streamMeta) else { return nil }
        let fields = smpb.split(whereSeparator: { $0 == " " }).map(String.init)
        guard fields.count >= 4, let valid = Int64(fields[3], radix: 16), valid > 0 else { return nil }
        return valid
    }

    private func convert(frame: UnsafeMutablePointer<AVFrame>, swr: OpaquePointer) -> AVAudioPCMBuffer? {
        let inSamples = frame.pointee.nb_samples
        guard inSamples > 0 else { return nil }

        let delay = swr_get_delay(swr, Int64(inSampleRate))
        let outCount = av_rescale_rnd(delay + Int64(inSamples),
                                      Int64(CanonicalAudio.sampleRate),
                                      Int64(inSampleRate), AV_ROUND_UP)
        guard outCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: CanonicalAudio.format,
                                            frameCapacity: AVAudioFrameCount(outCount)) else { return nil }

        var outPlanes = outPlanePointers(buffer)
        let inData = UnsafeRawPointer(frame.pointee.extended_data)?
            .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
        let written = outPlanes.withUnsafeMutableBufferPointer { out in
            swr_convert(swr, out.baseAddress, Int32(outCount), inData, inSamples)
        }
        guard written >= 0 else { return nil }
        buffer.frameLength = AVAudioFrameCount(written)
        return buffer
    }

    private func outPlanePointers(_ buffer: AVAudioPCMBuffer) -> [UnsafeMutablePointer<UInt8>?] {
        let channels = Int(CanonicalAudio.channelCount)
        guard let planes = buffer.floatChannelData else { return [] }
        return (0..<channels).map { ch in
            UnsafeMutableRawPointer(planes[ch]).assumingMemoryBound(to: UInt8.self)
        }
    }

    private func close() {
        if let frame { var f: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&f) }
        if let packet { var p: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&p) }
        if let swr { var s: OpaquePointer? = swr; swr_free(&s) }
        if let codecCtx { var c: UnsafeMutablePointer<AVCodecContext>? = codecCtx; avcodec_free_context(&c) }
        if let fmtCtx { var f: UnsafeMutablePointer<AVFormatContext>? = fmtCtx; avformat_close_input(&f) }
        frame = nil; packet = nil; swr = nil; codecCtx = nil; fmtCtx = nil
    }
}
