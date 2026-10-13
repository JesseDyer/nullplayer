import Foundation
import NullPlayerCore

/// The library browser's state and data, shared by the classic and modern views.
///
/// Each browser instance owns one: the classic and modern windows, the windows Compact Mode
/// creates, and a `.wal` skin's embedded library. The model loads and builds the rows of the
/// current source and tab, and keeps the caches, expansion, sort and search behind them. Its view
/// draws `displayItems` and reacts to `onChange`; the view keeps scroll position, selection, hover
/// and animation. Loading is split per source across the `LibraryBrowserModel+<Source>` files.
@MainActor
final class LibraryBrowserModel: NSObject {

    /// What changed, for the view to react to.
    enum Change {
        /// `displayItems` changed.
        case rows
        /// `isLoading` or `errorMessage` changed.
        case loading
        /// A new list replaced the rows: selection and scroll position no longer apply.
        case rowsReplaced
        /// The rows were re-built in place after an expand, collapse or re-sort.
        case rebuilt
        /// A load of the current tab finished.
        case loaded
        /// The row a search → Artists navigation was looking for: select it and scroll to it.
        case reveal(Int)
        /// `currentSource` changed; the rows were cleared and are reloading.
        case source
        /// `browseMode` changed.
        case browseMode
    }

    var onChange: ((Change) -> Void)?

    /// Prefixes the keys each view keeps its own column visibility and tab-slot choice under
    /// ("Classic" for the classic view, empty for the modern view).
    private let keyPrefix: String

    // MARK: - Source and tab

    var currentSource: LibraryBrowserSource = .local {
        didSet {
            currentSource.save()
            sourceDidChange()
        }
    }
    /// A saved server source whose server list had not loaded yet; restored on `serversDidChange`.
    var pendingSourceRestore: LibraryBrowserSource?

    var browseMode: LibraryBrowseMode = .artists {
        didSet {
            guard browseMode != oldValue else { return }
            if oldValue == .folders, browseMode != .folders {
                cancelLocalFolderBuild()
            }
            onChange?(.browseMode)
        }
    }

    var searchQuery: String = ""

    // MARK: - Rows and loading

    var displayItems: [LibraryBrowserItem] = [] {
        didSet { onChange?(.rows) }
    }
    var isLoading = false {
        didSet { onChange?(.loading) }
    }
    var errorMessage: String? {
        didSet { onChange?(.loading) }
    }

    /// Bumped by every reload; a load that finds it changed was superseded and drops its result.
    var loadGeneration = 0
    var sourceConnectTask: Task<Void, Never>?
    /// The current server source's load of the current tab.
    var loadTask: Task<Void, Never>?
    var radioLoadTask: Task<Void, Never>?
    /// A Subsonic, Jellyfin or Emby row's children; a newer expand replaces it.
    var expandTask: Task<Void, Never>?
    var jellyfinAlbumWarmTask: Task<Void, Never>?

    // MARK: - Expansion

    var expanded: Set<ExpansionKey> = []
    /// Expanded YouTube channels, kept whole: their uploads load by channel.
    var expandedYouTubeChannels: [String: YouTubeChannel] = [:]

    // MARK: - Search → Artists

    var pendingScrollToArtistId: String?
    var pendingScrollToArtistName: String?
    var pendingScrollAttempts = 0
    /// The Artists load after a search jump fetches unfiltered, so an artist the search found
    /// outside the selected folder or library is in the list.
    var pendingArtistLoadUnfiltered = false

    // MARK: - Columns

    var visibleTrackColumnIds = LibraryBrowserColumn.defaultTrackColumnIds { didSet { saveVisibleColumns() } }
    var visibleAlbumColumnIds = LibraryBrowserColumn.defaultAlbumColumnIds { didSet { saveVisibleColumns() } }
    var visibleArtistColumnIds = LibraryBrowserColumn.defaultArtistColumnIds { didSet { saveVisibleColumns() } }

    // YouTube channels keep their own sort state (session-only, default = none → date
    // order as returned by yt-dlp). This keeps the persisted library column sort from
    // leaking in and re-ordering videos to A–Z on every rebuild (e.g. after a download).
    // Only an explicit header click in the YouTube tab sets this.
    var youtubeColumnSortId: String?
    var youtubeColumnSortAscending = true

    // MARK: - Server caches

