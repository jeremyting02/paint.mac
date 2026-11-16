import AppKit

final class EditorView: NSView {
    let canvas: CanvasView
    private let brush = EditorView.icon("paintbrush", label: "Paintbrush")
    private let eraser = EditorView.icon("eraser", label: "Eraser")
    private let undo = EditorView.icon("arrow.uturn.backward", label: "Undo")
    private let redo = EditorView.icon("arrow.uturn.forward", label: "Redo")
    private let color = NSColorWell()
    private let swatchColors: [(String, NSColor)] = [("Black", .black), ("Red", .systemRed), ("Blue", .systemBlue)]

    init(document: PaintDocument) {
        canvas = CanvasView(document: document)
        super.init(frame: NSRect(x: 0, y: 0, width: 880, height: 640))

        for button in [brush, eraser] {
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

        let toolbar = NSStackView(views: [undo, redo, NSTextField(labelWithString: "Size"), size])
        toolbar.spacing = 8
        let tools = NSStackView(views: [Self.caption("Tools"), brush, eraser])
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
        let dimensions = document.image.map { "\($0.width) × \($0.height) px" } ?? ""
        let status = NSTextField(labelWithString: dimensions)
        status.textColor = .secondaryLabelColor
        status.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

        for view in [toolbar, tools, colors, canvas, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 60),
            canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -5),
            tools.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 8),
            tools.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            colors.bottomAnchor.constraint(equalTo: canvas.bottomAnchor, constant: -8),
            colors.centerXAnchor.constraint(equalTo: tools.centerXAnchor),
            color.widthAnchor.constraint(equalToConstant: 36),
            color.heightAnchor.constraint(equalToConstant: 26),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func updateHistory(_ history: UndoManager?) {
        undo.isEnabled = history?.canUndo == true
        redo.isEnabled = history?.canRedo == true
    }

    @objc private func selectTool(_ sender: NSButton) {
        canvas.isErasing = sender === eraser
        brush.state = canvas.isErasing ? .off : .on
        eraser.state = canvas.isErasing ? .on : .off
        brush.contentTintColor = canvas.isErasing ? .labelColor : .controlAccentColor
        eraser.contentTintColor = canvas.isErasing ? .controlAccentColor : .labelColor
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
