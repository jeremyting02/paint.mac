import CoreGraphics

struct RectangleSelection {
    enum Sizing: String, CaseIterable {
        case anySize = "Any Size"
        case fixedRatio = "Fixed Ratio"
        case fixedSize = "Fixed Size"
    }

    enum Unit: String, CaseIterable {
        case pixels = "Pixels"
        case inches = "Inches"
        case centimeters = "Centimeters"

        func pixelsPerUnit(resolution: ImageResolution) -> CGSize {
            switch self {
            case .pixels: return CGSize(width: 1, height: 1)
            case .inches: return CGSize(width: resolution.horizontal, height: resolution.vertical)
            case .centimeters: return CGSize(width: resolution.horizontal / 2.54, height: resolution.vertical / 2.54)
            }
        }
    }

    var sizing = Sizing.anySize
    var ratio = CGSize(width: 4, height: 3)
    var size = CGSize(width: 100, height: 100)
    var unit = Unit.pixels

    mutating func changeUnit(to destination: Unit, resolution: ImageResolution) {
        let current = unit.pixelsPerUnit(resolution: resolution)
        let next = destination.pixelsPerUnit(resolution: resolution)
        size = CGSize(width: size.width * (current.width / next.width),
                      height: size.height * (current.height / next.height))
        unit = destination
    }

    func bounds(from anchor: CGPoint, to pointer: CGPoint, canvas: CGRect,
                resolution: ImageResolution, square: Bool = false) -> CGRect {
        if sizing == .fixedSize {
            let pixels = unit.pixelsPerUnit(resolution: resolution)
            let width = max(1, min(canvas.width, (size.width * pixels.width).rounded()))
            let height = max(1, min(canvas.height, (size.height * pixels.height).rounded()))
            let x = min(max(pointer.x, canvas.minX), canvas.maxX - width)
            // The pointer positions the upper-left corner. Canvas coordinates grow upward.
            let y = min(max(pointer.y - height, canvas.minY), canvas.maxY - height)
            return CGRect(x: x, y: y, width: width, height: height)
        }

        let dx = pointer.x - anchor.x, dy = pointer.y - anchor.y
        guard sizing == .fixedRatio || square else {
            return CGRect(x: min(anchor.x, pointer.x), y: min(anchor.y, pointer.y), width: abs(dx), height: abs(dy))
        }

        let aspect = sizing == .fixedRatio ? ratio.width / ratio.height : 1
        guard aspect.isFinite, aspect > 0 else { return .zero }
        let leftward = dx < 0 || (dx == 0 && anchor.x == canvas.maxX)
        let downward = dy < 0 || (dy == 0 && anchor.y == canvas.maxY)
        let roomX = leftward ? anchor.x - canvas.minX : canvas.maxX - anchor.x
        let roomY = downward ? anchor.y - canvas.minY : canvas.maxY - anchor.y
        let height = min(max(abs(dx) / aspect, abs(dy)), roomX / aspect, roomY)
        let width = min(height * aspect, roomX)
        return CGRect(x: leftward ? anchor.x - width : anchor.x, y: downward ? anchor.y - height : anchor.y,
                      width: width, height: height)
    }
}
