import AppKit

final class RasterFilterPanel: NSPanel, NSTextFieldDelegate {
    private enum Field {
        case numeric(NSSlider, NSTextField)
        case choice(NSPopUpButton)

        @MainActor var value: Double {
            switch self {
            case let .numeric(slider, _): return slider.doubleValue
            case let .choice(popup): return Double(popup.indexOfSelectedItem)
            }
        }

        @MainActor func setValue(_ value: Double) {
            switch self {
            case let .numeric(slider, field):
                slider.doubleValue = value
                field.stringValue = RasterFilterPanel.valueText(value)
            case let .choice(popup):
                popup.selectItem(at: Int(value))
            }
        }
    }

    private static let renderQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "paint.mac.filter-preview"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let filter: RasterFilter
    private let input: RasterFilter.Input
    private let apply = NSButton(title: "Apply", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private var fields: [Field] = []
    private var renderRequest: Operation?
    private var revision = 0
    private(set) var result: PaintLayer?
    var preview: ((PaintLayer?) -> Void)?
    var values: [Double] { fields.map(\.value) }

    init(filter: RasterFilter, input: RasterFilter.Input) {
        self.filter = filter
        self.input = input
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 100 + 34 * filter.controls.count),
                   styleMask: [.titled], backing: .buffered, defer: false)
        title = filter.title
        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        form.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)

        for (index, control) in filter.controls.enumerated() {
            let label = NSTextField(labelWithString: control.title)
            let row: NSStackView
            if let choices = control.choices {
                let popup = NSPopUpButton()
                popup.addItems(withTitles: choices)
                popup.selectItem(at: Int(control.initial))
                popup.target = self
                popup.action = #selector(changeChoice(_:))
                popup.setAccessibilityLabel(control.title)
                fields.append(.choice(popup))
                row = NSStackView(views: [label, popup])
            } else {
                let slider = NSSlider(value: control.initial, minValue: control.range.lowerBound,
                                      maxValue: control.range.upperBound, target: self, action: #selector(change(_:)))
                slider.isContinuous = true
                slider.setAccessibilityLabel(control.title)
                slider.tag = index
                let field = NSTextField(string: Self.valueText(control.initial))
                field.delegate = self
                field.alignment = .right
                field.tag = index
                field.setAccessibilityLabel("\(control.title) value")
                field.widthAnchor.constraint(equalToConstant: 60).isActive = true
                fields.append(.numeric(slider, field))
                row = NSStackView(views: [label, slider, field])
            }
            row.alignment = .centerY
            form.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -32),
                label.widthAnchor.constraint(equalToConstant: 130)
            ])
        }
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetValues(_:)))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeSheet(_:)))
        cancel.keyEquivalent = "\u{1b}"
        apply.target = self
        apply.action = #selector(closeSheet(_:))
        apply.keyEquivalent = "\r"
        apply.isEnabled = false
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [reset, status, cancel, apply])
        form.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -32).isActive = true
        contentView = form
    }

    func updatePreview() {
        revision += 1
        let requestedRevision = revision
        let input = self.input, filter = self.filter, values = self.values
        renderRequest?.cancel()
        result = nil
        status.stringValue = "Rendering…"
        apply.isEnabled = false
        let request = BlockOperation()
        request.addExecutionBlock { [weak self, weak request] in
            let rendered = input.render(filter, values: values, isCancelled: { request?.isCancelled != false })
            guard request?.isCancelled == false else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, revision == requestedRevision else { return }
                result = rendered
                apply.isEnabled = rendered != nil
                status.stringValue = rendered == nil ? "Preview unavailable" : ""
                preview?(rendered)
            }
        }
        renderRequest = request
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
            if !request.isCancelled { Self.renderQueue.addOperation(request) }
        }
    }

    func stopPreview() {
        revision += 1
        renderRequest?.cancel()
        renderRequest = nil
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, fields.indices.contains(field.tag),
              case let .numeric(slider, _) = fields[field.tag],
              let rawValue = Double(field.stringValue), rawValue.isFinite else { return }
        slider.doubleValue = filter.controls[field.tag].snapped(rawValue)
        updatePreview()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, fields.indices.contains(field.tag),
              case let .numeric(slider, _) = fields[field.tag] else { return }
        field.stringValue = Self.valueText(slider.doubleValue)
    }

    @objc private func change(_ slider: NSSlider) {
        guard fields.indices.contains(slider.tag) else { return }
        fields[slider.tag].setValue(filter.controls[slider.tag].snapped(slider.doubleValue))
        updatePreview()
    }

    @objc private func changeChoice(_ sender: NSPopUpButton) { updatePreview() }

    @objc private func resetValues(_ sender: Any?) {
        for (index, control) in filter.controls.enumerated() {
            fields[index].setValue(control.initial)
        }
        updatePreview()
    }

    @objc private func closeSheet(_ sender: NSButton) {
        guard sender !== apply || result != nil else { return }
        sheetParent?.endSheet(self, returnCode: sender === apply ? .OK : .cancel)
    }

    private static func valueText(_ value: Double) -> String { String(format: "%.4g", value) }
}
