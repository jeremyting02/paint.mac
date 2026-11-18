import AppKit

enum ImageCommand: CaseIterable {
    case resize, canvasSize, flipHorizontal, flipVertical, rotateClockwise, rotateCounterClockwise, rotateHalfTurn

    var title: String {
        switch self {
        case .resize: return "Resize…"
        case .canvasSize: return "Canvas Size…"
        default: return orientation?.rawValue ?? ""
        }
    }

    var orientation: ImageOrientationEdit? {
        switch self {
        case .resize, .canvasSize: return nil
        case .flipHorizontal: return .flipHorizontal
        case .flipVertical: return .flipVertical
        case .rotateClockwise: return .clockwise
        case .rotateCounterClockwise: return .counterClockwise
        case .rotateHalfTurn: return .halfTurn
        }
    }
}

extension PaintDocument {
    @objc func imageCommand(_ sender: NSMenuItem) {
        guard ImageCommand.allCases.indices.contains(sender.tag) else { return }
        let command = ImageCommand.allCases[sender.tag]
        if let orientation = command.orientation {
            performOrientation(orientation)
        } else {
            showImageSizeOptions(canvasOnly: command == .canvasSize)
        }
    }

    @objc func flipLayerHorizontal(_ sender: Any?) { performOrientation(.flipHorizontal, activeLayerOnly: true) }
    @objc func flipLayerVertical(_ sender: Any?) { performOrientation(.flipVertical, activeLayerOnly: true) }
    @objc func rotateLayer180(_ sender: Any?) { performOrientation(.halfTurn, activeLayerOnly: true) }
    @objc func rotateZoomLayer(_ sender: Any?) { showFilter(LayerRotateZoom.filter) }

    func performOrientation(_ orientation: ImageOrientationEdit, activeLayerOnly: Bool = false) {
        editor?.canvas.finishSelection()
        guard let previous = stack else { return }
        let image = previous.activeLayer.image
        let outline = editor?.canvas.selectionOutline
        let transformed = activeLayerOnly ? outline : outline?.transformed(by:
            orientation.selectionTransform(width: image.width, height: image.height))
        do {
            let next = try previous.reoriented(orientation, activeOnly: activeLayerOnly)
            applyEdit(replacingStack: next, actionName: orientation.rawValue, selectionChange: (outline, transformed))
        } catch {
            presentError(error)
        }
    }

    private func showImageSizeOptions(canvasOnly: Bool) {
        guard !hasBackgroundJob, let image, let window = windowForSheet, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = canvasOnly ? "Canvas Size" : "Resize"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let options = ImageSizeOptions(width: image.width, height: image.height,
                                       purpose: canvasOnly ? .canvasSize : .resize,
                                       resolution: stack?.resolution ?? .standard)
        alert.accessoryView = options.view
        options.acceptButton = alert.buttons.first
        options.updateValidation()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, let size = options.size,
                  let resolution = options.resolution else { return }
            self.performResize(width: size.width, height: size.height, canvasOnly: canvasOnly,
                               anchor: options.anchor, fill: options.fillWord(canvas: self.editor?.canvas,
                                                                             colorSpace: self.stack?.workingColorSpace),
                               sampling: options.sampling, linearLight: options.linearLight, resolution: resolution)
        }
    }

    func performResize(width: Int, height: Int, canvasOnly: Bool = false, anchor: CanvasAnchor = .center,
                       fill: UInt32 = 0, sampling: ImageResampler.Mode = .bicubic, linearLight: Bool = false,
                       resolution: ImageResolution? = nil) {
        guard !hasBackgroundJob, let image else { return }
        let sizeChanged = image.width != width || image.height != height
        let newResolution = resolution.flatMap { $0 == (stack?.resolution ?? .standard) ? nil : $0 }
        guard sizeChanged || newResolution != nil else { return }
        editor?.canvas.finishSelection()
        guard let previous = stack else { return }
        let outline = editor?.canvas.selectionOutline
        if !sizeChanged {
            guard let newResolution else { return }
            var next = previous
            next.metadata = newResolution.updating(next.metadata)
            applyEdit(replacingStack: next, actionName: "Set Resolution", selectionChange: (outline, outline))
            return
        }

        let revision = stackRevision
        let oldWidth = image.width, oldHeight = image.height
        let action = canvasOnly ? "Canvas Size" : "Resize"
        runDocumentJob(title: canvasOnly ? "Changing Canvas Size…" : "Resizing Image…") {
            var next: LayerStack
            let transform: CGAffineTransform
            if canvasOnly {
                next = try previous.resizedCanvas(width: width, height: height, anchor: anchor, fill: fill)
                let delta = anchor.offset(widthDelta: width - oldWidth, heightDelta: height - oldHeight)
                transform = CGAffineTransform(translationX: CGFloat(delta.x), y: CGFloat(height - oldHeight - delta.y))
            } else {
                next = try previous.resizedImage(width: width, height: height, sampling: sampling, linearLight: linearLight)
                transform = CGAffineTransform(scaleX: CGFloat(width) / CGFloat(oldWidth),
                                              y: CGFloat(height) / CGFloat(oldHeight))
            }
            if let newResolution { next.metadata = newResolution.updating(next.metadata) }
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            return (stack: next, selection: outline?.transformed(by: transform)?.clipped(to: bounds))
        } commit: { document, result in
            guard document.canCommitDocumentJob(revision: revision, selection: outline) else { return }
            document.applyEdit(replacingStack: result.stack, actionName: action,
                               selectionChange: (outline, result.selection))
        }
    }
}

