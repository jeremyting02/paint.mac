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
fileItem.submenu = fileMenu

app.mainMenu = menu
app.run()
