import SwiftUI

/// Full-size album art, zoomable so the sleeve's small print can be read.
///
/// Zoom is a frame the image is drawn into rather than a `.scaleEffect`, which
/// lets the enclosing `ScrollView` pan it without any offset bookkeeping.
struct ArtworkZoomView: View {
    let path: String

    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var image: PlatformImage?
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1

    private let maxZoom: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                content
                    .frame(width: geo.size.width * scale, height: geo.size.height * scale)
                    .contentShape(Rectangle())
                    // On the scroll content, not above the ScrollView: the UIKit
                    // scroll view underneath would otherwise keep both fingers.
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { pinch = $0.magnification }
                            .onEnded { _ in zoom = scale; pinch = 1 }
                    )
                    .onTapGesture(count: 2) { setZoom(zoom > 1 ? 1 : 3) }
            }
            .scrollDisabled(scale <= 1)
        }
        .background(.black)
        .ignoresSafeArea()
        .overlay(alignment: .bottom) { controls }
        .overlay(alignment: .topTrailing) { closeButton }
        .task { image = await ArtworkCache.shared.load(path: path, maxPixel: 3000, from: library) }
    }

    private var scale: CGFloat { min(max(zoom * pinch, 1), maxZoom) }

    @ViewBuilder private var content: some View {
        if let image {
            Image(platformImage: image).resizable().scaledToFit()
        } else {
            ProgressView().controlSize(.large)
        }
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
        withAnimation(.easeOut(duration: 0.2)) { zoom = min(max(target, 1), maxZoom) }
        pinch = 1
    }
}
