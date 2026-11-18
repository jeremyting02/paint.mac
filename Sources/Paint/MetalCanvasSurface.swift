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
        let checkerboard: SIMD4<Float>
        let activeImage: ObjectIdentifier?
        let strokeRevision: Int?
    }

    private var last: (MetalMovePreview, Frame)?
    private var inFlight = false
    private var pending = false
    private var failed = false
    private var drawableMisses = 0
    private var retryScheduled = false

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.isOpaque = true
        return layer
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func clearFrame() {
        last = nil
        isHidden = true
        drawableMisses = 0
    }

    func draw(_ frame: Frame, with renderer: MetalMovePreview,
              activePixels: () -> MetalMovePreview.ActivePixels?, invalidate: @escaping () -> Void) -> Bool {
        guard !failed else { return false }
        guard let layer = layer as? CAMetalLayer else {
            MetalMovePreview.log.error("Canvas has no Metal backing layer")
            return false
        }
        if let last, last.0 === renderer, last.1 == frame { return true }
        if inFlight {
            pending = true
            return true
        }
        let replacement = activePixels()
        if replacement == nil && (frame.activeImage != nil || frame.strokeRevision != nil) {
            MetalMovePreview.log.error("Could not prepare the active layer's preview buffer")
            return false
        }
        let result = renderer.present(in: layer, region: frame.region, size: frame.size, by: frame.transform,
                                    copy: frame.copy, sampling: frame.sampling, activePixels: replacement,
                                    checkerboard: frame.checkerboard) { [weak self] success in
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
        switch result {
        case .submitted:
            inFlight = true
            drawableMisses = 0
            last = (renderer, frame)
            return true
        case .noDrawable:
            drawableMisses += 1
            guard drawableMisses < 3 else {
                MetalMovePreview.log.error("Canvas could not acquire a drawable after retrying")
                return false
            }
            if !retryScheduled {
                retryScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
                    guard let self else { return }
                    self.retryScheduled = false
                    if !self.isHidden { invalidate() }
                }
            }
            return true
        case .encodingFailed:
            MetalMovePreview.log.error("Could not encode the canvas render pass")
            return false
        }
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
