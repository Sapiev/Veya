import SpotCoreKit
import SwiftUI

extension EnvironmentValues {
    /// Nil in UI test scenarios, which never reach Spotify's CDN.
    @Entry var artworkLoader: ArtworkLoader?
}

/// Square cover art sized for `side` points at the screen's backing scale.
struct ArtworkView: View {
    let artwork: [Artwork]
    let side: CGFloat
    @Environment(\.displayScale) private var scale
    @Environment(\.artworkLoader) private var loader
    @State private var image: CGImage?

    var body: some View {
        let pixels = Int((side * scale).rounded(.up))
        Group {
            if let image {
                Image(decorative: image, scale: scale).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: side, height: side)
        .clipped()
        // Every cover sits beside its title, so VoiceOver skips it.
        .accessibilityHidden(true)
        .task(id: [artwork.first?.url, String(pixels)]) {
            let loaded = await loader?.image(for: artwork, pixels: pixels)
            // A cancelled load must not paint a cover the view no longer shows.
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
