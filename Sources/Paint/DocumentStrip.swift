import AppKit

@MainActor
final class WorkspaceDocuments: NSObject {
    static let shared = WorkspaceDocuments()

    @MainActor final class Entry {
        weak var document: PaintDocument?
        let id = UUID()
        var thumbnail: NSImage?
        var thumbnailRevision = 0

        init(document: PaintDocument) {
            self.document = document
        }

        var title: String {
            guard let document else { return "" }
            return (document.isDocumentEdited ? "* " : "") + document.displayName
        }
    }

    private(set) var entries: [Entry] = []
    private let strips = NSHashTable<DocumentStrip>.weakObjects()
    private var pendingThumbnails: Set<UUID> = []
    private let thumbnailQueue = DispatchQueue(label: "paint.mac.thumbnails", qos: .utility)
    private var controller: NSWindowController?
    private var pendingActivation: UUID?
    private var isConfirmingClose = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(windowUpdated(_:)),
                                               name: NSWindow.didUpdateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sheetEnded(_:)),
                                               name: NSWindow.didEndSheetNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func show(_ document: PaintDocument) {
        guard let strip = document.editor?.documentStrip else { return }
        if let entry = entries.first(where: { $0.document === document }) {
            activate(entry.id)
            return
        }
        let entry = Entry(document: document)
        entries.append(entry)
        strip.bind(entry.id)
        strips.add(strip)
        invalidateThumbnail(for: document)
        updateStrips()
        activate(entry.id)
    }

    func activate(_ id: UUID) {
        guard let document = entries.first(where: { $0.id == id })?.document else { return }
        if controller?.window?.attachedSheet != nil || isConfirmingClose {
            pendingActivation = id
            return
        }
        pendingActivation = nil
        display(document)?.makeKeyAndOrderFront(nil)
    }

    private func display(_ document: PaintDocument) -> NSWindow? {
        guard let editor = document.editor else { return nil }
        let controller = controller ?? makeWindowController()
        guard let window = controller.window else { return nil }
        if controller.document as? PaintDocument !== document {
            (window.contentView as? EditorView)?.setWorkspaceActive(false)
            window.contentView = editor
            // AppKit transfers ownership, including document commands and the window title.
            document.addWindowController(controller)
            editor.installPanels(on: window)
            editor.setWorkspaceActive(true)
            window.initialFirstResponder = editor.canvas
            window.makeFirstResponder(editor.canvas)
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        return window
    }

    private func makeWindowController() -> NSWindowController {
        let window = WorkspaceWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.workspace = self
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 420, height: 420)
        window.center()
        let controller = NSWindowController(window: window)
        self.controller = controller
        return controller
    }

    fileprivate func closeActiveTab() {
        guard !isConfirmingClose, let controller, controller.window?.attachedSheet == nil,
              let document = controller.document as? PaintDocument else { return }
        isConfirmingClose = true
        document.canClose(withDelegate: self, shouldClose: #selector(tabCanClose(_:shouldClose:contextInfo:)),
                          contextInfo: nil)
    }

    @objc private func tabCanClose(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        isConfirmingClose = false
        if shouldClose { document.close() }
        if let pendingActivation { activate(pendingActivation) }
    }

    func remove(_ document: PaintDocument) {
        guard let index = entries.firstIndex(where: { $0.document === document }) else { return }
        let id = entries.remove(at: index).id
        pendingThumbnails.remove(id)
        if pendingActivation == id { pendingActivation = nil }
        if controller?.document as? PaintDocument === document {
            if let next = entries.isEmpty ? nil : entries[min(index, entries.count - 1)].document {
                _ = display(next)
            } else {
                // Let NSDocument close the workspace window along with the last tab.
                controller = nil
            }
        }
        updateStrips()
    }

    func reorder(_ source: UUID, before successor: UUID?) {
        guard source != successor, let index = entries.firstIndex(where: { $0.id == source }),
              successor == nil || entries.contains(where: { $0.id == successor }) else { return }
        let entry = entries.remove(at: index)
        let destination = entries.firstIndex(where: { $0.id == successor }) ?? entries.endIndex
        entries.insert(entry, at: destination)
        updateStrips()
    }

    func invalidateThumbnail(for document: PaintDocument) {
        guard let entry = entries.first(where: { $0.document === document }) else { return }
        entry.thumbnailRevision += 1
        scheduleThumbnail(for: entry)
    }

    private func scheduleThumbnail(for entry: Entry) {
        guard pendingThumbnails.insert(entry.id).inserted else { return }
        // Let a burst of edits settle and keep one snapshot in flight per document.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(125)) { [weak self, weak entry] in
            guard let self, let entry, pendingThumbnails.contains(entry.id) else { return }
            guard let document = entry.document, let stack = document.stack else {
                pendingThumbnails.remove(entry.id)
                return
            }
            let revision = entry.thumbnailRevision
            let composite = document.editor?.canvas.cachedCommittedComposite
            let metal = document.editor?.canvas.cachedMetalComposite
            thumbnailQueue.async { [weak self, weak entry] in
                let thumbnail = Self.thumbnail(of: stack, composite: composite, metal: metal)
                DispatchQueue.main.async { [weak self, weak entry] in
                    guard let self, let entry, pendingThumbnails.remove(entry.id) != nil else { return }
                    if entry.thumbnailRevision == revision {
                        entry.thumbnail = thumbnail.map { NSImage(cgImage: $0, size: .zero) }
                        updateStrips()
                    } else {
                        scheduleThumbnail(for: entry)
                    }
                }
            }
        }
    }

    private nonisolated static func thumbnail(of stack: LayerStack, composite: CGImage?, metal: MetalMovePreview?) -> CGImage? {
        let source = stack.activeLayer.image
        let aspect = CGFloat(source.width) / CGFloat(source.height)
        let size = NSSize(width: max(1, min(96, 48 * aspect).rounded()), height: max(1, min(48, 96 / aspect).rounded()))
        if composite == nil, let image = metal?.renderViewport(
            in: CGRect(x: 0, y: 0, width: source.width, height: source.height), size: size
        ) { return image }
        let frame = CGRect(origin: .zero, size: size)
        guard let bitmap = LayerStack.makeBitmap(width: Int(size.width), height: Int(size.height)) else { return nil }
        bitmap.interpolationQuality = .high
        if let composite {
            bitmap.draw(composite, in: frame)
        } else if stack.needsBlendComposite {
            guard let image = stack.blendComposite()?.image else { return nil }
            bitmap.draw(image, in: frame)
        } else {
            stack.draw(in: bitmap, rect: frame)
        }
        return bitmap.makeImage()
    }

    private func updateStrips() {
        for strip in strips.allObjects { strip.show(entries) }
    }

    @objc private func sheetEnded(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === controller?.window,
              pendingActivation != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let pendingActivation else { return }
            activate(pendingActivation)
        }
    }

    @objc private func windowUpdated(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === controller?.window,
              let document = controller?.document as? PaintDocument,
              let entry = entries.first(where: { $0.document === document }) else { return }
        for strip in strips.allObjects { strip.update(entry) }
    }
}

