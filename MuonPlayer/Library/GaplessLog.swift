import Foundation

/// A written record of every seam the app judged and every trim it applied.
///
/// The gapless logic changes what you hear — a track is decoded shorter than it is on
/// disk — and, if source rewriting is on, what is on disk. When something sounds wrong,
/// the first question is always "did we touch this file, and what did we think we
/// measured?". Without a log the answer is unrecoverable, so one is kept on both
/// platforms: Application Support, next to the library.
///
///     macOS  ~/Library/Containers/me.pecheny.muonplayer/Data/Library/Application Support/gapless.log
///     iOS    the app container's Application Support (Files.app, or simctl get_app_container)
final class GaplessLog: @unchecked Sendable {
    static let shared = GaplessLog()

    /// Two runs' worth of a big library, then the oldest half is dropped. Long enough to
    /// still hold the run that broke something, short enough never to matter.
    private static let maxBytes = 4 << 20

    private let lock = NSLock()
    private let url: URL
    private lazy var stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    init(name: String = "gapless.log") {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        url = support.appendingPathComponent(name)
    }

    var path: String { url.path }

    func log(_ message: String) {
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
        trimIfNeeded()
    }

    private func trimIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        guard size > Self.maxBytes else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.suffix(lines.count / 2).joined(separator: "\n")
        try? kept.data(using: .utf8)?.write(to: url)
    }
}
