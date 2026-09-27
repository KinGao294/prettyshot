import CoreGraphics
@testable import PrettyShot

enum TestImages {
    /// Solid-colour sRGB image, optionally with a contrasting stripe pattern so redactions change pixels.
    static func make(width: Int, height: Int, striped: Bool = false) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if striped {
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            var x = 0
            while x < width {
                context.fill(CGRect(x: x, y: 0, width: 1, height: height))
                x += 2
            }
        }
        return context.makeImage()!
    }

    /// RGBA bytes of one pixel (x, y measured from the top-left).
    static func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return data
    }
}
