import AppKit

final class ToolOptionsView: NSStackView, NSTextFieldDelegate {
    private weak var canvas: CanvasView?
    private let rectangleSizing = NSPopUpButton()
    private let rectangleWidth = NSTextField()
    private let rectangleHeight = NSTextField()
    private let rectangleUnit = NSPopUpButton()
    private let moveSampling = NSPopUpButton()
    private let brushAntialias = NSButton(checkboxWithTitle: "Antialias", target: nil, action: nil)
    private let hardnessLabel = NSTextField(labelWithString: "Hardness %")
    private let hardness = NSTextField()
    private let spacingLabel = NSTextField(labelWithString: "Spacing %")
    private let brushSpacing = NSTextField()
    private let brushSmoothing = NSButton(checkboxWithTitle: "Smooth Path", target: nil, action: nil)
    private let brushPressure = NSButton(checkboxWithTitle: "Pen Pressure", target: nil, action: nil)
    private let brushPattern = NSPopUpButton()
    private let brushBlend = NSPopUpButton()
    private let brushClipping = NSPopUpButton()
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
        configure(rectangleSizing, "Rectangle Selection Sizing", RectangleSelection.Sizing.allCases.map(\.rawValue))
        configure(rectangleUnit, "Rectangle Selection Units", RectangleSelection.Unit.allCases.map(\.rawValue))
        configure(moveSampling, "Move Pixels Resampling", MoveResampler.Mode.allCases.map(\.rawValue))
        for (field, label) in [(rectangleWidth, "Selection Width"), (rectangleHeight, "Selection Height")] {
            field.delegate = self
            field.alignment = .right
            field.placeholderString = label
            field.toolTip = label
            field.setAccessibilityLabel(label)
            field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        }
        refreshRectangleDimensions()
        configure(sampleSource, "Color Picker Sampling", FloodSettings.Sampling.allCases.map(\.rawValue))
        configure(sampleSize, "Color Picker Sample Size", sampleSizes.map { "\($0) × \($0)" })
        configure(after, "After Picking", CanvasView.PickerAfter.allCases.map(\.rawValue))
        configure(gradientShape, "Gradient Shape", GradientOptions.Shape.allCases.map(\.rawValue))
        configure(gradientRepeat, "Gradient Repetition", GradientOptions.Repeat.allCases.map(\.rawValue))
        configure(gradientMode, "Gradient Mode", ["Color", "Transparency"])
        configure(gradientBlend, "Gradient Blend Mode", LayerBlendMode.allCases.map(\.title))
        configure(brushPattern, "Brush Fill", BrushOptions.Pattern.allCases.map(\.rawValue))
        configure(brushBlend, "Brush Blend Mode", BrushOptions.Blend.choices.map(\.title))
        configure(brushClipping, "Brush Selection Clipping", ["Smooth Selection", "Pixelated Selection"])
        configureBrushPercent(hardness, label: "Brush hardness percent", range: 0...100)
        configureBrushPercent(brushSpacing, label: "Brush spacing percent", range: 1...300)
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
        for button in [brushAntialias, brushSmoothing, brushPressure, smoothing, bold, italic] {
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
        for view in [rectangleSizing, rectangleWidth, rectangleHeight, rectangleUnit, moveSampling, brushPressure,
                     hardnessLabel, hardness, spacingLabel, brushSpacing, brushSmoothing,
                     brushPattern, brushAntialias, brushBlend, brushClipping,
                     sampleSource, sampleSize, after, gradientShape, gradientRepeat, gradientMode, gradientBlend,
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
        let tip = tool.usesBrushTip
        let options = canvas.brushOptions
        for control in [hardnessLabel, hardness, spacingLabel, brushSpacing, brushSmoothing, brushAntialias] as [NSView] {
            control.isHidden = !tip
        }
        hardness.integerValue = options.hardness
        hardness.isEnabled = options.antialiased
        hardnessLabel.textColor = options.antialiased ? .labelColor : .disabledControlTextColor
        brushSpacing.integerValue = options.spacing
        brushPressure.isHidden = !tip || !canvas.hasSeenTablet
        brushSmoothing.state = options.smoothed ? .on : .off
        brushPressure.state = options.pressureSensitive ? .on : .off
        brushAntialias.state = options.antialiased ? .on : .off
        brushPattern.isHidden = tool != .brush && tool != .eraser
        brushPattern.selectItem(withTitle: options.pattern.rawValue)
        brushBlend.isHidden = tool != .brush && tool != .pencil && tool != .cloneStamp
        brushBlend.selectItem(withTitle: options.blend.title)
        brushClipping.isHidden = !tool.usesRasterDrawing
        brushClipping.selectItem(at: options.antialiasedSelection ? 0 : 1)
        rectangleSizing.isHidden = tool != .rectangleSelect
        let rectangleDimensionsVisible = tool == .rectangleSelect && canvas.rectangleSelection.sizing != .anySize
        rectangleWidth.isHidden = !rectangleDimensionsVisible
        rectangleHeight.isHidden = !rectangleDimensionsVisible
        rectangleUnit.isHidden = tool != .rectangleSelect || canvas.rectangleSelection.sizing != .fixedSize
        moveSampling.isHidden = tool != .moveSelectedPixels
        moveSampling.selectItem(withTitle: canvas.moveSampling.rawValue)
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
        isHidden = !tool.usesRasterDrawing && tool != .colorPicker && tool != .gradient &&
            tool != .rectangleSelect && tool != .moveSelectedPixels && !tool.usesVectorDrawing
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === text {
            canvas?.drawingStyle.text = text.stringValue
        } else if field === rectangleWidth || field === rectangleHeight {
            updateRectangleDimension(field)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === rectangleWidth || field === rectangleHeight else { return }
        updateRectangleDimension(field)
        refreshRectangleDimensions()
    }

    private func updateRectangleDimension(_ field: NSTextField) {
        guard let canvas, let value = (try? Double(field.stringValue, format: .number)) ?? Double(field.stringValue),
              value.isFinite, value > 0 else { return }
        let isRatio = canvas.rectangleSelection.sizing == .fixedRatio
        var dimensions = isRatio ? canvas.rectangleSelection.ratio : canvas.rectangleSelection.size
        if field === rectangleWidth { dimensions.width = value } else { dimensions.height = value }
        if isRatio { canvas.rectangleSelection.ratio = dimensions } else { canvas.rectangleSelection.size = dimensions }
    }

    private func refreshRectangleDimensions() {
        guard let options = canvas?.rectangleSelection else { return }
        let dimensions = options.sizing == .fixedRatio ? options.ratio : options.size
        let format = FloatingPointFormatStyle<Double>.number.grouping(.never).precision(.fractionLength(0...8))
        rectangleWidth.stringValue = Double(dimensions.width).formatted(format)
        rectangleHeight.stringValue = Double(dimensions.height).formatted(format)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
            commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if control === text { finishText(nil) }
            else { window?.makeFirstResponder(canvas) }
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

    private func configureBrushPercent(_ field: NSTextField, label: String, range: ClosedRange<Int>) {
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: range.lowerBound)
        formatter.maximum = NSNumber(value: range.upperBound)
        field.formatter = formatter
        field.alignment = .right
        field.setAccessibilityLabel(label)
        field.toolTip = label
        field.widthAnchor.constraint(equalToConstant: 45).isActive = true
        field.target = self
        field.action = #selector(change(_:))
    }

    @objc private func change(_ sender: NSControl) {
        guard let canvas else { return }
        if sender === brushAntialias {
            canvas.brushOptions.antialiased = brushAntialias.state == .on
            update()
        } else if sender === hardness || sender === brushSpacing {
            canvas.brushOptions.hardness = min(100, max(0, hardness.integerValue))
            canvas.brushOptions.spacing = min(300, max(1, brushSpacing.integerValue))
            update()
            window?.makeFirstResponder(canvas)
        } else if sender === brushPressure {
            canvas.brushOptions.pressureSensitive = brushPressure.state == .on
        } else if sender === brushSmoothing {
            canvas.brushOptions.smoothed = brushSmoothing.state == .on
        } else if sender === brushPattern {
            canvas.brushOptions.pattern = BrushOptions.Pattern.allCases[brushPattern.indexOfSelectedItem]
        } else if sender === brushBlend {
            canvas.brushOptions.blend = BrushOptions.Blend.choices[brushBlend.indexOfSelectedItem]
        } else if sender === brushClipping {
            canvas.brushOptions.antialiasedSelection = brushClipping.indexOfSelectedItem == 0
        } else if sender === rectangleSizing {
            canvas.rectangleSelection.sizing = RectangleSelection.Sizing.allCases[rectangleSizing.indexOfSelectedItem]
            refreshRectangleDimensions()
            update()
            // The options row is horizontally scrollable and must remeasure when fields appear.
            canvas.selectionDidChange?()
        } else if sender === rectangleUnit {
            canvas.rectangleSelection.changeUnit(to: RectangleSelection.Unit.allCases[rectangleUnit.indexOfSelectedItem],
                                                 resolution: canvas.imageResolution)
            refreshRectangleDimensions()
        } else if sender === moveSampling {
            canvas.setMoveSampling(MoveResampler.Mode.allCases[moveSampling.indexOfSelectedItem])
            update()
            window?.makeFirstResponder(canvas)
        } else if sender === sampleSource {
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
