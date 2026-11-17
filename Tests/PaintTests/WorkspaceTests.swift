import AppKit
import Testing
@testable import Paint

@MainActor
struct WorkspaceTests {
    @Test func zoomStepsAndTypedPercentages() {
        #expect(WorkspaceZoom.next(from: 100, by: 1) == 150)
        #expect(WorkspaceZoom.next(from: 100, by: -1) == 75)
        #expect(WorkspaceZoom.next(from: 10_000, by: 1) == nil)
        #expect(WorkspaceZoom.next(from: 1, by: -1) == nil)
        #expect(WorkspaceZoom.parse("125.5%", locale: Locale(identifier: "en_NZ")) == 125.5)
        #expect(WorkspaceZoom.parse("12,5 %", locale: Locale(identifier: "fr_FR")) == 12.5)
        #expect(WorkspaceZoom.parse("0%", locale: Locale(identifier: "en_NZ")) == nil)
        #expect(WorkspaceZoom.parse("100% extra", locale: Locale(identifier: "en_NZ")) == nil)
    }

    @Test func pixelGridAndRulerIntervalsFollowZoomAndPanning() {
        let horizontal = WorkspacePixelAxis(origin: 3, pointPerPixel: 2)
        #expect(horizontal.pixels(in: 4...11, every: 1) == 1...4)
        #expect(horizontal.point(at: 4) == 11)
        #expect(horizontal.rulerMajorInterval == 50)
        let vertical = WorkspacePixelAxis(origin: 13, pointPerPixel: -2)
        #expect(vertical.pixels(in: 4...11, every: 1) == 1...4)
        #expect(vertical.point(at: 4) == 5)
        #expect(vertical.pixels(in: 5.25...5.75, every: 1) == nil)
    }

    @Test func rgbHexEditsPreserveOpacityAndRejectInvalidInput() {
        var color = WorkspaceColor(WorkspaceColor.fromARGB(0x8000A0FF))
        let accepted = color.setHex(" #ea2233 ")
        #expect(accepted)
        #expect(color.argb == 0x80EA2233)
        #expect(color.rgbHex == "EA2233")
        for invalid in ["FF997788", "G0FF00", "FFFF"] {
            let accepted = color.setHex(invalid)
            #expect(!accepted)
        }
        #expect(color.argb == 0x80EA2233)
    }

    @Test func colorWheelConstrainsHueAndSaturation() {
        var color = WorkspaceColor(WorkspaceColor.fromARGB(0x80400000))
        color.setHSV(hue: 0, saturation: 0.4, value: 0.5)
        color.pickOnWheel(x: 0, y: 1, modifiers: [.control])
        #expect(color.hue == 0.25)
        #expect(color.saturation == 0.4)
        #expect(color.value == 0.5)
        #expect(WorkspaceColor.byte(color.color.alphaComponent) == 128)

        color.pickOnWheel(x: 0.2, y: 0, modifiers: [.option])
        #expect(color.hue == 0.25)
        #expect(color.saturation == 0.2)

        color.pickOnWheel(x: cos(.pi / 10) * 0.7, y: sin(.pi / 10) * 0.7, modifiers: [.control, .shift])
        #expect(color.hue == 1.0 / 24)
        #expect(color.saturation == 0.2)
        color.pickOnWheel(x: 1, y: 0, modifiers: [])
        #expect(color.argb == 0x80FF0000)
    }

