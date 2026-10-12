import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ScreenshotWriter {
    public enum WriteError: LocalizedError {
        case cannotCreateDestination
        case encodingFailed

        public var errorDescription: String? {
            switch self {
                case .cannotCreateDestination: "Could not create the screenshot file."
                case .encodingFailed: "Could not encode the screenshot as PNG."
            }
        }
    }

    /// Encodes a framebuffer image as PNG. Only pixel data is written: no metadata about the connection.
    public static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()

        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw WriteError.cannotCreateDestination
        }

        CGImageDestinationAddImage(destination, opaqueCopy(of: image), nil)

        guard CGImageDestinationFinalize(destination) else {
            throw WriteError.encodingFailed
        }

        return data as Data
    }

    /// VNC framebuffers are opaque; dropping the alpha channel keeps PNGs smaller.
    static func opaqueCopy(of image: CGImage) -> CGImage {
        let skip: CGImageAlphaInfo

        switch image.alphaInfo {
            case .premultipliedFirst, .first: skip = .noneSkipFirst
            case .premultipliedLast, .last: skip = .noneSkipLast
            default: return image
        }

        guard image.bitsPerPixel == 32,
              let provider = image.dataProvider,
              let colorSpace = image.colorSpace else {
            return image
        }

        let byteOrder = image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue
        let bitmapInfo = CGBitmapInfo(rawValue: byteOrder | skip.rawValue)

        return CGImage(width: image.width,
                       height: image.height,
                       bitsPerComponent: image.bitsPerComponent,
                       bitsPerPixel: image.bitsPerPixel,
                       bytesPerRow: image.bytesPerRow,
                       space: colorSpace,
                       bitmapInfo: bitmapInfo,
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent) ?? image
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        try pngData(image).write(to: url, options: .atomic)
    }
}
