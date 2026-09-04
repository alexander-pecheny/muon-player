//
//  muon-send — push an album from the Mac to MuonPlayer on the phone, over Wi-Fi.
//
//  The phone advertises `_muon._tcp` while the app is on screen. Each file is sent
//  with its path relative to the Mac library folder holding it, so
//  ~/Music/Arab Strap/Philophobia lands at Documents/Arab Strap/Philophobia and the
//  app indexes it where you would expect. Files the phone already holds, judged by
//  size and mtime, are not sent again.
//
//  Compiled against the app's sender and its library-root rules:
//
//    swiftc -O scripts/muon-send.swift MuonPlayerMac/TransferSender.swift \
//      MuonPlayer/Shared/MuonTransfer.swift MuonPlayer/Library/LibraryRoot.swift \
//      MuonPlayer/Models/Track.swift MuonPlayer/Scanner/FileScanner.swift -o /tmp/muon-send
//    /tmp/muon-send ~/Music/"Arab Strap"/Philophobia
//    /tmp/muon-send --list
//
//  The library folders come from the Mac app's own preferences, so the same
//  folders it indexes are the ones a path is measured against. --root overrides
//  that, and is what you want if the app has never run.
//

import Foundation

struct Options {
    var paths: [URL] = []
    var roots: [LibraryRoot] = []
    var to: String?
    var list = false

    static func parse() -> Options {
        var options = Options()
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--root":
                guard let path = it.next() else { die("--root needs a folder") }
                options.roots.append(LibraryRoot(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)))
            case "--to":
                options.to = it.next()
            case "--list":
                options.list = true
            case "-h", "--help":
                print("usage: muon-send [--root FOLDER] [--to PHONE] [--list] PATH…")
                exit(0)
            default:
                options.paths.append(URL(fileURLWithPath: (arg as NSString).expandingTildeInPath))
            }
        }
        return options
    }
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("muon-send: \(message)\n".utf8))
    exit(1)
}

/// The folders the Mac app indexes. Its preferences live inside its sandbox
/// container, and each folder is stored as a security-scoped bookmark — but the
/// *path* comes out of one without resolving the scope, which is all we need.
func macAppRoots() -> [LibraryRoot] {
    let prefs = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Containers/me.pecheny.muonplayer/Data/Library/Preferences")
        .appendingPathComponent("me.pecheny.muonplayer.plist")
    guard let stored = NSDictionary(contentsOf: prefs)?["libraryBookmarks"] as? [Data] else { return [] }
    return stored.compactMap { data in
        guard let path = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)?.path else { return nil }
        return LibraryRoot(URL(fileURLWithPath: path))
    }
}

@main
struct MuonSend {
    static func main() async {
        let options = Options.parse()

        if options.list {
            let peers = await TransferSender.discover()
            if peers.isEmpty { die("no phone found") }
            for peer in peers { print(peer.name) }
            return
        }

        guard !options.paths.isEmpty else { die("nothing to send; try --help") }
        let roots = options.roots.isEmpty ? macAppRoots() : options.roots
        guard !roots.isEmpty else {
            die("no library folders known. Run the Mac app once, or pass --root ~/Music")
        }

        do {
            let items = try TransferSender.items(for: options.paths, roots: roots)
            let peers = await TransferSender.discover()
            let match = options.to.map { name in peers.first { $0.name == name } } ?? peers.first
            guard let target = match else { throw TransferError.noReceiver }

            let sent = try await TransferSender.send(items, to: target, as: .local(suffix: "muon-send")) { p in
                let line = p.fileIndex < p.fileCount
                    ? "\(p.fileIndex + 1)/\(p.fileCount)  \(p.name)"
                    : "done"
                FileHandle.standardError.write(Data("\u{1B}[2K\r\(line)".utf8))
            }
            FileHandle.standardError.write(Data("\u{1B}[2K\r".utf8))
            print(sent == 0
                  ? "\(target.name) already had all \(items.count) files"
                  : "sent \(sent) of \(items.count) files to \(target.name)")
        } catch {
            die(error.localizedDescription)
        }
    }
}
