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
let redo = editMenu.addItem(withTitle: "Redo", action: #selector(PaintDocument.redoStroke(_:)), keyEquivalent: "z")
redo.keyEquivalentModifierMask = [.command, .shift]
editItem.submenu = editMenu

let layerItem = menu.addItem(withTitle: "Layer", action: nil, keyEquivalent: "")
let layerMenu = NSMenu(title: "Layer")
for command in PaintDocument.LayerCommand.allCases {
    let item = layerMenu.addItem(withTitle: command.title, action: #selector(PaintDocument.layerCommand(_:)), keyEquivalent: "")
    item.tag = command.rawValue
    if command == .properties {
        layerMenu.insertItem(.separator(), at: layerMenu.numberOfItems - 1)
        item.keyEquivalent = String(UnicodeScalar(Int(NSF4FunctionKey))!)
        item.keyEquivalentModifierMask = []
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
