import AppKit

final class LayerPropertiesPanel: NSPanel, NSTextFieldDelegate {
    private let original: PaintLayer
    private let nameField = NSTextField()
    private let opacityField = NSTextField()
    private let opacitySlider = NSSlider()
    private let opacityStepper = NSStepper()
    private let blendMenu = NSPopUpButton()
    private let visibility = NSButton(checkboxWithTitle: "Visible", target: nil, action: nil)
    var preview: ((PaintLayer) -> Void)?

    var editedLayer: PaintLayer {
        var layer = original
        layer.name = nameField.stringValue
        layer.opacity = UInt8(clamping: opacitySlider.integerValue)
        layer.blendMode = LayerBlendMode.allCases[blendMenu.indexOfSelectedItem]
        layer.isVisible = visibility.state == .on
        return layer
    }

    init(layer: PaintLayer) {
        original = layer
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 234),
                   styleMask: [.titled], backing: .buffered, defer: false)
        title = "Layer Properties"
        nameField.stringValue = layer.name
        nameField.setAccessibilityLabel("Name")
        opacityField.integerValue = Int(layer.opacity)
        opacityField.alignment = .right
        opacityField.delegate = self
        opacityField.setAccessibilityLabel("Opacity value")
        opacitySlider.maxValue = 255
        opacitySlider.integerValue = Int(layer.opacity)
        opacitySlider.isContinuous = true
        opacitySlider.setAccessibilityLabel("Opacity")
        opacityStepper.maxValue = 255
        opacityStepper.integerValue = Int(layer.opacity)
        opacityStepper.valueWraps = false
        opacityStepper.setAccessibilityLabel("Adjust opacity")
        blendMenu.addItems(withTitles: LayerBlendMode.allCases.map(\.title))
        blendMenu.selectItem(at: layer.blendMode.rawValue)
        blendMenu.setAccessibilityLabel("Blend Mode")
        visibility.state = layer.isVisible ? .on : .off
        for control in [opacitySlider, opacityStepper, blendMenu, visibility] as [NSControl] {
            control.target = self
            control.action = #selector(updatePreview(_:))
        }

        let opacity = NSStackView(views: [opacitySlider, opacityField, opacityStepper])
        opacity.spacing = 4
        let blending = NSStackView(views: [NSTextField(labelWithString: "Blend Mode:"), blendMenu])
        let ok = NSButton(title: "OK", target: self, action: #selector(finish(_:)))
        ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(finish(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancel, ok])
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let form = NSStackView(views: [heading, NSTextField(labelWithString: "Name"), nameField,
                                      NSTextField(labelWithString: "Opacity"), opacity, blending, visibility, buttons])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 7
        form.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        contentView = form
        NSLayoutConstraint.activate([
            nameField.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -32),
            opacity.widthAnchor.constraint(equalTo: nameField.widthAnchor),
            opacityField.widthAnchor.constraint(equalToConstant: 42),
            buttons.widthAnchor.constraint(equalTo: nameField.widthAnchor),
            ok.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 72)
        ])
        initialFirstResponder = nameField
        let controls = [nameField, opacityField, opacitySlider, opacityStepper, blendMenu, visibility, cancel, ok] as [NSView]
        for (current, next) in zip(controls, controls.dropFirst() + [nameField]) { current.nextKeyView = next }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let editor = opacityField.currentEditor(), let value = Int(editor.string) else { return }
        setOpacity(value, updateField: false)
        preview?(editedLayer)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        setOpacity(Int(opacityField.stringValue) ?? opacitySlider.integerValue)
        preview?(editedLayer)
    }

    @objc private func updatePreview(_ sender: NSControl) {
        if sender === opacitySlider || sender === opacityStepper {
            setOpacity(sender.integerValue)
        }
        preview?(editedLayer)
    }

    private func setOpacity(_ value: Int, updateField: Bool = true) {
        let clamped = Int(UInt8(clamping: value))
        opacitySlider.integerValue = clamped
        opacityStepper.integerValue = clamped
        if updateField { opacityField.integerValue = clamped }
    }

    @objc private func finish(_ sender: NSButton) {
        let response: NSApplication.ModalResponse = sender.keyEquivalent == "\r" ? .OK : .cancel
        if response == .OK {
            makeFirstResponder(nil)
            setOpacity(Int(opacityField.stringValue) ?? opacitySlider.integerValue)
        }
        sheetParent?.endSheet(self, returnCode: response)
    }
}
