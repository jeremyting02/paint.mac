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
    private let paintBucket = EditorView.icon(EditorView.bucketImage, label: "Paint Bucket")
    private let rectangleSelect = EditorView.icon("rectangle.dashed", label: "Rectangle Select")
    private let ellipseSelect = EditorView.icon("circle.dashed", label: "Ellipse Select")
    private let lassoSelect = EditorView.icon("lasso", label: "Lasso Select")
    private let magicWand = EditorView.icon("wand.and.stars", label: "Magic Wand")
    private let moveSelectedPixels = EditorView.icon("arrow.up.and.down.and.arrow.left.and.right", label: "Move Selected Pixels")
    private let moveSelection = EditorView.icon("rectangle.dashed.and.paperclip", label: "Move Selection")
    private let applyCrop = EditorView.icon("crop", label: "Crop to Selection")
    private let finish = NSButton(title: "Finish", target: nil, action: nil)
    private let undo = EditorView.icon("arrow.uturn.backward", label: "Undo")
    private let redo = EditorView.icon("arrow.uturn.forward", label: "Redo")
    private let color = NSColorWell()
    private let toolButtons = NSStackView()
    private let brushControls = NSStackView()
    private let selectionModes = NSPopUpButton()
    private let floodControls = NSStackView()
    private let floodToleranceValue = NSTextField(labelWithString: "")
    private let colorControls = NSStackView()
    private let historyScroll = NSScrollView()
    private let historyTable = NSTableView()
    private let historyUndo = EditorView.icon("arrow.uturn.backward", label: "Undo")
    private let historyRedo = EditorView.icon("arrow.uturn.forward", label: "Redo")
    private var updatingHistory = false
    private let layersView: LayersView
    private var panels: UtilityPanels?
    private let swatchColors: [(String, NSColor)] = [("Black", .black), ("Red", .systemRed), ("Blue", .systemBlue)]
    private var tools: [(button: NSButton, tool: CanvasView.Tool)] {
        [(brush, .brush), (eraser, .eraser), (paintBucket, .paintBucket), (rectangleSelect, .rectangleSelect),
         (ellipseSelect, .ellipseSelect), (lassoSelect, .lassoSelect), (magicWand, .magicWand),
         (moveSelectedPixels, .moveSelectedPixels), (moveSelection, .moveSelection)]
    }

    init(document: PaintDocument) {
        self.document = document
        canvas = CanvasView(document: document)
        layersView = LayersView(document: document)
        super.init(frame: NSRect(x: 0, y: 0, width: 880, height: 640))

        for (button, _) in tools {
            button.setButtonType(.pushOnPushOff)
            button.target = self
            button.action = #selector(selectTool(_:))
            toolButtons.addArrangedSubview(button)
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
        finish.target = self
        finish.action = #selector(commitSelection(_:))
        finish.toolTip = "Finish editing and keep the selection"
        canvas.selectionDidChange = { [weak self] in self?.updateStatus() }
        canvas.selectTool = { [weak self] tool in
            guard let self, let button = tools.first(where: { $0.tool == tool })?.button else { return }
            selectTool(button)
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

        brushControls.spacing = 8
        brushControls.addArrangedSubview(NSTextField(labelWithString: "Size"))
        brushControls.addArrangedSubview(size)
        selectionModes.addItems(withTitles: SelectionOutline.Mode.allCases.map(\.rawValue))
        selectionModes.setAccessibilityLabel("Selection Mode")
        selectionModes.toolTip = "Selection Mode"
        selectionModes.target = self
        selectionModes.action = #selector(changeSelectionMode(_:))
        let toolbar = NSStackView(views: [undo, redo, brushControls, selectionModes, applyCrop, finish])
        toolbar.spacing = 8
        configureFloodControls()
        let toolbarRows = NSStackView(views: [toolbar, floodControls])
        toolbarRows.orientation = .vertical
        toolbarRows.alignment = .leading
        toolbarRows.spacing = 5
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

        for view in [toolbarRows, panelButtons, scrollView, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbarRows.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            toolbarRows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            panelButtons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            panelButtons.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbarRows.bottomAnchor, constant: 8),
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
        brushControls.isHidden = canvas.tool.drawsSelection || canvas.tool == .paintBucket
        selectionModes.isHidden = !canvas.tool.drawsSelection
        floodControls.isHidden = !canvas.tool.usesFlood
        applyCrop.isEnabled = canvas.cropRect != nil
        finish.isHidden = !canvas.tool.transformsSelection && !canvas.tool.usesFlood
        finish.isEnabled = canvas.hasPendingMove || canvas.hasPendingFloodEdit
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

    @objc private func commitSelection(_ sender: NSButton) {
        canvas.finishSelection()
        window?.makeFirstResponder(canvas)
    }

    private func updateUndoButtons(_ history: UndoManager?) {
        undo.isEnabled = history?.canUndo == true || canvas.hasFloodChange
        redo.isEnabled = history?.canRedo == true && !canvas.hasFloodChange
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

    @objc private func changeSelectionMode(_ sender: NSPopUpButton) {
        if let title = sender.titleOfSelectedItem, let mode = SelectionOutline.Mode(rawValue: title) {
            canvas.selectionMode = mode
        }
        canvas.window?.makeFirstResponder(canvas)
    }

    private func configureFloodControls() {
        let label = NSTextField(labelWithString: "Tolerance")
        let tolerance = NSSlider(value: Double(canvas.floodSettings.tolerance), minValue: 0, maxValue: 100,
                                 target: self, action: #selector(changeFloodTolerance(_:)))
        tolerance.isContinuous = true
        tolerance.setAccessibilityLabel("Tolerance")
        floodToleranceValue.alignment = .right
        floodToleranceValue.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        floodToleranceValue.stringValue = "\(canvas.floodSettings.tolerance)%"

        let sampling = NSPopUpButton()
        sampling.addItems(withTitles: FloodSettings.Sampling.allCases.map(\.rawValue))
        sampling.selectItem(withTitle: canvas.floodSettings.sampling.rawValue)
        sampling.setAccessibilityLabel("Sampling")
        sampling.toolTip = "Sample the active layer or the composite image"
        sampling.target = self
        sampling.action = #selector(changeFloodSampling(_:))

        let flood = NSPopUpButton()
        flood.addItems(withTitles: FloodSettings.Flood.allCases.map(\.rawValue))
        flood.selectItem(withTitle: canvas.floodSettings.flood.rawValue)
        flood.setAccessibilityLabel("Flood Mode")
        flood.toolTip = "Select touching pixels or matching pixels anywhere"
        flood.target = self
        flood.action = #selector(changeFloodFlood(_:))

        floodControls.spacing = 8
        for view in [label, tolerance, floodToleranceValue, sampling, flood] {
            floodControls.addArrangedSubview(view)
        }
        tolerance.widthAnchor.constraint(equalToConstant: 86).isActive = true
        floodToleranceValue.widthAnchor.constraint(equalToConstant: 38).isActive = true
    }

    @objc private func changeFloodTolerance(_ sender: NSSlider) {
        canvas.setFloodTolerance(Int(sender.doubleValue.rounded()))
        floodToleranceValue.stringValue = "\(canvas.floodSettings.tolerance)%"
    }

    @objc private func changeFloodSampling(_ sender: NSPopUpButton) {
        if let title = sender.titleOfSelectedItem, let mode = FloodSettings.Sampling(rawValue: title) {
            canvas.floodSettings.sampling = mode
        }
        canvas.window?.makeFirstResponder(canvas)
    }

    @objc private func changeFloodFlood(_ sender: NSPopUpButton) {
        if let title = sender.titleOfSelectedItem, let mode = FloodSettings.Flood(rawValue: title) {
            canvas.floodSettings.flood = mode
        }
        canvas.window?.makeFirstResponder(canvas)
    }

    @objc private func changeColor(_ sender: NSColorWell) {
        canvas.brushColor = sender.color
    }

    @objc private func pickSwatch(_ sender: NSButton) {
        color.color = swatchColors[sender.tag].1
        changeColor(color)
    }

    static func icon(_ symbol: String, label: String) -> NSButton {
        icon(NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), label: label)
    }

    private static func icon(_ image: NSImage, label: String) -> NSButton {
        let button = NSButton(image: image, target: nil, action: nil)
        button.bezelStyle = .texturedRounded
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    private static let bucketImage: NSImage = {
        let image = NSImage(size: CGSize(width: 17, height: 17), flipped: false) { _ in
            NSColor.black.set()
            let bucket = NSBezierPath()
            bucket.move(to: CGPoint(x: 1.5, y: 8))
            bucket.line(to: CGPoint(x: 7.5, y: 14))
            bucket.line(to: CGPoint(x: 13.5, y: 8))
            bucket.line(to: CGPoint(x: 7.5, y: 2))
            bucket.close()
            bucket.move(to: CGPoint(x: 7.5, y: 10))
            bucket.line(to: CGPoint(x: 4.5, y: 16))
            bucket.lineWidth = 1.4
            bucket.lineJoinStyle = .round
            bucket.lineCapStyle = .round
            bucket.stroke()
            NSBezierPath(ovalIn: CGRect(x: 13.5, y: 3, width: 3, height: 3.5)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
