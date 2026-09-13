import Testing
import Foundation
@testable import MuonPlayer

@Suite("Folder Walk Tests")
struct FolderWalkTests {

    private func createTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuonPlayerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func createFile(at directory: URL, name: String) throws {
        try Data("dummy".utf8).write(to: directory.appendingPathComponent(name))
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test("The walk returns only audio files from a mixed directory")
    func walkFindsOnlyAudioFiles() throws {
        let tempDir = try createTempDirectory()
        defer { cleanup(tempDir) }

        try createFile(at: tempDir, name: "song.mp3")
        try createFile(at: tempDir, name: "track.m4a")
        try createFile(at: tempDir, name: "readme.txt")
        try createFile(at: tempDir, name: "image.png")
        try createFile(at: tempDir, name: "beat.wav")

        let files = FolderWalk.audioFiles(under: tempDir)

        #expect(files.count == 3)
        #expect(Set(files.map { $0.pathExtension.lowercased() }) == Set(["mp3", "m4a", "wav"]))
    }

    @Test("The walk descends into subdirectories")
    func walkRecursive() throws {
        let tempDir = try createTempDirectory()
        defer { cleanup(tempDir) }

        let subDir = tempDir.appendingPathComponent("Artist/Album")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        try createFile(at: tempDir, name: "root.mp3")
        try createFile(at: subDir, name: "nested.aac")

        #expect(FolderWalk.audioFiles(under: tempDir).count == 2)
    }

    @Test("An empty directory yields nothing")
    func walkEmptyDirectory() throws {
        let tempDir = try createTempDirectory()
        defer { cleanup(tempDir) }

        #expect(FolderWalk.audioFiles(under: tempDir).isEmpty)
    }

    @Test("The walk ignores hidden files")
    func walkIgnoresHiddenFiles() throws {
        let tempDir = try createTempDirectory()
        defer { cleanup(tempDir) }

        try createFile(at: tempDir, name: "visible.mp3")
        try createFile(at: tempDir, name: ".hidden.mp3")

        let files = FolderWalk.audioFiles(under: tempDir)
        #expect(files.count == 1)
        #expect(files[0].lastPathComponent == "visible.mp3")
    }

    @Test("The walk finds every supported extension")
    func walkAllExtensions() throws {
        let tempDir = try createTempDirectory()
        defer { cleanup(tempDir) }

        for ext in AudioFormat.supportedExtensions {
            try createFile(at: tempDir, name: "test.\(ext)")
        }

        #expect(FolderWalk.audioFiles(under: tempDir).count == AudioFormat.supportedExtensions.count)
    }
}
