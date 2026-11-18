import AppKit
import UniformTypeIdentifiers

@MainActor
final class ColorsView: NSView, NSTextFieldDelegate {
    private enum Component: Int, CaseIterable {
        case red, green, blue, hue, saturation, value, alpha

        var title: String { ["Red", "Green", "Blue", "Hue", "Saturation", "Value", "Opacity"][rawValue] }
        var label: String { ["R", "G", "B", "H", "S", "V", ""][rawValue] }
        var maximum: Int {
            switch self {
            case .hue: return 360
            case .saturation, .value: return 100
            default: return 255
            }
        }

        func fraction(of color: WorkspaceColor) -> CGFloat {
            switch self {
            case .hue: return color.hue
            case .saturation: return color.saturation
            case .value: return color.value
            case .alpha: return color.channels[3]
            default: return color.channels[rawValue]
            }
        }

        func apply(_ fraction: CGFloat, to color: inout WorkspaceColor) {
            switch self {
            case .hue: color.setHSV(hue: fraction, saturation: color.saturation, value: color.value)
            case .saturation: color.setHSV(hue: color.hue, saturation: fraction, value: color.value)
            case .value: color.setHSV(hue: color.hue, saturation: color.saturation, value: fraction)
            case .alpha: color.color = color.color.withAlphaComponent(fraction)
            default:
                var channels = color.channels
                channels[rawValue] = fraction
                color.setRGB(channels)
            }
        }
    }

    override var isFlipped: Bool { true }

    private let model: WorkspaceColors
    private let primary = ColorSwatch(frame: CGRect(x: 0, y: 0, width: 34, height: 34))
    private let secondary = ColorSwatch(frame: CGRect(x: 18, y: 18, width: 34, height: 34))
    private let wheel = ColorWheel(frame: CGRect(x: 50, y: 28, width: 142, height: 142))
    private let grid = NSView(frame: CGRect(x: 0, y: 178, width: 192, height: 72))
    private let gridOutline = NSView()
    private let details = NSView(frame: CGRect(x: 215, y: 0, width: 154, height: 250))
    private let more = NSButton(title: "More »", target: nil, action: nil)
    private let add = ColorSwatch(frame: CGRect(x: 0, y: 153, width: 17, height: 17))
    private let palettes = EditorView.icon("paintpalette", label: "Manage palettes")
    private let hex = NSTextField()
    private var controls: [(slider: NSSlider, field: NSTextField, stepper: NSStepper)] = []
    private var swatches: [ColorSwatch] = []
    private var insertionColor: UInt32?
    private var editedField: NSTextField?
    private(set) var expanded: Bool
    var expansionDidChange: (() -> Void)?
    var colorsDidChange: (() -> Void)?

    var panelSize: CGSize { Self.panelSize(expanded: expanded) }

    nonisolated static func panelSize(expanded: Bool) -> CGSize {
        CGSize(width: expanded ? 385 : 208, height: expanded ? 266 : 218)
    }

