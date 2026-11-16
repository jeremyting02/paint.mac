import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PaintLayer {
    var name: String
    var image: CGImage
    var isVisible = true
}

struct LayerStack {
    static let limit = 8
    var layers: [PaintLayer] // Bottom to top.
    var active: Int

    var activeLayer: PaintLayer { layers[active] }
    var needsProject: Bool { layers.count > 1 || !activeLayer.isVisible || activeLayer.name != "Background" }

    func draw(in context: CGContext, rect: CGRect, preview: CGImage? = nil) {
        for (index, layer) in layers.enumerated() where layer.isVisible {
            context.draw(index == active ? preview ?? layer.image : layer.image, in: rect)
        }
    }

    func flattened() -> CGImage? {
        let visible = layers.filter(\.isVisible)
        if visible.count == 1 { return visible[0].image }
        let image = activeLayer.image
        guard let bitmap = Self.makeBitmap(width: image.width, height: image.height) else { return nil }
        draw(in: bitmap, rect: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bitmap.makeImage()
    }

    static func makeBitmap(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

enum PaintFiles {
    private static let projectByteLimit = 280 * 1024 * 1024

    private struct Project: Codable {
        struct Layer: Codable {
            let name: String
            let isVisible: Bool
            let png: Data
        }

        let version: Int
        let active: Int
        let layers: [Layer]
    }

    static func readProject(_ data: Data) throws -> LayerStack {
        let invalid = CocoaError(.fileReadCorruptFile, userInfo: [
            NSLocalizedDescriptionKey: "The file could not be read as a paint.mac project."
        ])
        guard data.count <= projectByteLimit,
              let project = try? PropertyListDecoder().decode(Project.self, from: data),
              project.version == 1, project.layers.indices.contains(project.active),
              project.layers.count <= LayerStack.limit else { throw invalid }

        let layers = try project.layers.map { layer in
            PaintLayer(name: layer.name, image: try readPNG(layer.png), isVisible: layer.isVisible)
        }
        let size = layers[0].image
        guard layers.allSatisfy({ $0.image.width == size.width && $0.image.height == size.height }) else {
            throw invalid
        }
        return LayerStack(layers: layers, active: project.active)
    }

    static func projectData(_ stack: LayerStack) throws -> Data {
        let layers = try stack.layers.map { layer in
            Project.Layer(name: layer.name, isVisible: layer.isVisible, png: try pngData(layer.image))
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(Project(version: 1, active: stack.active, layers: layers))
        guard data.count <= projectByteLimit else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "The project exceeds 280 MiB."])
        }
        return data
    }

    static func readPNG(_ data: Data) throws -> CGImage {
        let corrupt = CocoaError(.fileReadCorruptFile, userInfo: [
            NSLocalizedDescriptionKey: "The file could not be read as a static PNG image."
        ])
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw corrupt }

        guard width <= 4096, height <= 4096, width * height <= 8_388_608 else {
            throw CocoaError(.fileReadTooLarge, userInfo: [
                NSLocalizedDescriptionKey: "PNG images can be at most 4,096 pixels per side and 8,388,608 pixels total."
            ])
        }

        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw corrupt }
        return image
    }

    static func pngData(_ image: CGImage) throws -> Data {
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return bytes as Data
    }
}
