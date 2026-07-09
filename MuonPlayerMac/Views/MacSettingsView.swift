import SwiftUI

struct MacSettingsView: View {
    var body: some View {
        TabView {
            LibrarySettings()
                .tabItem { Label("Library", systemImage: "music.note.house") }
            ScrobbleSettings()
                .tabItem { Label("Last.fm", systemImage: "waveform") }
            MacAboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 380)
    }
}

/// Add and remove the folders that make up the library. Removing a folder drops
/// its tracks on the next scan; the files themselves are never touched.
private struct LibrarySettings: View {
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryFolders.self) private var folders
    @State private var selection: LibraryRoot.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Folders").font(.headline)

            List(selection: $selection) {
                ForEach(folders.roots) { root in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(root.name)
                        Text(root.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    .tag(root.id)
                }
            }
            .frame(minHeight: 140)
            .overlay {
                if folders.isEmpty {
                    Text("No folders added").foregroundStyle(.secondary)
                }
            }

            HStack {
                Button {
                    if folders.promptToAdd() { reindex() }
                } label: { Image(systemName: "plus") }

                Button {
                    guard let root = folders.roots.first(where: { $0.id == selection }) else { return }
                    folders.remove(root)
                    selection = nil
                    reindex()
                } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)

                Spacer()

                Text("\(library.trackCount) tracks").font(.caption).foregroundStyle(.secondary)

                Button {
                    Task { await library.rescan() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Rescan")
                        if library.isScanning { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(library.isScanning || folders.isEmpty)
            }

            Text("Folders are indexed in place. Music is never copied or moved.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
    }

    private func reindex() {
        Task { await library.setRoots(folders.roots) }
    }
}

private struct ScrobbleSettings: View {
    @Environment(ScrobbleService.self) private var scrobbler
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        Form {
            if scrobbler.isLoggedIn {
                LabeledContent("Signed in as", value: scrobbler.username ?? "")
                LabeledContent("Pending scrobbles", value: "\(scrobbler.pendingCount)")
                Button("Sign Out") {
                    scrobbler.logOut()
                    username = ""; password = ""
                }
            } else {
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
                if let error = scrobbler.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                if !scrobbler.canLogIn {
                    Text("App API key/secret not configured.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Sign In") {
                        Task { _ = await scrobbler.logIn(username: username, password: password) }
                    }
                    .disabled(username.isEmpty || password.isEmpty || scrobbler.isBusy || !scrobbler.canLogIn)
                    if scrobbler.isBusy { ProgressView().controlSize(.small) }
                }
            }

            Section {
                Text("Scrobbles are saved locally first and retried until Last.fm accepts them, so nothing is lost while offline.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(4)
    }
}
