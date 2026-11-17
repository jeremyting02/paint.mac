import AppKit

_ = NSApplication.shared

let width = 4096, height = 2048
let fixture = LayerStack(layers: (0..<8).map { index in
    let pixels = Data(repeating: UInt8(120 + index), count: width * height * 4)
    let image = BGRA8.image(from: pixels, width: width, height: height)!
    return PaintLayer(name: "Layer \(index + 1)", image: image, pdnPixels: pixels)
}, active: 7)

final class Heartbeat {
    var last = DispatchTime.now().uptimeNanoseconds
    var longest: UInt64 = 0
    var ticks = 0

    func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        longest = max(longest, now - last)
        last = now
        ticks += 1
    }
}

func pump(until finished: () -> Bool) {
    let deadline = DispatchTime.now() + .seconds(60)
    while !finished() {
        precondition(DispatchTime.now() < deadline, "Timed out waiting for document command")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
    }
}

func measure(_ action: () -> Void, finished: () -> Bool) -> (gap: Double, elapsed: Double) {
    let probe = Heartbeat()
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in probe.tick() }
    RunLoop.main.add(timer, forMode: .common)
    defer { timer.invalidate() }
    pump { probe.ticks > 0 }
    probe.longest = 0
    let start = DispatchTime.now().uptimeNanoseconds
    action()
    pump(until: finished)
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    let lastTick = probe.ticks
    pump { probe.ticks > lastTick }
    return (Double(probe.longest) / 1_000_000, Double(elapsed) / 1_000_000)
}

let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: directory) }

func isIdle(_ document: PaintDocument) -> Bool {
    #if MAIN_THREAD_BASELINE
    true
    #else
    !document.hasBackgroundJob
    #endif
}

let effect = RasterFilter.effects.first { $0.title == "Add Noise" }!
let settings = effect.controls.map(\.initial)
for name in ["Bicubic resize to 2048x1024", "Repeat Add Noise", "PNG export"] {
    var samples = [(gap: Double, elapsed: Double)]()
    for trial in 0..<4 {
        let result = try autoreleasepool {
            let document = PaintDocument.newImage(width: width, height: height, resolution: .standard)!
            document.applyEdit(replacingStack: fixture, actionName: "Setup")
            let url = directory.appendingPathComponent("export-\(trial).png")
            switch name {
            case "Bicubic resize to 2048x1024":
                let result = measure({ document.performResize(width: 2048, height: 1024) },
                                     finished: { isIdle(document) })
                precondition(document.image?.width == 2048 && document.image?.height == 1024)
                precondition(document.historyEntries.last == "Resize")
                return result
            case "Repeat Add Noise":
                let input = document.filterInput()!
                document.commitFilter(effect, input: input, layer: input.layer, values: settings)
                let result = measure({ document.repeatEffect(nil) }, finished: { isIdle(document) })
                precondition(document.historyEntries.last == effect.title)
                return result
            default:
                let result = measure({
                    #if MAIN_THREAD_BASELINE
                    let data = try! PaintFiles.rasterData(fixture, as: .png, quality: 0.9)
                    try! data.write(to: url, options: .atomic)
                    #else
                    document.export(fixture, to: url, as: .png, quality: 0.9)
                    #endif
                }, finished: { isIdle(document) })
                let data = try Data(contentsOf: url)
                let image = try PaintFiles.readRaster(data)
                precondition(image.width == width && image.height == height && document.stack?.layers.count == 8)
                return result
            }
        }
        if trial > 0 { samples.append(result) }
    }
    let medianGap = samples.map(\.gap).sorted()[1]
    let worstGap = samples.map(\.gap).max()!
    let medianElapsed = samples.map(\.elapsed).sorted()[1]
    print(String(format: "%@ | median longest heartbeat gap %.1f ms | worst gap %.1f ms | median elapsed %.1f ms",
                 name, medianGap, worstGap, medianElapsed))
}
