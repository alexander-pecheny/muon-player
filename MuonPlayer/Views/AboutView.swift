import SwiftUI

/// About screen: app version plus open-source license information. Reached from
/// Settings → About.
struct AboutView: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: version)
            }

            Section {
                Text("MuonPlayer is open-source software, released under the MIT License.")
                Link(destination: URL(string: "https://muonplayer.pecheny.me/privacy")!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
            } header: {
                Text("MuonPlayer")
            }

            Section {
                NavigationLink {
                    LicenseTextView(title: "FFmpeg — LGPL 2.1",
                                    resource: "LGPL-2.1",
                                    header: Self.ffmpegNotice)
                } label: {
                    Label("FFmpeg — LGPL 2.1", systemImage: "doc.text")
                }
            } header: {
                Text("Open-Source Licenses")
            } footer: {
                Text("MuonPlayer statically links a lean, audio-only build of FFmpeg (release/7.1), licensed under the LGPL 2.1. Because the app is fully open source, you can rebuild it against a modified FFmpeg — see THIRD-PARTY-NOTICES.md in the source repository.")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let ffmpegNotice = """
    This application uses libraries from the FFmpeg project (release/7.1) under \
    the LGPLv2.1. The FFmpeg source and the exact build script used are available \
    in the MuonPlayer source repository. The full license text follows.
    """
}

/// Renders a bundled plain-text license file, with an optional header note.
struct LicenseTextView: View {
    let title: String
    let resource: String
    let header: String?

    private var text: String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return "License text unavailable."
        }
        return contents
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let header {
                    Text(header)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .selectableText()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