    var plex = PlexBrowserCache()
    var subsonic = ServerMusicCache<SubsonicArtist, SubsonicAlbum, SubsonicSong, SubsonicPlaylist>()
    var jellyfin = ServerMusicCache<JellyfinArtist, JellyfinAlbum, JellyfinSong, JellyfinPlaylist>()
    var jellyfinVideo = ServerVideoCache<JellyfinMovie, JellyfinShow, JellyfinSeason, JellyfinEpisode>()
    var emby = ServerMusicCache<EmbyArtist, EmbyAlbum, EmbySong, EmbyPlaylist>()
    var embyVideo = ServerVideoCache<EmbyMovie, EmbyShow, EmbySeason, EmbyEpisode>()
    var subsonicSearchResults: SubsonicSearchResults?
    var jellyfinSearchResults: JellyfinSearchResults?
    var embySearchResults: EmbySearchResults?

    // MARK: - Local

    var localArtistPageOffset = 0
    var localAlbumPageOffset = 0
    let localPageSize = 200
    var localArtistTotal = 0
    var localAlbumTotal = 0
    var localArtistLetterOffsets: [String: Int] = [:]
    var localAlbumLetterOffsets: [String: Int] = [:]
    /// Bumped on each Folders rebuild; an in-flight off-actor walk discards its result if stale.
    var localFolderBuildGeneration = 0
    /// The in-flight Folders walk, cancelled when a newer rebuild starts (fast-click protection).
    var localFolderBuildTask: Task<Void, Never>?
    var cachedLocalMovies: [LocalVideo] = []
    var cachedLocalShows: [LocalShow] = []
    var localPlaylistTracks: [String: [Track]] = [:]
    var cachedLocalPlaylists: [LocalPlaylist] = []
    var localLibraryReloadWorkItem: DispatchWorkItem?
    /// Watch folders on volumes that are not mounted, as of the last local load.
    var offlineWatchFolders: [WatchFolderSummary] = []
    var offlineVolumePrefixes: Set<String> = []

    // MARK: - Internet Radio and YouTube

    var cachedRadioStations: [RadioStation] = []
    var cachedRadioFolders: [RadioFolderDescriptor] = []
    /// Search tab (YouTube source): channels found by the last submitted query.
    let youtubeSearch = YouTubeChannelSearch()

    // MARK: - Init

    /// Restores the saved source. The first load is the view's `reloadData()` once it has
    /// subscribed to `onChange`.
    init(keyPrefix: String) {
        self.keyPrefix = keyPrefix
        super.init()
        loadVisibleColumns()
        // Set directly, so `currentSource`'s observer does not start a load before the view listens.
        (currentSource, pendingSourceRestore) = Self.restoredSource()
        currentSource.save()
        // Internet Radio and YouTube list their content on the Radio tab.
        if currentSource.usesRadioTab { browseMode = .radio }
        observeNotifications()
    }

