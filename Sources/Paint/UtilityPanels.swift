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
            case .tools: return CGSize(width: 88, height: 76)
            case .history: return CGSize(width: 160, height: 145)
            case .layers: return CGSize(width: 160, height: 72)
            case .colors: return CGSize(width: 144, height: 88)
            }
        }
    }

    private weak var parent: NSWindow?
    private var panels: [Kind: NSPanel] = [:]
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
                content.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor, constant: -8)
            ])
            panel.contentView = body
            panels[kind] = panel
        }

        resetPositions()
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
        for (kind, panel) in panels {
            let left = kind == .tools || kind == .colors
            let top = kind == .tools || kind == .history
            let frame = parent.frame
            let x = left ? frame.minX + 8 : frame.maxX - panel.frame.width - 8
            let y = top ? frame.maxY - panel.frame.height - 66 : frame.minY + 34
            panel.setFrameOrigin(CGPoint(x: x, y: y))
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
            for panel in panels.values { hide(panel) }
            parent = nil
        } else if notification.name == NSWindow.didResignMainNotification {
            for panel in panels.values { hide(panel) }
        } else {
            updateVisibility()
        }
    }

    private func updateVisibility() {
        guard let parent else { return }
        for (kind, panel) in panels {
            if parent.isMainWindow && !parent.isMiniaturized && shown.contains(kind) {
                if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
                if !panel.isVisible { panel.orderFront(nil) }
            } else {
                hide(panel)
            }
        }
    }

    private func hide(_ panel: NSPanel) {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}