final class NewImageCommand: NSObject {
    static let shared = NewImageCommand()
    static let defaultWidth = 800
    static let defaultHeight = 600

    @MainActor @objc func show(_ sender: Any?) {
        let parent = (sender as? NSView)?.window ?? NSApp.mainWindow
        guard parent?.attachedSheet == nil else { return }
        let clipboard = PaintDocument.image(on: .general)
        let alert = NSAlert()
        alert.messageText = "New Image"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let options = ImageSizeOptions(width: clipboard?.width ?? Self.defaultWidth,
                                       height: clipboard?.height ?? Self.defaultHeight,
                                       purpose: .newImage, resolution: .standard)
        alert.accessoryView = options.view
        options.acceptButton = alert.buttons.first
        options.updateValidation()
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn, let size = options.size,
                  let resolution = options.resolution,
                  let document = PaintDocument.newImage(width: size.width, height: size.height, resolution: resolution)
            else { return }
            NSDocumentController.shared.addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
        }
        if let parent {
            alert.beginSheetModal(for: parent, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}

private final class ImageSizeOptions: NSObject, NSTextFieldDelegate {
    enum Purpose { case newImage, resize, canvasSize }
    let view: NSView
    weak var acceptButton: NSButton?
    private let originalWidth: Int
    private let originalHeight: Int
    private let dimensionMode = NSPopUpButton()
    private let widthField: NSTextField
    private let heightField: NSTextField
    private let horizontalDPI: NSTextField
    private let verticalDPI: NSTextField
    private let percentageField = NSTextField(string: "100")
    private let aspect = NSButton(checkboxWithTitle: "Maintain aspect ratio", target: nil, action: nil)
    private let anchorChoice = NSPopUpButton()
    private let fillChoice = NSPopUpButton()
    private let samplingChoice = NSPopUpButton()
    private let gamma = NSButton(checkboxWithTitle: "Gamma correction", target: nil, action: nil)
    private let message = NSTextField(labelWithString: "")

    init(width: Int, height: Int, purpose: Purpose, resolution: ImageResolution) {
        originalWidth = width
        originalHeight = height
        widthField = NSTextField(string: String(width))
        heightField = NSTextField(string: String(height))
        horizontalDPI = NSTextField(string: String(resolution.horizontal))
        verticalDPI = NSTextField(string: String(resolution.vertical))
        view = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 1))
        super.init()

        dimensionMode.addItems(withTitles: ["By absolute size", "By percentage"])
        dimensionMode.target = self
        dimensionMode.action = #selector(changeOptions)
        widthField.setAccessibilityLabel("Width in pixels")
        heightField.setAccessibilityLabel("Height in pixels")
        percentageField.setAccessibilityLabel("Percentage")
        horizontalDPI.setAccessibilityLabel("Horizontal resolution in dots per inch")
        verticalDPI.setAccessibilityLabel("Vertical resolution in dots per inch")
        for field in [widthField, heightField, percentageField, horizontalDPI, verticalDPI] {
            field.delegate = self
            field.alignment = .right
        }
        aspect.state = purpose == .resize ? .on : .off
        aspect.target = self
        aspect.action = #selector(changeOptions)
        anchorChoice.addItems(withTitles: CanvasAnchor.allCases.map(\.rawValue))
        anchorChoice.selectItem(withTitle: CanvasAnchor.center.rawValue)
        fillChoice.addItems(withTitles: ["Transparent", "Primary Color", "Secondary Color", "White", "Black"])
        samplingChoice.addItems(withTitles: ImageResampler.Mode.allCases.map(\.rawValue))
        message.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        var rows: [(String, NSView)] = [("Width (px)", widthField), ("Height (px)", heightField)]
        if purpose != .newImage {
            rows.insert(("Size", dimensionMode), at: 0)
            rows.append(("Percentage", percentageField))
        }
        rows += [
            ("", aspect),
            ("Horizontal resolution (dpi)", horizontalDPI), ("Vertical resolution (dpi)", verticalDPI)
        ]
        if purpose == .canvasSize { rows += [("Anchor", anchorChoice), ("Fill", fillChoice)] }
        if purpose == .resize { rows += [("Resampling", samplingChoice), ("", gamma)] }
        let grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), $0.1] })
        grid.columnSpacing = 9
        grid.rowSpacing = 6
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        let stack = NSStackView(views: [grid, message])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        view.setFrameSize(NSSize(width: 330, height: stack.fittingSize.height))
        if purpose == .newImage { updateValidation() } else { changeOptions() }
    }

    var anchor: CanvasAnchor { CanvasAnchor.allCases[anchorChoice.indexOfSelectedItem] }
    var sampling: ImageResampler.Mode { ImageResampler.Mode.allCases[samplingChoice.indexOfSelectedItem] }
    var linearLight: Bool { gamma.state == .on }
    private var byPercentage: Bool { dimensionMode.indexOfSelectedItem == 1 }

    var size: (width: Int, height: Int)? {
        guard let width = Int(widthField.stringValue), let height = Int(heightField.stringValue),
              LayerStack.supportsCanvas(width: width, height: height) else { return nil }
        return (width, height)
    }

    var resolution: ImageResolution? {
        guard let horizontal = Double(horizontalDPI.stringValue), let vertical = Double(verticalDPI.stringValue) else { return nil }
        return ImageResolution(horizontal: horizontal, vertical: vertical)
    }

    func fillWord(canvas: CanvasView?, colorSpace: CGColorSpace?) -> UInt32 {
        let color: NSColor
        switch fillChoice.indexOfSelectedItem {
        case 1: color = canvas?.brushColor ?? .black
        case 2: color = canvas?.secondaryColor ?? .white
        case 3: color = .white
        case 4: color = .black
        default: return 0
        }
        let drawingColor = DrawingColor(color, in: colorSpace)
        return UInt32(drawingColor.blue) | (UInt32(drawingColor.green) << 8) |
               (UInt32(drawingColor.red) << 16) | (UInt32(drawingColor.alpha) << 24)
    }

    @objc private func changeOptions() {
        widthField.isEnabled = !byPercentage
        heightField.isEnabled = !byPercentage
        percentageField.isEnabled = byPercentage
        aspect.isEnabled = !byPercentage
        updateFields(edited: byPercentage ? percentageField : widthField)
    }

    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSTextField {
            if field === horizontalDPI || field === verticalDPI { updateValidation() }
            else { updateFields(edited: field) }
        }
    }

    private func updateFields(edited: NSTextField) {
        if byPercentage {
            if let percent = Double(percentageField.stringValue), percent.isFinite, (0.01...409_600).contains(percent) {
                widthField.stringValue = String(max(1, Int((Double(originalWidth) * percent / 100).rounded())))
                heightField.stringValue = String(max(1, Int((Double(originalHeight) * percent / 100).rounded())))
            } else {
                widthField.stringValue = ""
                heightField.stringValue = ""
            }
        } else if aspect.state == .on, let dimension = Int(edited.stringValue), (1...4096).contains(dimension) {
            if edited === widthField {
                heightField.stringValue = String(max(1, Int((Double(dimension) * Double(originalHeight) / Double(originalWidth)).rounded())))
            } else {
                widthField.stringValue = String(max(1, Int((Double(dimension) * Double(originalWidth) / Double(originalHeight)).rounded())))
            }
        }
        updateValidation()
    }

    func updateValidation() {
        guard let size, let resolution else {
            acceptButton?.isEnabled = false
            message.stringValue = size == nil ? "Enter a size within the app’s image limits." : "Enter a valid resolution."
            return
        }
        acceptButton?.isEnabled = true
        message.stringValue = String(format: "Print size %.2f × %.2f in", Double(size.width) / resolution.horizontal,
                                     Double(size.height) / resolution.vertical)
    }
}

