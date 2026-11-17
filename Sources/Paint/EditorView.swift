import AppKit

final class EditorView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSComboBoxDelegate {
    let canvas: CanvasView
    private weak var document: PaintDocument?
    private weak var enclosingOptionsArea: WorkspaceOptionsArea?
    private let scrollView = NSScrollView()
    let documentStrip = DocumentStrip()
    private let toolOptions = ToolOptionsView()
    private let status = NSTextField(labelWithString: "")
    private let coordinates = NSTextField(labelWithString: "")
    private let dimensions = NSTextField(labelWithString: "")
    private let zoom = NSSegmentedControl(labels: ["Fit", "100%"], trackingMode: .selectOne,
                                          target: nil, action: nil)
    private let zoomLevel = NSTextField()
    private let zoomSlider = NSSlider()
    private let zoomOut = EditorView.icon("minus.magnifyingglass", label: "Zoom Out")
    private let zoomIn = EditorView.icon("plus.magnifyingglass", label: "Zoom In")
    private let rulersButton = EditorView.icon("ruler", label: "Rulers")
    private let gridButton = EditorView.icon("grid", label: "Pixel Grid")
    private var horizontalRuler: WorkspaceRuler?
    private var verticalRuler: WorkspaceRuler?
    var showsRulers: Bool { scrollView.rulersVisible }
    var showsGrid: Bool { canvas.showsPixelGrid }
    private let brush = EditorView.icon("paintbrush", label: "Paintbrush")
    private let eraser = EditorView.icon("eraser", label: "Eraser")
    private let paintBucket = EditorView.icon(EditorView.bucketImage, label: "Paint Bucket")
    private let gradient = EditorView.icon("circle.lefthalf.filled", label: "Gradient")
    private let rectangleSelect = EditorView.icon("rectangle.dashed", label: "Rectangle Select")
    private let ellipseSelect = EditorView.icon("circle.dashed", label: "Ellipse Select")
    private let lassoSelect = EditorView.icon("lasso", label: "Lasso Select")
    private let magicWand = EditorView.icon("wand.and.stars", label: "Magic Wand")
    private let moveSelectedPixels = EditorView.icon("arrow.up.and.down.and.arrow.left.and.right", label: "Move Pixels")
    private let moveSelection = EditorView.icon("rectangle.dashed.and.paperclip", label: "Move Selection")
    private let zoomTool = EditorView.icon("magnifyingglass", label: "Zoom Tool")
    private let pan = EditorView.icon("hand.raised", label: "Pan")
    private let pencil = EditorView.icon("pencil", label: "Pencil")
    private let picker = EditorView.icon("eyedropper", label: "Color Picker")
    private let stamp = EditorView.icon("paintbrush.pointed", label: "Clone Stamp")
    private let recolor = EditorView.icon("paintbrush.pointed.fill", label: "Recolor")
    private let text = EditorView.icon("textformat", label: "Text")
    private let line = EditorView.icon("line.diagonal", label: "Line / Curve")
    private let shapes = EditorView.icon("square.on.circle", label: "Shapes")
    private let toolName = NSTextField(labelWithString: "Paintbrush")
    private let applyCrop = EditorView.icon("crop", label: "Crop to Selection")
    private let finish = NSButton(title: "Finish", target: nil, action: nil)
    private let undo = EditorView.icon("arrow.uturn.backward", label: "Undo")
    private let redo = EditorView.icon("arrow.uturn.forward", label: "Redo")
    private let colors = ColorsView(model: .shared)
    private let toolButtons = NSStackView()
    private let brushControls = NSStackView()
    private let brushSize = NSComboBox()
    private let selectionModes = NSPopUpButton()
    private let floodControls = NSStackView()
    private let floodToleranceValue = NSTextField(labelWithString: "")
    private let historyScroll = NSScrollView()
    private let historyTable = NSTableView()
    private let historyUndo = EditorView.icon("arrow.uturn.backward", label: "Undo")
    private let historyRedo = EditorView.icon("arrow.uturn.forward", label: "Redo")
    private var updatingHistory = false
    private let layersView: LayersView
    private var panels: UtilityPanels?
    private var panelButtons: [UtilityPanels.Kind: NSButton] = [:]
    private var tools: [(button: NSButton, tool: CanvasView.Tool)] {
        [(rectangleSelect, .rectangleSelect), (moveSelectedPixels, .moveSelectedPixels),
         (lassoSelect, .lassoSelect), (moveSelection, .moveSelection), (ellipseSelect, .ellipseSelect), (zoomTool, .zoom),
         (magicWand, .magicWand), (pan, .pan), (paintBucket, .paintBucket), (gradient, .gradient),
         (brush, .brush), (eraser, .eraser), (pencil, .pencil), (picker, .colorPicker),
         (stamp, .cloneStamp), (recolor, .recolor), (text, .text), (line, .lineCurve), (shapes, .shapes)]
    }

