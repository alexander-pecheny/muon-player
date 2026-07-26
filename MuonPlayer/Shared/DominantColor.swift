import SwiftUI
import CoreGraphics

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Derives a vivid "accent" color from album artwork — a dominant hue that is
/// legible as an accent, on both a light and a dark background (à la Spotify).
///
/// Grayscale or artless input yields `nil`, so callers fall back to the system
/// accent. Extraction is cheap: the image is drawn into a tiny 48×48 buffer and
/// the pixels are binned by hue, weighted toward vivid, well-lit ones.
extension Color {
    /// Neutral tint used when there's no artwork-derived accent (nothing playing,
    /// or grayscale artwork). Deliberately a system gray rather than the system
    /// blue, so the app reads as neutral until a track colors it.
    static var neutralAccent: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemGray)
        #else
        Color.gray
        #endif
    }
}

enum DominantColor {
    /// sRGB components, 0...1.
    struct RGB: Equatable, Sendable {
        var r: Double, g: Double, b: Double
    }

    /// Where an accent is allowed to land. The bound that matters is perceived
    /// luminance, not HSB brightness: a fully-lit saturated blue has a brightness
    /// of 1 and a luminance of 0.07, which is why such a tint disappeared into a
    /// dark background even though it passed a brightness floor.
    ///
    /// The accent is drawn two ways — as a label on the app's background, and as
    /// a button fill under a white label — so it needs contrast on both sides.
    /// The bounds are WCAG relative luminance: 0.18 is 4.5:1 against black, 0.22
    /// is 4.5:1 against white, and the far bound of each range is where the
    /// opposite use starts to suffer.
    struct SafeRange {
        var minLuminance: Double
        var maxLuminance: Double

        static let dark = SafeRange(minLuminance: 0.18, maxLuminance: 0.55)
        static let light = SafeRange(minLuminance: 0.05, maxLuminance: 0.22)

        func contains(_ luminance: Double) -> Bool {
            luminance >= minLuminance && luminance <= maxLuminance
        }
    }

    /// The accent for `image`, as one color that resolves differently in light
    /// and dark appearance — the safe ranges barely overlap, so a single value
    /// cannot serve both.
    static func from(_ image: PlatformImage) -> Color? {
        let candidates = candidates(from: image)
        guard let dark = accent(from: candidates, in: .dark),
              let light = accent(from: candidates, in: .light) else { return nil }
        return Color(light: light, dark: dark)
    }

    /// The image's dominant hues, most prominent first. More than one, because
    /// the most prominent hue is often the one that cannot be made legible.
    static func candidates(from image: PlatformImage, limit: Int = 5) -> [RGB] {
        guard let cg = cgImage(from: image),
              let px = downsampledPixels(cg, side: 48) else { return [] }

        let bins = 24
        var weight = [Double](repeating: 0, count: bins)
        var sum = [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: bins)

        var i = 0
        while i + 3 < px.count {
            let c = RGB(r: Double(px[i]) / 255, g: Double(px[i + 1]) / 255, b: Double(px[i + 2]) / 255)
            let a = Double(px[i + 3]) / 255
            i += 4
            guard a > 0.5 else { continue }
            let (h, s, v) = hsb(c)
            // Skip near-gray, near-black and blown-out pixels — they carry no hue.
            guard s > 0.2, v > 0.15, v < 0.98 else { continue }
            let bin = min(bins - 1, Int(h * Double(bins)))
            let w = s * v            // prefer vivid, well-lit pixels
            weight[bin] += w
            sum[bin].r += c.r * w; sum[bin].g += c.g * w; sum[bin].b += c.b * w
        }

        let ranked = weight.indices.filter { weight[$0] > 0 }.sorted { weight[$0] > weight[$1] }
        guard let top = ranked.first else { return [] }
        // A hue only competes for the accent if it is actually a fifth of the
        // cover; otherwise a stray legible speck would outrank the real subject.
        return ranked.prefix(limit)
            .filter { weight[$0] >= weight[top] * 0.2 }
            .map { RGB(r: sum[$0].r / weight[$0], g: sum[$0].g / weight[$0], b: sum[$0].b / weight[$0]) }
    }