    init(model: WorkspaceColors) {
        self.model = model
        expanded = model.expanded
        super.init(frame: .zero)

        addSubview(wheel)
        for (slot, button) in [(WorkspaceColors.Slot.secondary, secondary), (.primary, primary)] {
            button.tag = slot.rawValue
            button.setAccessibilityLabel("\(slot.name) color")
            button.toolTip = "\(slot.name) color"
            button.target = self
            button.action = #selector(selectSlot(_:))
            addSubview(button)
        }
        icon("arrow.left.arrow.right", "Swap Primary and Secondary Colors (X)",
             frame: CGRect(x: 38, y: 0, width: 17, height: 17), action: #selector(swap))
        icon("circle.lefthalf.filled", "Reset to Black and White",
             frame: CGRect(x: 0, y: 38, width: 15, height: 15), action: #selector(reset))

        more.frame = CGRect(x: 118, y: 0, width: 74, height: 22)
        more.controlSize = .small
        more.bezelStyle = .rounded
        more.target = self
        more.action = #selector(toggleExpanded)
        addSubview(more)

        wheel.setAccessibilityLabel("Color wheel")
        wheel.change = { [weak self] x, y, flags, secondary in
            guard let self else { return }
            finishFieldEditing()
            let slot = secondary ? model.active.other : model.active
            var color = model[slot]
            color.pickOnWheel(x: x, y: y, modifiers: flags)
            model.set(color, for: slot)
        }

        add.target = self
        add.action = #selector(toggleInsertion)
        add.setAccessibilityLabel("Add active color to palette")
        add.toolTip = "Add active color to palette"
        add.showsPlus = true
        addSubview(add)
        palettes.frame = CGRect(x: 20, y: 152, width: 29, height: 19)
        palettes.imagePosition = .imageOnly
        palettes.target = self
        palettes.action = #selector(showPalettes)
        addSubview(palettes)

        addSubview(grid)
        for index in 0..<WorkspacePalette.count {
            let row = index / WorkspacePalette.columns
            let column = index % WorkspacePalette.columns
            let button = ColorSwatch(frame: CGRect(x: column * 12, y: 60 - row * 12, width: 12, height: 12))
            button.tag = index
            button.target = self
            button.action = #selector(useSwatch(_:))
            button.alternateAction = { [weak self] in self?.useSwatch(index, alternate: true) }
            swatches.append(button)
            grid.addSubview(button)
        }

        gridOutline.wantsLayer = true
        gridOutline.layer?.borderWidth = 1
        gridOutline.layer?.borderColor = NSColor.controlAccentColor.cgColor
        addSubview(gridOutline, positioned: .below, relativeTo: grid)
        addSubview(details)
        configureDetails()
        NotificationCenter.default.addObserver(self, selector: #selector(workspaceColorsChanged(_:)),
                                               name: WorkspaceColors.changed, object: model)
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    func handleShortcut(_ key: String) -> Bool {
        switch key {
        case "c": model.select(model.active.other)
        case "x": model.swap()
        default: return false
        }
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        if insertionColor != nil { toggleInsertion() } else { super.cancelOperation(sender) }
    }

    private func icon(_ symbol: String, _ title: String, frame: CGRect, action: Selector) {
        let button = EditorView.icon(symbol, label: title)
        button.frame = frame
        button.isBordered = false
        button.controlSize = .mini
        button.target = self
        button.action = action
        addSubview(button)
    }

    private func configureDetails() {
        func label(_ text: String, x: CGFloat = 0, y: CGFloat, width: CGFloat) {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11)
            label.frame = CGRect(x: x, y: 250 - y - 16, width: width, height: 16)
            details.addSubview(label)
        }

        for (title, y, width) in [("RGB", 0.0, 27.0), ("HSV", 110.0, 27.0), ("Opacity - Alpha", 199.0, 82.0)] {
            label(title, y: y, width: width)
            let rule = NSBox(frame: CGRect(x: width, y: 242 - y, width: 154 - width, height: 1))
            rule.boxType = .separator
            details.addSubview(rule)
        }
        for component in Component.allCases {
            let y = [16, 38, 60, 126, 148, 170, 218][component.rawValue]
            label(component.label, y: CGFloat(y + 3), width: 19)
            let field = NSTextField(frame: CGRect(x: 101, y: 250 - y - 20, width: 39, height: 20))
            configureField(field, label: component.title, tag: component.rawValue)
            let slider = NSSlider(frame: CGRect(x: 20, y: 250 - y - 20, width: 77, height: 20))
            slider.cell = ColorSliderCell()
            slider.controlSize = .small
            slider.minValue = 0
            slider.maxValue = Double(component.maximum)
            slider.isContinuous = true
            slider.setAccessibilityLabel(component.title)
            slider.tag = component.rawValue
            slider.target = self
            slider.action = #selector(adjustValue(_:))
            details.addSubview(slider)

            let stepper = NSStepper(frame: CGRect(x: 140, y: 250 - y - 20, width: 14, height: 20))
            stepper.controlSize = .small
            stepper.minValue = 0
            stepper.maxValue = Double(component.maximum)
            stepper.valueWraps = false
            stepper.setAccessibilityLabel("\(component.title) stepper")
            stepper.tag = component.rawValue
            stepper.target = self
            stepper.action = #selector(adjustValue(_:))
            details.addSubview(stepper)
            controls.append((slider, field, stepper))
        }

        label("Hex:", y: 85, width: 33)
        hex.frame = CGRect(x: 92, y: 250 - 82 - 22, width: 62, height: 22)
        configureField(hex, label: "Hex color", tag: -1)
        hex.toolTip = "Six-digit RGB hex color"
    }

    private func configureField(_ field: NSTextField, label: String, tag: Int) {
        field.controlSize = .small
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.alignment = .right
        field.setAccessibilityLabel(label)
        field.tag = tag
        field.delegate = self
        details.addSubview(field)
    }

    @objc private func workspaceColorsChanged(_ notification: Notification) { refresh() }

    private func refresh() {
        let active = model[model.active]
        primary.color = model[.primary].color
        secondary.color = model[.secondary].color
        primary.marked = model.active == .primary
        secondary.marked = model.active == .secondary
        primary.setAccessibilityValue(primary.marked ? "Active" : "Inactive")
        secondary.setAccessibilityValue(secondary.marked ? "Active" : "Inactive")
        add.color = insertionColor.map(WorkspaceColor.fromARGB) ?? active.color
        add.marked = insertionColor != nil
        gridOutline.isHidden = insertionColor == nil
        gridOutline.frame = CGRect(x: -1, y: 177, width: 194, height: model.expanded ? 74 : 26)
        wheel.color = active
        if model.expanded { refreshFields(active) }

        for (index, button) in swatches.enumerated() {
            let argb = model.palette[index]
            if button.paletteValue != argb {
                button.paletteValue = argb
                button.color = WorkspaceColor.fromARGB(argb)
                let name = String(format: "Swatch %d, %08X", index + 1, argb)
                button.toolTip = name
                button.setAccessibilityLabel(name)
            }
            button.isHidden = !model.expanded && index >= 32
        }
        details.isHidden = !model.expanded
        more.title = model.expanded ? "« Less" : "More »"
        if expanded != model.expanded {
            expanded = model.expanded
            expansionDidChange?()
        }
        colorsDidChange?()
    }

    private func refreshFields(_ active: WorkspaceColor) {
        if editedField !== hex { hex.stringValue = active.rgbHex }
        for component in Component.allCases {
            let (slider, field, stepper) = controls[component.rawValue]
            let value = Int((component.fraction(of: active) * CGFloat(component.maximum)).rounded())
            slider.integerValue = value
            stepper.integerValue = value
            if editedField !== field { field.integerValue = value }

            var stops: [NSColor] = []
            let count = component == .hue ? 7 : 2
            for index in 0..<count {
                var endpoint = active
                let fraction = CGFloat(index) / CGFloat(count - 1)
                if component == .hue {
                    endpoint.setHSV(hue: fraction, saturation: 1, value: 1)
                } else {
                    component.apply(fraction, to: &endpoint)
                }
                stops.append(component == .alpha ? endpoint.color : endpoint.color.withAlphaComponent(1))
            }
            (slider.cell as? ColorSliderCell)?.colors = stops
            slider.needsDisplay = true
        }
    }

    @objc private func selectSlot(_ sender: NSButton) {
        guard let slot = WorkspaceColors.Slot(rawValue: sender.tag) else { return }
        finishFieldEditing()
        model.select(slot)
    }

    @objc private func swap() {
        finishFieldEditing()
        model.swap()
    }

    @objc private func reset() {
        finishFieldEditing()
        model.reset()
    }

    @objc private func toggleExpanded() {
        finishFieldEditing()
        model.toggleExpanded()
    }

    @objc private func adjustValue(_ sender: NSControl) {
        guard let component = Component(rawValue: sender.tag) else { return }
        let value = sender.integerValue
        finishFieldEditing()
        setComponent(component, to: value)
    }

    private func setComponent(_ component: Component, to value: Int) {
        var color = model[model.active]
        let fraction = CGFloat(min(component.maximum, max(0, value))) / CGFloat(component.maximum)
        component.apply(fraction, to: &color)
        model.set(color, for: model.active)
    }

    private func finishFieldEditing() {
        if editedField != nil { window?.makeFirstResponder(nil) }
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        editedField = notification.object as? NSTextField
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === hex {
            var color = model[model.active]
            if color.setHex(field.stringValue) { model.set(color, for: model.active) }
        } else if let component = Component(rawValue: field.tag),
                  let value = Int(field.stringValue), (0...component.maximum).contains(value) {
            setComponent(component, to: value)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField, let component = Component(rawValue: field.tag),
           let value = Int(field.stringValue), !(0...component.maximum).contains(value) {
            setComponent(component, to: value)
        }
        editedField = nil
        refreshFields(model[model.active])
    }

    @objc private func toggleInsertion() {
        finishFieldEditing()
        insertionColor = insertionColor == nil ? model[model.active].argb : nil
        refresh()
    }

    @objc private func useSwatch(_ sender: NSButton) { useSwatch(sender.tag, alternate: false) }

    private func useSwatch(_ index: Int, alternate: Bool) {
        finishFieldEditing()
        if let insertionColor {
            var colors = model.palette
            colors[index] = insertionColor
            self.insertionColor = nil
            model.setPalette(colors, name: nil)
        } else {
            let slot = alternate ? model.active.other : model.active
            model.set(WorkspaceColor(WorkspaceColor.fromARGB(model.palette[index])), for: slot)
        }
    }

    private var paletteFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("paint.mac/Palettes", isDirectory: true)
    }

    @objc private func showPalettes(_ sender: NSButton) {
        finishFieldEditing()
        let menu = NSMenu()
        let files = (try? FileManager.default.contentsOfDirectory(at: paletteFolder,
                     includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles)) ?? []
        for file in files.filter({
            $0.pathExtension.lowercased() == "txt" &&
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }).sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let name = file.deletingPathExtension().lastPathComponent
            let item = menu.addItem(withTitle: name, action: #selector(loadPalette(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = file
            item.state = name == model.paletteName ? .on : .off
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        for (title, action) in [("Load Palette…", #selector(importPalette)),
                                ("Save Current Palette As…", #selector(savePalette)),
                                ("Open Palettes Folder", #selector(openPaletteFolder)),
                                ("Reset to Default Palette", #selector(resetPalette))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            if action == #selector(resetPalette), model.palette == WorkspacePalette.standard { item.state = .on }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: sender.frame.minX, y: sender.frame.maxY), in: self)
    }

    @objc private func loadPalette(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { readPalette(url) }
    }

    private func readPalette(_ url: URL) {
        do {
            let colors = try WorkspacePalette.read(from: url)
            insertionColor = nil
            model.setPalette(colors, name: url.deletingPathExtension().lastPathComponent)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func importPalette() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.directoryURL = paletteFolder
        if panel.runModal() == .OK, let url = panel.url { readPalette(url) }
    }

    @objc private func savePalette() {
        do {
            try FileManager.default.createDirectory(at: paletteFolder, withIntermediateDirectories: true)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.plainText]
            panel.directoryURL = paletteFolder
            panel.nameFieldStringValue = (model.paletteName ?? "My Palette") + ".txt"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let colors = model.palette
            try WorkspacePalette.serialize(colors).write(to: url, atomically: true, encoding: .utf8)
            model.setPalette(colors, name: url.deletingPathExtension().lastPathComponent)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func openPaletteFolder() {
        do {
            try FileManager.default.createDirectory(at: paletteFolder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(paletteFolder)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func resetPalette() {
        insertionColor = nil
        model.setPalette(WorkspacePalette.standard, name: nil)
    }
}

private final class ColorSwatch: NSButton {
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    var marked = false { didSet { needsDisplay = true } }
    var showsPlus = false
    var paletteValue: UInt32?
    var alternateAction: (() -> Void)?

    override func draw(_ dirtyRect: CGRect) {
        let frame = bounds.insetBy(dx: paletteValue == nil ? 1 : 0, dy: paletteValue == nil ? 1 : 0)
        if color.alphaComponent < 1 { drawColorCheckerboard(in: frame) }
        color.setFill()
        frame.fill(using: .sourceOver)
        if paletteValue == nil {
            (showsPlus && marked ? NSColor.controlAccentColor : .labelColor).setStroke()
            NSBezierPath(rect: frame.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
        if showsPlus {
            NSColor.controlBackgroundColor.setFill()
            CGRect(x: bounds.maxX - 8, y: bounds.minY, width: 8, height: 8).fill()
            NSColor.labelColor.setFill()
            CGRect(x: bounds.maxX - 5, y: bounds.minY + 1, width: 1, height: 6).fill()
            CGRect(x: bounds.maxX - 7.5, y: bounds.minY + 3.5, width: 6, height: 1).fill()
        } else if marked {
            let marker = NSBezierPath()
            marker.move(to: CGPoint(x: bounds.midX - 5, y: 1))
            marker.line(to: CGPoint(x: bounds.midX, y: 7))
            marker.line(to: CGPoint(x: bounds.midX + 5, y: 1))
            marker.close()
            NSColor.white.setFill()
            marker.fill()
            NSColor.black.setStroke()
            marker.stroke()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let alternateAction { alternateAction() } else { super.rightMouseDown(with: event) }
    }
}

private final class ColorSliderCell: NSSliderCell {
    var colors: [NSColor] = []

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let bar = CGRect(x: rect.minX, y: rect.midY - 4, width: rect.width, height: 8)
        if colors.contains(where: { $0.alphaComponent < 1 }) { drawColorCheckerboard(in: bar) }
        NSGradient(colors: colors)?.draw(in: bar, angle: 0)
    }
}

private final class ColorWheel: NSView {
    var color = WorkspaceColor(.black) { didSet { needsDisplay = true } }
    var change: ((CGFloat, CGFloat, NSEvent.ModifierFlags, Bool) -> Void)?
    private static let image = makeImage()
    private var dragging = false

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: CGRect) {
        let radius = bounds.width / 2
        if let image = Self.image, let context = NSGraphicsContext.current?.cgContext { context.draw(image, in: bounds) }
        let angle = color.hue * 2 * .pi
        let distance = max(0, radius - 4) * color.saturation
        let point = CGPoint(x: bounds.midX + cos(angle) * distance, y: bounds.midY - sin(angle) * distance)
        let marker = NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
        NSColor.white.setStroke()
        marker.lineWidth = 3
        marker.stroke()
        NSColor.black.setStroke()
        marker.lineWidth = 1
        marker.stroke()
    }

    private static func makeImage() -> CGImage? {
        let size = 284
        let radius = CGFloat(size) / 2
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for row in 0..<size {
            for column in 0..<size {
                let x = (CGFloat(column) + 0.5 - radius) / radius
                let y = (CGFloat(row) + 0.5 - radius) / radius
                let distance = hypot(x, y)
                guard distance <= 1 else { continue }
                let hue = (atan2(y, x) / (2 * .pi) + 1).truncatingRemainder(dividingBy: 1)
                let rgb = WorkspaceColor.hsvComponents(hue: hue, saturation: distance, value: 1)
                let offset = (row * size + column) * 4
                bytes[offset] = UInt8(WorkspaceColor.byte(rgb.red))
                bytes[offset + 1] = UInt8(WorkspaceColor.byte(rgb.green))
                bytes[offset + 2] = UInt8(WorkspaceColor.byte(rgb.blue))
                bytes[offset + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: size * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    override func mouseDown(with event: NSEvent) { pick(event, alternate: false, begins: true) }
    override func mouseDragged(with event: NSEvent) { pick(event, alternate: false, begins: false) }
    override func rightMouseDown(with event: NSEvent) { pick(event, alternate: true, begins: true) }
    override func rightMouseDragged(with event: NSEvent) { pick(event, alternate: true, begins: false) }

    private func pick(_ event: NSEvent, alternate: Bool, begins: Bool) {
        let point = convert(event.locationInWindow, from: nil)
        let radius = bounds.width / 2
        let x = (point.x - bounds.midX) / radius
        let y = (bounds.midY - point.y) / radius
        if begins { dragging = hypot(x, y) <= 1 }
        if dragging { change?(x, y, event.modifierFlags, alternate && event.buttonNumber == 1) }
    }
}

private func drawColorCheckerboard(in rect: CGRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    context.clip(to: rect)
    NSColor.white.setFill()
    rect.fill()
    NSColor(srgbRed: 0.72, green: 0.72, blue: 0.72, alpha: 1).setFill()
    let size: CGFloat = 4
    for row in 0..<Int(ceil(rect.height / size)) {
        for column in stride(from: row % 2, to: Int(ceil(rect.width / size)), by: 2) {
            CGRect(x: rect.minX + CGFloat(column) * size, y: rect.minY + CGFloat(row) * size,
                   width: size, height: size).fill()
        }
    }
    context.restoreGState()
}
