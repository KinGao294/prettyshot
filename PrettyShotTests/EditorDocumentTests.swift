import XCTest
@testable import PrettyShot

@MainActor
final class EditorDocumentTests: XCTestCase {
    private func makeDocument(width: Int = 400, height: Int = 300, scale: CGFloat = 1) -> EditorDocument {
        EditorDocument(image: TestImages.make(width: width, height: height, striped: true), scale: scale, mode: .region,
                       background: .default, sourceHistoryID: nil)
    }

    private func drag(_ doc: EditorDocument, from a: CGPoint, to b: CGPoint) {
        doc.pointerDown(at: a)
        doc.pointerDragged(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
        doc.pointerDragged(to: b)
        doc.pointerUp(at: b)
    }

    func testDrawingShapesAndUndoRedo() {
        let doc = makeDocument()
        doc.tool = .arrow
        drag(doc, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 80))
        doc.tool = .rectangle
        drag(doc, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 120, y: 90))
        doc.tool = .ellipse
        drag(doc, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 90, y: 60))
        XCTAssertEqual(doc.annotations.map(\.kind), [.arrow, .rectangle, .ellipse])

        doc.undo()
        XCTAssertEqual(doc.annotations.count, 2)
        doc.redo()
        XCTAssertEqual(doc.annotations.count, 3)
        XCTAssertTrue(doc.canUndo)
        XCTAssertFalse(doc.canRedo)
    }

    func testAccidentalClicksDoNotCreateShapes() {
        let doc = makeDocument()
        doc.tool = .rectangle
        drag(doc, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 11, y: 11))
        XCTAssertTrue(doc.annotations.isEmpty)
        XCTAssertFalse(doc.canUndo)
    }

    func testCountersIncrement() {
        let doc = makeDocument()
        doc.tool = .counter
        for x in [20, 60, 100] {
            doc.pointerDown(at: CGPoint(x: x, y: 40))
            doc.pointerUp(at: CGPoint(x: x, y: 40))
        }
        XCTAssertEqual(doc.annotations.map(\.number), [1, 2, 3])
    }

    func testTextCommitAndReEdit() {
        let doc = makeDocument()
        doc.tool = .text
        doc.pointerDown(at: CGPoint(x: 50, y: 50))
        doc.pointerUp(at: CGPoint(x: 50, y: 50))
        XCTAssertNotNil(doc.pendingText)
        doc.pendingText?.text = "Hello 纸感"
        doc.commitPendingText()
        XCTAssertEqual(doc.annotations.first?.text, "Hello 纸感")

        // Clicking the existing text re-opens it for editing instead of adding a new one.
        let origin = doc.annotations[0].start
        doc.pointerDown(at: CGPoint(x: origin.x + 2, y: origin.y + 2))
        doc.pointerUp(at: CGPoint(x: origin.x + 2, y: origin.y + 2))
        XCTAssertEqual(doc.pendingText?.text, "Hello 纸感")
        doc.pendingText?.text = "Edited"
        doc.commitPendingText()
        XCTAssertEqual(doc.annotations.map(\.text), ["Edited"])

        // Empty text is discarded.
        doc.pointerDown(at: CGPoint(x: 200, y: 200))
        doc.pointerUp(at: CGPoint(x: 200, y: 200))
        doc.commitPendingText()
        XCTAssertEqual(doc.annotations.count, 1)
    }

    func testCropAppliesAndReturnsToPreviousTool() {
        let doc = makeDocument()
        doc.tool = .rectangle
        doc.tool = .crop
        drag(doc, from: CGPoint(x: 50, y: 40), to: CGPoint(x: 250, y: 190))
        XCTAssertEqual(doc.cropRect, CGRect(x: 50, y: 40, width: 200, height: 150))
        XCTAssertEqual(doc.tool, .rectangle)

        let exported = doc.exportImage()
        let padding = Int((BackgroundStyle.default.padding).rounded()) * 2
        XCTAssertEqual(exported?.width, 200 + padding)
        XCTAssertEqual(exported?.height, 150 + padding)

        doc.resetCrop()
        XCTAssertNil(doc.cropRect)
    }

    func testCropIsClampedToImage() {
        let doc = makeDocument()
        doc.tool = .crop
        drag(doc, from: CGPoint(x: -50, y: -50), to: CGPoint(x: 1000, y: 1000))
        XCTAssertEqual(doc.cropRect, doc.imageBounds)
    }

    func testRedactionRebuildsBaseAndSelectMoves() {
        let doc = makeDocument()
        doc.tool = .blur
        drag(doc, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 120, y: 120))
        XCTAssertFalse(doc.redactedBase === doc.original)
        XCTAssertTrue(doc.vectorAnnotations.isEmpty)

        doc.tool = .select
        drag(doc, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 160, y: 60))
        XCTAssertEqual(doc.redactions.first?.rect.minX, 100)

        doc.deleteSelected()
        XCTAssertTrue(doc.annotations.isEmpty)
        XCTAssertTrue(doc.redactedBase === doc.original)
    }

    func testStyleAppliesToSelection() {
        let doc = makeDocument(scale: 2)
        doc.tool = .rectangle
        drag(doc, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 120, y: 90))
        doc.tool = .select
        doc.pointerDown(at: CGPoint(x: 20, y: 50))
        doc.pointerUp(at: CGPoint(x: 20, y: 50))
        XCTAssertNotNil(doc.selectedID)
        doc.strokeLevel = .thick
        doc.color = RGBAColor.palette[1]
        doc.applyStyleToSelection()
        XCTAssertEqual(doc.annotations[0].lineWidth, StrokeLevel.thick.lineWidth * 2)
        XCTAssertEqual(doc.annotations[0].color, RGBAColor.palette[1])
    }
}
