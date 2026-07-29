import SwiftUI
#if os(Android)
import MuonCore
#endif

/// First thing to run on Android: prove the shared Swift core is really in the
/// APK and working — FFmpeg and SQLite linked, the scanner walking a directory,
/// and the metadata reader parsing a file's tags.
struct CoreProbeView: View {
    @State var scanPath = NSTemporaryDirectory()
    @State var found: [String] = []

    var body: some View {
        Form {
            Section("Core") {
                LabeledContent("FFmpeg", value: ffmpegVersion)
                LabeledContent("SQLite", value: sqliteVersion)
                LabeledContent("Formats", value: "\(supportedExtensions.count)")
            }
            Section("Scanner") {
                TextField("Folder", text: $scanPath)
                Button("Scan") { found = scan(scanPath) }
                if found.isEmpty {
                    Text("No audio files found").foregroundStyle(.secondary)
                } else {
                    ForEach(found, id: \.self) { Text($0).font(.footnote) }
                }
            }
        }
    }

    // On Apple these read the same values through the Xcode target's copy of the
    // core; the port is only interesting when both sides answer identically.
    private var ffmpegVersion: String {
        #if os(Android)
        MuonCore.ffmpegVersion
        #else
        "host"
        #endif
    }

    private var sqliteVersion: String {
        #if os(Android)
        MuonCore.sqliteVersion
        #else
        "host"
        #endif
    }

    private var supportedExtensions: [String] {
        #if os(Android)
        MuonCore.supportedExtensions
        #else
        []
        #endif
    }

    /// Reports what FFmpeg made of each file it found, so a green result means the
    /// decoder actually opened and parsed them — not just that the library linked.
    private func scan(_ path: String) -> [String] {
        #if os(Android)
        MuonCore.scanWithTags(path: path)
        #else
        []
        #endif
    }
}
