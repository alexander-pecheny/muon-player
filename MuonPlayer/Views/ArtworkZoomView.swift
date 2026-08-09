import SwiftUI
import UIKit

/// An artwork path presented full-screen. A path is its own identity, so opening
/// the same sleeve twice reuses the same presentation.
struct ArtworkRef: Identifiable, Hashable {
    let path: String
    var id: String { path }
}

/// Full-size album art over black, zoomable so the sleeve's small print can be
/// read.
///
/// The zooming is a `UIScrollView` rather than SwiftUI gestures: pinch, pan,
/// momentum and rubber-banding all have to feel exactly like Photos, and that is
/// the one thing `UIScrollView` gives away for free.
struct ArtworkZoomView: View {
    let path: String

    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var loaded = false
    @State private var atFit = true
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                ZoomableImage(image: image, atFit: $atFit)
                    .ignoresSafeArea()
            } else if loaded {
                // The art can go missing between the tap and the load — a tag edit
                // strips it, or the file is gone. Say so instead of spinning, which
                // the cache's remembered miss would make permanent.
                ContentUnavailableView("No Artwork", systemImage: "photo",
                                       description: Text("This file has no cover image."))
                    .foregroundStyle(.white)
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }
        }
        .offset(y: dragOffset)
        // Dragging while zoomed in pans the picture, so the dismiss gesture only
        // exists at fit scale — as in Photos.
        .gesture(atFit ? dismissDrag : nil)
        .overlay(alignment: .topTrailing) { closeButton }
        .statusBarHidden()
        .task {
            image = await ArtworkCache.shared.load(path: path, maxPixel: 3000, from: library)
            loaded = true
        }
    }

    private var dismissDrag: some Gesture {
        DragGesture()
            .onChanged { dragOffset = $0.translation.height }
            .onEnded {
                if abs($0.translation.height) > 120 { dismiss() }
                else { withAnimation(.easeOut(duration: 0.2)) { dragOffset = 0 } }
            }
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .white.opacity(0.25))
        }
        .buttonStyle(.plain)
        .padding(16)
    }
}

private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    @Binding var atFit: Bool

    func makeUIView(context: Context) -> ZoomScrollView {
        let scroll = ZoomScrollView()
        scroll.delegate = context.coordinator
        scroll.maximumZoomScale = 8
        scroll.minimumZoomScale = 1
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .black
        scroll.contentInsetAdjustmentBehavior = .never

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: ZoomScrollView, context: Context) {
        context.coordinator.atFit = $atFit
        guard scroll.imageView.image !== image else { return }
        scroll.setImage(image)
    }

    func makeCoordinator() -> Coordinator { Coordinator(atFit: $atFit) }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var atFit: Binding<Bool>

        init(atFit: Binding<Bool>) { self.atFit = atFit }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ZoomScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? ZoomScrollView)?.centerContent()
            let fit = scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01
            if fit != atFit.wrappedValue { atFit.wrappedValue = fit }
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scroll = recognizer.view as? ZoomScrollView else { return }
            if scroll.zoomScale > scroll.minimumZoomScale {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
                return
            }
            let point = recognizer.location(in: scroll.imageView)
            let scale: CGFloat = 3
            let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
            scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                   width: size.width, height: size.height), animated: true)
        }
    }
}

/// Sizes the image to the screen and keeps it centred.
///
/// This has to happen in `layoutSubviews` rather than in `updateUIView`: SwiftUI
/// hands the representable a view with no bounds yet, and once the image is set
/// nothing changes again, so a frame worked out up front stays zero and the
/// picture never appears.
private final class ZoomScrollView: UIScrollView {
    let imageView = UIImageView()
    private var laidOutFor: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: UIImage) {
        imageView.image = image
        laidOutFor = .zero
        zoomScale = 1
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let size = imageView.image?.size, bounds.width > 0, bounds.height > 0 else { return }
        if laidOutFor != bounds.size {
            laidOutFor = bounds.size
            // The image view is the aspect-fit rect itself rather than the whole
            // bounds, so zooming magnifies the sleeve and not the black beside it.
            let scale = min(bounds.width / size.width, bounds.height / size.height)
            let fitted = CGSize(width: size.width * scale, height: size.height * scale)
            zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: fitted)
            contentSize = fitted
        }
        centerContent()
    }

    /// Keep the picture in the middle while it is smaller than the screen —
    /// without this it clings to the top-left corner as you zoom back out.
    func centerContent() {
        let inset = UIEdgeInsets(top: max(0, (bounds.height - contentSize.height) / 2),
                                 left: max(0, (bounds.width - contentSize.width) / 2),
                                 bottom: 0, right: 0)
        if contentInset != inset { contentInset = inset }
    }
}
