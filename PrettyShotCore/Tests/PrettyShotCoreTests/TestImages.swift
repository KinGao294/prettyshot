import CoreGraphics
import XCTest

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

    static func bytes(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }
}

func XCTAssertSamePixels(
    _ actual: CGImage?,
    _ expected: CGImage?,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let actual, let expected else {
        XCTFail("missing image — \(message)", file: file, line: line)
        return
    }
    XCTAssertEqual(actual.width, expected.width, message, file: file, line: line)
    XCTAssertEqual(actual.height, expected.height, message, file: file, line: line)
    guard actual.width == expected.width, actual.height == expected.height else { return }
    let left = TestImages.bytes(actual)
    let right = TestImages.bytes(expected)
    guard left != right else { return }
    let width = actual.width
    for index in 0..<min(left.count, right.count) where left[index] != right[index] {
        let pixel = index / 4
        let channel = index % 4
        XCTFail(
            "\(message): pixel (\(pixel % width), \(pixel / width)) channel \(channel) is \(left[index]), frozen \(right[index])",
            file: file,
            line: line
        )
        return
    }
    XCTFail("\(message): byte length \(left.count) vs \(right.count)", file: file, line: line)
}
