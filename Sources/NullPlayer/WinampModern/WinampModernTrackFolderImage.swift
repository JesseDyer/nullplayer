import CoreGraphics
import Foundation

/// A cover image a skin's script looks for **beside the playing file**, answered with the album art
/// NullPlayer already has.
///
/// Deimos's `cover.maki` (57 corpus skins: Mac OS X Panther, Ebonite, Dronev11, Itemskin…) takes
/// `getPath(getPlayItemString())`, drops its first seven characters, appends `cover.jpg`,
/// `folder.jpg`, `front.jpg`… and sets each as a layer's `image=`, testing it with an animated
/// layer's `getLength()`. Winamp loaded the file from disk. A skin may never read the host
/// filesystem here, so nothing is opened: a path whose folder is the tail of the playing track's
/// folder and whose leaf is an image *names* the cover, and the cover is the host's artwork.
extension WinampModernHost {
    func trackFolderArtwork(forImage value: String) -> CGImage? {
        guard isTrackFolderImage(value) else { return nil }
        return albumArtwork
    }

    func isTrackFolderImage(_ value: String) -> Bool {
        let path = value.replacingOccurrences(of: "\\", with: "/")
        guard let slash = path.lastIndex(of: "/"),
              Self.imageExtensions.contains((path as NSString).pathExtension.lowercased()) else { return false }
        let folder = String(path[..<slash]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trackFolder = (trackPath.replacingOccurrences(of: "\\", with: "/") as NSString)
            .deletingLastPathComponent
        return !folder.isEmpty && trackFolder.lowercased().hasSuffix(folder.lowercased())
    }

    private static var imageExtensions: Set<String> { ["jpg", "jpeg", "png", "bmp", "gif"] }
}
