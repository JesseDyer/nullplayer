import Foundation

/// The library browser's tab. Raw values are persisted (`AppState.browserBrowseMode`, the
/// per-tab sort store), so they never change.
enum LibraryBrowseMode: Int {
    case artists = 0
    case albums = 1
    case plists = 3
    case movies = 4
    case shows = 5
    case search = 6
    case radio = 7
    case history = 8
    case folders = 9

    var title: String {
        switch self {
        case .artists: return "Artists"
        case .albums: return "Albums"
        case .folders: return "Folders"
        case .plists: return "Plists"
        case .movies: return "Movies"
        case .shows: return "TV"
        case .search: return "Search"
        case .radio: return "Radio"
        case .history: return "Data"
        }
    }

    var isVideoMode: Bool {
        self == .movies || self == .shows
    }

    var isMusicMode: Bool {
        self == .artists || self == .albums || self == .plists || self == .folders
    }

    var isRadioMode: Bool {
        self == .radio
    }

    var isHistoryMode: Bool {
        self == .history
    }

    /// The tab strip, in order. `.folders` is excluded: it occupies the same tab slot as
    /// `.plists` and is reached only by toggling that slot (local source only).
    static let tabs: [LibraryBrowseMode] = [.artists, .albums, .plists, .movies, .shows, .radio, .search, .history]
}
