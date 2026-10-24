import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a chosen image into what Spotify takes as a playlist picture: a JPEG
/// of at most `maxBytes`, its longest side at most `maxSide` pixels.
public enum PlaylistPicture {
    public static let maxBytes = 256 * 1024
    public static let maxSide = 640

    public enum Failure: Error, Equatable {
        case undecodable
        /// Still over `maxBytes` at the lowest quality tried.
        case tooLarge
    }

    public static func jpeg(from data: Data) throws -> Data {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw Failure.undecodable }
        for quality in stride(from: 0.9, through: 0.1, by: -0.1) {
            let jpeg = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil)
            else { throw Failure.undecodable }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw Failure.undecodable }
            if jpeg.length <= maxBytes { return jpeg as Data }
        }
        throw Failure.tooLarge
    }
}
