import SwiftUI

struct SettingsView: View {
    @Environment(ScrobbleService.self) private var scrobbler
    @Environment(LibraryStore.self) private var library

    @State private var username = ""
    @State private var password = ""
    @AppStorage(GaplessFixMode.key) private var gaplessFixMode = GaplessFixMode.playbackOnly.rawValue

    var body: some View {
        Form {
            Section {
                if scrobbler.isLoggedIn {
                    LabeledContent("Signed in as", value: scrobbler.username ?? "")
                    LabeledContent("Pending scrobbles", value: "\(scrobbler.pendingCount)")
                    Button("Sign Out", role: .destructive) {
                        scrobbler.logOut()
                        username = ""; password = ""
                    }
                } else {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)

                    if let error = scrobbler.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }

                    Button {
                        Task { _ = await scrobbler.logIn(username: username, password: password) }
                    } label: {
                        HStack {
                            Text("Sign In")
                            if scrobbler.isBusy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(username.isEmpty || password.isEmpty || scrobbler.isBusy || !scrobbler.canLogIn)

                    if !scrobbler.canLogIn {
                        Text("App API key/secret not configured.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Last.fm")
            } footer: {
                Text("Scrobbles are saved locally first and retried until Last.fm accepts them, so nothing is lost while offline.")
            }

            Section {
                LabeledContent("Tracks", value: "\(library.trackCount)")
                Button {
                    Task { await library.rescan() }
                } label: {
                    HStack {
                        Text("Rescan Library")
                        if library.isScanning { Spacer(); ProgressView() }
                    }
                }
                .disabled(library.isScanning)
            } header: {
                Text("Library")
            } footer: {
                Text("Add music via the Files app under **On My iPhone → MuonPlayer**.")
            }

            Section {
                Picker("Broken Seams", selection: $gaplessFixMode) {
                    ForEach(GaplessFixMode.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
            } header: {
                Text("Gapless")
            } footer: {
                Text("""
                Some albums are ripped so that silence is stranded between two tracks meant to \
                run together. Muon measures it after each scan and skips it as it plays — in any \
                format, and without touching a file.

                **Also repair the files** additionally writes the fix into the MP3s, so other \
                players get it too. Originals are backed up first; only MP3 can carry a fix this \
                way, so the rest stay playback-only.
                """)
            }

            Section("Appearance") {
                NavigationLink {
                    TabsReorderView()
                } label: {
                    Label("Tab Order", systemImage: "square.grid.2x2")
                }
            }

            Section("About") {
                NavigationLink {
                    AboutView()
                } label: {
                    Label("About & Licenses", systemImage: "info.circle")
                }
            }
        }
    }
}
