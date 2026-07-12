import Foundation
import CFFmpeg

/// Interleaved float samples at the file's *own* rate. Resampling to a canonical
/// rate — which is what playback does — would round off the very discontinuity a
/// seam scan is looking for, so this is the one place the native rate is kept.
struct EdgeAudio {
    let rate: Int
    let channels: Int
    let samples: [Float]

    var frames: Int { channels > 0 ? samples.count / channels : 0 }

    func channel(_ c: Int) -> [Float] {
        stride(from: c, to: samples.count, by: channels).map { samples[$0] }
    }
}

/// The first or last few hundred ms of a file, decoded in-process.
///
/// The seam scan needs two short windows per track and nothing else, so shelling out
/// to the ffmpeg CLI spent ~27 ms of process startup to do ~2 ms of work — over a
/// library that is the whole cost of the scan. Here the file is opened once and only
/// the wanted window is decoded.
///
/// The trims the player applies are applied here too (`GaplessInfo`, and the mp4
/// duration cap that FFmpeg itself ignores at the tail), so what the scan measures is
/// what you would hear.
final class EdgeDecoder {
    enum Failure: Error { case open(String), noAudioStream, codec(String), resampler }

    private var fmtCtx: UnsafeMutablePointer<AVFormatContext>?
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var swr: OpaquePointer?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var streamIndex: Int32 = -1
    private var timeBase = AVRational(num: 1, den: 1)

    private(set) var rate = 0
    private(set) var channels = 0
    private(set) var duration: TimeInterval = 0

    /// Leading input samples FFmpeg will not drop for us.
    private var priming: Int64 = 0
    /// Exact content length past the priming, when the file declares one.
    private var contentSamples: Int64?

    init(path: String) throws {
        var ctx: UnsafeMutablePointer<AVFormatContext>?
        let rc = path.withCString { avformat_open_input(&ctx, $0, nil, nil) }
        guard rc == 0, let ctx else { throw Failure.open(FFErr.string(rc)) }
        fmtCtx = ctx
        guard avformat_find_stream_info(ctx, nil) >= 0 else { throw Failure.open("find_stream_info") }

        var decoder: UnsafePointer<AVCodec>?
        let idx = av_find_best_stream(ctx, AVMEDIA_TYPE_AUDIO, -1, -1, &decoder, 0)
        guard idx >= 0, let decoder else { throw Failure.noAudioStream }
        streamIndex = idx

        let stream = ctx.pointee.streams[Int(idx)]!
        timeBase = stream.pointee.time_base

        guard let cctx = avcodec_alloc_context3(decoder) else { throw Failure.codec("alloc") }
        codecCtx = cctx
        guard avcodec_parameters_to_context(cctx, stream.pointee.codecpar) >= 0 else {
            throw Failure.codec("params_to_context")
        }
        let opened = avcodec_open2(cctx, decoder, nil)
        guard opened == 0 else { throw Failure.codec(FFErr.string(opened)) }

        rate = Int(cctx.pointee.sample_rate)
        channels = Int(cctx.pointee.ch_layout.nb_channels)
        guard rate > 0, channels > 0 else { throw Failure.codec("no format") }

        if stream.pointee.duration > 0 {
            duration = Double(stream.pointee.duration) * av_q2d(timeBase)
        } else if ctx.pointee.duration > 0 {
            duration = Double(ctx.pointee.duration) / Double(AV_TIME_BASE)
        }

        let demuxer = ctx.pointee.iformat.flatMap { $0.pointee.name }.map { String(cString: $0) } ?? ""
        let isMP4 = demuxer.contains("mp4") || demuxer.contains("mov")
        let streamSamples = av_rescale_q(stream.pointee.duration, timeBase,
                                         AVRational(num: 1, den: Int32(rate)))

        if let g = GaplessInfo.read(ctx.pointee.metadata, stream.pointee.metadata) {
            contentSamples = g.validSamples
            duration = Double(g.validSamples) / Double(rate)
            if !g.ffmpegAlreadyTrims(streamDurationInSamples: streamSamples) { priming = g.priming }
        } else if isMP4, streamSamples > 0 {
            contentSamples = streamSamples
        }

        // Format-only conversion: same rate, same layout, so swr never resamples and
        // never buffers — it just packs whatever the codec emits into interleaved float.
        var swrCtx: OpaquePointer?
        let sr = swr_alloc_set_opts2(&swrCtx,
                                     &cctx.pointee.ch_layout, AV_SAMPLE_FMT_FLT, Int32(rate),
                                     &cctx.pointee.ch_layout, cctx.pointee.sample_fmt, Int32(rate),
                                     0, nil)
        guard sr == 0, let swrCtx, swr_init(swrCtx) == 0 else { throw Failure.resampler }
        swr = swrCtx

        packet = av_packet_alloc()
        frame = av_frame_alloc()
    }

    deinit { close() }

