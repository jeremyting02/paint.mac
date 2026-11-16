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
    private(set) var stack: LayerStack?
    var image: CGImage? { stack?.activeLayer.image }
    private weak var editor: EditorView?
    private let undoLimit = 5
    private(set) var historyEntries = ["New Image"]
    private(set) var historyPosition = 0

    func selectLayer(_ index: Int) {
        guard let stack, stack.layers.indices.contains(index), index != stack.active else { return }
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
        replaceStack(with: next, actionName: actionName)
    }

    @objc func cropSelection(_ sender: Any?) {
        guard let rect = editor?.canvas.cropRect, var next = stack else { return }
        for index in next.layers.indices {
            guard next.layers[index].crop(to: rect) else { return }
        }
        replaceStack(with: next, actionName: "Crop to Selection")
    }

    func addLayer() {
        guard var next = stack, next.layers.count < LayerStack.limit else { return }
        let image = next.activeLayer.image
        guard let blank = LayerStack.makeBitmap(width: image.width, height: image.height)?.makeImage() else { return }
        let names = Set(next.layers.map(\.name))
        var number = 1
        while names.contains("Layer \(number)") { number += 1 }
        next.active += 1
        next.layers.insert(PaintLayer(name: "Layer \(number)", image: blank), at: next.active)
        replaceStack(with: next, actionName: "Add Layer")
    }

    func setLayerVisibility(_ visible: Bool, at index: Int) {
        guard var next = stack, next.layers.indices.contains(index),
              next.layers[index].isVisible != visible else { return }
        next.layers[index].isVisible = visible
        replaceStack(with: next, actionName: visible ? "Show Layer" : "Hide Layer")
    }

    func moveLayer(by offset: Int) {
        guard var next = stack, next.layers.indices.contains(next.active + offset) else { return }
        next.layers.swapAt(next.active, next.active + offset)
        next.active += offset
        replaceStack(with: next, actionName: "Move Layer")
    }

    func deleteLayer() {
        guard var next = stack, next.layers.count > 1 else { return }
        next.layers.remove(at: next.active)
        next.active = min(next.active, next.layers.count - 1)
        replaceStack(with: next, actionName: "Delete Layer")
    }

    func duplicateLayer() {
        guard var next = stack, next.duplicateActiveLayer() else { return }
        replaceStack(with: next, actionName: LayerCommand.duplicate.title)
    }

    func mergeLayerDown() {
        guard var next = stack, next.mergeActiveLayerDown() else { return }
        replaceStack(with: next, actionName: LayerCommand.mergeDown.title)
    }

    private func showImportPanel() {
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
        replaceStack(with: next, actionName: "Import From File")
    }

    @objc func flattenLayers(_ sender: Any?) {
        guard var next = stack, next.layers.count > 1 else { return }
        guard let flat = next.flattenedLayer() else {
            presentError(CocoaError(.fileWriteUnknown))
            return
        }
        next.layers = [flat]
        next.active = 0
        replaceStack(with: next, actionName: "Flatten")
    }

    func showLayerProperties() {
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
            self.replaceStack(with: next, actionName: "Layer Properties")
        }
    }

    func commitSelectedPixelsTransform(_ layer: PaintLayer, from source: CGRect, to destination: CGRect, actionName: String) {
        guard var next = stack else { return }
        next.layers[next.active] = layer
        replaceStack(with: next, actionName: actionName, selectionChange: (source, destination))
    }

    private func replaceStack(with replacement: LayerStack, actionName: String,
                              selectionChange: (before: CGRect, after: CGRect)? = nil) {
        guard let previous = stack else { return }
        undoManager?.registerUndo(withTarget: self) { document in
            document.replaceStack(with: previous, actionName: actionName,
                                  selectionChange: selectionChange.map { ($0.after, $0.before) })
        }
        undoManager?.setActionName(actionName)
        if undoManager?.isUndoing == true {
            historyPosition -= 1
        } else if undoManager?.isRedoing == true {
            historyPosition += 1
        } else {
            historyEntries = Array(historyEntries.prefix(historyPosition + 1)) + [actionName]
            if historyEntries.count > undoLimit + 1 { historyEntries.removeFirst() }
            historyPosition = historyEntries.count - 1
        }
        stack = replacement
        let oldImage = previous.activeLayer.image, newImage = replacement.activeLayer.image
        editor?.refreshImage(clearSelection: oldImage.width != newImage.width || oldImage.height != newImage.height)
        if let selectionChange { editor?.canvas.setSelection(selectionChange.after) }
        editor?.updateHistory(undoManager)
    }

    @objc func undoStroke(_ sender: Any?) {
        undoManager?.undo()
        editor?.updateHistory(undoManager)
    }

    @objc func redoStroke(_ sender: Any?) {
        undoManager?.redo()
        editor?.updateHistory(undoManager)
    }

    func goToHistoryEntry(_ position: Int) {
        if position < historyPosition {
            for _ in position..<historyPosition where undoManager?.canUndo == true { undoStroke(nil) }
        } else {
            for _ in historyPosition..<position where undoManager?.canRedo == true { redoStroke(nil) }
        }
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
        case #selector(undoStroke(_:)): return undoManager?.canUndo == true
        case #selector(redoStroke(_:)): return undoManager?.canRedo == true
        case #selector(cropSelection(_:)): return editor?.canvas.cropRect != nil
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
        if fileURL != nil && !Self.isProject(fileType) {
            runModalSavePanel(for: .saveAsOperation, delegate: delegate, didSave: selector, contextInfo: contextInfo)
        } else {
            super.save(withDelegate: delegate, didSave: selector, contextInfo: contextInfo)
        }
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
        undoManager?.levelsOfUndo = undoLimit

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
