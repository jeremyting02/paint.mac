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
            case .colors: return CGSize(width: 224, height: 104)
            }
        }
    }

    struct Placement {
        let fromLeft: Bool
        let fromTop: Bool
        let inset: CGPoint
        var lastOrigin: CGPoint?

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

        @MainActor mutating func apply(to panel: NSPanel, in frame: CGRect) {
            let panelFrame = panel.frame
            let origin = origin(for: panelFrame.size, in: frame)
            if panelFrame.origin != origin { panel.setFrameOrigin(origin) }
            lastOrigin = panel.frame.origin
        }
    }

    private final class TopAlignedPanelContent: NSView {
        override var isFlipped: Bool { true }
    }

    private weak var parent: NSWindow?
    private var panels: [Kind: NSPanel] = [:]
    private var placements: [Kind: Placement] = [:]
    private var parentFrame: CGRect = .zero
    private var shown = Set(Kind.allCases)
    var visibilityDidChange: (() -> Void)?

    init(parent: NSWindow, contents: [Kind: NSView]) {
        self.parent = parent
        super.init()

        for (kind, content) in contents {
            let panel = NSPanel(contentRect: CGRect(origin: .zero, size: kind.size),
                                styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.title = kind.title
            panel.isFloatingPanel = true
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
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(parentFrameChanged(_:)), name: name, object: parent)
        }
        for name in [NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
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
        guard let parent else { return }
        parentFrame = parent.frame
        for (kind, panel) in panels {
            let left = kind == .tools || kind == .colors
            let top = kind == .tools || kind == .history
            var placement = Placement(fromLeft: left, fromTop: top, inset: CGPoint(x: 8, y: top ? 100 : 34))
            resizeTopPanel(panel, kind: kind, ownerHeight: parentFrame.height)
            placement.apply(to: panel, in: parentFrame)
            placements[kind] = placement
        }
    }

    @objc private func parentFrameChanged(_ notification: Notification) {
        guard let frame = parent?.frame, frame != parentFrame else { return }
        for (kind, panel) in panels {
            guard var placement = placements[kind] else { continue }
            // Read manual moves when the owner changes geometry so dragging a panel stays native.
            if panel.frame.origin != placement.lastOrigin {
                placement = Placement(panel: panel.frame, in: parentFrame)
            }
            resizeTopPanel(panel, kind: kind, ownerHeight: frame.height)
            placement.apply(to: panel, in: frame)
            placements[kind] = placement
        }
        parentFrame = frame
    }

    static func topContentHeight(ownerHeight: CGFloat, lowerPanelHeight: CGFloat,
                                 chromeHeight: CGFloat, preferredHeight: CGFloat) -> CGFloat {
        min(preferredHeight, max(88, ownerHeight - 100 - 34 - 8 - lowerPanelHeight - chromeHeight))
    }

    private func resizeTopPanel(_ panel: NSPanel, kind: Kind, ownerHeight: CGFloat) {
        guard kind == .tools || kind == .history,
              let lower = panels[kind == .tools ? .colors : .layers],
              let content = panel.contentView else { return }
        let height = Self.topContentHeight(ownerHeight: ownerHeight, lowerPanelHeight: lower.frame.height,
                                          chromeHeight: panel.frame.height - content.frame.height,
                                          preferredHeight: kind.size.height)
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
        } else if notification.name == NSWindow.didResignMainNotification {
            for panel in panels.values { panel.orderOut(nil) }
        } else {
            updateVisibility()
        }
    }

    private func updateVisibility() {
        guard let parent else { return }
        for (kind, panel) in panels {
            if parent.isMainWindow && !parent.isMiniaturized && shown.contains(kind) {
                if !panel.isVisible { panel.orderFront(nil) }
            } else {
                panel.orderOut(nil)
            }
        }
        visibilityDidChange?()
    }
}
