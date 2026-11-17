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

func makeDocument(width: Int, height: Int, layerCount: Int, patterned: Bool = false) -> PaintDocument {
    let document = PaintDocument.newImage(width: width, height: height, resolution: resolution)!
    var stack = document.stack!
    stack.layers = (0..<layerCount).map { index in
        var bytes = Data(repeating: UInt8(120 + index), count: width * height * 4)
        if patterned {
            bytes.withUnsafeMutableBytes { buffer in
                let pixels = buffer.bindMemory(to: UInt32.self)
                for pixel in pixels.indices {
                    let bits = UInt32(pixel) &* 2_654_435_761 &+ UInt32(index) &* 97_409
                    pixels[pixel] = (bits & 0x7fff_ffff) | 0x4000_0000
                }
            }
        }
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

#if METAL_MOVE_BENCHMARK
let translatesSelection = CommandLine.arguments.contains("--move-selection")
if translatesSelection || CommandLine.arguments.contains("--move-rotation") {
    setbuf(stdout, nil)
    guard let name = MetalMovePreview.deviceName else {
        fputs("Metal preview is unavailable\n", stderr)
        exit(1)
    }
    print("Metal device: \(name)")
    let width = 4096, height = 2048, frames = 15
    for count in [1, 4] {
        let document = makeDocument(width: width, height: height, layerCount: count, patterned: true)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let canvas = CanvasView(document: document)
        scroll.documentView = canvas
        canvas.tool = .moveSelectedPixels
        if translatesSelection {
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            canvas.setSelection(SelectionOutline(rect: bounds.insetBy(dx: 32, dy: 32))!)
        }
        for zoom: CGFloat? in [nil, 100] {
            canvas.setZoom(zoom)
            let viewport = canvas.visibleRect
            let image = canvas.canvasImageRect
            let output = LayerStack.makeBitmap(width: 900, height: 600)!
            output.translateBy(x: -viewport.minX, y: -viewport.minY)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: output, flipped: false)
            defer { NSGraphicsContext.current = nil }
            for metal in [false, true] {
                canvas.usesMetalMovePreview = metal
                canvas.draw(viewport)
                func event(_ type: NSEvent.EventType, step: Int) -> NSEvent {
                    let point = CGPoint(x: image.midX + 135 - (translatesSelection ? CGFloat(step * 2) : 0),
                                        y: image.midY + 30 + CGFloat(step * 5))
                    return NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil),
                        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                        eventNumber: step, clickCount: 1, pressure: 1)!
                }
                let down = event(translatesSelection ? .leftMouseDown : .rightMouseDown, step: 0)
                if translatesSelection { canvas.mouseDown(with: down) } else { canvas.rightMouseDown(with: down) }
                let samples = (1...frames).map { step in
                    let drag = event(translatesSelection ? .leftMouseDragged : .rightMouseDragged, step: step)
                    return time {
                        if translatesSelection { canvas.mouseDragged(with: drag) } else { canvas.rightMouseDragged(with: drag) }
                        canvas.draw(viewport)
                    }
                }
                let label = "\(width)x\(height) / \(count) layers / \(zoom == nil ? "fit" : "100%") / \(metal ? "Metal" : "CPU")"
                guard canvas.hasPendingMove, canvas.metalMovePreviewDraws == (metal ? frames : 0) else {
                    fputs("\(label) did not use the expected preview for all frames\n", stderr)
                    exit(1)
                }
                stats("\(label) / first \(translatesSelection ? "translation" : "rotation") frame", [samples[0]])
                stats("\(label) / subsequent drag + viewport draw", Array(samples.dropFirst()))
                canvas.cancelEditingGesture()
            }
        }
    }
    exit(0)
}
#endif

if CommandLine.arguments.contains("--move") {
    for count in [1, 4] {
        let document = makeDocument(width: 2048, height: 1536, layerCount: count)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let canvas = CanvasView(document: document)
        scroll.documentView = canvas
        canvas.tool = .moveSelectedPixels
        for zoom: CGFloat? in [100, nil] {
            canvas.setZoom(zoom)
            let viewport = canvas.visibleRect
            let image = canvas.canvasImageRect
            let output = LayerStack.makeBitmap(width: 900, height: 600)!
            output.translateBy(x: -viewport.minX, y: -viewport.minY)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: output, flipped: false)
            defer { NSGraphicsContext.current = nil }
            canvas.draw(viewport)
            for rotation in [false, true] {
                func event(_ type: NSEvent.EventType, step: Int) -> NSEvent {
                    let point = CGPoint(x: image.midX + 135, y: image.midY + 30 + CGFloat(step * 4))
                    return NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil),
                        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                let down = event(rotation ? .rightMouseDown : .leftMouseDown, step: 0)
                let start = time { if rotation { canvas.rightMouseDown(with: down) } else { canvas.mouseDown(with: down) } }
                let samples = (1...15).map { step in
                    let drag = event(rotation ? .rightMouseDragged : .leftMouseDragged, step: step)
                    return time {
                        if rotation { canvas.rightMouseDragged(with: drag) } else { canvas.mouseDragged(with: drag) }
                        canvas.draw(viewport)
                    }
                }
                precondition(canvas.hasPendingMove)
                let label = "2048x1536 / \(count) layers / \(zoom == nil ? "fit" : "100%") / \(rotation ? "rotate" : "translate")"
                stats("\(label) / gesture start", [start])
                stats("\(label) / drag + viewport draw", Array(samples.dropFirst()))
                canvas.cancelEditingGesture()
            }
        }
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
