import AppKit

@MainActor
final class WorkspaceDocuments: NSObject {
    static let shared = WorkspaceDocuments()

    @MainActor final class Entry {
        weak var document: PaintDocument?
        weak var window: NSWindow?
        let id = UUID()
        var thumbnail: NSImage?

        init(document: PaintDocument, window: NSWindow) {
            self.document = document
            self.window = window
        }

        var title: String {
            guard let document else { return "" }
            return (document.isDocumentEdited ? "* " : "") + document.displayName
        }
    }

    private(set) var entries: [Entry] = []
    private let strips = NSHashTable<DocumentStrip>.weakObjects()
    private var pendingThumbnails: Set<UUID> = []

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(windowClosed(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowUpdated(_:)),
                                               name: NSWindow.didUpdateNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @discardableResult
    func register(document: PaintDocument, window: NSWindow, strip: DocumentStrip) -> UUID {
        let entry = Entry(document: document, window: window)
        entries.append(entry)
        strip.bind(entry.id)
        strips.add(strip)
        invalidateThumbnail(for: document)
        updateStrips()
        return entry.id
    }

    func activate(_ id: UUID) {
        guard let window = entries.first(where: { $0.id == id })?.window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        if let editor = window.contentView as? EditorView { window.makeFirstResponder(editor.canvas) }
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
        guard let entry = entries.first(where: { $0.document === document }),
              pendingThumbnails.insert(entry.id).inserted else { return }
        // Coalesce multiple changes from editing and invalidation in the same run-loop turn.
        DispatchQueue.main.async { [weak self, weak entry] in
            guard let self, let entry, pendingThumbnails.remove(entry.id) != nil,
                  let stack = entry.document?.stack else { return }
            entry.thumbnail = Self.thumbnail(of: stack)
            updateStrips()
        }
    }

    private static func thumbnail(of stack: LayerStack) -> NSImage? {
        let source = stack.activeLayer.image
        let aspect = CGFloat(source.width) / CGFloat(source.height)
        let size = NSSize(width: max(1, min(96, 48 * aspect).rounded()), height: max(1, min(48, 96 / aspect).rounded()))
        let frame = CGRect(origin: .zero, size: size)
        guard let bitmap = LayerStack.makeBitmap(width: Int(size.width), height: Int(size.height)) else { return nil }
        bitmap.interpolationQuality = .high
        if stack.needsBlendComposite {
            guard let composite = stack.blendComposite()?.image else { return nil }
            bitmap.draw(composite, in: frame)
        } else {
            stack.draw(in: bitmap, rect: frame)
        }
        return bitmap.makeImage().map { NSImage(cgImage: $0, size: size) }
    }

    private func updateStrips() {
        for strip in strips.allObjects { strip.show(entries) }
    }

    @objc private func windowClosed(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let index = entries.firstIndex(where: { $0.window === window }) else { return }
        pendingThumbnails.remove(entries.remove(at: index).id)
        updateStrips()
    }

    @objc private func windowUpdated(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let entry = entries.first(where: { $0.window === window }) else { return }
        for strip in strips.allObjects { strip.update(entry) }
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
