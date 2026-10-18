import AppKit

// MARK: - Sonique skins actions

extension MenuActions {
    private var soniqueController: SoniqueSkinMainWindowController? {
        WindowManager.shared.mainWindowController as? SoniqueSkinMainWindowController
    }

    @objc func setSoniqueMode() {
        guard AppCapabilities.supports(.soniqueSkinMode), WindowManager.shared.uiMode != .sonique else { return }
        WindowManager.shared.reloadUI(to: .sonique)
    }

    /// In place inside the family; otherwise the selection is saved and entering the family loads it.
    @objc func selectSoniqueSkin(_ sender: NSMenuItem) {
        guard AppCapabilities.supports(.soniqueSkinMode), let name = sender.representedObject as? String else { return }
        if let controller = soniqueController {
            controller.selectSkin(named: name)
        } else {
            SoniqueSkinImporter().select(name)
            WindowManager.shared.reloadUI(to: .sonique)
        }
    }

    @objc func setSoniqueWindowMode(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let mode = SoniqueSkin.Mode(rawValue: name) else { return }
        soniqueController?.mode = mode
    }

    @objc func loadSoniqueSkinFromFile() {
        guard AppCapabilities.supports(.soniqueSkinMode) else { return }
        if let controller = soniqueController {
            controller.importSkinFromPanel()
        } else {
            WindowManager.shared.reloadUI(to: .sonique) { [weak self] in self?.soniqueController?.importSkinFromPanel() }
        }
    }

    @objc func openSoniqueSkinsFolder() {
        let importer = SoniqueSkinImporter()
        do {
            try importer.folder.ensureExists()
            NSWorkspace.shared.open(importer.directoryURL)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func removeSoniqueSkin(named name: String) {
        Task { @MainActor in
            do {
                try await SoniqueSkinImporter().removeSkin(named: name)
                self.soniqueController?.resetToUnskinned()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}
