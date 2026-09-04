import Foundation
import Network
import Observation
import UIKit

/// The phone half of the Wi-Fi transfer. It advertises `_muon._tcp` while the app is
/// running and writes what the Mac sends straight into Documents, at the path the Mac
/// asked for — which is that file's path relative to its Mac library folder, so an
/// album filed under `Arab Strap` there arrives under `Arab Strap` here.
///
/// Anyone on the network can find the service, so the first transfer from a machine
/// asks before it writes anything, and the answer is remembered per machine.
@MainActor
@Observable
final class TransferReceiver {

    struct Sender: Sendable, Hashable {
        var id: String
        var name: String
    }

    struct TrustRequest: Identifiable {
        let id = UUID()
        let sender: Sender
        let respond: @MainActor (Bool) -> Void
    }

    struct Status {
        var done: Int
        var total: Int
        var current: String
    }

    /// A machine we have never heard from, waiting on the user's answer.
    private(set) var pendingTrust: TrustRequest?
    /// Non-nil while a batch is arriving, and for a moment after it lands.
    private(set) var status: Status?

    /// Called once a batch has settled, to fold the new files into the library.
    var onFinished: (() async -> Void)?

    nonisolated let root: URL

    private var listener: NWListener?
    private var trusted: [String: String]
    private var refused: Set<String> = []
    private var settleTask: Task<Void, Never>?

    private static let trustedKey = "trustedSenders"

    init(root: URL = LibraryRoot.documents.url) {
        self.root = root
        self.trusted = UserDefaults.standard.dictionary(forKey: Self.trustedKey) as? [String: String] ?? [:]
    }

