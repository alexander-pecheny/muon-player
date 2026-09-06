import SwiftUI

/// The zoomable artwork in a window of its own.
struct MacArtworkZoomView: View {
    static let windowID = "artwork"

    let path: String

    var body: some View {
        ArtworkZoomView(path: path).background(FillsScreen())
    }
}

/// Sizes the hosting window to the screen once, on open. Native full screen is
/// avoided on purpose: it would move the app to its own Space, and leaving that
/// Space is a slower way out of a picture than closing a window.
private struct FillsScreen: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window, let frame = window.screen?.visibleFrame else { return }
            window.setFrame(frame, display: true)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
