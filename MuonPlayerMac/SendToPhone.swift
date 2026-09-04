import Observation
import SwiftUI

/// "Send to iPhone", and what the window shows while it happens.
///
/// One transfer at a time: the phone writes into a single library, and two batches
/// racing each other would only make the progress meaningless.
@MainActor
@Observable
final class SendToPhone {

    enum Phase: Equatable {
        case idle
        case finding
        case sending(done: Int, total: Int, name: String)
        case sent(Int, to: String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private var task: Task<Void, Never>?

    var isBusy: Bool {
        switch phase {
        case .finding, .sending: return true
        default: return false
        }
    }

    /// Send every album folder the artist has.
    func sendArtist(_ artist: String, library: LibraryStore, opus: Bool = false) async {
        var folders: Set<URL> = []
        for album in library.albums where album.artist == artist {
            folders.formUnion(await library.tracks(in: album).map { $0.url.deletingLastPathComponent() })
        }
        send(Array(folders), roots: library.roots, opus: opus)
    }

    /// Send the folders the album's tracks sit in, rather than the tracks themselves,
    /// so the cover art beside them goes too.
    func sendAlbum(_ album: Album, library: LibraryStore, opus: Bool = false) async {
        let folders = Set(await library.tracks(in: album).map { $0.url.deletingLastPathComponent() })
        send(Array(folders), roots: library.roots, opus: opus)
    }

    /// `opus` re-encodes the lossless files on the way, at 160 kbps. Lossy ones are sent
    /// as they are: putting an mp3 through Opus spends CPU to make it worse.
    func send(_ urls: [URL], roots: [LibraryRoot], opus: Bool = false) {
        guard !isBusy else { return }
        phase = .finding
        // Detached, because encoding a FLAC on the main actor freezes the window.
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                var items = try TransferSender.items(for: urls, roots: roots)
                if opus {
                    items = items.map { OpusTranscoder.isLossless($0.url) ? $0.transcoded(to: "opus") : $0 }
                }
                let peers = await TransferSender.discover()
                guard let peer = peers.first else { throw TransferError.noReceiver }
                await self?.set(.sending(done: 0, total: items.count, name: ""))
                let sent = try await TransferSender.send(
                    items, to: peer, as: .local(),
                    encode: opus ? Self.encodeToOpus : nil
                ) { progress in
                    Task { @MainActor [weak self] in
                        self?.phase = .sending(done: progress.fileIndex,
                                               total: progress.fileCount,
                                               name: progress.name)
                    }
                }
                await self?.set(.sent(sent, to: peer.name))
            } catch {
                await self?.set(.failed(error.localizedDescription))
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await self?.clearIfSettled()
        }
    }

    private static let encodeToOpus: @Sendable (TransferSender.Item) throws -> URL = { item in
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("opus")
        try OpusTranscoder.encode(item.url, to: destination)
        return destination
    }

    private func set(_ next: Phase) {
        phase = next
    }

    private func clearIfSettled() {
        if !isBusy { phase = .idle }
    }
}

/// A toast in the corner of the window. Nothing is shown until a send starts.
struct SendToPhoneBanner: View {
    @Environment(SendToPhone.self) private var sender

    var body: some View {
        Group {
            switch sender.phase {
            case .idle:
                EmptyView()
            case .finding:
                row(icon: "iphone.badge.play", text: "Looking for your iPhone…", spinner: true)
            case .sending(let done, let total, let name):
                row(icon: "arrow.up.circle", text: "Sending \(done + 1) of \(total)", detail: name, spinner: true)
            case .sent(let count, let peer):
                row(icon: "checkmark.circle", text: count == 0 ? "\(peer) already had it"
                                                               : "Sent \(count) files to \(peer)")
            case .failed(let message):
                row(icon: "exclamationmark.triangle", text: message)
            }
        }
        .animation(.default, value: sender.phase)
    }

    private func row(icon: String, text: String, detail: String? = nil, spinner: Bool = false) -> some View {
        HStack(spacing: 9) {
            if spinner {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: icon)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(text).font(.callout)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
        .shadow(radius: 12, y: 4)
        .padding(16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
