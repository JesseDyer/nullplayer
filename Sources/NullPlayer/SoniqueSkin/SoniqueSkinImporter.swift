import Foundation

struct SoniqueInstalledSkin: Hashable {
    /// The file name without `.sgf`.
    let name: String
    let url: URL
}

enum SoniqueSkinImportError: LocalizedError {
    case selectionMissing(String)
    case notInstalled(String)

    var errorDescription: String? {
        switch self {
        case let .selectionMissing(name):
            return "The selected Sonique skin “\(name)” is no longer installed. Load it again or choose another skin."
        case let .notInstalled(name):
            return "No Sonique skin named “\(name)” is installed."
        }
    }
}

/// Owns the installed-skins directory and the selection preference. A skin is one `.sgf` file
/// (decision record § *Decisions*); an import validates the copied bytes through
/// `SoniqueSkinLoader` off the main thread before one same-directory move commits it.
struct SoniqueSkinImporter {
    static let selectedSkinNameKey = "soniqueSkinName"

    let directoryURL: URL
    let defaults: UserDefaults
    let fileManager: FileManager

    init(directoryURL: URL? = nil, defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
            .appendingPathComponent("NullPlayer", isDirectory: true)
            .appendingPathComponent("SoniqueSkins", isDirectory: true)
    }

    var selectedSkinName: String? { defaults.string(forKey: Self.selectedSkinNameKey) }

    func installedSkins() -> [SoniqueInstalledSkin] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        return names.filter { !$0.hasPrefix(".") && $0.lowercased().hasSuffix(".sgf") }
            .map { SoniqueInstalledSkin(name: String($0.dropLast(4)), url: directoryURL.appendingPathComponent($0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The installed skin of that name; a name that is not a plain visible file name never resolves
    /// outside the directory.
    func skin(named name: String) -> SoniqueInstalledSkin? {
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return nil }
        return installedSkins().first { $0.name == name }
    }

    /// The selected skin's file, nil when nothing is selected; throws when the selection is gone.
    func selectedSkinURL() throws -> URL? {
        guard let name = selectedSkinName, !name.isEmpty else { return nil }
        guard let skin = skin(named: name) else { throw SoniqueSkinImportError.selectionMissing(name) }
        return skin.url
    }

    func ensureDirectoryExists() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func select(_ name: String) { defaults.set(name, forKey: Self.selectedSkinNameKey) }

    func resetSelection() { defaults.removeObject(forKey: Self.selectedSkinNameKey) }

    /// Installs an `.sgf`, replacing one of the same name, and selects it.
    @discardableResult
    func importSkin(from source: URL) async throws -> SoniqueInstalledSkin {
        let installed = try await Task.detached(priority: .userInitiated) { [self] in
            try ensureDirectoryExists()
            let name = source.deletingPathExtension().lastPathComponent
            let destination = directoryURL.appendingPathComponent(name + ".sgf")
            let incoming = directoryURL.appendingPathComponent(".incoming-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: incoming) }
            try fileManager.copyItem(at: source, to: incoming)
            // Validate the copied bytes, not the source: the copy is what gets committed.
            _ = try SoniqueSkinLoader.load(contentsOf: incoming)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: incoming, backupItemName: nil, options: [])
            } else {
                try fileManager.moveItem(at: incoming, to: destination)
            }
            return SoniqueInstalledSkin(name: name, url: destination)
        }.value
        select(installed.name)
        return installed
    }

    /// Deletes an installed skin off the main thread; removing the selected one clears the selection.
    func removeSkin(named name: String) async throws {
        try await Task.detached(priority: .userInitiated) { [self] in
            guard let skin = skin(named: name) else { throw SoniqueSkinImportError.notInstalled(name) }
            try fileManager.removeItem(at: skin.url)
        }.value
        if selectedSkinName == name { resetSelection() }
    }
}
