import XCTest
@testable import NullPlayer

final class LocalFolderTreeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalFolderTreeTests-\(UUID().uuidString)")
        for directory in ["10 - Growing Light", "2 - A Realm Reborn", "1 - Before Meteor", "The Wall"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        for file in ["10 Track.mp3", "2 Track.mp3", "100 Track.mp3", "1 Track.mp3", "cover.jpg"] {
            FileManager.default.createFile(atPath: root.appendingPathComponent("2 - A Realm Reborn/\(file)").path, contents: Data())
        }
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func names(_ rows: [LocalFolderTree.Row]) -> [String] {
        rows.map {
            switch $0 {
            case .folder(_, let name, let indent): return "\(indent) \(name)/"
            case .track(let track, let indent): return "\(indent) \(track.url.lastPathComponent)"
            }
        }
    }

    /// #543: folders, then audio files, each numbers-by-value as Finder sorts them, and only an
    /// expanded folder's contents are listed.
    func testFoldersThenFilesInFinderOrderIntoExpandedFoldersOnly() {
        // Expand by the row's own URL, as the browsers do: the walk's spelling of the path is its own.
        let realm = LocalFolderTree.rows(roots: [root], expanded: [], tracks: { _ in [:] }).compactMap {
            if case .folder(let url, "2 - A Realm Reborn", _) = $0 { return url.path } else { return nil }
        }
        let rows = LocalFolderTree.rows(roots: [root], expanded: Set(realm), tracks: { _ in [:] })
        XCTAssertEqual(names(rows), [
            "0 1 - Before Meteor/",
            "0 2 - A Realm Reborn/",
            "1 1 Track.mp3", "1 2 Track.mp3", "1 10 Track.mp3", "1 100 Track.mp3",
            "0 10 - Growing Light/",
            "0 The Wall/",
        ])
    }

    func testSeveralRootsAreEachATopLevelFolder() {
        let second = root.appendingPathComponent("The Wall")
        let rows = LocalFolderTree.rows(roots: [root, second], expanded: [second.path], tracks: { _ in [:] })
        XCTAssertEqual(names(rows), ["0 \(root.lastPathComponent)/", "0 The Wall/"])
    }
}

extension LocalFolderTreeTests {
    /// The walk skips a symlinked folder (it could loop) but not the folders under a symlinked root:
    /// the temporary directory's own path runs through the /var symlink.
    func testASymlinkedFolderIsSkippedButASymlinkedRootIsWalked() throws {
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Loop"), withDestinationURL: root)
        let rows = LocalFolderTree.rows(roots: [root], expanded: [], tracks: { _ in [:] })
        XCTAssertEqual(names(rows).count, 4, "\(names(rows))")
        XCTAssertFalse(names(rows).contains("0 Loop/"))
    }
}
