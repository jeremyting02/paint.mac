import AppKit

final class LayersView: NSStackView, NSTableViewDataSource, NSTableViewDelegate {
    private weak var document: PaintDocument?
    private let table = NSTableView()
    private let add = EditorView.icon("plus", label: "Add Layer")
    private let up = EditorView.icon("arrow.up", label: "Move Layer Up")
    private let down = EditorView.icon("arrow.down", label: "Move Layer Down")
    private let delete = EditorView.icon("trash", label: "Delete Layer")
    private let properties = EditorView.icon("wrench", label: "Layer Properties")
    private var refreshing = false

    init(document: PaintDocument) {
        self.document = document
        super.init(frame: .zero)
        orientation = .vertical
        spacing = 6

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Layer"))
        column.width = 144
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.backgroundColor = .clear
        table.allowsEmptySelection = false
        table.setAccessibilityLabel("Layer Stack")
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openClickedLayer(_:))

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = table
        addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(equalToConstant: 102).isActive = true
        scroll.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

        let buttons = NSStackView(views: [add, up, down, delete, properties])
        buttons.spacing = 3
        addArrangedSubview(buttons)
        for button in [add, up, down, delete, properties] { button.target = self }
        add.action = #selector(addLayer(_:))
        up.action = #selector(moveLayer(_:))
        down.action = #selector(moveLayer(_:))
        up.tag = 1
        down.tag = -1
        delete.action = #selector(deleteLayer(_:))
        properties.action = #selector(openProperties(_:))
    }

    required init?(coder: NSCoder) { nil }

    func refresh() {
        guard let stack = document?.stack else { return }
        refreshing = true
        table.reloadData()
        let row = stack.layers.count - 1 - stack.active
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        refreshing = false
        add.isEnabled = stack.layers.count < LayerStack.limit
        up.isEnabled = stack.active < stack.layers.count - 1
        down.isEnabled = stack.active > 0
        delete.isEnabled = stack.layers.count > 1
    }

    func numberOfRows(in tableView: NSTableView) -> Int { document?.stack?.layers.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let stack = document?.stack else { return nil }
        let index = stack.layers.count - 1 - row
        let layer = stack.layers[index]
        let thumbnail = NSImageView(image: NSImage(cgImage: layer.image, size: .zero))
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(labelWithString: layer.name)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let visible = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleLayer(_:)))
        visible.setAccessibilityLabel("Show \(layer.name)")
        visible.state = layer.isVisible ? .on : .off
        visible.tag = index
        let cell = NSStackView(views: [thumbnail, name, visible])
        cell.spacing = 5
        thumbnail.widthAnchor.constraint(equalToConstant: 24).isActive = true
        thumbnail.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshing, table.selectedRow >= 0, let count = document?.stack?.layers.count else { return }
        document?.selectLayer(count - 1 - table.selectedRow)
    }

    @objc private func addLayer(_ sender: NSButton) { document?.addLayer() }
    @objc private func deleteLayer(_ sender: NSButton) { document?.deleteLayer() }
    @objc private func openProperties(_ sender: NSButton) { document?.showLayerProperties() }
    @objc private func openClickedLayer(_ sender: NSTableView) {
        guard sender.clickedRow >= 0, let document, let stack = document.stack else { return }
        document.selectLayer(stack.layers.count - 1 - sender.clickedRow)
        document.showLayerProperties()
    }
    @objc private func moveLayer(_ sender: NSButton) { document?.moveLayer(by: sender.tag) }
    @objc private func toggleLayer(_ sender: NSButton) {
        document?.setLayerVisibility(sender.state == .on, at: sender.tag)
    }
}
