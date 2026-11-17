import AppKit

@MainActor
final class UtilityPanels: NSObject, NSWindowDelegate {
    enum Kind: Int, CaseIterable {
        case tools, history, layers, colors

        var title: String { ["Tools", "History", "Layers", "Colors"][rawValue] }
        var symbol: String { ["paintbrush", "clock.arrow.circlepath", "square.3.layers.3d", "paintpalette"][rawValue] }
        var keyEquivalent: String { String(UnicodeScalar(Int(NSF5FunctionKey) + rawValue)!) }
        var size: CGSize {
            switch self {
            case .tools: return CGSize(width: 76, height: 246)
            case .history: return CGSize(width: 160, height: 172)
            case .layers: return CGSize(width: 224, height: 151)
            case .colors: return ColorsView.panelSize(expanded: false)
            }
        }
    }

    struct Placement {
        let fromLeft: Bool
        let fromTop: Bool
        let inset: CGPoint

        init(fromLeft: Bool, fromTop: Bool, inset: CGPoint) {
            self.fromLeft = fromLeft
            self.fromTop = fromTop
            self.inset = inset
        }

        init(panel: CGRect, in frame: CGRect) {
            let left = panel.minX - frame.minX
            let right = frame.maxX - panel.maxX
            let top = frame.maxY - panel.maxY
            let bottom = panel.minY - frame.minY
            let fromLeft = abs(left) <= abs(right)
            let fromTop = abs(top) <= abs(bottom)
            self.init(fromLeft: fromLeft, fromTop: fromTop,
                      inset: CGPoint(x: fromLeft ? left : right, y: fromTop ? top : bottom))
        }

        func origin(for size: CGSize, in frame: CGRect) -> CGPoint {
            let x = fromLeft ? frame.minX + inset.x : frame.maxX - size.width - inset.x
            let y = fromTop ? frame.maxY - size.height - inset.y : frame.minY + inset.y
            return CGPoint(x: x, y: y)
        }

        @MainActor func apply(to panel: NSPanel, in frame: CGRect) {
            let panelFrame = panel.frame
            let origin = origin(for: panelFrame.size, in: frame)
            if panelFrame.origin != origin { panel.setFrameOrigin(origin) }
        }
    }

    private final class TopAlignedPanelContent: NSView {
        override var isFlipped: Bool { true }
    }

    private weak var parent: NSWindow?
    private var panels: [Kind: NSPanel] = [:]
    private var placements: [Kind: Placement] = [:]
    private var panelMoveStartFrames: [Kind: CGRect] = [:]
    private var isLayingOutPanels = false
    private var needsResizeLayout = false
    private var shown = Set(Kind.allCases)
    var isWorkspaceActive = false {
        didSet { if oldValue != isWorkspaceActive { updateVisibility() } }
    }
    var visibilityDidChange: (() -> Void)?

