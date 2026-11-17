import AppKit
import Testing
@testable import Paint

struct TonalAdjustmentTests {
    @Test func curvePassesThroughControlPointsAndExtendsMovableEndpoints() {
        var graph = CurveGraph()
        graph.setPoint(.init(input: 128, output: 200))
        graph.setPoint(.init(input: 32, output: 16), replacing: 0)
        graph.setPoint(.init(input: 224, output: 240), replacing: 255)
        let table = graph.table
        #expect(table[0] == 16)
        #expect(table[32] == 16)
        #expect(table[80] > 108)
        #expect(table[128] == 200)
        #expect(table[224] == 240)
        #expect(table[255] == 240)
        graph.setPoint(.init(input: 240, output: 256), replacing: 128)
        #expect(graph.points[1] == .init(input: 223, output: 255))
        graph.removePoint(at: 223)
        graph.removePoint(at: 32)
        #expect(graph.points.map(\.input) == [32, 224])
    }

    @Test func curvesChangeChosenColorChannelOrLuminosityWithoutChangingAlpha() throws {
        let colored = try input([32, 96, 128, 193, 20, 20, 20, 242])
        var settings = CurveSettings()
        #expect(colored.render(settings.filter(), values: [])?.pdnPixels == colored.pixels)
        settings.rgb[RGBChannel.green.rawValue].setPoint(.init(input: 96, output: 141))
        settings.mode = .rgb
        let rgb = try #require(colored.render(settings.filter(), values: [])?.pdnPixels)
        #expect(Array(rgb.prefix(4)) == [32, 141, 128, 193])
        #expect(rgb[4] == 20 && rgb[5] > 29 && rgb[6] == 20 && rgb[7] == 242)
        settings.mode = .luminosity
        settings.luminosity.setPoint(.init(input: 0, output: 255))
        settings.luminosity.setPoint(.init(input: 255, output: 0))
        let rendered = try #require(colored.render(settings.filter(), values: [])?.pdnPixels)
        #expect(Array(rendered.suffix(4)) == [235, 235, 235, 242])
        #expect(Int(rendered[2]) - Int(rendered[1]) == 32)
        #expect(rendered[3] == 193)
        #expect(colored.render(settings.filter(), values: [], isCancelled: { true }) == nil)
    }

    @Test func levelsApplyInputOutputAndGammaPerChannel() throws {
        let colored = try input([128, 128, 128, 193, 16, 16, 16, 255, 240, 240, 240, 120])
        var settings = LevelSettings()
        settings.set(.inputBlack, to: 32, channels: [.red])
        settings.set(.inputWhite, to: 224, channels: [.red])
        settings.set(.outputBlack, to: 16, channels: [.red])
        settings.set(.outputWhite, to: 240, channels: [.red])
        settings.set(.gamma, to: 2, channels: [.red, .green])
        let result = try #require(colored.render(settings.filter(), values: [])?.pdnPixels)
        #expect(result == Data([128, 181, 174, 193, 16, 64, 16, 255, 240, 247, 240, 120]))
        settings.set(.inputBlack, to: 255, channels: [.red])
        #expect(settings[.red].inputBlack == 223)
        settings.set(.gamma, to: -5, channels: [.blue])
        #expect(settings[.blue].gamma == 0.1)
    }

