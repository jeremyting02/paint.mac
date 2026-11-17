import AppKit

extension PaintDocument {
    private static var lastEffect: (filter: RasterFilter, values: [Double])?

    var canFilterActiveLayer: Bool {
        stack?.activeLayer.isVisible == true && windowForSheet?.attachedSheet == nil
    }

    @objc func applyAdjustment(_ sender: NSMenuItem) {
        guard RasterFilter.adjustments.indices.contains(sender.tag) else { return }
        showFilter(RasterFilter.adjustments[sender.tag])
    }

    @objc func applyEffect(_ sender: NSMenuItem) {
        guard RasterFilter.effects.indices.contains(sender.tag) else { return }
        showFilter(RasterFilter.effects[sender.tag])
    }

    func validateRepeatEffect(_ item: NSMenuItem?) -> Bool {
        item?.title = Self.lastEffect.map { "Repeat \($0.filter.title)" } ?? "Repeat Last Effect"
        return canFilterActiveLayer && Self.lastEffect != nil
    }

    @objc func repeatEffect(_ sender: Any?) {
        guard canFilterActiveLayer, let last = Self.lastEffect,
              let input = filterInput() else { return }
        applyFilter(last.filter, input: input, values: last.values)
    }

    func filterInput() -> RasterFilter.Input? {
        editor?.canvas.finishSelection()
        guard let stack, stack.activeLayer.isVisible else { return nil }
        return RasterFilter.Input(layer: stack.activeLayer, selection: editor?.canvas.selectionOutline,
                                  layerIndex: stack.active)
    }

    func showFilter(_ filter: RasterFilter) {
        guard canFilterActiveLayer, let window = windowForSheet, let input = filterInput() else { return }
        if filter.controls.isEmpty && filter.editor == nil {
            applyFilter(filter, input: input, values: [])
            return
        }

        let panel = RasterFilterPanel(filter: filter, input: input)
        panel.preview = { [weak self] layer in
            guard let self, var preview = stack, preview.active == input.layerIndex,
                  preview.activeLayer.image === input.layer.image else { return }
            if let layer { preview.layers[preview.active] = layer }
            editor?.canvas.layerPreview = layer == nil ? nil : preview
        }
        window.beginSheet(panel) { [weak self] response in
            panel.stopPreview()
            self?.editor?.canvas.layerPreview = nil
            guard response == .OK, let layer = panel.result else { return }
            self?.commitFilter(filter, input: input, layer: layer, values: panel.values)
        }
        panel.updatePreview()
    }

    private func applyFilter(_ filter: RasterFilter, input: RasterFilter.Input, values: [Double]) {
        guard let output = input.render(filter, values: values) else {
            presentError(CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Could not apply \(filter.title)."]))
            return
        }
        commitFilter(filter, input: input, layer: output, values: values)
    }

    func commitFilter(_ filter: RasterFilter, input: RasterFilter.Input, layer: PaintLayer, values: [Double]) {
        guard let stack, stack.active == input.layerIndex, stack.activeLayer.image === input.layer.image,
              stack.activeLayer.pdnPixels == input.layer.pdnPixels else { return }
        if filter.category != nil { Self.lastEffect = (filter, values) }
        guard stack.activeLayer.image !== layer.image else { return }
        var updated = stack.activeLayer
        updated.image = layer.image
        updated.pdnPixels = layer.pdnPixels
        commitPaintLayer(updated, actionName: filter.title)
    }
}