    init(document: PaintDocument) {
        self.document = document
        canvas = CanvasView(document: document)
        layersView = LayersView(document: document)
        super.init(frame: NSRect(x: 0, y: 0, width: 880, height: 640))

        configureToolPalette()
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
        canvas.colorDidPick = { picked, isSecondary in
            WorkspaceColors.shared.set(WorkspaceColor(picked), for: isSecondary ? .secondary : .primary)
        }
        canvas.handleColorShortcut = { [weak self] key in self?.colors.handleShortcut(key) == true }
        colors.colorsDidChange = { [weak self] in self?.applyColors() }
        applyColors()
        toolOptions.configure(canvas: canvas)

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
        configureZoomControls()
        configureRulers()

        brushSize.addItems(withObjectValues: [1, 2, 4, 8, 12, 16, 24, 32, 48, 64, 96, 128].map(String.init))
        brushSize.numberOfVisibleItems = 8
        brushSize.setAccessibilityLabel("Brush size in pixels")
        brushSize.widthAnchor.constraint(equalToConstant: 78).isActive = true
        brushSize.delegate = self
        brushSize.target = self
        brushSize.action = #selector(changeSize(_:))
        canvas.brushSizeDidChange = { [weak self] in self?.refreshBrushSize() }
        refreshBrushSize()

        brushControls.spacing = 8
        brushControls.addArrangedSubview(NSTextField(labelWithString: "Size (px)"))
        brushControls.addArrangedSubview(brushSize)
        selectionModes.addItems(withTitles: SelectionOutline.Mode.allCases.map(\.rawValue))
        selectionModes.setAccessibilityLabel("Selection Mode")
        selectionModes.toolTip = "Selection Mode"
        selectionModes.target = self
        selectionModes.action = #selector(changeSelectionMode(_:))
        configureFloodControls()
        let contextual = NSStackView(views: [toolName, brushControls, selectionModes, floodControls, toolOptions, finish])
        contextual.spacing = 7
        let optionsScroll = NSScrollView()
        optionsScroll.identifier = NSUserInterfaceItemIdentifier("Tool Options")
        optionsScroll.drawsBackground = false
        optionsScroll.hasHorizontalScroller = true
        optionsScroll.autohidesScrollers = true
        optionsScroll.scrollerStyle = .overlay
        let optionsArea = WorkspaceOptionsArea(contents: contextual)
        enclosingOptionsArea = optionsArea
        optionsScroll.documentView = optionsArea
        let panelsBar = NSStackView(views: UtilityPanels.Kind.allCases.map { kind in
            let button = Self.icon(kind.symbol, label: "Toggle \(kind.title)")
            button.tag = kind.rawValue
            button.target = self
            button.action = #selector(togglePanelButton(_:))
            panelButtons[kind] = button
            return button
        })
        panelsBar.spacing = 3
        configureCommandToolbarButtons()
        let commands = NSStackView(views: [command("doc.badge.plus", "New", #selector(NewImageCommand.show(_:)),
                                                    target: NewImageCommand.shared),
                                             command("folder", "Open", #selector(NSDocumentController.openDocument(_:))),
                                             command("internaldrive", "Save", #selector(NSDocument.save(_:)), target: document),
                                             undo, redo, applyCrop, rulersButton, gridButton])
        commands.identifier = NSUserInterfaceItemIdentifier("Editor Commands")
        commands.spacing = 3
        for label in [status, coordinates, dimensions] {
            label.textColor = .secondaryLabelColor
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.lineBreakMode = .byTruncatingTail
        }
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        zoomLevel.textColor = .secondaryLabelColor
        zoomLevel.font = status.font
        let footer = NSStackView(views: [coordinates, dimensions, zoom, zoomOut, zoomSlider, zoomIn, zoomLevel])
        footer.identifier = NSUserInterfaceItemIdentifier("View Controls")
        footer.spacing = 4
        coordinates.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dimensions.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        coordinates.setAccessibilityLabel("Cursor position")
        dimensions.setAccessibilityLabel("Image dimensions")
        let divider = NSBox()
        divider.boxType = .separator

        for view in [commands, documentStrip, panelsBar, optionsScroll, divider, scrollView, status, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            documentStrip.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            documentStrip.leadingAnchor.constraint(equalTo: commands.trailingAnchor, constant: 8),
            documentStrip.trailingAnchor.constraint(equalTo: panelsBar.leadingAnchor, constant: -8),
            documentStrip.widthAnchor.constraint(greaterThanOrEqualToConstant: 1),
            documentStrip.heightAnchor.constraint(equalToConstant: 30),
            commands.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            commands.centerYAnchor.constraint(equalTo: documentStrip.centerYAnchor),
            panelsBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            panelsBar.centerYAnchor.constraint(equalTo: documentStrip.centerYAnchor),
            optionsScroll.topAnchor.constraint(equalTo: documentStrip.bottomAnchor, constant: 1),
            optionsScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            optionsScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            optionsScroll.heightAnchor.constraint(equalToConstant: 32),
            divider.topAnchor.constraint(equalTo: optionsScroll.bottomAnchor, constant: 2),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -3),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            status.trailingAnchor.constraint(lessThanOrEqualTo: footer.leadingAnchor, constant: -6),
            status.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        ])
        selectTool(brush)
        updateStatus()
    }

