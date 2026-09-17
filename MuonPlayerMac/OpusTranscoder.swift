import Foundation
import CFFmpeg

/// Re-encodes a lossless file to Opus on its way to the phone.
///
/// Mac-only, and so is the encoder: `scripts/build-ffmpeg.sh` enables libopus in the
/// macOS slice alone, because the phone has nothing to encode. Everything here is the
/// plain libav* transcode loop — demux, decode, resample to 48 kHz, encode, mux into
/// an Ogg-Opus file.
enum OpusTranscoder {

    /// Codecs worth re-encoding. A lossy source is left alone: sending an mp3 through
    /// Opus at 160k spends CPU to make it worse.
    private static let lossless: Set<AVCodecID> = [
        AV_CODEC_ID_FLAC, AV_CODEC_ID_ALAC, AV_CODEC_ID_APE, AV_CODEC_ID_WAVPACK,
        AV_CODEC_ID_TTA, AV_CODEC_ID_TAK,
        AV_CODEC_ID_PCM_S16LE, AV_CODEC_ID_PCM_S24LE, AV_CODEC_ID_PCM_S32LE,
        AV_CODEC_ID_PCM_S16BE, AV_CODEC_ID_PCM_S24BE, AV_CODEC_ID_PCM_F32LE,
    ]

    /// Opus is a 48 kHz codec; anything else would be resampled inside the encoder.
    private static let rate: Int32 = 48_000

    enum Failure: Error, LocalizedError {
        case open(String), noAudio, decoder, encoderMissing, ff(String, Int32)

        var errorDescription: String? {
            switch self {
            case .open(let path): return "Could not open \(path)."
            case .noAudio: return "No audio in that file."
            case .decoder: return "No decoder for that file."
            case .encoderMissing: return "This build has no Opus encoder."
            case .ff(let what, let code): return "\(what) failed: \(FFErr.string(code))"
            }
        }
    }