    @Test func levelsHistogramsAndAutoLevelUseSelectedVisiblePixels() throws {
        let selection = try #require(SelectionOutline(rect: CGRect(x: 1, y: 0, width: 3, height: 1)))
        let colored = try input([
            0, 0, 0, 255,
            30, 100, 55, 255,
            70, 180, 105, 120,
            75, 120, 88, 0,
            255, 255, 255, 255
        ], selection: selection)
        let histogram = ChannelHistogram(pixels: colored.pixels, mask: colored.mask)
        #expect(histogram[.red][55] == 1)
        #expect(histogram[.red][105] == 1)
        #expect(histogram[.red][255] == 0)
        #expect(histogram[.red][0] == 0)
        var levels = LevelSettings()
        levels.auto(using: histogram, channels: Set(RGBChannel.allCases))
        let after = histogram.remapped(by: levels.tables)
        #expect(after[.green][0] == 1)
        #expect(after[.green][255] == 1)
        let manual = try #require(colored.render(levels.filter(), values: [])?.pdnPixels)
        let auto = try #require(colored.render(.autoLevel, values: [])?.pdnPixels)
        #expect(manual == auto)
        #expect(auto == Data([
            0, 0, 0, 255,
            0, 0, 0, 255,
            255, 255, 255, 120,
            75, 120, 88, 0,
            255, 255, 255, 255
        ]))
    }

    @MainActor @Test func levelsPanelPreviewsChannelEditsAndResetFromOriginal() async throws {
        _ = NSApplication.shared
        let source = try input([128, 128, 128, 255])
        let filter = try #require(RasterFilter.adjustments.first { $0.title == "Levels" })
        let panel = RasterFilterPanel(filter: filter, input: source)
        defer { panel.stopPreview() }
        let windowView = try #require(panel.contentView)
        let controls = descendants(in: windowView)
        let green = try #require(controls.compactMap { $0 as? NSButton }.first { $0.title == "Green" })
        let blue = try #require(controls.compactMap { $0 as? NSButton }.first { $0.title == "Blue" })
        green.performClick(nil)
        blue.performClick(nil)
        let black = try #require(controls.compactMap { $0 as? NSSlider }
            .first { $0.accessibilityLabel() == "Input black point" })
        black.doubleValue = 64
        #expect(NSApp.sendAction(try #require(black.action), to: black.target, from: black))
        for _ in 0..<100 where panel.result == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(panel.result?.pdnPixels == Data([128, 128, 85, 255]))
        let reset = try #require(controls.compactMap { $0 as? NSButton }.first { $0.title == "Reset" })
        reset.performClick(nil)
        for _ in 0..<100 where panel.result == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(panel.result?.pdnPixels == source.pixels)
        #expect(green.state == .on && blue.state == .on)
    }

    @MainActor @Test func curvesPanelDragsAndRemovesAnInteriorRGBPoint() async throws {
        _ = NSApplication.shared
        let source = try input([128, 128, 128, 231])
        let filter = try #require(RasterFilter.adjustments.first { $0.title == "Curves" })
        let panel = RasterFilterPanel(filter: filter, input: source)
        defer { panel.stopPreview() }
        let content = try #require(panel.contentView)
        content.layoutSubtreeIfNeeded()
        let views = descendants(in: content)
        let popup = try #require(views.compactMap { $0 as? NSPopUpButton }.first)
        popup.selectItem(withTitle: "RGB")
        #expect(NSApp.sendAction(try #require(popup.action), to: popup.target, from: popup))
        for channel in ["Green", "Blue"] {
            let checkbox = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == channel })
            checkbox.performClick(nil)
        }
        let graph = try #require(views.compactMap { $0 as? CurveGraphView }.first)
        #expect(graph.bounds.width > 0 && graph.bounds.height > 0)
        let start = CGPoint(x: graph.bounds.midX, y: graph.bounds.midY)
        let end = CGPoint(x: start.x, y: graph.bounds.height * 0.75)
        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: graph.convert(point, to: nil), modifierFlags: [],
                                           timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                           eventNumber: 0, clickCount: 1, pressure: 1))
        }
        graph.mouseDown(with: try event(.leftMouseDown, at: start))
        graph.mouseDragged(with: try event(.leftMouseDragged, at: end))
        graph.mouseUp(with: try event(.leftMouseUp, at: end))
        for _ in 0..<100 where panel.result == nil { try await Task.sleep(for: .milliseconds(20)) }
        let pixels = try #require(panel.result?.pdnPixels)
        #expect(pixels[0] == 128 && pixels[1] == 128 && pixels[2] > 180 && pixels[3] == 231)
        graph.rightMouseDown(with: try event(.rightMouseDown, at: end))
        for _ in 0..<100 where panel.result == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(panel.result?.pdnPixels == source.pixels)
    }

    @MainActor private func descendants(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(in: $0) }
    }

    private func input(_ bytes: [UInt8], selection: SelectionOutline? = nil) throws -> RasterFilter.Input {
        let pixels = Data(bytes)
        let image = try #require(BGRA8.image(from: pixels, width: bytes.count / 4, height: 1))
        let layer = PaintLayer(name: "Sample", image: image, pdnPixels: pixels)
        return try #require(RasterFilter.Input(layer: layer, selection: selection))
    }
}
