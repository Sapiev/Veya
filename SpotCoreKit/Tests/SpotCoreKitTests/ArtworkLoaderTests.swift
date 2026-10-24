import Foundation
import ImageIO
@testable import SpotCoreKit
import Testing
import UniformTypeIdentifiers

struct ArtworkLoaderTests {
    private let directory = URL.temporaryDirectory.appending(path: "ArtworkLoaderTests-\(UUID().uuidString)")

    private static let covers = [
        Artwork(url: "https://i.scdn.co/image/a64", size: .small, width: 64, height: 64),
        Artwork(url: "https://i.scdn.co/image/a300", size: .default, width: 300, height: 300),
        Artwork(url: "https://i.scdn.co/image/a640", size: .large, width: 640, height: 640),
    ]

    @Test func picksTheSmallestArtworkThatFills() {
        #expect(Self.covers.best(forPixels: 64)?.width == 64)
        #expect(Self.covers.best(forPixels: 65)?.width == 300)
        #expect(Self.covers.best(forPixels: 600)?.width == 640)
        #expect(Self.covers.best(forPixels: 2000)?.width == 640)
        #expect([Artwork]().best(forPixels: 100) == nil)
    }

    @Test func fallsBackToTheSizeClassWhenWidthIsUnknown() {
        let unsized = [
            Artwork(url: "large", size: .large, width: 0, height: 0),
            Artwork(url: "small", size: .small, width: 0, height: 0),
        ]
        #expect(unsized.best(forPixels: 50)?.url == "small")
        #expect(unsized.best(forPixels: 200)?.url == "large")
    }

    @Test func decodesADownscaledThumbnailAndDownloadsOnce() async throws {
        let fetches = Counter()
        let loader = ArtworkLoader(directory: directory) { url in
            fetches.increment()
            #expect(url.absoluteString.hasSuffix("a300"))
            return try png(side: 300)
        }

        async let first = loader.image(for: Self.covers, pixels: 100)
        async let second = loader.image(for: Self.covers, pixels: 100)
        let images = await [first, second]
        let again = await loader.image(for: Self.covers, pixels: 100)

        #expect(images.allSatisfy { $0?.width == 100 })
        #expect(again?.width == 100)
        #expect(fetches.value == 1)
    }

    @Test func aRelaunchServesArtworkFromDisk() async throws {
        let first = ArtworkLoader(directory: directory) { _ in try png(side: 64) }
        _ = await first.image(for: Self.covers, pixels: 64)

        let relaunched = ArtworkLoader(directory: directory) { _ in throw URLError(.notConnectedToInternet) }
        #expect(await relaunched.image(for: Self.covers, pixels: 32)?.width == 32)
    }

    @Test func bytesThatDoNotDecodeAreNotCached() async {
        let fetches = Counter()
        let loader = ArtworkLoader(directory: directory) { _ in
            fetches.increment()
            return Data("<html>not found</html>".utf8)
        }

        #expect(await loader.image(for: Self.covers, pixels: 64) == nil)
        #expect(await loader.image(for: Self.covers, pixels: 64) == nil)
        #expect(fetches.value == 2)
    }

    @Test func diskCacheEvictsTheLeastRecentlyUsedFile() async throws {
        let cache = ArtworkDiskCache(directory: directory, limitBytes: 250)
        let urls = (0..<3).map { URL(string: "https://i.scdn.co/image/\($0)")! }
        await cache.store(Data(count: 100), for: urls[0])
        await cache.store(Data(count: 100), for: urls[1])
        try await Task.sleep(for: .milliseconds(10))
        _ = cache.data(for: urls[0])

        await cache.store(Data(count: 100), for: urls[2])

        #expect(cache.data(for: urls[0]) != nil)
        #expect(cache.data(for: urls[1]) == nil)
        #expect(cache.data(for: urls[2]) != nil)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

func png(side: Int) throws -> Data {
    let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { throw URLError(.cannotDecodeContentData) }
    return data as Data
}
