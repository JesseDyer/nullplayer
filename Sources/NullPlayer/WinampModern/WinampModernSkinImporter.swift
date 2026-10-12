import Foundation

enum WinampModernContainerKind: String {
    case walArchive
    case classicProInstaller
}

struct WinampModernValidatedContainer {
    let kind: WinampModernContainerKind
    let sourceURL: URL
    let displayName: String
    let preferredFilename: String
}

protocol WinampModernContainerIngesting {
    func supports(_ sourceURL: URL) -> Bool
    func validate(_ sourceURL: URL) throws -> WinampModernValidatedContainer
}

struct WalContainerIngestor: WinampModernContainerIngesting {
    let limits: WalArchiveLimits

    init(limits: WalArchiveLimits = .production) { self.limits = limits }

    func supports(_ sourceURL: URL) -> Bool { sourceURL.pathExtension.lowercased() == "wal" }

    func validate(_ sourceURL: URL) throws -> WinampModernValidatedContainer {
        guard supports(sourceURL) else {
            throw WalFailure(WalDiagnostic(.unsupportedContainer, "Expected a .wal skin archive, not '.\(sourceURL.pathExtension)'."))
        }
        _ = try WalArchive(url: sourceURL, limits: limits)
        let filename = sourceURL.lastPathComponent
        return WinampModernValidatedContainer(
            kind: .walArchive,
            sourceURL: sourceURL,
            displayName: sourceURL.deletingPathExtension().lastPathComponent,
            preferredFilename: filename
        )
    }
}

/// Recognizes user-supplied ClassicPro engine sources for the container seam. The engine is stored
/// separately from `.wal` skins (in `ClassicProEngineStore`), so this classifies/validates the
/// source; `ClassicProEngineImporter` performs the actual internal extraction and install.
struct ClassicProEngineIngestor: WinampModernContainerIngesting {
    let importer: ClassicProEngineImporter

    init(importer: ClassicProEngineImporter = .shared) { self.importer = importer }

    func supports(_ sourceURL: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory)
        if exists && isDirectory.boolValue { return true }
        return ["exe", "zip"].contains(sourceURL.pathExtension.lowercased())
    }

    func validate(_ sourceURL: URL) throws -> WinampModernValidatedContainer {
        // A full internal extraction proves the source really contains a ClassicPro "one" engine.
        let map = try importer.engineFileMap(from: sourceURL)
        _ = try ClassicProEngineStore.validate(engineFiles: map)
        return WinampModernValidatedContainer(
            kind: .classicProInstaller,
            sourceURL: sourceURL,
            displayName: "ClassicPro Engine",
            preferredFilename: sourceURL.lastPathComponent
        )
    }
}

struct WinampModernImportedSkin: Equatable {
    let name: String
    let archiveURL: URL
}

/// Single ingestion seam for all user-supplied Winamp Modern containers. Phase 2 ships the `.wal`
/// strategy; Phase 6 adds the internal NSIS strategy without changing picker or storage code.
final class WinampModernSkinImporter {
    static let shared = WinampModernSkinImporter()
    static let selectedSkinNameKey = "winampModernSkinName"

    let destinationDirectory: URL
    private let fileManager: FileManager
    private let ingestors: [WinampModernContainerIngesting]

    init(
        destinationDirectory: URL? = nil,
        fileManager: FileManager = .default,
        ingestors: [WinampModernContainerIngesting] = [WalContainerIngestor()]
    ) {
        self.fileManager = fileManager
        self.destinationDirectory = destinationDirectory ?? Self.defaultDestinationDirectory(fileManager: fileManager)
        self.ingestors = ingestors
    }

    static func defaultDestinationDirectory(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("NullPlayer", isDirectory: true)
            .appendingPathComponent("WinampModernSkins", isDirectory: true)
    }

