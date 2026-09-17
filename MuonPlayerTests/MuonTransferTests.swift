import Testing
import Foundation
@testable import MuonPlayer

@Suite("Wi-Fi transfer")
struct MuonTransferTests {

    private let root = URL(fileURLWithPath: "/tmp/muon-root")

    @Test("A relative path keeps the Mac's folder layout")
    func layoutSurvives() {
        let url = MuonTransfer.destination(for: "Arab Strap/Philophobia/01 - Packs Of Three.flac", under: root)
        #expect(url?.path == "/tmp/muon-root/Arab Strap/Philophobia/01 - Packs Of Three.flac")
    }

    @Test("A path that would escape the root is refused, not sanitised", arguments: [
        "../outside.flac",
        "Artist/../../outside.flac",
        "/etc/passwd",
        "",
        "Artist//Album/x.flac",
        "Artist/./x.flac",
        "Artist/x\u{0}.flac",
    ])
    func hostilePathsRefused(path: String) {
        #expect(MuonTransfer.destination(for: path, under: root) == nil)
    }

    @Test("A file with the same size and mtime is not sent twice")
    func skipsWhatIsAlreadyThere() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("track.flac")
        try Data(repeating: 7, count: 1024).write(to: file)
        let mtime = try file.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate!.timeIntervalSince1970

        #expect(MuonTransfer.isCurrent(TransferEntry(path: "x", size: 1024, mtime: mtime), at: file))
        // Half a second of filesystem slop still counts as the same file.
        #expect(MuonTransfer.isCurrent(TransferEntry(path: "x", size: 1024, mtime: mtime - 0.5), at: file))
        #expect(!MuonTransfer.isCurrent(TransferEntry(path: "x", size: 1025, mtime: mtime), at: file))
        #expect(!MuonTransfer.isCurrent(TransferEntry(path: "x", size: 1024, mtime: mtime - 60), at: file))
        #expect(!MuonTransfer.isCurrent(TransferEntry(path: "x", size: 1024, mtime: mtime),
                                        at: dir.appendingPathComponent("absent.flac")))
    }

    @Test("A head parses into a method, a target and lowercased headers")
    func headParsing() {
        let raw = Data("POST /file HTTP/1.1\r\nContent-Length: 42\r\nX-Muon-Path: A%2Fb\r\n".utf8)
        let head = HTTPHead(raw)
        #expect(head?.method == "POST")
        #expect(head?.target == "/file")
        #expect(head?.contentLength == 42)
        #expect(head?.headers["x-muon-path"] == "A%2Fb")
    }
}
