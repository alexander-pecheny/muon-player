import SwiftUI

struct SettingsView: View {
    @Environment(ScrobbleService.self) private var scrobbler
    @Environment(LibraryStore.self) private var library

    @State private var username = ""
    @State private var password = ""

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
        }
    }
}
