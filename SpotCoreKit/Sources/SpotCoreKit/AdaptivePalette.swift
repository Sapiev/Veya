import CoreGraphics

/// An sRGB color with components in 0...1.
public struct RGB: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let white = RGB(red: 1, green: 1, blue: 1)
    public static let black = RGB(red: 0, green: 0, blue: 0)
    /// The fallback when no artwork drives the window: the system blue.
    public static let systemAccent = RGB(red: 10 / 255, green: 132 / 255, blue: 1)

    /// WCAG relative luminance.
    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, 1...21.
    public func contrast(with other: RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let high = max(red, green, blue), low = min(red, green, blue)
        let lightness = (high + low) / 2
        guard high != low else { return (0, 0, lightness) }
        let delta = high - low
        let saturation = lightness > 0.5 ? delta / (2 - high - low) : delta / (high + low)
        let hue: Double = switch high {
        case red: (green - blue) / delta + (green < blue ? 6 : 0)
        case green: (blue - red) / delta + 2
        default: (red - green) / delta + 4
        }
        return (hue / 6, saturation, lightness)
    }

    init(hue: Double, saturation: Double, lightness: Double) {
        guard saturation > 0 else {
            self.init(red: lightness, green: lightness, blue: lightness)
            return
        }
        let q = lightness < 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q
        func channel(_ t: Double) -> Double {
            let t = t < 0 ? t + 1 : t > 1 ? t - 1 : t
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        self.init(red: channel(hue + 1 / 3), green: channel(hue), blue: channel(hue - 1 / 3))
    }

    /// `#RRGGBB`, how Settings stores the accent color; nil for anything else.
    public init?(hex: String) {
        guard hex.count == 7, hex.first == "#", hex.dropFirst().allSatisfy(\.isHexDigit), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(
            red: Double(value >> 16 & 0xFF) / 255,
            green: Double(value >> 8 & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    public var hex: String {
        func byte(_ channel: Double) -> Int { Int((min(max(channel, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// The same color with its hue turned `turns` of the color wheel; any number of turns wraps.
    public func rotatingHue(by turns: Double) -> RGB {
        let (hue, saturation, lightness) = hsl
        let turned = (hue + turns).truncatingRemainder(dividingBy: 1)
        return RGB(hue: turned < 0 ? turned + 1 : turned, saturation: saturation, lightness: lightness)
    }
}

/// Window colors derived from artwork: an ambient wash, a glow, an accent for
/// fills, the ink drawn on that accent, and the accent as readable text.
public struct AdaptivePalette: Equatable, Sendable {
    public let ambient: RGB
    public let glow: RGB
    public let tint: RGB
    public let tintInk: RGB
    public let tintText: RGB

    /// `accent` is the artwork's most vivid color, `dominant` its most common.
    public init(accent: RGB, dominant: RGB, dark: Bool) {
        let (hue, accentSaturation, accentLightness) = accent.hsl
        let (dominantHue, dominantSaturation, _) = dominant.hsl
        let saturation = min(accentSaturation, 0.75)
        // A grey dominant color would wash the glow out, so fall back to the accent's hue.
        let glowHue = dominantSaturation > 0.25 ? dominantHue : hue
        let glowSaturation = min(dominantSaturation > 0.25 ? dominantSaturation : saturation, 0.7)

        ambient = RGB(hue: hue, saturation: saturation * (dark ? 0.55 : 0.5), lightness: dark ? 0.12 : 0.94)
        glow = RGB(hue: glowHue, saturation: glowSaturation * (dark ? 0.85 : 0.75), lightness: dark ? 0.30 : 0.82)
        tint = RGB(
            hue: hue,
            saturation: saturation,
            lightness: dark ? min(max(accentLightness, 0.52), 0.62) : min(max(accentLightness, 0.36), 0.48)
        )
        tintInk = tint.contrast(with: .white) >= tint.contrast(with: .black) ? .white : .black

        // Walk lightness until the accent reads as small text on the wash and on the glow, which side panels show through.
        var lightness = dark ? max(accentLightness, 0.6) : min(accentLightness, 0.42)
        var text = RGB(hue: hue, saturation: saturation, lightness: lightness)
        while text.contrast(with: ambient) < 4.5 || text.contrast(with: glow) < 4.5, lightness > 0.05, lightness < 0.95 {
            lightness += dark ? 0.03 : -0.03
            text = RGB(hue: hue, saturation: saturation, lightness: lightness)
        }
        tintText = text
    }

    /// The palette when nothing is playing: `accent` over a neutral wash.
    public static func system(dark: Bool, accent: RGB = .systemAccent) -> AdaptivePalette {
        AdaptivePalette(accent: accent, dominant: RGB(red: 44 / 255, green: 44 / 255, blue: 46 / 255), dark: dark)
    }
}

public enum ArtworkColors {
    /// The most common and the most vivid colors of `image`, from a 24×24 downsample
    /// bucketed to 3 bits per channel. Nil when the image cannot be drawn.
    public static func extract(from image: CGImage) -> (accent: RGB, dominant: RGB)? {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var buckets: [Int: (red: Int, green: Int, blue: Int, count: Int)] = [:]
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let (r, g, b) = (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
            let key = (r >> 5) << 6 | (g >> 5) << 3 | b >> 5
            let sum = buckets[key, default: (0, 0, 0, 0)]
            buckets[key] = (sum.red + r, sum.green + g, sum.blue + b, sum.count + 1)
        }
        // Sorted so ties between equal buckets resolve the same way every launch.
        let ordered = buckets.sorted { $0.key < $1.key }.map(\.value)
        let colors = ordered.map { sum in
            (color: RGB(
                red: Double(sum.red) / Double(sum.count) / 255,
                green: Double(sum.green) / Double(sum.count) / 255,
                blue: Double(sum.blue) / Double(sum.count) / 255
            ), count: sum.count)
        }
        guard let dominant = colors.max(by: { $0.count < $1.count }) else { return nil }
        // Vividness weighted by share, so a single bright speck cannot win.
        let accent = colors.max { $0.color.hsl.saturation * Double($0.count) < $1.color.hsl.saturation * Double($1.count) }!
        return (accent.color, dominant.color)
    }
}