private final class WorkspaceWindow: NSWindow {
    weak var workspace: WorkspaceDocuments?

    override func performClose(_ sender: Any?) {
        workspace?.closeActiveTab()
    }
}

@MainActor
final class DocumentStrip: NSScrollView {
    private let workspace: WorkspaceDocuments
    private let documentArea = NSView()
    private let buttons = NSStackView()
    private var entries: [UUID] = []
    private var tabs: [UUID: Tab] = [:]
    private(set) var currentDocument: UUID?

    convenience init() { self.init(workspace: .shared) }

    init(workspace: WorkspaceDocuments) {
        self.workspace = workspace
        super.init(frame: .zero)
        drawsBackground = false
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        setAccessibilityLabel("Open Images")
        buttons.spacing = 4
        buttons.alignment = .centerY
        buttons.translatesAutoresizingMaskIntoConstraints = false
        documentArea.addSubview(buttons)
        documentView = documentArea
        NSLayoutConstraint.activate([
            buttons.leadingAnchor.constraint(equalTo: documentArea.leadingAnchor),
            buttons.centerYAnchor.constraint(equalTo: documentArea.centerYAnchor)
        ])
        registerForDraggedTypes([Tab.pasteboardType])
    }

    required init?(coder: NSCoder) { nil }

    func bind(_ id: UUID) { currentDocument = id }

