import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
_ = NSDocumentController.shared

let menu = NSMenu()
let appItem = menu.addItem(withTitle: "paint.mac", action: nil, keyEquivalent: "")
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit paint.mac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu

let fileItem = menu.addItem(withTitle: "File", action: nil, keyEquivalent: "")
let fileMenu = NSMenu(title: "File")
fileMenu.addItem(withTitle: "New…", action: #selector(NewImageCommand.show(_:)), keyEquivalent: "n").target = NewImageCommand.shared
fileMenu.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
fileMenu.addItem(.separator())
fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
fileMenu.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
let saveAs = fileMenu.addItem(withTitle: "Save As…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "s")
saveAs.keyEquivalentModifierMask = [.command, .shift]
fileMenu.addItem(withTitle: "Export…", action: #selector(PaintDocument.exportImage(_:)), keyEquivalent: "")
fileItem.submenu = fileMenu

let editItem = menu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "")
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: #selector(PaintDocument.undoStroke(_:)), keyEquivalent: "z")
editMenu.addItem(withTitle: "Redo", action: #selector(PaintDocument.redoStroke(_:)), keyEquivalent: "y")
editMenu.addItem(.separator())
editMenu.addItem(withTitle: "Cut", action: #selector(PaintDocument.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(PaintDocument.copy(_:)), keyEquivalent: "c")
let copyFlattened = editMenu.addItem(withTitle: "Copy Flattened", action: #selector(PaintDocument.copyFlattened(_:)), keyEquivalent: "c")
copyFlattened.keyEquivalentModifierMask = [.command, .shift]
editMenu.addItem(withTitle: "Paste", action: #selector(PaintDocument.paste(_:)), keyEquivalent: "v")
let pasteLayer = editMenu.addItem(withTitle: "Paste into New Layer", action: #selector(PaintDocument.pasteIntoNewLayer(_:)), keyEquivalent: "v")
pasteLayer.keyEquivalentModifierMask = [.command, .shift]
let pasteImage = editMenu.addItem(withTitle: "Paste into New Image", action: #selector(PaintDocument.pasteIntoNewImage(_:)), keyEquivalent: "v")
pasteImage.keyEquivalentModifierMask = [.command, .option]
editMenu.addItem(.separator())
let copySelection = editMenu.addItem(withTitle: "Copy Selection", action: #selector(PaintDocument.copySelection(_:)), keyEquivalent: "c")
copySelection.keyEquivalentModifierMask = [.command, .option, .shift]
let pasteSelectionMenu = NSMenu(title: "Paste Selection")
editMenu.addItem(withTitle: "Paste Selection", action: nil, keyEquivalent: "").submenu = pasteSelectionMenu
for (index, mode) in SelectionOutline.Mode.allCases.enumerated() {
    let item = pasteSelectionMenu.addItem(withTitle: mode.rawValue, action: #selector(PaintDocument.pasteSelection(_:)),
                                          keyEquivalent: mode == .replace ? "v" : "")
    item.tag = index
    if mode == .replace { item.keyEquivalentModifierMask = [.command, .option, .shift] }
}
editMenu.addItem(withTitle: "Select All", action: #selector(PaintDocument.selectAllPixels(_:)), keyEquivalent: "a")
editMenu.addItem(withTitle: "Invert Selection", action: #selector(PaintDocument.invertPixelSelection(_:)), keyEquivalent: "i")
let eraseSelection = editMenu.addItem(withTitle: "Erase Selection", action: #selector(PaintDocument.eraseSelectedPixels(_:)),
                                     keyEquivalent: String(UnicodeScalar(Int(NSDeleteFunctionKey))!))
eraseSelection.keyEquivalentModifierMask = []
let fillSelection = editMenu.addItem(withTitle: "Fill Selection", action: #selector(PaintDocument.fillSelectedPixels(_:)),
                                     keyEquivalent: "\u{7f}")
fillSelection.keyEquivalentModifierMask = []
editMenu.addItem(withTitle: "Deselect", action: #selector(PaintDocument.deselect(_:)), keyEquivalent: "d")
editItem.submenu = editMenu

let viewMenu = NSMenu(title: "View")
menu.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = viewMenu
viewMenu.addItem(withTitle: "Rulers", action: #selector(PaintDocument.toggleWorkspaceRulers(_:)), keyEquivalent: "")
viewMenu.addItem(withTitle: "Pixel Grid", action: #selector(PaintDocument.toggleWorkspaceGrid(_:)), keyEquivalent: "")

let imageItem = menu.addItem(withTitle: "Image", action: nil, keyEquivalent: "")
let imageMenu = NSMenu(title: "Image")
let crop = imageMenu.addItem(withTitle: "Crop to Selection", action: #selector(PaintDocument.cropSelection(_:)), keyEquivalent: "x")
crop.keyEquivalentModifierMask = [.command, .shift]
for (index, command) in ImageCommand.allCases.enumerated() {
    if command == .flipHorizontal { imageMenu.addItem(.separator()) }
    let item = imageMenu.addItem(withTitle: command.title, action: #selector(PaintDocument.imageCommand(_:)), keyEquivalent: "")
    item.tag = index
    if command == .resize || command == .canvasSize {
        item.keyEquivalent = "r"
        if command == .canvasSize { item.keyEquivalentModifierMask = [.command, .shift] }
    }
}
imageMenu.addItem(.separator())
let flatten = imageMenu.addItem(withTitle: "Flatten", action: #selector(PaintDocument.flattenLayers(_:)), keyEquivalent: "f")
flatten.keyEquivalentModifierMask = [.command, .shift]
imageItem.submenu = imageMenu

let layerItem = menu.addItem(withTitle: "Layer", action: nil, keyEquivalent: "")
let layerMenu = NSMenu(title: "Layer")
for command in PaintDocument.LayerCommand.allCases {
    let item = layerMenu.addItem(withTitle: command.title, action: #selector(PaintDocument.layerCommand(_:)), keyEquivalent: "")
    item.tag = command.rawValue
    switch command {
    case .duplicate:
        item.keyEquivalent = "d"
        item.keyEquivalentModifierMask = [.command, .shift]
    case .mergeDown:
        item.keyEquivalent = "m"
    case .properties:
        layerMenu.insertItem(.separator(), at: layerMenu.numberOfItems - 1)
        item.keyEquivalent = String(UnicodeScalar(Int(NSF4FunctionKey))!)
        item.keyEquivalentModifierMask = []
    default: break
    }
}
layerMenu.insertItem(withTitle: "Flip Horizontal", action: #selector(PaintDocument.flipLayerHorizontal(_:)),
                     keyEquivalent: "", at: layerMenu.numberOfItems - 2)
layerMenu.insertItem(withTitle: "Flip Vertical", action: #selector(PaintDocument.flipLayerVertical(_:)),
                     keyEquivalent: "", at: layerMenu.numberOfItems - 2)
layerMenu.insertItem(withTitle: "Rotate 180°", action: #selector(PaintDocument.rotateLayer180(_:)),
                     keyEquivalent: "", at: layerMenu.numberOfItems - 2)
let rotateZoom = layerMenu.insertItem(withTitle: "Rotate / Zoom…", action: #selector(PaintDocument.rotateZoomLayer(_:)),
                                     keyEquivalent: "z", at: layerMenu.numberOfItems - 2)
rotateZoom.keyEquivalentModifierMask = [.command, .shift]
layerItem.submenu = layerMenu

let adjustmentsMenu = NSMenu(title: "Adjustments")
menu.addItem(withTitle: "Adjustments", action: nil, keyEquivalent: "").submenu = adjustmentsMenu
let adjustmentShortcuts: [String: (key: String, modifiers: NSEvent.ModifierFlags)] = [
    "Auto-Level": ("l", [.command, .shift]),
    "Black and White": ("g", [.command, .shift]),
    "Brightness / Contrast": ("t", [.command, .shift]),
    "Curves": ("m", [.command, .shift]),
    "Hue / Saturation": ("u", [.command, .shift]),
    "Invert Alpha": ("i", [.command, .option]),
    "Invert Colors": ("i", [.command, .shift]),
    "Levels": ("l", .command),
    "Posterize": ("p", [.command, .shift]),
    "Sepia": ("e", [.command, .shift])
]
for (index, filter) in RasterFilter.adjustments.enumerated() {
    let title = filter.title + (filter.controls.isEmpty && filter.editor == nil ? "" : "…")
    let shortcut = adjustmentShortcuts[filter.title]
    let item = adjustmentsMenu.addItem(withTitle: title, action: #selector(PaintDocument.applyAdjustment(_:)),
                                       keyEquivalent: shortcut?.key ?? "")
    item.keyEquivalentModifierMask = shortcut?.modifiers ?? []
    item.tag = index
}

let effectsMenu = NSMenu(title: "Effects")
menu.addItem(withTitle: "Effects", action: nil, keyEquivalent: "").submenu = effectsMenu
effectsMenu.addItem(withTitle: "Repeat Last Effect", action: #selector(PaintDocument.repeatEffect(_:)), keyEquivalent: "f")
effectsMenu.addItem(.separator())
let categories = Dictionary(grouping: RasterFilter.effects.enumerated()) { $0.element.category ?? "Other" }
for category in categories.keys.sorted() {
    let submenu = NSMenu(title: category)
    effectsMenu.addItem(withTitle: category, action: nil, keyEquivalent: "").submenu = submenu
    for (index, filter) in categories[category, default: []] {
        let title = filter.title + (filter.controls.isEmpty ? "" : "…")
        let item = submenu.addItem(withTitle: title, action: #selector(PaintDocument.applyEffect(_:)), keyEquivalent: "")
        item.tag = index
    }
}

let windowItem = menu.addItem(withTitle: "Window", action: nil, keyEquivalent: "")
let windowMenu = NSMenu(title: "Window")
for kind in UtilityPanels.Kind.allCases {
    let item = windowMenu.addItem(withTitle: kind.title, action: #selector(PaintDocument.toggleUtilityPanel(_:)),
                                  keyEquivalent: kind.keyEquivalent)
    item.tag = kind.rawValue
    item.keyEquivalentModifierMask = []
}
windowMenu.addItem(.separator())
windowMenu.addItem(withTitle: "Reset Panel Layout", action: #selector(PaintDocument.resetUtilityPanels(_:)), keyEquivalent: "")
windowItem.submenu = windowMenu
app.windowsMenu = windowMenu

app.mainMenu = menu
app.run()
