import Foundation
import Network

/// The Mac half of the Wi-Fi transfer: find the phone, ask what it is missing, send it.
///
/// It sits in the Mac target rather than `Shared` because `Host.current()` does not exist
/// on iOS. `scripts/muon-send.swift` compiles this file directly, the way
/// `muon-albumartist.swift` compiles against `TagWriter`.
enum TransferSender {

    struct Peer: Identifiable, Sendable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    /// A file and the path it should occupy on the phone.
    struct Item: Sendable, Hashable {
        let url: URL
        let relativePath: String
        /// Send an encoded copy rather than the file itself. `send`'s `encode` makes it.
        var transcode = false

        func transcoded(to ext: String) -> Item {
            Item(url: url,
                 relativePath: (relativePath as NSString).deletingPathExtension + "." + ext,
                 transcode: true)
        }
    }

    struct Progress: Sendable {
        var fileIndex: Int
        var fileCount: Int
        var name: String
        var bytesSent: Int64
        var bytesTotal: Int64
    }

    /// Who the phone is being asked to trust. The id is stable across launches so the
    /// question is asked once per machine, not once per transfer.
    struct Identity: Sendable {
        var id: String
        var name: String

        static func local(suffix: String? = nil) -> Identity {
            let key = "muonSenderID"
            let stored = UserDefaults.standard.string(forKey: key) ?? {
                let fresh = UUID().uuidString
                UserDefaults.standard.set(fresh, forKey: key)
                return fresh
            }()
            var name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            if let suffix { name += " (\(suffix))" }
            return Identity(id: stored, name: name)
        }
    }

    // MARK: - What to send

