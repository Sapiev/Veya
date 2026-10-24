import CoreGraphics
import Foundation
import ImageIO
@testable import SpotCoreKit
import Testing
import UniformTypeIdentifiers

/// A `width` x `height` image of random pixels, which compresses badly.
func noiseImage(width: Int, height: Int, type: UTType = .png) -> Data {
    var generator = SystemRandomNumberGenerator()
    var pixels = (0 ..< width * height * 4).map { _ in UInt8.random(in: 0 ... 255, using: &generator) }
    let context = pixels.withUnsafeMutableBytes { buffer in
        CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
    }
    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func size(of jpeg: Data) -> (Int, Int) {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return (0, 0) }
    return (width, height)
}

struct PlaylistPictureTests {
    @Test func scalesALargeImageDownKeepingItsAspect() throws {
        let jpeg = try PlaylistPicture.jpeg(from: noiseImage(width: 2000, height: 1000))

        #expect(jpeg.starts(with: [0xFF, 0xD8, 0xFF]))
        #expect(jpeg.count <= PlaylistPicture.maxBytes)
        let (width, height) = size(of: jpeg)
        #expect(width == 640)
        #expect(height == 320)
    }

    @Test func lowersQualityUntilNoiseFitsTheLimit() throws {
        let jpeg = try PlaylistPicture.jpeg(from: noiseImage(width: 640, height: 640, type: .jpeg))
        #expect(jpeg.count <= PlaylistPicture.maxBytes)
        #expect(jpeg.starts(with: [0xFF, 0xD8, 0xFF]))
    }

    @Test func keepsASmallImageAtItsSize() throws {
        let (width, height) = try size(of: PlaylistPicture.jpeg(from: noiseImage(width: 300, height: 200)))
        #expect(width == 300)
        #expect(height == 200)
    }

    @Test func rejectsDataThatIsNotAnImage() {
        #expect(throws: PlaylistPicture.Failure.undecodable) { try PlaylistPicture.jpeg(from: Data("not an image".utf8)) }
        #expect(throws: PlaylistPicture.Failure.undecodable) { try PlaylistPicture.jpeg(from: Data()) }
    }
}
