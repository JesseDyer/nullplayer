import AppKit

/// The artwork fetches both library browser views make the same way, and the one cache they share.
@MainActor
enum LibraryArtwork {
    static let cache = NSCache<NSString, NSImage>()

    /// A row's art cache key and loader, as the views' `itemArtwork` returns it.
    typealias ItemArtwork = (cacheKey: String?, load: () async -> NSImage?)

    /// An http(s) image, cached under `cacheNamespace`. A favicon passes without an image MIME type.
    static func remote(urlString: String, cacheNamespace: String) async -> NSImage? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }

        let cacheKey = NSString(string: "\(cacheNamespace):\(trimmed)")
        if let cached = cache.object(forKey: cacheKey) { return cached }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let mime = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            let looksLikeIcon = url.path.lowercased().hasSuffix(".ico") || mime.contains("icon")
            guard mime.contains("image") || looksLikeIcon else { return nil }
            guard let image = NSImage(data: data) else { return nil }
            cache.setObject(image, forKey: cacheKey)
            return image
        } catch {
            return nil
        }
    }

    /// A station's art: the track's own, then the station icon, then the stream host's favicon.
    static func radio(for track: Track, station: RadioStation? = nil) async -> NSImage? {
        if let thumb = track.artworkThumb,
           let image = await remote(urlString: thumb, cacheNamespace: "radio") {
            return image
        }

        let activeStation = station ?? RadioManager.shared.currentStation
        if let iconURL = activeStation?.iconURL?.absoluteString,
           let image = await remote(urlString: iconURL, cacheNamespace: "radio") {
            return image
        }

        var hosts = Set<String>()
        if let host = track.url.host, !host.isEmpty { hosts.insert(host) }
        if let host = activeStation?.url.host, !host.isEmpty { hosts.insert(host) }

        var candidates: [String] = []
        for host in hosts {
            candidates.append("https://\(host)/favicon.ico")
            if !host.lowercased().hasPrefix("www.") {
                candidates.append("https://www.\(host)/favicon.ico")
            }
            candidates.append("http://\(host)/favicon.ico")
        }

        for candidate in candidates {
            if let image = await remote(urlString: candidate, cacheNamespace: "radio-favicon") {
                return image
            }
        }

        return nil
    }

    /// The Primary image of a Jellyfin item (an `artworkItemId`).
    static func jellyfin(itemId: String) async -> NSImage? {
        await serverImage(cacheKey: "jellyfin:\(itemId)",
                          url: JellyfinManager.shared.imageURL(itemId: itemId, imageTag: nil, size: 400))
    }

    /// The Primary image of an Emby item (an `artworkItemId`).
    static func emby(itemId: String) async -> NSImage? {
        await serverImage(cacheKey: "emby:\(itemId)",
                          url: EmbyManager.shared.imageURL(itemId: itemId, imageTag: nil, size: 400))
    }

    /// A Jellyfin row's art, from its `artworkItemId` (nil when the item has no picture).
    static func jellyfinItem(_ itemId: String?) -> ItemArtwork {
        guard let itemId else { return (nil, { nil }) }
        return ("jellyfin:\(itemId)", { await jellyfin(itemId: itemId) })
    }

    /// An Emby row's art, from its `artworkItemId` (nil when the item has no picture).
    static func embyItem(_ itemId: String?) -> ItemArtwork {
        guard let itemId else { return (nil, { nil }) }
        return ("emby:\(itemId)", { await emby(itemId: itemId) })
    }

    private static func serverImage(cacheKey: String, url: URL?) async -> NSImage? {
        let key = NSString(string: cacheKey)
        if let cached = cache.object(forKey: key) { return cached }
        guard let url else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let image = NSImage(data: data) else { return nil }
            cache.setObject(image, forKey: key)
            return image
        } catch { return nil }
    }
}
