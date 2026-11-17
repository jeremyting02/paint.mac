import AppKit
import Darwin
import Foundation

_ = NSApplication.shared
let resolution = ImageResolution.standard

func time(_ operation: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    autoreleasepool(invoking: operation)
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

func stats(_ label: String, _ values: [Double]) {
    let sorted = values.sorted()
    print(String(format: "%@ median %.3f ms, p95 %.3f ms", label, sorted[sorted.count / 2],
                 sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]))
}

func physicalFootprint() -> Double? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let entries = Int(count)
    let status = withUnsafeMutablePointer(to: &info) { info in
        info.withMemoryRebound(to: integer_t.self, capacity: entries) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : nil
}

func makeDocument(width: Int, height: Int, layerCount: Int) -> PaintDocument {
    let document = PaintDocument.newImage(width: width, height: height, resolution: resolution)!
    var stack = document.stack!
    stack.layers = (0..<layerCount).map { index in
        let bytes = Data(repeating: UInt8(120 + index), count: width * height * 4)
        return PaintLayer(name: "Layer", image: BGRA8.image(from: bytes, width: width, height: height)!,
                          pdnPixels: bytes)
    }
    stack.active = layerCount - 1
    document.applyEdit(replacingStack: stack, actionName: "Setup")
    return document
}

if CommandLine.arguments.contains("--initial") {
    let document = makeDocument(width: 4096, height: 2048, layerCount: 8)
    let zooms: [CGFloat?] = [100, nil]
    var samples = [[Double](), [Double]()]
    for trial in 0..<11 {
        for index in zooms.indices {
            autoreleasepool {
                let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
                let canvas = CanvasView(document: document)
                scroll.documentView = canvas
                canvas.setZoom(zooms[index])
                let viewport = canvas.visibleRect
                let output = LayerStack.makeBitmap(width: 900, height: 600)!
                output.translateBy(x: -viewport.minX, y: -viewport.minY)
                NSGraphicsContext.current = NSGraphicsContext(cgContext: output, flipped: false)
                defer { NSGraphicsContext.current = nil }
                let duration = time { canvas.draw(viewport) }
                if trial > 0 { samples[index].append(duration) }
            }
        }
    }
    for index in zooms.indices {
        let zoom = zooms[index] == nil ? "fit" : "100%"
        stats("4096x2048 / 8 layers / \(zoom) / initial draw", samples[index])
    }
    exit(0)
}

if CommandLine.arguments.contains("--history") {
    let document = PaintDocument.newImage(width: 2048, height: 2048, resolution: resolution)!
    document.undoManager = UndoManager()
    document.undoManager?.groupsByEvent = false
    let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
    let canvas = CanvasView(document: document)
    scroll.documentView = canvas
    canvas.tool = .pencil
    canvas.setZoom(100)
    let rect = canvas.canvasImageRect
    func event(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
        let point = canvas.convert(CGPoint(x: rect.midX + x, y: rect.midY - 50), to: nil)
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                  windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    let footprintBefore = physicalFootprint()
    let durations = (0..<24).map { index in
        time {
            let x = CGFloat(index * 5 + 5)
            canvas.mouseDown(with: event(.leftMouseDown, x: x))
            canvas.mouseUp(with: event(.leftMouseUp, x: x))
        }
    }
    precondition(document.historyPosition == 24 && document.undoManager?.canUndo == true)
    stats("2048x2048 / 24 pencil edits / pencil commit", durations)
    if let footprintBefore, let footprintAfter = physicalFootprint() {
        print(String(format: "Physical footprint after 24 strokes: %.1f MiB (%+.1f MiB during the workload)",
                     footprintAfter, footprintAfter - footprintBefore))
    }
    document.goToHistoryEntry(0)
    precondition(document.stack?.activeLayer.straightPixels?.allSatisfy { $0 == 255 } == true)
    document.goToHistoryEntry(24)
    precondition(document.stack?.activeLayer.straightPixels?.contains(0) == true)
    exit(0)
}

for (width, height, count) in [(2048, 1024, 4), (4096, 2048, 2), (4096, 2048, 8)] {
    let document = makeDocument(width: width, height: height, layerCount: count)
    let retainedStack = document.stack!
    stats("\(width)x\(height) / \(count) layers / full composite",
          (0..<7).map { _ in time { precondition(retainedStack.blendComposite() != nil) } })
    let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
    let canvas = CanvasView(document: document)
    scroll.documentView = canvas
    canvas.tool = .pencil
    let output = LayerStack.makeBitmap(width: 900, height: 600)!
    for zoom: CGFloat? in [100, nil] {
        canvas.setZoom(zoom)
        let viewport = canvas.visibleRect
        output.saveGState()
        output.translateBy(x: -viewport.minX, y: -viewport.minY)
        let graphics = NSGraphicsContext(cgContext: output, flipped: false)
        NSGraphicsContext.current = graphics
        let image = canvas.canvasImageRect
        func event(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type,
                location: canvas.convert(CGPoint(x: image.midX + x, y: image.midY + 17), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let label = "\(width)x\(height) / \(count) layers / \(zoom == nil ? "fit" : "100%")"
        stats("\(label) / initial draw", [time { canvas.draw(viewport) }])
        canvas.mouseDown(with: event(.leftMouseDown, x: -100))
        canvas.draw(viewport)
        var durations = [Double]()
        for index in 1...36 {
            let x = CGFloat(index * 5 - 100)
            let update = event(.leftMouseDragged, x: x)
            durations.append(time {
                canvas.mouseDragged(with: update)
                canvas.draw(viewport)
            })
        }
        stats("\(label) / pencil update + viewport draw", durations)
        let preview = canvas.copyableLayer?.straightPixels
        precondition(preview != nil && preview != retainedStack.activeLayer.straightPixels)
        canvas.cancelEditingGesture()
        NSGraphicsContext.current = nil
        output.restoreGState()
    }
}