    /// Expand folders, drop everything that is not music or cover art, and work out
    /// where each file belongs on the phone.
    ///
    /// The destination is the file's path relative to the library root holding it, so
    /// the folder layout survives the trip. A file under no root has no answer to that
    /// question and is an error rather than a guess.
    static func items(for urls: [URL], roots: [LibraryRoot]) throws -> [Item] {
        let fm = FileManager.default
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let walker = fm.enumerator(at: url, includingPropertiesForKeys: nil,
                                           options: [.skipsHiddenFiles])
                while let child = walker?.nextObject() as? URL {
                    files.append(child)
                }
            } else {
                files.append(url)
            }
        }

        var items: [Item] = []
        var seen = Set<String>()
        for file in files {
            guard MuonTransfer.sendableExtensions.contains(file.pathExtension.lowercased()) else { continue }
            let path = LibraryRoot.canonicalPath(of: file)
            guard seen.insert(path).inserted else { continue }
            guard let relative = roots.compactMap({ $0.relativePath(of: path) }).first else {
                throw TransferError.notUnderRoot(file.path)
            }
            items.append(Item(url: file, relativePath: relative))
        }
        guard !items.isEmpty else { throw TransferError.nothingToSend }
        return items.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    // MARK: - Finding the phone

    /// Browse for receivers, returning as soon as the set of them stops growing.
    /// A phone on the same Wi-Fi answers in well under a second; peer-to-peer is on,
    /// so one with Wi-Fi off but AirDrop reachable answers too.
    static func discover(timeout: TimeInterval = 3) async -> [Peer] {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: MuonTransfer.serviceType, domain: nil), using: params)
        let box = ResultBox()
        browser.browseResultsChangedHandler = { results, _ in
            box.set(results.compactMap { result in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return Peer(name: name, endpoint: result.endpoint)
            })
        }
        browser.start(queue: .global(qos: .userInitiated))
        defer { browser.cancel() }

        var previous: [Peer] = []
        for _ in 0..<Int(timeout / 0.1) {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let now = box.get()
            if !now.isEmpty && now.count == previous.count { return now }
            previous = now
        }
        return previous
    }

    // MARK: - Sending

    /// Send everything the phone does not already hold. Returns the number of files written.
    ///
    /// `encode` turns an item marked `transcode` into a temporary file to send in its
    /// place. It runs only for files the phone actually wants, which is why a
    /// transcoded item offers no size in the manifest: nobody knows it until the
    /// encoder has run, and running it for a file already on the phone is exactly the
    /// work worth skipping.
    @discardableResult
    static func send(_ items: [Item], to peer: Peer, as identity: Identity,
                     encode: (@Sendable (Item) throws -> URL)? = nil,
                     onProgress: @Sendable @escaping (Progress) -> Void) async throws -> Int {
        let entries = try items.map { item -> TransferEntry in
            let values = try item.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return TransferEntry(path: item.relativePath,
                                 size: item.transcode ? TransferEntry.sizeUnknown : Int64(values.fileSize ?? 0),
                                 mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }

        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let stream = NWStream(NWConnection(to: peer.endpoint, using: params))
        defer { stream.cancel() }
        try await stream.start()

        let manifest = TransferManifest(senderID: identity.id, senderName: identity.name, files: entries)
        let body = try JSONEncoder().encode(manifest)
        let reply = try await request(stream, "POST", "/manifest", headers: [:], body: body, identity: identity)
        let wanted = try JSONDecoder().decode(TransferManifestReply.self, from: reply).wanted

        let total = wanted.reduce(Int64(0)) { $0 + max(0, entries[$1].size) }
        var sent: Int64 = 0
        for (n, index) in wanted.enumerated() {
            let item = items[index]
            var entry = entries[index]
            onProgress(Progress(fileIndex: n, fileCount: wanted.count,
                                name: item.url.lastPathComponent,
                                bytesSent: sent, bytesTotal: total))

            var payload = item.url
            var temporary: URL?
            if item.transcode, let encode {
                payload = try encode(item)
                temporary = payload
            }
            entry.size = Int64((try? payload.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }

            try await upload(stream, file: payload, entry: entry, identity: identity)
            sent += entry.size
        }
        onProgress(Progress(fileIndex: wanted.count, fileCount: wanted.count,
                            name: "", bytesSent: sent, bytesTotal: total))
        return wanted.count
    }

    private static func upload(_ stream: NWStream, file: URL, entry: TransferEntry,
                               identity: Identity) async throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        let encoded = entry.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        try await stream.write(head("POST", "/file", identity: identity, [
            MuonTransfer.Header.path: encoded,
            "X-Muon-Mtime": String(entry.mtime),
            "Content-Length": String(entry.size),
        ]))

        var left = entry.size
        while left > 0 {
            let chunk = try handle.read(upToCount: min(Int(left), 1 << 18)) ?? Data()
            guard !chunk.isEmpty else { throw TransferError.connectionClosed }
            try await stream.write(chunk)
            left -= Int64(chunk.count)
        }
        _ = try await response(stream)
    }

    private static func request(_ stream: NWStream, _ method: String, _ target: String,
                                headers: [String: String], body: Data,
                                identity: Identity) async throws -> Data {
        var all = headers
        all["Content-Length"] = String(body.count)
        try await stream.write(head(method, target, identity: identity, all))
        try await stream.write(body)
        return try await response(stream)
    }

    private static func head(_ method: String, _ target: String, identity: Identity,
                             _ headers: [String: String]) -> String {
        var lines = ["\(method) \(target) HTTP/1.1"]
        lines.append("Host: muon")
        lines.append("\(MuonTransfer.Header.sender): \(identity.id)")
        lines.append("\(MuonTransfer.Header.senderName): " +
                     (identity.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "Mac"))
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            lines.append("\(name): \(value)")
        }
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    private static func response(_ stream: NWStream) async throws -> Data {
        guard let head = try await stream.readHead() else { throw TransferError.connectionClosed }
        let body = try await stream.read(head.contentLength)
        switch head.statusCode {
        case 200, 201: return body
        case 403: throw TransferError.refused
        default: throw TransferError.http(head.statusCode, String(data: body, encoding: .utf8) ?? "")
        }
    }
}

/// `browseResultsChangedHandler` fires on the browser's queue; the discovery loop
/// reads from another.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [TransferSender.Peer] = []

    func set(_ new: [TransferSender.Peer]) {
        lock.lock(); peers = new; lock.unlock()
    }

    func get() -> [TransferSender.Peer] {
        lock.lock(); defer { lock.unlock() }; return peers
    }
}
