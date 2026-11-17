import AppKit
import UniformTypeIdentifiers

@objc(PaintDocument)
final class PaintDocument: NSDocument {
    enum LayerCommand: Int, CaseIterable {
        case add, delete, duplicate, mergeDown, importFromFile, selectAbove, selectBelow, toggleVisibility, moveUp, moveDown, properties

        var title: String {
            ["Add Layer", "Delete Layer", "Duplicate Layer", "Merge Layer Down", "Import From File…", "Select Layer Above",
             "Select Layer Below", "Show Layer", "Move Layer Up", "Move Layer Down", "Layer Properties…"][rawValue]
        }
    }

    private static let projectType = "Paint.NET Project"
    private static let projectContentType = UTType(importedAs: "com.paintdotnet.pdn")
    private static let pixelClipboardTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, .init(UTType.jpeg.identifier)]
    private(set) var stack: LayerStack?
    var image: CGImage? { stack?.activeLayer.image }
    private weak var editor: EditorView?
    private(set) var historyEntries = ["New Image"]
    private(set) var historyPosition = 0

    override var isDocumentEdited: Bool {
        editor?.canvas.hasPendingPixelEdit == true || super.isDocumentEdited
    }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        // Selection and preview steps are undoable, but leave the saved layer data alone.
        guard change.rawValue & NSDocument.ChangeType.changeDiscardable.rawValue == 0 else { return }
        super.updateChangeCount(change)
    }

    func selectLayer(_ index: Int) {
        guard let stack, stack.layers.indices.contains(index), index != stack.active else { return }
        editor?.canvas.finishSelection()
        self.stack?.active = index
        editor?.refreshImage()
    }

    func replaceImage(with replacement: CGImage, actionName: String, in selection: CGRect?) {
        guard var next = stack else { return }
        if let selection, var pixels = next.activeLayer.pdnPixels {
            // Compare renderer output and keep the original straight-alpha bytes for untouched pixels.
            guard let region = replacement.cropping(to: selection),
                  let originalRegion = next.activeLayer.image.cropping(to: selection),
                  let edited = BGRA8.pixels(from: region), let original = BGRA8.pixels(from: originalRegion),
                  edited != original else { return }
            let regionPixelCount = edited.count / 4
            let origin = Int(selection.minY) * replacement.width + Int(selection.minX)
            pixels.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
                edited.withUnsafeBytes { (after: UnsafeRawBufferPointer) in
                    original.withUnsafeBytes { (before: UnsafeRawBufferPointer) in
                        for pixel in 0..<regionPixelCount {
                            let source = pixel * 4
                            let updated = after.loadUnaligned(fromByteOffset: source, as: UInt32.self)
                            guard updated != before.loadUnaligned(fromByteOffset: source, as: UInt32.self) else { continue }
                            let offset = origin + pixel / region.width * replacement.width + pixel % region.width
                            destination.storeBytes(of: updated, toByteOffset: offset * 4, as: UInt32.self)
                        }
                    }
                }
            }
            guard let image = BGRA8.image(from: pixels, width: replacement.width, height: replacement.height) else { return }
            next.layers[next.active].image = image
            next.layers[next.active].pdnPixels = pixels
        } else {
            next.layers[next.active].image = replacement
        }
        applyEdit(replacingStack: next, actionName: actionName)
    }

    @objc func cropSelection(_ sender: Any?) {
        guard let canvas = editor?.canvas, let rect = canvas.cropRect, let outline = canvas.selectionOutline else { return }
        canvas.finishLiveEdit()
        guard var next = stack else { return }
        let mask = outline.pixelRectangle ? nil : outline.mask(in: rect, imageHeight: next.activeLayer.image.height)
        guard outline.pixelRectangle || mask != nil else { return }
        for index in next.layers.indices {
            guard next.layers[index].crop(to: rect, keeping: mask) else { return }
        }
        applyEdit(replacingStack: next, actionName: "Crop to Selection", selectionChange: (outline, nil))
    }

    @objc func copySelection(_ sender: Any?) {
        guard let image, let text = editor?.canvas.copyableOutline?.clipboardText(imageHeight: image.height) else { return }
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        clipboard.setString(text, forType: .string)
    }

    @objc func cut(_ sender: Any?) { copyPixels(to: .general, cutting: true) }
    @objc func copy(_ sender: Any?) { copyPixels(to: .general, cutting: false) }
    @objc func paste(_ sender: Any?) { pastePixels(from: .general) }

    func copyPixels(to clipboard: NSPasteboard, cutting: Bool) {
        guard let canvas = editor?.canvas, canvas.canCopyPixels, let layer = canvas.copyableLayer else { return }
        var copied = layer
        var cutLayer: PaintLayer?
        if let outline = canvas.copyableOutline {
            let bounds = outline.bounds.integral
            let height = layer.image.height
            let region = CGRect(x: bounds.minX, y: CGFloat(height) - bounds.maxY,
                                width: bounds.width, height: bounds.height)
            let mask = outline.pixelRectangle ? nil : outline.mask(in: region, imageHeight: height)
            guard outline.pixelRectangle || mask != nil, copied.crop(to: region, keeping: mask) else { return }
            if cutting {
                guard let source = layer.straightPixels,
                      let cleared = layer.withPixels(layer.clearing(region, mask: mask, from: source)) else { return }
                cutLayer = cleared
            }
        } else if cutting {
            return
        }

        guard let data = try? PaintFiles.pngData(copied.image) else { return }
        clipboard.clearContents()
        guard clipboard.setData(data, forType: .png) else { return }
        if let cutLayer {
            canvas.finishLiveEdit()
            canvas.completeMoveDrag()
            commitSelectedPixelsTransform(cutLayer, to: nil, actionName: "Cut")
        }
    }

    func pastePixels(from clipboard: NSPasteboard) {
        guard let canvas = editor?.canvas, stack?.activeLayer.isVisible == true else { return }
        for type in Self.pixelClipboardTypes {
            if let data = clipboard.data(forType: type), let image = PaintFiles.readClipboardImage(data) {
                canvas.pastePixels(image)
                return
            }
        }
        NSSound.beep()
    }

    @objc func pasteSelection(_ sender: Any?) {
        guard let canvas = editor?.canvas, let outline = clipboardOutline else { return }
        canvas.finishSelection()
        commitSelection(outline, actionName: "Paste Selection")
    }

    private var clipboardOutline: SelectionOutline? {
        guard let image, let text = NSPasteboard.general.string(forType: .string) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        return SelectionOutline(clipboardText: text, imageHeight: image.height)?.clipped(to: bounds)
    }

    @objc func deselect(_ sender: Any?) {
        guard let canvas = editor?.canvas else { return }
        canvas.finishSelection()
        canvas.cancelEditingGesture()
        commitSelection(nil, actionName: "Deselect")
    }

    func addLayer() {
        editor?.canvas.finishSelection()
        guard var next = stack, next.layers.count < LayerStack.limit else { return }
        let image = next.activeLayer.image
        guard let blank = LayerStack.makeBitmap(width: image.width, height: image.height)?.makeImage() else { return }
        let names = Set(next.layers.map(\.name))
        var number = 1
        while names.contains("Layer \(number)") { number += 1 }
        next.active += 1
        next.layers.insert(PaintLayer(name: "Layer \(number)", image: blank), at: next.active)
        applyEdit(replacingStack: next, actionName: "Add Layer")
    }

    func setLayerVisibility(_ visible: Bool, at index: Int) {
        editor?.canvas.finishSelection()
        guard var next = stack, next.layers.indices.contains(index),
              next.layers[index].isVisible != visible else { return }
        next.layers[index].isVisible = visible
        applyEdit(replacingStack: next, actionName: visible ? "Show Layer" : "Hide Layer")
    }

    func moveLayer(by offset: Int) {
        editor?.canvas.finishSelection()
        guard var next = stack, next.layers.indices.contains(next.active + offset) else { return }
        next.layers.swapAt(next.active, next.active + offset)
        next.active += offset
        applyEdit(replacingStack: next, actionName: "Move Layer")
    }

    func deleteLayer() {
        editor?.canvas.finishSelection()
        guard var next = stack, next.layers.count > 1 else { return }
        next.layers.remove(at: next.active)
        next.active = min(next.active, next.layers.count - 1)
        applyEdit(replacingStack: next, actionName: "Delete Layer")
    }

    func duplicateLayer() {
        editor?.canvas.finishSelection()
        guard var next = stack, next.duplicateActiveLayer() else { return }
        applyEdit(replacingStack: next, actionName: LayerCommand.duplicate.title)
    }

    func mergeLayerDown() {
        editor?.canvas.finishSelection()
        guard var next = stack, next.mergeActiveLayerDown() else { return }
        applyEdit(replacingStack: next, actionName: LayerCommand.mergeDown.title)
    }

    private func showImportPanel() {
        editor?.canvas.finishSelection()
        guard let window = windowForSheet, window.attachedSheet == nil, stack?.canDuplicate == true else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, Self.projectContentType]
        panel.allowsMultipleSelection = true
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        panel.prompt = "Import"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            do {
                try self.importLayerFiles(panel.urls)
            } catch {
                self.presentError(error)
            }
        }
    }

    func importLayerFiles(_ urls: [URL]) throws {
        editor?.canvas.finishSelection()
        guard var next = stack, !urls.isEmpty else { return }
        let capacity = LayerStack.limit - next.layers.count
        guard urls.count <= capacity else { throw PDNError.tooLarge }
        var incoming: [PaintLayer] = []
        for url in urls {
            guard incoming.count < capacity else { throw PDNError.tooLarge }
            incoming += try PaintFiles.layersForImport(from: url)
            guard incoming.count <= capacity else { throw PDNError.tooLarge }
        }
        try next.importLayers(incoming)
        applyEdit(replacingStack: next, actionName: "Import From File")
    }

    @objc func flattenLayers(_ sender: Any?) {
        editor?.canvas.finishSelection()
        guard var next = stack, next.layers.count > 1 else { return }
        guard let flat = next.flattenedLayer() else {
            presentError(CocoaError(.fileWriteUnknown))
            return
        }
        next.layers = [flat]
        next.active = 0
        applyEdit(replacingStack: next, actionName: "Flatten")
    }

    func showLayerProperties() {
        editor?.canvas.finishSelection()
        guard let original = stack, let window = windowForSheet, window.attachedSheet == nil,
              let canvas = editor?.canvas else { return }
        let panel = LayerPropertiesPanel(layer: original.activeLayer)
        panel.preview = { [weak canvas] layer in
            var preview = original
            preview.layers[original.active] = layer
            canvas?.layerPreview = preview
        }
        window.beginSheet(panel) { [weak self, weak canvas] response in
            canvas?.layerPreview = nil
            guard response == .OK, let self, var next = self.stack,
                  next.layers.indices.contains(original.active),
                  next.layers[original.active].image === original.activeLayer.image else { return }
            let edited = panel.editedLayer, before = original.activeLayer
            guard edited.name != before.name || edited.isVisible != before.isVisible ||
                  edited.opacity != before.opacity || edited.blendMode != before.blendMode else { return }
            next.layers[original.active] = edited
            self.applyEdit(replacingStack: next, actionName: "Layer Properties")
        }
    }

    func commitSelection(_ outline: SelectionOutline?, actionName: String) {
        guard let canvas = editor?.canvas, canvas.selectionOutline != outline else { return }
        applyEdit(actionName: actionName, selectionChange: (canvas.selectionOutline, outline))
    }

    func commitPaintLayer(_ layer: PaintLayer, actionName: String) {
        guard var next = stack else { return }
        next.layers[next.active] = layer
        applyEdit(replacingStack: next, actionName: actionName)
    }

    func recordMove(from before: CanvasView.MoveSession?, to after: CanvasView.MoveSession, actionName: String) {
        applyEdit(actionName: actionName, moveChange: (before, after))
    }

    func commitSelectedPixelsTransform(_ layer: PaintLayer?, to destination: SelectionOutline?, actionName: String) {
        var replacement: LayerStack?
        if let layer, var next = stack {
            next.layers[next.active] = layer
            replacement = next
        }
        applyEdit(replacingStack: replacement, actionName: actionName,
                  selectionChange: (editor?.canvas.selectionOutline, destination),
                  moveChange: (editor?.canvas.move, nil))
    }

    private func applyEdit(replacingStack replacement: LayerStack? = nil, actionName: String,
                           selectionChange: (before: SelectionOutline?, after: SelectionOutline?)? = nil,
                           moveChange: (before: CanvasView.MoveSession?, after: CanvasView.MoveSession?)? = nil) {
        guard let previous = stack else { return }
        // A single UI event can finish a floating selection and then make another edit.
        let startsGroup = undoManager?.groupingLevel == 0
        if startsGroup { undoManager?.beginUndoGrouping() }
        let previousStack = replacement == nil ? nil : previous
        undoManager?.registerUndo(withTarget: self) { document in
            document.applyEdit(replacingStack: previousStack, actionName: actionName,
                               selectionChange: selectionChange.map { ($0.after, $0.before) },
                               moveChange: moveChange.map { ($0.after, $0.before) })
        }
        undoManager?.setActionName(actionName)
        undoManager?.setActionIsDiscardable(replacement == nil)
        let isUndoing = undoManager?.isUndoing == true
        let isRedoing = undoManager?.isRedoing == true
        if isUndoing {
            historyPosition -= 1
        } else if isRedoing {
            historyPosition += 1
        } else {
            historyEntries.removeLast(historyEntries.count - historyPosition - 1)
            historyEntries.append(actionName)
            historyPosition = historyEntries.count - 1
        }
        if let replacement { stack = replacement }
        if let move = moveChange?.after { stack?.active = move.layerIndex }
        if replacement != nil || previous.active != stack?.active {
            let oldImage = previous.activeLayer.image
            editor?.refreshImage(clearSelection: oldImage.width != image?.width || oldImage.height != image?.height)
        }
        if let selectionChange { editor?.canvas.setSelection(selectionChange.after) }
        editor?.canvas.restoreMove(moveChange?.after)
        if startsGroup { undoManager?.endUndoGrouping() }
        if !isUndoing && !isRedoing { editor?.updateHistory(undoManager) }
    }

    @objc func undoStroke(_ sender: Any?) {
        editor?.canvas.finishLiveEdit()
        editor?.canvas.cancelEditingGesture()
        undoManager?.undo()
        editor?.updateHistory(undoManager)
    }

    @objc func redoStroke(_ sender: Any?) {
        guard editor?.canvas.hasLiveEditChange != true else { return }
        editor?.canvas.cancelEditingGesture()
        undoManager?.redo()
        editor?.updateHistory(undoManager)
    }

    func goToHistoryEntry(_ position: Int) {
        guard historyEntries.indices.contains(position), let undoManager else { return }
        editor?.canvas.cancelEditingGesture()
        if position < historyPosition {
            for _ in position..<historyPosition where undoManager.canUndo { undoManager.undo() }
        } else {
            for _ in historyPosition..<position where undoManager.canRedo { undoManager.redo() }
        }
        editor?.updateHistory(undoManager)
    }

    @objc func toggleUtilityPanel(_ sender: NSMenuItem) {
        if let kind = UtilityPanels.Kind(rawValue: sender.tag) { editor?.togglePanel(kind) }
    }

    @objc func resetUtilityPanels(_ sender: Any?) { editor?.resetPanels() }

    @objc func layerCommand(_ sender: NSMenuItem) {
        guard let command = LayerCommand(rawValue: sender.tag), let stack else { return }
        switch command {
        case .add: addLayer()
        case .selectAbove: selectLayer(stack.active + 1)
        case .selectBelow: selectLayer(stack.active - 1)
        case .toggleVisibility: setLayerVisibility(!stack.activeLayer.isVisible, at: stack.active)
        case .moveUp: moveLayer(by: 1)
        case .moveDown: moveLayer(by: -1)
        case .delete: deleteLayer()
        case .duplicate: duplicateLayer()
        case .mergeDown: mergeLayerDown()
        case .importFromFile: showImportPanel()
        case .properties: showLayerProperties()
        }
    }

    @objc func exportPNG(_ sender: Any?) {
        editor?.canvas.finishSelection()
        guard let window = windowForSheet, let stack else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = fileURL?.deletingPathExtension().lastPathComponent ?? displayName
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                guard let image = stack.flattenedLayer()?.image else { throw CocoaError(.fileWriteUnknown) }
                try PaintFiles.pngData(image).write(to: url, options: .atomic)
            } catch {
                self?.presentError(error)
            }
        }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undoStroke(_:)): return undoManager?.canUndo == true || editor?.canvas.hasLiveEditChange == true
        case #selector(redoStroke(_:)): return undoManager?.canRedo == true && editor?.canvas.hasLiveEditChange != true
        case #selector(cropSelection(_:)): return editor?.canvas.cropRect != nil
        case #selector(copySelection(_:)): return editor?.canvas.copyableOutline != nil
        case #selector(cut(_:)): return editor?.canvas.copyableOutline != nil
        case #selector(copy(_:)): return editor?.canvas.canCopyPixels == true
        case #selector(paste(_:)): return stack?.activeLayer.isVisible == true
            && NSPasteboard.general.availableType(from: Self.pixelClipboardTypes) != nil
        case #selector(pasteSelection(_:)): return clipboardOutline != nil
        case #selector(deselect(_:)):
            guard let canvas = editor?.canvas else { return false }
            return canvas.imageSelection != nil || canvas.hasPendingMove || canvas.hasPendingFloodEdit ||
                canvas.hasPendingGradient
        case #selector(flattenLayers(_:)): return stack.map { $0.layers.count > 1 } ?? false
        case #selector(toggleUtilityPanel(_:)):
            if let menuItem = item as? NSMenuItem, let kind = UtilityPanels.Kind(rawValue: menuItem.tag) {
                menuItem.state = editor?.isPanelShown(kind) == true ? .on : .off
            }
            return editor != nil
        case #selector(layerCommand(_:)):
            guard let stack, let menuItem = item as? NSMenuItem,
                  let command = LayerCommand(rawValue: menuItem.tag) else { return false }
            switch command {
            case .add: return stack.layers.count < LayerStack.limit
            case .selectAbove, .moveUp: return stack.active < stack.layers.count - 1
            case .selectBelow, .moveDown: return stack.active > 0
            case .toggleVisibility:
                menuItem.title = stack.activeLayer.isVisible ? "Hide Layer" : "Show Layer"
                return true
            case .delete: return stack.layers.count > 1
            case .duplicate: return stack.canDuplicate
            case .mergeDown: return stack.canMergeDown
            case .importFromFile: return stack.canDuplicate && windowForSheet?.attachedSheet == nil
            case .properties: return windowForSheet?.attachedSheet == nil
            }
        default: return super.validateUserInterfaceItem(item)
        }
    }

    private static func isProject(_ type: String?) -> Bool {
        type == projectType || type == projectContentType.identifier
    }

    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        [Self.projectType]
    }

    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        if Self.isProject(typeName) { return "pdn" }
        return super.fileNameExtension(forType: typeName, saveOperation: saveOperation)
    }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        guard super.prepareSavePanel(savePanel) else { return false }
        savePanel.allowedContentTypes = [Self.projectContentType]
        savePanel.allowsOtherFileTypes = false
        return true
    }

    override func save(withDelegate delegate: Any?, didSave selector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        editor?.canvas.finishSelection()
        if fileURL != nil && !Self.isProject(fileType) {
            runModalSavePanel(for: .saveAsOperation, delegate: delegate, didSave: selector, contextInfo: contextInfo)
        } else {
            super.save(withDelegate: delegate, didSave: selector, contextInfo: contextInfo)
        }
    }

    override func saveAs(_ sender: Any?) {
        editor?.canvas.finishSelection()
        super.saveAs(sender)
    }

    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?,
                           contextInfo: UnsafeMutableRawPointer?) {
        editor?.canvas.finishSelection()
        super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        if Self.isProject(typeName) {
            stack = try PDNFile.read(data)
        } else if typeName == "PNG Image" || typeName == UTType.png.identifier {
            let image = try PaintFiles.readPNG(data)
            stack = LayerStack(layers: [PaintLayer(name: "Background", image: image, isBackground: true)], active: 0)
        } else {
            throw CocoaError(.fileReadUnknown)
        }
        undoManager?.removeAllActions()
        historyEntries = ["Open Image"]
        historyPosition = 0
        editor?.refreshImage(clearSelection: true)
        editor?.canvas.restoreMove(nil)
        editor?.updateHistory(undoManager)
    }

    override func data(ofType typeName: String) throws -> Data {
        guard let stack, Self.isProject(typeName) else { throw CocoaError(.fileWriteUnknown) }
        return try PDNFile.write(stack)
    }

    override func makeWindowControllers() {
        if stack == nil, let blank = LayerStack.makeBitmap(width: 1024, height: 768)?.makeImage() {
            stack = LayerStack(layers: [PaintLayer(name: "Background", image: blank, isBackground: true)], active: 0)
        }
        undoManager?.levelsOfUndo = 0
        undoManager?.groupsByEvent = false

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        let editor = EditorView(document: self)
        self.editor = editor
        window.contentView = editor
        window.contentMinSize = NSSize(width: 420, height: 420)
        window.initialFirstResponder = editor.canvas
        window.center()
        editor.installPanels(on: window)
        addWindowController(NSWindowController(window: window))
    }
}
