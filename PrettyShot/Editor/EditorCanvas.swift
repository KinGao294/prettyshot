import AppKit
import PrettyShotCore
import SwiftUI

/// Live canvas. Draws through `Renderer.draw` (same code as export) scaled to fit, and maps
/// pointer events back into image pixels for `EditorDocument`.
@MainActor
struct EditorCanvas: View {
    @ObservedObject var doc: EditorDocument
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let cropEditing = doc.tool == .crop
            let input = doc.renderInput(forCropEditing: cropEditing)
            let layout = Renderer.layout(for: input)
            let zoom = fitZoom(canvas: layout.canvasSize, available: geo.size)
            let displaySize = CGSize(width: layout.canvasSize.width * zoom, height: layout.canvasSize.height * zoom)

            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    context.withCGContext { cg in
                        cg.scaleBy(x: zoom, y: zoom)
                        Renderer.draw(input, in: cg) { cg in
                            drawEditorChrome(in: cg, zoom: zoom)
                        }
                    }
                }
                .frame(width: displaySize.width, height: displaySize.height)
                .shadow(color: input.background.preset == nil ? Palette.charcoal.opacity(0.15) : .clear, radius: 10, y: 4)

                if let pending = doc.pendingText {
                    let p = layout.canvasPoint(fromImage: pending.point)
                    PendingTextField(doc: doc, fontSize: pending.fontSize * zoom, color: pending.color.color)
                        .offset(x: p.x * zoom - 4, y: p.y * zoom - 3)
                }
            }
            .frame(width: displaySize.width, height: displaySize.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            doc.pointerDown(at: imagePoint(value.startLocation, layout: layout, zoom: zoom))
                        }
                        doc.pointerDragged(to: imagePoint(value.location, layout: layout, zoom: zoom))
                    }
                    .onEnded { value in
                        if !isDragging {
                            doc.pointerDown(at: imagePoint(value.startLocation, layout: layout, zoom: zoom))
                        }
                        isDragging = false
                        doc.pointerUp(at: imagePoint(value.location, layout: layout, zoom: zoom))
                    }
            )
            .onHover { inside in
                if inside { cursor.push() } else { NSCursor.pop() }
            }
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .padding(28)
    }

    private var cursor: NSCursor {
        switch doc.tool {
        case .select: return .arrow
        case .text: return .iBeam
        default: return .crosshair
        }
    }

    /// Fit inside the available space, never above 100 % (1 image point per screen point).
    private func fitZoom(canvas: CGSize, available: CGSize) -> CGFloat {
        guard canvas.width > 0, canvas.height > 0, available.width > 0, available.height > 0 else { return 1 }
        return min(available.width / canvas.width, available.height / canvas.height, 1 / doc.scale)
    }

    private func imagePoint(_ viewPoint: CGPoint, layout: RenderLayout, zoom: CGFloat) -> CGPoint {
        layout.imagePoint(fromCanvas: CGPoint(x: viewPoint.x / zoom, y: viewPoint.y / zoom))
    }

    /// Drafts, selection outline and crop mask. Runs in image-pixel coordinates.
    private func drawEditorChrome(in cg: CGContext, zoom: CGFloat) {
        let hairline = 1.5 / zoom
        let rose = CGColor(srgbRed: 0.91, green: 0.63, blue: 0.66, alpha: 1)

        if let draft = doc.draft {
            if draft.kind.isRedaction {
                cg.saveGState()
                cg.setFillColor(CGColor(srgbRed: 0.17, green: 0.16, blue: 0.16, alpha: 0.18))
                cg.fill(draft.rect)
                cg.setStrokeColor(CGColor(srgbRed: 0.17, green: 0.16, blue: 0.16, alpha: 0.8))
                cg.setLineWidth(hairline)
                cg.setLineDash(phase: 0, lengths: [5 / zoom, 4 / zoom])
                cg.stroke(draft.rect)
                cg.restoreGState()
            } else {
                AnnotationRenderer.draw(draft, in: cg)
            }
        }

        if doc.tool == .select, let selected = doc.selectedAnnotation {
            cg.saveGState()
            cg.setStrokeColor(rose)
            cg.setLineWidth(hairline)
            cg.setLineDash(phase: 0, lengths: [5 / zoom, 3 / zoom])
            cg.stroke(selected.bounds.insetBy(dx: -4 / zoom, dy: -4 / zoom))
            cg.restoreGState()
        }

        if doc.tool == .crop {
            let bounds = doc.imageBounds
            let rect = doc.cropDraft ?? doc.cropRect ?? bounds
            cg.saveGState()
            cg.addRect(bounds)
            cg.addRect(rect)
            cg.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45))
            cg.fillPath(using: .evenOdd)

            cg.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35))
            cg.setLineWidth(1 / zoom)
            for i in 1...2 {
                let x = rect.minX + rect.width * CGFloat(i) / 3
                let y = rect.minY + rect.height * CGFloat(i) / 3
                cg.move(to: CGPoint(x: x, y: rect.minY)); cg.addLine(to: CGPoint(x: x, y: rect.maxY))
                cg.move(to: CGPoint(x: rect.minX, y: y)); cg.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            cg.strokePath()

            cg.setStrokeColor(rose)
            cg.setLineWidth(2 / zoom)
            cg.stroke(rect)
            cg.restoreGState()
        }
    }
}

/// Inline text entry positioned on the canvas. ↩ commits, Esc cancels.
@MainActor
private struct PendingTextField: View {
    @ObservedObject var doc: EditorDocument
    let fontSize: CGFloat
    let color: Color
    @FocusState private var focused: Bool

    var body: some View {
        TextField("输入文字", text: Binding(
            get: { doc.pendingText?.text ?? "" },
            set: { doc.pendingText?.text = $0 }
        ))
        .textFieldStyle(.plain)
        .font(.system(size: max(fontSize, 9), weight: .semibold, design: .rounded))
        .foregroundStyle(color)
        .fixedSize()
        .frame(minWidth: 80, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.bloomRose, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .focused($focused)
        .onSubmit { doc.commitPendingText() }
        .onExitCommand { doc.cancelPendingText() }
        .task {
            // Focus after the field is in the window, otherwise AppKit drops the request.
            try? await Task.sleep(nanoseconds: 30_000_000)
            focused = true
        }
    }
}
