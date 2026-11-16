import AppKit
import ImageIO
import UniformTypeIdentifiers

@objc(PaintDocument)
final class PaintDocument: NSDocument {
    private(set) var image: CGImage?
    private weak var editor: EditorView?

    static func makeBitmap(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    func replaceImage(with replacement: CGImage, actionName: String) {
        guard let previous = image else { return }
        undoManager?.registerUndo(withTarget: self) { document in
            document.replaceImage(with: previous, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        image = replacement
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

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undoStroke(_:)): return undoManager?.canUndo == true
        case #selector(redoStroke(_:)): return undoManager?.canRedo == true
        default: return super.validateUserInterfaceItem(item)
        }
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let corrupt = CocoaError(.fileReadCorruptFile, userInfo: [
            NSLocalizedDescriptionKey: "The file could not be read as a static PNG image."
        ])
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw corrupt }

        guard width <= 4096, height <= 4096, width * height <= 8_388_608 else {
            throw CocoaError(.fileReadTooLarge, userInfo: [
                NSLocalizedDescriptionKey: "PNG images can be at most 4,096 pixels per side and 8,388,608 pixels total."
            ])
        }

        guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw corrupt }
        image = decoded
    }

    override func data(ofType typeName: String) throws -> Data {
        let bytes = NSMutableData()
        guard let image,
              let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return bytes as Data
    }

    override func makeWindowControllers() {
        if image == nil {
            image = Self.makeBitmap(width: 1024, height: 768)?.makeImage()
        }
        undoManager?.levelsOfUndo = 5

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        let editor = EditorView(document: self)
        self.editor = editor
        window.contentView = editor
        window.contentMinSize = NSSize(width: 420, height: 300)
        window.initialFirstResponder = editor.canvas
        window.center()
        addWindowController(NSWindowController(window: window))
    }
}
