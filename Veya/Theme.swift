import SpotCoreKit
import SwiftUI

/// Spacing, radii and type from the Tone design; one place so screens stay on the same rhythm.
nonisolated enum Theme {
    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16
    static let s5: CGFloat = 20, s6: CGFloat = 24, s8: CGFloat = 32, s12: CGFloat = 48

    static let sidebarWidth: CGFloat = 248, queueWidth: CGFloat = 290
    /// Icon-only sidebar; still wider than the window buttons that sit inside it.
    static let compactSidebarWidth: CGFloat = 80
    /// Room the window buttons take at the top leading corner (`TrafficLightInset`: 20 pt in, three 14 pt buttons 8 pt apart).
    static let windowButtonsWidth: CGFloat = 72
    static let panelRadius: CGFloat = 14, cardRadius: CGFloat = 8, smallRadius: CGFloat = 6
    static let playerHeight: CGFloat = 76, playerRadius: CGFloat = 22

    static let fast = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.16)
    static let standard = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24)
    static let themeChange = Animation.easeInOut(duration: 0.4)

    @MainActor static let greeting = ScaledFont(size: 28, weight: .bold)
    @MainActor static let sectionTitle = ScaledFont(size: 22, weight: .bold)
    @MainActor static let heroTitle = ScaledFont(size: 56, weight: .heavy)
    @MainActor static let cardTitle = ScaledFont(size: 13, weight: .semibold)
    @MainActor static let cardSubtitle = ScaledFont(size: 12)
}

/// Settings > General > Text size. macOS has no Dynamic Type for SwiftUI, so Veya scales its own fonts.
/// Stored as a percentage: `@AppStorage` keeps only Int or String raw values.
enum TextSize: Int, CaseIterable {
    case standard = 100, large = 115, larger = 130, largest = 150

    static let key = "textSize"

    var scale: CGFloat { CGFloat(rawValue) / 100 }
}

extension EnvironmentValues {
    @Entry var textScale: CGFloat = 1
}

/// The system font at `size` points times the chosen text size; every font in the app goes through it.
struct ScaledFont: ViewModifier {
    let size: CGFloat
    var weight: Font.Weight = .regular
    var design: Font.Design = .default
    @Environment(\.textScale) private var scale

    func body(content: Content) -> some View {
        // swiftlint:disable:next unscaled_font
        content.font(.system(size: size * scale, weight: weight, design: design))
    }
}

/// Publishes the chosen text size to a window and scales the text that sets no font of its own.
struct ScalesText: ViewModifier {
    @AppStorage(TextSize.key) private var size = TextSize.standard

    func body(content: Content) -> some View {
        content
            // swiftlint:disable:next unscaled_font
            .font(.system(size: NSFont.systemFontSize * size.scale))
            .environment(\.textScale, size.scale)
    }
}

/// Pins `.primary`, `.secondary` and `.tertiary` to opaque inks for the window's scheme.
/// Assistive tech reads text color from the accessibility attributes, not the screen: the system
/// label color arrives as dark ink over Veya's dark wash, and `.secondary` as 50% white with no
/// background, which the audit cannot judge. Opaque greys keep the hierarchy and read as drawn.
struct ConcreteInk: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let dark = scheme == .dark, increased = contrast == .increased
        content.foregroundStyle(
            Color(white: dark ? 1 : 0),
            Color(white: dark ? (increased ? 0.9 : 0.78) : (increased ? 0.15 : 0.3)),
            Color(white: dark ? (increased ? 0.8 : 0.62) : (increased ? 0.25 : 0.42))
        )
    }
}

extension View {
    func scaledFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design))
    }
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
            .onChange(of: palette.tint, initial: true) { _, tint in
                SelectionTint.install()
                SelectionTint.color = NSColor(Color(tint))
            }
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
    /// `shown: false` keeps the layout but drops the fill and edge.
    func glassPanel(cornerRadius: CGFloat, strong: Bool = false, shown: Bool = true) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius, strong: strong, shown: shown))
    }
}