    /// The first `ms` of content.
    func head(ms: Double) -> EdgeAudio? {
        let want = frames(ms)
        var out: [Float] = []
        out.reserveCapacity(want * channels)
        pump(from: nil) { block in
            out.append(contentsOf: block)
            return out.count < want * channels
        }
        guard !out.isEmpty else { return nil }
        return EdgeAudio(rate: rate, channels: channels,
                         samples: Array(out.prefix(want * channels)))
    }

    /// The last `ms` of content.
    ///
    /// Seeking lands on the packet *before* the target, and a duration can be a guess
    /// (a Xing-less VBR mp3 only has one), so the window is not taken from where the
    /// seek arrives — everything from there is decoded and the last `ms` kept. That is
    /// what `-sseof` did, without needing the duration to be exact.
    func tail(ms: Double) -> EdgeAudio? {
        let want = frames(ms)
        let slack = ms / 1000 + 0.5
        let seek = duration > slack ? duration - slack : nil

        var ring: [Float] = []
        let cap = want * channels
        ring.reserveCapacity(cap * 2)
        pump(from: seek) { block in
            ring.append(contentsOf: block)
            if ring.count > cap * 2 { ring.removeFirst(ring.count - cap) }
            return true
        }
        guard !ring.isEmpty else { return nil }
        return EdgeAudio(rate: rate, channels: channels, samples: Array(ring.suffix(cap)))
    }

    private func frames(_ ms: Double) -> Int { Int(ms / 1000 * Double(rate)) }

    /// Decodes from `seconds` (or the start), handing each frame's content samples to
    /// `sink` as interleaved float. `sink` returns false to stop early — which is the
    /// point: a head window stops after a few frames instead of decoding the track.
    private func pump(from seconds: TimeInterval?, _ sink: ([Float]) -> Bool) {
        guard let fmtCtx, let codecCtx, let packet, let frame else { return }

        if let seconds {
            let sample = priming + Int64(seconds * Double(rate))
            let ts = av_rescale_q(sample, AVRational(num: 1, den: Int32(rate)), timeBase)
            av_seek_frame(fmtCtx, streamIndex, ts, AVSEEK_FLAG_BACKWARD)
            avcodec_flush_buffers(codecCtx)
        }

        var cursor: Int64 = 0          // absolute input sample of the next decoded frame
        var draining = false

        func handle() -> Bool {        // false = stop
            let n = Int64(frame.pointee.nb_samples)
            if frame.pointee.pts != Int64.min {
                // A negative pts means libavcodec has already trimmed this frame's head
                // (Opus's 312-sample pre-skip, mp3's LAME delay) and could not rewrite
                // the timestamp to match. The samples it handed us start at content
                // sample 0; reading the pts literally would drop the priming twice.
                cursor = max(0, av_rescale_q(frame.pointee.pts, timeBase,
                                             AVRational(num: 1, den: Int32(rate))))
            }
            let start = cursor
            cursor += n

            let from = min(n, max(0, priming - start))
            var to = n
            if let content = contentSamples { to = min(to, priming + content - start) }
            guard to > from else { return to > 0 }        // stop once past the content end

            if let block = convert(frame, dropping: Int32(from), count: Int32(to - from)) {
                return sink(block)
            }
            return true
        }

        while true {
            let recv = avcodec_receive_frame(codecCtx, frame)
            if recv == 0 {
                let more = handle()
                av_frame_unref(frame)
                if !more { return }
                continue
            }
            if recv == FFErr.eof { return }
            if recv != FFErr.eagain { return }

            if draining { return }

            let rf = av_read_frame(fmtCtx, packet)
            if rf < 0 {
                draining = true
                avcodec_send_packet(codecCtx, nil)
                continue
            }
            defer { av_packet_unref(packet) }
            if packet.pointee.stream_index == streamIndex {
                avcodec_send_packet(codecCtx, packet)
            }
        }
    }

    private func convert(_ frame: UnsafeMutablePointer<AVFrame>,
                         dropping skip: Int32, count: Int32) -> [Float]? {
        guard let codecCtx, let swr, count > 0 else { return nil }

        let fmt = codecCtx.pointee.sample_fmt
        let bytes = Int(av_get_bytes_per_sample(fmt))
        let planar = av_sample_fmt_is_planar(fmt) == 1
        let offset = Int(skip) * (planar ? bytes : bytes * channels)

        let planes = UnsafeRawPointer(frame.pointee.extended_data)!
            .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
        var inData: [UnsafePointer<UInt8>?] = (0 ..< (planar ? channels : 1))
            .map { planes[$0].map { $0 + offset } }

        var out = [Float](repeating: 0, count: Int(count) * channels)
        let written = out.withUnsafeMutableBytes { raw -> Int32 in
            var outPlanes: [UnsafeMutablePointer<UInt8>?] = [
                raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
            ]
            return outPlanes.withUnsafeMutableBufferPointer { o in
                inData.withUnsafeMutableBufferPointer { i in
                    swr_convert(swr, o.baseAddress, count, i.baseAddress, count)
                }
            }
        }
        guard written > 0 else { return nil }
        return written == count ? out : Array(out.prefix(Int(written) * channels))
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
