import SwiftUI
import MuonCore

struct AlbumView: View {
    let albumID: Int
    let albumTitle: String
    @State var tracks: [TrackItem] = []

    var body: some View {
        List {
            Section("Now playing") { NowPlayingBar() }
            Section("Tracks") {
                ForEach(tracks) { track in
                    Button {
                        play(track.id)
                    } label: {
                        HStack {
                            Text("\(track.id + 1).").foregroundStyle(.secondary)
                            Text(track.title)
                            Spacer()
                            Text(track.codec).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(albumTitle)
        .task { await load() }
    }

    private func load() async {
        #if os(Android)
        tracks = await MuonCore.library.openAlbum(albumID)
        #endif
    }

    private func play(_ index: Int) {
        #if os(Android)
        MuonCore.library.play(trackAt: index)
        #endif
    }
}

/// The transport, polled rather than observed: what matters for a gapless seam is
/// that the title flips while the clock keeps running, and a poll shows that
/// without depending on how Skip bridges @Observable across the JNI boundary.
struct NowPlayingBar: View {
    @State var title = "—"
    @State var position = ""
    @State var playing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).lineLimit(1)
            Text(position).font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button(playing ? "Pause" : "Play") { toggle() }
                Spacer()
                Button("Next") { next() }
            }
        }
        .task { await tick() }
    }

    private func tick() async {
        while !Task.isCancelled {
            #if os(Android)
            let lib = MuonCore.library
            title = lib.currentTitle.isEmpty ? "—" : lib.currentTitle
            playing = lib.isPlaying
            position = lib.duration > 0 ? "\(clock(lib.currentTime)) / \(clock(lib.duration))" : ""
            #endif
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    private func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func toggle() {
        #if os(Android)
        MuonCore.library.togglePlayPause()
        #endif
    }

    private func next() {
        #if os(Android)
        MuonCore.library.next()
        #endif
    }
}
