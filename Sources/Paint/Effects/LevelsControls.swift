import AppKit

final class LevelsControls: NSStackView, TonalAdjustmentControls, NSTextFieldDelegate {
    private struct Row {
        let slider: NSSlider
        let field: NSTextField
        let swatch: NSColorWell
    }

    private var settings = LevelSettings()
    private var channels: [NSButton] = []
    private var rows: [LevelSettings.Parameter: Row] = [:]
    private let inputHistogram = LevelHistogramView(label: "Input histogram")
    private let outputHistogram = LevelHistogramView(label: "Output histogram")
    private let auto = NSButton(title: "Auto", target: nil, action: nil)
    var view: NSView { self }
    var didChange: (() -> Void)?

    init(input: RasterFilter.Input) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 12

        let inputColumn = column(title: "Input", histogram: inputHistogram, parameters: [.inputWhite, .inputBlack])
        let outputColumn = column(title: "Output", histogram: outputHistogram, parameters: [.outputWhite, .gamma, .outputBlack])
        let histograms = NSStackView(views: [inputColumn, outputColumn])
        histograms.alignment = .top
        histograms.spacing = 14
        addArrangedSubview(histograms)
        histograms.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        inputColumn.widthAnchor.constraint(equalTo: outputColumn.widthAnchor).isActive = true

        for channel in RGBChannel.allCases {
            let enabled = NSButton(checkboxWithTitle: channel.title, target: self, action: #selector(selectChannels))
            enabled.state = .on
            enabled.tag = channel.rawValue
            channels.append(enabled)
        }
        auto.target = self
        auto.action = #selector(applyAuto)
        auto.isEnabled = false
        let channelRow = NSStackView(views: channels + [auto])
        channelRow.spacing = 10
        addArrangedSubview(channelRow)
        refresh()

        let pixels = input.pixels, mask = input.mask
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let histogram = ChannelHistogram(pixels: pixels, mask: mask)
            DispatchQueue.main.async { [weak self] in
                self?.inputHistogram.histogram = histogram
                self?.refresh()
            }
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func renderFilter() -> RasterFilter { settings.filter() }

    func reset() {
        settings = LevelSettings()
        for button in channels { button.state = .on }
        refresh()
    }

    private var selected: Set<RGBChannel> {
        Set(channels.compactMap { $0.state == .on ? RGBChannel(rawValue: $0.tag) : nil })
    }

    private func column(title: String, histogram: LevelHistogramView,
                        parameters: [LevelSettings.Parameter]) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let column = NSStackView(views: [heading, histogram])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 7
        histogram.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        histogram.heightAnchor.constraint(equalToConstant: 120).isActive = true
        for parameter in parameters {
            let name = "\(title) \(parameter.title.lowercased())"
            let title = NSTextField(labelWithString: parameter.title)
            let slider = NSSlider(value: 0, minValue: parameter.range.lowerBound, maxValue: parameter.range.upperBound,
                                  target: self, action: #selector(changeSlider(_:)))
            slider.isContinuous = true
            slider.tag = parameter.rawValue
            slider.setAccessibilityLabel(name)
            let field = NSTextField()
            field.alignment = .right
            field.delegate = self
            field.tag = parameter.rawValue
            field.setAccessibilityLabel("\(name) value")
            let swatch = NSColorWell()
            swatch.colorWellStyle = .minimal
            swatch.tag = parameter.rawValue
            swatch.target = self
            swatch.action = #selector(changeSwatch(_:))
            swatch.setAccessibilityLabel(parameter == .gamma ? "Output gray point color" : "\(name) color")
            rows[parameter] = Row(slider: slider, field: field, swatch: swatch)
            let row = NSStackView(views: [title, slider, field, swatch])
            row.spacing = 5
            row.alignment = .centerY
            column.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: column.widthAnchor),
                title.widthAnchor.constraint(equalToConstant: 71),
                field.widthAnchor.constraint(equalToConstant: 47),
                swatch.widthAnchor.constraint(equalToConstant: 28)
            ])
        }
        return column
    }

    private func refresh(excluding currentField: NSTextField? = nil) {
        let selected = self.selected
        for (parameter, row) in rows {
            let average = selected.isEmpty ? 0 : selected.reduce(0) { $0 + settings[$1][parameter] } / Double(selected.count)
            row.slider.doubleValue = average
            row.slider.isEnabled = !selected.isEmpty
            row.field.isEnabled = !selected.isEmpty
            row.swatch.isEnabled = !selected.isEmpty
            if currentField !== row.field {
                row.field.stringValue = selected.isEmpty ? "" : parameter == .gamma
                    ? String(format: "%.2f", average) : String(Int(average.rounded()))
            }
            let colors = RGBChannel.allCases.map { channel -> Double in
                let range = settings[channel]
                if parameter == .gamma {
                    return (range.outputBlack + pow(0.5, 1 / range.gamma) * (range.outputWhite - range.outputBlack)) / 255
                }
                return range[parameter] / 255
            }
            row.swatch.color = NSColor(srgbRed: colors[0], green: colors[1], blue: colors[2], alpha: 1)
        }
        auto.isEnabled = !selected.isEmpty && inputHistogram.histogram != nil
        inputHistogram.highlighted = selected
        outputHistogram.highlighted = selected
        outputHistogram.histogram = inputHistogram.histogram?.remapped(by: settings.tables)
    }

    @objc private func selectChannels() { refresh() }

    @objc private func applyAuto() {
        guard let histogram = inputHistogram.histogram else { return }
        settings.auto(using: histogram, channels: selected)
        refresh()
        didChange?()
    }

    @objc private func changeSlider(_ sender: NSSlider) {
        guard let parameter = LevelSettings.Parameter(rawValue: sender.tag) else { return }
        settings.set(parameter, to: sender.doubleValue, channels: selected)
        refresh()
        didChange?()
    }

    @objc private func changeSwatch(_ sender: NSColorWell) {
        guard let parameter = LevelSettings.Parameter(rawValue: sender.tag),
              let color = sender.color.usingColorSpace(.sRGB) else { return }
        let values = [color.redComponent, color.greenComponent, color.blueComponent].map { Double($0) * 255 }
        if parameter == .gamma {
            for channel in selected {
                let range = settings[channel]
                guard range.outputBlack < range.outputWhite else { continue }
                let fraction = (values[channel.rawValue] - range.outputBlack) / (range.outputWhite - range.outputBlack)
                let gamma = log(0.5) / log(min(0.9999, max(0.0001, fraction)))
                settings.set(.gamma, to: gamma, channels: [channel])
            }
        } else {
            settings.set(parameter, to: values, channels: selected)
        }
        refresh()
        didChange?()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let parameter = LevelSettings.Parameter(rawValue: field.tag),
              let raw = Double(field.stringValue), raw.isFinite else { return }
        settings.set(parameter, to: raw, channels: selected)
        refresh(excluding: field)
        didChange?()
    }

    func controlTextDidEndEditing(_ notification: Notification) { refresh() }
}

