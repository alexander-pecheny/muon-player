import AppKit
import SwiftUI

/// Selects `url` in the Finder. A file is selected inside its folder; a folder is
/// selected in its parent — which is what "reveal" means either way.
func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

/// Context-menu item for the common case where the target is known up front.
struct RevealInFinderButton: View {
    let url: URL?

    var body: some View {
        if let url {
            Button("Reveal in Finder") { revealInFinder(url) }
        }
    }
}
