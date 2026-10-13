import Foundation

/// The Emby source.
extension LibraryBrowserModel {

    func loadEmbyData(serverId: String, generation: Int) {
        let expectedSource = LibraryBrowserSource.emby(serverId: serverId)
        guard isLoadContextActive(generation, source: expectedSource) else { return }
        isLoading = true
        errorMessage = nil
        let manager = EmbyManager.shared
        let load: @MainActor () -> Void = { [weak self] in
            self?.loadEmbyDataForCurrentMode(generation: generation, expectedSource: expectedSource)
        }
        guard manager.currentServer?.id != serverId else { load(); return }
        let server = manager.servers.first { $0.id == serverId }
        connectThenLoad(generation: generation, source: expectedSource,
                        connect: server.map { server in { try await manager.connect(to: server) } },
                        isConnected: { manager.currentServer?.id == serverId }, load: load)
    }

    private func loadEmbyDataForCurrentMode(generation: Int, expectedSource: LibraryBrowserSource) {
        let manager = EmbyManager.shared
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard self.isLoadContextActive(generation, source: expectedSource),
                      try await self.waitForPreload({ manager.isPreloading }, generation: generation, source: expectedSource)
                else { return }

                func preloadedOr<Item>(_ preloaded: [Item], fetch: @MainActor () async throws -> [Item]) async throws -> [Item] {
                    try await self.preloadedOrFetched(preloaded, isPreloaded: manager.isContentPreloaded,
                                                      generation: generation, source: expectedSource, fetch: fetch)
                }

                switch self.browseMode {
                case .artists:
                    if self.emby.artists.isEmpty {
                        if self.pendingArtistLoadUnfiltered {
                            try Task.checkCancellation()
                            self.emby.artists = try await manager.fetchArtistsUnfiltered()
                            guard self.isLoadContextActive(generation, source: expectedSource) else { return }
                        } else {
                            self.emby.artists = try await preloadedOr(manager.cachedArtists) { try await manager.fetchArtists() }
                            self.emby.albums = try await preloadedOr(manager.cachedAlbums) { try await manager.fetchAlbums() }
                        }
                    }
                    self.pendingArtistLoadUnfiltered = false
                    self.buildEmbyArtistItems()
                case .albums:
                    if self.emby.albums.isEmpty {
                        self.emby.albums = try await preloadedOr(manager.cachedAlbums) { try await manager.fetchAlbums() }
                    }
                    self.buildEmbyAlbumItems()
                case .plists, .folders:
                    if self.emby.playlists.isEmpty {
                        self.emby.playlists = try await preloadedOr(manager.cachedPlaylists) { try await manager.fetchPlaylists() }
                    }
                    self.buildEmbyPlaylistItems()
                case .search:
                    if self.searchQuery.isEmpty {
                        self.displayItems = []
                    } else {
                        self.embySearchResults = try await manager.searchWithArtistAlbums(query: self.searchQuery)
                        guard self.isLoadContextActive(generation, source: expectedSource) else { return }
                        self.buildEmbySearchItems()
                    }
                case .movies:
                    if self.embyVideo.movies.isEmpty {
                        self.embyVideo.movies = try await preloadedOr(manager.cachedMovies) { try await manager.fetchMovies() }
                    }
                    self.buildEmbyMovieItems()
                case .shows:
                    if self.embyVideo.shows.isEmpty {
                        self.embyVideo.shows = try await preloadedOr(manager.cachedShows) { try await manager.fetchShows() }
                    }
                    self.buildEmbyShowItems()
                case .radio:
                    self.loadEmbyRadioStations(generation: generation)
                    return
                case .history:
                    self.displayItems = []
                }
                self.finishLoadIfActive(generation: generation, source: expectedSource)
            } catch is CancellationError {
            } catch where Task.isCancelled {
            } catch {
                self.setLoadErrorIfActive(error.localizedDescription, generation: generation, source: expectedSource)
            }
        }
    }

    func rebuildEmbyItems() {
        switch browseMode {
        case .artists: buildEmbyArtistItems()
        case .albums: buildEmbyAlbumItems()
        case .plists: buildEmbyPlaylistItems()
        case .movies: buildEmbyMovieItems()
        case .shows: buildEmbyShowItems()
        case .search: buildEmbySearchItems()
        default: displayItems = []
        }
    }

    /// A music library was picked from the server bar (nil: all libraries).
    func selectEmbyMusicLibrary(_ library: EmbyMusicLibrary?) {
        if let library {
            EmbyManager.shared.selectMusicLibrary(library)
        } else {
            EmbyManager.shared.clearMusicLibrarySelection()
        }
        resetEmbyMusic()
        reloadData()
    }

    /// A video library was picked from the server bar (nil: all libraries).
    func selectEmbyVideoLibrary(_ library: EmbyMusicLibrary?) {
        EmbyManager.shared.selectMovieLibrary(library)
        EmbyManager.shared.selectShowLibrary(library)
        resetEmbyVideo()
        reloadData()
    }

    // MARK: - Music rows

    private func buildEmbyArtistItems() {
        var rows: [LibraryBrowserItem] = []
        for artist in sortEmbyArtists(emby.artists) {
            rows.append(embyArtistItem(artist, indentLevel: 0))
            guard isExpanded(.embyArtist, artist.id), let albums = emby.artistAlbums[artist.id] else { continue }
            for album in sortEmbyAlbums(albums) {
                rows.append(embyAlbumItem(album, title: album.name, indentLevel: 1))
                rows += embySongRows(ofAlbum: album, indentLevel: 2)
            }
        }
        displayItems = rows
    }

    private func embyArtistItem(_ artist: EmbyArtist, indentLevel: Int) -> LibraryBrowserItem {
        let info = artist.albumCount > 0 ? countLabel(artist.albumCount, "album") : nil
        return LibraryBrowserItem(id: artist.id, title: artist.name, info: info, indentLevel: indentLevel, hasChildren: true, type: .embyArtist(artist))
    }

    private func embyAlbumItem(_ album: EmbyAlbum, title: String, indentLevel: Int) -> LibraryBrowserItem {
        LibraryBrowserItem(id: album.id, title: title, info: album.year.map { String($0) }, indentLevel: indentLevel, hasChildren: true, type: .embyAlbum(album))
    }

    /// An expanded album's songs, by disc then track number.
    private func embySongRows(ofAlbum album: EmbyAlbum, indentLevel: Int) -> [LibraryBrowserItem] {
        guard isExpanded(.embyAlbum, album.id), let songs = emby.albumSongs[album.id] else { return [] }
        return embySongRows(discOrdered(songs, disc: \.discNumber, track: \.track), indentLevel: indentLevel)
    }

    private func buildEmbyAlbumItems() {
        var rows: [LibraryBrowserItem] = []
        for album in sortEmbyAlbums(emby.albums) {
            rows.append(embyAlbumItem(album, title: "\(album.artist ?? "Unknown") - \(album.name)", indentLevel: 0))
            rows += embySongRows(ofAlbum: album, indentLevel: 1)
        }
        displayItems = rows
    }

    private func buildEmbyPlaylistItems() {
        var rows: [LibraryBrowserItem] = []
        for playlist in menuSorted(emby.playlists, name: \.name) {
            rows.append(LibraryBrowserItem(id: playlist.id, title: playlist.name, info: countLabel(playlist.songCount, "track"), indentLevel: 0, hasChildren: playlist.songCount > 0, type: .embyPlaylist(playlist)))
            guard isExpanded(.embyPlaylist, playlist.id), let tracks = emby.playlistTracks[playlist.id] else { continue }
            for track in tracks {
                rows.append(LibraryBrowserItem(id: "\(playlist.id)-\(track.id)", title: track.title, info: formatDuration(track.duration), indentLevel: 1, hasChildren: false, type: .embyTrack(track)))
            }
        }
        displayItems = rows
    }

    private func embySongRows(_ songs: [EmbySong], indentLevel: Int) -> [LibraryBrowserItem] {
        songs.map { LibraryBrowserItem(id: $0.id, title: $0.title, info: formatDuration($0.duration), indentLevel: indentLevel, hasChildren: false, type: .embyTrack($0)) }
    }

    // MARK: - Video rows

    private func buildEmbyMovieItems() {
        displayItems = embyVideo.movies.map { embyMovieItem($0, indentLevel: 0) }
    }

    private func embyMovieItem(_ movie: EmbyMovie, indentLevel: Int) -> LibraryBrowserItem {
        let info = [movie.year.map { String($0) }, movie.formattedDuration].compactMap { $0 }.joined(separator: " • ")
        return LibraryBrowserItem(id: movie.id, title: movie.title, info: info.isEmpty ? nil : info, indentLevel: indentLevel, hasChildren: false, type: .embyMovie(movie))
    }

    private func buildEmbyShowItems() {
        displayItems = embyVideo.shows.flatMap { embyShowRows($0, indentLevel: 0) }
    }

    /// A show, then its seasons when expanded, each with its episodes when expanded. Emby can
    /// report no season or episode count; the info then leaves it out.
    private func embyShowRows(_ show: EmbyShow, indentLevel: Int) -> [LibraryBrowserItem] {
        let seasonCount = show.childCount > 0 ? "\(show.childCount) seasons" : nil
        let info = [show.year.map { String($0) }, seasonCount].compactMap { $0 }.joined(separator: " • ")
        var rows = [LibraryBrowserItem(id: show.id, title: show.title, info: info.isEmpty ? nil : info, indentLevel: indentLevel, hasChildren: true, type: .embyShow(show))]
        guard isExpanded(.embyShow, show.id), let seasons = embyVideo.showSeasons[show.id] else { return rows }
        for season in seasons {
            let episodeCount = season.childCount > 0 ? "\(season.childCount) episodes" : nil
            rows.append(LibraryBrowserItem(id: season.id, title: season.title, info: episodeCount, indentLevel: indentLevel + 1, hasChildren: true, type: .embySeason(season)))
            guard isExpanded(.embySeason, season.id), let episodes = embyVideo.seasonEpisodes[season.id] else { continue }
            for episode in episodes {
                rows.append(LibraryBrowserItem(id: episode.id, title: "\(episode.episodeIdentifier) - \(episode.title)", info: episode.formattedDuration, indentLevel: indentLevel + 2, hasChildren: false, type: .embyEpisode(episode)))
            }
        }
        return rows
    }

    // MARK: - Search

    private func buildEmbySearchItems() {
        var rows: [LibraryBrowserItem] = []
        defer { displayItems = rows }
        guard let results = embySearchResults else { return }
        let artists = sortEmbyArtists(results.artists)
        if !artists.isEmpty {
            rows.append(LibraryBrowserItem(id: "header-artists", title: "Artists (\(artists.count))", info: nil, indentLevel: 0, hasChildren: false, type: .header))
            rows += artists.map { embyArtistItem($0, indentLevel: 1) }
        }
        let albums = sortEmbyAlbums(results.albums)
        if !albums.isEmpty {
            rows.append(LibraryBrowserItem(id: "header-albums", title: "Albums (\(albums.count))", info: nil, indentLevel: 0, hasChildren: false, type: .header))
            rows += albums.map { embyAlbumItem($0, title: $0.name, indentLevel: 1) }
        }
        let songs = menuSorted(results.songs, name: \.title, created: { $0.created }, year: { $0.year })
        if !songs.isEmpty {
            rows.append(LibraryBrowserItem(id: "header-tracks", title: "Tracks (\(songs.count))", info: nil, indentLevel: 0, hasChildren: false, type: .header))
            rows += embySongRows(songs, indentLevel: 1)
        }
        if !results.movies.isEmpty {
            rows.append(LibraryBrowserItem(id: "header-movies", title: "Movies (\(results.movies.count))", info: nil, indentLevel: 0, hasChildren: false, type: .header))
            rows += results.movies.map { embyMovieItem($0, indentLevel: 1) }
        }
        if !results.shows.isEmpty {
            rows.append(LibraryBrowserItem(id: "header-shows", title: "TV Shows (\(results.shows.count))", info: nil, indentLevel: 0, hasChildren: false, type: .header))
            rows += results.shows.flatMap { embyShowRows($0, indentLevel: 1) }
        }
    }

    // MARK: - Sorting

    private func sortEmbyArtists(_ artists: [EmbyArtist]) -> [EmbyArtist] {
        sortServerArtists(artists,
                          albums: emby.albums.map { .init(artistId: $0.artistId, artist: $0.artist, created: $0.created, year: $0.year) },
                          id: \.id, name: \.name)
    }

    private func sortEmbyAlbums(_ albums: [EmbyAlbum]) -> [EmbyAlbum] {
        menuSorted(albums, name: \.name, created: { $0.created }, year: { $0.year })
    }

    // MARK: - Radio

    func loadEmbyRadioStations(generation: Int) {
        guard case .emby = currentSource else { return }
        let expectedSource = currentSource
        isLoading = true
        errorMessage = nil
        radioLoadTask?.cancel()
        radioLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let genres = await EmbyManager.shared.getMusicGenres()
            guard !Task.isCancelled,
                  self.isLoadContextActive(generation, source: expectedSource),
                  self.browseMode == .radio else { return }
            self.buildEmbyRadioStationItems(genres: genres)
            self.isLoading = false
            self.radioLoadTask = nil
        }
    }

    private func buildEmbyRadioStationItems(genres: [String]) {
        var stations: [(id: String, title: String, info: String, type: EmbyRadioType)] = [
            ("emby-radio-library", "Library Radio", "Library", .libraryRadio),
            ("emby-radio-library-mix", "Library Radio (Instant Mix)", "Library", .libraryInstantMix),
            ("emby-radio-fav", "Favorites Radio", "Favorites", .favoritesRadio),
            ("emby-radio-fav-mix", "Favorites Radio (Instant Mix)", "Favorites", .favoritesInstantMix),
        ]
        for genre in genres {
            stations.append(("emby-radio-genre-\(genre)", "\(genre) Radio", "Genre", .genreRadio(genre)))
            stations.append(("emby-radio-genre-\(genre)-mix", "\(genre) Radio (Instant Mix)", "Genre", .genreInstantMix(genre)))
        }
        for decade in RadioConfig.decades {
            stations.append(("emby-radio-decade-\(decade.name)", "\(decade.name) Radio", "Decade",
                             .decadeRadio(start: decade.start, end: decade.end, name: decade.name)))
            stations.append(("emby-radio-decade-\(decade.name)-mix", "\(decade.name) Radio (Instant Mix)", "Decade",
                             .decadeInstantMix(start: decade.start, end: decade.end, name: decade.name)))
        }
        displayItems = stations.map {
            LibraryBrowserItem(id: $0.id, title: $0.title, info: $0.info, indentLevel: 0, hasChildren: false, type: .embyRadioStation($0.type))
        }
    }
}