    /// Whether re-encoding this file would gain anything. Decided by the codec inside,
    /// not the extension: an `.m4a` is usually AAC and sometimes ALAC.
    static func isLossless(_ url: URL) -> Bool {
        var fmt: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&fmt, url.path, nil, nil) == 0 else { return false }
        defer { avformat_close_input(&fmt) }
        guard avformat_find_stream_info(fmt, nil) >= 0 else { return false }
        let index = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        guard index >= 0, let stream = fmt?.pointee.streams[Int(index)] else { return false }
        return lossless.contains(stream.pointee.codecpar.pointee.codec_id)
    }

    /// Transcode `source` into `destination` (an `.opus` path), at `bitrate` bits per
    /// second. Tags are carried over; embedded cover art is not, because the Ogg-Opus
    /// muxer has nowhere to put an attached picture — the folder's own cover travels
    /// with the album instead.
    static func encode(_ source: URL, to destination: URL, bitrate: Int = 160_000) throws {
        var input: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&input, source.path, nil, nil) == 0 else {
            throw Failure.open(source.lastPathComponent)
        }
        defer { avformat_close_input(&input) }
        guard avformat_find_stream_info(input, nil) >= 0 else { throw Failure.noAudio }

        let index = av_find_best_stream(input, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        guard index >= 0, let inStream = input?.pointee.streams[Int(index)] else { throw Failure.noAudio }

        guard let decoder = avcodec_find_decoder(inStream.pointee.codecpar.pointee.codec_id),
              let dec = avcodec_alloc_context3(decoder) else { throw Failure.decoder }
        var decCtx: UnsafeMutablePointer<AVCodecContext>? = dec
        defer { avcodec_free_context(&decCtx) }
        guard avcodec_parameters_to_context(dec, inStream.pointee.codecpar) >= 0,
              avcodec_open2(dec, decoder, nil) >= 0 else { throw Failure.decoder }

        guard let encoder = avcodec_find_encoder_by_name("libopus"),
              let enc = avcodec_alloc_context3(encoder) else { throw Failure.encoderMissing }
        var encCtx: UnsafeMutablePointer<AVCodecContext>? = enc
        defer { avcodec_free_context(&encCtx) }

        let channels = min(max(dec.pointee.ch_layout.nb_channels, 1), 2)
        av_channel_layout_default(&enc.pointee.ch_layout, channels)
        enc.pointee.sample_rate = rate
        enc.pointee.sample_fmt = AV_SAMPLE_FMT_FLT
        enc.pointee.bit_rate = Int64(bitrate)
        enc.pointee.time_base = AVRational(num: 1, den: rate)

        var output: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&output, nil, nil, destination.path) >= 0,
              let out = output else { throw Failure.open(destination.lastPathComponent) }
        defer { avformat_free_context(out) }
        if out.pointee.oformat.pointee.flags & AVFMT_GLOBALHEADER != 0 {
            enc.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER
        }

        var code = avcodec_open2(enc, encoder, nil)
        guard code >= 0 else { throw Failure.ff("Opening the Opus encoder", code) }

        guard let outStream = avformat_new_stream(out, nil) else { throw Failure.encoderMissing }
        guard avcodec_parameters_from_context(outStream.pointee.codecpar, enc) >= 0 else {
            throw Failure.encoderMissing
        }
        outStream.pointee.time_base = enc.pointee.time_base
        // FLAC keeps its tags on the container, Ogg on the stream; take both.
        av_dict_copy(&out.pointee.metadata, input?.pointee.metadata, 0)
        av_dict_copy(&out.pointee.metadata, inStream.pointee.metadata, AV_DICT_DONT_OVERWRITE)
        if let picture = pictureBlock(input) {
            av_dict_set(&out.pointee.metadata, "METADATA_BLOCK_PICTURE", picture, 0)
        }

        code = avio_open(&out.pointee.pb, destination.path, AVIO_FLAG_WRITE)
        guard code >= 0 else { throw Failure.ff("Creating \(destination.lastPathComponent)", code) }
        defer { avio_closep(&out.pointee.pb) }

        code = avformat_write_header(out, nil)
        guard code >= 0 else { throw Failure.ff("Writing the Opus header", code) }

        var swr: OpaquePointer?
        code = swr_alloc_set_opts2(&swr,
                                   &enc.pointee.ch_layout, AV_SAMPLE_FMT_FLT, rate,
                                   &dec.pointee.ch_layout, dec.pointee.sample_fmt, dec.pointee.sample_rate,
                                   0, nil)
        guard code >= 0, swr_init(swr) >= 0 else { throw Failure.ff("Resampling", code) }
        defer { swr_free(&swr) }

        let writer = Writer(out: out, stream: outStream, enc: enc, channels: Int(channels))
        defer { writer.release() }

        let packet = av_packet_alloc()
        let frame = av_frame_alloc()
        defer {
            var p = packet; av_packet_free(&p)
            var f = frame; av_frame_free(&f)
        }

        while av_read_frame(input, packet) >= 0 {
            defer { av_packet_unref(packet) }
            guard packet?.pointee.stream_index == index else { continue }
            guard avcodec_send_packet(dec, packet) >= 0 else { continue }
            while avcodec_receive_frame(dec, frame) >= 0 {
                try writer.append(resample(swr, frame, channels: Int(channels)))
                av_frame_unref(frame)
            }
        }
        // Flush the decoder, then whatever the resampler is still holding.
        avcodec_send_packet(dec, nil)
        while avcodec_receive_frame(dec, frame) >= 0 {
            try writer.append(resample(swr, frame, channels: Int(channels)))
            av_frame_unref(frame)
        }
        try writer.append(resample(swr, nil, channels: Int(channels)))
        try writer.finish()

        code = av_write_trailer(out)
        guard code >= 0 else { throw Failure.ff("Finishing the Opus file", code) }
    }

    /// The source's embedded cover, as the base64 FLAC picture block that Ogg files
    /// carry it in.
    ///
    /// The Ogg muxer will not take an attached-picture *stream*, so the art has to be
    /// handed over as a Vorbis comment instead — and it has to be, because the app
    /// reads artwork out of the file and nowhere else. A folder's `cover.jpg` is not
    /// currently a source of album art.
    private static func pictureBlock(_ input: UnsafeMutablePointer<AVFormatContext>?) -> String? {
        guard let input else { return nil }
        for index in 0..<Int(input.pointee.nb_streams) {
            guard let stream = input.pointee.streams[index],
                  stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC != 0,
                  let par = stream.pointee.codecpar?.pointee,
                  let bytes = stream.pointee.attached_pic.data,
                  stream.pointee.attached_pic.size > 0 else { continue }
            let mime: String
            switch par.codec_id {
            case AV_CODEC_ID_MJPEG: mime = "image/jpeg"
            case AV_CODEC_ID_PNG: mime = "image/png"
            default: continue
            }

            var block = Data()
            func append(_ value: Int32) {
                var big = UInt32(bitPattern: value).bigEndian
                withUnsafeBytes(of: &big) { block.append(contentsOf: $0) }
            }
            append(3)                                   // front cover
            append(Int32(mime.utf8.count)); block.append(contentsOf: Array(mime.utf8))
            append(0)                                   // no description
            append(max(par.width, 0)); append(max(par.height, 0))
            append(24); append(0)                       // depth, and not a palette
            append(stream.pointee.attached_pic.size)
            block.append(UnsafeBufferPointer(start: bytes, count: Int(stream.pointee.attached_pic.size)))
            return block.base64EncodedString()
        }
        return nil
    }

    /// One decoded frame as interleaved 48 kHz floats. Passing a nil frame drains the
    /// resampler's own buffer, which holds back a few samples for its filter.
    private static func resample(_ swr: OpaquePointer?, _ frame: UnsafeMutablePointer<AVFrame>?,
                                 channels: Int) -> [Float] {
        let incoming = frame.map { Int64($0.pointee.nb_samples) } ?? 0
        let capacity = Int(swr_get_out_samples(swr, Int32(incoming)))
        guard capacity > 0 else { return [] }

        var out = [Float](repeating: 0, count: capacity * channels)
        let produced: Int32 = out.withUnsafeMutableBufferPointer { buffer in
            var plane: UnsafeMutablePointer<UInt8>? =
                UnsafeMutablePointer(OpaquePointer(buffer.baseAddress!))
            return withUnsafeMutablePointer(to: &plane) { planes in
                let input = frame?.pointee.extended_data.map {
                    UnsafePointer<UnsafePointer<UInt8>?>(OpaquePointer($0))
                }
                return swr_convert(swr, planes, Int32(capacity), input, Int32(incoming))
            }
        }
        guard produced > 0 else { return [] }
        return Array(out.prefix(Int(produced) * channels))
    }

    /// Cuts the resampled stream into the encoder's fixed frame size and writes what
    /// comes back. Opus frames are 20 ms by default, so nothing but the last one is
    /// ever short.
    private final class Writer {
        private let out: UnsafeMutablePointer<AVFormatContext>
        private let stream: UnsafeMutablePointer<AVStream>
        private let enc: UnsafeMutablePointer<AVCodecContext>
        private let channels: Int
        private let frameSize: Int
        private var pending: [Float] = []
        private var pts: Int64 = 0
        private var frame: UnsafeMutablePointer<AVFrame>?
        private var packet: UnsafeMutablePointer<AVPacket>?

        init(out: UnsafeMutablePointer<AVFormatContext>, stream: UnsafeMutablePointer<AVStream>,
             enc: UnsafeMutablePointer<AVCodecContext>, channels: Int) {
            self.out = out
            self.stream = stream
            self.enc = enc
            self.channels = channels
            self.frameSize = enc.pointee.frame_size > 0 ? Int(enc.pointee.frame_size) : 960
            self.packet = av_packet_alloc()
            self.frame = av_frame_alloc()
            frame?.pointee.format = AV_SAMPLE_FMT_FLT.rawValue
            frame?.pointee.sample_rate = enc.pointee.sample_rate
            frame?.pointee.nb_samples = Int32(frameSize)
            av_channel_layout_copy(&frame!.pointee.ch_layout, &enc.pointee.ch_layout)
            av_frame_get_buffer(frame, 0)
        }

        func release() {
            av_frame_free(&frame)
            av_packet_free(&packet)
        }

        func append(_ samples: [Float]) throws {
            pending.append(contentsOf: samples)
            while pending.count >= frameSize * channels {
                try emit(Array(pending.prefix(frameSize * channels)), count: frameSize)
                pending.removeFirst(frameSize * channels)
            }
        }

        func finish() throws {
            if !pending.isEmpty {
                let count = pending.count / channels
                try emit(pending, count: count)
                pending.removeAll()
            }
            try send(nil)
        }

        private func emit(_ samples: [Float], count: Int) throws {
            guard let frame else { return }
            av_frame_make_writable(frame)
            frame.pointee.nb_samples = Int32(count)
            frame.pointee.pts = pts
            pts += Int64(count)
            samples.withUnsafeBufferPointer { source in
                frame.pointee.data.0?.withMemoryRebound(to: Float.self, capacity: samples.count) {
                    $0.update(from: source.baseAddress!, count: samples.count)
                }
            }
            try send(frame)
        }

        private func send(_ frame: UnsafeMutablePointer<AVFrame>?) throws {
            let code = avcodec_send_frame(enc, frame)
            guard code >= 0 else { throw Failure.ff("Encoding", code) }
            while avcodec_receive_packet(enc, packet) >= 0 {
                av_packet_rescale_ts(packet, enc.pointee.time_base, stream.pointee.time_base)
                packet?.pointee.stream_index = stream.pointee.index
                let written = av_interleaved_write_frame(out, packet)
                av_packet_unref(packet)
                guard written >= 0 else { throw Failure.ff("Writing", written) }
            }
        }
    }
}
