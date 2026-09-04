import Foundation
import Network

/// Sending music from the Mac to the phone over Wi-Fi.
///
/// The phone advertises `_muon._tcp` while MuonPlayer is on screen; the Mac app and
/// `scripts/muon-send.swift` browse for it and speak HTTP/1.1 over the connection.
/// Both ends are ours, so the framing could have been anything — HTTP is what keeps
/// the receiver answerable to `curl` when a transfer misbehaves.
///
/// A file's destination is its path relative to the library root it came from, so
/// `~/Music/Arab Strap/Philophobia/01.flac` lands at `Documents/Arab Strap/Philophobia/01.flac`:
/// the Mac's chosen folder and the phone's single root mirror each other, and nothing
/// has to remember a mapping.
enum MuonTransfer {
    static let serviceType = "_muon._tcp"

    enum Header {
        static let path = "X-Muon-Path"
        static let sender = "X-Muon-Sender"
        static let senderName = "X-Muon-Sender-Name"
    }

    /// Two copies of a file count as the same one if size and mtime agree. Filesystems
    /// disagree about sub-second timestamps, so a second of slack.
    static let mtimeTolerance: TimeInterval = 1

    /// Everything worth carrying along with the music: the audio the scanner indexes,
    /// plus the cover art it reads out of the folder.
    static let sendableExtensions: Set<String> =
        AudioFormat.supportedExtensions.union(FileScanner.FolderArt.extensions)

    /// Where `relativePath` lands under `root`, or nil if it may not land anywhere.
    ///
    /// The receiver must treat the path as hostile: an absolute path or one climbing
    /// out with `..` is refused outright rather than sanitised, because a silently
    /// rewritten path files music somewhere the sender did not ask for.
    static func destination(for relativePath: String, under root: URL) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return nil }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 0 else { return nil }
        for part in parts where part.isEmpty || part == "." || part == ".." { return nil }
        let base = root.standardizedFileURL
        let url = parts.reduce(base) { $0.appendingPathComponent(String($1)) }
        guard url.standardizedFileURL.path.hasPrefix(base.path + "/") else { return nil }
        return url
    }

    /// True if `url` already holds the file `entry` describes, so it need not be sent
    /// again. Size and mtime are all the sender knows; hashing an album to find out
    /// would cost more than resending it.
    static func isCurrent(_ entry: TransferEntry, at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate
        else { return false }
        guard abs(modified.timeIntervalSince1970 - entry.mtime) <= mtimeTolerance else { return false }
        // A transcode's size is whatever the encoder produced; the mtime carried over
        // from its source is the only thing the two ends can agree on in advance.
        return entry.size == TransferEntry.sizeUnknown || Int64(size) == entry.size
    }
}

/// One file the sender is offering.
struct TransferEntry: Codable, Sendable, Hashable {
    var path: String
    /// `sizeUnknown` when the sender will encode the file on the way and cannot say
    /// how big it will be until it has.
    var size: Int64
    var mtime: Double

    static let sizeUnknown: Int64 = -1
}

struct TransferManifest: Codable, Sendable {
    var senderID: String
    var senderName: String
    var files: [TransferEntry]
}

/// The indices of `files` the receiver does not already hold.
struct TransferManifestReply: Codable, Sendable {
    var wanted: [Int]
}

enum TransferError: Error, LocalizedError {
    case connectionClosed
    case http(Int, String)
    case refused
    case noReceiver
    case badPath(String)
    case notUnderRoot(String)
    case nothingToSend

    var errorDescription: String? {
        switch self {
        case .connectionClosed: return "The connection closed early."
        case .http(let code, let body): return "The phone answered \(code) \(body)."
        case .refused: return "The phone refused the transfer."
        case .noReceiver: return "No phone found. Open MuonPlayer on it, on the same network."
        case .badPath(let path): return "Illegal destination path: \(path)"
        case .notUnderRoot(let path): return "\(path) is not inside a library folder."
        case .nothingToSend: return "No audio files there."
        }
    }
}

// MARK: - HTTP framing

/// A parsed request or response head. Header names are lowercased, since HTTP's are
/// case-insensitive and only one side of this conversation is ours to spell.
struct HTTPHead {
    let words: [String]
    let headers: [String: String]

    var method: String { words.first ?? "" }
    var target: String { words.count > 1 ? words[1] : "" }
    var statusCode: Int { words.count > 1 ? Int(words[1]) ?? 0 : 0 }
    var contentLength: Int { Int(headers["content-length"] ?? "") ?? 0 }

    init?(_ raw: Data) {
        guard let text = String(data: raw, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first, !first.isEmpty else { return nil }
        words = first.split(separator: " ", maxSplits: 2).map(String.init)
        lines.removeFirst()
        var found: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            found[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        headers = found
    }
}

/// A byte stream over an `NWConnection`, with the buffering HTTP framing needs.
///
/// An actor rather than a class because both ends hand the same stream between tasks —
/// the receiver's header parse and its streaming body write, the sender's upload and
/// its response read.
actor NWStream {
    private let connection: NWConnection
    private var buffer = Data()
    private var atEnd = false

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    /// Open the connection and wait for it to be usable.
    ///
    /// `.waiting` is not treated as failure: a peer-to-peer link routinely reports the
    /// network as down for a moment while it comes up. The timeout is what decides that
    /// a phone is not answering.
    func start(timeout: TimeInterval = 10) async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { cont.resume() }
                case .failed(let error):
                    if once.claim() { cont.resume(throwing: error) }
                case .cancelled:
                    if once.claim() { cont.resume(throwing: TransferError.connectionClosed) }
                default:
                    break
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { cont.resume(throwing: TransferError.noReceiver) }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    nonisolated func cancel() {
        connection.cancel()
    }

    private func fill() async throws {
        guard !atEnd else { throw TransferError.connectionClosed }
        let chunk: Data? = try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error) }
                else if let data, !data.isEmpty { cont.resume(returning: data) }
                else if isComplete { cont.resume(returning: nil) }
                else { cont.resume(returning: Data()) }
            }
        }
        guard let chunk else { atEnd = true; throw TransferError.connectionClosed }
        buffer.append(chunk)
    }

    /// The next head, without its blank-line terminator. Nil when the peer hung up
    /// between requests, which on a keep-alive connection is how a batch ends.
    func readHead() async throws -> HTTPHead? {
        let terminator = Data("\r\n\r\n".utf8)
        while true {
            if let range = buffer.range(of: terminator) {
                let raw = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                guard let head = HTTPHead(raw) else { throw TransferError.connectionClosed }
                return head
            }
            do { try await fill() } catch {
                if buffer.isEmpty { return nil }
                throw error
            }
        }
    }

    func read(_ count: Int) async throws -> Data {
        while buffer.count < count { try await fill() }
        let out = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(out)
    }

    /// Stream `count` bytes straight to disk. An album of FLACs is not something to
    /// hold in memory on a phone.
    func read(_ count: Int, into handle: FileHandle, onProgress: (Int) -> Void) async throws {
        var left = count
        while left > 0 {
            if buffer.isEmpty { try await fill() }
            let take = min(left, buffer.count)
            try handle.write(contentsOf: buffer.prefix(take))
            buffer.removeFirst(take)
            left -= take
            onProgress(count - left)
        }
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    func write(_ text: String) async throws {
        try await write(Data(text.utf8))
    }
}

/// Resumes a continuation exactly once, whichever of the connection's state and the
/// timeout gets there first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