    deinit {
        localLibraryReloadWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    /// The saved source when its server is still configured. A server source saved before the
    /// server list has loaded is returned as pending, with Local shown meanwhile.
    private static func restoredSource() -> (LibraryBrowserSource, pending: LibraryBrowserSource?) {
        guard let saved = LibraryBrowserSource.load() else {
            if PlexManager.shared.isLinked, let first = PlexManager.shared.servers.first {
                return (.plex(serverId: first.id), nil)
            }
            return (.local, nil)
        }
        if saved.isPlex && !PlexManager.shared.isLinked { return (.local, nil) }
        if let source = configuredSource(for: saved) { return (source, nil) }
        return (.local, saved)
    }

    /// `source` if its server is configured, else the first configured server of its kind; nil
    /// when there is none. Local, Internet Radio and YouTube are always configured.
    static func configuredSource(for source: LibraryBrowserSource) -> LibraryBrowserSource? {
        let servers: [String]
        let first: (String) -> LibraryBrowserSource
        switch source {
        case .local, .radio, .youtube: return source
        case .plex: servers = PlexManager.shared.servers.map(\.id); first = LibraryBrowserSource.plex
        case .subsonic: servers = SubsonicManager.shared.servers.map(\.id); first = LibraryBrowserSource.subsonic
        case .jellyfin: servers = JellyfinManager.shared.servers.map(\.id); first = LibraryBrowserSource.jellyfin
        case .emby: servers = EmbyManager.shared.servers.map(\.id); first = LibraryBrowserSource.emby
        }
        if let serverId = source.serverId, servers.contains(serverId) { return source }
        return servers.first.map(first)
    }

    /// The tab a restored session was on. Folders belongs to the Local source; elsewhere its slot
    /// is Plists.
    func restoreBrowseMode(rawValue: Int) {
        guard let mode = LibraryBrowseMode(rawValue: rawValue) else { return }
        browseMode = mode == .folders && !isLocalSource ? .plists : mode
        onChange?(.rowsReplaced)
        reloadData()
    }

    // MARK: - Source changes

    private func sourceDidChange() {
        invalidateActiveLoads()
        if browseMode == .folders && !isLocalSource {
            browseMode = .plists
        }
        clearAllCachedData()
        clearLocalCachedData()
        displayItems.removeAll()
        errorMessage = nil
        isLoading = false
        // Internet Radio only has radio/search content, but every library
        // source supports the Radio tab. Preserve Radio across source changes.
        // YouTube reuses the Radio tab to list its channels, so force it too.
        if !browseMode.isHistoryMode, currentSource.usesRadioTab {
            browseMode = .radio
        }
        onChange?(.source)
        reloadData()
    }

    var isLocalSource: Bool {
        if case .local = currentSource { return true }
        return false
    }

    // MARK: - Tab slots

    /// The Plists tab slot toggles between Plists and Folders (Local source only).
    var localPlistsSlotShowsFolders: Bool {
        get { UserDefaults.standard.object(forKey: keyPrefix + "LocalPlistsSlotShowsFolders") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: keyPrefix + "LocalPlistsSlotShowsFolders") }
    }

    var effectivePlistsSlotMode: LibraryBrowseMode {
        isLocalSource && localPlistsSlotShowsFolders ? .folders : .plists
    }

