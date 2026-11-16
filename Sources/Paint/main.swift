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
fileMenu.addItem(withTitle: "New", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
fileMenu.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
fileMenu.addItem(.separator())
fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
fileMenu.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
let saveAs = fileMenu.addItem(withTitle: "Save As…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "s")
saveAs.keyEquivalentModifierMask = [.command, .shift]
fileMenu.addItem(withTitle: "Export PNG…", action: #selector(PaintDocument.exportPNG(_:)), keyEquivalent: "")
fileItem.submenu = fileMenu

let editItem = menu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "")
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: #selector(PaintDocument.undoStroke(_:)), keyEquivalent: "z")
editMenu.addItem(withTitle: "Redo", action: #selector(PaintDocument.redoStroke(_:)), keyEquivalent: "y")
editMenu.addItem(.separator())
editMenu.addItem(withTitle: "Cut", action: #selector(PaintDocument.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(PaintDocument.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(PaintDocument.paste(_:)), keyEquivalent: "v")
editMenu.addItem(.separator())
let copySelection = editMenu.addItem(withTitle: "Copy Selection", action: #selector(PaintDocument.copySelection(_:)), keyEquivalent: "c")
copySelection.keyEquivalentModifierMask = [.command, .option, .shift]
let pasteSelection = editMenu.addItem(withTitle: "Paste Selection", action: #selector(PaintDocument.pasteSelection(_:)), keyEquivalent: "v")
pasteSelection.keyEquivalentModifierMask = [.command, .option, .shift]
editMenu.addItem(withTitle: "Deselect", action: #selector(PaintDocument.deselect(_:)), keyEquivalent: "d")
editItem.submenu = editMenu

let imageItem = menu.addItem(withTitle: "Image", action: nil, keyEquivalent: "")
let imageMenu = NSMenu(title: "Image")
let crop = imageMenu.addItem(withTitle: "Crop to Selection", action: #selector(PaintDocument.cropSelection(_:)), keyEquivalent: "x")
crop.keyEquivalentModifierMask = [.command, .shift]
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
layerItem.submenu = layerMenu

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
