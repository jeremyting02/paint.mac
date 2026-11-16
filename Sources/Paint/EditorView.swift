import AppKit

final class EditorView: NSView {
    let canvas: CanvasView
    private weak var document: PaintDocument?
    private let scrollView = NSScrollView()
    private let status = NSTextField(labelWithString: "")
    private let brush = EditorView.icon("paintbrush", label: "Paintbrush")
    private let eraser = EditorView.icon("eraser", label: "Eraser")
    private let crop = EditorView.icon("crop", label: "Rectangle Crop")
    private let applyCrop = NSButton(title: "Crop", target: nil, action: nil)
    private let undo = EditorView.icon("arrow.uturn.backward", label: "Undo")
    private let redo = EditorView.icon("arrow.uturn.forward", label: "Redo")
    private let color = NSColorWell()
    private let swatchColors: [(String, NSColor)] = [("Black", .black), ("Red", .systemRed), ("Blue", .systemBlue)]

    init(document: PaintDocument) {
        self.document = document
        canvas = CanvasView(document: document)
        super.init(frame: NSRect(x: 0, y: 0, width: 880, height: 640))

        for button in [brush, eraser, crop] {
            button.setButtonType(.pushOnPushOff)
            button.target = self
            button.action = #selector(selectTool(_:))
        }
        selectTool(brush)
        undo.target = document
        undo.action = #selector(PaintDocument.undoStroke(_:))
        redo.target = document
        redo.action = #selector(PaintDocument.redoStroke(_:))
        updateHistory(document.undoManager)
        applyCrop.target = self
        applyCrop.action = #selector(cropSelection(_:))
        canvas.selectionDidChange = { [weak self] in self?.updateStatus() }

        scrollView.documentView = canvas
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        let zoom = NSSegmentedControl(labels: ["Fit", "100%"], trackingMode: .selectOne,
                                      target: self, action: #selector(changeZoom(_:)))
        zoom.selectedSegment = 0
        zoom.setAccessibilityLabel("Zoom")
        zoom.setToolTip("Fit to window", forSegment: 0)
        zoom.setToolTip("Actual pixels", forSegment: 1)

        let size = NSPopUpButton()
        for diameter in [1, 2, 4, 8, 12, 16, 24, 32, 48, 64, 96, 128] {
            size.addItem(withTitle: "\(diameter) px")
            size.lastItem?.tag = diameter
        }
        size.selectItem(withTitle: "12 px")
        size.setAccessibilityLabel("Brush size")
        size.target = self
        size.action = #selector(changeSize(_:))

        color.colorWellStyle = .minimal
        color.color = .black
        color.setAccessibilityLabel("Paint color")
        color.toolTip = "Paint color"
        color.target = self
        color.action = #selector(changeColor(_:))

        let toolbar = NSStackView(views: [undo, redo, NSTextField(labelWithString: "Size"), size, applyCrop])
        toolbar.spacing = 8
        let tools = NSStackView(views: [Self.caption("Tools"), brush, eraser, crop])
        tools.orientation = .vertical
        tools.spacing = 6
        let swatches = NSStackView(views: swatchColors.enumerated().map { index, swatch in
            let button = Self.icon("square.fill", label: swatch.0)
            button.isBordered = false
            button.contentTintColor = swatch.1
            button.tag = index
            button.target = self
            button.action = #selector(pickSwatch(_:))
            return button
        })
        swatches.spacing = 3
        let colors = NSStackView(views: [Self.caption("Color"), color, swatches])
        colors.orientation = .vertical
        colors.spacing = 6
        status.textColor = .secondaryLabelColor
        status.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let footer = NSStackView(views: [status, zoom])
        footer.spacing = 8
        updateStatus()

        for view in [toolbar, tools, colors, scrollView, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 60),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -5),
            tools.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 8),
            tools.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            colors.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -8),
            colors.centerXAnchor.constraint(equalTo: tools.centerXAnchor),
            color.widthAnchor.constraint(equalToConstant: 36),
            color.heightAnchor.constraint(equalToConstant: 26),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        canvas.fitViewport()
    }

    func refreshImage() {
        canvas.clearSelection()
        canvas.fitViewport()
        updateStatus()
    }

    private func updateStatus() {
        applyCrop.isEnabled = canvas.cropRect != nil
        let dimensions = document?.image.map { "\($0.width) × \($0.height) px" } ?? ""
        if let rect = canvas.cropRect {
            status.stringValue = "\(Int(rect.width)) × \(Int(rect.height)) at \(Int(rect.minX)), \(Int(rect.minY))  ·  \(dimensions)"
        } else {
            status.stringValue = dimensions
        }
    }

    func updateHistory(_ history: UndoManager?) {
        undo.isEnabled = history?.canUndo == true
        redo.isEnabled = history?.canRedo == true
    }

    @objc private func selectTool(_ sender: NSButton) {
        for (button, tool) in [(brush, CanvasView.Tool.brush), (eraser, .eraser), (crop, .crop)] {
            let selected = button === sender
            button.state = selected ? .on : .off
            button.contentTintColor = selected ? .controlAccentColor : .labelColor
            if selected { canvas.tool = tool }
        }
    }

    @objc private func cropSelection(_ sender: NSButton) {
        canvas.cropSelection()
    }

    @objc private func changeZoom(_ sender: NSSegmentedControl) {
        canvas.fitsToWindow = sender.selectedSegment == 0
        canvas.fitViewport()
        let clip = scrollView.contentView
        clip.scroll(to: CGPoint(x: 0, y: max(0, canvas.bounds.height - clip.bounds.height)))
        scrollView.reflectScrolledClipView(clip)
        scrollView.flashScrollers()
    }

    @objc private func changeSize(_ sender: NSPopUpButton) {
        if let pixels = sender.selectedItem?.tag {
            canvas.brushSize = CGFloat(pixels)
        }
    }

    @objc private func changeColor(_ sender: NSColorWell) {
        canvas.brushColor = sender.color
    }

    @objc private func pickSwatch(_ sender: NSButton) {
        color.color = swatchColors[sender.tag].1
        changeColor(color)
    }

    private static func caption(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    private static func icon(_ symbol: String, label: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
        button.bezelStyle = .texturedRounded
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }
}