private final class LevelHistogramView: NSView {
    var histogram: ChannelHistogram? { didSet { needsDisplay = true } }
    var highlighted = Set(RGBChannel.allCases) { didSet { needsDisplay = true } }

    init(label: String) {
        super.init(frame: .zero)
        setAccessibilityRole(.image)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let plot = bounds.insetBy(dx: 0.5, dy: 0.5)
        NSColor.controlBackgroundColor.setFill()
        plot.fill()
        let border = NSBezierPath(rect: plot)
        border.lineWidth = 1
        NSColor.gridColor.setStroke()
        border.stroke()
        guard let histogram, let peak = histogram.bins.compactMap({ $0.max() }).max(), peak > 0 else { return }

        for channel in RGBChannel.allCases {
            let bins = histogram[channel]
            let path = NSBezierPath()
            path.move(to: CGPoint(x: plot.minX, y: plot.minY))
            for (index, count) in bins.enumerated() {
                path.line(to: CGPoint(x: plot.minX + CGFloat(index) * plot.width / 255,
                                      y: plot.minY + plot.height * CGFloat(count) / CGFloat(peak)))
            }
            path.line(to: CGPoint(x: plot.maxX, y: plot.minY))
            path.close()
            channel.graphColor.withAlphaComponent(highlighted.contains(channel) ? 0.37 : 0.12).setFill()
            path.fill()
        }
    }
}
