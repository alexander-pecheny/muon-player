import SwiftUI
import CoreGraphics

#if canImport(UIKit)
import UIKit
#endif

/// Derives a vivid "accent" color from album artwork — the most saturated
/// dominant hue, then clamped into a legible saturation/brightness range so it
/// reads as an accent on both light and dark backgrounds (à la Spotify).
///
/// Grayscale or artless input yields `nil`, so callers fall back to the system
/// accent. Extraction is cheap: the image is drawn into a tiny 48×48 buffer and
/// the pixels are binned by hue, weighted toward vivid, well-lit ones.
enum DominantColor {
    static func from(_ image: PlatformImage) -> Color? {
        guard let cg = cgImage(from: image),
              let px = downsampledPixels(cg, side: 48) else { return nil }

        let bins = 24
        var weight = [Double](repeating: 0, count: bins)
        var sumR = [Double](repeating: 0, count: bins)
        var sumG = [Double](repeating: 0, count: bins)
        var sumB = [Double](repeating: 0, count: bins)

        var i = 0
        var colorful = 0
        while i + 3 < px.count {
            let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
            let a = Double(px[i + 3]) / 255
            i += 4
            guard a > 0.5 else { continue }
            let (h, s, v) = hsb(r, g, b)
            // Skip near-gray, near-black and blown-out pixels — they carry no hue.
            guard s > 0.2, v > 0.15, v < 0.98 else { continue }
            let bin = min(bins - 1, Int(h * Double(bins)))
            let w = s * v            // prefer vivid, well-lit pixels
            weight[bin] += w
            sumR[bin] += r * w; sumG[bin] += g * w; sumB[bin] += b * w
            colorful += 1
        }

        guard colorful > 0,
              let best = weight.indices.max(by: { weight[$0] < weight[$1] }),
              weight[best] > 0 else { return nil }

        let w = weight[best]
        let (h, s, v) = hsb(sumR[best] / w, sumG[best] / w, sumB[best] / w)
        // Clamp into a range that pops as an accent without being garish or washed out.
        return Color(hue: h,
                     saturation: min(1, max(0.55, s)),
                     brightness: min(0.92, max(0.60, v)))
    }

    // MARK: - Helpers

    private static func cgImage(from image: PlatformImage) -> CGImage? {
        #if canImport(UIKit)
        return image.cgImage
        #else
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #endif
    }

    /// Draw into a small RGBA8 buffer and return the raw bytes.
    private static func downsampledPixels(_ cg: CGImage, side: Int) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &data, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        return data
    }

    /// RGB (0...1) → HSB (0...1), matching UIColor's channel conventions.
    private static func hsb(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
        let maxc = max(r, g, b), minc = min(r, g, b)
        let d = maxc - minc
        let s = maxc == 0 ? 0 : d / maxc
        var h = 0.0
        if d != 0 {
            if maxc == r { h = (g - b) / d + (g < b ? 6 : 0) }
            else if maxc == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
        }
        return (h, s, maxc)
    }
}