    required init?(coder: NSCoder) { nil }

    func installPanels(on window: NSWindow) {
        guard panels == nil else { return }
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
        panels = UtilityPanels(parent: window, colorsSize: colors.panelSize, contents: [
            .tools: toolButtons, .colors: colors, .history: historyPanel, .layers: layersView
        ])
        panels?.visibilityDidChange = { [weak self] in
            self?.updatePanelButtons()
            self?.applyColors()
        }
        colors.expansionDidChange = { [weak self] in
            guard let self else { return }
            panels?.resizeColors(to: colors.panelSize)
        }
        updatePanelButtons()
        updateHistory(document?.undoManager)
    }

    func setWorkspaceActive(_ active: Bool) { panels?.isWorkspaceActive = active }

    func isPanelShown(_ kind: UtilityPanels.Kind) -> Bool { panels?.isShown(kind) == true }

    func togglePanel(_ kind: UtilityPanels.Kind) { panels?.toggle(kind) }

    func resetPanels() { panels?.resetPositions() }

    func resetColorsPanel() { panels?.resetColorsPosition() }

    private func updatePanelButtons() {
        for (kind, button) in panelButtons { button.state = isPanelShown(kind) ? .on : .off }
    }

    @objc private func togglePanelButton(_ sender: NSButton) {
        guard let kind = UtilityPanels.Kind(rawValue: sender.tag) else { return }
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if kind == .colors, flags.contains([.control, .shift]) { resetColorsPanel() }
        else { togglePanel(kind) }
    }

    private func configureToolPalette() {
        toolButtons.orientation = .vertical
        toolButtons.alignment = .leading
        toolButtons.spacing = 1
        for (index, item) in tools.enumerated() {
            let button = item.button
            button.setButtonType(.pushOnPushOff)
            button.target = self
            button.action = #selector(selectTool(_:))
            button.isBordered = false
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
            if index.isMultiple(of: 2) {
                let row = NSStackView()
                row.spacing = 1
                toolButtons.addArrangedSubview(row)
            }
            (toolButtons.arrangedSubviews.last as? NSStackView)?.addArrangedSubview(button)
        }
    }

    private func command(_ symbol: String, _ title: String, _ action: Selector, target: AnyObject? = nil) -> NSButton {
        let button = Self.icon(symbol, label: title)
        button.target = target
        button.action = action
        return button
    }

    private func configureCommandToolbarButtons() {
        rulersButton.target = self
        rulersButton.action = #selector(toggleRulersButton(_:))
        gridButton.target = self
        gridButton.action = #selector(toggleGridButton(_:))
        for button in [rulersButton, gridButton] + Array(panelButtons.values) {
            button.setButtonType(.pushOnPushOff)
        }
    }

    private func configureRulers() {
        let horizontal = WorkspaceRuler(scrollView: scrollView, canvas: canvas, orientation: .horizontalRuler)
        let vertical = WorkspaceRuler(scrollView: scrollView, canvas: canvas, orientation: .verticalRuler)
        scrollView.horizontalRulerView = horizontal
        scrollView.verticalRulerView = vertical
        scrollView.hasHorizontalRuler = true
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = false
        horizontalRuler = horizontal
        verticalRuler = vertical
        canvas.pointerDidMove = { [weak self] point in
            guard let self else { return }
            let label = point.map { "\(Int($0.x)), \(Int($0.y))" } ?? ""
            if coordinates.stringValue != label { coordinates.stringValue = label }
            horizontalRuler?.pointer = point?.x
            verticalRuler?.pointer = point?.y
        }
    }