    @Test func paletteFilesRoundTripAndHandleShortAndOversizedPalettes() throws {
        let text = "\u{FEFF}; Sample palette\r\n\r\n0044AAEE\r\n 80ff0033 \r\n"
        let padded = try WorkspacePalette.parse(text)
        #expect(padded.count == 96)
        #expect(Array(padded.prefix(3)) == [0x0044AAEE, 0x80FF0033, 0xFFFFFFFF])
        #expect(try WorkspacePalette.parse(WorkspacePalette.serialize(padded)) == padded)
        #expect(try WorkspacePalette.parse(WorkspacePalette.serialize(padded) + "ignored\n") == padded)
        #expect(throws: WorkspacePalette.ReadError.self) {
            try WorkspacePalette.parse("006699\n")
        }
        #expect(WorkspacePalette.standard.count == 96)
        #expect(WorkspacePalette.standard[2] == 0xFFFF0000)
        #expect(WorkspacePalette.standard[66] == 0x80FF0000)
    }

    @Test func colorSlotsAndPalettePreferencesAreIndependent() throws {
        _ = NSApplication.shared
        let suite = "PaintTests.Colors." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = WorkspaceColors(defaults: defaults)
        let view = ColorsView(model: model)
        let red = WorkspaceColor(WorkspaceColor.fromARGB(0xFFFF0000))
        model.set(red, for: .primary)
        #expect(view.handleShortcut("c"))
        #expect(model.active == .secondary)
        #expect(view.handleShortcut("x"))
        #expect(model.active == .secondary)
        #expect(model[.secondary].argb == red.argb)
        model.reset()
        #expect(model[.primary].argb == 0xFF000000)
        #expect(model[.secondary].argb == 0xFFFFFFFF)
        model.toggleExpanded()
        #expect(view.expanded)
        var palette = WorkspacePalette.standard
        palette[0] = 0x4080A0B0
        model.setPalette(palette, name: "Example")
        let reopened = WorkspaceColors(defaults: defaults)
        #expect(reopened.expanded)
        #expect(reopened.palette == palette)
        #expect(reopened.paletteName == "Example")
    }

    @Test func colorsPanelRoutesSwatchesAndUpdatesExpandedControls() throws {
        _ = NSApplication.shared
        let suite = "PaintTests.Colors.Panel." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = WorkspaceColors(defaults: defaults)
        let view = ColorsView(model: model)
        let grid = try #require(view.subviews.first { $0.subviews.count == WorkspacePalette.count })
        let red = try #require(grid.subviews[2] as? NSButton)
        let orange = try #require(grid.subviews[3] as? NSButton)
        let transparent = try #require(grid.subviews[66] as? NSButton)
        #expect(transparent.isHidden)
        red.performClick(nil)
        #expect(model[.primary].argb == 0xFFFF0000)

        let rightClick = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                                        timestamp: 0, windowNumber: 0, context: nil,
                                                        eventNumber: 0, clickCount: 1, pressure: 1))
        orange.rightMouseDown(with: rightClick)
        #expect(model[.secondary].argb == 0xFFFF6A00)
        #expect(model.active == .primary)

        let more = try #require(view.subviews.compactMap { $0 as? NSButton }.first { $0.title == "More »" })
        let compactSize = view.panelSize
        more.performClick(nil)
        #expect(view.panelSize.width > compactSize.width)
        #expect(!transparent.isHidden)
        transparent.performClick(nil)
        #expect(model[.primary].argb == 0x80FF0000)

        let fields = view.subviews.flatMap(\.subviews).compactMap { $0 as? NSTextField }
        let hex = try #require(fields.first { $0.accessibilityLabel() == "Hex color" })
        let alpha = try #require(fields.first { $0.accessibilityLabel() == "Opacity" })
        #expect(hex.stringValue == "FF0000")
        #expect(alpha.integerValue == 128)
        hex.stringValue = "#2266AA"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: hex))
        #expect(model[.primary].argb == 0x802266AA)
        #expect(alpha.integerValue == 128)
    }

    @Test func panelPlacementTracksClosestCorner() {
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        let panel = CGRect(x: 690, y: 510, width: 200, height: 160)
        let placement = UtilityPanels.Placement(panel: panel, in: frame)
        #expect(!placement.fromLeft)
        #expect(placement.fromTop)
        #expect(placement.origin(for: panel.size, in: frame) == panel.origin)
        #expect(placement.origin(for: panel.size, in: CGRect(x: 110, y: 80, width: 700, height: 500)) == CGPoint(x: 600, y: 390))
        #expect(UtilityPanels.topContentHeight(ownerHeight: 440, lowerPanelHeight: 130,
                                            chromeHeight: 24, preferredHeight: 246) == 144)
        #expect(UtilityPanels.topContentHeight(ownerHeight: 640, lowerPanelHeight: 130,
                                            chromeHeight: 24, preferredHeight: 246) == 246)
    }

    @Test func utilityPanelsFollowOwnerAndKeepManualPlacementWhenToggled() throws {
        final class OwnerWindow: NSWindow {
            override var isMainWindow: Bool { true }
            var isUncovered = false
            override var occlusionState: NSWindow.OcclusionState { isUncovered ? .visible : [] }
        }
        _ = NSApplication.shared
        let owner = OwnerWindow(contentRect: CGRect(x: 100, y: 120, width: 640, height: 460),
                                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        defer { owner.close() }
        owner.center()
        let panels = UtilityPanels(parent: owner, colorsSize: .zero,
                                   contents: [.history: NSView(), .layers: NSView()])
        panels.isWorkspaceActive = true
        #expect(owner.childWindows?.isEmpty != false)

        owner.orderFront(nil)
        #expect(owner.childWindows?.isEmpty != false)
        owner.isUncovered = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: owner)
        let history = try #require(owner.childWindows?.first(where: { $0.title == "History" }))
        #expect(history.isVisible)
        #expect(history.level == owner.level)
        // WindowServer constrains frames to placeholder sizes in headless test runs.
        let canCheckGeometry = owner.screen != nil
        if canCheckGeometry {
            let original = history.frame.origin
            owner.setFrameOrigin(CGPoint(x: owner.frame.minX + 20, y: owner.frame.minY + 15))
            #expect(history.frame.origin == CGPoint(x: original.x + 20, y: original.y + 15))
            history.setFrameOrigin(CGPoint(x: history.frame.minX - 24, y: history.frame.minY - 14))
        }
        let moved = history.frame.origin
        panels.toggle(.history)
        #expect(history.parent == nil)
        #expect(!history.isVisible)
        if canCheckGeometry {
            owner.setFrameOrigin(CGPoint(x: owner.frame.minX + 12, y: owner.frame.minY))
        }
        panels.toggle(.history)
        #expect(history.parent === owner)
        if canCheckGeometry {
            #expect(history.frame.origin == CGPoint(x: moved.x + 12, y: moved.y))
            let resized = owner.frame.insetBy(dx: -10, dy: -8)
            owner.setFrame(resized, display: false)
            #expect(history.frame.origin == CGPoint(x: moved.x + 22, y: moved.y + 8))
        }

        owner.isUncovered = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: owner)
        #expect(!history.isVisible)
        #expect(panels.isShown(.history))
    }

    @Test func historyRowsUseDifferentIconsForDocumentAndToolActions() throws {
        _ = NSApplication.shared
        let document = try #require(PaintDocument.newImage(width: 3, height: 3, resolution: .standard))
        let editor = EditorView(document: document)
        document.applyEdit(actionName: "Rectangle Select (Intersect)")
        let table = NSTableView()
        let first = try #require(editor.tableView(table, viewFor: nil, row: 0) as? NSTableCellView)
        let second = try #require(editor.tableView(table, viewFor: nil, row: 1) as? NSTableCellView)
        let documentIcon = try #require(first.imageView?.image)
        let toolIcon = try #require(second.imageView?.image)
        #expect(documentIcon != toolIcon)
        #expect(first.textField?.stringValue == "New Image")
        #expect(second.textField?.stringValue == "Rectangle Select (Intersect)")
    }

    @Test func layerDragMapsTopFirstRowsToBottomFirstIndices() {
        #expect(LayersView.dropDestination(from: 3, above: 0, count: 4) == 3)
        #expect(LayersView.dropDestination(from: 0, above: 4, count: 4) == 0)
        #expect(LayersView.dropDestination(from: 3, above: 1, count: 4) == 2)
        #expect(LayersView.dropDestination(from: 1, above: 2, count: 4) == nil)
        #expect(LayersView.dropDestination(from: 0, above: 5, count: 4) == nil)
    }

    @Test func documentTabsShareOneWindowAndKeepTheirEditors() throws {
        _ = NSApplication.shared
        let workspace = WorkspaceDocuments.shared
        let first = PaintDocument()
        let second = PaintDocument()
        defer {
            first.close()
            second.close()
        }
        first.showWindows()
        let window = try #require(first.windowForSheet)
        let firstEditor = try #require(first.editor)
        let firstID = try #require(firstEditor.documentStrip.currentDocument)
        firstEditor.toggleGrid()
        second.showWindows()
        let secondEditor = try #require(second.editor)
        let secondID = try #require(secondEditor.documentStrip.currentDocument)
        #expect(first.windowForSheet == nil)
        #expect(second.windowForSheet === window)
        #expect(window.contentView === secondEditor)
        #expect(window.tabGroup?.isTabBarVisible != true)
        #expect(!secondEditor.showsGrid)

        workspace.reorder(secondID, before: firstID)
        #expect(workspace.entries.map(\.id) == [secondID, firstID])
        workspace.activate(firstID)
        #expect(first.windowForSheet === window)
        #expect(second.windowForSheet == nil)
        #expect(window.contentView === firstEditor)
        #expect(firstEditor.showsGrid)

        window.performClose(nil)
        #expect(workspace.entries.map(\.id) == [secondID])
        #expect(second.windowForSheet === window)
        #expect(window.contentView === secondEditor)
        second.close()
        #expect(workspace.entries.isEmpty)
    }

    @Test func editorTogglesRulersAndGridIndependently() {
        _ = NSApplication.shared
        let document = PaintDocument()
        let editor = EditorView(document: document)
        #expect(!editor.showsRulers)
        #expect(!editor.showsGrid)
        editor.toggleRulers()
        #expect(editor.showsRulers)
        #expect(!editor.showsGrid)
        editor.toggleGrid()
        #expect(editor.showsGrid)
        editor.toggleRulers()
        #expect(!editor.showsRulers)
        #expect(editor.showsGrid)
    }

    @Test func editorKeepsToolbarAndViewControlsInsideNarrowAndWideWindows() throws {
        _ = NSApplication.shared
        let document = PaintDocument()
        let editor = EditorView(document: document)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 880, height: 640),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        defer { window.close() }
        func view(named identifier: String) throws -> NSView {
            try #require(editor.subviews.first { $0.identifier?.rawValue == identifier })
        }
        for size in [CGSize(width: 420, height: 420), CGSize(width: 880, height: 640)] {
            window.setContentSize(size)
            editor.layoutSubtreeIfNeeded()
            let commands = try view(named: "Editor Commands")
            let options = try view(named: "Tool Options")
            let footer = try view(named: "View Controls")
            let strip = try #require(editor.subviews.first { $0 is DocumentStrip })
            #expect(strip.frame.width > 0)
            #expect(editor.bounds.contains(commands.frame))
            #expect(editor.bounds.contains(options.frame))
            #expect(editor.bounds.contains(footer.frame))
            #expect(strip.frame.minY > options.frame.maxY)
            #expect(!commands.frame.intersects(strip.frame))
        }
    }

    @Test func menuValidationFollowsEachDocumentsActiveLayerAndSelection() {
        _ = NSApplication.shared
        let first = PaintDocument()
        let second = PaintDocument()
        first.makeWindowControllers()
        second.makeWindowControllers()
        defer {
            first.close()
            second.close()
        }

        let layers = NSMenuItem(title: "Add Layer", action: #selector(PaintDocument.layerCommand(_:)), keyEquivalent: "")
        layers.tag = PaintDocument.LayerCommand.add.rawValue
        let adjustment = NSMenuItem(title: "Adjust", action: #selector(PaintDocument.applyAdjustment(_:)), keyEquivalent: "")
        let invert = NSMenuItem(title: "Invert Selection", action: #selector(PaintDocument.invertPixelSelection(_:)), keyEquivalent: "")

        #expect(first.validateUserInterfaceItem(layers))
        #expect(first.validateUserInterfaceItem(adjustment))
        #expect(!first.validateUserInterfaceItem(invert))
        first.selectAllPixels(nil)
        #expect(first.validateUserInterfaceItem(invert))
        #expect(!second.validateUserInterfaceItem(invert))

        first.setLayerVisibility(false, at: 0)
        #expect(first.validateUserInterfaceItem(layers))
        #expect(!first.validateUserInterfaceItem(adjustment))
        #expect(second.validateUserInterfaceItem(adjustment))
    }
}