    /// The Radio tab slot toggles between Internet Radio stations and YouTube
    /// channels (YouTube source only), mirroring the Plists/Folders toggle.
    /// Defaults to showing channels so the YouTube source opens on "Channels".
    var radioSlotShowsChannels: Bool {
        get { UserDefaults.standard.object(forKey: keyPrefix + "RadioSlotShowsChannels") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: keyPrefix + "RadioSlotShowsChannels") }
    }
    /// Whether the Radio tab slot is currently displaying YouTube channels.
    var radioSlotShowingChannels: Bool {
        currentSource.isYouTube && radioSlotShowsChannels
    }
    /// Whether the Search tab is showing YouTube channel-search results (YouTube source).
    var isYouTubeChannelSearch: Bool {
        currentSource.isYouTube && browseMode == .search
    }
    /// A YouTube channel search typed but not yet run: Enter submits it. Once its results
    /// are showing, Enter acts on the selected row (subscribe / expand) instead.
    var hasUnsubmittedYouTubeSearch: Bool {
        isYouTubeChannelSearch && youtubeSearch.isUnsubmitted(searchQuery)
    }

    /// A tab-bar click on `slot`. A double-click flips what a two-way slot shows: Plists and
    /// Folders for the Local source, Internet Radio and Channels for YouTube.
    func selectTab(_ slot: LibraryBrowseMode, doubleClick: Bool) {
        if doubleClick, slot == .plists, isLocalSource {
            localPlistsSlotShowsFolders.toggle()
        } else if doubleClick, slot == .radio, currentSource.isYouTube {
            radioSlotShowsChannels.toggle()
        }
        browseMode = slot == .plists ? effectivePlistsSlotMode : slot
        onChange?(.rowsReplaced)
        loadDataForCurrentMode()
    }

    // MARK: - Sort

    /// The current tab's sort; each tab keeps its own in `LibraryBrowserTabSortStore`.
    var tabSort: LibraryBrowserTabSort { LibraryBrowserTabSortStore.shared.sort(for: browseMode.rawValue) }
    var currentSort: LibraryBrowserSortOption { tabSort.menuSort }
    /// Column header sort; overrides `currentSort` when set
    var columnSortId: String? { tabSort.columnSortId }

    /// Column sort that applies to the current source. YouTube uses its own session
    /// state (default date order) instead of the persisted library sort.
    var activeColumnSortId: String? {
        currentSource.isYouTube ? youtubeColumnSortId : columnSortId
    }
    var activeColumnSortAscending: Bool {
        currentSource.isYouTube ? youtubeColumnSortAscending : tabSort.columnSortAscending
    }

    /// Sort-menu choice for the current tab: local paging restarts under the new order.
    func selectMenuSort(_ option: LibraryBrowserSortOption) {
        LibraryBrowserTabSortStore.shared.setMenuSort(option, for: browseMode.rawValue)
        localArtistPageOffset = 0; localAlbumPageOffset = 0
        localArtistLetterOffsets = [:]; localAlbumLetterOffsets = [:]
        rebuildCurrentModeItems()
    }

    /// A column-header click: sort by that column, or reverse the order when it already does.
    func sortByColumn(_ columnId: String) {
        if currentSource.isYouTube {
            guard columnId != "thumbnail" else { return }  // an image column has nothing to sort by
            // YouTube uses its own session sort (not persisted to the library sort).
            if youtubeColumnSortId == columnId {
                youtubeColumnSortAscending.toggle()
            } else {
                youtubeColumnSortId = columnId
                youtubeColumnSortAscending = true
            }
        } else {
            LibraryBrowserTabSortStore.shared.clickColumn(columnId, for: browseMode.rawValue)
        }
        applyColumnSort(collapseExpanded: true)
    }

    func compareNameStrings(_ lhs: String, _ rhs: String, ascending: Bool) -> Bool {
        LibraryTextSorter.areInOrder(lhs, rhs, ascending: ascending, ignoreLeadingArticles: true)
    }

    // MARK: - Loading

    func reloadData() {
        let generation = invalidateActiveLoads()
        loadDataForCurrentMode(generation: generation)
    }

    func loadDataForCurrentMode(generation: Int? = nil) {
        let generation = generation ?? loadGeneration

        if browseMode.isHistoryMode {
            invalidateActiveLoads()
            displayItems = []
            isLoading = false
            errorMessage = nil
            onChange?(.rowsReplaced)
            return
        }

        // YouTube content lives only in the Radio tab slot (channels or Internet Radio
        // stations) and the Search tab; Internet Radio has only Radio and Search.
        if currentSource.usesRadioTab {
            switch browseMode {
            case .radio:
                if radioSlotShowingChannels { loadYouTubeChannels() } else { loadRadioStations() }
            case .search:
                if currentSource.isYouTube { loadYouTubeSearchResults() } else { loadRadioSearchResults() }
            default:
                isLoading = false
                errorMessage = nil
                displayItems = []
            }
            return
        }

        if browseMode == .radio {
            switch currentSource {
            case .plex: loadPlexRadioStations(generation: generation)
            case .subsonic: loadSubsonicRadioStations(generation: generation)
            case .jellyfin: loadJellyfinRadioStations(generation: generation)
            case .emby: loadEmbyRadioStations(generation: generation)
            case .local: loadLocalRadioStations()
            case .radio, .youtube: displayItems = []
            }
            return
        }

        switch currentSource {
        case .local: loadLocalData()
        case .plex(let serverId): loadPlexData(serverId: serverId, generation: generation)
        case .subsonic(let serverId): loadSubsonicData(serverId: serverId, generation: generation)
        case .jellyfin(let serverId): loadJellyfinData(serverId: serverId, generation: generation)
        case .emby(let serverId): loadEmbyData(serverId: serverId, generation: generation)
        case .radio, .youtube: break
        }
    }

    /// Rebuild the current tab's rows from the caches, after an expand, collapse or re-sort.
    func rebuildCurrentModeItems() {
        onChange?(.rebuilt)
        if currentSource.usesRadioTab {
            switch browseMode {
            case .radio:
                if radioSlotShowingChannels { buildYouTubeChannelItems() } else { buildRadioStationItems() }
            case .search:
                if currentSource.isYouTube { buildYouTubeSearchItems() } else { buildRadioSearchItems() }
            default:
                displayItems = []
            }
            if activeColumnSortId != nil { applyColumnSort() }
            return
        }
        // A server's or the library's radio stations are not rebuilt; they stay as loaded.
        if browseMode == .radio { return }
        switch currentSource {
        case .local: rebuildLocalItems()
        case .plex: rebuildPlexItems()
        case .subsonic: rebuildSubsonicItems()
        case .jellyfin: rebuildJellyfinItems()
        case .emby: rebuildEmbyItems()
        case .radio, .youtube: break
        }
        if columnSortId != nil { applyColumnSort() }
        resolvePendingArtist()
    }

    /// The Refresh button: re-read the current tab from its source, dropping the server's cache.
    func refreshCurrentSource() {
        if currentSource.usesRadioTab {
            if case .youtube = currentSource, browseMode == .search {
                loadYouTubeSearchResults(force: true)
            } else if case .youtube = currentSource, browseMode != .radio {
                isLoading = false
                errorMessage = nil
                displayItems = []
            } else {
                loadDataForCurrentMode()
            }
            return
        }
        if browseMode == .radio {
            loadDataForCurrentMode()
            return
        }
        switch currentSource {
        case .local:
            MediaLibrary.shared.rescanWatchFolders()
            loadLocalData()
        case .plex:
            refreshData()
        case .subsonic:
            SubsonicManager.shared.clearCachedContent()
            refreshAfterPreload { await SubsonicManager.shared.preloadLibraryContent() }
        case .jellyfin:
            jellyfinAlbumWarmTask?.cancel(); jellyfinAlbumWarmTask = nil
            JellyfinManager.shared.clearCachedContent()
            refreshAfterPreload { await JellyfinManager.shared.preloadLibraryContent() }
        case .emby:
            EmbyManager.shared.clearCachedContent()
            refreshAfterPreload { await EmbyManager.shared.preloadLibraryContent() }
        case .radio, .youtube:
            break
        }
    }

    /// Show the loading state at once, then reload once the server's library is preloaded again.
    private func refreshAfterPreload(_ preload: @escaping @MainActor () async -> Void) {
        loadTask?.cancel(); loadTask = nil
        let source = currentSource
        isLoading = true; errorMessage = nil; displayItems = []
        Task { @MainActor [weak self] in
            await preload()
            guard let self, self.currentSource == source else { return }
            self.refreshData()
        }
    }

    /// Clear every server cache and reload the current tab.
    func refreshData() {
        if case .plex = currentSource, !PlexManager.shared.isLinked { return }
        let generation = invalidateActiveLoads()
        clearAllCachedData()
        onChange?(.rowsReplaced)
        isLoading = true; errorMessage = nil; displayItems = []
        PlexManager.shared.clearCachedContent()
        loadDataForCurrentMode(generation: generation)
    }

    // MARK: - Load generations

    @discardableResult
    func invalidateActiveLoads() -> Int {
        loadGeneration &+= 1
        for task in [sourceConnectTask, loadTask, radioLoadTask, expandTask, jellyfinAlbumWarmTask] {
            task?.cancel()
        }
        sourceConnectTask = nil; loadTask = nil; radioLoadTask = nil; expandTask = nil; jellyfinAlbumWarmTask = nil
        youtubeSearch.cancel()
        return loadGeneration
    }

    func isLoadContextActive(_ generation: Int, source expectedSource: LibraryBrowserSource) -> Bool {
        generation == loadGeneration && currentSource == expectedSource
    }

    func setLoadErrorIfActive(_ message: String, generation: Int, source expectedSource: LibraryBrowserSource) {
        guard isLoadContextActive(generation, source: expectedSource) else { return }
        isLoading = false
        errorMessage = message
    }

    func finishLoadIfActive(generation: Int, source expectedSource: LibraryBrowserSource) {
        guard isLoadContextActive(generation, source: expectedSource) else { return }
        isLoading = false
        errorMessage = nil
        // Apply any active column-header sort so a fresh server load matches what an
        // expand-driven rebuild produces — otherwise expanding a row would re-order the list.
        if columnSortId != nil { applyColumnSort() }
        resolvePendingArtist()
        onChange?(.loaded)
    }

    /// A server's library is preloading: wait for it (up to two seconds) rather than fetch the
    /// same content twice. Returns false once the load is superseded.
    func waitForPreload(_ isPreloading: @MainActor () -> Bool, generation: Int,
                        source expectedSource: LibraryBrowserSource) async throws -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while isPreloading(), Date() < deadline {
            try Task.checkCancellation()
            guard isLoadContextActive(generation, source: expectedSource) else { return false }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return isLoadContextActive(generation, source: expectedSource)
    }

    /// A tab's rows from the server's preload when it has them, else from `fetch`. A fetch that
    /// returns after the load was superseded throws `CancellationError`.
    func preloadedOrFetched<Item>(_ preloaded: [Item], isPreloaded: Bool, generation: Int,
                                  source expectedSource: LibraryBrowserSource,
                                  fetch: @MainActor () async throws -> [Item]) async throws -> [Item] {
        if isPreloaded && !preloaded.isEmpty { return preloaded }
        try Task.checkCancellation()
        let items = try await fetch()
        guard isLoadContextActive(generation, source: expectedSource) else { throw CancellationError() }
        return items
    }

    /// Connect a server source's manager to its server, then `load` if it is still current.
    /// `connect` is nil when the server is no longer configured.
    func connectThenLoad(generation: Int, source expectedSource: LibraryBrowserSource,
                         connect: (@MainActor () async throws -> Void)?,
                         isConnected: @escaping @MainActor () -> Bool,
                         load: @escaping @MainActor () -> Void) {
        guard let connect else {
            setLoadErrorIfActive("Server not found", generation: generation, source: expectedSource)
            return
        }
        sourceConnectTask?.cancel()
        sourceConnectTask = Task { @MainActor [weak self] in
            guard let self, self.isLoadContextActive(generation, source: expectedSource) else { return }
            do {
                try await connect()
                guard self.isLoadContextActive(generation, source: expectedSource), isConnected() else { return }
                load()
            } catch {
                self.setLoadErrorIfActive(error.localizedDescription, generation: generation, source: expectedSource)
            }
        }
    }

    // MARK: - Caches

    /// Drop every server's rows and collapse them; the local rows are kept.
    func clearAllCachedData() {
        jellyfinAlbumWarmTask?.cancel()
        jellyfinAlbumWarmTask = nil
        plex = PlexBrowserCache()
        collapse(.plexLibrary, .plexPlaylists)
        resetSubsonic()
        resetJellyfinMusic()
        resetJellyfinVideo()
        resetEmbyMusic()
        resetEmbyVideo()
        cachedRadioStations = []
        cachedRadioFolders = []
    }

    func clearLocalCachedData() {
        localArtistPageOffset = 0; localAlbumPageOffset = 0
        localArtistTotal = 0; localAlbumTotal = 0
        localArtistLetterOffsets = [:]; localAlbumLetterOffsets = [:]
        cachedLocalMovies = []; cachedLocalShows = []
        collapse(.local)
    }

    func resetSubsonic() { subsonic = .init(); collapse(.subsonic) }
    func resetJellyfinMusic() { jellyfin = .init(); collapse(.jellyfinMusic) }
    func resetJellyfinVideo() { jellyfinVideo = .init(); collapse(.jellyfinVideo) }
    func resetEmbyMusic() { emby = .init(); collapse(.embyMusic) }
    func resetEmbyVideo() { embyVideo = .init(); collapse(.embyVideo) }

    // MARK: - Search → Artists

    /// A search result's artist row was activated: open the Artists tab on that artist.
    func navigateToArtistFromSearch(id: String, name: String = "") {
        let artistName = name.isEmpty ? id.replacingOccurrences(of: "local-artist-", with: "") : name
        pendingScrollToArtistId = id
        pendingScrollToArtistName = artistName
        pendingScrollAttempts = 0
        pendingArtistLoadUnfiltered = true
        // Clear the artist caches to force a fresh fetch that bypasses folder/library
        // filters (so an artist found via unfiltered search is findable).
        plex.artists.removeAll()
        subsonic.artists.removeAll()
        jellyfin.artists.removeAll()
        emby.artists.removeAll()
        // Switch first so the page offset is computed under the Artists tab's own sort.
        browseMode = .artists
        if isLocalSource,
           let artistOffset = MediaLibraryStore.shared.artistOffset(named: artistName, sort: currentSort) {
            localArtistPageOffset = (artistOffset / localPageSize) * localPageSize
        }
        onChange?(.rowsReplaced)
        loadDataForCurrentMode()
    }

    /// After a load or rebuild: reveal the artist a search jump is looking for, giving up after
    /// three tries.
    func resolvePendingArtist() {
        guard let artistId = pendingScrollToArtistId else { return }
        pendingScrollAttempts += 1
        let index = pendingArtistIndex(artistId: artistId, name: pendingScrollToArtistName ?? "")
        guard index != nil || pendingScrollAttempts >= 3 else { return }
        pendingScrollToArtistId = nil
        pendingScrollToArtistName = nil
        pendingScrollAttempts = 0
        pendingArtistLoadUnfiltered = false
        if let index { onChange?(.reveal(index)) }
    }

    private func pendingArtistIndex(artistId: String, name: String) -> Int? {
        let titleMatch = !name.isEmpty ? displayItems.firstIndex { item in
            item.type.isArtist && item.title.caseInsensitiveCompare(name) == .orderedSame
        } : nil
        return titleMatch ?? displayItems.firstIndex { item in
            item.type.isArtist && item.id == artistId
        }
    }

    // MARK: - Letters and type-ahead

    /// The alphabet-index letter a title files under, ignoring a leading article as the sort does.
    static func sortLetter(for title: String) -> String {
        let sortTitle = LibraryTextSorter.normalized(title, ignoreLeadingArticles: true).uppercased()
        guard let firstChar = sortTitle.first else { return "#" }
        return firstChar.isLetter ? String(firstChar) : "#"
    }

    /// The letter a row files under; a Subsonic artist uses the server's index letter.
    static func effectiveSortLetter(for item: LibraryBrowserItem) -> String {
        if case .subsonicArtist(let artist) = item.type,
           let normalized = normalizedIndexLetter(artist.indexLetter) {
            return normalized
        }
        return sortLetter(for: item.title)
    }

    /// Normalizes a raw Subsonic `indexLetter` to a single uppercase letter, or nil if blank.
    static func normalizedIndexLetter(_ raw: String?) -> String? {
        guard let first = raw?.trimmingCharacters(in: .whitespaces).first else { return nil }
        return String(first).uppercased()
    }

    /// Whether type-ahead `query` (lowercased) picks this title: its start, its start without a
    /// leading article ("beat" → "The Beatles"), or its canonical form ("the at" → "Atlas Moth, The").
    static func titleMatchesTypeAhead(_ title: String, query: String) -> Bool {
        let lower = title.lowercased()
        if lower.hasPrefix(query) { return true }
        if LibraryTextSorter.normalized(title, ignoreLeadingArticles: true).lowercased().hasPrefix(query) { return true }
        for suffix in [", the", ", an", ", a"] where lower.hasSuffix(suffix) {
            let article = String(suffix.dropFirst(2))
            return (article + " " + lower.dropLast(suffix.count)).hasPrefix(query)
        }
        return false
    }

    /// The local Artists and Albums tabs page from the store: jump the page to `letter`.
    /// Returns nil on other tabs and sources, which scroll the loaded rows instead; otherwise
    /// whether the page moved (false when nothing files under `letter`).
    func showLocalPage(atLetter letter: String) -> Bool? {
        guard isLocalSource else { return nil }
        switch browseMode {
        case .artists:
            guard let offset = localArtistLetterOffsets[letter] else { return false }
            localArtistPageOffset = offset
            buildLocalArtistItems()
            return true
        case .albums:
            guard let offset = localAlbumLetterOffsets[letter] else { return false }
            localAlbumPageOffset = offset
            buildLocalAlbumItems()
            return true
        default:
            return nil
        }
    }

    // MARK: - Columns

    /// The column group a row's cells belong to; nil for a row drawn as a plain title line.
    func columnGroup(for item: LibraryBrowserItem) -> LibraryColumnVisibilityGroup? {
        switch item.type {
        case .track, .subsonicTrack, .localTrack, .jellyfinTrack, .embyTrack:
            return .track
        case .album, .subsonicAlbum, .localAlbum, .jellyfinAlbum, .embyAlbum:
            return .album
        case .artist, .subsonicArtist, .localArtist, .jellyfinArtist, .embyArtist:
            return item.indentLevel == 0 ? .artist : nil
        case .youtubeVideo:
            return .youtube
        default:
            return nil
        }
    }

    func isInternetRadioItem(_ item: LibraryBrowserItem) -> Bool {
        guard case .radio = currentSource, case .radioStation = item.type else { return false }
        return true
    }

    var hasInternetRadioColumns: Bool {
        guard case .radio = currentSource else { return false }
        return displayItems.contains(where: isInternetRadioItem)
    }

    /// YouTube channel uploads render through the resizable column path (title + time),
    /// gated on the "Channels" view actually containing video rows.
    var hasYouTubeColumns: Bool {
        guard radioSlotShowingChannels || isYouTubeChannelSearch else { return false }
        return displayItems.contains { if case .youtubeVideo = $0.type { return true }; return false }
    }

    func currentColumnGroup() -> LibraryColumnVisibilityGroup? {
        if hasYouTubeColumns { return .youtube }
        return LibraryColumnVisibility.headerGroup(displayItems.lazy.map { self.columnGroup(for: $0) })
    }

    /// Whether a row draws columns rather than a plain title line.
    func drawsColumns(_ item: LibraryBrowserItem) -> Bool {
        columnGroup(for: item) != nil || isInternetRadioItem(item)
    }

    /// The header's columns for the list's column group; radio has its own fixed set and no group.
    func headerColumns(for group: LibraryColumnVisibilityGroup?) -> [LibraryBrowserColumn] {
        if hasInternetRadioColumns { return LibraryBrowserColumn.internetRadioColumns }
        guard let group else { return [] }
        return LibraryColumnVisibility.visibleColumns(allColumns: LibraryBrowserColumn.all(for: group),
                                                      visibleIds: visibleColumnIds(for: group)) { $0.id }
    }

    func visibleColumnIds(for group: LibraryColumnVisibilityGroup) -> [String] {
        switch group {
        case .artist: return normalizedColumnIds(visibleArtistColumnIds, group: .artist)
        case .album: return normalizedColumnIds(visibleAlbumColumnIds, group: .album)
        case .track: return normalizedColumnIds(visibleTrackColumnIds, group: .track)
        // YouTube columns are fixed (not user-hideable); always the full set.
        case .youtube: return LibraryBrowserColumn.defaultYouTubeColumnIds
        }
    }

    func setVisibleColumnIds(_ ids: [String], for group: LibraryColumnVisibilityGroup) {
        switch group {
        case .artist: visibleArtistColumnIds = normalizedColumnIds(ids, group: .artist)
        case .album: visibleAlbumColumnIds = normalizedColumnIds(ids, group: .album)
        case .track: visibleTrackColumnIds = normalizedColumnIds(ids, group: .track)
        case .youtube: break
        }
    }

    private func normalizedColumnIds(_ ids: [String], group: LibraryColumnVisibilityGroup) -> [String] {
        LibraryColumnVisibility.normalizedIds(ids, allIds: LibraryBrowserColumn.all(for: group).map(\.id))
    }

    private func saveVisibleColumns() {
        UserDefaults.standard.set(visibleTrackColumnIds, forKey: keyPrefix + "BrowserVisibleTrackColumns")
        UserDefaults.standard.set(visibleAlbumColumnIds, forKey: keyPrefix + "BrowserVisibleAlbumColumns")
        UserDefaults.standard.set(visibleArtistColumnIds, forKey: keyPrefix + "BrowserVisibleArtistColumns")
    }

    private func loadVisibleColumns() {
        let defaults = UserDefaults.standard
        if let saved = defaults.stringArray(forKey: keyPrefix + "BrowserVisibleTrackColumns") {
            visibleTrackColumnIds = normalizedColumnIds(saved, group: .track)
        }
        if let saved = defaults.stringArray(forKey: keyPrefix + "BrowserVisibleAlbumColumns") {
            visibleAlbumColumnIds = normalizedColumnIds(saved, group: .album)
        }
        if let saved = defaults.stringArray(forKey: keyPrefix + "BrowserVisibleArtistColumns") {
            visibleArtistColumnIds = normalizedColumnIds(saved, group: .artist)
        }
    }

    // MARK: - Row text

    /// "1 album", "3 albums".
    func countLabel(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// A row's duration info, as the Time column shows it.
    func formatDuration(_ seconds: Int?) -> String? {
        seconds.map { LibraryBrowserItem.formatDuration(TimeInterval($0)) }
    }

    // MARK: - Teardown

    /// Cancel every in-flight load, so a detached `@MainActor` expand or load task does not pin
    /// the model (and its view) alive after a UI reload.
    func cancelAll() {
        invalidateActiveLoads()
        cancelLocalFolderBuild()
        localLibraryReloadWorkItem?.cancel(); localLibraryReloadWorkItem = nil
    }
}

extension LibraryBrowserItem.ItemType {
    var isArtist: Bool {
        switch self {
        case .artist, .localArtist, .subsonicArtist, .jellyfinArtist, .embyArtist: return true
        default: return false
        }
    }
}
