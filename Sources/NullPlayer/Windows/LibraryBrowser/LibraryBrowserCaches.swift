import Foundation
import NullPlayerCore

/// A Plex server's rows, as fetched for the selected library. Replacing it with a fresh value
/// drops every one of them; the expansion of their rows is collapsed alongside.
struct PlexBrowserCache {
    var artists: [PlexArtist] = []
    var albums: [PlexAlbum] = []
    /// Album count per artist id, counted from the albums' `parentKey`.
    var artistAlbumCounts: [String: Int] = [:]
    var artistGroupsByName: [String: [PlexArtist]] = [:]
    var albumsByArtistGroupKey: [String: [PlexAlbum]] = [:]
    var albumCountsByArtistGroupKey: [String: Int] = [:]
    /// Albums fetched on expand, by artist group key.
    var artistAlbums: [String: [PlexAlbum]] = [:]
    /// Albums fetched for a search result's artist, by normalized name (search ids can vary).
    var artistAlbumsByName: [String: [PlexAlbum]] = [:]
    var albumTracks: [String: [PlexTrack]] = [:]
    var movies: [PlexMovie] = []
    var shows: [PlexShow] = []
    var showSeasons: [String: [PlexSeason]] = [:]
    var seasonEpisodes: [String: [PlexEpisode]] = [:]
    /// Playlists span the server's libraries, so picking another library keeps them.
    var playlists: [PlexPlaylist] = []
    var playlistTracks: [String: [PlexTrack]] = [:]
    var searchResults: PlexSearchResults?
}

/// A Subsonic, Jellyfin or Emby server's music rows. Children fetched on expand are keyed by
/// their parent's id.
struct ServerMusicCache<Artist, Album, Song, Playlist> {
    var artists: [Artist] = []
    var albums: [Album] = []
    var playlists: [Playlist] = []
    var artistAlbums: [String: [Album]] = [:]
    var albumSongs: [String: [Song]] = [:]
    var playlistTracks: [String: [Song]] = [:]
}

/// A Jellyfin or Emby server's video rows.
struct ServerVideoCache<Movie, Show, Season, Episode> {
    var movies: [Movie] = []
    var shows: [Show] = []
    var showSeasons: [String: [Season]] = [:]
    var seasonEpisodes: [String: [Episode]] = [:]
}
