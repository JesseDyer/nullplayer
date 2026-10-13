import Foundation

/// Source for browsing content. Persisted under `"BrowserSource"`, so the case names are
/// part of the saved format.
enum LibraryBrowserSource: Equatable, Codable {
    case local
    case plex(serverId: String)
    case subsonic(serverId: String)
    case jellyfin(serverId: String)
    case emby(serverId: String)
    case radio
    case youtube

    /// Display name for the source
    var displayName: String {
        switch self {
        case .local:
            return "LOCAL FILES"
        case .plex(let serverId):
            if let server = PlexManager.shared.servers.first(where: { $0.id == serverId }) {
                return "PLEX: \(server.name)"
            }
            return "PLEX"
        case .subsonic(let serverId):
            if let server = SubsonicManager.shared.servers.first(where: { $0.id == serverId }) {
                return "SUBSONIC: \(server.name)"
            }
            return "SUBSONIC"
        case .jellyfin(let serverId):
            if let server = JellyfinManager.shared.servers.first(where: { $0.id == serverId }) {
                return "JELLYFIN: \(server.name)"
            }
            return "JELLYFIN"
        case .emby(let serverId):
            if let server = EmbyManager.shared.servers.first(where: { $0.id == serverId }) {
                return "EMBY: \(server.name)"
            }
            return "EMBY"
        case .radio:
            return "INTERNET RADIO"
        case .youtube:
            return "YOUTUBE"
        }
    }

    /// Short name for compact display
    var shortName: String {
        switch self {
        case .local:
            return "Local Files"
        case .plex(let serverId):
            if let server = PlexManager.shared.servers.first(where: { $0.id == serverId }) {
                return server.name
            }
            return "Plex"
        case .subsonic(let serverId):
            if let server = SubsonicManager.shared.servers.first(where: { $0.id == serverId }) {
                return server.name
            }
            return "Subsonic"
        case .jellyfin(let serverId):
            if let server = JellyfinManager.shared.servers.first(where: { $0.id == serverId }) {
                return server.name
            }
            return "Jellyfin"
        case .emby(let serverId):
            if let server = EmbyManager.shared.servers.first(where: { $0.id == serverId }) {
                return server.name
            }
            return "Emby"
        case .radio:
            return "Radio"
        case .youtube:
            return "YouTube"
        }
    }

    /// Whether this is the local library
    var isLocal: Bool {
        if case .local = self { return true }
        return false
    }

    /// Whether this is a Subsonic source
    var isSubsonic: Bool {
        if case .subsonic = self { return true }
        return false
    }
    
    /// Whether this is a Jellyfin source
    var isJellyfin: Bool {
        if case .jellyfin = self { return true }
        return false
    }

    /// Whether this is an Emby source
    var isEmby: Bool {
        if case .emby = self { return true }
        return false
    }
    
    /// Whether this is a Plex source
    var isPlex: Bool {
        if case .plex = self { return true }
        return false
    }
    
    /// Whether this is a radio source
    var isRadio: Bool {
        if case .radio = self { return true }
        return false
    }

    /// Whether this is a YouTube source
    var isYouTube: Bool {
        if case .youtube = self { return true }
        return false
    }

    /// YouTube reuses the Internet Radio tab's UI to list its channels/videos.
    var usesRadioTab: Bool { isRadio || isYouTube }

    /// Whether this is a remote source (Plex, Subsonic, Jellyfin, or Emby)
    var isRemote: Bool {
        switch self {
        case .local, .radio, .youtube:
            return false
        case .plex, .subsonic, .jellyfin, .emby:
            return true
        }
    }

    /// The server of a remote source
    var serverId: String? {
        switch self {
        case .local, .radio, .youtube:
            return nil
        case .plex(let id), .subsonic(let id), .jellyfin(let id), .emby(let id):
            return id
        }
    }
    
    /// Persistence key
    private static let userDefaultsKey = "BrowserSource"
    
    /// Save to UserDefaults
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }
    
    /// Load from UserDefaults
    static func load() -> LibraryBrowserSource? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let source = try? JSONDecoder().decode(LibraryBrowserSource.self, from: data) else {
            return nil
        }
        return source
    }
}
