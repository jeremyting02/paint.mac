import AppKit

final class EditorView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let canvas: CanvasView
    private weak var document: PaintDocument?
    private let scrollView = NSScrollView()
    private let status = NSTextField(labelWithString: "")
    private let zoom = NSSegmentedControl(labels: ["Fit", "100%"], trackingMode: .selectOne,
                                          target: nil, action: nil)
    private let zoomLevel = NSTextField(labelWithString: "")
    private let brush = EditorView.icon("paintbrush", label: "Paintbrush")
    private let eraser = EditorView.icon("eraser", label: "Eraser")
    private let rectangleSelect = EditorView.icon("rectangle.dashed", label: "Rectangle Select")
    private let ellipseSelect = EditorView.icon("circle.dashed", label: "Ellipse Select")
    private let moveSelectedPixels = EditorView.icon("arrow.up.and.down.and.arrow.left.and.right", label: "Move Selected Pixels")
    private let moveSelection = EditorView.icon("rectangle.dashed.and.paperclip", label: "Move Selection")
    private let applyCrop = EditorView.icon("crop", label: "Crop to Selection")
    private let finishMove = NSButton(title: "Finish", target: nil, action: nil)
    private let undo = EditorView.icon("arrow.uturn.backward", label: "Undo")
    private let redo = EditorView.icon("arrow.uturn.forward", label: "Redo")
    private let color = NSColorWell()
    private let toolButtons = NSStackView()
    private let colorControls = NSStackView()
    private let historyScroll = NSScrollView()
    private let historyTable = NSTableView()
    private let historyUndo = EditorView.icon("arrow.uturn.backward", label: "Undo")
    private let historyRedo = EditorView.icon("arrow.uturn.forward", label: "Redo")
    private var updatingHistory = false
    private let layersView: LayersView
    private var panels: UtilityPanels?
    private let swatchColors: [(String, NSColor)] = [("Black", .black), ("Red", .systemRed), ("Blue", .systemBlue)]

    init(document: PaintDocument) {
        self.document = document
        canvas = CanvasView(document: document)
        layersView = LayersView(document: document)
        super.init(frame: NSRect(x: 0, y: 0, width: 880, height: 640))

        for button in [brush, eraser, rectangleSelect, ellipseSelect, moveSelectedPixels, moveSelection] {
            button.setButtonType(.pushOnPushOff)
            button.target = self
            button.action = #selector(selectTool(_:))
        }
        selectTool(brush)
        for button in [undo, historyUndo] {
            button.target = document
            button.action = #selector(PaintDocument.undoStroke(_:))
        }
        for button in [redo, historyRedo] {
            button.target = document
            button.action = #selector(PaintDocument.redoStroke(_:))
        }
        let historyColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("History"))
        historyTable.addTableColumn(historyColumn)
        historyTable.headerView = nil
        historyTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        historyTable.allowsEmptySelection = false
        historyTable.rowHeight = 19
        historyTable.backgroundColor = .clear
        historyTable.setAccessibilityLabel("History")
        historyTable.dataSource = self
        historyTable.delegate = self
        historyScroll.documentView = historyTable
        historyScroll.hasVerticalScroller = true
        historyScroll.autohidesScrollers = true
        historyScroll.scrollerStyle = .overlay
        historyScroll.drawsBackground = false
        updateHistory(document.undoManager)
        applyCrop.target = document
        applyCrop.action = #selector(PaintDocument.cropSelection(_:))
        finishMove.target = self
        finishMove.action = #selector(commitMove(_:))
        finishMove.toolTip = "Finish the current transform (Return or Escape)"
        canvas.selectionDidChange = { [weak self] in self?.updateStatus() }
        canvas.selectTransformTool = { [weak self] tool in
            guard let self else { return }
            self.selectTool(tool == .moveSelection ? self.moveSelection : self.moveSelectedPixels)
        }

        scrollView.documentView = canvas
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        zoom.target = self
        zoom.action = #selector(changeZoom(_:))
        zoom.selectedSegment = 0
        zoom.setAccessibilityLabel("Zoom")
        zoom.setToolTip("Fit to window", forSegment: 0)
        zoom.setToolTip("Actual pixels", forSegment: 1)
        canvas.zoomDidChange = { [weak self] in self?.updateZoom() }

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

        let toolbar = NSStackView(views: [undo, redo, NSTextField(labelWithString: "Size"), size, applyCrop, finishMove])
        toolbar.spacing = 8
        for button in [brush, eraser, rectangleSelect, ellipseSelect, moveSelectedPixels, moveSelection] {
            toolButtons.addArrangedSubview(button)
        }
        toolButtons.distribution = .fillEqually
        toolButtons.spacing = 1
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
        colorControls.orientation = .vertical
        colorControls.spacing = 6
        colorControls.addArrangedSubview(color)
        colorControls.addArrangedSubview(swatches)
        let panelButtons = NSStackView(views: UtilityPanels.Kind.allCases.map { kind in
            let button = Self.icon(kind.symbol, label: "Toggle \(kind.title)")
            button.tag = kind.rawValue
            button.target = self
            button.action = #selector(togglePanelButton(_:))
            return button
        })
        panelButtons.spacing = 3
        status.textColor = .secondaryLabelColor
        status.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        zoomLevel.textColor = .secondaryLabelColor
        zoomLevel.font = status.font
        let footer = NSStackView(views: [status, zoomLevel, zoom])
        footer.spacing = 8
        updateStatus()

        for view in [toolbar, panelButtons, scrollView, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            panelButtons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            panelButtons.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -5),
            color.widthAnchor.constraint(equalToConstant: 56),
            color.heightAnchor.constraint(equalToConstant: 26),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func installPanels(on window: NSWindow) {
        let historyControls = NSStackView(views: [historyUndo, historyRedo])
        historyControls.spacing = 2
        for button in [historyUndo, historyRedo] {
            button.isBordered = false
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        }
        let separator = NSBox()
        separator.boxType = .separator
        let historyPanel = NSStackView(views: [historyScroll, separator, historyControls])
        historyPanel.orientation = .vertical
        historyPanel.alignment = .leading
        historyPanel.spacing = 3
        historyScroll.widthAnchor.constraint(equalTo: historyPanel.widthAnchor).isActive = true
        separator.widthAnchor.constraint(equalTo: historyPanel.widthAnchor).isActive = true
        panels = UtilityPanels(parent: window, contents: [
            .tools: toolButtons, .colors: colorControls, .history: historyPanel, .layers: layersView
        ])
        refreshImage()
        updateHistory(document?.undoManager)
    }

    func isPanelShown(_ kind: UtilityPanels.Kind) -> Bool { panels?.isShown(kind) == true }

    func togglePanel(_ kind: UtilityPanels.Kind) { panels?.toggle(kind) }

    func resetPanels() { panels?.resetPositions() }

    @objc private func togglePanelButton(_ sender: NSButton) {
        if let kind = UtilityPanels.Kind(rawValue: sender.tag) { togglePanel(kind) }
    }

    override func layout() {
        super.layout()
        canvas.updateViewport()
    }

    func refreshImage(clearSelection: Bool = false) {
        canvas.cancelEditingGesture()
        if clearSelection { canvas.setSelection(nil) }
        canvas.updateViewport()
        layersView.refresh()
        updateStatus()
    }

    private func updateStatus() {
        applyCrop.isEnabled = canvas.cropRect != nil
        finishMove.isHidden = !canvas.tool.transformsSelection
        finishMove.isEnabled = canvas.hasPendingMove
        updateUndoButtons(document?.undoManager)
        let dimensions = document?.image.map { "\($0.width) × \($0.height) px" } ?? ""
        if let angle = canvas.rotationDegrees, abs(angle) >= 0.05 {
            status.stringValue = "\(Double(angle).formatted(.number.precision(.fractionLength(0...1))))°  ·  \(dimensions)"
        } else if let rect = canvas.imageSelection {
            status.stringValue = "\(Int(rect.width)) × \(Int(rect.height)) at \(Int(rect.minX)), \(Int(rect.minY))  ·  \(dimensions)"
        } else {
            status.stringValue = dimensions
        }
    }

    @objc private func commitMove(_ sender: NSButton) {
        canvas.finishMove()
        window?.makeFirstResponder(canvas)
    }

    private func updateUndoButtons(_ history: UndoManager?) {
        undo.isEnabled = history?.canUndo == true
        redo.isEnabled = history?.canRedo == true
        historyUndo.isEnabled = undo.isEnabled
        historyRedo.isEnabled = redo.isEnabled
    }

    func updateHistory(_ history: UndoManager?) {
        updateUndoButtons(history)
        guard let document else { return }
        updatingHistory = true
        defer { updatingHistory = false }
        historyTable.reloadData()
        historyTable.selectRowIndexes(IndexSet(integer: document.historyPosition), byExtendingSelection: false)
        historyTable.scrollRowToVisible(document.historyPosition)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { document?.historyEntries.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let document else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("History Entry")
        let label = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField
            ?? NSTextField(labelWithString: "")
        label.identifier = identifier
        label.stringValue = document.historyEntries[row]
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingHistory, historyTable.selectedRow >= 0 else { return }
        document?.goToHistoryEntry(historyTable.selectedRow)
    }

    @objc private func selectTool(_ sender: NSButton) {
        let tools: [(NSButton, CanvasView.Tool)] = [
            (brush, .brush), (eraser, .eraser), (rectangleSelect, .rectangleSelect),
            (ellipseSelect, .ellipseSelect),
            (moveSelectedPixels, .moveSelectedPixels), (moveSelection, .moveSelection)
        ]
        for (button, tool) in tools {
            let selected = button === sender
            button.state = selected ? .on : .off
            button.contentTintColor = selected ? .controlAccentColor : .labelColor
            if selected { canvas.tool = tool }
        }
        canvas.window?.makeFirstResponder(canvas)
    }

    private func updateZoom() {
        let segment = canvas.zoomPercent.map { $0 == 100 ? 1 : -1 } ?? 0
        if zoom.selectedSegment != segment { zoom.selectedSegment = segment }
        let scale = Double(canvas.displayedZoomPercent) / 100
        let label = scale.formatted(.percent.precision(.fractionLength(0...1)))
        if zoomLevel.stringValue != label { zoomLevel.stringValue = label }
    }

    @objc private func changeZoom(_ sender: NSSegmentedControl) {
        canvas.setZoom(sender.selectedSegment == 0 ? nil : 100)
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

    static func icon(_ symbol: String, label: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
        button.bezelStyle = .texturedRounded
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }
}
