import AppKit

struct WorkspaceColor {
    var color: NSColor
    var hue: CGFloat = 0
    var saturation: CGFloat = 0
    var value: CGFloat = 0

    init(_ color: NSColor) {
        self.color = color
        let rgb = channels
        let sRGB = NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: rgb[3])
        (hue, saturation, value) = (sRGB.hueComponent, sRGB.saturationComponent, sRGB.brightnessComponent)
    }

    var channels: [CGFloat] {
        let rgb = color.usingColorSpace(.extendedSRGB) ?? .black.usingColorSpace(.sRGB)!
        return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
            .map { min(1, max(0, $0)) }
    }

    mutating func setHSV(hue: CGFloat, saturation: CGFloat, value: CGFloat) {
        (self.hue, self.saturation, self.value) = (hue, saturation, value)
        color = Self.hsvColor(hue: hue, saturation: saturation, value: value, alpha: color.alphaComponent)
    }

    static func hsvColor(hue: CGFloat, saturation: CGFloat, value: CGFloat, alpha: CGFloat = 1) -> NSColor {
        let rgb = hsvComponents(hue: hue, saturation: saturation, value: value)
        return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: alpha)
    }

    static func hsvComponents(hue: CGFloat, saturation: CGFloat, value: CGFloat)
        -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let position = hue * 6
        let sector = Int(position)
        let fraction = position - CGFloat(sector)
        let low = value * (1 - saturation)
        let falling = value * (1 - saturation * fraction)
        let rising = value * (1 - saturation * (1 - fraction))
        switch sector % 6 {
        case 0: return (value, rising, low)
        case 1: return (falling, value, low)
        case 2: return (low, value, rising)
        case 3: return (low, falling, value)
        case 4: return (rising, low, value)
        default: return (value, low, falling)
        }
    }

    mutating func setRGB(_ channels: [CGFloat]) {
        self = Self(NSColor(srgbRed: channels[0], green: channels[1], blue: channels[2], alpha: channels[3]))
    }

    mutating func setHex(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = text.hasPrefix("#") ? text.dropFirst() : text[...]
        guard hex.count == 6, let rgb = Self.parseHex(hex) else { return false }
        setRGB([Self.channel(rgb, 16), Self.channel(rgb, 8), Self.channel(rgb, 0), color.alphaComponent])
        return true
    }

    var rgbHex: String { String(format: "%06X", argb & 0xFFFFFF) }

    var argb: UInt32 {
        let bytes = channels.map { UInt32(Self.byte($0)) }
        return bytes[3] << 24 | bytes[0] << 16 | bytes[1] << 8 | bytes[2]
    }

    static func byte(_ channel: CGFloat) -> Int { Int((channel * 255).rounded()) }

    static func parseHex(_ hex: Substring) -> UInt32? {
        guard hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else { return nil }
        return UInt32(hex, radix: 16)
    }

    static func channel(_ color: UInt32, _ shift: Int) -> CGFloat { CGFloat((color >> shift) & 255) / 255 }

    static func fromARGB(_ color: UInt32) -> NSColor {
        NSColor(srgbRed: channel(color, 16), green: channel(color, 8), blue: channel(color, 0), alpha: channel(color, 24))
    }

    mutating func pickOnWheel(x: CGFloat, y: CGFloat, modifiers: NSEvent.ModifierFlags) {
        let distance = hypot(x, y)
        let angle = atan2(y, x) / (2 * .pi)
        var newHue = distance > 0 && !modifiers.contains(.option) ? (angle + 1).truncatingRemainder(dividingBy: 1) : hue
        if modifiers.contains(.shift) { newHue = (newHue * 24).rounded().truncatingRemainder(dividingBy: 24) / 24 }
        let newSaturation = modifiers.contains(.control) ? saturation : min(distance, 1)
        let isConstrained = !modifiers.intersection([.control, .option, .shift]).isEmpty
        setHSV(hue: newHue, saturation: newSaturation, value: isConstrained ? value : 1)
    }
}

enum WorkspacePalette {
    static let columns = 16
    static let count = 96

