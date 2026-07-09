import SwiftUI

struct MacAboutView: View {
    @State private var showLicense = false

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)

            Text("MuonPlayer").font(.title2.bold())
            Text("Version \(version)").font(.caption).foregroundStyle(.secondary)

            Text("A gapless music player. Open-source software, released under the MIT License.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 30)

            Button("FFmpeg — LGPL 2.1…") { showLicense = true }
                .buttonStyle(.link)

            Spacer(minLength: 0)
        }
        .padding(20)
        .sheet(isPresented: $showLicense) {
            MacLicenseView(title: "FFmpeg — LGPL 2.1", resource: "LGPL-2.1", header: Self.ffmpegNotice)
        }
    }

    private static let ffmpegNotice = """
    This application uses libraries from the FFmpeg project (release/7.1) under \
    the LGPLv2.1. The FFmpeg source and the exact build script used are available \
    in the MuonPlayer source repository. The full license text follows.
    """
}

struct MacLicenseView: View {
    let title: String
    let resource: String
    let header: String?

    @Environment(\.dismiss) private var dismiss

    private var text: String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return "License text unavailable."
        }
        return contents
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let header {
                        Text(header).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(text)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
        .frame(width: 560, height: 520)
    }
}