    init(parent: NSWindow, colorsSize: CGSize, contents: [Kind: NSView]) {
        self.parent = parent
        super.init()

        for (kind, content) in contents {
            let panel = NSPanel(contentRect: CGRect(origin: .zero, size: kind == .colors ? colorsSize : kind.size),
                                styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.title = kind.title
            panel.isFloatingPanel = false
            panel.level = .normal
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.isExcludedFromWindowsMenu = true
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = .fullScreenAuxiliary
            panel.delegate = self

            let body = NSView()
            let child = kind == .tools ? scrollableTools(content) : content
            child.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(child)
            NSLayoutConstraint.activate([
                child.topAnchor.constraint(equalTo: body.topAnchor, constant: 8),
                child.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 8),
                child.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -8),
                kind == .history || kind == .tools
                    ? child.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -8)
                    : child.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor, constant: -8)
            ])
            panel.contentView = body
            panels[kind] = panel
        }

        resetPositions()
        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(parentResized(_:)), name: name, object: parent)
        }
        for name in [NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(parentChanged(_:)), name: name, object: parent)
        }
        updateVisibility()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func scrollableTools(_ content: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        let container = TopAlignedPanelContent(frame: CGRect(origin: .zero, size: content.fittingSize))
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        scroll.documentView = container
        return scroll
    }

    func isShown(_ kind: Kind) -> Bool { shown.contains(kind) }

    func toggle(_ kind: Kind) {
        if shown.remove(kind) == nil { shown.insert(kind) }
        updateVisibility()
    }

    func resetPositions() {
        for kind in Kind.allCases { resetPosition(kind) }
    }

    func resetColorsPosition() {
        resetPosition(.colors)
        shown.insert(.colors)
        updateVisibility()
    }

    private func resetPosition(_ kind: Kind) {
        guard let panel = panels[kind], let frame = parent?.frame else { return }
        panelMoveStartFrames.removeValue(forKey: kind)
        let left = kind == .tools || kind == .colors
        let top = kind == .tools || kind == .history
        placements[kind] = Placement(fromLeft: left, fromTop: top, inset: CGPoint(x: 8, y: top ? 100 : 34))
        isLayingOutPanels = true
        defer { isLayingOutPanels = false }
        resizeTopPanel(panel, kind: kind, ownerHeight: frame.height)
        placements[kind]?.apply(to: panel, in: frame)
    }

    func resizeColors(to size: CGSize) {
        guard let frame = parent?.frame, let panel = panels[.colors] else { return }
        panelMoveStartFrames.removeValue(forKey: .colors)
        panelMoveStartFrames.removeValue(forKey: .tools)
        isLayingOutPanels = true
        defer { isLayingOutPanels = false }
        panel.setContentSize(size)
        placements[.colors]?.apply(to: panel, in: frame)
        if let tools = panels[.tools] {
            resizeTopPanel(tools, kind: .tools, ownerHeight: frame.height)
            placements[.tools]?.apply(to: tools, in: frame)
        }
    }

    func windowWillMove(_ notification: Notification) {
        guard !isLayingOutPanels, let parent, !parent.inLiveResize,
              let panel = notification.object as? NSPanel, panel.parent === parent,
              let kind = panels.first(where: { $0.value === panel })?.key else { return }
        panelMoveStartFrames[kind] = parent.frame
    }

    func windowDidMove(_ notification: Notification) {
        guard !isLayingOutPanels, let parent, !parent.inLiveResize,
              let panel = notification.object as? NSPanel, panel.parent === parent,
              let kind = panels.first(where: { $0.value === panel })?.key,
              let frame = panelMoveStartFrames[kind] else { return }
        guard frame == parent.frame else {
            panelMoveStartFrames.removeValue(forKey: kind)
            return
        }
        placements[kind] = Placement(panel: panel.frame, in: frame)
    }

    @objc private func parentResized(_ notification: Notification) {
        panelMoveStartFrames.removeAll()
        guard !needsResizeLayout else { return }
        needsResizeLayout = true
        // A left or bottom resize also moves the owner's origin. Let AppKit finish moving its
        // child windows before placing them relative to the new edges.
        RunLoop.main.perform(inModes: [.common, .eventTracking]) { [weak self] in
            MainActor.assumeIsolated { self?.layoutAfterResize() }
        }
    }

    private func layoutAfterResize() {
        needsResizeLayout = false
        guard let frame = parent?.frame else { return }
        isLayingOutPanels = true
        defer { isLayingOutPanels = false }
        for (kind, panel) in panels {
            resizeTopPanel(panel, kind: kind, ownerHeight: frame.height)
            placements[kind]?.apply(to: panel, in: frame)
        }
    }

    static func topContentHeight(ownerHeight: CGFloat, lowerPanelHeight: CGFloat,
                                 chromeHeight: CGFloat, preferredHeight: CGFloat, minimumHeight: CGFloat = 88) -> CGFloat {
        min(preferredHeight, max(minimumHeight, ownerHeight - 100 - 34 - 8 - lowerPanelHeight - chromeHeight))
    }

    private func resizeTopPanel(_ panel: NSPanel, kind: Kind, ownerHeight: CGFloat) {
        guard kind == .tools || kind == .history,
              let lower = panels[kind == .tools ? .colors : .layers],
              let content = panel.contentView else { return }
        let height = Self.topContentHeight(ownerHeight: ownerHeight, lowerPanelHeight: lower.frame.height,
                                          chromeHeight: panel.frame.height - content.frame.height,
                                          preferredHeight: kind.size.height, minimumHeight: kind == .tools ? 56 : 88)
        if abs(content.frame.height - height) >= 1 {
            panel.setContentSize(CGSize(width: kind.size.width, height: height))
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let kind = panels.first(where: { $0.value === sender })?.key {
            shown.remove(kind)
            updateVisibility()
        }
        return false
    }

    @objc private func parentChanged(_ notification: Notification) {
        if notification.name == NSWindow.willCloseNotification {
            for panel in panels.values { panel.orderOut(nil) }
            parent = nil
        } else {
            updateVisibility()
        }
    }

    private func updateVisibility() {
        guard let parent else { return }
        let frame = parent.frame
        let canShow = isWorkspaceActive && parent.isMainWindow && parent.isVisible
            && !parent.isMiniaturized && parent.occlusionState.contains(.visible)
        for (kind, panel) in panels {
            if canShow && shown.contains(kind) {
                guard panel.parent == nil, let placement = placements[kind] else { continue }
                placement.apply(to: panel, in: frame)
                parent.addChildWindow(panel, ordered: .above)
            } else if panel.parent === parent {
                panelMoveStartFrames.removeValue(forKey: kind)
                panel.orderOut(nil)
            }
        }
        visibilityDidChange?()
    }
}
