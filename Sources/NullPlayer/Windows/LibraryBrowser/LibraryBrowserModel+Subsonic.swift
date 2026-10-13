import Foundation

/// The Subsonic source.
extension LibraryBrowserModel {

    func loadSubsonicData(serverId: String, generation: Int) {
        let expectedSource = LibraryBrowserSource.subsonic(serverId: serverId)
        guard isLoadContextActive(generation, source: expectedSource) else { return }
        isLoading = true
        errorMessage = nil
        let manager = SubsonicManager.shared
        let load: @MainActor () -> Void = { [weak self] in
            self?.loadSubsonicDataForCurrentMode(generation: generation, expectedSource: expectedSource)
        }
        guard manager.currentServer?.id != serverId else { load(); return }
        let server = manager.servers.first { $0.id == serverId }
        connectThenLoad(generation: generation, source: expectedSource,
                        connect: server.map { server in { try await manager.connect(to: server) } },
                        isConnected: { manager.currentServer?.id == serverId }, load: load)
    }

    private func loadSubsonicDataForCurrentMode(generation: Int, expectedSource: LibraryBrowserSource) {
        let manager = SubsonicManager.shared
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
                    if self.subsonic.artists.isEmpty {
                        if self.pendingArtistLoadUnfiltered {
                            try Task.checkCancellation()
                            self.subsonic.artists = try await manager.fetchArtistsUnfiltered()
                            guard self.isLoadContextActive(generation, source: expectedSource) else { return }
                        } else {
                            self.subsonic.artists = try await preloadedOr(manager.cachedArtists) { try await manager.fetchArtists() }
                            self.subsonic.albums = try await preloadedOr(manager.cachedAlbums) { try await manager.fetchAlbums() }
                        }
                    }
                    self.pendingArtistLoadUnfiltered = false
                    self.buildSubsonicArtistItems()
                case .albums:
                    if self.subsonic.albums.isEmpty {
                        self.subsonic.albums = try await preloadedOr(manager.cachedAlbums) { try await manager.fetchAlbums() }
                    }
                    self.buildSubsonicAlbumItems()
                case .plists, .folders:
                    if self.subsonic.playlists.isEmpty {
                        self.subsonic.playlists = try await preloadedOr(manager.cachedPlaylists) { try await manager.fetchPlaylists() }
                    }
                    self.buildSubsonicPlaylistItems()
                case .search:
                    if self.searchQuery.isEmpty {
                        self.displayItems = []
                    } else {
                        self.subsonicSearchResults = try await manager.searchWithArtistAlbums(query: self.searchQuery)
                        guard self.isLoadContextActive(generation, source: expectedSource) else { return }
                        self.buildSubsonicSearchItems()
                    }
                case .movies, .shows, .history:
                    self.displayItems = []
                case .radio:
                    self.loadSubsonicRadioStations(generation: generation)
                    return
                }
                self.finishLoadIfActive(generation: generation, source: expectedSource)
            } catch is CancellationError {
            } catch where Task.isCancelled {
            } catch {
                self.setLoadErrorIfActive(error.localizedDescription, generation: generation, source: expectedSource)
            }
        }
    }

    func rebuildSubsonicItems() {
        switch browseMode {
        case .artists: buildSubsonicArtistItems()
        case .albums: buildSubsonicAlbumItems()
        case .plists: buildSubsonicPlaylistItems()
        case .search: buildSubsonicSearchItems()
        default: displayItems = []
        }
    }

    /// A music folder was picked from the server bar (nil: all folders).
    func selectSubsonicMusicFolder(_ folder: SubsonicMusicFolder?) {
        if let folder {
            SubsonicManager.shared.selectMusicFolder(folder)
        } else {
            SubsonicManager.shared.clearMusicFolderSelection()
        }
        resetSubsonic()
        reloadData()
    }

    // MARK: - Rows

    private func buildSubsonicArtistItems() {
        var rows: [LibraryBrowserItem] = []
        for artist in sortSubsonicArtists(subsonic.artists) {
            rows.append(subsonicArtistItem(artist, indentLevel: 0))
            guard isExpanded(.subsonicArtist, artist.id), let albums = subsonic.artistAlbums[artist.id] else { continue }
            for album in sortSubsonicAlbums(albums) {
                rows.append(subsonicAlbumItem(album, title: album.name, indentLevel: 1))
                rows += subsonicSongRows(ofAlbum: album, indentLevel: 2)
            }
        }
        displayItems = rows
    }

    private func subsonicArtistItem(_ artist: SubsonicArtist, indentLevel: Int) -> LibraryBrowserItem {
        let info = artist.albumCount > 0 ? countLabel(artist.albumCount, "album") : nil
        return LibraryBrowserItem(id: artist.id, title: artist.name, info: info, indentLevel: indentLevel, hasChildren: true, type: .subsonicArtist(artist))
    }

    private func subsonicAlbumItem(_ album: SubsonicAlbum, title: String, indentLevel: Int) -> LibraryBrowserItem {
        LibraryBrowserItem(id: album.id, title: title, info: album.year.map { String($0) }, indentLevel: indentLevel, hasChildren: true, type: .subsonicAlbum(album))
    }

    /// An expanded album's songs, by disc then track number.
    private func subsonicSongRows(ofAlbum album: SubsonicAlbum, indentLevel: Int) -> [LibraryBrowserItem] {
        guard isExpanded(.subsonicAlbum, album.id), let songs = subsonic.albumSongs[album.id] else { return [] }
        return subsonicSongRows(discOrdered(songs, disc: \.discNumber, track: \.track), indentLevel: indentLevel)
    }

    private func buildSubsonicAlbumItems() {
        var rows: [LibraryBrowserItem] = []
        for album in sortSubsonicAlbums(subsonic.albums) {
            rows.append(subsonicAlbumItem(album, title: "\(album.artist ?? "Unknown") - \(album.name)", indentLevel: 0))
            rows += subsonicSongRows(ofAlbum: album, indentLevel: 1)
        }
        displayItems = rows
    }

    private func buildSubsonicPlaylistItems() {
        var rows: [LibraryBrowserItem] = []
        for playlist in menuSorted(subsonic.playlists, name: \.name, created: { $0.changed ?? $0.created }) {
            rows.append(LibraryBrowserItem(id: playlist.id, title: playlist.name, info: countLabel(playlist.songCount, "track"), indentLevel: 0, hasChildren: playlist.songCount > 0, type: .subsonicPlaylist(playlist)))
            guard isExpanded(.subsonicPlaylist, playlist.id), let tracks = subsonic.playlistTracks[playlist.id] else { continue }
            for track in tracks {
                rows.append(LibraryBrowserItem(id: "\(playlist.id)-\(track.id)", title: track.title, info: formatDuration(track.duration), indentLevel: 1, hasChildren: false, type: .subsonicTrack(track)))
            }
        }
        displayItems = rows
    }

    private func buildSubsonicSearchItems() {
        var rows: [LibraryBrowserItem] = []
        defer { displayItems = rows }
        guard let results = subsonicSearchResults else { return }
        let artists = sortSubsonicArtists(results.artists)
        if !artists.isEmpty {
            rows.append(LibraryBrowserItem(id: "header-artists", title: "Artists (\(artists.count))", info: nil, indentLevel: 0, hasChildren: false, type: .header))
            rows += artists.map { subsonicArtistItem($0, indentLevel: 1) }
        }
        let albums = sortSubsonicAlbums(results.albums)
        if !albums.isEmpty {
            rows.append(LibraryBrowserItem(id: "header-albums", title: "Albums (\(albums.count))", info: nil, indentLevel: 0, hasChildren: false, type: .header))
            rows += albums.map { subsonicAlbumItem($0, title: $0.name, indentLevel: 1) }
        }
        let songs = menuSorted(results.songs, name: \.title, created: { $0.created }, year: { $0.year })
        if !songs.isEmpty {
            rows.append(LibraryBrowserItem(id: "header-tracks", title: "Tracks (\(songs.count))", info: nil, indentLevel: 0, hasChildren: false, type: .header))
            rows += subsonicSongRows(songs, indentLevel: 1)
        }
    }

    private func subsonicSongRows(_ songs: [SubsonicSong], indentLevel: Int) -> [LibraryBrowserItem] {
        songs.map { LibraryBrowserItem(id: $0.id, title: $0.title, info: formatDuration($0.duration), indentLevel: indentLevel, hasChildren: false, type: .subsonicTrack($0)) }
    }

    // MARK: - Sorting

    private func sortSubsonicArtists(_ artists: [SubsonicArtist]) -> [SubsonicArtist] {
        sortServerArtists(artists,
                          albums: subsonic.albums.map { .init(artistId: $0.artistId, artist: $0.artist, created: $0.created, year: $0.year) },
                          id: \.id, name: \.name, indexLetter: \.indexLetter)
    }

    private func sortSubsonicAlbums(_ albums: [SubsonicAlbum]) -> [SubsonicAlbum] {
        menuSorted(albums, name: \.name, created: { $0.created }, year: { $0.year })
    }

    // MARK: - Radio

    func loadSubsonicRadioStations(generation: Int) {
        guard case .subsonic = currentSource else { return }
        let expectedSource = currentSource
        isLoading = true
        errorMessage = nil
        radioLoadTask?.cancel()
        radioLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let genres = await SubsonicManager.shared.getGenres()
            guard !Task.isCancelled,
                  self.isLoadContextActive(generation, source: expectedSource),
                  self.browseMode == .radio else { return }
            self.buildSubsonicRadioStationItems(genres: genres)
            self.isLoading = false
            self.radioLoadTask = nil
        }
    }

    private func buildSubsonicRadioStationItems(genres: [String]) {
        var stations: [(id: String, title: String, info: String, type: SubsonicRadioType)] = [
            ("sub-radio-library", "Library Radio", "Library", .libraryRadio),
            ("sub-radio-library-sim", "Library Radio (Similar)", "Library", .librarySimilar),
            ("sub-radio-starred", "Starred Radio", "Starred", .starredRadio),
            ("sub-radio-starred-sim", "Starred Radio (Similar)", "Starred", .starredSimilar),
        ]
        for genre in genres {
            stations.append(("sub-radio-genre-\(genre)", "\(genre) Radio", "Genre", .genreRadio(genre)))
            stations.append(("sub-radio-genre-\(genre)-sim", "\(genre) Radio (Similar)", "Genre", .genreSimilar(genre)))
        }
        for decade in RadioConfig.decades {
            stations.append(("sub-radio-decade-\(decade.name)", "\(decade.name) Radio", "Decade",
                             .decadeRadio(start: decade.start, end: decade.end, name: decade.name)))
            stations.append(("sub-radio-decade-\(decade.name)-sim", "\(decade.name) Radio (Similar)", "Decade",
                             .decadeSimilar(start: decade.start, end: decade.end, name: decade.name)))
        }
        displayItems = stations.map {
            LibraryBrowserItem(id: $0.id, title: $0.title, info: $0.info, indentLevel: 0, hasChildren: false, type: .subsonicRadioStation($0.type))
        }
    }
}
