import AppKit
import UniformTypeIdentifiers

@objc(PaintDocument)
final class PaintDocument: NSDocument {
    enum LayerCommand: Int, CaseIterable {
        case add, selectAbove, selectBelow, toggleVisibility, moveUp, moveDown, delete

        var title: String {
            ["Add Layer", "Select Layer Above", "Select Layer Below", "Show Layer",
             "Move Layer Up", "Move Layer Down", "Delete Layer"][rawValue]
        }
    }

    static let projectType = "paint.mac Project"
    private static let projectContentType = UTType(exportedAs: "local.paintmac.project")
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

    func replaceImage(with replacement: CGImage, actionName: String) {
        guard var next = stack else { return }
        next.layers[next.active].image = replacement
        replaceStack(with: next, actionName: actionName)
    }

    func crop(to rect: CGRect) {
        guard var next = stack else { return }
        for index in next.layers.indices {
            guard let cropped = next.layers[index].image.cropping(to: rect) else { return }
            next.layers[index].image = cropped
        }
        replaceStack(with: next, actionName: "Crop")
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

    private func replaceStack(with replacement: LayerStack, actionName: String) {
        guard let previous = stack else { return }
        undoManager?.registerUndo(withTarget: self) { document in
            document.replaceStack(with: previous, actionName: actionName)
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
        editor?.refreshImage()
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
                guard let image = stack.flattened() else { throw CocoaError(.fileWriteUnknown) }
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
            }
        default: return super.validateUserInterfaceItem(item)
        }
    }

    private static func isProject(_ type: String?) -> Bool {
        type == projectType || type == projectContentType.identifier
    }

    private var savesAsProject: Bool { Self.isProject(fileType) || stack?.needsProject == true }

    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        if savesAsProject { return [Self.projectType] }
        return super.writableTypes(for: saveOperation)
    }

    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        if Self.isProject(typeName) { return "paintmac" }
        return super.fileNameExtension(forType: typeName, saveOperation: saveOperation)
    }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        guard super.prepareSavePanel(savePanel) else { return false }
        if savesAsProject {
            savePanel.allowedContentTypes = [Self.projectContentType]
            savePanel.allowsOtherFileTypes = false
        }
        return true
    }

    override func save(withDelegate delegate: Any?, didSave selector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        if stack?.needsProject == true && !Self.isProject(fileType) {
            runModalSavePanel(for: .saveAsOperation, delegate: delegate, didSave: selector, contextInfo: contextInfo)
        } else {
            super.save(withDelegate: delegate, didSave: selector, contextInfo: contextInfo)
        }
    }

    override func read(from data: Data, ofType typeName: String) throws {
        if Self.isProject(typeName) {
            stack = try PaintFiles.readProject(data)
        } else {
            stack = LayerStack(layers: [PaintLayer(name: "Background", image: try PaintFiles.readPNG(data))], active: 0)
        }
        undoManager?.removeAllActions()
        historyEntries = ["Open Image"]
        historyPosition = 0
        editor?.refreshImage()
        editor?.updateHistory(undoManager)
    }

    override func data(ofType typeName: String) throws -> Data {
        guard let stack else { throw CocoaError(.fileWriteUnknown) }
        if Self.isProject(typeName) { return try PaintFiles.projectData(stack) }
        guard !stack.needsProject else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "Save a paint.mac project to keep the layers, or use Export PNG to flatten them."
            ])
        }
        return try PaintFiles.pngData(stack.activeLayer.image)
    }

    override func makeWindowControllers() {
        if stack == nil, let blank = LayerStack.makeBitmap(width: 1024, height: 768)?.makeImage() {
            stack = LayerStack(layers: [PaintLayer(name: "Background", image: blank)], active: 0)
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