    func show(_ entries: [WorkspaceDocuments.Entry]) {
        let newOrder = entries.map(\.id)
        if self.entries != newOrder {
            for tab in buttons.arrangedSubviews { tab.removeFromSuperview() }
            tabs = tabs.filter { newOrder.contains($0.key) }
            self.entries = newOrder
            for id in newOrder {
                let tab = tabs[id] ?? Tab(id: id, target: self, action: #selector(openDocument(_:)))
                tabs[id] = tab
                buttons.addArrangedSubview(tab)
            }
            documentArea.setFrameSize(CGSize(width: buttons.fittingSize.width, height: 30))
            layoutSubtreeIfNeeded()
            if let currentDocument, let tab = tabs[currentDocument] { buttons.scrollToVisible(tab.frame) }
        }
        for entry in entries { update(entry) }
    }

    func update(_ entry: WorkspaceDocuments.Entry) {
        guard let tab = tabs[entry.id] else { return }
        let title = entry.title
        if tab.title != title {
            tab.title = title
            tab.toolTip = title
            tab.setAccessibilityLabel(title)
        }
        if tab.image !== entry.thumbnail { tab.image = entry.thumbnail }
        let selected = entry.id == currentDocument
        if (tab.state == .on) != selected {
            tab.state = selected ? .on : .off
        }
    }

    @objc private func openDocument(_ sender: Tab) { workspace.activate(sender.id) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingSource is Tab ? .move : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard sender.draggingSource is Tab,
              let value = sender.draggingPasteboard.string(forType: Tab.pasteboardType),
              let id = UUID(uuidString: value), entries.contains(id) else { return false }
        let x = buttons.convert(sender.draggingLocation, from: nil).x
        let successor = entries.first { key in key != id && (tabs[key]?.frame.midX ?? 0) > x }
        workspace.reorder(id, before: successor)
        return true
    }

    private final class Tab: NSButton, NSDraggingSource {
        static let pasteboardType = NSPasteboard.PasteboardType("com.paintmac.document-tab")
        let id: UUID

        init(id: UUID, target: DocumentStrip, action: Selector) {
            self.id = id
            super.init(frame: .zero)
            self.target = target
            self.action = action
            setButtonType(.onOff)
            bezelStyle = .recessed
            imagePosition = .imageLeft
            imageScaling = .scaleProportionallyDown
            lineBreakMode = .byTruncatingTail
            font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            widthAnchor.constraint(equalToConstant: 106).isActive = true
            heightAnchor.constraint(equalToConstant: 28).isActive = true
        }

        required init?(coder: NSCoder) { nil }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
                if next.type == .leftMouseUp {
                    if bounds.contains(convert(next.locationInWindow, from: nil)) { sendAction(action, to: target) }
                    return
                }
                let distance = hypot(next.locationInWindow.x - event.locationInWindow.x,
                                     next.locationInWindow.y - event.locationInWindow.y)
                if distance >= 4 {
                    let pasteboard = NSPasteboardItem()
                    pasteboard.setString(id.uuidString, forType: Self.pasteboardType)
                    let item = NSDraggingItem(pasteboardWriter: pasteboard)
                    item.setDraggingFrame(bounds, contents: image)
                    beginDraggingSession(with: [item], event: next, source: self)
                    return
                }
            }
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }
    }
}