    func toggleRulers() {
        scrollView.rulersVisible.toggle()
        rulersButton.state = showsRulers ? .on : .off
        canvas.updateViewport()
    }

    func toggleGrid() {
        canvas.showsPixelGrid.toggle()
        gridButton.state = showsGrid ? .on : .off
    }

    @objc private func toggleRulersButton(_ sender: NSButton) { toggleRulers() }
    @objc private func toggleGridButton(_ sender: NSButton) { toggleGrid() }

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
        if let document { WorkspaceDocuments.shared.invalidateThumbnail(for: document) }
    }

    private func updateStatus() {
        brushControls.isHidden = ![CanvasView.Tool.brush, .eraser, .cloneStamp, .recolor, .lineCurve, .shapes].contains(canvas.tool)
        selectionModes.isHidden = !canvas.tool.drawsSelection
        floodControls.isHidden = !canvas.tool.usesFlood
        applyCrop.isEnabled = canvas.cropRect != nil
        let supportsFinish = [CanvasView.Tool.gradient, .text, .lineCurve, .shapes].contains(canvas.tool)
        finish.isHidden = !canvas.tool.transformsSelection && !canvas.tool.usesFlood && !supportsFinish
        finish.isEnabled = canvas.hasPendingMove || canvas.hasPendingFloodEdit || canvas.hasPendingGradient || canvas.hasPendingDrawing
        toolOptions.update()
        enclosingOptionsArea?.refreshSize()
        updateUndoButtons(document?.undoManager)
        let image = document?.image
        dimensions.stringValue = image.map { "\($0.width) × \($0.height) px" } ?? ""
        horizontalRuler?.pixelCount = image?.width ?? 0
        verticalRuler?.pixelCount = image?.height ?? 0
        if let angle = canvas.rotationDegrees, abs(angle) >= 0.05 {
            status.stringValue = "\(Double(angle).formatted(.number.precision(.fractionLength(0...1))))°"
        } else if let rect = canvas.imageSelection {
            status.stringValue = "\(Int(rect.width)) × \(Int(rect.height)) at \(Int(rect.minX)), \(Int(rect.minY))"
        } else {
            status.stringValue = ""
        }
    }

    @objc private func commitSelection(_ sender: NSButton) {
        canvas.finishSelection()
        window?.makeFirstResponder(canvas)
    }

    private func updateUndoButtons(_ history: UndoManager?) {
        undo.isEnabled = history?.canUndo == true || canvas.hasLiveEditChange
        redo.isEnabled = history?.canRedo == true && !canvas.hasLiveEditChange
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
            if selected {
                toolName.stringValue = button.toolTip ?? ""
                canvas.tool = tool
            }
        }
        canvas.window?.makeFirstResponder(canvas)
    }

    private func updateZoom() {
        let segment = canvas.zoomPercent.map { $0 == 100 ? 1 : -1 } ?? 0
        if zoom.selectedSegment != segment { zoom.selectedSegment = segment }
        let scale = Double(canvas.displayedZoomPercent) / 100
        let label = scale.formatted(.percent.precision(.fractionLength(0...1)))
        if zoomLevel.currentEditor() == nil, zoomLevel.stringValue != label {
            zoomLevel.stringValue = label
        }
        zoomSlider.integerValue = CanvasView.zoomSteps.indices.min {
            abs(CanvasView.zoomSteps[$0] - canvas.displayedZoomPercent) < abs(CanvasView.zoomSteps[$1] - canvas.displayedZoomPercent)
        } ?? 0
        zoomIn.isEnabled = WorkspaceZoom.next(from: canvas.displayedZoomPercent, by: 1) != nil
        zoomOut.isEnabled = WorkspaceZoom.next(from: canvas.displayedZoomPercent, by: -1) != nil
        horizontalRuler?.needsDisplay = true
        verticalRuler?.needsDisplay = true
    }

    private func configureZoomControls() {
        zoomSlider.minValue = 0
        zoomSlider.maxValue = Double(CanvasView.zoomSteps.count - 1)
        zoomSlider.target = self
        zoomSlider.action = #selector(changeZoomSlider(_:))
        zoomSlider.isContinuous = true
        zoomSlider.controlSize = .small
        zoomSlider.setAccessibilityLabel("Zoom level")
        zoomSlider.widthAnchor.constraint(equalToConstant: 62).isActive = true
        zoomLevel.controlSize = .small
        zoomLevel.alignment = .right
        zoomLevel.target = self
        zoomLevel.action = #selector(changeZoomLevel(_:))
        zoomLevel.setAccessibilityLabel("Zoom percentage")
        zoomLevel.widthAnchor.constraint(equalToConstant: 58).isActive = true
        for (button, direction) in [(zoomOut, -1), (zoomIn, 1)] {
            button.tag = direction
            button.target = self
            button.action = #selector(stepZoom(_:))
        }
    }

    @objc private func changeZoom(_ sender: NSSegmentedControl) {
        canvas.setZoom(sender.selectedSegment == 0 ? nil : 100)
    }

    @objc private func changeZoomSlider(_ sender: NSSlider) {
        canvas.setZoom(CanvasView.zoomSteps[Int(sender.doubleValue.rounded())])
    }

    @objc private func changeZoomLevel(_ sender: NSTextField) {
        let requestedPercent = WorkspaceZoom.parse(sender.stringValue, locale: .current)
        window?.makeFirstResponder(canvas)
        if let requestedPercent { canvas.setZoom(requestedPercent) }
        updateZoom()
    }

    @objc private func stepZoom(_ sender: NSButton) {
        guard let next = WorkspaceZoom.next(from: canvas.displayedZoomPercent, by: sender.tag) else { return }
        canvas.setZoom(next)
    }

    @objc private func changeSize(_ sender: NSComboBox) {
        setBrushSize(from: sender.stringValue)
        window?.makeFirstResponder(canvas)
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        if let selected = brushSize.objectValueOfSelectedItem as? String { setBrushSize(from: selected) }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if (notification.object as? NSComboBox) === brushSize { setBrushSize(from: brushSize.stringValue) }
    }

    private func setBrushSize(from string: String) {
        if let pixels = (try? Double(string, format: .number)) ?? Double(string),
           CanvasView.brushSizeRange.contains(CGFloat(pixels)) {
            canvas.brushSize = CGFloat(pixels)
        } else {
            refreshBrushSize()
        }
    }

    private func refreshBrushSize() {
        brushSize.stringValue = Double(canvas.brushSize).formatted(.number.grouping(.never).precision(.fractionLength(0...8)))
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

    private func applyColors() {
        guard window?.isMainWindow != false else { return }
        let primary = WorkspaceColors.shared[.primary].color
        let secondary = WorkspaceColors.shared[.secondary].color
        if canvas.brushColor != primary { canvas.brushColor = primary }
        if canvas.secondaryColor != secondary { canvas.secondaryColor = secondary }
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

private final class WorkspaceOptionsArea: NSView {
    private let contents: NSStackView

    init(contents: NSStackView) {
        self.contents = contents
        super.init(frame: .zero)
        contents.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contents)
        NSLayoutConstraint.activate([
            contents.leadingAnchor.constraint(equalTo: leadingAnchor),
            contents.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        refreshSize()
    }

    required init?(coder: NSCoder) { nil }

    func refreshSize() {
        let width = contents.arrangedSubviews.filter { !$0.isHidden }.reduce(CGFloat(0)) { partial, view in
            partial + view.fittingSize.width + contents.spacing
        }
        let size = CGSize(width: ceil(width), height: 32)
        if frame.size != size { setFrameSize(size) }
    }
}

enum WorkspaceZoom {
    static func next(from percent: CGFloat, by direction: Int) -> CGFloat? {
        if direction > 0 { return CanvasView.zoomSteps.first { $0 > percent + 0.0001 } }
        return CanvasView.zoomSteps.last { $0 < percent - 0.0001 }
    }

    static func parse(_ string: String, locale: Locale) -> CGFloat? {
        let input = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = input.hasSuffix("%") ? String(input.dropLast()).trimmingCharacters(in: .whitespaces) : input
        let normalized = value.replacingOccurrences(of: locale.decimalSeparator ?? ".", with: ".")
        guard normalized.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let number = Double(normalized), number.isFinite,
              let minimum = CanvasView.zoomSteps.first, let maximum = CanvasView.zoomSteps.last,
              number >= minimum, number <= maximum else { return nil }
        return CGFloat(number)
    }
}