    /// The first candidate that is already legible in `range`; failing that, the
    /// one that needs the least correction, corrected.
    static func accent(from candidates: [RGB], in range: SafeRange) -> RGB? {
        guard !candidates.isEmpty else { return nil }
        let vivid = candidates.map(vividened)
        if let usable = vivid.first(where: { range.contains(relativeLuminance($0)) }) { return usable }
        return vivid
            .map { (original: $0, fixed: clamped($0, into: range)) }
            .min { distance($0.original, $0.fixed) < distance($1.original, $1.fixed) }?
            .fixed
    }

    /// Lift washed-out candidates to a floor low enough that muted covers (e.g.
    /// kraft-paper tans) keep their real hue instead of being pushed to a vivid gold.
    private static func vividened(_ c: RGB) -> RGB {
        let (h, s, v) = hsb(c)
        return s >= 0.40 ? c : rgb(h: h, s: 0.40, v: v)
    }

    /// Move `c` onto the near edge of `range`, keeping its hue.
    static func clamped(_ c: RGB, into range: SafeRange) -> RGB {
        let (h, s, v) = hsb(c)
        let l = relativeLuminance(c)
        if l < range.minLuminance {
            // Brightness first. A deep hue like pure blue cannot reach the floor at
            // any brightness — blue carries 7% of white's luminance — so once it is
            // fully lit the only way up is to drain saturation.
            if relativeLuminance(rgb(h: h, s: s, v: 1)) >= range.minLuminance {
                return solve(range.minLuminance) { rgb(h: h, s: s, v: v + (1 - v) * $0) }
            }
            return solve(range.minLuminance) { rgb(h: h, s: s * (1 - $0), v: 1) }
        }
        if l > range.maxLuminance {
            return solve(range.maxLuminance) { rgb(h: h, s: s, v: v * $0) }
        }
        return c
    }

    /// WCAG relative luminance.
    static func relativeLuminance(_ c: RGB) -> Double {
        func linear(_ x: Double) -> Double {
            x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    // MARK: - Helpers

    /// Binary-search `t` in 0...1 for the color whose luminance first reaches
    /// `target`. `make` must be monotonically brightening in `t`.
    private static func solve(_ target: Double, _ make: (Double) -> RGB) -> RGB {
        var lo = 0.0, hi = 1.0
        for _ in 0..<20 {
            let mid = (lo + hi) / 2
            if relativeLuminance(make(mid)) < target { lo = mid } else { hi = mid }
        }
        return make(hi)
    }

    private static func distance(_ a: RGB, _ b: RGB) -> Double {
        let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
        return dr * dr + dg * dg + db * db
    }

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
    static func hsb(_ c: RGB) -> (h: Double, s: Double, v: Double) {
        let maxc = max(c.r, c.g, c.b), minc = min(c.r, c.g, c.b)
        let d = maxc - minc
        let s = maxc == 0 ? 0 : d / maxc
        var h = 0.0
        if d != 0 {
            if maxc == c.r { h = (c.g - c.b) / d + (c.g < c.b ? 6 : 0) }
            else if maxc == c.g { h = (c.b - c.r) / d + 2 }
            else { h = (c.r - c.g) / d + 4 }
            h /= 6
        }
        return (h, s, maxc)
    }

    static func rgb(h: Double, s: Double, v: Double) -> RGB {
        let i = (h * 6).truncatingRemainder(dividingBy: 6)
        let f = i - i.rounded(.down)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch Int(i) {
        case 0: return RGB(r: v, g: t, b: p)
        case 1: return RGB(r: q, g: v, b: p)
        case 2: return RGB(r: p, g: v, b: t)
        case 3: return RGB(r: p, g: q, b: v)
        case 4: return RGB(r: t, g: p, b: v)
        default: return RGB(r: v, g: p, b: q)
        }
    }
}

extension Color {
    /// One color that resolves to `light` or `dark` according to the appearance it
    /// is drawn in, so a single stored accent stays legible in both.
    init(light: DominantColor.RGB, dark: DominantColor.RGB) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            NSColor(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
        #endif
    }
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(_ c: DominantColor.RGB) {
        self.init(red: c.r, green: c.g, blue: c.b, alpha: 1)
    }
}
#else
private extension NSColor {
    convenience init(_ c: DominantColor.RGB) {
        self.init(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }
}
#endif
