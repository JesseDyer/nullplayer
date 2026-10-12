import Foundation

/// The Folders tab's rows, shared by both library browsers, which map each row to their own
/// display item. A depth-first walk of the watch folders into every expanded directory: one root
/// shows its contents directly, several are each a top-level folder. Reads the file system and the
/// store, so it runs off the main actor, and stops early once its task is cancelled.
enum LocalFolderTree {
    enum Row {
        case folder(URL, name: String, indent: Int)
        case track(LibraryTrack, indent: Int)
    }

    /// `expanded` holds folder paths. `tracks` looks up the scanned tracks for a folder's audio
    /// files; a file it does not return is listed from its URL alone.
    static func rows(
        roots: [URL],
        expanded: Set<String>,
        tracks: ([URL]) -> [URL: LibraryTrack] = { MediaLibraryStore.shared.tracks(forURLs: $0) }
    ) -> [Row] {
        var rows: [Row] = []

        func walk(_ url: URL, indent: Int) {
            if Task.isCancelled { return }
            var subdirectories: [URL] = []
            var audioFiles: [URL] = []
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            for item in contents {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    // A symlinked directory could loop forever. Ask the item itself: comparing resolved
                    // paths also dropped every folder under a symlinked root such as /tmp.
                    let isLink = (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
                    if !isLink { subdirectories.append(item) }
                } else if LocalFileDiscovery.isSupportedAudioFile(item) {
                    audioFiles.append(item)
                }
            }
            // Directories first, then files, each in Finder's order: numbers by value (#543)
            subdirectories.sort { inFinderOrder($0.lastPathComponent, $1.lastPathComponent) }
            audioFiles.sort { inFinderOrder($0.lastPathComponent, $1.lastPathComponent) }

            for directory in subdirectories {
                rows.append(.folder(directory, name: directory.lastPathComponent, indent: indent))
                // Recurse in place, so a folder's contents follow it directly
                if expanded.contains(directory.path) { walk(directory, indent: indent + 1) }
            }
            let scanned = tracks(audioFiles)
            for file in audioFiles {
                rows.append(.track(scanned[file] ?? LibraryTrack(url: file), indent: indent))
            }
        }

        if roots.count > 1 {
            for root in roots {
                rows.append(.folder(root, name: root.lastPathComponent, indent: 0))
                if expanded.contains(root.path) { walk(root, indent: 1) }
            }
        } else if let only = roots.first {
            walk(only, indent: 0)
        }
        return rows
    }

    /// Case- and diacritic-insensitive, numbers by value, and no leading-article stripping: Finder
    /// files "The Wall" under T.
    private static func inFinderOrder(_ lhs: String, _ rhs: String) -> Bool {
        LibraryTextSorter.areInOrder(lhs, rhs, ascending: true, ignoreLeadingArticles: false)
    }
}
