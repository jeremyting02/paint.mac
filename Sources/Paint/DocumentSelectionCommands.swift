import AppKit

extension PaintDocument {
    @objc func selectAllPixels(_ sender: Any?) {
        guard let canvas = editor?.canvas else { return }
        canvas.finishSelection()
        guard let image else { return }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        commitSelection(SelectionOutline(rect: bounds), actionName: "Select All")
    }

    @objc func invertPixelSelection(_ sender: Any?) {
        guard let canvas = editor?.canvas else { return }
        canvas.finishSelection()
        guard let image, let outline = canvas.selectionOutline else { return }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let all = SelectionOutline(rect: bounds)
        let inverted = SelectionOutline.Mode.subtract.applying(outline, to: all)
        commitSelection(inverted, actionName: "Invert Selection")
    }

    @objc func eraseSelectedPixels(_ sender: Any?) {
        guard let canvas = editor?.canvas else { return }
        canvas.finishSelection()
        guard let layer = stack?.activeLayer, layer.isVisible, let outline = canvas.selectionOutline,
              let pixels = layer.straightPixels else { return }
        let canvasBounds = CGRect(x: 0, y: 0, width: layer.image.width, height: layer.image.height)
        let bounds = outline.bounds.integral.intersection(canvasBounds)
        guard !bounds.isEmpty else { return }
        let region = CGRect(x: bounds.minX, y: canvasBounds.height - bounds.maxY, width: bounds.width, height: bounds.height)
        let mask = outline.pixelRectangle ? nil : outline.mask(in: region, imageHeight: layer.image.height)
        guard outline.pixelRectangle || mask != nil else { return }
        let cleared = layer.clearing(region, mask: mask, from: pixels)
        if cleared == pixels {
            commitSelection(nil, actionName: "Erase Selection")
        } else if let result = layer.withPixels(cleared), var next = stack {
            next.layers[next.active] = result
            applyEdit(replacingStack: next, actionName: "Erase Selection", selectionChange: (outline, nil))
        }
    }

    @objc func fillSelectedPixels(_ sender: Any?) {
        guard let canvas = editor?.canvas else { return }
        canvas.finishSelection()
        guard let layer = stack?.activeLayer, layer.isVisible, let outline = canvas.selectionOutline,
              let clipped = outline.clipped(to: CGRect(x: 0, y: 0, width: layer.image.width, height: layer.image.height))
        else { return }
        let color = DrawingColor(canvas.brushColor, in: layer.workingColorSpace)
        guard let result = layer.filling(clipped, blue: color.blue, green: color.green, red: color.red,
                                         alpha: color.alpha) else { return }
        commitPaintLayer(result, actionName: "Fill Selection")
    }
}
