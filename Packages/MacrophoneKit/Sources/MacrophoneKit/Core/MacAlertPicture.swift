#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension MacAlerts {
    /// An alert's picture: scaled to `pictureSide` on its long side, then the quality stepped down
    /// until it fits `pictureBytes` (it rides an iCloud record).
    public static func jpeg(_ image: CGImage) -> Data? {
        let k = min(1, pictureSide / CGFloat(max(image.width, image.height)))
        var img = image
        if k < 1, let ctx = CGContext(data: nil, width: Int(CGFloat(image.width) * k), height: Int(CGFloat(image.height) * k),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            if let scaled = ctx.makeImage() { img = scaled }
        }
        for q in [0.7, 0.55, 0.4, 0.3] {
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            if data.length <= pictureBytes || q == 0.3 { return data as Data }
        }
        return nil
    }
}
#endif
