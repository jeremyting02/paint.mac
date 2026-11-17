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

    @Test func rgbAndRgbaHexValues() throws {
        let rgb = try #require(WorkspaceColorHex.parse("#EA2233"))
        #expect(WorkspaceColorHex.format(rgb) == "EA2233FF")
        let rgba = try #require(WorkspaceColorHex.parse("7F00a080"))
        #expect(WorkspaceColorHex.format(rgba) == "7F00A080")
        #expect(WorkspaceColorHex.parse("G0FF00") == nil)
        #expect(WorkspaceColorHex.parse("FFFF") == nil)
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

    @Test func layerDragMapsTopFirstRowsToBottomFirstIndices() {
        #expect(LayersView.dropDestination(from: 3, above: 0, count: 4) == 3)
        #expect(LayersView.dropDestination(from: 0, above: 4, count: 4) == 0)
        #expect(LayersView.dropDestination(from: 3, above: 1, count: 4) == 2)
        #expect(LayersView.dropDestination(from: 1, above: 2, count: 4) == nil)
        #expect(LayersView.dropDestination(from: 0, above: 5, count: 4) == nil)
    }

    @Test func documentStripKeepsOneOrderAndTracksClosedWindows() {
        _ = NSApplication.shared
        let workspace = WorkspaceDocuments()
        let windows = (0..<3).map { _ in
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 420),
                                  styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            return window
        }
        let documents = (0..<3).map { _ in PaintDocument() }
        let strips = (0..<3).map { _ in DocumentStrip(workspace: workspace) }
        let ids = windows.indices.map { workspace.register(document: documents[$0], window: windows[$0], strip: strips[$0]) }
        #expect(strips.map(\.currentDocument) == ids.map(Optional.some))
        workspace.reorder(ids[2], before: ids[0])
        #expect(workspace.entries.map(\.id) == [ids[2], ids[0], ids[1]])
        workspace.reorder(ids[2], before: nil)
        #expect(workspace.entries.map(\.id) == ids)
        windows[1].close()
        #expect(workspace.entries.map(\.id) == [ids[0], ids[2]])
        windows[0].close()
        windows[2].close()
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
