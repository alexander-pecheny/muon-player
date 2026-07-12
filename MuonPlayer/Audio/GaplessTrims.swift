import Foundation

/// Silence to take off the ends of a track that the file itself does not declare —
/// encoder delay at the head, padding at the tail, in samples at the file's own rate.
///
/// An mp3 with no Xing/LAME header, or an AAC with neither an edit list nor `iTunSMPB`,
/// decodes with the encoder's priming and padding as if they were music. Nothing in the
/// file says where the music really starts and stops, so `GaplessMaintenance` measures
/// it and this is what it found.
struct GaplessTrim: Equatable, Sendable {
    var head: Int
    var tail: Int

    var isEmpty: Bool { head == 0 && tail == 0 }
}

/// The measured trims, by path, for the decoder to consult.
///
/// A registry rather than a field on `Track` because the decoder is opened on the
/// player's feed queue from a `Track` that several different SELECTs build — and a
/// waveform is drawn from a third place that has no `Track` at all. Threading a column
/// through all of them to reach one `if` inside `FFmpegDecoder` buys nothing; this way
/// every decode in the app trims alike, whoever opened it.
///
/// Populated by `LibraryStore` after each scan, read on decode queues.
final class GaplessTrims: @unchecked Sendable {
    static let shared = GaplessTrims()

    private let lock = NSLock()
    private var byPath: [String: GaplessTrim] = [:]

    func replaceAll(_ trims: [String: GaplessTrim]) {
        lock.lock(); byPath = trims; lock.unlock()
    }

    func set(_ trim: GaplessTrim, for path: String) {
        lock.lock(); byPath[path] = trim; lock.unlock()
    }

    func trim(for path: String) -> GaplessTrim? {
        lock.lock(); defer { lock.unlock() }
        return byPath[path]
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return byPath.count
    }
}