/// Increase Contrast swaps the see-through glass for a solid panel with a visible edge.
private struct GlassPanel: ViewModifier {
    let cornerRadius: CGFloat
    let strong: Bool
    let shown: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let increased = contrast == .increased
        // Increase Contrast keeps the panel so text never sits straight on artwork.
        let shown = shown || increased
        let fill: AnyShapeStyle = increased ? AnyShapeStyle(.windowBackground)
            : strong ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.ultraThinMaterial)
        content
            .background(shown ? fill : AnyShapeStyle(.clear), in: .rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(PanelEdge.color(increased), lineWidth: PanelEdge.width(increased))
                    .opacity(shown ? 1 : 0)
            }
    }
}

/// A full-width rule in the glass panel's edge color, to split content inside a panel.
struct PanelEdge: View {
    @Environment(\.colorSchemeContrast) private var contrast

    static func color(_ increased: Bool) -> Color {
        increased ? .primary.opacity(0.6) : .white.opacity(0.14)
    }

    static func width(_ increased: Bool) -> CGFloat {
        increased ? 1 : 0.5
    }

    var body: some View {
        let increased = contrast == .increased
        Rectangle()
            .fill(Self.color(increased))
            .frame(height: Self.width(increased))
            .accessibilityHidden(true)
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
                .scaledFont(size: large ? 22 : 17, weight: .semibold)
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
            .modifier(Theme.sectionTitle)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, top)
            .padding(.bottom, Theme.s3)
    }
}

extension ColorSchemeContrast {
    /// A faded foreground that carries meaning moves halfway to opaque under Increase Contrast.
    func opacity(_ base: Double) -> Double {
        self == .increased ? base + (1 - base) / 2 : base
    }
}

/// The system focus ring is always the system accent, so this draws its own in the palette tint.
private struct FocusRing<ID: Hashable>: ViewModifier {
    let focus: FocusState<ID?>.Binding
    let id: ID
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused(focus, equals: id)
            .overlay {
                if focus.wrappedValue == id {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color(palette.tint), lineWidth: 3)
                }
            }
    }
}

extension View {
    /// Focusable as `id` in `focus`, ringed in the palette tint while focused.
    func focusRing<ID: Hashable>(_ focus: FocusState<ID?>.Binding, equals id: ID) -> some View {
        modifier(FocusRing(focus: focus, id: id))
    }

    /// Up and Down move focus through `ids` and Return runs `activate` on the focused one.
    /// Arrows and Return reach a focused button as AppKit commands, which `onKeyPress` never sees.
    func arrowKeyList<ID: Hashable>(
        _ ids: [ID], focus: FocusState<ID?>.Binding, activate: @escaping (ID) -> Void
    ) -> some View {
        onMoveCommand { direction in
            guard direction == .up || direction == .down else { return }
            let index = focus.wrappedValue.flatMap(ids.firstIndex) ?? (direction == .up ? ids.count : -1)
            let next = index + (direction == .up ? -1 : 1)
            if ids.indices.contains(next) { focus.wrappedValue = ids[next] }
        }
        .onCommand(#selector(NSResponder.insertNewline(_:))) {
            if let current = focus.wrappedValue, ids.contains(current) { activate(current) }
        }
    }
}

extension View {
    /// The accent foreground when `on`, else `fallback`; on an accent row selection, the ink drawn on the accent.
    func accentForeground(_ on: Bool = true, else fallback: some ShapeStyle = .primary) -> some View {
        modifier(AccentForeground(on: on, fallback: fallback))
    }
}

private struct AccentForeground<Fallback: ShapeStyle>: ViewModifier {
    let on: Bool
    let fallback: Fallback
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        if prominence == .increased {
            content.foregroundStyle(Color(palette.tintInk))
        } else if on {
            content.foregroundStyle(Color(palette.tintText))
        } else {
            content.foregroundStyle(fallback)
        }
    }
}
