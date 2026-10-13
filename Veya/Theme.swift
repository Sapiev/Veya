import SpotCoreKit
import SwiftUI

/// Spacing, radii and type from the Tone design; one place so screens stay on the same rhythm.
nonisolated enum Theme {
    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16
    static let s5: CGFloat = 20, s6: CGFloat = 24, s8: CGFloat = 32, s12: CGFloat = 48

    static let sidebarWidth: CGFloat = 248, queueWidth: CGFloat = 290
    static let panelRadius: CGFloat = 14, cardRadius: CGFloat = 8, smallRadius: CGFloat = 6
    static let playerHeight: CGFloat = 76, playerRadius: CGFloat = 22

    static let fast = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.16)
    static let standard = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24)
    static let themeChange = Animation.easeInOut(duration: 0.4)

    static let greeting = Font.system(size: 28, weight: .bold)
    static let sectionTitle = Font.system(size: 22, weight: .bold)
    static let heroTitle = Font.system(size: 56, weight: .heavy)
    static let cardTitle = Font.system(size: 13, weight: .semibold)
    static let cardSubtitle = Font.system(size: 12)
}

extension Color {
    init(_ rgb: RGB) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// Hover fill and resting tile fill (`--fill`), and selected fill (`--fill-2`).
    static let fill = Color.primary.opacity(0.07)
    static let fillStrong = Color.primary.opacity(0.12)
}

extension EnvironmentValues {
    /// Colors taken from the playing track's artwork; the system palette otherwise.
    @Entry var palette = AdaptivePalette.system(dark: true, accent: .defaultAccent)
}

extension RGB {
    /// Veya's warm red (#C94636), the accent until the user picks another in Settings.
    static let defaultAccent = RGB(red: 0xC9 / 255, green: 0x46 / 255, blue: 0x36 / 255)
}

/// Where the window takes its colors from (Settings > General).
enum ColorSource: String {
    /// The playing track's artwork; the accent color while nothing plays.
    case artwork
    /// Always the accent color.
    case accent
    /// The accent color turning around the color wheel.
    case cycle

    static let key = "colorSource"
    static let accentKey = "accentColor"
    static let cycleSecondsKey = "colorCycleSeconds"
    static let defaultCycleSeconds = 60.0
}

extension RGB {
    init(_ color: Color) {
        let srgb = NSColor(color).usingColorSpace(.sRGB) ?? .systemBlue
        self.init(red: Double(srgb.redComponent), green: Double(srgb.greenComponent), blue: Double(srgb.blueComponent))
    }
}

/// Publishes the window's palette: from the playing track's artwork, the accent color, or the accent cycling.
struct AdaptiveColors: ViewModifier {
    let artwork: [Artwork]
    @AppStorage(ColorSource.key) private var source = ColorSource.artwork
    @AppStorage(ColorSource.accentKey) private var accentHex = RGB.defaultAccent.hex
    @AppStorage(ColorSource.cycleSecondsKey) private var cycleSeconds = ColorSource.defaultCycleSeconds
    @Environment(\.artworkLoader) private var loader
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var colors: (accent: RGB, dominant: RGB)?
    /// How far the cycle has turned the accent's hue, in turns of the wheel.
    @State private var turns = 0.0

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let accent = RGB(hex: accentHex) ?? .defaultAccent
        let cycling = source == .cycle && !reduceMotion
        // The accent washes the whole window, so the cycle reads in the background too.
        let shown = accent.rotatingHue(by: cycling ? turns : 0)
        let palette: AdaptivePalette = switch (source, colors) {
        case let (.artwork, colors?): AdaptivePalette(accent: colors.accent, dominant: colors.dominant, dark: dark)
        case (.artwork, nil): .system(dark: dark, accent: accent)
        case (.accent, _), (.cycle, _): AdaptivePalette(accent: shown, dominant: shown, dark: dark)
        }
        content
            .environment(\.palette, palette)
            .tint(Color(palette.tint))
            // Cycle steps blend into each other, so the hue never stops moving.
            .animation(reduceMotion ? nil : cycling ? .linear(duration: 1) : Theme.themeChange, value: palette)
            .task(id: cycling ? cycleSeconds : nil) {
                guard cycling, cycleSeconds > 0 else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    turns = (turns + 1 / cycleSeconds).truncatingRemainder(dividingBy: 1)
                }
            }
            .task(id: artwork.first?.url) {
                guard let image = await loader?.image(for: artwork, pixels: 64) else {
                    colors = nil
                    return
                }
                colors = ArtworkColors.extract(from: image)
            }
    }
}

/// The window wash: the ambient color with a glow from the top right and a softer one bottom left.
struct AmbientBackground: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Color(palette.ambient)
            .overlay {
                GeometryReader { proxy in
                    let reach = max(proxy.size.width, proxy.size.height)
                    ZStack {
                        RadialGradient(
                            colors: [Color(palette.glow), .clear],
                            center: UnitPoint(x: 0.72, y: -0.12),
                            startRadius: 0,
                            endRadius: reach * 0.62
                        )
                        RadialGradient(
                            colors: [Color(palette.glow).opacity(0.45), .clear],
                            center: UnitPoint(x: 0, y: 1.1),
                            startRadius: 0,
                            endRadius: reach * 0.55
                        )
                    }
                }
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

extension View {
    /// A translucent panel with the design's hairline edge (`.glass`, `.glass-strong`).
    func glassPanel(cornerRadius: CGFloat, strong: Bool = false) -> some View {
        background(strong ? .regularMaterial : .ultraThinMaterial, in: .rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
            }
    }
}

/// The round accent play button (`.fab`): 44 pt, 56 pt when `large`.
struct PlayFab: View {
    let label: LocalizedStringKey
    var large = false
    var systemImage = "play.fill"
    let action: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: large ? 22 : 17, weight: .semibold))
                .foregroundStyle(Color(palette.tintInk))
                .frame(width: large ? 56 : 44, height: large ? 56 : 44)
                .background(Color(palette.tint), in: .circle)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 6)
                .scaleEffect(hovering ? 1.05 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .help(Text(label))
        .onHover { hovering = $0 }
        .animation(Theme.fast, value: hovering)
    }
}

/// A section title in the 22 pt display weight with the design's top spacing.
struct SectionHeader: View {
    let title: LocalizedStringKey
    var top = Theme.s8

    var body: some View {
        Text(title)
            .font(Theme.sectionTitle)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, top)
            .padding(.bottom, Theme.s3)
    }
}
