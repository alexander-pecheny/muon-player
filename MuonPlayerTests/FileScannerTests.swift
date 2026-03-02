import Testing
import Foundation
@testable import MuonPlayer

@Suite("FileScanner Tests")
struct FileScannerTests {

    private func createTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuonPlayerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func createFile(at directory: URL, name: String) throws {
        let fileURL = directory.appendingPathComponent(name)
        try Data("dummy".utf8).write(to: fileURL)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test("Scanner returns only audio files from mixed directory")
    func scanFindsOnlyAudioFiles() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanup(tempDir) }

        try createFile(at: tempDir, name: "song.mp3")
        try createFile(at: tempDir, name: "track.m4a")
        try createFile(at: tempDir, name: "readme.txt")
        try createFile(at: tempDir, name: "image.png")
        try createFile(at: tempDir, name: "beat.wav")

        let scanner = FileScanner(rootURL: tempDir)
        let tracks = await scanner.scan()

        #expect(tracks.count == 3)
        let extensions = Set(tracks.map { $0.url.pathExtension.lowercased() })
        #expect(extensions == Set(["mp3", "m4a", "wav"]))
    }

    @Test("Scanner recursively scans subdirectories")
    func scanRecursive() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanup(tempDir) }

        let subDir = tempDir.appendingPathComponent("Artist/Album")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        try createFile(at: tempDir, name: "root.mp3")
        try createFile(at: subDir, name: "nested.aac")

        let scanner = FileScanner(rootURL: tempDir)
        let tracks = await scanner.scan()

        #expect(tracks.count == 2)
    }

    @Test("Scanner returns empty array for empty directory")
    func scanEmptyDirectory() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanup(tempDir) }

        let scanner = FileScanner(rootURL: tempDir)
        let tracks = await scanner.scan()

        #expect(tracks.isEmpty)
    }

    @Test("Scanner ignores hidden files")
    func scanIgnoresHiddenFiles() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanup(tempDir) }

        try createFile(at: tempDir, name: "visible.mp3")
        try createFile(at: tempDir, name: ".hidden.mp3")

        let scanner = FileScanner(rootURL: tempDir)
        let tracks = await scanner.scan()

        #expect(tracks.count == 1)
        #expect(tracks[0].url.lastPathComponent == "visible.mp3")
    }

    @Test("Scanner finds all supported extensions")
    func scanAllExtensions() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanup(tempDir) }

        for ext in AudioFormat.supportedExtensions {
            try createFile(at: tempDir, name: "test.\(ext)")
        }

        let scanner = FileScanner(rootURL: tempDir)
        let tracks = await scanner.scan()

        #expect(tracks.count == AudioFormat.supportedExtensions.count)
    }
}