    /// Machines allowed to send, newest name first — Settings lists them so a trust
    /// granted once can be taken back.
    var trustedSenders: [Sender] {
        trusted.map { Sender(id: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
    }

    func forget(_ sender: Sender) {
        trusted[sender.id] = nil
        UserDefaults.standard.set(trusted, forKey: Self.trustedKey)
    }

    // MARK: - The listener

    /// Idempotent: called at launch and again whenever the app returns to the front,
    /// since a suspended app loses its listener.
    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params) else { return }
        listener.service = NWListener.Service(name: UIDevice.current.name, type: MuonTransfer.serviceType)
        listener.stateUpdateHandler = { [weak self] state in
            guard case .failed = state else { return }
            Task { @MainActor in self?.restart() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.serve(connection) }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    private func restart() {
        listener?.cancel()
        listener = nil
        start()
    }

    // MARK: - Serving a connection

    /// One connection carries a whole batch: a manifest, then the files the phone
    /// said it wanted. It runs off the main actor — the body of a FLAC goes to disk
    /// here — and hops back only to ask about trust and to move the progress bar.
    private nonisolated func serve(_ connection: NWConnection) async {
        let stream = NWStream(connection)
        defer { stream.cancel() }
        do {
            try await stream.start()
            while let head = try await stream.readHead() {
                try await handle(head, on: stream)
            }
        } catch {
            // A sender that hangs up mid-batch leaves the files it did send; the
            // settle pass folds those in and the rest arrive on the next attempt.
        }
    }

    private nonisolated func handle(_ head: HTTPHead, on stream: NWStream) async throws {
        let sender = Sender(
            id: head.headers[MuonTransfer.Header.sender.lowercased()] ?? "",
            name: head.headers[MuonTransfer.Header.senderName.lowercased()]?.removingPercentEncoding ?? "A Mac"
        )

        switch (head.method, head.target) {
        case ("POST", "/manifest"):
            let body = try await stream.read(head.contentLength)
            guard await authorize(sender) else { return try await reply(stream, 403, "not trusted") }
            let manifest = try JSONDecoder().decode(TransferManifest.self, from: body)
            let wanted = manifest.files.indices.filter { needs(manifest.files[$0]) }
            await begin(count: wanted.count)
            let json = try JSONEncoder().encode(TransferManifestReply(wanted: wanted))
            try await reply(stream, 200, body: json, type: "application/json")

        case ("POST", "/file"):
            guard await isTrusted(sender.id) else {
                _ = try await stream.read(head.contentLength)
                return try await reply(stream, 403, "not trusted")
            }
            let relative = head.headers[MuonTransfer.Header.path.lowercased()]?.removingPercentEncoding ?? ""
            guard let destination = MuonTransfer.destination(for: relative, under: root) else {
                _ = try await stream.read(head.contentLength)
                return try await reply(stream, 400, "illegal path")
            }
            try await receive(head.contentLength, to: destination, on: stream,
                              mtime: Double(head.headers["x-muon-mtime"] ?? ""))
            await recorded(destination.lastPathComponent)
            try await reply(stream, 201, "ok")

        default:
            _ = try await stream.read(head.contentLength)
            try await reply(stream, 404, "no such thing")
        }
    }

    /// Stream the body into a hidden staging folder, then move it into place. The move
    /// is what makes a half-written file impossible for the scanner to see; the staging
    /// folder is dot-prefixed, and the scanner skips hidden files.
    private nonisolated func receive(_ count: Int, to destination: URL, on stream: NWStream,
                                     mtime: Double?) async throws {
        let fm = FileManager.default
        let staging = root.appendingPathComponent(".muon-incoming", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let temp = staging.appendingPathComponent(UUID().uuidString)
        fm.createFile(atPath: temp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        do {
            try await stream.read(count, into: handle) { _ in }
            try handle.close()
        } catch {
            try? handle.close()
            try? fm.removeItem(at: temp)
            throw error
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: temp, to: destination)
        // Carry the Mac's timestamp across, so the next send knows this copy is current.
        if let mtime {
            try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)],
                                  ofItemAtPath: destination.path)
        }
    }

    /// True if we do not already hold this exact file. A path we would refuse to write
    /// is still asked for, so the refusal happens once, where it can be reported.
    private nonisolated func needs(_ entry: TransferEntry) -> Bool {
        guard let destination = MuonTransfer.destination(for: entry.path, under: root) else { return true }
        return !MuonTransfer.isCurrent(entry, at: destination)
    }

    private nonisolated func reply(_ stream: NWStream, _ code: Int, _ text: String) async throws {
        try await reply(stream, code, body: Data(text.utf8), type: "text/plain")
    }

    private nonisolated func reply(_ stream: NWStream, _ code: Int, body: Data, type: String) async throws {
        let head = "HTTP/1.1 \(code) \(code < 300 ? "OK" : "Error")\r\n" +
                   "Content-Type: \(type)\r\n" +
                   "Content-Length: \(body.count)\r\n\r\n"
        try await stream.write(head)
        try await stream.write(body)
    }

    // MARK: - Main-actor state

    private func isTrusted(_ id: String) -> Bool {
        trusted[id] != nil
    }

    /// Ask about an unknown machine, and hold the transfer until the user answers.
    private func authorize(_ sender: Sender) async -> Bool {
        if trusted[sender.id] != nil { return true }
        guard !sender.id.isEmpty, !refused.contains(sender.id), pendingTrust == nil else { return false }
        return await withCheckedContinuation { continuation in
            pendingTrust = TrustRequest(sender: sender) { [weak self] allowed in
                guard let self else { return continuation.resume(returning: false) }
                if allowed {
                    trusted[sender.id] = sender.name
                    UserDefaults.standard.set(trusted, forKey: Self.trustedKey)
                } else {
                    refused.insert(sender.id)
                }
                pendingTrust = nil
                continuation.resume(returning: allowed)
            }
        }
    }

    private func begin(count: Int) {
        settleTask?.cancel()
        status = count > 0 ? Status(done: 0, total: count, current: "") : nil
    }

    private func recorded(_ name: String) {
        status = Status(done: (status?.done ?? 0) + 1, total: max(status?.total ?? 1, 1), current: name)
        // A batch is over when nothing more has arrived for a couple of seconds. The
        // sender never says so explicitly, because a sender that dies mid-album still
        // leaves files that belong in the library.
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await onFinished?()
            status = nil
        }
    }
}