    @discardableResult
    func importContainer(at sourceURL: URL) throws -> WinampModernImportedSkin {
        guard let ingestor = ingestors.first(where: { $0.supports(sourceURL) }) else {
            let ext = sourceURL.pathExtension.isEmpty ? "(none)" : sourceURL.pathExtension
            throw WalFailure(WalDiagnostic(.unsupportedContainer, "Unsupported Winamp Modern container extension '\(ext)'."))
        }

        // Validation is deliberately complete before the installed archive can be replaced.
        let validated = try ingestor.validate(sourceURL)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destination = destinationDirectory.appendingPathComponent(validated.preferredFilename, isDirectory: false)
        if sourceURL.standardizedFileURL != destination.standardizedFileURL {
            let staging = destinationDirectory.appendingPathComponent(".\(UUID().uuidString).wal-importing")
            defer { try? fileManager.removeItem(at: staging) }
            try fileManager.copyItem(at: sourceURL, to: staging)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        }
        let imported = WinampModernImportedSkin(name: validated.displayName, archiveURL: destination)
        selectSkin(imported)
        return imported
    }

    /// The default skin that ships inside the app bundle — Modern's answer to Classic's bundled
    /// `NullPlayer-Silver`. Like Silver it has no menu entry: it is what the mode loads before any
    /// skin is imported and what it falls back to when the selected skin is removed.
    ///
    /// The archive name carries no version: the skin scopes its saved settings by filename, so an
    /// update shipped under the same name keeps the user's font and size choices.
    static let bundledDefaultSkinName = "iTunes Miniplayer"

    /// Where the bundled `.wal` sits. The same three-path search `findBundledClassicSkin` does,
    /// because SwiftPM's resource bundle lands in a different place than a plain copy does.
    func bundledDefaultSkin() -> WinampModernImportedSkin? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let name = Self.bundledDefaultSkinName
        let candidates = [
            resourceURL.appendingPathComponent("Resources/Skins/\(name).wal"),
            resourceURL.appendingPathComponent("NullPlayer_NullPlayer.bundle/Resources/Skins/\(name).wal"),
            resourceURL.appendingPathComponent("Skins/\(name).wal"),
        ]
        guard let url = candidates.first(where: { fileManager.fileExists(atPath: $0.path) })
        else { return nil }
        return WinampModernImportedSkin(name: name, archiveURL: url)
    }

    /// Every skin that can be *loaded*: what the user imported, plus the bundled default.
    ///
    /// This is the resolution list — what `selectedSkin()` matches a stored name against — and not
    /// the menu's list, which shows only `installedSkins()`; the bundled skin has no entry. Separate
    /// from `installedSkins()`, which stays the user's library and nothing else: the import/storage
    /// seam is about files we own in Application Support, and the bundled skin is neither imported
    /// nor removable. A skin they imported under the same name wins, so replacing the default
    /// with their own copy behaves the way importing anything else does.
    func availableSkins() -> [WinampModernImportedSkin] {
        let installed = installedSkins()
        guard let bundled = bundledDefaultSkin(),
              !installed.contains(where: { $0.name.caseInsensitiveCompare(bundled.name) == .orderedSame })
        else { return installed }
        return (installed + [bundled])
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func installedSkins() -> [WinampModernImportedSkin] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: destinationDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files.filter { $0.pathExtension.lowercased() == "wal" }
            .map { WinampModernImportedSkin(name: $0.deletingPathExtension().lastPathComponent, archiveURL: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The stored skin, or the bundled default when nothing is stored or the stored name matches
    /// nothing — a removed skin, or the retired `NullPlayer-Black` an upgrade carries over — rather
    /// than whichever installed skin happens to sort first.
    func selectedSkin() -> WinampModernImportedSkin? {
        let available = availableSkins()
        func named(_ name: String) -> WinampModernImportedSkin? {
            available.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        return UserDefaults.standard.string(forKey: Self.selectedSkinNameKey).flatMap(named)
            ?? named(Self.bundledDefaultSkinName) ?? available.first
    }

    func selectSkin(_ skin: WinampModernImportedSkin) {
        UserDefaults.standard.set(skin.name, forKey: Self.selectedSkinNameKey)
    }

    /// The selected skin when the user installed it — the bundled default has nothing to remove.
    func removableSelectedSkin() -> WinampModernImportedSkin? {
        guard let selected = selectedSkin() else { return nil }
        return installedSkins().first { $0.archiveURL == selected.archiveURL }
    }

    /// Moves an installed skin to the Trash and clears the selection, which `selectedSkin()`
    /// resolves to the bundled default. The caller reloads the player when the mode is on screen.
    func trashSkin(_ skin: WinampModernImportedSkin) throws {
        try fileManager.trashItem(at: skin.archiveURL, resultingItemURL: nil)
        UserDefaults.standard.removeObject(forKey: Self.selectedSkinNameKey)
    }
}
