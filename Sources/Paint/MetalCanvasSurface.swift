import AppKit
import QuartzCore

/// Hosts only the visible image. The scroll view and AppKit tool decorations stay independent.
final class MetalCanvasSurface: NSView {
    struct Frame: Equatable {
        let region: CGRect
        let size: CGSize
        let transform: CGAffineTransform
        let copy: Bool
        let sampling: MoveResampler.Mode
    }

    private var last: (MetalMovePreview, Frame)?
    private var inFlight = false
    private var pending = false
    private var failed = false

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.isOpaque = false
        return layer
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func clearFrame() {
        last = nil
        isHidden = true
    }

    func draw(_ frame: Frame, with renderer: MetalMovePreview, invalidate: @escaping () -> Void) -> Bool {
        guard !failed, let layer = layer as? CAMetalLayer else { return false }
        if let last, last.0 === renderer, last.1 == frame { return true }
        if inFlight {
            pending = true
            return true
        }
        inFlight = renderer.present(in: layer, region: frame.region, size: frame.size, by: frame.transform,
                                    copy: frame.copy, sampling: frame.sampling) { [weak self] success in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight = false
                self.failed = !success
                if self.pending || !success {
                    self.pending = false
                    invalidate()
                }
            }
        }
        if inFlight { last = (renderer, frame) }
        return inFlight
    }
}

final class MetalCanvasOverlay: NSView {
    var drawDecorations: ((CGContext) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: -frame.minX, y: -frame.minY)
        drawDecorations?(context)
        context.restoreGState()
    }
}
