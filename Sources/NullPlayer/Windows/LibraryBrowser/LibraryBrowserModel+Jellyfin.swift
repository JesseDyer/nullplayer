import Foundation

/// The Jellyfin source.
extension LibraryBrowserModel {

    func loadJellyfinData(serverId: String, generation: Int) {
        let expectedSource = LibraryBrowserSource.jellyfin(serverId: serverId)
        guard isLoadContextActive(generation, source: expectedSource) else { return }
        isLoading = true
        errorMessage = nil
        let manager = JellyfinManager.shared
        let load: @MainActor () -> Void = { [weak self] in
            self?.loadJellyfinDataForCurrentMode(generation: generation, expectedSource: expectedSource)
        }
        guard manager.currentServer?.id != serverId else { load(); return }
        let server = manager.servers.first { $0.id == serverId }
        connectThenLoad(generation: generation, source: expectedSource,
                        connect: server.map { server in { try await manager.connect(to: server) } },
                        isConnected: { manager.currentServer?.id == serverId }, load: load)
    }

    private func loadJellyfinDataForCurrentMode(generation: Int, expectedSource: LibraryBrowserSource) {
        let manager = JellyfinManager.shared
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
                    if self.jellyfin.artists.isEmpty {
                        if self.pendingArtistLoadUnfiltered {
                            try Task.checkCancellation()
                            self.jellyfin.artists = try await manager.fetchArtistsUnfiltered()
                            guard self.isLoadContextActive(generation, source: expectedSource) else { return }
                        } else if manager.isContentPreloaded && !manager.cachedArtists.isEmpty {
                            self.jellyfin.artists = manager.cachedArtists
                            self.jellyfin.albums = manager.cachedAlbums
                        } else {
                            // The albums follow in the background
                            self.jellyfin.artists = try await preloadedOr([]) { try await manager.fetchArtists() }
                            if let server = manager.currentServer {
                                self.warmJellyfinAlbumsCache(forServerId: server.id)
                            }
                        }
                    }
                    self.pendingArtistLoadUnfiltered = false
                    self.buildJellyfinArtistItems()
                case .albums:
                    if self.jellyfin.albums.isEmpty {
                        self.jellyfin.albums = try await preloadedOr(manager.cachedAlbums) { try await manager.fetchAlbums() }
                    }
                    self.buildJellyfinAlbumItems()
                case .plists, .folders:
                    if self.jellyfin.playlists.isEmpty {
                        self.jellyfin.playlists = try await preloadedOr(manager.cachedPlaylists) { try await manager.fetchPlaylists() }
                    }
                    self.buildJellyfinPlaylistItems()
                case .search:
                    if self.searchQuery.isEmpty {
                        self.displayItems = []
                    } else {
                        self.jellyfinSearchResults = try await manager.searchWithArtistAlbums(query: self.searchQuery)
                        guard self.isLoadContextActive(generation, source: expectedSource) else { return }
                        self.buildJellyfinSearchItems()
                    }
                case .movies:
                    if self.jellyfinVideo.movies.isEmpty {
                        self.jellyfinVideo.movies = try await preloadedOr(manager.cachedMovies) { try await manager.fetchMovies() }
                    }
                    self.buildJellyfinMovieItems()
                case .shows:
                    if self.jellyfinVideo.shows.isEmpty {
                        self.jellyfinVideo.shows = try await preloadedOr(manager.cachedShows) { try await manager.fetchShows() }
                    }
                    self.buildJellyfinShowItems()
                case .radio:
                    self.loadJellyfinRadioStations(generation: generation)
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

    /// The Artists tab loaded without albums: fetch them in the background for the date and
    /// year sorts and for instant expansion.
    private func warmJellyfinAlbumsCache(forServerId serverId: String) {
        guard jellyfinAlbumWarmTask == nil else { return }
        jellyfinAlbumWarmTask = Task.detached { @MainActor [weak self] in
            do {
                let albums = try await JellyfinManager.shared.fetchAlbums()
                guard let self else { return }
                defer { self.jellyfinAlbumWarmTask = nil }
                guard case .jellyfin(let activeServerId) = self.currentSource, activeServerId == serverId,
                      self.jellyfin.albums.isEmpty else { return }
                self.jellyfin.albums = albums
                if self.browseMode == .artists {
                    self.buildJellyfinArtistItems()
                }
            } catch {
                self?.jellyfinAlbumWarmTask = nil
                if !(error is CancellationError) {
                    NSLog("LibraryBrowserModel: Jellyfin album cache warm failed: %@", error.localizedDescription.redactingSensitiveURLQueryItems)
                }
            }
        }
    }

    func rebuildJellyfinItems() {
        switch browseMode {
        case .artists: buildJellyfinArtistItems()
        case .albums: buildJellyfinAlbumItems()
        case .plists: buildJellyfinPlaylistItems()
        case .movies: buildJellyfinMovieItems()
        case .shows: buildJellyfinShowItems()
        case .search: buildJellyfinSearchItems()
        default: displayItems = []
        }
    }

    /// A music library was picked from the server bar (nil: all libraries).
    func selectJellyfinMusicLibrary(_ library: JellyfinMusicLibrary?) {
        if let library {
            JellyfinManager.shared.selectMusicLibrary(library)
        } else {
            JellyfinManager.shared.clearMusicLibrarySelection()
        }
        jellyfinAlbumWarmTask?.cancel()
        jellyfinAlbumWarmTask = nil
        resetJellyfinMusic()
        reloadData()
    }

    /// A video library was picked from the server bar (nil: all libraries).
    func selectJellyfinVideoLibrary(_ library: JellyfinMusicLibrary?) {
        JellyfinManager.shared.selectMovieLibrary(library)
        JellyfinManager.shared.selectShowLibrary(library)
        resetJellyfinVideo()
        reloadData()
    }

    // MARK: - Music rows

    private func buildJellyfinArtistItems() {
        var rows: [LibraryBrowserItem] = []
        for artist in sortJellyfinArtists(jellyfin.artists) {
            rows.append(jellyfinArtistItem(artist, indentLevel: 0))
            guard isExpanded(.jellyfinArtist, artist.id), let albums = jellyfin.artistAlbums[artist.id] else { continue }
            for album in sortJellyfinAlbums(albums) {
                rows.append(jellyfinAlbumItem(album, title: album.name, indentLevel: 1))
                rows += jellyfinSongRows(ofAlbum: album, indentLevel: 2)
            }
        }
        displayItems = rows
    }

    private func jellyfinArtistItem(_ artist: JellyfinArtist, indentLevel: Int) -> LibraryBrowserItem {
        let info = artist.albumCount > 0 ? countLabel(artist.albumCount, "album") : nil
        return LibraryBrowserItem(id: artist.id, title: artist.name, info: info, indentLevel: indentLevel, hasChildren: true, type: .jellyfinArtist(artist))
    }

    private func jellyfinAlbumItem(_ album: JellyfinAlbum, title: String, indentLevel: Int) -> LibraryBrowserItem {
        LibraryBrowserItem(id: album.id, title: title, info: album.year.map { String($0) }, indentLevel: indentLevel, hasChildren: true, type: .jellyfinAlbum(album))
    }

    /// An expanded album's songs, by disc then track number.
    private func jellyfinSongRows(ofAlbum album: JellyfinAlbum, indentLevel: Int) -> [LibraryBrowserItem] {
        guard isExpanded(.jellyfinAlbum, album.id), let songs = jellyfin.albumSongs[album.id] else { return [] }
        return jellyfinSongRows(discOrdered(songs, disc: \.discNumber, track: \.track), indentLevel: indentLevel)
    }

    private func buildJellyfinAlbumItems() {
        var rows: [LibraryBrowserItem] = []
        for album in sortJellyfinAlbums(jellyfin.albums) {
            rows.append(jellyfinAlbumItem(album, title: "\(album.artist ?? "Unknown") - \(album.name)", indentLevel: 0))
            rows += jellyfinSongRows(ofAlbum: album, indentLevel: 1)
        }
        displayItems = rows
    }

    private func buildJellyfinPlaylistItems() {
        var rows: [LibraryBrowserItem] = []
        for playlist in menuSorted(jellyfin.playlists, name: \.name) {
            rows.append(LibraryBrowserItem(id: playlist.id, title: playlist.name, info: countLabel(playlist.songCount, "track"), indentLevel: 0, hasChildren: playlist.songCount > 0, type: .jellyfinPlaylist(playlist)))
            guard isExpanded(.jellyfinPlaylist, playlist.id), let tracks = jellyfin.playlistTracks[playlist.id] else { continue }
            for track in tracks {
                rows.append(LibraryBrowserItem(id: "\(playlist.id)-\(track.id)", title: track.title, info: formatDuration(track.duration), indentLevel: 1, hasChildren: false, type: .jellyfinTrack(track)))
            }
        }
        displayItems = rows
    }

    private func jellyfinSongRows(_ songs: [JellyfinSong], indentLevel: Int) -> [LibraryBrowserItem] {
        songs.map { LibraryBrowserItem(id: $0.id, title: $0.title, info: formatDuration($0.duration), indentLevel: indentLevel, hasChildren: false, type: .jellyfinTrack($0)) }
    }

    // MARK: - Video rows

    private func buildJellyfinMovieItems() {
        displayItems = jellyfinVideo.movies.map { jellyfinMovieItem($0, indentLevel: 0) }
    }

    private func jellyfinMovieItem(_ movie: JellyfinMovie, indentLevel: Int) -> LibraryBrowserItem {
        let info = [movie.year.map { String($0) }, movie.formattedDuration].compactMap { $0 }.joined(separator: " • ")
        return LibraryBrowserItem(id: movie.id, title: movie.title, info: info.isEmpty ? nil : info, indentLevel: indentLevel, hasChildren: false, type: .jellyfinMovie(movie))
    }

    private func buildJellyfinShowItems() {
        displayItems = jellyfinVideo.shows.flatMap { jellyfinShowRows($0, indentLevel: 0) }
    }

    /// A show, then its seasons when expanded, each with its episodes when expanded.
    private func jellyfinShowRows(_ show: JellyfinShow, indentLevel: Int) -> [LibraryBrowserItem] {
        let info = [show.year.map { String($0) }, "\(show.childCount) seasons"].compactMap { $0 }.joined(separator: " • ")
        var rows = [LibraryBrowserItem(id: show.id, title: show.title, info: info, indentLevel: indentLevel, hasChildren: true, type: .jellyfinShow(show))]
        guard isExpanded(.jellyfinShow, show.id), let seasons = jellyfinVideo.showSeasons[show.id] else { return rows }
        for season in seasons {
            rows.append(LibraryBrowserItem(id: season.id, title: season.title, info: "\(season.childCount) episodes", indentLevel: indentLevel + 1, hasChildren: true, type: .jellyfinSeason(season)))
            guard isExpanded(.jellyfinSeason, season.id), let episodes = jellyfinVideo.seasonEpisodes[season.id] else { continue }
            for episode in episodes {
                rows.append(LibraryBrowserItem(id: episode.id, title: "\(episode.episodeIdentifier) - \(episode.title)", info: episode.formattedDuration, indentLevel: indentLevel + 2, hasChildren: false, type: .jellyfinEpisode(episode)))
            }
        }
        return rows
    }

    // MARK: - Search

    private func buildJellyfinSearchItems() {
        var rows: [LibraryBrowserItem] = []
        defer { displayItems = rows }
        guard let results = jellyfinSearchResults else { return }
        let artists = sortJellyfinArtists(results.artists)
        if !artists.isEmpty {
            rows.append(LibraryBrowserItem(id: "header-artists", title: "Artists (\(artists.count))", info: nil, indentLevel: 0, hasChildren: false, type: .header))
            rows += artists.map { jellyfinArtistItem($0, indentLevel: 1) }
        }
        let albums = sortJellyfinAlbums(results.albums)
        if !albums.isEmpty {
            rows.append(LibraryBrowserItem(id: "header-albums", title: "Albums (\(albums.count))", info: nil, indentLevel: 0, hasChildren: false, type: .header))
            rows += albums.map { jellyfinAlbumItem($0, title: $0.name, indentLevel: 1) }
        }
        let songs = menuSorted(results.songs, name: \.title, created: { $0.created }, year: { $0.year })
        if !songs.isEmpty {
            rows.append(LibraryBrowserItem(id: "header-tracks", title: "Tracks (\(songs.count))", info: nil, indentLevel: 0, hasChildren: false, type: .header))
            rows += jellyfinSongRows(songs, indentLevel: 1)
        }
        if !results.movies.isEmpty {
            rows.append(LibraryBrowserItem(id: "header-movies", title: "Movies (\(results.movies.count))", info: nil, indentLevel: 0, hasChildren: false, type: .header))
            rows += results.movies.map { jellyfinMovieItem($0, indentLevel: 1) }
        }
        if !results.shows.isEmpty {
            rows.append(LibraryBrowserItem(id: "header-shows", title: "TV Shows (\(results.shows.count))", info: nil, indentLevel: 0, hasChildren: false, type: .header))
            rows += results.shows.flatMap { jellyfinShowRows($0, indentLevel: 1) }
        }
    }

    // MARK: - Sorting

    private func sortJellyfinArtists(_ artists: [JellyfinArtist]) -> [JellyfinArtist] {
        sortServerArtists(artists,
                          albums: jellyfin.albums.map { .init(artistId: $0.artistId, artist: $0.artist, created: $0.created, year: $0.year) },
                          id: \.id, name: \.name)
    }

    private func sortJellyfinAlbums(_ albums: [JellyfinAlbum]) -> [JellyfinAlbum] {
        menuSorted(albums, name: \.name, created: { $0.created }, year: { $0.year })
    }

    // MARK: - Radio

    func loadJellyfinRadioStations(generation: Int) {
        guard case .jellyfin = currentSource else { return }
        let expectedSource = currentSource
        isLoading = true
        errorMessage = nil
        radioLoadTask?.cancel()
        radioLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let genres = await JellyfinManager.shared.getMusicGenres()
            guard !Task.isCancelled,
                  self.isLoadContextActive(generation, source: expectedSource),
                  self.browseMode == .radio else { return }
            self.buildJellyfinRadioStationItems(genres: genres)
            self.isLoading = false
            self.radioLoadTask = nil
        }
    }

