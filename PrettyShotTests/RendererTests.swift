import PrettyShotCore
import XCTest
@testable import PrettyShot

final class RendererTests: XCTestCase {
    private func input(_ image: CGImage, crop: CGRect? = nil, background: BackgroundStyle, scale: CGFloat = 2) -> RenderInput {
        RenderInput(
            base: image,
            crop: crop ?? CGRect(x: 0, y: 0, width: image.width, height: image.height),
            annotations: [],
            background: background,
            scale: scale
        )
    }

    func testLayoutAddsScaledPaddingOnlyWithBackground() {
        let image = TestImages.make(width: 400, height: 300)
        let styled = Renderer.layout(for: input(image, background: .default))
        XCTAssertEqual(styled.canvasSize, CGSize(width: 400 + 2 * 56, height: 300 + 2 * 56)) // 28pt × 2x
        XCTAssertEqual(styled.imageRect.origin, CGPoint(x: 56, y: 56))

        let plain = Renderer.layout(for: input(image, background: BackgroundStyle(presetKey: nil, padding: 28, radius: 12, shadow: 48)))
        XCTAssertEqual(plain.canvasSize, CGSize(width: 400, height: 300))
    }

    func testCropMappingRoundTrips() {
        let image = TestImages.make(width: 400, height: 300)
        let layout = Renderer.layout(for: input(image, crop: CGRect(x: 100, y: 50, width: 200, height: 100), background: .default))
        let imagePoint = CGPoint(x: 150, y: 80)
        let canvasPoint = layout.canvasPoint(fromImage: imagePoint)
        XCTAssertEqual(canvasPoint, CGPoint(x: 56 + 50, y: 56 + 30))
        XCTAssertEqual(layout.imagePoint(fromCanvas: canvasPoint), imagePoint)
    }

    func testRenderProducesCanvasSizedImageWithBackgroundCorners() {
        let image = TestImages.make(width: 120, height: 80)
        let output = Renderer.render(input(image, background: .default, scale: 1))
        XCTAssertEqual(output?.width, 120 + 56)
        XCTAssertEqual(output?.height, 80 + 56)

        // Top-left corner is Paper Mist (#F7F2EA-ish), not transparent.
        let corner = TestImages.pixel(output!, x: 1, y: 1)
        XCTAssertEqual(corner[3], 255)
        XCTAssertGreaterThan(Int(corner[0]), 200)
    }

    func testPlainRenderKeepsPixelsAndIsNotFlipped() {
        // Top half black, bottom half white → verify orientation survives the y-down pipeline.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 5)) // CG y-up: bottom half
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 5, width: 10, height: 5)) // top half
        let image = context.makeImage()!

        let output = Renderer.render(input(image, background: BackgroundStyle(presetKey: nil, padding: 0, radius: 0, shadow: 0), scale: 1))!
        XCTAssertLessThan(TestImages.pixel(output, x: 5, y: 1)[0], 20)
        XCTAssertGreaterThan(TestImages.pixel(output, x: 5, y: 8)[0], 235)
    }

    func testRedactionChangesOnlyTheRegion() {
        let image = TestImages.make(width: 200, height: 100, striped: true)
        let region = Annotation(kind: .pixelate, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 100),
                                color: .bloomRose, lineWidth: 4, fontSize: 22)
        let redacted = Redactor.apply([region], to: image, scale: 1)

        // Inside: stripes are averaged into grey; outside: untouched stripes.
        let inside = [TestImages.pixel(redacted, x: 40, y: 50)[0], TestImages.pixel(redacted, x: 41, y: 50)[0]]
        XCTAssertLessThan(abs(Int(inside[0]) - Int(inside[1])), 40)
        let outside = [TestImages.pixel(redacted, x: 160, y: 50)[0], TestImages.pixel(redacted, x: 161, y: 50)[0]]
        XCTAssertGreaterThan(abs(Int(outside[0]) - Int(outside[1])), 200)
    }

    func testFacadeMatchesSharedCompositorPixels() {
        let image = TestImages.make(width: 80, height: 40, striped: true)
        let cases: [(String, RenderInput)] = [
            ("pastel", input(image, background: .default, scale: 2)),
            ("plain", input(image, background: BackgroundStyle(presetKey: nil, padding: 28, radius: 12, shadow: 48), scale: 1)),
            ("crop", input(image, crop: CGRect(x: 10, y: 4, width: 40, height: 20), background: BackgroundStyle(presetKey: "paper-mist", padding: 16, radius: 8, shadow: 20), scale: 2)),
            ("preview-size", {
                var rendered = input(image, background: BackgroundStyle(presetKey: "night-ink", padding: 12, radius: 0, shadow: 0), scale: 1)
                rendered.baseSize = CGSize(width: 160, height: 80)
                return rendered
            }()),
        ]
        for (name, rendered) in cases {
            let viaApp = Renderer.render(rendered)
            let viaCore = BeautifyRenderer.render(rendered.beautifyInput)
            XCTAssertEqual(viaApp?.width, viaCore?.width, name)
            XCTAssertEqual(viaApp?.height, viaCore?.height, name)
            XCTAssertEqual(TestImages.bytes(viaApp!), TestImages.bytes(viaCore!), name)
        }
    }

    func testAnnotationRedactionMatchesSharedRegion() {
        let image = TestImages.make(width: 80, height: 40, striped: true)
        let annotation = Annotation(kind: .blur, start: CGPoint(x: 8, y: 4), end: CGPoint(x: 48, y: 28),
                                    color: .bloomRose, lineWidth: 4, fontSize: 22)
        let viaAnnotation = Redactor.apply([annotation], to: image, scale: 2, geometryScale: 0.5)
        let viaRegion = Redactor.apply([
            SharedMark(kind: .blur, rect: annotation.rect, meaningful: true),
        ], to: image, scale: 2, geometryScale: 0.5)
        XCTAssertEqual(TestImages.bytes(viaAnnotation), TestImages.bytes(viaRegion))
    }

    func testFacadeStillDrawsAnnotations() {
        let image = TestImages.make(width: 40, height: 40)
        var rendered = input(image, background: BackgroundStyle(presetKey: nil, padding: 0, radius: 0, shadow: 0), scale: 1)
        rendered.annotations = [
            Annotation(kind: .arrow, start: CGPoint(x: 2, y: 20), end: CGPoint(x: 38, y: 20),
                       color: RGBAColor(hex: 0x000000), lineWidth: 4, fontSize: 16),
        ]
        let output = Renderer.render(rendered)!
        XCTAssertLessThan(TestImages.pixel(output, x: 20, y: 20)[0], 80)
    }
}

private struct SharedMark: Redactable {
    var kind: RedactionKind
    var rect: CGRect
    var meaningful: Bool

    var redactionKind: RedactionKind? { kind }
    var redactionRect: CGRect { rect }
    var isMeaningfulRedaction: Bool { meaningful }
}
