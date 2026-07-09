import Foundation

/// Verifies embedded album-art extraction via FFmpeg. Gated by MUON_ARTWORK_TEST.
@MainActor
enum ArtworkSelfTest {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["MUON_ARTWORK_TEST"] != nil }

    static func run(library: LibraryStore) async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let all = await library.allTracks()
        var lines: [String] = []
        for t in all where t.hasArtwork {
            if let img = await library.artwork(forPath: t.url.path) {
                lines.append("\(t.url.lastPathComponent): \(Int(img.size.width))x\(Int(img.size.height))")
            } else {
                lines.append("\(t.url.lastPathComponent): FAILED")
            }
        }
        let report = lines.isEmpty ? "no-artwork-tracks" : lines.joined(separator: "\n")
        try? report.write(to: docs.appendingPathComponent("artwork.done"), atomically: true, encoding: .utf8)
        NSLog("ARTWORKTEST:\n\(report)")
    }
}
