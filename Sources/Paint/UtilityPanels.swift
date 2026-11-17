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
            case .tools: return CGSize(width: 236, height: 76)
            case .history: return CGSize(width: 160, height: 172)
            case .layers: return CGSize(width: 224, height: 151)
            case .colors: return CGSize(width: 144, height: 88)
            }
        }
    }

    private struct Placement {
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

        @MainActor mutating func apply(to panel: NSPanel, in frame: CGRect) {
            let panelFrame = panel.frame
            let x = fromLeft ? frame.minX + inset.x : frame.maxX - panelFrame.width - inset.x
            let y = fromTop ? frame.maxY - panelFrame.height - inset.y : frame.minY + inset.y
            let origin = CGPoint(x: x, y: y)
            if panelFrame.origin != origin { panel.setFrameOrigin(origin) }
            lastOrigin = panel.frame.origin
        }
    }

    private weak var parent: NSWindow?
    private var panels: [Kind: NSPanel] = [:]
    private var placements: [Kind: Placement] = [:]
    private var parentFrame: CGRect = .zero
    private var shown = Set(Kind.allCases)

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
            content.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: body.topAnchor, constant: 8),
                content.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 8),
                content.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -8),
                kind == .history
                    ? content.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -8)
                    : content.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor, constant: -8)
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
            var placement = Placement(fromLeft: left, fromTop: top, inset: CGPoint(x: 8, y: top ? 66 : 34))
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
            placement.apply(to: panel, in: frame)
            placements[kind] = placement
        }
        parentFrame = frame
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
    }
}
