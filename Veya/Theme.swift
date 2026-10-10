import SpotCoreKit
import SwiftUI

/// Spacing, radii and type from the Tone design; one place so screens stay on the same rhythm.
enum Theme {
    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16
    static let s5: CGFloat = 20, s6: CGFloat = 24, s8: CGFloat = 32, s12: CGFloat = 48

    static let sidebarWidth: CGFloat = 248
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
    @Entry var palette = AdaptivePalette.system(dark: true)
}

/// Follows the playing track's artwork and publishes its palette to the window.
struct AdaptiveColors: ViewModifier {
    let artwork: [Artwork]
    @Environment(\.artworkLoader) private var loader
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var colors: (accent: RGB, dominant: RGB)?

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let palette = colors.map { AdaptivePalette(accent: $0.accent, dominant: $0.dominant, dark: dark) }
            ?? .system(dark: dark)
        content
            .environment(\.palette, palette)
            .tint(Color(palette.tint))
            .animation(reduceMotion ? nil : Theme.themeChange, value: palette)
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

    var body: some View {
        Text(title)
            .font(Theme.sectionTitle)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, Theme.s8)
            .padding(.bottom, Theme.s3)
    }
}
