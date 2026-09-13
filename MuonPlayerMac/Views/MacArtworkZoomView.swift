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
    func makeNSView(context: Context) -> NSView { ScreenFiller() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// `makeNSView` runs before the view has a window, and the one runloop hop this
/// used to wait was not always enough — the window then opened at SwiftUI's own
/// default size. Waiting for the window itself is the thing that always works.
private final class ScreenFiller: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, let frame = window.screen?.visibleFrame, window.frame != frame else { return }
        window.setFrame(frame, display: true)
    }
}
