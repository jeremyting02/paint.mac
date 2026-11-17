import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum RasterFormat: String, CaseIterable {
    case png = "public.png"
    case jpeg = "public.jpeg"
    case tiff = "public.tiff"
    case bmp = "com.microsoft.bmp"
    case gif = "com.compuserve.gif"
    case heic = "public.heic"
    case heif = "public.heif"
    case webp = "org.webmproject.webp"
    case avif = "public.avif"
    case jpegXL = "public.jpeg-xl"
    case dds = "com.microsoft.dds"
    case tga = "com.truevision.tga-image"

    static let readable = supported(by: CGImageSourceCopyTypeIdentifiers())
    static let writable: [Self] = {
        let installed = supported(by: CGImageDestinationCopyTypeIdentifiers())
        let needsProbe: Set<Self> = [.heic, .avif, .dds]
        let bitmap = LayerStack.makeBitmap(width: 64, height: 64)
        bitmap?.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        bitmap?.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let sample = bitmap?.makeImage()
        return installed.filter { format in
            // Codec identifiers can be advertised even when the corresponding hardware encoder is unavailable.
            guard needsProbe.contains(format) else { return true }
            return sample.flatMap { try? PaintFiles.rasterData($0, as: format) } != nil
        }
    }()

    private static func supported(by identifiers: CFArray) -> [Self] {
        let supported = Set(identifiers as? [String] ?? [])
        return allCases.filter { supported.contains($0.rawValue) }
    }

    var contentType: UTType { UTType(rawValue) ?? UTType(importedAs: rawValue, conformingTo: .image) }

    var filenameExtension: String {
        switch self {
        case .avif: return "avif"
        case .dds: return "dds"
        case .tga: return "tga"
        default: return contentType.preferredFilenameExtension ?? rawValue
        }
    }

    var displayName: String {
        switch self {
        case .jpeg: return "JPEG"
        case .jpegXL: return "JPEG XL"
        case .webp: return "WebP"
        default: return filenameExtension.uppercased()
        }
    }

    var isLossy: Bool { self == .jpeg || self == .heic || self == .avif || self == .webp || self == .jpegXL }

    var preservesColorProfile: Bool {
        switch self {
        case .png, .jpeg, .tiff, .heic, .heif, .webp, .avif, .jpegXL: return true
        case .bmp, .gif, .dds, .tga: return false
        }
    }
}

enum PaintFiles {
    struct Raster {
        let image: CGImage
        let resolution: ImageResolution?
        let colorProfile: RGBColorProfile?
    }

    static func readClipboardImage(_ data: Data) -> CGImage? { try? readRaster(data) }

    static func layersForImport(from url: URL) throws -> [PaintLayer] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let name = url.deletingPathExtension().lastPathComponent
        let layers = if url.pathExtension.lowercased() == "pdn" {
            try PDNFile.read(data).layers
        } else {
            [PaintLayer(name: "Background", image: try readRaster(data))]
        }
        return layers.map { layer in
            var imported = layer
            imported.name = "\(name): \(layer.name)"
            imported.isBackground = false
            return imported
        }
    }

    static func readRaster(_ data: Data, expected: RasterFormat? = nil) throws -> CGImage {
        try decodeRaster(data, expected: expected).image
    }

    static func decodeRaster(_ data: Data, expected: RasterFormat? = nil) throws -> Raster {
        let corrupt = CocoaError(.fileReadCorruptFile, userInfo: [
            NSLocalizedDescriptionKey: "The file could not be read as a supported bitmap image."
        ])
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              let format = RasterFormat(rawValue: type), expected == nil || expected == format,
              (format != .png || CGImageSourceGetCount(source) == 1) else { throw corrupt }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw corrupt }

        guard LayerStack.supportsCanvas(width: width, height: height) else {
            throw CocoaError(.fileReadTooLarge, userInfo: [
                NSLocalizedDescriptionKey: "Images can be at most 4,096 pixels per side and 8,388,608 pixels total."
            ])
        }

        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let image: CGImage?
        if (2...8).contains(orientation) {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                           kCGImageSourceCreateThumbnailWithTransform: true,
                                           kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
            image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, index, nil)
        }
        guard let image, CGImageSourceGetStatusAtIndex(source, index) == .statusComplete else { throw corrupt }
        let resolution: ImageResolution? = if let horizontal = properties[kCGImagePropertyDPIWidth] as? Double,
                                             let vertical = properties[kCGImagePropertyDPIHeight] as? Double {
            ImageResolution(horizontal: horizontal, vertical: vertical)
        } else {
            nil
        }
        let profile = RGBColorProfile.usefulProfile(for: image.colorSpace)
        let raster: CGImage
        if profile == nil, image.colorSpace?.name != CGColorSpace.sRGB {
            // PDN stores RGB pixels. Normalize the appearance of sources without a usable RGB profile.
            guard let pixels = BGRA8.pixels(from: image),
                  let converted = BGRA8.image(from: pixels, width: image.width, height: image.height)
            else { throw corrupt }
            raster = converted
        } else {
            raster = image
        }
        return Raster(image: raster, resolution: (5...8).contains(orientation) ? resolution?.transposed : resolution,
                      colorProfile: profile)
    }

    static func pngData(_ image: CGImage) throws -> Data { try rasterData(image, as: .png) }

    static func rasterData(_ image: CGImage, as format: RasterFormat, quality: Double = 0.9,
                           resolution: ImageResolution? = nil) throws -> Data {
        let bytes = NSMutableData()
        let failure = CocoaError(.fileWriteUnknown, userInfo: [
            NSLocalizedDescriptionKey: "The installed encoder could not export this image as \(format.displayName)."
        ])
        guard let destination = CGImageDestinationCreateWithData(bytes, format.rawValue as CFString, 1, nil)
        else { throw failure }
        // Image I/O's AVIF encoder rejects 1.0, which requests its unavailable lossless mode.
        let maximumQuality = format == .avif ? 0.99 : 1.0
        var properties: [CFString: Any] = format.isLossy
            ? [kCGImageDestinationLossyCompressionQuality: min(maximumQuality, max(0, quality))] : [:]
        if let resolution {
            properties[kCGImagePropertyDPIWidth] = resolution.horizontal
            properties[kCGImagePropertyDPIHeight] = resolution.vertical
        }
        let output: CGImage
        if format == .jpeg || format == .bmp {
            // These output formats use an opaque matte for transparent pixels.
            let outputSpace = format.preservesColorProfile && image.colorSpace?.model == .rgb
                ? image.colorSpace ?? BGRA8.sRGB : BGRA8.sRGB
            guard let bitmap = LayerStack.makeBitmap(width: image.width, height: image.height, colorSpace: outputSpace) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            bitmap.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            bitmap.fill(bounds)
            bitmap.draw(image, in: bounds)
            guard let flattened = bitmap.makeImage() else { throw CocoaError(.fileWriteUnknown) }
            output = flattened
        } else if !format.preservesColorProfile, image.colorSpace?.model == .rgb,
                  image.colorSpace?.name != CGColorSpace.sRGB {
            guard let pixels = BGRA8.pixels(from: image),
                  let converted = BGRA8.image(from: pixels, width: image.width, height: image.height)
            else { throw failure }
            output = converted
        } else {
            output = image
        }
        CGImageDestinationAddImage(destination, output, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw failure }
        return bytes as Data
    }
}
