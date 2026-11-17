import AppKit

final class ToolOptionsView: NSStackView, NSTextFieldDelegate {
    private weak var canvas: CanvasView?
    private let sampleSource = NSPopUpButton()
    private let sampleSize = NSPopUpButton()
    private let after = NSPopUpButton()
    private let gradientShape = NSPopUpButton()
    private let gradientRepeat = NSPopUpButton()
    private let gradientMode = NSPopUpButton()
    private let gradientBlend = NSPopUpButton()
    private let tolerance = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let toleranceLabel = NSTextField(labelWithString: "Tolerance 50%")
    private let shape = NSPopUpButton()
    private let fill = NSPopUpButton()
    private let curve = NSPopUpButton()
    private let linePattern = NSPopUpButton()
    private let vectorBlend = NSPopUpButton()
    private let cornerRadius = NSPopUpButton()
    private let smoothing = NSButton(checkboxWithTitle: "Antialias", target: nil, action: nil)
    private let text = NSTextField()
    private let font = NSPopUpButton()
    private let fontSize = NSPopUpButton()
    private let textAlignment = NSPopUpButton()
    private let bold = NSButton(checkboxWithTitle: "Bold", target: nil, action: nil)
    private let italic = NSButton(checkboxWithTitle: "Italic", target: nil, action: nil)
    private let sampleSizes = [1, 3, 5, 11, 31, 51]
    private let fontSizes = [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 40, 48, 64, 80, 96, 128]
    private let cornerSizes = [0, 2, 4, 8, 12, 16, 24, 32, 48, 64]
    private let systemFontTitle = "System Font"

    func configure(canvas: CanvasView) {
        self.canvas = canvas
        spacing = 6
        configure(sampleSource, "Color Picker Sampling", FloodSettings.Sampling.allCases.map(\.rawValue))
        configure(sampleSize, "Color Picker Sample Size", sampleSizes.map { "\($0) × \($0)" })
        configure(after, "After Picking", CanvasView.PickerAfter.allCases.map(\.rawValue))
        configure(gradientShape, "Gradient Shape", GradientOptions.Shape.allCases.map(\.rawValue))
        configure(gradientRepeat, "Gradient Repetition", GradientOptions.Repeat.allCases.map(\.rawValue))
        configure(gradientMode, "Gradient Mode", ["Color", "Transparency"])
        configure(gradientBlend, "Gradient Blend Mode", LayerBlendMode.allCases.map(\.title))
        tolerance.target = self
        tolerance.action = #selector(change(_:))
        tolerance.isContinuous = true
        tolerance.setAccessibilityLabel("Recolor tolerance")
        tolerance.widthAnchor.constraint(equalToConstant: 88).isActive = true
        configure(shape, "Shape", DrawingShape.allCases.map(\.rawValue))
        configure(fill, "Shape Drawing Mode", DrawingFill.allCases.map(\.rawValue))
        configure(curve, "Line Geometry", ["Straight", "Bézier"])
        configure(linePattern, "Line Pattern", DrawingLinePattern.allCases.map(\.rawValue))
        configure(vectorBlend, "Drawing Blend Mode", LayerBlendMode.allCases.map(\.title))
        configure(cornerRadius, "Corner Radius", cornerSizes.map { "Corner \($0) px" })
        cornerRadius.selectItem(withTitle: "Corner 12 px")
        configure(font, "Font", [systemFontTitle] + NSFontManager.shared.availableFonts.filter { !$0.hasPrefix(".") }.sorted())
        configure(fontSize, "Font Size", fontSizes.map { "\($0) px" })
        fontSize.selectItem(withTitle: "16 px")
        configure(textAlignment, "Text Alignment", TextAlignment.allCases.map(\.rawValue))
        for button in [smoothing, bold, italic] {
            button.target = self
            button.action = #selector(change(_:))
        }
        smoothing.state = .on
        text.delegate = self
        text.target = self
        text.action = #selector(finishText(_:))
        text.placeholderString = "Text"
        text.setAccessibilityLabel("Text to draw")
        text.widthAnchor.constraint(equalToConstant: 128).isActive = true
        font.widthAnchor.constraint(lessThanOrEqualToConstant: 140).isActive = true
        for view in [sampleSource, sampleSize, after, gradientShape, gradientRepeat, gradientMode, gradientBlend,
                     toleranceLabel, tolerance, shape, fill, cornerRadius, curve, linePattern, vectorBlend,
                     smoothing, text, font, fontSize, textAlignment, bold, italic] as [NSView] {
            addArrangedSubview(view)
        }
        canvas.editText = { [weak self] in
            guard let self else { return }
            text.stringValue = ""
            update()
            text.selectText(nil)
        }
        update()
    }

