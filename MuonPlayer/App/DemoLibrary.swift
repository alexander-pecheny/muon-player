import Foundation

/// Seeds the library with the bundled demo album the first time the app opens
/// with nothing to play. A fresh install otherwise lands on an empty screen that
/// says nothing about whether the player works — which is also all an App Review
/// device would ever see, since the library is whatever the user has put in
/// Documents.
enum DemoLibrary {
    private static let seededKey = "demoLibrary.seeded"

    /// Runs once ever, not once per empty launch: someone who deletes the demo
    /// should not find it back on the next start.
    static func seedIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        UserDefaults.standard.set(true, forKey: seededKey)

        let bundled = Bundle.main.urls(forResourcesWithExtension: "flac", subdirectory: nil) ?? []
        let documents = LibraryRoot.documents.url
        guard !bundled.isEmpty, !holdsAudio(documents) else { return }

        let album = documents
            .appendingPathComponent("MuonPlayer", isDirectory: true)
            .appendingPathComponent("Muon Demo", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
            for track in bundled {
                let destination = album.appendingPathComponent(track.lastPathComponent)
                guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
                try FileManager.default.copyItem(at: track, to: destination)
            }
        } catch {
            print("Demo album seed failed: \(error)")
        }
    }

    private static func holdsAudio(_ documents: URL) -> Bool {
        guard let files = FileManager.default.enumerator(
            at: documents, includingPropertiesForKeys: nil) else { return false }
        for case let url as URL in files
        where AudioFormat.supportedExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }
        return false
    }
}