final class ExportOptions: NSObject {
    private weak var panel: NSSavePanel?
    private let formats: [RasterFormat]
    private let formatsMenu = NSPopUpButton()
    private let qualitySlider = NSSlider(value: 90, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let qualityLabel = NSTextField(labelWithString: "Quality")

    init(panel: NSSavePanel, formats: [RasterFormat]) {
        self.panel = panel
        self.formats = formats.isEmpty ? [.png] : formats
        super.init()
        formatsMenu.addItems(withTitles: self.formats.map(\.displayName))
        updateFormat()
        guard self.formats.count > 1 else { return }
        formatsMenu.target = self
        formatsMenu.action = #selector(updateFormat)
        qualitySlider.setAccessibilityLabel("Export quality")
        let formatRow = NSStackView(views: [NSTextField(labelWithString: "Format"), formatsMenu])
        let qualityRow = NSStackView(views: [qualityLabel, qualitySlider])
        qualitySlider.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let content = NSStackView(views: [formatRow, qualityRow])
        content.orientation = .vertical
        content.alignment = .leading
        content.setFrameSize(content.fittingSize)
        panel.accessoryView = content
    }

    var format: RasterFormat { formats[max(0, formatsMenu.indexOfSelectedItem)] }
    var quality: Double { qualitySlider.doubleValue / 100 }

    @objc private func updateFormat() {
        panel?.allowedContentTypes = [format.contentType]
        qualitySlider.isEnabled = format.isLossy
        qualityLabel.textColor = format.isLossy ? .labelColor : .disabledControlTextColor
    }
}
