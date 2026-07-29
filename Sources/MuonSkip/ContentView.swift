import SwiftUI

enum ContentTab: String, Hashable {
    case library, core
}

struct ContentView: View {
    @AppStorage("tab") var tab = ContentTab.library

    var body: some View {
        TabView(selection: $tab) {
            LibraryView()
                .tabItem { Label("Library", systemImage: "music.note.list") }
                    .tag(ContentTab.library)

                NavigationStack {
                    CoreProbeView().navigationTitle("Core")
                }
                .tabItem { Label("Core", systemImage: "waveform") }
                .tag(ContentTab.core)
        }
    }
}
