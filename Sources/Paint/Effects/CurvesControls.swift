import AppKit

@MainActor
protocol TonalAdjustmentControls: AnyObject {
    var view: NSView { get }
    var didChange: (() -> Void)? { get set }
    func renderFilter() -> RasterFilter
    func reset()
}

extension RGBChannel {
    var graphColor: NSColor {
        switch self {
        case .red: return .systemRed
        case .green: return .systemGreen
        case .blue: return .systemBlue
        }
    }
}

final class CurvesControls: NSStackView, TonalAdjustmentControls {
    private let mode = NSPopUpButton()
    private let graph = CurveGraphView()
    private var channels: [NSButton] = []
    private var settings = CurveSettings()
    var view: NSView { self }
    var didChange: (() -> Void)?

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 12

        mode.addItems(withTitles: ["Luminosity", "RGB"])
        mode.setAccessibilityLabel("Transfer map")
        mode.target = self
        mode.action = #selector(changeCurveMode(_:))
        addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: "Transfer map"), mode]))
        addArrangedSubview(graph)
        graph.widthAnchor.constraint(equalToConstant: 340).isActive = true
        graph.heightAnchor.constraint(equalToConstant: 300).isActive = true
        for channel in RGBChannel.allCases {
            let button = NSButton(checkboxWithTitle: channel.title, target: self, action: #selector(changeChannels))
            button.state = .on
            button.tag = channel.rawValue
            channels.append(button)
        }
        addArrangedSubview(NSStackView(views: channels))
        graph.didEdit = { [weak self] curves in
            guard let self else { return }
            if settings.mode == .luminosity { settings.luminosity = curves[0] }
            else { settings.rgb = curves }
            didChange?()
        }
        updateGraph()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func renderFilter() -> RasterFilter { settings.filter() }

    func reset() {
        settings = CurveSettings()
        mode.selectItem(at: CurveSettings.Mode.luminosity.rawValue)
        for button in channels { button.state = .on }
        updateGraph()
    }

    private func updateGraph() {
        let isRGB = settings.mode == .rgb
        for button in channels { button.isEnabled = isRGB }
        let editable = isRGB ? channels.filter { $0.state == .on }.map(\.tag) : [0]
        graph.setCurves(isRGB ? settings.rgb : [settings.luminosity], editable: editable)
    }

    @objc private func changeCurveMode(_ sender: NSPopUpButton) {
        guard let selected = CurveSettings.Mode(rawValue: sender.indexOfSelectedItem) else { return }
        settings.mode = selected
        updateGraph()
        didChange?()
    }

    @objc private func changeChannels() { updateGraph() }
}

