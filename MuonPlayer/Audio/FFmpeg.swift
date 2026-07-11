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
    private var primingInputSamples: Int64 = 0   // leading samples FFmpeg won't drop for us
    private var skipUntilInputSample: Int64 = 0  // absolute input sample output should start at
    private var inputSampleCursor: Int64 = 0     // absolute input sample of the next decoded frame

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

        let demuxer = ctx.pointee.iformat.flatMap { $0.pointee.name }.map { String(cString: $0) } ?? ""
        let isMP4 = demuxer.contains("mp4") || demuxer.contains("mov")

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

        // Gapless trimming. FFmpeg drops encoder priming itself for mp3/opus/
        // vorbis, and for AAC-in-MP4 that carries an edit list. Apple's
        // `iTunSMPB` tag it ignores entirely, so an edit-list-less m4a decodes
        // with priming at the head and padding at the tail — audible as a gap
        // and a click at every album transition.
        let streamSamples = av_rescale_q(stream.pointee.duration, timeBase,
                                         AVRational(num: 1, den: inSampleRate))

        if let g = GaplessInfo.read(ctx.pointee.metadata, stream.pointee.metadata) {
            duration = Double(g.validSamples) / Double(inSampleRate)
            targetOutputFrames = rescaleToCanonical(g.validSamples)

            if !g.ffmpegAlreadyTrims(streamDurationInSamples: streamSamples) {
                primingInputSamples = g.priming
            }
        } else if isMP4, streamSamples > 0 {
            // An edit list gets FFmpeg to drop the priming and to report the true
            // duration — but not to stop decoding at it, so the trailing padding
            // still plays. Only mp4 gets this cap: there the duration comes from
            // the sample tables and is exact, while a Xing-less VBR mp3 only has a
            // guess from the bitrate, and capping to that would cut real music.
            targetOutputFrames = rescaleToCanonical(streamSamples)
        }
        skipUntilInputSample = primingInputSamples

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

    private func rescaleToCanonical(_ inputSamples: Int64) -> Int64 {
        av_rescale_q(inputSamples, AVRational(num: 1, den: inSampleRate),
                     AVRational(num: 1, den: Int32(CanonicalAudio.sampleRate)))
    }

    /// Seek to `time` seconds of *content* — i.e. past any encoder priming.
    /// Flushes decoder + resampler state.
    func seek(to time: TimeInterval) {
        guard let fmtCtx, let codecCtx else { return }
        let contentSample = Int64((time * Double(inSampleRate)).rounded())
        skipUntilInputSample = primingInputSamples + contentSample
        let ts = av_rescale_q(skipUntilInputSample, AVRational(num: 1, den: inSampleRate), timeBase)
        av_seek_frame(fmtCtx, streamIndex, ts, AVSEEK_FLAG_BACKWARD)
        avcodec_flush_buffers(codecCtx)
        if let swr { swr_convert(swr, nil, 0, nil, 0) } // drain
        finished = false
        flushed = false
        inputSampleCursor = 0
        emittedOutputFrames = rescaleToCanonical(contentSample)
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

    /// Number of leading samples of `frame` that fall before `skipUntilInputSample`,
    /// advancing the absolute input cursor past it.
    private func consumeSkip(_ frame: UnsafeMutablePointer<AVFrame>) -> Int32 {
        let count = Int64(frame.pointee.nb_samples)
        if frame.pointee.pts != Int64.min { // AV_NOPTS_VALUE
            inputSampleCursor = av_rescale_q(frame.pointee.pts, timeBase,
                                             AVRational(num: 1, den: inSampleRate))
        }
        let drop = min(count, max(0, skipUntilInputSample - inputSampleCursor))
        inputSampleCursor += count
        return Int32(drop)
    }

    /// Returns the next chunk of canonical PCM, or nil at end of stream.
    /// Buffers are ~one decoded frame each (resampled).
    func nextBuffer() -> AVAudioPCMBuffer? {
        guard let codecCtx, let packet, let frame, let swr else { return nil }

        while true {
            // Try to pull a decoded frame first.
            let recv = avcodec_receive_frame(codecCtx, frame)
            if recv == 0 {
                let buf = convert(frame: frame, swr: swr, dropping: consumeSkip(frame))
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
                    let buf = convert(frame: frame, swr: swr, dropping: consumeSkip(frame))
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

    /// Byte offset into each input plane for `samples`, honouring planar vs packed.
    private func planeOffset(_ samples: Int32, codecCtx: UnsafeMutablePointer<AVCodecContext>) -> Int {
        let bytes = Int(av_get_bytes_per_sample(codecCtx.pointee.sample_fmt))
        let stride = av_sample_fmt_is_planar(codecCtx.pointee.sample_fmt) == 1
            ? bytes : bytes * Int(codecCtx.pointee.ch_layout.nb_channels)
        return Int(samples) * stride
    }

    private func convert(frame: UnsafeMutablePointer<AVFrame>, swr: OpaquePointer,
                         dropping skip: Int32) -> AVAudioPCMBuffer? {
        guard let codecCtx else { return nil }
        let inSamples = frame.pointee.nb_samples - skip
        guard inSamples > 0 else { return nil }

        let delay = swr_get_delay(swr, Int64(inSampleRate))
        let outCount = av_rescale_rnd(delay + Int64(inSamples),
                                      Int64(CanonicalAudio.sampleRate),
                                      Int64(inSampleRate), AV_ROUND_UP)
        guard outCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: CanonicalAudio.format,
                                            frameCapacity: AVAudioFrameCount(outCount)) else { return nil }

        let offset = planeOffset(skip, codecCtx: codecCtx)
        let planes = UnsafeRawPointer(frame.pointee.extended_data)!
            .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
        let planeCount = av_sample_fmt_is_planar(codecCtx.pointee.sample_fmt) == 1
            ? Int(codecCtx.pointee.ch_layout.nb_channels) : 1
        var inData: [UnsafePointer<UInt8>?] = (0..<planeCount).map { planes[$0].map { $0 + offset } }

        var outPlanes = outPlanePointers(buffer)
        let written = outPlanes.withUnsafeMutableBufferPointer { out in
            inData.withUnsafeMutableBufferPointer { inp in
                swr_convert(swr, out.baseAddress, Int32(outCount), inp.baseAddress, inSamples)
            }
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