    func update() {
        guard let canvas else { return }
        let tool = canvas.tool
        sampleSource.isHidden = tool != .colorPicker
        sampleSize.isHidden = tool != .colorPicker
        after.isHidden = tool != .colorPicker
        for option in [gradientShape, gradientRepeat, gradientMode, gradientBlend] { option.isHidden = tool != .gradient }
        gradientBlend.isEnabled = !canvas.gradientOptions.transparency
        toleranceLabel.isHidden = tool != .recolor
        tolerance.isHidden = tool != .recolor
        shape.isHidden = tool != .shapes
        shape.selectItem(withTitle: canvas.drawingStyle.shape.rawValue)
        fill.isHidden = tool != .shapes
        cornerRadius.isHidden = tool != .shapes || canvas.drawingStyle.shape != .roundedRectangle
        curve.isHidden = tool != .lineCurve
        curve.selectItem(at: canvas.drawingStyle.curve ? 1 : 0)
        linePattern.isHidden = tool != .lineCurve && tool != .shapes
        vectorBlend.isHidden = !tool.usesVectorDrawing
        smoothing.isHidden = !tool.usesVectorDrawing
        for view in [text, font, fontSize, textAlignment, bold, italic] as [NSView] { view.isHidden = tool != .text }
        text.isEnabled = canvas.hasPendingDrawing
        isHidden = tool != .colorPicker && tool != .recolor && tool != .gradient && !tool.usesVectorDrawing
    }

    func controlTextDidChange(_ obj: Notification) {
        canvas?.drawingStyle.text = text.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
            commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishText(nil)
            return true
        }
        return false
    }

    @objc private func finishText(_ sender: Any?) {
        guard let canvas else { return }
        canvas.finishLiveEdit()
        window?.makeFirstResponder(canvas)
    }

    private func configure(_ menu: NSPopUpButton, _ label: String, _ titles: [String]) {
        menu.addItems(withTitles: titles)
        menu.setAccessibilityLabel(label)
        menu.toolTip = label
        menu.target = self
        menu.action = #selector(change(_:))
    }

    @objc private func change(_ sender: NSControl) {
        guard let canvas else { return }
        if sender === sampleSource {
            canvas.pickerSampling = FloodSettings.Sampling.allCases[sampleSource.indexOfSelectedItem]
        } else if sender === sampleSize {
            canvas.pickerSampleSize = sampleSizes[sampleSize.indexOfSelectedItem]
        } else if sender === after {
            canvas.pickerAfter = CanvasView.PickerAfter.allCases[after.indexOfSelectedItem]
        } else if sender === tolerance {
            canvas.recolorTolerance = tolerance.integerValue
            toleranceLabel.stringValue = "Tolerance \(tolerance.integerValue)%"
        } else if [gradientShape, gradientRepeat, gradientMode, gradientBlend].contains(where: { sender === $0 }) {
            canvas.gradientOptions = GradientOptions(
                shape: GradientOptions.Shape.allCases[gradientShape.indexOfSelectedItem],
                repeats: GradientOptions.Repeat.allCases[gradientRepeat.indexOfSelectedItem],
                transparency: gradientMode.indexOfSelectedItem == 1,
                blendMode: LayerBlendMode.allCases[gradientBlend.indexOfSelectedItem]
            )
            update()
        } else {
            var style = canvas.drawingStyle
            style.shape = DrawingShape.allCases[shape.indexOfSelectedItem]
            style.fill = DrawingFill.allCases[fill.indexOfSelectedItem]
            style.curve = curve.indexOfSelectedItem == 1
            style.linePattern = DrawingLinePattern.allCases[linePattern.indexOfSelectedItem]
            style.blendMode = LayerBlendMode.allCases[vectorBlend.indexOfSelectedItem]
            style.cornerRadius = CGFloat(cornerSizes[cornerRadius.indexOfSelectedItem])
            style.antialiased = smoothing.state == .on
            style.fontSize = CGFloat(fontSizes[fontSize.indexOfSelectedItem])
            style.fontName = font.titleOfSelectedItem == systemFontTitle
                ? NSFont.systemFont(ofSize: style.fontSize).fontName : font.titleOfSelectedItem ?? ""
            style.alignment = TextAlignment.allCases[textAlignment.indexOfSelectedItem]
            style.bold = bold.state == .on
            style.italic = italic.state == .on
            canvas.drawingStyle = style
            update()
        }
    }
}
