import SwiftUI

/// Full-size album art, zoomable so the sleeve's small print can be read.
struct ArtworkZoomView: View {
    let path: String

    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var image: PlatformImage?
    @State private var zoom: CGFloat = 1

    private let maxZoom: CGFloat = 8

    var body: some View {
        Group {
            if let image {
                zoomable(image)
            } else {
                ProgressView().controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.black)
        .ignoresSafeArea()
        .overlay(alignment: .bottom) { controls }
        .overlay(alignment: .topTrailing) { closeButton }
        .task { image = await ArtworkCache.shared.load(path: path, maxPixel: 3000, from: library) }
    }

    private var scale: CGFloat { min(max(zoom, 1), maxZoom) }

    private func zoomable(_ image: PlatformImage) -> some View {
        ZoomScrollView(image: image, zoom: $zoom, maxZoom: maxZoom)
    }

    private var controls: some View {
        HStack(spacing: 4) {
            zoomButton("minus.magnifyingglass", to: zoom / 1.5).disabled(scale <= 1)
            Text(String(format: "%.1f×", scale))
                .font(.callout.monospacedDigit())
                .frame(width: 46)
            zoomButton("plus.magnifyingglass", to: zoom * 1.5).disabled(scale >= maxZoom)
            Divider().frame(height: 16)
            Button("Fit") { setZoom(1) }.disabled(scale <= 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 24)
    }

    private func zoomButton(_ symbol: String, to target: CGFloat) -> some View {
        Button { setZoom(target) } label: {
            Image(systemName: symbol).font(.title3).frame(width: 28)
        }
        .buttonStyle(.borderless)
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.4))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .padding(12)
    }

    private func setZoom(_ target: CGFloat) {
        zoom = min(max(target, 1), maxZoom)
    }
}

#if os(iOS)
/// UIScrollView's own zooming, because SwiftUI's ScrollView cannot be told where
/// to zoom: a pinch grows the picture around the fingers and a double tap around
/// the tap, as in Photos.
private struct ZoomScrollView: UIViewRepresentable {
    let image: UIImage
    @Binding var zoom: CGFloat
    let maxZoom: CGFloat

    func makeUIView(context: Context) -> ImageScrollView {
        let view = ImageScrollView()
        view.maximumZoomScale = maxZoom
        view.onZoom = { zoom = $0 }
        return view
    }

    func updateUIView(_ view: ImageScrollView, context: Context) {
        view.image = image
        if abs(view.zoomScale - zoom) > 0.01, !view.isZooming, !view.isZoomBouncing {
            view.setZoomScale(zoom, animated: true)
        }
    }
}

private final class ImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var fitted: CGSize = .zero
    var onZoom: ((CGFloat) -> Void)?
    var image: UIImage? {
        didSet {
            guard image !== oldValue else { return }
            imageView.image = image
            fitted = .zero
            setNeedsLayout()
        }
    }

    init() {
        super.init(frame: .zero)
        delegate = self
        addSubview(imageView)
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTap))
        tap.numberOfTapsRequired = 2
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let size = image?.size, size.width > 0, size.height > 0, bounds.width > 0 else { return }
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        let target = CGSize(width: size.width * fit, height: size.height * fit)
        if target != fitted {
            fitted = target
            zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: target)
            contentSize = target
        }
        center()
    }

    private func center() {
        contentInset = UIEdgeInsets(top: max(0, (bounds.height - contentSize.height) / 2),
                                    left: max(0, (bounds.width - contentSize.width) / 2),
                                    bottom: 0, right: 0)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        center()
        onZoom?(zoomScale)
    }

    @objc private func doubleTap(_ tap: UITapGestureRecognizer) {
        if zoomScale > 1 { setZoomScale(1, animated: true); return }
        let point = tap.location(in: imageView)
        let size = CGSize(width: bounds.width / 3, height: bounds.height / 3)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                        width: size.width, height: size.height), animated: true)
    }
}
#endif

#if os(macOS)
/// NSScrollView's own magnification, for the same reason: a trackpad pinch grows
/// the picture around the pointer, and a double click around the click.
private struct ZoomScrollView: NSViewRepresentable {
    let image: NSImage
    @Binding var zoom: CGFloat
    let maxZoom: CGFloat

    func makeNSView(context: Context) -> ImageScrollView {
        let view = ImageScrollView()
        view.maxMagnification = maxZoom
        view.onZoom = { zoom = $0 }
        return view
    }

    func updateNSView(_ view: ImageScrollView, context: Context) {
        view.image = image
        if abs(view.magnification - zoom) > 0.01, !view.isLiveMagnifying {
            view.setMagnificationKeepingCentre(zoom)
        }
    }
}

private final class ImageScrollView: NSScrollView {
    private let imageView = NSImageView()
    private var fitted: CGSize = .zero
    private var reported: CGFloat = 1
    private(set) var isLiveMagnifying = false
    var onZoom: ((CGFloat) -> Void)?
    var image: NSImage? {
        didSet {
            guard image !== oldValue else { return }
            imageView.image = image
            fitted = .zero
            needsLayout = true
        }
    }

    init() {
        super.init(frame: .zero)
        contentView = CentringClipView()
        documentView = imageView
        imageView.imageScaling = .scaleAxesIndependently
        allowsMagnification = true
        minMagnification = 1
        drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = false
        contentView.postsBoundsChangedNotifications = true

        let click = NSClickGestureRecognizer(target: self, action: #selector(doubleClick))
        click.numberOfClicksRequired = 2
        addGestureRecognizer(click)

        let centre = NotificationCenter.default
        centre.addObserver(self, selector: #selector(reportZoom),
                           name: NSView.boundsDidChangeNotification, object: contentView)
        centre.addObserver(self, selector: #selector(liveMagnifyStarted),
                           name: NSScrollView.willStartLiveMagnifyNotification, object: self)
        centre.addObserver(self, selector: #selector(liveMagnifyEnded),
                           name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        guard let size = image?.size, size.width > 0, size.height > 0, bounds.width > 0 else { return }
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        let target = CGSize(width: size.width * fit, height: size.height * fit)
        guard target != fitted else { return }
        fitted = target
        magnification = 1
        imageView.frame = CGRect(origin: .zero, size: target)
        reportZoom()
    }

    func setMagnificationKeepingCentre(_ target: CGFloat) {
        let visible = contentView.documentVisibleRect
        setMagnification(target, centeredAt: CGPoint(x: visible.midX, y: visible.midY))
    }

    @objc private func reportZoom() {
        guard abs(magnification - reported) > 0.001 else { return }
        reported = magnification
        onZoom?(magnification)
    }
    @objc private func liveMagnifyStarted() { isLiveMagnifying = true }
    @objc private func liveMagnifyEnded() { isLiveMagnifying = false; reportZoom() }

    @objc private func doubleClick(_ click: NSClickGestureRecognizer) {
        if magnification > 1 {
            setMagnificationKeepingCentre(1)
        } else {
            setMagnification(3, centeredAt: click.location(in: imageView))
        }
    }
}

/// An NSScrollView pins a document smaller than itself to a corner; this holds it
/// in the middle, the way UIScrollView's content insets do on iOS.
private final class CentringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width {
            rect.origin.x = (document.frame.width - rect.width) / 2
        }
        if rect.height > document.frame.height {
            rect.origin.y = (document.frame.height - rect.height) / 2
        }
        return rect
    }
}
#endif