final class CurveGraphView: NSView {
    private var curves = [CurveGraph()]
    private var editable = [0]
    private var selection: Int?
    private var dragSource: [CurveGraph]?
    private var dragInput: Int?
    var didEdit: (([CurveGraph]) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        setAccessibilityLabel("Input and output tone curve")
        setAccessibilityRole(.group)
        setAccessibilityHelp("Click to add a point, then drag to move it. Right-click to remove an interior point. Use Option plus Left or Right to select a point and arrow keys to move it.")
        toolTip = "Drag to move a control point. Right-click to remove an interior point."
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setCurves(_ curves: [CurveGraph], editable: [Int]) {
        self.curves = curves
        self.editable = editable
        selection = nil
        dragSource = nil
        dragInput = nil
        needsDisplay = true
    }

    private var plot: CGRect { bounds.insetBy(dx: 28, dy: 21) }

    override func draw(_ dirtyRect: NSRect) {
        let rect = plot
        guard rect.width > 0, rect.height > 0 else { return }
        NSColor.controlBackgroundColor.setFill()
        rect.fill()
        NSColor.gridColor.setStroke()
        let grid = NSBezierPath()
        for index in 0...4 {
            let x = rect.minX + CGFloat(index) * rect.width / 4
            let y = rect.minY + CGFloat(index) * rect.height / 4
            grid.move(to: CGPoint(x: rect.minX, y: y))
            grid.line(to: CGPoint(x: rect.maxX, y: y))
            grid.move(to: CGPoint(x: x, y: rect.minY))
            grid.line(to: CGPoint(x: x, y: rect.maxY))
        }
        grid.lineWidth = 0.5
        grid.stroke()

        let axisLabel: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        ]
        ("0" as NSString).draw(at: CGPoint(x: rect.minX, y: 4), withAttributes: axisLabel)
        ("255" as NSString).draw(at: CGPoint(x: rect.maxX - 17, y: 4), withAttributes: axisLabel)
        ("255" as NSString).draw(at: CGPoint(x: 4, y: rect.maxY - 3), withAttributes: axisLabel)
        for (index, curve) in curves.enumerated() {
            let color = curves.count == 1 ? NSColor.labelColor : RGBChannel.allCases[index].graphColor
            color.withAlphaComponent(editable.contains(index) ? 0.95 : 0.4).setStroke()
            let path = NSBezierPath()
            let table = curve.table
            path.move(to: position(input: 0, output: Int(table[0])))
            for input in 1...255 { path.line(to: position(input: input, output: Int(table[input]))) }
            path.lineWidth = 1.5
            path.stroke()
            guard editable.contains(index) else { continue }
            for point in curve.points {
                let center = position(input: point.input, output: point.output)
                let radius: CGFloat = selection == point.input ? 4.5 : 3.5
                let knot = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                       width: 2 * radius, height: 2 * radius))
                NSColor.controlBackgroundColor.setFill()
                knot.fill()
                knot.lineWidth = 1.5
                knot.stroke()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !editable.isEmpty else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard plot.insetBy(dx: -8, dy: -8).contains(location) else { return }
        window?.makeFirstResponder(self)
        let next = point(at: location)
        let knot = closestPoint(to: location)
        dragSource = curves
        dragInput = knot?.input ?? next.input
        selection = dragInput
        if knot == nil { updateCurves(from: curves, moving: nil, to: next) }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let original = dragSource, let input = dragInput else { return }
        updateCurves(from: original, moving: input, to: point(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        dragSource = nil
        dragInput = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let knot = closestPoint(to: convert(event.locationInWindow, from: nil)) else { return }
        removePoint(at: knot.input)
    }

    override func keyDown(with event: NSEvent) {
        guard let channel = editable.first else { return super.keyDown(with: event) }
        let points = curves[channel].points
        if event.modifierFlags.contains(.option), event.keyCode == 123 || event.keyCode == 124 {
            let index = points.firstIndex { $0.input == selection } ?? (event.keyCode == 123 ? points.count : -1)
            selection = points[min(points.count - 1, max(0, index + (event.keyCode == 123 ? -1 : 1)))].input
            needsDisplay = true
            return
        }
        guard let knot = points.first(where: { $0.input == selection }) else { return super.keyDown(with: event) }
        let step = event.modifierFlags.contains(.shift) ? 10 : 1
        let delta: (Int, Int)
        switch event.keyCode {
        case 51, 117: removePoint(at: knot.input); return
        case 123: delta = (-step, 0)
        case 124: delta = (step, 0)
        case 125: delta = (0, -step)
        case 126: delta = (0, step)
        default: return super.keyDown(with: event)
        }
        updateCurves(from: curves, moving: knot.input,
                     to: .init(input: knot.input + delta.0, output: knot.output + delta.1))
    }

    private func updateCurves(from original: [CurveGraph], moving input: Int?, to point: CurveGraph.Point) {
        var updated = original
        var output = point
        if let input {
            let bounds = editable.map { original[$0].boundsForMovingPoint(at: input) }
            let lower = bounds.map(\.lowerBound).max() ?? 0
            let upper = bounds.map(\.upperBound).min() ?? 255
            output = .init(input: min(upper, max(lower, point.input)), output: point.output)
        }
        for index in editable { updated[index].setPoint(output, replacing: input) }
        selection = output.input
        publish(updated)
    }

    private func removePoint(at input: Int) {
        var updated = curves
        for index in editable { updated[index].removePoint(at: input) }
        selection = nil
        publish(updated)
    }

    private func publish(_ updated: [CurveGraph]) {
        if updated != curves {
            curves = updated
            didEdit?(updated)
        }
        needsDisplay = true
    }

    private func closestPoint(to location: CGPoint) -> CurveGraph.Point? {
        var closest: CurveGraph.Point?
        var distance = 9.0
        for channel in editable {
            for knot in curves[channel].points {
                let center = position(input: knot.input, output: knot.output)
                let candidate = hypot(center.x - location.x, center.y - location.y)
                if candidate < distance {
                    closest = knot
                    distance = candidate
                }
            }
        }
        return closest
    }

    private func position(input: Int, output: Int) -> CGPoint {
        CGPoint(x: plot.minX + plot.width * CGFloat(input) / 255,
                y: plot.minY + plot.height * CGFloat(output) / 255)
    }

    private func point(at location: CGPoint) -> CurveGraph.Point {
        let x = (location.x - plot.minX) / plot.width
        let y = (location.y - plot.minY) / plot.height
        return .init(input: Int((min(1, max(0, x)) * 255).rounded()),
                     output: Int((min(1, max(0, y)) * 255).rounded()))
    }
}