    // RGB values observed in the Paint.NET default palette. The final two rows repeat the first two at alpha 128.
    static let standard: [UInt32] = {
        let rgb: [UInt32] = [
            0x000000, 0x404040, 0xFF0000, 0xFF6A00, 0xFFD800, 0xB6FF00, 0x4CFF00, 0x00FF21,
            0x00FF90, 0x00FFFF, 0x0094FF, 0x0026FF, 0x4800FF, 0xB200FF, 0xFF00DC, 0xFF006E,
            0xFFFFFF, 0x808080, 0x7F0000, 0x7F3300, 0x7F6A00, 0x5B7F00, 0x267F00, 0x007F0E,
            0x007F46, 0x007F7F, 0x004A7F, 0x00137F, 0x21007F, 0x57007F, 0x7F006E, 0x7F0037,
            0xA0A0A0, 0x303030, 0xFF7F7F, 0xFFB27F, 0xFFE97F, 0xDAFF7F, 0xA5FF7F, 0x7FFF8E,
            0x7FFFC5, 0x7FFFFF, 0x7FC9FF, 0x7F92FF, 0xA17FFF, 0xD67FFF, 0xFF7FED, 0xFF7FB6,
            0xC0C0C0, 0x606060, 0x7F3F3F, 0x7F593F, 0x7F743F, 0x6D7F3F, 0x527F3F, 0x3F7F47,
            0x3F7F62, 0x3F7F7F, 0x3F647F, 0x3F497F, 0x503F7F, 0x6B3F7F, 0x7F3F76, 0x7F3F5B
        ]
        return rgb.map { 0xFF000000 | $0 } + rgb.prefix(32).map { 0x80000000 | $0 }
    }()

    enum ReadError: LocalizedError {
        case invalidLine(Int)
        case invalidFile

        var errorDescription: String? {
            switch self {
            case .invalidLine(let number): return "Expected an eight-digit AARRGGBB color on line \(number)."
            case .invalidFile: return "The palette must be a UTF-8 or UTF-16 text file no larger than 256 KB."
            }
        }
    }

    static func parse(_ text: String) throws -> [UInt32] {
        var colors: [UInt32] = []
        for (index, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let entry = line.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}")))
            if entry.isEmpty || entry.hasPrefix(";") { continue }
            guard entry.count == 8, let color = WorkspaceColor.parseHex(entry[...]) else {
                throw ReadError.invalidLine(index + 1)
            }
            colors.append(color)
            if colors.count == count { return colors }
        }
        return colors + Array(repeating: 0xFFFFFFFF, count: count - colors.count)
    }

    static func read(from url: URL) throws -> [UInt32] {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let limit = 256 * 1024
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ReadError.invalidFile }
        let hasUTF16BOM = data.starts(with: [0xFE, 0xFF]) || data.starts(with: [0xFF, 0xFE])
        guard let text = String(data: data, encoding: hasUTF16BOM ? .utf16 : .utf8) else { throw ReadError.invalidFile }
        return try parse(text)
    }

    static func serialize(_ colors: [UInt32]) -> String {
        "; Paint.NET Palette File\r\n" + colors.map { String(format: "%08X", $0) }.joined(separator: "\r\n") + "\r\n"
    }
}

@MainActor
final class WorkspaceColors {
    static let shared = WorkspaceColors()
    static let changed = Notification.Name("WorkspaceColorsChanged")

    enum Slot: Int, CaseIterable {
        case primary, secondary
        var other: Slot { self == .primary ? .secondary : .primary }
        var name: String { self == .primary ? "Primary" : "Secondary" }
    }

    private let defaults: UserDefaults
    private var colors = [WorkspaceColor(.black), WorkspaceColor(.white)]
    private(set) var active = Slot.primary
    private(set) var expanded: Bool
    private(set) var palette: [UInt32]
    private(set) var paletteName: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        expanded = defaults.bool(forKey: "ColorsExpanded")
        let saved = defaults.stringArray(forKey: "ColorsPalette")?.compactMap { WorkspaceColor.parseHex($0[...]) }
        if let saved, saved.count == WorkspacePalette.count {
            palette = saved
            paletteName = defaults.string(forKey: "ColorsPaletteName")
        } else {
            palette = WorkspacePalette.standard
        }
    }

    subscript(_ slot: Slot) -> WorkspaceColor { colors[slot.rawValue] }

    func select(_ slot: Slot) {
        active = slot
        notify()
    }

    func set(_ color: WorkspaceColor, for slot: Slot) {
        colors[slot.rawValue] = color
        notify()
    }

    func swap() {
        colors.swapAt(0, 1)
        notify()
    }

    func reset() {
        colors = [WorkspaceColor(.black), WorkspaceColor(.white)]
        notify()
    }

    func toggleExpanded() {
        expanded.toggle()
        defaults.set(expanded, forKey: "ColorsExpanded")
        notify()
    }

    func setPalette(_ colors: [UInt32], name: String?) {
        palette = colors
        paletteName = name
        defaults.set(colors.map { String(format: "%08X", $0) }, forKey: "ColorsPalette")
        defaults.set(name, forKey: "ColorsPaletteName")
        notify()
    }

    private func notify() { NotificationCenter.default.post(name: Self.changed, object: self) }
}
