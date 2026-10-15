import CoreGraphics
@testable import SpotCoreKit
import Testing

struct AdaptivePaletteTests {
    private static let red = RGB(red: 0.86, green: 0.12, blue: 0.16)
    private static let navy = RGB(red: 0.08, green: 0.12, blue: 0.35)
    private static let grey = RGB(red: 0.5, green: 0.5, blue: 0.5)

    @Test(arguments: [true, false])
    func tintTextIsReadableOnTheWindowColors(dark: Bool) {
        for accent in [Self.red, Self.navy, Self.grey, RGB.systemAccent, .white, .black] {
            let palette = AdaptivePalette(accent: accent, dominant: Self.navy, dark: dark)
            #expect(palette.tintText.contrast(with: palette.ambient) >= 4.5)
            // Side panels show the glow through their glass behind small text, such as the queue's playing title.
            #expect(palette.tintText.contrast(with: palette.glow) >= 4.5)
        }
    }

    @Test func hexRoundTripsAndRejectsOtherText() {
        #expect(RGB(hex: "#E0604A")?.hex == "#E0604A")
        #expect(RGB(hex: RGB.systemAccent.hex)?.hex == RGB.systemAccent.hex)
        for text in ["", "E0604A", "#E0604", "#GGGGGG", "#E0604A00"] {
            #expect(RGB(hex: text) == nil, "\(text)")
        }
    }

    @Test func hueRotationWrapsAroundTheWheel() {
        let red = RGB(red: 1, green: 0, blue: 0)
        #expect(red.rotatingHue(by: 1 / 3).hex == "#00FF00")
        #expect(red.rotatingHue(by: 7 / 3).hex == "#00FF00")
        #expect(red.rotatingHue(by: -1 / 3).hex == "#0000FF")
        #expect(Self.grey.rotatingHue(by: 0.5) == Self.grey)
    }

    @Test func inkIsTheMoreReadableOfBlackAndWhite() {
        let palette = AdaptivePalette(accent: Self.red, dominant: Self.red, dark: true)
        let other: RGB = palette.tintInk == .white ? .black : .white
        #expect(palette.tint.contrast(with: palette.tintInk) >= palette.tint.contrast(with: other))
    }

    @Test func ambientFollowsTheSchemeLightness() {
        #expect(AdaptivePalette(accent: Self.red, dominant: Self.red, dark: true).ambient.luminance < 0.05)
        #expect(AdaptivePalette(accent: Self.red, dominant: Self.red, dark: false).ambient.luminance > 0.75)
    }

    @Test func greyDominantKeepsTheAccentHueInTheGlow() {
        let palette = AdaptivePalette(accent: Self.red, dominant: Self.grey, dark: true)
        #expect(palette.glow.red > palette.glow.blue)
    }

    @Test func hslRoundTrips() {
        for color in [Self.red, Self.navy, Self.grey, RGB.systemAccent] {
            let (h, s, l) = color.hsl
            let back = RGB(hue: h, saturation: s, lightness: l)
            #expect(abs(back.red - color.red) < 1e-9 && abs(back.green - color.green) < 1e-9 && abs(back.blue - color.blue) < 1e-9)
        }
    }

    @Test func extractsTheMostCommonAndMostVividColors() throws {
        // Three quarters grey, one quarter saturated red.
        let image = try #require(Self.image(width: 4, height: 4) { x, _ in x == 0 ? (220, 30, 40) : (128, 128, 128) })
        let colors = try #require(ArtworkColors.extract(from: image))
        #expect(abs(colors.dominant.red - colors.dominant.blue) < 0.05)
        #expect(colors.accent.red > 0.7 && colors.accent.green < 0.3)
    }

    private static func image(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage? {
        var bytes: [UInt8] = []
        for y in 0 ..< height {
            for x in 0 ..< width {
                let (r, g, b) = pixel(x, y)
                bytes += [r, g, b, 255]
            }
        }
        let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return context?.makeImage()
    }
}
