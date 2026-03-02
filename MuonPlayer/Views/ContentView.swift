import SwiftUI

struct ContentView: View {
    @Environment(AudioEngine.self) private var audioEngine

    var body: some View {
        ZStack(alignment: .bottom) {
            NavigationStack {
                FileListView()
                    .navigationTitle("Muon Player")
            }

            if audioEngine.currentTrack != nil {
                NowPlayingView()
                    .padding(.bottom)
            }
        }
    }
}
