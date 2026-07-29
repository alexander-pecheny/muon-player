import SwiftUI
import MuonCore

/// Which build of the shared core is actually inside the APK. Kept around because
/// "the decoder is missing a format" and "the decoder is not linked" look the same
/// from the library screen.
struct CoreProbeView: View {
    var body: some View {
        Form {
            Section("Native") {
                LabeledContent("FFmpeg", value: ffmpegVersion)
                LabeledContent("SQLite", value: sqliteVersion)
                LabeledContent("Output", value: "AAudio")
            }
            Section("Formats (\(supportedExtensions.count))") {
                Text(supportedExtensions.joined(separator: " "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

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
}