    private func buildJellyfinRadioStationItems(genres: [String]) {
        var stations: [(id: String, title: String, info: String, type: JellyfinRadioType)] = [
            ("jf-radio-library", "Library Radio", "Library", .libraryRadio),
            ("jf-radio-library-mix", "Library Radio (Instant Mix)", "Library", .libraryInstantMix),
            ("jf-radio-fav", "Favorites Radio", "Favorites", .favoritesRadio),
            ("jf-radio-fav-mix", "Favorites Radio (Instant Mix)", "Favorites", .favoritesInstantMix),
        ]
        for genre in genres {
            stations.append(("jf-radio-genre-\(genre)", "\(genre) Radio", "Genre", .genreRadio(genre)))
            stations.append(("jf-radio-genre-\(genre)-mix", "\(genre) Radio (Instant Mix)", "Genre", .genreInstantMix(genre)))
        }
        for decade in RadioConfig.decades {
            stations.append(("jf-radio-decade-\(decade.name)", "\(decade.name) Radio", "Decade",
                             .decadeRadio(start: decade.start, end: decade.end, name: decade.name)))
            stations.append(("jf-radio-decade-\(decade.name)-mix", "\(decade.name) Radio (Instant Mix)", "Decade",
                             .decadeInstantMix(start: decade.start, end: decade.end, name: decade.name)))
        }
        displayItems = stations.map {
            LibraryBrowserItem(id: $0.id, title: $0.title, info: $0.info, indentLevel: 0, hasChildren: false, type: .jellyfinRadioStation($0.type))
        }
    }
}
