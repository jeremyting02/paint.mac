import AppKit

/// A progress sheet keeps edits to the shared workspace ordered while the run loop remains free.
final class DocumentJob {
    private static let queue = DispatchQueue(label: "paint.mac.document-jobs", qos: .userInitiated)
    private weak var parent: NSWindow?
    private let sheet: NSPanel?
    var closeRequests: [() -> Void] = []

    init(title: String, window: NSWindow?) {
        parent = window
        guard let window else {
            sheet = nil
            return
        }
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 300, height: 86),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = title
        let spinner = NSProgressIndicator(frame: .zero)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let content = NSStackView(views: [spinner, NSTextField(labelWithString: title)])
        content.alignment = .centerY
        content.translatesAutoresizingMaskIntoConstraints = false
        if let view = panel.contentView {
            view.addSubview(content)
            NSLayoutConstraint.activate([
                content.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                content.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
        }
        sheet = panel
        window.beginSheet(panel)
    }

    func dismiss() {
        if let sheet, let parent, parent.sheets.contains(where: { $0 === sheet }) {
            parent.endSheet(sheet)
        }
    }

    func run<Value>(_ work: @escaping () throws -> Value,
                    completion: @escaping (Result<Value, Error>) -> Void) {
        Self.queue.async {
            let result = autoreleasepool { Result(catching: work) }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
