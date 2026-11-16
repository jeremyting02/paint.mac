import CoreGraphics
import Foundation

struct SelectionOutline: Equatable {
    let path: CGPath

    init?(path: CGPath) {
        guard !path.isEmpty, !path.boundingBoxOfPath.isEmpty else { return nil }
        self.path = path
    }

    init?(rect: CGRect) {
        self.init(path: CGPath(rect: rect, transform: nil))
    }

    var bounds: CGRect { path.boundingBoxOfPath }

    var pixelRectangle: Bool {
        var rect = CGRect.zero
        return path.isRect(&rect) && rect == rect.integral
    }

    func transformed(by transform: CGAffineTransform) -> Self? {
        var transform = transform
        return path.copy(using: &transform).flatMap(Self.init(path:))
    }

    func clipped(to rect: CGRect) -> Self? {
        if rect.contains(bounds) { return self }
        if !rect.intersects(bounds) { return nil }
        return Self(path: path.intersection(CGPath(rect: rect, transform: nil), using: .evenOdd))
    }

    // One byte per pixel in image row order, using the same coordinate conversion as cropping.
    func mask(in region: CGRect, imageHeight: Int) -> Data? {
        let width = Int(region.width), height = Int(region.height)
        var bytes = Data(count: width * height)
        let rendered = bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            guard let bitmap = CGContext(data: buffer.baseAddress, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                         bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            bitmap.translateBy(x: -region.minX, y: region.maxY - CGFloat(imageHeight))
            bitmap.setAllowsAntialiasing(false)
            bitmap.setFillColor(gray: 1, alpha: 1)
            bitmap.addPath(path)
            bitmap.fillPath(using: .evenOdd)
            return true
        }
        return rendered ? bytes : nil
    }

    private struct ClipboardGeometry: Codable {
        let polygonList: [String]
    }

    private static func coordinateText(_ value: CGFloat) -> String {
        if let integer = Int(exactly: value) { return String(integer) }
        return String(Double(value))
    }

    func clipboardText(imageHeight: Int) -> String? {
        var polygons: [String] = []
        var vertices: [String] = []
        path.applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint:
                let point = element.pointee.points[0]
                let x = Self.coordinateText(point.x)
                let y = Self.coordinateText(CGFloat(imageHeight) - point.y)
                vertices.append("\(x),\(y)")
            case .closeSubpath:
                if let first = vertices.first { vertices.append(first) }
                polygons.append(vertices.joined(separator: ","))
                vertices.removeAll(keepingCapacity: true)
            default: break
            }
        }
        guard !polygons.isEmpty, let data = try? JSONEncoder().encode(ClipboardGeometry(polygonList: polygons)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    init?(clipboardText: String, imageHeight: Int) {
        guard clipboardText.utf8.count <= 262_144,
              let geometry = try? JSONDecoder().decode(ClipboardGeometry.self, from: Data(clipboardText.utf8)) else { return nil }
        let path = CGMutablePath()
        var vertexCount = 0
        for polygon in geometry.polygonList {
            let values = polygon.split(separator: ",", omittingEmptySubsequences: false)
            guard values.count >= 6, values.count.isMultiple(of: 2) else { return nil }
            vertexCount += values.count / 2
            guard vertexCount <= 8192 else { return nil }
            for index in stride(from: 0, to: values.count, by: 2) {
                guard let x = Double(values[index].trimmingCharacters(in: .whitespacesAndNewlines)),
                      let y = Double(values[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)),
                      abs(x) <= 1e7, abs(y) <= 1e7 else { return nil }
                let point = CGPoint(x: x, y: Double(imageHeight) - y)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        }
        self.init(path: path.normalized(using: .evenOdd))
    }
}
