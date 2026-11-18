import AppKit
import UniformTypeIdentifiers

extension PaintDocument {
    @objc func showColorProfile(_ sender: Any?) {
        guard let stack, let window = windowForSheet, window.attachedSheet == nil else { return }
        let options = ColorProfileOptions(current: stack.colorProfile)
        let alert = NSAlert()
        alert.messageText = "Color Profile"
        alert.informativeText = "Convert preserves appearance within the new gamut. Assign keeps the pixel values."
        alert.accessoryView = options.view
        alert.addButton(withTitle: "Convert")
        alert.addButton(withTitle: "Assign")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn || response == .alertSecondButtonReturn,
                  let chosen = options.selectedProfile else { return }
            do {
                try applyColorProfile(chosen, converting: response == .alertFirstButtonReturn)
            } catch {
                presentError(error)
            }
        }
    }

    func applyColorProfile(_ profile: RGBColorProfile, converting: Bool) throws {
        guard stack?.colorProfile != profile else { return }
        editor?.canvas.finishSelection()
        guard let stack else { return }
        let changed = try stack.applyingColorProfile(profile, converting: converting)
        applyEdit(replacingStack: changed, actionName: converting ? "Convert Color Profile" : "Assign Color Profile")
    }
}

@MainActor
private final class ColorProfileOptions: NSObject {
    private static let builtIns: [(String, CFString)] = [
        ("sRGB", CGColorSpace.sRGB), ("Adobe RGB (1998)", CGColorSpace.adobeRGB1998),
        ("Display P3", CGColorSpace.displayP3), ("ProPhoto RGB", CGColorSpace.rommrgb)
    ]

    private static let contentTypes = ["icc", "icm"].compactMap { UTType(filenameExtension: $0) }
    private let current: RGBColorProfile?
    private var profiles: [RGBColorProfile] = []
    private let popup = NSPopUpButton()
    let view: NSView

    var selectedProfile: RGBColorProfile? {
        let index = popup.indexOfSelectedItem
        return profiles.indices.contains(index) ? profiles[index] : nil
    }

    init(current: RGBColorProfile?) {
        self.current = current
        view = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 78))
        super.init()
        popup.setAccessibilityLabel("Target color profile")

        for (title, name) in Self.builtIns {
            guard let space = CGColorSpace(name: name), let profile = RGBColorProfile(colorSpace: space) else { continue }
            add(profile, title: title)
        }

        if let current {
            let index = profiles.firstIndex(of: current) ?? add(current, title: current.name)
            popup.selectItem(at: index)
        }
        for screen in NSScreen.screens {
            guard let data = screen.colorSpace?.iccProfileData, let profile = RGBColorProfile(iccData: data),
                  !profiles.contains(profile) else { continue }
            add(profile, title: screen.localizedName)
        }

        let importButton = NSButton(title: "Import…", target: self, action: #selector(importProfile(_:)))
        let exportButton = NSButton(title: "Export Current…", target: self, action: #selector(exportProfile(_:)))
        let buttons = NSStackView(views: [importButton, exportButton])
        buttons.spacing = 6
        let form = NSStackView(views: [
            NSTextField(labelWithString: "Current profile · \(current?.name ?? "sRGB")"), popup, buttons
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 6
        form.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(form)
        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            form.topAnchor.constraint(equalTo: view.topAnchor),
            form.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            popup.widthAnchor.constraint(equalTo: view.widthAnchor)
        ])
        view.setFrameSize(NSSize(width: 330, height: form.fittingSize.height))
    }

    @discardableResult
    private func add(_ profile: RGBColorProfile, title: String) -> Int {
        var label = title
        var suffix = 2
        while popup.item(withTitle: label) != nil {
            label = "\(title) (\(suffix))"
            suffix += 1
        }
        popup.addItem(withTitle: label)
        profiles.append(profile)
        return profiles.count - 1
    }

    @objc private func importProfile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Import Color Profile"
        panel.allowedContentTypes = Self.contentTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            guard let data = try file.read(upToCount: RGBColorProfile.maximumBytes + 1),
                  let profile = RGBColorProfile(iccData: data) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [
                    NSLocalizedDescriptionKey: "The selected file is missing a usable RGB ICC profile."
                ])
            }
            let index = profiles.firstIndex(of: profile) ?? add(profile, title: url.deletingPathExtension().lastPathComponent)
            popup.selectItem(at: index)
        } catch {
            NSApp.presentError(error)
        }
    }

    @objc private func exportProfile(_ sender: Any?) {
        guard let profile = current ?? RGBColorProfile(colorSpace: BGRA8.sRGB) else { return }
        let panel = NSSavePanel()
        panel.title = "Export Color Profile"
        panel.allowedContentTypes = Self.contentTypes
        panel.nameFieldStringValue = profile.name + ".icc"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try profile.iccData.write(to: url, options: .atomic)
        } catch {
            NSApp.presentError(error)
        }
    }
}
