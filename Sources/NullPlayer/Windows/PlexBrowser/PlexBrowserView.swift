import AppKit
import AVFoundation
import NullPlayerCore
import SwiftUI

// =============================================================================
// PLEX BROWSER VIEW - Skinned Plex browser with playlist sprite support
// =============================================================================
// Follows the same pattern as PlaylistView for:
// - Coordinate transformation (skin top-down system)
// - Button hit testing and visual feedback
// - Scaling support for resizable windows
// =============================================================================

/// Plex browser view with skin-style skin support
class PlexBrowserView: NSView {
    
    // MARK: - Properties
    
    weak var controller: PlexBrowserWindowController?

    /// The browser's source, tab, rows and caches; this view draws them. Column visibility and
    /// the tab-slot choices are kept apart from the modern browser's, under "Classic" keys.
    let model = LibraryBrowserModel(keyPrefix: "Classic")

    /// Selected item indices
    private var selectedIndices: Set<Int> = []
    
    /// Scroll offset
    private var scrollOffset: CGFloat = 0

    /// Typeahead state for keyboard navigation in non-search mode
    private var typeAheadQuery: String = ""
    private var typeAheadTimer: Timer?
    
    /// Horizontal scroll offset for column headers
    private var horizontalScrollOffset: CGFloat = 0
    
    /// Classic library content metrics follow UI Size just like the modern/metal browser.
    /// The window itself is stretchable, so scale the content rather than deriving this from
    /// the current window dimensions (which would also enlarge text during a manual resize).
    private var contentScale: CGFloat {
        embeddedScale?() ?? WindowManager.shared.classicScaleMultiplier
    }

    private var itemHeight: CGFloat {
        18 * contentScale
    }

    /// Extra inset so top bar items don't sit against the window edges.
    private let toolbarItemHorizontalEdgePadding: CGFloat = 5

    /// Extra inset so tab labels don't sit against the window edges.
    private let tabItemHorizontalEdgePadding: CGFloat = 5

    /// Additional inset for right-edge controls/items only.
    private let rightEdgeItemPaddingBoost: CGFloat = 6
    
    /// Height of column headers
    private var columnHeaderHeight: CGFloat {
        18 * contentScale
    }

    private var bitmapTextScale: CGFloat {
        1.5 * contentScale
    }

    private func contentFont(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size * contentScale, weight: weight)
    }
    
    /// Stored column widths (persisted)
    private var columnWidths: [String: CGFloat] = [:] {
        didSet { saveColumnWidths() }
    }


    /// Column being resized (id) and resize state
    private var resizingColumnId: String?
    private var resizingColumnGroup: LibraryColumnVisibilityGroup?
    private var resizingColumnFromLeadingEdge = false
    private var resizeStartX: CGFloat = 0
    private var resizeStartWidth: CGFloat = 0
    


    /// Where the list sits, in skin coordinates (top-left origin), worked out in one place.
    /// Drawing, every hit test and every scroll range read it, so a click lands on the row drawn
    /// under it (PR #480: hit tests reserved the header on a different condition than drawing,
    /// and every click landed one row up).
    private struct ListLayout {
        /// Below the tab bar (and search bar), above the status bar, the window's full inner
        /// width. Loading, error and Cover Flow backgrounds fill it.
        let area: NSRect
        /// The column header band and the columns it shows, when the list has columns.
        let header: Header?
        /// Where rows are drawn: under the header, left of the scrollbar and alphabet index.
        let rows: NSRect
        /// The alphabet index, beside the header and the rows.
        let alphabet: NSRect

        struct Header {
            let rect: NSRect
            let columns: [LibraryBrowserColumn]
            /// The group the columns' widths are keyed by; nil for radio's fixed columns.
            let group: LibraryColumnVisibilityGroup?
        }
    }

    /// The bottom of the tab bar, or of the search bar in search mode.
    private var listTopY: CGFloat {
        Layout.titleBarHeight + Layout.serverBarHeight + Layout.tabBarHeight
            + (model.browseMode == .search ? Layout.searchBarHeight : 0)
    }

    private func listLayout() -> ListLayout {
        let size = originalWindowSize
        let area = NSRect(x: Layout.leftBorder, y: listTopY,
                          width: size.width - Layout.leftBorder - Layout.rightBorder,
                          height: size.height - listTopY - Layout.statusBarHeight)
        let group = model.currentColumnGroup()
        let columns = model.headerColumns(for: group)
        let headerHeight = columns.isEmpty ? 0 : columnHeaderHeight
        let width = area.width - Layout.scrollbarWidth - Layout.alphabetWidth
        return ListLayout(
            area: area,
            header: columns.isEmpty ? nil : .init(rect: NSRect(x: area.minX, y: area.minY, width: width, height: headerHeight),
                                                  columns: columns, group: group),
            rows: NSRect(x: area.minX, y: area.minY + headerHeight, width: width, height: area.height - headerHeight),
            alphabet: NSRect(x: area.minX + width, y: area.minY, width: Layout.alphabetWidth, height: area.height)
        )
    }

    /// The columns a row draws and the group their widths are keyed by (nil = simple list rendering).
    /// Artist, album and track rows all draw the list's one header, Finder-style; radio and
    /// YouTube rows draw their own fixed columns.
    private func rowColumns(for item: LibraryBrowserItem, header: ListLayout.Header?) -> (columns: [LibraryBrowserColumn], group: LibraryColumnVisibilityGroup?)? {
        switch model.columnGroup(for: item) {
        case .youtube?: return (LibraryBrowserColumn.youtubeColumns, .youtube)
        case _?: return header.map { ($0.columns, $0.group) }
        case nil: return model.isInternetRadioItem(item) ? (LibraryBrowserColumn.internetRadioColumns, nil) : nil
        }
    }
    
    /// Get width for a column (uses stored width or default)
    private func columnWidthKey(_ columnId: String, group: LibraryColumnVisibilityGroup) -> String {
        "\(group.rawValue):\(columnId)"
    }

    private func storedColumnWidth(for column: LibraryBrowserColumn, group: LibraryColumnVisibilityGroup?) -> CGFloat? {
        guard let group else { return columnWidths[column.id] }
        return columnWidths[columnWidthKey(column.id, group: group)]
    }

    private func setColumnWidth(_ width: CGFloat, for columnId: String, group: LibraryColumnVisibilityGroup) {
        columnWidths[columnWidthKey(columnId, group: group)] = width
    }

    private func widthForColumn(
        _ column: LibraryBrowserColumn,
        availableWidth: CGFloat,
        columns: [LibraryBrowserColumn],
        group: LibraryColumnVisibilityGroup?
    ) -> CGFloat {
        if column.id == "title" {
            // Title column gets remaining space
            let fixedWidth = columns.filter { $0.id != "title" }.reduce(0) { 
                $0 + (storedColumnWidth(for: $1, group: group) ?? $1.minWidth)
            }
            return max(column.minWidth, availableWidth - fixedWidth - 8)
        }
        return storedColumnWidth(for: column, group: group) ?? column.minWidth
    }
    
    /// Calculate total width needed for all columns
    private func totalColumnsWidth(columns: [LibraryBrowserColumn], group: LibraryColumnVisibilityGroup?) -> CGFloat {
        var total: CGFloat = 8  // Initial padding
        for column in columns {
            if column.id == "title" {
                total += column.minWidth  // Title uses minWidth for total calculation
            } else {
                total += storedColumnWidth(for: column, group: group) ?? column.minWidth
            }
        }
        return total
    }

    private func clampHorizontalScrollOffset() {
        guard let header = listLayout().header else { horizontalScrollOffset = 0; return }
        let maxOffset = max(0, totalColumnsWidth(columns: header.columns, group: header.group) - header.rect.width)
        horizontalScrollOffset = max(0, min(horizontalScrollOffset, maxOffset))
    }
    
    /// Save column widths to UserDefaults
    private func saveColumnWidths() {
        UserDefaults.standard.set(columnWidths, forKey: "BrowserColumnWidths")
    }
    
    /// Load column widths from UserDefaults
    private func loadColumnWidths() {
        if let saved = UserDefaults.standard.dictionary(forKey: "BrowserColumnWidths") as? [String: CGFloat] {
            columnWidths = migrateColumnWidths(saved)
        }
    }

    private func migrateColumnWidths(_ saved: [String: CGFloat]) -> [String: CGFloat] {
        var migrated: [String: CGFloat] = [:]
        for (key, width) in saved {
            if key.contains(":") {
                migrated[key] = width
                continue
            }
            for group in LibraryColumnVisibilityGroup.allCases where LibraryBrowserColumn.all(for: group).contains(where: { $0.id == key }) {
                migrated[columnWidthKey(key, group: group)] = width
            }
        }
        return migrated
    }

    


    

    
    


    private var radioPlayTask: Task<Void, Never>?

    /// A video row's Audio ▸ / Video ▸ menu and its downloads, which drive a per-row spinner.
    private lazy var youtubeVideoActions: YouTubeVideoActions = {
        let actions = YouTubeVideoActions(search: model.youtubeSearch)
        actions.onFetchesChanged = { [weak self] in
            guard let self else { return }
            if self.youtubeVideoActions.hasFetchesInFlight { self.startLoadingAnimation() } else { self.stopLoadingAnimation() }
            self.needsDisplay = true
        }
        actions.onFilesChanged = { [weak self] in self?.model.rebuildCurrentModeItems() }
        return actions
    }()

    private let historyAgent = PlayHistoryAgent()
    private var historyHostingView: NSHostingView<StatsContentView>?

    private struct RadioFolderMembershipAction {
        let station: RadioStation
        let folderID: UUID
    }
    private struct RadioSmartGenreAction {
        let station: RadioStation
        let genre: String?
    }
    private struct RadioSmartRegionAction {
        let station: RadioStation
        let region: String?
    }
    private struct RadioFolderRenameAction { let folderID: UUID }
    private struct RadioFolderDeleteAction { let folderID: UUID }
    private struct RadioFolderStationAction { let station: RadioStation }
    
    /// Strong reference to prevent deallocation while dialog is open
    private var activeRadioStationSheet: AddRadioStationSheet?
    private var activeYouTubeChannelSheet: AddYouTubeChannelSheet?
    
    
    
    /// Loading animation
    private var loadingAnimationTimer: Timer?
    private var loadingAnimationFrame: Int = 0
    /// Local library scan animation (server bar spinner)
    private var isLibraryScanning = false
    
    /// Server name scrolling animation
    private var serverNameScrollOffset: CGFloat = 0
    private var libraryNameScrollOffset: CGFloat = 0
    private var serverScrollTimer: Timer?
    private var lastServerName: String = ""
    private var lastLibraryName: String = ""
    /// How far the server and library names travel before their scroll wraps, written by
    /// drawServerBar each draw for the scroll tick; zero while a name fits its field or the bar
    /// shows no server.
    private var serverNameCycleWidth: CGFloat = 0
    private var libraryNameCycleWidth: CGFloat = 0

    /// Cached skin renderer — avoids recreating (and discarding its whiteTextImage cache) every frame
    private var cachedRenderer: SkinRenderer?
    private var cachedRendererSkinPath: String?

    /// Highlight state for drag-mode visual feedback
    private var isHighlighted = false
    
    /// List, Flow or Tiles, and the Flow / Tiles view standing in for the list (see LibraryArtLens).
    /// Classic's taller, freely stretchable window keeps the Flow label under the centred cover.
    private lazy var artLens = LibraryArtLens<LibraryBrowserItem>(
        container: self, flowLabelPlacement: .belowCenteredCover, host: .init(
            rows: { [unowned self] in model.displayItems },
            isSearch: { [unowned self] in model.browseMode == .search },
            selectedIndex: { [unowned self] in selectedIndices.min() },
            isBlocked: { [unowned self] in
                model.isLoading || model.errorMessage != nil || (model.currentSource.isPlex && !PlexManager.shared.isLinked)
            },
            style: { [unowned self] in
                let colors = currentPlaylistColors()
                return LibraryArtStyle(
                    titleColor: colors.normalText,
                    subtitleColor: colors.normalText.withAlphaComponent(0.6),
                    placeholderFill: colors.normalBackground.blended(withFraction: 0.15, of: .white) ?? colors.normalBackground,
                    placeholderTextColor: colors.normalText.withAlphaComponent(0.6)
                )
            },
            item: { [unowned self] in artItem(for: $0) },
            isExpanded: { [unowned self] in model.isExpanded($0) },
            toggleExpand: { [unowned self] in model.toggleExpand($0) },
            play: { [unowned self] in handleDoubleClick(on: $0) },
            menu: { [unowned self] row, event in
                // As a right-click on the row in the list: select it, then its menu.
                if let index = model.displayItems.firstIndex(where: { $0.id == row.id }) { selectedIndices = [index] }
                showContextMenu(for: row, at: event)
            },
            albumInfo: { [unowned self] in playable(for: $0).flatMap(LibraryAlbumInfo.init) },
            loadNextPage: { [unowned self] in
                if case .local = model.currentSource { model.appendNextLocalPage() }
            }
        ))
    /// The List / Flow / Tiles buttons in the server bar, as last drawn (skin coordinates).
    private var viewModeButtonRects: [(mode: LibraryViewMode, rect: NSRect)] = []

    private var refreshButtonRect: NSRect = .zero
    private var sourceButtonRect: NSRect = .zero
    private var libraryButtonRect: NSRect = .zero
    private var addButtonRect: NSRect = .zero
    private var tabButtonRects: [NSRect] = []
    private var sortButtonRect: NSRect = .zero
    
    /// Button being pressed (for visual feedback)
    private var pressedButton: SkinRenderer.PlexBrowserButtonType?
    
    /// Active tags panel (strong reference to prevent premature deallocation)
    private var activeTagsPanel: TagsPanel?
    private var activeEditTagsPanel: EditTagsPanel?
    private var activeEditAlbumTagsPanel: EditAlbumTagsPanel?
    private var activeEditVideoTagsPanel: EditVideoTagsPanel?
    
    /// Window dragging state
    private var isDraggingWindow = false
    private var windowDragStartPoint: NSPoint = .zero
    /// Embedded in a `.wal` holder there is no title bar of ours, so background the browser does not
    /// consume — the blank area below the last row — moves the skin's window instead (B60).
    private var embeddedWindowDrag = WinampModernHostedWindowDrag()
    
    /// Alphabet index for quick navigation
    private let alphabetLetters = ["#"] + (65...90).map { String(UnicodeScalar($0)) } // # A-Z
    
    // MARK: - Artwork Background State
    
    /// Current artwork image for background display
    private var currentArtwork: NSImage?
    
    /// Track ID for the currently displayed artwork (to avoid reloading)
    private var artworkTrackId: UUID?
    
    /// Async task for loading artwork (can be cancelled)
    private var artworkLoadTask: Task<Void, Never>?
    
    /// Static image cache shared across all browser instances
    private static let artworkCache = NSCache<NSString, NSImage>()
    private let rowThumbnails = LibraryRowThumbnailTracker()
    
    // MARK: - Layout Constants (reference to SkinElements)
    
    /// Per-instance layout metrics.
    ///
    /// The classic browser is a skinned window: a title bar, side borders, and a bottom border it
    /// draws itself. Embedded inside a `.wal` skin, the frame belongs to the skin and this view owns
    /// only the client area, so those collapse to zero and everything measured from them moves up.
    /// Every geometry and hit-test site in this file reads `Layout`, so there is one place to change.
    struct LayoutMetrics {
        var titleBarHeight: CGFloat
        var tabBarHeight: CGFloat
        var serverBarHeight: CGFloat
        var searchBarHeight: CGFloat
        var statusBarHeight: CGFloat
        var scrollbarWidth: CGFloat
        var alphabetWidth: CGFloat
        var leftBorder: CGFloat
        var rightBorder: CGFloat
        var padding: CGFloat

        static let classic = LayoutMetrics(
            titleBarHeight: SkinElements.PlexBrowser.Layout.titleBarHeight,
            tabBarHeight: SkinElements.PlexBrowser.Layout.tabBarHeight,
            serverBarHeight: SkinElements.PlexBrowser.Layout.serverBarHeight,
            searchBarHeight: SkinElements.PlexBrowser.Layout.searchBarHeight,
            statusBarHeight: SkinElements.PlexBrowser.Layout.statusBarHeight,
            scrollbarWidth: SkinElements.PlexBrowser.Layout.scrollbarWidth,
            alphabetWidth: SkinElements.PlexBrowser.Layout.alphabetWidth,
            leftBorder: SkinElements.PlexBrowser.Layout.leftBorder,
            rightBorder: SkinElements.PlexBrowser.Layout.rightBorder,
            padding: SkinElements.PlexBrowser.Layout.padding)

        /// No window chrome of our own: the `.wal` frame around us already drew it.
        static let embedded: LayoutMetrics = {
            var metrics = classic
            metrics.titleBarHeight = 0
            metrics.leftBorder = 0
            metrics.rightBorder = 0
            metrics.statusBarHeight = 0
            return metrics
        }()
    }

    /// True when this browser is hosted inside a `.wal` skin's component holder rather than in its
    /// own classic window (Phase 13.8). Set once, at construction.
    private(set) var isEmbeddedInSkin = false

    var Layout: LayoutMetrics {
        if isEmbeddedInSkin { return .embedded }
        guard let metrics = hostedFrame?.metrics else {
            // A `.wmz` or `.wal` session draws the unskinned library without its title bar: the top edge is
            // a border as thin as the status bar (`SkinnedSurfaceChrome.hidesPaletteTitleBar`).
            guard SkinnedSurfaceChrome.hidesPaletteTitleBar else { return .classic }
            var titleless = LayoutMetrics.classic
            titleless.titleBarHeight = SkinnedSurfaceChrome.glossBorder
            titleless.leftBorder = SkinnedSurfaceChrome.glossBorder
            titleless.rightBorder = SkinnedSurfaceChrome.glossBorder
            titleless.statusBarHeight = SkinnedSurfaceChrome.glossBorder
            return titleless
        }
        // The borrowed frame's own client hole replaces the four chrome numbers and nothing else:
        // the tab, server, search and status *bars* are this window's own furniture and keep their
        // heights, so only where the window's edges are moves.
        var borrowed = LayoutMetrics.classic
        borrowed.titleBarHeight = metrics.titleHeight
        borrowed.leftBorder = metrics.leftBorder
        borrowed.rightBorder = metrics.rightBorder
        borrowed.statusBarHeight = max(metrics.bottomBorder, LayoutMetrics.classic.statusBarHeight)
        return borrowed
    }

    /// The window frame the hosting skin lends this browser, when it lends one — a `.wmz` skin that
    /// draws its own panels as an eight-piece ring (`WMPHostedFrameTemplate`). Never for an embedded
    /// browser: a `.wal` holder has already drawn the chrome around it.
    var hostedFrame: SkinnedSurfaceFrameArtwork? {
        guard !isEmbeddedInSkin else { return nil }
        return WindowManager.shared.hostedSurfaceFrameArtwork(for: bounds.size)
    }

    // MARK: - Winamp Modern styling (Phase 16)

    /// The `.wal` skin's look, pushed in by the embedding holder on creation and on every colour-theme
    /// switch. Nil for a browser in a classic window, which resolves its own (see `winampModernStyle`).
    private var embeddedWinampModernStyle: WinampModernSurfaceStyle?

    /// Resolved style for a browser in a window of its own, and whether it has been resolved yet.
    ///
    /// Cached because `drawScaledSkinText` asks for it once per string — ~77 times a frame — and
    /// deriving a style converts seven colours through a colour space. The palette only changes on a
    /// colour-theme switch, which invalidates this through `hostedSurfaceStyleDidChange`.
    private var cachedWindowWinampModernStyle: WinampModernSurfaceStyle?
    private var hasResolvedWindowWinampModernStyle = false

    /// How this browser should be painted, or nil for the classic look.
    ///
    /// Embedded, the host pushes the style; in a window of its own the browser is only ever a
    /// `winampModern` *fallback* surface, so it asks `WindowManager` — which answers nil in every
    /// other mode, leaving the classic drawing exactly as it was.
    var winampModernStyle: WinampModernSurfaceStyle? {
        if isEmbeddedInSkin { return embeddedWinampModernStyle }
        if !hasResolvedWindowWinampModernStyle {
            cachedWindowWinampModernStyle = WindowManager.shared.hostedSurfaceStyle
            hasResolvedWindowWinampModernStyle = true
        }
        return cachedWindowWinampModernStyle
    }

    /// Called by the `.wal` holder that hosts this browser.
    func applyWinampModernStyle(_ style: WinampModernSurfaceStyle) {
        guard embeddedWinampModernStyle != style else { return }
        embeddedWinampModernStyle = style
        refreshHistoryHostingColors()
        artLens.restyle()
        needsDisplay = true
    }

    private func tabRowNaturalWidth(textScale: CGFloat) -> CGFloat {
        let style = winampModernStyle
        var labels = LibraryBrowseMode.tabs.map { $0.title }
        labels.append("Channels")
        labels.append("Folders")
        let maxLabelWidth = labels.map { ClassicLibraryTab.textWidth($0, scale: textScale, style: style) }.max() ?? 0
        let sortWidth = ClassicLibraryTab.textWidth("Sort", scale: textScale, style: style) + 8
        let perTab = maxLabelWidth + 12  // breathing room so labels don't touch
        let tabsWidth = perTab * CGFloat(LibraryBrowseMode.tabs.count)
        let insets = tabItemHorizontalEdgePadding + (tabItemHorizontalEdgePadding + rightEdgeItemPaddingBoost)
        return tabsWidth + sortWidth + insets
    }

    /// A source-bar name with the item count appended: "FLAC_LIB (988 items)".
    private func withItemCount(_ name: String) -> String {
        let count: Int
        switch model.currentSource {
        case .local:
            if model.browseMode == .artists {
                count = model.localArtistTotal > 0 ? model.localArtistTotal : model.displayItems.count
            } else if model.browseMode == .albums {
                count = model.localAlbumTotal > 0 ? model.localAlbumTotal : model.displayItems.count
            } else {
                count = model.displayItems.count
            }
        case .plex:
            switch PlexManager.shared.currentLibrary?.type {
            case "artist": count = model.plex.artists.count
            case "album":  count = model.plex.albums.count
            case "movie":  count = model.plex.movies.count
            case "show":   count = model.plex.shows.count
            default:       count = model.displayItems.count
            }
        case .radio:
            return "\(name) (\(model.displayItems.count) stations)"
        case .subsonic, .jellyfin, .emby, .youtube:
            count = model.displayItems.count
        }
        return "\(name) (\(count) items)"
    }

    /// What the source bar shows after "Source:".
    private enum ServerBarContent {
        /// Local Files, Internet Radio or YouTube: the name with its count, then +ADD.
        case builtIn(name: String)
        /// A configured server: its name in a field `maxChars` wide, then its library.
        case server(name: String, maxChars: Int, library: String)
        /// A server source with nothing configured: a centred prompt, and no right-side buttons.
        case unconfigured(prompt: String)
    }

    private var serverBarContent: ServerBarContent {
        switch model.currentSource {
        case .local:
            return .builtIn(name: "Local Files")
        case .radio:
            return .builtIn(name: "Internet Radio")
        case .youtube:
            return .builtIn(name: "YouTube")
        case .plex(let serverId):
            let manager = PlexManager.shared
            let server = manager.servers.first(where: { $0.id == serverId })
            guard server != nil || manager.isLinked else {
                return .unconfigured(prompt: "Click to link your Plex account")
            }
            return .server(name: server?.name ?? "Select Server", maxChars: 12,
                           library: manager.currentLibrary?.title ?? "Select")
        case .subsonic(let serverId):
            let manager = SubsonicManager.shared
            guard let server = manager.servers.first(where: { $0.id == serverId }) else {
                return .unconfigured(prompt: "Click to add a Subsonic server")
            }
            return .server(name: server.name, maxChars: 20, library: manager.currentMusicFolder?.name ?? "All")
        case .jellyfin(let serverId):
            guard let server = JellyfinManager.shared.servers.first(where: { $0.id == serverId }) else {
                return .unconfigured(prompt: "Click to add a Jellyfin server")
            }
            return .server(name: server.name, maxChars: 20, library: jellyfinCurrentLibraryName)
        case .emby(let serverId):
            guard let server = EmbyManager.shared.servers.first(where: { $0.id == serverId }) else {
                return .unconfigured(prompt: "Click to add an Emby server")
            }
            return .server(name: server.name, maxChars: 20, library: embyCurrentLibraryName)
        }
    }

    /// The library field's narrowest width, in characters; it grows into the free space before the
    /// right-side buttons.
    private static let minLibraryFieldChars: CGFloat = 10

    private func serverBarNaturalWidth(textScale: CGFloat) -> CGFloat {
        let charWidth = SkinElements.TextFont.charWidth * textScale
        let style = winampModernStyle
        let textWidth: (String) -> CGFloat = { ClassicLibraryTab.textWidth($0, scale: textScale, style: style) }
        let leadingInset = 4 + toolbarItemHorizontalEdgePadding
        let trailingInset = 8 + toolbarItemHorizontalEdgePadding + rightEdgeItemPaddingBoost
        let prefixWidth = textWidth("Source: ")
        let minimumGap: CGFloat = 12

        var rightWidth = trailingInset + textWidth("F5")
        if artLens.hasItems {
            rightWidth += 12 + viewModeButtonsWidth(textScale: textScale, chromeScale: 1)
        }

        let leftWidth: CGFloat
        switch serverBarContent {
        case .builtIn(let name):
            leftWidth = leadingInset + prefixWidth + textWidth(withItemCount(name)) + 28 + textWidth("+ADD")
        case .server(_, let maxChars, _):
            leftWidth = leadingInset + prefixWidth + CGFloat(maxChars) * charWidth + 16 +
                textWidth("Lib:") + 4 + Self.minLibraryFieldChars * charWidth
        case .unconfigured(let prompt):
            leftWidth = leadingInset + prefixWidth
            return max(leftWidth + minimumGap, textWidth(prompt) + 2 * leftWidth + 2 * minimumGap)
        }
        return leftWidth + minimumGap + rightWidth
    }

    private var topChromeScale: CGFloat {
        let referenceWidth = max(tabRowNaturalWidth(textScale: bitmapTextScale),
                                 serverBarNaturalWidth(textScale: bitmapTextScale))
        let availableWidth = max(0, originalWindowSize.width - Layout.leftBorder - Layout.rightBorder)
        guard referenceWidth > 0 else { return 1 }
        return min(1, max(0.66, availableWidth / referenceWidth))
    }

    /// Smallest content width that keeps every full-size compact tab label inside its slot.
    var minimumCompactContentWidth: CGFloat {
        ceil(tabRowNaturalWidth(textScale: bitmapTextScale) +
             Layout.leftBorder + Layout.rightBorder)
    }

    /// The label shown in each tab slot (some slots are dynamic), in `tabs` order.
    private func currentTabLabels() -> [String] {
        LibraryBrowseMode.tabs.map { mode in
            // plists slot shows "Folders" when toggled on a local source.
            if mode == .plists, model.localPlistsSlotShowsFolders, case .local = model.currentSource {
                return "Folders"
            }
            // radio slot shows "Channels" when the YouTube source is displaying channels.
            if mode == .radio, model.radioSlotShowingChannels {
                return "Channels"
            }
            return mode.title
        }
    }

    /// Per-tab widths across the tab area (which excludes the Sort indicator). Content-aware:
    /// each tab is sized to its own label plus padding, then leftover space is shared equally
    /// so every tab gets breathing room and short labels (e.g. "TV", "Data") don't hog width.
    /// Shared by `drawTabBar` and `hitTestTabBar` so they stay in sync.
    private func tabBarWidths(tabsWidth: CGFloat, textScale: CGFloat,
                              horizontalScale: CGFloat) -> [CGFloat] {
        let style = winampModernStyle
        let boxPadding = 18 * horizontalScale
        let natural = currentTabLabels().map { ClassicLibraryTab.textWidth($0, scale: textScale, style: style) + boxPadding }
        let naturalSum = natural.reduce(0, +)
        if naturalSum > tabsWidth {
            let scale = tabsWidth / naturalSum
            return natural.map { $0 * scale }
        }
        let extra = (tabsWidth - naturalSum) / CGFloat(natural.count)
        return natural.map { $0 + extra }
    }

    // MARK: - Initialization
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    /// Build the browser as a `.wal` skin's embedded library surface (Phase 13.8).
    ///
    /// Everything the classic window supplies has to be injected instead, because there is no
    /// `PlexBrowserWindowController` here: the palette and the content scale come from the skin, and
    /// the link sheet is presented by whoever owns the hosting window. The browsing behaviour —
    /// servers, tabs, search, CoverFlow, history — is the same code either way.
    convenience init(embeddedFrame frame: NSRect,
                     skinScale: @escaping () -> CGFloat,
                     presentLinkSheet: @escaping () -> Void) {
        self.init(frame: frame)
        isEmbeddedInSkin = true
        embeddedScale = skinScale
        embeddedLinkSheet = presentLinkSheet
    }

    /// UI Size for an embedded browser: the `.wal` window's own skin scale, not the classic
    /// multiplier. A `.wal` window is not run through classic scaling, so relying on the two matching
    /// would make the embedded text the wrong size at every level but 100%.
    private var embeddedScale: (() -> CGFloat)?
    /// Presented instead of `controller?.showLinkSheet()` when embedded.
    private var embeddedLinkSheet: (() -> Void)?

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }
    
    private func setupView() {
        wantsLayer = true
        
        loadColumnWidths()

        // A `.wal` colour-theme switch recolours this browser (Phase 16). The embedded case is told
        // directly through `applyWinampModernStyle`; a fallback window has no such handle.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hostedSurfaceStyleDidChange),
            name: .hostedSurfaceStyleDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(youtubeUploadsDidChange),
            name: YouTubeChannelUploads.didChangeNotification,
            object: nil
        )
        // Redraw when a YouTube row thumbnail / avatar finishes loading
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(libraryRowThumbnailDidLoad),
            name: LibraryRowThumbnails.didLoadNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playHistoryDidChange),
            name: MediaLibraryStore.playHistoryDidChangeNotification,
            object: nil
        )
        
        // Observe track changes for artwork background
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(trackDidChange),
            name: .audioTrackDidChange,
            object: nil
        )
        
        // Register for drag and drop (local files)
        registerForDraggedTypes([.fileURL])
        
        // Initial data load
        model.onChange = { [weak self] in self?.modelDidChange($0) }
        model.reloadData()
        
        // Start server name scroll animation
        startServerNameScroll()
        
        // Load artwork for currently playing track (if any)
        if WindowManager.shared.showBrowserArtworkBackground {
            loadArtwork(for: WindowManager.shared.audioEngine.currentTrack)
        }
        
        // Set up accessibility identifiers for UI testing
        setupAccessibility()
        updateHistoryHostingVisibility()
        
        // Observe window visibility changes to pause/resume the server-name scroll
        NotificationCenter.default.addObserver(self, selector: #selector(plexWindowDidMiniaturize),
                                               name: NSWindow.didMiniaturizeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(plexWindowDidDeminiaturize),
                                               name: NSWindow.didDeminiaturizeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(plexWindowDidChangeOcclusionState),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(libraryScanProgressChanged),
                                               name: MediaLibrary.scanProgressNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(connectedWindowHighlightDidChange(_:)),
                                               name: .connectedWindowHighlightDidChange, object: nil)
    }
    
    // MARK: - Accessibility
    
    /// Set up accessibility identifiers for UI testing
    private func setupAccessibility() {
        setAccessibilityIdentifier("plexBrowserView")
        setAccessibilityRole(.group)
        setAccessibilityLabel("Plex Browser")
    }
    
    /// Stop timers when Plex browser window is minimized to save CPU
    @objc private func plexWindowDidMiniaturize(_ notification: Notification) {
        guard notification.object as? NSWindow == window else { return }
        // Stop timers when minimized to save CPU
        stopServerNameScroll()
    }
    
    /// Restart timers when Plex browser window is restored from minimized state
    @objc private func plexWindowDidDeminiaturize(_ notification: Notification) {
        guard notification.object as? NSWindow == window else { return }
        // Restart timers when restored
        startServerNameScroll()
    }
    
    /// Handle window occlusion state changes to pause/resume timers for CPU efficiency
    @objc private func plexWindowDidChangeOcclusionState(_ notification: Notification) {
        guard notification.object as? NSWindow == window else { return }
        if window?.occlusionState.contains(.visible) == true {
            // Window became visible - restart timers
            startServerNameScroll()
        } else {
            // Window became occluded - stop timers to save CPU
            stopServerNameScroll()
        }
    }
    
    /// The model's rows, loading state, source or tab changed.
    private func modelDidChange(_ change: LibraryBrowserModel.Change) {
        switch change {
        case .rows:
            artLens.rowsDidChange()
            needsDisplay = true
        case .loading:
            artLens.updateVisibility()
            if model.isLoading { startLoadingAnimation() } else { stopLoadingAnimation() }
            needsDisplay = true
        case .rowsReplaced:
            selectedIndices.removeAll()
            scrollOffset = 0
            if model.browseMode.isHistoryMode {
                historyAgent.scheduleRefresh()
                updateHistoryHostingVisibility()
            }
        case .rebuilt:
            horizontalScrollOffset = 0
        case .loaded:
            // With nothing playing, the artwork background shows the browsed library's art.
            if model.isLocalSource { loadLocalBrowseArtwork() }
        case .reveal(let index):
            selectedIndices = [index]
            ensureVisible(index: index)
            needsDisplay = true
        case .source:
            artLens.resetNavigation()
            selectedIndices.removeAll()
            scrollOffset = 0
            startServerNameScroll()
        case .browseMode:
            // A new tab opens Flow or Tiles at its root.
            artLens.resetNavigation()
            if model.browseMode.isHistoryMode {
                historyAgent.scheduleRefresh()
            }
            updateHistoryHostingVisibility()
            needsDisplay = true
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stopLoadingAnimation()
        stopServerNameScroll()
    }

    /// Synchronously cancel every in-flight task, work item, and timer this view and its model
    /// own so they can be deallocated immediately when the controller is torn down for a UI
    /// reload — rather than being pinned alive (and mutating dead UI state) by a detached
    /// `@MainActor` expand/load task or a self-retaining repeating timer. `deinit` is deferred by
    /// AppKit's autorelease pool, so `WindowManager.teardownModeDependentWindows()` calls this
    /// *before* closing the window.
    func prepareForUITeardown() {
        model.cancelAll()
        artworkLoadTask?.cancel(); artworkLoadTask = nil
        radioPlayTask?.cancel(); radioPlayTask = nil
        youtubeVideoActions.cancel()

        // Timers (timers with a target/captured self can also pin the view alive).
        typeAheadTimer?.invalidate(); typeAheadTimer = nil
        stopLoadingAnimation()
        stopServerNameScroll()
        artLens.teardown()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        startServerNameScroll()
        updateHistoryHostingFrame()
    }

    override func layout() {
        super.layout()
        updateHistoryHostingFrame()
    }

    // MARK: - Scaling Support

    /// Get the original window size for drawing and hit testing
    /// Draw the classic window frame — title bar, borders, resize corner. An embedded browser sits
    /// inside the `.wal` skin's own frame, which has already drawn all of that, so this is skipped
    /// and the client area fills the holder.
    private func drawWindowChromeIfNeeded(renderer: SkinRenderer, context: CGContext, bounds: NSRect,
                                          isActive: Bool, scrollPosition: CGFloat) {
        guard !isEmbeddedInSkin else { return }
        if let style = winampModernStyle {
            drawWinampModernChrome(style: style, context: context, bounds: bounds, isActive: isActive)
            return
        }
        renderer.drawPlexBrowserWindow(in: context, bounds: bounds, isActive: isActive,
                                       pressedButton: pressedButton, scrollPosition: scrollPosition,
                                       controlScale: WindowManager.shared.playlistChromeScale)
    }

    /// Chrome for a palette-themed browser, including WMP despite the historical function name.
    /// Palette fallback uses classic layout metrics. WMP borrowed artwork instead uses the donor's
    /// resolved content geometry for layout/hit testing, fills only that hole, and paints the frame
    /// according to `paintsOverContent`, without adding a title or close glyph.
    private func drawWinampModernChrome(style: WinampModernSurfaceStyle, context: CGContext,
                                        bounds: NSRect, isActive: Bool) {
        let titleHeight = Layout.titleBarHeight
        let leftBorder = Layout.leftBorder
        let rightBorder = Layout.rightBorder
        let statusHeight = Layout.statusBarHeight

        // The hosting skin's own window ring, where it lends one. The client hole is filled first
        // and the artwork drawn over it — these rings are full of keyed-out and rounded corners, so
        // a slab painted over the whole window would square off everything the skin cut away.
        if let artwork = hostedFrame {
            let content = artwork.scaled(to: bounds.size).contentRect
            context.setFillColor(style.background.cgColor)
            context.fill(content)
            context.saveGState()
            // Solid interior fill has already been erased when paintsOverContent is true, so
            // preserve the whole bezel, including pixels intruding into the client rectangle.
            // Otherwise cut the rectangle to keep pictorial interiors (e.g. Scooby Doo) from
            // painting wallpaper over the browser's content.
            if !content.isEmpty, !artwork.paintsOverContent {
                context.beginPath()
                context.addRect(bounds)
                context.addRect(content)
                context.clip(using: .evenOdd)
            }
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = artwork.wasScaledToFit ? .high : .none
            context.draw(artwork.image, in: CGRect(origin: .zero, size: bounds.size))
            context.restoreGState()
            SkinnedSurfaceChrome.traceBorrowedChrome(bounds: bounds, artwork: artwork,
                                                     captionHeight: max(0, content.minY),
                                                     closeWidth: 20)
            return
        }

        // Titleless in WMP: the gloss frame, and the close is the corner hit area alone.
        if closesFromCorner {
            SkinnedSurfaceChrome.drawGlossFrame(in: context, bounds: bounds, style: style,
                                                isActive: isActive, fillGround: true)
            return
        }

        context.setFillColor(style.background.cgColor)
        context.fill(bounds)

        // Borders: one fill for the whole frame, then the content area punched back out of it, so
        // there are no seams where four separate strips would meet.
        context.setFillColor(style.barBackground.cgColor)
        context.fill(NSRect(x: 0, y: 0, width: bounds.width, height: titleHeight))
        context.fill(NSRect(x: 0, y: titleHeight, width: leftBorder, height: bounds.height - titleHeight))
        context.fill(NSRect(x: bounds.width - rightBorder, y: titleHeight,
                            width: rightBorder, height: bounds.height - titleHeight))
        context.fill(NSRect(x: 0, y: bounds.height - statusHeight, width: bounds.width, height: statusHeight))

        // A hairline where the chrome meets the content, and one around the window.
        context.setStrokeColor(style.border.cgColor)
        context.setLineWidth(1)
        context.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))
        context.setStrokeColor(style.divider.cgColor)
        context.stroke(NSRect(x: leftBorder - 0.5, y: titleHeight - 0.5,
                              width: bounds.width - leftBorder - rightBorder + 1,
                              height: bounds.height - titleHeight - statusHeight + 1))

        // Guarded against the bar it lands on — the title strip is `barBackground` in both states
        // (B48).
        let titleColor = isActive ? style.legibleText(style.currentText, on: style.barBackground)
                                  : style.legibleDimText(on: style.barBackground)
        let titleScale = WindowManager.shared.playlistChromeScale
        let title = "LIBRARY"
        let titleWidth = WinampModernSurfaceStyle.measuredWidth(title, scale: titleScale * 1.6)
        WinampModernSurfaceStyle.drawText(
            title,
            at: NSPoint(x: (bounds.width - titleWidth) / 2,
                        y: (titleHeight - WinampModernSurfaceStyle.classicCharHeight * titleScale * 1.6) / 2),
            scale: titleScale * 1.6, color: titleColor, in: context)

        // The close button, in the box `hitTestCloseButton` owns.
        let closeHit = NSRect(x: bounds.width - 20, y: 0, width: 20, height: 14)
        if pressedButton == .close {
            context.setFillColor(style.pressedFill.cgColor)
            context.fill(closeHit)
        }
        let glyph = closeHit.insetBy(dx: 7, dy: 4)
        context.setStrokeColor(titleColor.cgColor)
        context.setLineWidth(1)
        context.beginPath()
        context.move(to: CGPoint(x: glyph.minX, y: glyph.minY))
        context.addLine(to: CGPoint(x: glyph.maxX, y: glyph.maxY))
        context.move(to: CGPoint(x: glyph.maxX, y: glyph.minY))
        context.addLine(to: CGPoint(x: glyph.minX, y: glyph.maxY))
        context.strokePath()
    }

    /// Show the server-link sheet: the classic window's controller presents it, an embedded browser
    /// asks its host.
    private func presentLinkSheet() {
        if let embeddedLinkSheet { embeddedLinkSheet() } else { controller?.showLinkSheet() }
    }

    /// Let an embedding host trigger the same link flow the toolbar button does.
    func showLinkSheetFromHost() { presentLinkSheet() }

    /// Hide Title Bars is a classic-window preference. An embedded browser has no title bar to hide
    /// (its `Layout.titleBarHeight` is already zero), so it must not also take the shift-up offset —
    /// that would move the content off the top of the holder.
    private var hidesClassicTitleBar: Bool {
        !isEmbeddedInSkin && WindowManager.shared.hideTitleBars
    }

    /// True for a library in the titleless gloss frame (WMP, Audion, or a `.wal` palette with no
    /// borrowed frame): its close is a corner hit area over the server bar. The bar's right-edge
    /// controls keep their usual place and carve themselves out of that area (`hitTestCloseButton`).
    private var closesFromCorner: Bool {
        !isEmbeddedInSkin && hostedFrame == nil && SkinnedSurfaceChrome.hidesPaletteTitleBar
    }

    private var originalWindowSize: NSSize {
        // Use actual bounds, no scaling
        return bounds.size
    }

    /// Calculate scale factor based on current bounds vs original (base) size
    private var scaleFactor: CGFloat {
        // No scaling, UI stays at fixed pixel size
        return 1.0
    }

    private func currentPlaylistColors() -> PlaylistColors {
        if let style = winampModernStyle { return style.playlistColors }
        let skin = WindowManager.shared.currentSkin ?? SkinLoader.shared.loadDefault()
        return skin.playlistColors
    }

    private func classicAppearance(for background: NSColor) -> NSAppearance? {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        background.usingColorSpace(.deviceRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        let brightness = 0.299 * r + 0.587 * g + 0.114 * b
        return NSAppearance(named: brightness < 0.5 ? .darkAqua : .aqua)
    }

    /// The Data tab's content, coloured from the playlist colours — the classic skin's, or the
    /// `.wal`/`.wmz` surface style's (which follows the colour theme).
    private func makeHistoryRootView(_ colors: PlaylistColors) -> StatsContentView {
        StatsContentView(agent: historyAgent,
                         skinTextColor: Color(nsColor: colors.normalText),
                         headerTitle: "Library Data",
                         heatmapTheme: ContributionHeatmapTheme(background: colors.normalBackground,
                                                                text: colors.normalText,
                                                                accent: colors.currentText))
    }

    private func makeHistoryHostingView() -> NSHostingView<StatsContentView> {
        let colors = currentPlaylistColors()
        let rootView = makeHistoryRootView(colors)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = colors.normalBackground.cgColor
        hostingView.layer?.isOpaque = true
        hostingView.appearance = classicAppearance(for: colors.normalBackground)
        hostingView.setAccessibilityIdentifier("plexBrowser.data")
        hostingView.setAccessibilityLabel("Library Data")
        return hostingView
    }

    private func ensureHistoryHostingView() {
        guard historyHostingView == nil else { return }
        let hostingView = makeHistoryHostingView()
        addSubview(hostingView)
        historyHostingView = hostingView
        updateHistoryHostingFrame()
    }

    private func updateHistoryHostingVisibility() {
        if model.browseMode.isHistoryMode {
            ensureHistoryHostingView()
        }
        let isVisible = model.browseMode.isHistoryMode
        historyHostingView?.isHidden = !isVisible
        updateHistoryHostingFrame()
    }

    private func updateHistoryHostingFrame() {
        historyHostingView?.frame = embeddedContentRect()
        // Flow / Tiles leave the alphabet index beside them.
        artLens.frame = embeddedContentRect().divided(atDistance: Layout.alphabetWidth * scaleFactor, from: .maxXEdge).remainder
    }

    /// Content rect (view coordinates) below the tab bar and above the status bar — shared by the
    /// embedded history subview and the cover flow overlay.
    private func embeddedContentRect() -> NSRect {
        let scale = scaleFactor
        let hiddenTitleBarOffset = hidesClassicTitleBar ? Layout.titleBarHeight : 0
        let topInset = (listTopY - hiddenTitleBarOffset) * scale
        let bottomInset = Layout.statusBarHeight * scale
        let horizontalInset = (Layout.leftBorder + Layout.rightBorder) * scale
        return NSRect(
            x: Layout.leftBorder * scale,
            y: bottomInset,
            width: max(0, bounds.width - horizontalInset),
            height: max(0, bounds.height - topInset - bottomInset)
        )
    }

    // MARK: - Art (Flow, Tiles, row thumbnails)

    /// A row as the Flow / Tiles views show it.
    private func artItem(for item: LibraryBrowserItem) -> LibraryArtItem {
        let cacheKey = itemArtwork(for: item).cacheKey
        return LibraryArtItem(id: item.id, title: item.title, subtitle: item.info ?? "",
                              cachedArtwork: { cacheKey.flatMap { Self.artworkCache.object(forKey: NSString(string: $0)) } },
                              art: rowThumbnailSource(for: item),
                              artAspect: item.type.isPoster ? LibraryArtItem.posterAspect : 1)
    }

    /// Resolve a display item to its artwork cache key and async loader (reusing the per-source
    /// loaders that back `loadArtworkForSelection`).
    private func itemArtwork(for item: LibraryBrowserItem) -> (cacheKey: String?, load: () async -> NSImage?) {
        switch item.type {
        case .album(let album):
            guard let thumb = album.thumb else { return ("plex:\(album.id)", { nil }) }
            let key = "plex:\(album.id)"
            return (key, { [weak self] in await self?.loadPlexArtworkByThumb(thumb: thumb, cacheKey: key) })
        case .localAlbum(let album):
            // Resolve the album's first track off the main thread (inside the throttled loader) —
            // never synchronously here, since this runs for every item on each list rebuild.
            return (nil, { [weak self] in
                let track: LibraryTrack?
                if let first = album.tracks.first {
                    track = first
                } else {
                    track = await Task.detached { MediaLibraryStore.shared.tracksForAlbum(album.id).first }.value
                }
                guard let self, let track else { return nil }
                return await self.loadLocalArtwork(url: track.url)
            })
        case .subsonicAlbum(let album):
            guard let coverArt = album.coverArt else { return (nil, { nil }) }
            let key = "subsonic:\(coverArt)"
            return (key, { [weak self] in await self?.loadSubsonicArtworkByCoverId(coverArt: coverArt, cacheKey: key) })
        case .jellyfinAlbum(let album):
            return jellyfinArtwork(album.artworkItemId)
        case .embyAlbum(let album):
            return embyArtwork(album.artworkItemId)
        case .movie(let movie):
            let key = "plex:\(movie.id)"
            return (key, { [weak self] in
                guard let self else { return nil }
                if let thumb = movie.thumb,
                   let image = await self.loadPlexArtworkByThumb(thumb: thumb, cacheKey: key) {
                    return image
                }
                return await self.loadMovieWebArtwork(title: movie.title, year: movie.year)
            })
        case .show(let show):
            guard let thumb = show.thumb else { return ("plex:\(show.id)", { nil }) }
            let key = "plex:\(show.id)"
            return (key, { [weak self] in await self?.loadPlexArtworkByThumb(thumb: thumb, cacheKey: key) })
        case .season(let season):
            guard let thumb = season.thumb else { return ("plex:\(season.id)", { nil }) }
            let key = "plex:\(season.id)"
            return (key, { [weak self] in await self?.loadPlexArtworkByThumb(thumb: thumb, cacheKey: key) })
        case .episode(let episode):
            guard let thumb = episode.thumb else { return ("plex:\(episode.id)", { nil }) }
            let key = "plex:\(episode.id)"
            return (key, { [weak self] in await self?.loadPlexArtworkByThumb(thumb: thumb, cacheKey: key) })
        case .localMovie(let movie):
            return ("local:\(movie.url.path)", { [weak self] in await self?.loadLocalArtwork(url: movie.url) })
        case .localShow(let show):
            guard let episode = show.seasons.first(where: { !$0.episodes.isEmpty })?.episodes.first else {
                return (nil, { nil })
            }
            return ("local:\(episode.url.path)", { [weak self] in await self?.loadLocalArtwork(url: episode.url) })
        case .localSeason(let season, _):
            guard let episode = season.episodes.first else { return (nil, { nil }) }
            return ("local:\(episode.url.path)", { [weak self] in await self?.loadLocalArtwork(url: episode.url) })
        case .localEpisode(let episode):
            return ("local:\(episode.url.path)", { [weak self] in await self?.loadLocalArtwork(url: episode.url) })
        case .jellyfinMovie(let movie):
            return jellyfinArtwork(movie.artworkItemId)
        case .jellyfinShow(let show):
            return jellyfinArtwork(show.artworkItemId)
        case .jellyfinSeason(let season):
            return jellyfinArtwork(season.artworkItemId)
        case .jellyfinEpisode(let episode):
            return jellyfinArtwork(episode.artworkItemId)
        case .embyMovie(let movie):
            return embyArtwork(movie.artworkItemId)
        case .embyShow(let show):
            return embyArtwork(show.artworkItemId)
        case .embySeason(let season):
            return embyArtwork(season.artworkItemId)
        case .embyEpisode(let episode):
            return embyArtwork(episode.artworkItemId)
        case .artist(let artist):
            guard let thumb = artist.thumb else { return ("plex:\(artist.id)", { nil }) }
            let key = "plex:\(artist.id)"
            return (key, { [weak self] in await self?.loadPlexArtworkByThumb(thumb: thumb, cacheKey: key) })
        case .localArtist(let artist):
            return (nil, { [weak self] in
                let track = await Task.detached {
                    MediaLibraryStore.shared.searchTracks(query: artist.name, limit: 1, offset: 0).first
                }.value
                guard let self, let track else { return nil }
                return await self.loadLocalArtwork(url: track.url)
            })
        case .subsonicArtist(let artist):
            guard let coverArt = artist.coverArt else { return (nil, { nil }) }
            let key = "subsonic:\(coverArt)"
            return (key, { [weak self] in await self?.loadSubsonicArtworkByCoverId(coverArt: coverArt, cacheKey: key) })
        case .jellyfinArtist(let artist):
            return jellyfinArtwork(artist.artworkItemId)
        case .embyArtist(let artist):
            return embyArtwork(artist.artworkItemId)
        case .track(let track):
            guard let thumb = track.thumb else { return ("plex:\(track.id)", { nil }) }
            let key = "plex:\(track.id)"
            return (key, { [weak self] in await self?.loadPlexArtworkByThumb(thumb: thumb, cacheKey: key) })
        case .localTrack(let track):
            return ("local:\(track.url.path)", { [weak self] in await self?.loadLocalArtwork(url: track.url) })
        case .subsonicTrack(let song):
            guard let coverArt = song.coverArt else { return (nil, { nil }) }
            let key = "subsonic:\(coverArt)"
            return (key, { [weak self] in await self?.loadSubsonicArtworkByCoverId(coverArt: coverArt, cacheKey: key) })
        case .jellyfinTrack(let song):
            return jellyfinArtwork(song.artworkItemId)
        case .embyTrack(let song):
            return embyArtwork(song.artworkItemId)
        default:
            return (nil, { nil })
        }
    }

    /// A Jellyfin item's art, from its `artworkItemId` (nil when the item has no picture).
    private func jellyfinArtwork(_ itemId: String?) -> (cacheKey: String?, load: () async -> NSImage?) {
        guard let itemId else { return (nil, { nil }) }
        return ("jellyfin:\(itemId)", { [weak self] in await self?.loadJellyfinArtwork(itemId: itemId) })
    }

    /// An Emby item's art, from its `artworkItemId` (nil when the item has no picture).
    private func embyArtwork(_ itemId: String?) -> (cacheKey: String?, load: () async -> NSImage?) {
        guard let itemId else { return (nil, { nil }) }
        return ("emby:\(itemId)", { [weak self] in await self?.loadEmbyArtwork(itemId: itemId) })
    }

    /// The art for a row's round thumbnail, or nil for rows that never carry art. Cover Flow items
    /// reuse `itemArtwork`'s loaders, keyed within the current server.
    private func rowThumbnailSource(for item: LibraryBrowserItem) -> LibraryRowThumbnails.Source? {
        switch item.type {
        case .localFolder: return nil
        case .youtubeChannel(let channel): return .channel(channel)
        case .youtubeVideo(let video): return .video(video)
        case .radioStation(let station): return .radio(station)
        case .localPlaylistTrack(let track): return .localFile(track.url)
        default:
            guard item.type.isArtItem else { return nil }
            let (cacheKey, load) = itemArtwork(for: item)
            return .item(key: cacheKey ?? "item:\(item.id)", server: model.currentSource.serverId, owner: self, load: load)
        }
    }

    /// Convert a point from view coordinates to skin coordinates (top-left origin)
    private func convertToSkinCoordinates(_ point: NSPoint) -> NSPoint {
        // No scaling, just flip Y coordinate (macOS bottom-left to skin top-left)
        var skinPoint = NSPoint(x: point.x, y: bounds.height - point.y)
        // When title bars are hidden, offset to match the shifted drawing
        if hidesClassicTitleBar {
            skinPoint.y += Layout.titleBarHeight
        }
        return skinPoint
    }

    /// The inverse of `convertToSkinCoordinates`, for a rect.
    private func convertFromSkinCoordinates(_ rect: NSRect) -> NSRect {
        let titleOffset = hidesClassicTitleBar ? Layout.titleBarHeight : 0
        return NSRect(x: rect.minX, y: bounds.height - rect.maxY + titleOffset, width: rect.width, height: rect.height)
    }
    
    // MARK: - Drawing
    
    override func draw(_ dirtyRect: NSRect) {
        // Capture artwork reference to prevent release during draw cycle.
        // An async Task may replace currentArtwork mid-draw, causing the old
        // image to be deallocated while Core Animation still references it.
        let capturedArtwork = currentArtwork
        
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        
        let originalSize = originalWindowSize
        
        // Use current skin
        let skin = WindowManager.shared.currentSkin ?? SkinLoader.shared.loadDefault()
        let skinPath = WindowManager.shared.currentSkinPath ?? "default"
        if cachedRenderer == nil || cachedRendererSkinPath != skinPath {
            cachedRenderer = SkinRenderer(skin: skin)
            cachedRendererSkinPath = skinPath
        }
        let renderer = cachedRenderer!
        let isActive = window?.isKeyWindow ?? true
        
        // Flip coordinate system to match skin's top-down coordinates
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        
        // When hiding title bars, shift content up to clip the title bar off the top
        if hidesClassicTitleBar {
            context.translateBy(x: 0, y: -Layout.titleBarHeight)
        }

        // Use low interpolation for cleaner scaling of skin sprites (none can cause artifacts)
        context.interpolationQuality = .low
        
        // Use original bounds for drawing (scaling is applied via transform)
        let drawBounds = NSRect(origin: .zero, size: originalSize)

        let colors = currentPlaylistColors()

            // Fast path: scroll timer marks only server bar area dirty — skip tab bar + list
            // Must still draw the window chrome (borders) so the border tiles aren't missing in that row
            let serverBarMinY = bounds.height - CGFloat(Layout.titleBarHeight + Layout.serverBarHeight)
            if dirtyRect.minY >= serverBarMinY {
                let scrollPosition = calculateScrollPosition()
                drawWindowChromeIfNeeded(renderer: renderer, context: context, bounds: drawBounds,
                                         isActive: isActive, scrollPosition: scrollPosition)
                drawServerBar(in: context, drawBounds: drawBounds, colors: colors, renderer: renderer)
            } else {
                // Calculate scroll position for scrollbar (0-1)
                let scrollPosition = calculateScrollPosition()

                // Draw window frame using skin sprites
                drawWindowChromeIfNeeded(renderer: renderer, context: context, bounds: drawBounds,
                                         isActive: isActive, scrollPosition: scrollPosition)

                // Draw server/library selector bar
                drawServerBar(in: context, drawBounds: drawBounds, colors: colors, renderer: renderer)

                // Draw tabs, search, and list.
                // Skip expensive tab+list rendering if dirtyRect is entirely in the title/server bar zone
                // (server name scroll timer marks only serverBarArea dirty at 15Hz).
                let belowServerBar = bounds.height - CGFloat(Layout.titleBarHeight + Layout.serverBarHeight)
                if dirtyRect.minY < belowServerBar {
                    // Draw tab bar
                    drawTabBar(in: context, drawBounds: drawBounds, colors: colors, renderer: renderer)

                    // Draw search bar (only in search mode)
                    if model.browseMode == .search {
                        drawSearchBar(in: context, drawBounds: drawBounds, colors: colors, renderer: renderer)
                    }

                    if model.browseMode.isHistoryMode {
                        // SwiftUI-hosted history content is rendered via an embedded subview.
                    } else {
                        // Draw list area or connection status
                        // Only check Plex link status if using Plex source
                        let needsPlexLink = model.currentSource.isPlex && !PlexManager.shared.isLinked
                        if needsPlexLink {
                            drawNotLinkedState(in: context, colors: colors, renderer: renderer)
                        } else if model.isLoading {
                            drawLoadingState(in: context, colors: colors, renderer: renderer)
                        } else if let error = model.errorMessage {
                            drawErrorState(in: context, message: error, colors: colors, renderer: renderer)
                        } else if artLens.isPresenting {
                            // The Flow / Tiles view renders the art; just fill the list area
                            // background so the interior isn't left stale behind it.
                            let layout = listLayout()
                            colors.normalBackground.setFill()
                            context.fill(layout.area)
                            drawAlphabetIndex(in: context, rect: layout.alphabet, colors: colors, renderer: renderer)
                        } else {
                            drawListArea(in: context, layout: listLayout(), colors: colors, renderer: renderer, artwork: capturedArtwork)
                        }
                    }

                    // Draw status bar text
                    drawStatusBarText(in: context, drawBounds: drawBounds, colors: colors, renderer: renderer)
                }
            }

        context.restoreGState()

        if isHighlighted {
            NSColor.white.withAlphaComponent(0.15).setFill()
            bounds.fill()
        }
    }

    /// Calculate scroll position as 0-1 value
    private func calculateScrollPosition() -> CGFloat {
        let listHeight = listLayout().rows.height
        let totalContentHeight = CGFloat(model.displayItems.count) * itemHeight
        
        guard totalContentHeight > listHeight else { return 0 }
        
        let scrollRange = totalContentHeight - listHeight
        return min(1, max(0, scrollOffset / scrollRange))
    }
    
    // MARK: - Content Drawing (in skin coordinates, using skin text font)
    
    /// The colour the classic sheet's text is drawn in — sampled from `text.bmp` normally, taken
    /// from the `.wal` palette inside a modern skin (Phase 16). Used by the callers that tint their
    /// own glyphs rather than going through `drawScaledSkinText`.
    ///
    /// Always in an RGB space: several callers dim it by reading `redComponent` and friends, which
    /// *raise* on a greyscale or catalog colour rather than returning anything.
    private func accentTextColor(_ renderer: SkinRenderer) -> NSColor {
        let color = winampModernStyle?.text ?? renderer.skinTextColor()
        return color.usingColorSpace(.deviceRGB) ?? WasabiPalette.listTextFallback
    }

    /// Helper to draw scaled skin text (green)
    ///
    /// Inside a `.wal` skin this is the skin's own list colour in the proportional system font
    /// instead of the classic 5×6 bitmap sprite sheet (Phase 16), drawn inside the `count` cells the
    /// layout reserves; anything placed by the label's width measures it with
    /// `ClassicLibraryTab.textWidth`.
    ///
    /// `color` overrides the skin's list colour for a caller that draws onto something other than the
    /// content background and has already checked what can be read there (B48). It is only ever
    /// non-nil in `winampModern` mode; the classic sprite path has no per-call colour and ignores it.
    private func drawScaledSkinText(_ text: String, at position: NSPoint, scale: CGFloat, renderer: SkinRenderer,
                                    in context: CGContext, color: NSColor? = nil) {
        ClassicLibraryTab.drawSkinText(text, at: position, scale: scale, color: color, renderer: renderer,
                                       style: winampModernStyle, context: context)
    }

    /// Helper to draw scaled white skin text. "White" is the classic sheet's emphasis colour; the
    /// skin's own "current" role is the same job done in a `.wal` palette.
    private func drawScaledWhiteSkinText(_ text: String, at position: NSPoint, scale: CGFloat, renderer: SkinRenderer, in context: CGContext) {
        ClassicLibraryTab.drawSkinText(text, at: position, scale: scale, white: true, renderer: renderer,
                                       style: winampModernStyle, context: context)
    }
    
    /// Draw the List / Flow / Tiles buttons with the source-level controls, before F5. Returns the
    /// leading edge that the next accessory (count, rating) should lay out before.
    private func drawViewModeButtons(
        before trailingX: CGFloat,
        textY: CGFloat,
        textScale: CGFloat,
        chromeScale: CGFloat,
        context: CGContext
    ) -> CGFloat {
        guard artLens.hasItems else { return trailingX }
        let side = viewModeIconSide(textScale: textScale)
        let leadingX = trailingX - 12 * chromeScale - viewModeButtonsWidth(textScale: textScale, chromeScale: chromeScale)
        let colors = currentPlaylistColors()
        var x = leadingX
        for mode in LibraryViewMode.allCases {
            // Centred on the bitmap text's line, padded out to a comfortable hit target.
            let icon = NSRect(x: x, y: textY - textScale, width: side, height: side)
            mode.drawIcon(in: icon, color: artLens.mode == mode ? colors.currentText : colors.normalText,
                          context: context)
            viewModeButtonRects.append((mode, icon.insetBy(dx: -1.5 * chromeScale, dy: -3 * textScale)))
            x += side + 3 * chromeScale
        }
        return leadingX
    }

    /// The icons sit on the bitmap font's 6 px line, a pixel over it each side.
    private func viewModeIconSide(textScale: CGFloat) -> CGFloat {
        (SkinElements.TextFont.charHeight + 2) * textScale
    }

    private func viewModeButtonsWidth(textScale: CGFloat, chromeScale: CGFloat) -> CGFloat {
        let count = CGFloat(LibraryViewMode.allCases.count)
        return count * viewModeIconSide(textScale: textScale) + (count - 1) * 3 * chromeScale
    }
    
    private func drawServerBar(in context: CGContext, drawBounds: NSRect, colors: PlaylistColors, renderer: SkinRenderer) {
        let barY = Layout.titleBarHeight
        let barRect = NSRect(x: Layout.leftBorder, y: barY,
                            width: drawBounds.width - Layout.leftBorder - Layout.rightBorder,
                            height: Layout.serverBarHeight)
        
        // Background - always fully opaque in classic UI
        colors.normalBackground.setFill()
        context.fill(barRect)
        
        let charWidth = SkinElements.TextFont.charWidth
        let charHeight = SkinElements.TextFont.charHeight
        let chromeScale = topChromeScale
        let textScale = bitmapTextScale * chromeScale
        let scaledCharWidth = charWidth * textScale
        let scaledCharHeight = charHeight * textScale
        // Round textY to prevent shimmering on non-Retina displays
        let backingScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let rawTextY = barRect.minY + (barRect.height - scaledCharHeight) / 2
        let textY = backingScale < 1.5 ? round(rawTextY) : rawTextY
        let toolbarLeftInset = (4 + toolbarItemHorizontalEdgePadding) * chromeScale
        let toolbarRightInset = (8 + toolbarItemHorizontalEdgePadding + rightEdgeItemPaddingBoost) * chromeScale
        
        // Common prefix for all sources
        let prefix = "Source: "
        drawScaledSkinText(prefix, at: NSPoint(x: barRect.minX + toolbarLeftInset, y: textY), scale: textScale, renderer: renderer, in: context)
        let prefixWidth = ClassicLibraryTab.textWidth(prefix, scale: textScale, style: winampModernStyle)
        let sourceNameStartX = barRect.minX + toolbarLeftInset + prefixWidth
        
        refreshButtonRect = .zero
        viewModeButtonRects = []
        sourceButtonRect = .zero
        libraryButtonRect = .zero
        addButtonRect = .zero
        serverNameCycleWidth = 0
        libraryNameCycleWidth = 0

        let content = serverBarContent
        if case .unconfigured(let prompt) = content {
            let promptWidth = ClassicLibraryTab.textWidth(prompt, scale: textScale, style: winampModernStyle)
            drawScaledSkinText(prompt, at: NSPoint(x: barRect.midX - promptWidth / 2, y: textY), scale: textScale, renderer: renderer, in: context)
            sourceButtonRect = barRect
            return
        }

        // Right side: F5 refresh label, with the view-mode buttons before it
        let refreshText = "F5"
        let refreshTextWidth = ClassicLibraryTab.textWidth(refreshText, scale: textScale, style: winampModernStyle)
        let refreshX = barRect.maxX - refreshTextWidth - toolbarRightInset
        drawScaledSkinText(refreshText, at: NSPoint(x: refreshX, y: textY), scale: textScale, renderer: renderer, in: context)
        // Under a corner close F5 owns its label plus a 2pt hit margin, so the close keeps the
        // corner beside it.
        let refreshWidth = closesFromCorner
            ? refreshTextWidth + 2 * chromeScale : barRect.maxX - refreshX
        refreshButtonRect = NSRect(x: refreshX, y: barRect.minY, width: refreshWidth, height: barRect.height)
        let accessoryX = drawViewModeButtons(
            before: refreshX, textY: textY, textScale: textScale, chromeScale: chromeScale,
            context: context
        )

        switch content {
        case .builtIn(let name):
            let sourceText = withItemCount(name)
            drawScaledWhiteSkinText(sourceText, at: NSPoint(x: sourceNameStartX, y: textY), scale: textScale, renderer: renderer, in: context)
            let sourceTextWidth = ClassicLibraryTab.textWidth(sourceText, scale: textScale, style: winampModernStyle)
            sourceButtonRect = NSRect(x: barRect.minX, y: barRect.minY,
                                      width: sourceNameStartX + sourceTextWidth - barRect.minX,
                                      height: barRect.height)

            // +ADD button after source name with balanced spacing (green text)
            let addText = "+ADD"
            let addX = sourceNameStartX + sourceTextWidth + 28 * chromeScale
            drawScaledSkinText(addText, at: NSPoint(x: addX, y: textY), scale: textScale, renderer: renderer, in: context)
            addButtonRect = NSRect(x: addX, y: barRect.minY,
                                   width: ClassicLibraryTab.textWidth(addText, scale: textScale, style: winampModernStyle) + 8 * chromeScale,
                                   height: barRect.height)

            // Scan animation: small spinner at center of bar while library is scanning
            if case .local = model.currentSource, isLibraryScanning {
                let cx = barRect.midX
                let cy = barRect.midY
                let innerR: CGFloat = 3
                let outerR: CGFloat = 8
                let n = 8
                let step = CGFloat.pi * 2 / CGFloat(n)
                let textColor = accentTextColor(renderer)
                for i in 0..<n {
                    let angle = CGFloat(i) * step - CGFloat.pi / 2 + CGFloat(loadingAnimationFrame) * step
                    textColor.withAlphaComponent(CGFloat(i + 1) / CGFloat(n) * 0.9).setStroke()
                    context.setLineWidth(2)
                    context.move(to: CGPoint(x: cx + cos(angle) * innerR, y: cy + sin(angle) * innerR))
                    context.addLine(to: CGPoint(x: cx + cos(angle) * outerR, y: cy + sin(angle) * outerR))
                    context.strokePath()
                }
                let scanText = "SCANNING"
                let scanX = cx + outerR + 6
                drawScaledSkinText(scanText, at: NSPoint(x: scanX, y: textY), scale: textScale, renderer: renderer, in: context)
            }

        case .server(let serverName, let maxChars, let library):
            // A changed name scrolls from its start.
            if serverName != lastServerName {
                lastServerName = serverName
                serverNameScrollOffset = 0
            }
            if library != lastLibraryName {
                lastLibraryName = library
                libraryNameScrollOffset = 0
            }

            // Server name right after "Source:", in a fixed-width field
            let serverNameMaxWidth = CGFloat(maxChars) * scaledCharWidth
            serverNameCycleWidth = drawScrollingText(serverName, startX: sourceNameStartX, textY: textY,
                              availableWidth: serverNameMaxWidth, scale: textScale,
                              scrollOffset: serverNameScrollOffset,
                              renderer: renderer, in: context)

            // Library label and name after the server field
            let libLabel = "Lib:"
            let libraryLabelX = sourceNameStartX + serverNameMaxWidth + 16 * chromeScale
            drawScaledSkinText(libLabel, at: NSPoint(x: libraryLabelX, y: textY), scale: textScale, renderer: renderer, in: context)

            let libraryX = libraryLabelX + ClassicLibraryTab.textWidth(libLabel, scale: textScale, style: winampModernStyle) + 4 * chromeScale
            let libraryText = withItemCount(library)
            // The field grows into the free space before the right cluster; it scrolls when even that is short.
            let libraryNameMaxWidth = max(Self.minLibraryFieldChars * scaledCharWidth, accessoryX - 24 * chromeScale - libraryX)
            libraryNameCycleWidth = drawScrollingText(libraryText, startX: libraryX, textY: textY,
                              availableWidth: libraryNameMaxWidth, scale: textScale,
                              scrollOffset: libraryNameScrollOffset,
                              renderer: renderer, in: context)

            sourceButtonRect = NSRect(x: barRect.minX, y: barRect.minY,
                                      width: libraryLabelX - barRect.minX,
                                      height: barRect.height)
            libraryButtonRect = NSRect(x: libraryLabelX, y: barRect.minY,
                                       width: libraryX + libraryNameMaxWidth - libraryLabelX,
                                       height: barRect.height)
            if serverNameCycleWidth > 0 || libraryNameCycleWidth > 0 {
                startServerNameScroll()
            }

        case .unconfigured:
            break  // Drawn above, without the right-side buttons.
        }
    }

    /// Draw text in a field `availableWidth` wide, circularly scrolling when it overflows. Returns
    /// how far the text travels before the scroll wraps — what the scroll tick wraps its offset at —
    /// or 0 when it fits and does not scroll.
    private func drawScrollingText(_ text: String, startX: CGFloat, textY: CGFloat,
                                   availableWidth: CGFloat, scale: CGFloat,
                                   scrollOffset: CGFloat,
                                   renderer: SkinRenderer, in context: CGContext) -> CGFloat {
        let charHeight = SkinElements.TextFont.charHeight
        let scaledCharHeight = charHeight * scale
        
        guard ClassicLibraryTab.textWidth(text, scale: scale, style: winampModernStyle) > availableWidth else {
            drawScaledWhiteSkinText(text, at: NSPoint(x: startX, y: textY), scale: scale, renderer: renderer, in: context)
            return 0
        }
        // One cycle is the text and a separator for a seamless wrap, measured as the one run drawn.
        let fullText = text + "   "
        let totalCycleWidth = ClassicLibraryTab.textWidth(fullText, scale: scale, style: winampModernStyle)
        
        // Clip to the available area
        context.saveGState()
        let clipRect = NSRect(x: startX, y: textY, width: availableWidth, height: scaledCharHeight)
        context.clip(to: clipRect)
        
        // Draw two copies of "text + separator" for seamless circular scrolling
        for pass in 0..<2 {
            let baseX = startX - scrollOffset + (CGFloat(pass) * totalCycleWidth)
            
            // Check if this pass could be visible
            if baseX + totalCycleWidth < startX || baseX > startX + availableWidth {
                continue
            }
            
            drawScaledWhiteSkinText(fullText, at: NSPoint(x: baseX, y: textY), scale: scale, renderer: renderer, in: context)
        }
        
        context.restoreGState()
        return totalCycleWidth
    }
    
    private func drawTabBar(in context: CGContext, drawBounds: NSRect, colors: PlaylistColors, renderer: SkinRenderer) {
        let tabBarY = Layout.titleBarHeight + Layout.serverBarHeight
        let tabBarRect = NSRect(x: Layout.leftBorder, y: tabBarY,
                               width: drawBounds.width - Layout.leftBorder - Layout.rightBorder,
                               height: Layout.tabBarHeight)
        
        // Background - use fully opaque on non-Retina to prevent compositing artifacts
        let backingScaleForTabBg = NSScreen.main?.backingScaleFactor ?? 2.0
        if backingScaleForTabBg < 1.5 {
            colors.normalBackground.setFill()
        } else {
            colors.normalBackground.withAlphaComponent(0.4).setFill()
        }
        context.fill(tabBarRect)
        
        let charHeight = SkinElements.TextFont.charHeight
        let chromeScale = topChromeScale
        let textScale = bitmapTextScale * chromeScale
        let scaledCharHeight = charHeight * textScale
        
        // Round Y coordinates on non-Retina to prevent shimmering
        let backingScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let shouldRound = backingScale < 1.5
        
        // Calculate sort indicator width (on the right)
        let sortText = "Sort"
        let sortWidth = ClassicLibraryTab.textWidth(sortText, scale: textScale, style: winampModernStyle) + 8 * chromeScale
        let tabLeftInset = tabItemHorizontalEdgePadding * chromeScale
        let tabRightInset = (tabItemHorizontalEdgePadding + rightEdgeItemPaddingBoost) * chromeScale
        let tabsStartX = tabBarRect.minX + tabLeftInset

        // Draw tabs, leaving room for the sort indicator.
        let modes = LibraryBrowseMode.tabs
        let tabsWidth = tabBarRect.width - sortWidth - tabLeftInset - tabRightInset

        // Content-aware widths and resolved (possibly dynamic) labels, shared with hit-testing.
        let labels = currentTabLabels()
        let tabWidths = tabBarWidths(tabsWidth: tabsWidth, textScale: textScale,
                                     horizontalScale: chromeScale)

        var tabX = tabsStartX
        tabButtonRects.removeAll(keepingCapacity: true)
        for (index, mode) in modes.enumerated() {
            let tabWidth = tabWidths[index]
            let tabRect = NSRect(x: tabX, y: tabBarY,
                                width: tabWidth, height: Layout.tabBarHeight)
            tabX += tabWidth

            let label = labels[index]
            var isSelected = mode == model.browseMode
            // Highlight the plists slot when browseMode is .folders (local source only).
            if mode == .plists, model.browseMode == .folders, case .local = model.currentSource {
                isSelected = true
            }

            // Boxed toggle outline around each tab, mirroring the modern library tabs.
            ClassicLibraryTab.draw(label, isSelected: isSelected, in: tabRect, boxInsetX: 3 * chromeScale,
                                   textScale: textScale, colors: colors, renderer: renderer,
                                   style: winampModernStyle, context: context)
            tabButtonRects.append(tabRect)
        }
        
        // Draw sort indicator on the right
        let sortRect = NSRect(x: tabBarRect.maxX - tabRightInset - sortWidth,
                              y: tabBarY, width: sortWidth, height: Layout.tabBarHeight)
        sortButtonRect = sortRect
        let rawSortX = sortRect.minX + 4 * chromeScale
        let rawSortY = tabBarY + (Layout.tabBarHeight - scaledCharHeight) / 2
        let sortX = shouldRound ? round(rawSortX) : rawSortX
        let sortY = shouldRound ? round(rawSortY) : rawSortY
        drawScaledSkinText(sortText, at: NSPoint(x: sortX, y: sortY), scale: textScale, renderer: renderer, in: context)

    }
    
    private func drawSearchBar(in context: CGContext, drawBounds: NSRect, colors: PlaylistColors, renderer: SkinRenderer) {
        let searchY = listTopY - Layout.searchBarHeight
        let searchRect = NSRect(x: Layout.leftBorder + Layout.padding, y: searchY + 3,
                               width: drawBounds.width - Layout.leftBorder - Layout.rightBorder - Layout.padding * 2,
                               height: Layout.searchBarHeight - 6)
        
        // Search field background
        let isFocused = window?.firstResponder === self
        let bgColor = isFocused
            ? colors.selectedBackground.withAlphaComponent(0.5)
            : colors.normalBackground.withAlphaComponent(0.3)
        bgColor.setFill()
        let path = NSBezierPath(roundedRect: searchRect, xRadius: 3, yRadius: 3)
        path.fill()
        
        // Focus border
        if isFocused {
            colors.currentText.withAlphaComponent(0.5).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        
        // Search text historically renders at the bitmap font's native size at 100%.
        // Preserve that baseline while still following UI Size.
        let textScale = contentScale
        let charHeight = SkinElements.TextFont.charHeight * textScale
        let textY = searchRect.minY + (searchRect.height - charHeight) / 2
        
        // Search text or placeholder using skin font.
        //
        // The field is a *translucent* fill, so what the text lands on is neither role: judge the
        // composited colour or a focused field stays unreadable on the skins B48 measured while the
        // opaque selection row is fixed.
        let fieldBackground = winampModernStyle.map {
            WinampModernSurfaceStyle.composited(bgColor, over: $0.background)
        }
        let fieldTextColor = winampModernStyle.flatMap { style in
            fieldBackground.map { style.legibleText(style.text, on: $0) }
        }
        let placeholder = model.currentSource.isYouTube ? "Search YouTube channels - press Enter" : "Type to search..."
        let displayText = model.searchQuery.isEmpty ? placeholder : model.searchQuery
        drawScaledSkinText(displayText, at: NSPoint(x: searchRect.minX + 6, y: textY),
                           scale: textScale, renderer: renderer, in: context, color: fieldTextColor)

        // Draw cursor if focused
        if isFocused && !model.searchQuery.isEmpty {
            let cursorX = searchRect.minX + 6 + ClassicLibraryTab.textWidth(model.searchQuery, scale: textScale, style: winampModernStyle) + 1
            (fieldTextColor ?? colors.normalText).setFill()
            context.fill(CGRect(x: cursorX, y: textY, width: max(1, contentScale), height: charHeight))
        }
    }
    
    private func drawNotLinkedState(in context: CGContext, colors: PlaylistColors, renderer: SkinRenderer) {
        let listRect = listLayout().area
        
        // Counter-flip for text
        context.saveGState()
        let centerY = listRect.midY
        context.translateBy(x: 0, y: centerY)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -centerY)
        
        let message = "Link your Plex account to browse your music library"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: colors.normalText.withAlphaComponent(0.6),
            .font: contentFont(ofSize: 12)
        ]
        let size = message.size(withAttributes: attrs)
        message.draw(at: NSPoint(x: listRect.midX - size.width / 2, y: listRect.midY - size.height / 2),
                    withAttributes: attrs)
        
        // Link button hint
        let hint = "Click the server bar above to link"
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(calibratedRed: 0.9, green: 0.6, blue: 0.1, alpha: 1.0),
            .font: contentFont(ofSize: 10)
        ]
        let hintSize = hint.size(withAttributes: hintAttrs)
        hint.draw(at: NSPoint(x: listRect.midX - hintSize.width / 2,
                              y: listRect.midY - size.height / 2 - 20 * contentScale),
                 withAttributes: hintAttrs)
        
        context.restoreGState()
    }
    
    private func drawLoadingState(in context: CGContext, colors: PlaylistColors, renderer: SkinRenderer) {
        let listRect = listLayout().area
        
        let centerY = listRect.midY
        let centerX = listRect.midX
        
        // Draw animated spinner
        let innerRadius: CGFloat = 5
        let outerRadius: CGFloat = 12
        let numSegments = 8
        let segmentAngle = CGFloat.pi * 2 / CGFloat(numSegments)
        
        for i in 0..<numSegments {
            let angle = CGFloat(i) * segmentAngle - CGFloat.pi / 2 + CGFloat(loadingAnimationFrame) * segmentAngle
            let alpha = CGFloat(i + 1) / CGFloat(numSegments)
            
            colors.normalText.withAlphaComponent(alpha).setStroke()
            context.setLineWidth(2.5)
            
            let startX = centerX + cos(angle) * innerRadius
            let startY = centerY + sin(angle) * innerRadius
            let endX = centerX + cos(angle) * outerRadius
            let endY = centerY + sin(angle) * outerRadius
            
            context.move(to: CGPoint(x: startX, y: startY))
            context.addLine(to: CGPoint(x: endX, y: endY))
            context.strokePath()
        }
        
        // Start animation timer if not running
        startLoadingAnimation()
    }

    /// Small inline spinner used on a downloading YouTube video row.
    private func drawRowSpinner(in context: CGContext, center: CGPoint, radius: CGFloat, colors: PlaylistColors) {
        let innerRadius = radius * 0.45
        let outerRadius = radius
        let numSegments = 8
        let segmentAngle = CGFloat.pi * 2 / CGFloat(numSegments)
        context.saveGState()
        for i in 0..<numSegments {
            let angle = CGFloat(i) * segmentAngle - CGFloat.pi / 2 + CGFloat(loadingAnimationFrame) * segmentAngle
            let alpha = CGFloat(i + 1) / CGFloat(numSegments)
            colors.normalText.withAlphaComponent(alpha).setStroke()
            context.setLineWidth(1.5)
            context.move(to: CGPoint(x: center.x + cos(angle) * innerRadius, y: center.y + sin(angle) * innerRadius))
            context.addLine(to: CGPoint(x: center.x + cos(angle) * outerRadius, y: center.y + sin(angle) * outerRadius))
            context.strokePath()
        }
        context.restoreGState()
    }

    private func drawErrorState(in context: CGContext, message: String, colors: PlaylistColors, renderer: SkinRenderer) {
        let listRect = listLayout().area
        
        // Counter-flip for text
        context.saveGState()
        let centerY = listRect.midY
        context.translateBy(x: 0, y: centerY)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -centerY)
        
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: colors.normalText.withAlphaComponent(0.6),
            .font: contentFont(ofSize: 11)
        ]
        let size = message.size(withAttributes: attrs)
        message.draw(at: NSPoint(x: listRect.midX - size.width / 2, y: listRect.midY - size.height / 2),
                    withAttributes: attrs)
        
        context.restoreGState()
    }
    
    private func drawEmptyState(in context: CGContext, listRect: NSRect, colors: PlaylistColors, renderer: SkinRenderer) {
        // Determine empty message based on mode and library type
        let library = PlexManager.shared.currentLibrary
        let message: String
        
        switch model.browseMode {
        case .artists, .albums:
            if library?.isMusicLibrary == true {
                message = "No \(model.browseMode.title.lowercased()) found"
            } else {
                message = "This library doesn't contain music"
            }
        case .movies:
            if library?.isMovieLibrary == true {
                message = "No movies found"
            } else {
                message = "This library doesn't contain movies"
            }
        case .shows:
            if library?.isShowLibrary == true {
                message = "No TV shows found"
            } else {
                message = "This library doesn't contain TV shows"
            }
        case .plists:
            message = "No playlists found"
        case .folders:
            message = "No folders found"
        case .search:
            if model.isYouTubeChannelSearch {
                // Channel search is submit-only: until Enter, nothing has been searched.
                message = model.searchQuery.isEmpty || model.hasUnsubmittedYouTubeSearch ? "Type and press Enter to search" : "No results found"
            } else {
                message = model.searchQuery.isEmpty ? "Type to search" : "No results found"
            }
        case .radio:
            message = "No radio stations found"
        case .history:
            return
        }
        
        // Draw using green skin text, centered
        let charHeight = SkinElements.TextFont.charHeight
        let textScale = bitmapTextScale
        let scaledCharHeight = charHeight * textScale
        let textWidth = ClassicLibraryTab.textWidth(message, scale: textScale, style: winampModernStyle)
        let textX = listRect.midX - textWidth / 2
        let textY = listRect.midY - scaledCharHeight / 2
        
        drawScaledSkinText(message, at: NSPoint(x: textX, y: textY), scale: textScale, renderer: renderer, in: context)
    }
    
    private func drawListArea(in context: CGContext, layout: ListLayout, colors: PlaylistColors, renderer: SkinRenderer, artwork: NSImage?) {
        // Show empty state message if no items (an empty list has no columns, so `rows` is the whole list)
        if model.displayItems.isEmpty {
            drawEmptyState(in: context, listRect: layout.rows, colors: colors, renderer: renderer)
            return
        }
        
        // Draw column headers BEFORE clipping (so they stay fixed)
        if let header = layout.header {
            drawColumnHeaders(in: context, header: header, colors: colors)
        }
        
        let listRect = layout.rows
        
        // Clip to content area (below headers)
        context.saveGState()
        context.clip(to: listRect)
        
        // On non-Retina displays, fill the entire list area with background color first
        // to prevent any gaps/lines showing through between items
        let backingScale = NSScreen.main?.backingScaleFactor ?? 2.0
        if backingScale < 1.5 {
            colors.normalBackground.setFill()
            context.fill(listRect)
        }
        
        // Draw album art background if enabled and available
        if WindowManager.shared.showBrowserArtworkBackground, let artworkImage = artwork,
           let cgImage = artworkImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            context.saveGState()
            
            // Calculate centered fill rect (scale to fill, center, maintain aspect ratio)
            let imageSize = NSSize(width: cgImage.width, height: cgImage.height)
            let artworkRect = calculateCenterFillRect(imageSize: imageSize, in: listRect)
            
            // Set low opacity for subtle background
            context.setAlpha(0.12)
            
            // Draw the image - CGContext draws with origin at bottom-left, but we're in flipped skin coords
            // So we need to flip just for this image
            context.saveGState()
            context.translateBy(x: artworkRect.minX, y: artworkRect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: artworkRect.width, height: artworkRect.height))
            context.restoreGState()
            
            context.restoreGState()
        }
        
        // Draw items
        // Round scroll offset to integer pixels to prevent text shimmering on non-Retina displays
        let roundedScrollOffset = backingScale < 1.5 ? round(scrollOffset) : scrollOffset
        rowThumbnails.beginPass(placeholder: colors.normalText.withAlphaComponent(0.15))
        
        let visibleStart = max(0, Int(scrollOffset / itemHeight))
        let visibleEnd = min(model.displayItems.count, visibleStart + Int(listRect.height / itemHeight) + 2)
        
        // Guard against invalid range during window resize
        guard visibleStart < visibleEnd else {
            context.restoreGState()
            // Still draw alphabet index
            drawAlphabetIndex(in: context, rect: layout.alphabet, colors: colors, renderer: renderer)
            return
        }
        
        for index in visibleStart..<visibleEnd {
            let y = listRect.minY + CGFloat(index) * itemHeight - roundedScrollOffset
            
            if y + itemHeight < listRect.minY || y > listRect.maxY {
                continue
            }
            
            let itemRect = NSRect(x: listRect.minX, y: y, width: listRect.width, height: itemHeight)
            let item = model.displayItems[index]
            let isSelected = selectedIndices.contains(index)
            
            // On non-Retina displays, fill item background to prevent gaps/lines
            // BUT skip this when artwork background is showing (it already provides a continuous background)
            // On Retina, only fill background for selected items
            let hasArtworkBackground = WindowManager.shared.showBrowserArtworkBackground && artwork != nil
            if backingScale < 1.5 && !hasArtworkBackground {
                // Fill with normal or selected background (only when no artwork)
                let bgColor = isSelected ? colors.selectedBackground : colors.normalBackground
                bgColor.setFill()
                context.fill(itemRect)
            } else if isSelected {
                colors.selectedBackground.setFill()
                context.fill(itemRect)
            }
            
            if let row = rowColumns(for: item, header: layout.header) {
                let indent = CGFloat(item.indentLevel) * 16
                drawColumnRow(item: item, columns: row.columns, group: row.group,
                              in: context, rect: itemRect, isSelected: isSelected, colors: colors, indent: indent)
            } else {
                // Original rendering for artists, playlists, headers, etc.
                let indent = CGFloat(item.indentLevel) * 16
                let textX = itemRect.minX + indent + 4

                // Expand/collapse indicator for hierarchical items — or an inline spinner
                // while a YouTube channel's uploads load.
                let isLoadingChannel: Bool = {
                    if case .youtubeChannel(let channel) = item.type { return YouTubeChannelUploads.shared.isFetching(channel.id) }
                    return false
                }()
                var titleSpinnerInset: CGFloat = 0
                if isLoadingChannel {
                    let spinnerRadius = min(itemRect.height * 0.3, 6)
                    drawRowSpinner(in: context, center: CGPoint(x: textX + spinnerRadius, y: itemRect.midY),
                                   radius: spinnerRadius, colors: colors)
                    titleSpinnerInset = spinnerRadius * 2 + 4
                } else if item.hasChildren {
                    let expanded = model.isExpanded(item)
                    let indicator = expanded ? "▼" : "▶"

                    // Counter-flip for indicator
                    context.saveGState()
                    let indicatorY = itemRect.midY
                    context.translateBy(x: 0, y: indicatorY)
                    context.scaleBy(x: 1, y: -1)
                    context.translateBy(x: 0, y: -indicatorY)

                    let indicatorAttrs: [NSAttributedString.Key: Any] = [
                        .foregroundColor: colors.normalText.withAlphaComponent(0.6),
                        .font: contentFont(ofSize: 8)
                    ]
                    indicator.draw(at: NSPoint(x: textX - 12, y: itemRect.midY - 5), withAttributes: indicatorAttrs)

                    context.restoreGState()
                }
                
                // Main text (counter-flip)
                context.saveGState()
                let textCenterY = itemRect.midY
                context.translateBy(x: 0, y: textCenterY)
                context.scaleBy(x: 1, y: -1)
                context.translateBy(x: 0, y: -textCenterY)
                
                let textColor = isSelected ? colors.selectedText : colors.normalText
                let attrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: textColor,
                    .font: contentFont(ofSize: 10)
                ]

                // Round thumbnail ahead of the title, drawn inside the counter-flip so it is upright.
                if let thumbnail = rowThumbnailSource(for: item) {
                    titleSpinnerInset += rowThumbnails.draw(thumbnail, in: context, at: textX + titleSpinnerInset,
                                                            rowRect: itemRect, side: itemHeight - 2)
                }

                let textRect = NSRect(x: textX + titleSpinnerInset, y: itemRect.minY + 2,
                                     width: itemRect.width - indent - 60 - titleSpinnerInset, height: itemHeight - 4)
                item.shownTitle.draw(in: textRect, withAttributes: attrs)
                
                // Secondary info (only for non-column view)
                if let info = item.info {
                    let infoColor = isSelected ? colors.selectedText : colors.normalText.withAlphaComponent(0.6)
                    let infoAttrs: [NSAttributedString.Key: Any] = [
                        .foregroundColor: infoColor,
                        .font: contentFont(ofSize: 9)
                    ]
                    let infoSize = info.size(withAttributes: infoAttrs)
                    let infoX = model.browseMode == .radio
                        ? (itemRect.midX - infoSize.width / 2)
                        : (itemRect.maxX - infoSize.width - 4)
                    info.draw(at: NSPoint(x: infoX, y: itemRect.midY - infoSize.height / 2),
                             withAttributes: infoAttrs)
                }
                
                context.restoreGState()
            }
        }
        rowThumbnails.endPass(visible: visibleStart..<visibleEnd, count: model.displayItems.count) {
            rowThumbnailSource(for: model.displayItems[$0])
        }
        
        context.restoreGState()
        
        drawAlphabetIndex(in: context, rect: layout.alphabet, colors: colors, renderer: renderer)
    }
    
    /// Draw column headers with separator line and resize handles
    private func drawColumnHeaders(in context: CGContext, header: ListLayout.Header, colors: PlaylistColors) {
        let rect = header.rect, columns = header.columns, group = header.group
        // Clip to the header rect to prevent drawing over scrollbar/alphabet index
        context.saveGState()
        context.clip(to: rect)
        
        let totalWidth = rect.width
        
        // Calculate total columns width to determine if horizontal scroll is needed
        let columnsWidth = totalColumnsWidth(columns: columns, group: group)
        let maxHorizontalScroll = max(0, columnsWidth - totalWidth)
        
        // Clamp horizontal scroll offset
        if horizontalScrollOffset > maxHorizontalScroll {
            horizontalScrollOffset = maxHorizontalScroll
        }
        
        // Header background (slightly darker)
        colors.normalBackground.withAlphaComponent(0.9).setFill()
        context.fill(NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: columnHeaderHeight))
        
        // Counter-flip for text drawing
        context.saveGState()
        let textCenterY = rect.minY + columnHeaderHeight / 2
        context.translateBy(x: 0, y: textCenterY)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -textCenterY)
        
        let headerFont = contentFont(ofSize: 9, weight: .medium)
        let headerColor = colors.normalText.withAlphaComponent(0.7)
        let sortedHeaderColor = colors.normalText.withAlphaComponent(0.9)
        let separatorColor = colors.normalText.withAlphaComponent(0.2)
        
        var x = rect.minX + 4 - horizontalScrollOffset
        for (index, column) in columns.enumerated() {
            let width = widthForColumn(column, availableWidth: totalWidth, columns: columns, group: group)
            let isCenteredRadioColumn = (model.browseMode == .radio && column.id == "genre") ||
                (model.hasInternetRadioColumns && column.id == "rating")
            
            // Check if this column is the sort column
            let isSortColumn = model.activeColumnSortId == column.id
            
            let attrs: [NSAttributedString.Key: Any] = [
                .font: headerFont,
                .foregroundColor: isSortColumn ? sortedHeaderColor : headerColor
            ]
            
            let textSize = column.title.size(withAttributes: attrs)
            let textY = rect.minY + (columnHeaderHeight - textSize.height) / 2
            
            let textX = isCenteredRadioColumn ? (x + (width - textSize.width) / 2) : (x + 4)
            column.title.draw(at: NSPoint(x: textX, y: textY), withAttributes: attrs)
            
            // Draw sort indicator if this is the sorted column
            if isSortColumn {
                let indicator = model.activeColumnSortAscending ? "▲" : "▼"
                let indicatorAttrs: [NSAttributedString.Key: Any] = [
                    .font: contentFont(ofSize: 7),
                    .foregroundColor: sortedHeaderColor
                ]
                let indicatorX = textX + textSize.width + 3
                indicator.draw(at: NSPoint(x: indicatorX, y: textY + 1), withAttributes: indicatorAttrs)
            }
            
            // Draw column separator (except for last column)
            if index < columns.count - 1 {
                context.saveGState()
                context.setStrokeColor(separatorColor.cgColor)
                context.setLineWidth(1)
                context.move(to: CGPoint(x: x + width - 1, y: rect.minY + 3))
                context.addLine(to: CGPoint(x: x + width - 1, y: rect.minY + columnHeaderHeight - 3))
                context.strokePath()
                context.restoreGState()
            }
            
            x += width
        }
        
        context.restoreGState()
        
        // Bottom separator line
        context.setStrokeColor(colors.normalText.withAlphaComponent(0.3).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: rect.minX, y: rect.minY + columnHeaderHeight))
        context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + columnHeaderHeight))
        context.strokePath()
        
        // Restore clipping context
        context.restoreGState()
    }
    
    /// Draw a single row with columns
    private func drawColumnRow(item: LibraryBrowserItem, columns: [LibraryBrowserColumn], group: LibraryColumnVisibilityGroup?,
                               in context: CGContext, rect: NSRect, isSelected: Bool, colors: PlaylistColors, indent: CGFloat = 0) {
        let totalWidth = rect.width
        
        // Counter-flip for text drawing
        context.saveGState()
        let textCenterY = rect.midY
        context.translateBy(x: 0, y: textCenterY)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -textCenterY)
        
        let textColor = isSelected ? colors.selectedText : colors.normalText
        let dimColor = isSelected ? colors.selectedText : colors.normalText.withAlphaComponent(0.65)
        let font = contentFont(ofSize: 10)
        let smallFont = contentFont(ofSize: 9)
        
        let hasArtColumn = columns.contains { $0.id == "thumbnail" }
        let cells = LibraryColumnVisibility.cellFrames(
            widths: columns.map { widthForColumn($0, availableWidth: totalWidth, columns: columns, group: group) },
            titleIndex: columns.firstIndex { $0.id == "title" }, indent: indent,
            spansLeadingCells: model.columnGroup(for: item) != group)
        for (column, cell) in zip(columns, cells) {
            let x = rect.minX + cell.start - horizontalScrollOffset, width = cell.width
            if column.id == "thumbnail" {
                // Inside the counter-flip (y-up), centred on the row so the flip doesn't move it.
                if let thumbnail = rowThumbnailSource(for: item) {
                    rowThumbnails.draw(thumbnail, in: context, at: x + 4, rowRect: rect, side: min(width - 8, rect.height - 2))
                }
                continue
            }
            let value = column.id == "title" ? item.shownTitle : item.columnValue(for: column)
            let isCenteredRadioColumn = (model.browseMode == .radio && column.id == "genre") ||
                (model.isInternetRadioItem(item) && column.id == "rating")
            
            // Title column uses normal color/font, others use dim color/smaller font
            let color = column.id == "title" ? textColor : dimColor
            let useFont = column.id == "title" ? font : smallFont
            
            let attrs: [NSAttributedString.Key: Any] = [
                .font: useFont,
                .foregroundColor: color
            ]

            // Per-row download spinner on the title column of a downloading YouTube video.
            var titleSpinnerInset: CGFloat = 0
            if column.id == "title", case .youtubeVideo(let video) = item.type,
               youtubeVideoActions.isFetching(video.videoId) {
                let spinnerRadius = min(rect.height * 0.3, 6)
                let cx = x + 4 + spinnerRadius
                drawRowSpinner(in: context, center: CGPoint(x: cx, y: rect.midY), radius: spinnerRadius, colors: colors)
                titleSpinnerInset = spinnerRadius * 2 + 4
            }
            // Round art ahead of the title, unless the row has an Art column to hold it.
            if column.id == "title", !hasArtColumn, let thumbnail = rowThumbnailSource(for: item) {
                titleSpinnerInset += rowThumbnails.draw(thumbnail, in: context, at: x + 4 + titleSpinnerInset,
                                                        rowRect: rect, side: rect.height - 2)
            }

            let textSize = value.size(withAttributes: attrs)
            let textY = rect.minY + (rect.height - textSize.height) / 2

            let textX = isCenteredRadioColumn ? (x + (width - textSize.width) / 2) : (x + 4 + titleSpinnerInset)
            let maxTextWidth = width - 8 - titleSpinnerInset  // Padding on both sides
            
            // Draw with truncation if needed
            let drawRect = NSRect(x: textX, y: textY, width: maxTextWidth, height: textSize.height)
            if column.id == "rating" && !isSelected && (value.contains("★") || value.contains("☆")) {
                let goldColor = NSColor(calibratedRed: 0.98, green: 0.78, blue: 0.20, alpha: 1.0)
                let emptyColor = dimColor.withAlphaComponent(0.4)
                let astr = NSMutableAttributedString(string: value, attributes: attrs)
                for (i, ch) in value.enumerated() {
                    let range = NSRange(location: i, length: 1)
                    astr.addAttribute(.foregroundColor, value: ch == "★" ? goldColor : emptyColor, range: range)
                }
                astr.draw(with: drawRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            } else {
                value.draw(with: drawRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
            }
        }
        
        context.restoreGState()
    }
    
    private func drawAlphabetIndex(in context: CGContext, rect: NSRect, colors: PlaylistColors, renderer: SkinRenderer) {
        // Background
        colors.normalBackground.withAlphaComponent(0.3).setFill()
        context.fill(rect)
        
        // Calculate letter height based on available space
        let letterCount = CGFloat(alphabetLetters.count)
        let letterHeight = rect.height / letterCount
        let fontSize = min(9 * contentScale, letterHeight * 0.8)
        
        // Build set of sort letters that exist in current items
        var availableLetters = Set<String>()
        if model.currentSource == .local && model.browseMode == .artists {
            availableLetters = Set(model.localArtistLetterOffsets.keys)
        } else if model.currentSource == .local && model.browseMode == .albums {
            availableLetters = Set(model.localAlbumLetterOffsets.keys)
        } else {
            for item in model.displayItems {
                availableLetters.insert(LibraryBrowserModel.effectiveSortLetter(for: item))
            }
        }
        
        for (index, letter) in alphabetLetters.enumerated() {
            let y = rect.minY + CGFloat(index) * letterHeight
            let letterRect = NSRect(x: rect.minX, y: y, width: rect.width, height: letterHeight)
            
            // Highlight if this letter has items
            let hasItems = availableLetters.contains(letter)
            let color = hasItems ? colors.currentText : colors.normalText.withAlphaComponent(0.3)
            
            // Counter-flip for text
            context.saveGState()
            let centerY = letterRect.midY
            context.translateBy(x: 0, y: centerY)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: 0, y: -centerY)
            
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold)
            ]
            
            let letterSize = letter.size(withAttributes: attrs)
            let drawPoint = NSPoint(
                x: letterRect.midX - letterSize.width / 2,
                y: letterRect.midY - letterSize.height / 2
            )
            letter.draw(at: drawPoint, withAttributes: attrs)
            
            context.restoreGState()
        }
    }
    
    private func drawStatusBarText(in context: CGContext, drawBounds: NSRect, colors: PlaylistColors, renderer: SkinRenderer) {
        // Status info is now shown in the top server bar
        // This function is kept for potential future use but draws nothing
    }
    
    // MARK: - Loading Animation
    
    private func startLoadingAnimation() {
        guard loadingAnimationTimer == nil else { return }
        // Use .common run loop mode so timer continues during context menu display
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.loadingAnimationFrame += 1
            if self.model.isLoading || self.youtubeVideoActions.hasFetchesInFlight || YouTubeChannelUploads.shared.hasFetchesInFlight {
                // Only redraw the list area where the loading spinner is displayed
                // This prevents menu items from shimmering on non-Retina displays
                let area = self.listLayout().area
                self.setNeedsDisplay(self.convertFromSkinCoordinates(
                    NSRect(x: 0, y: area.minY, width: self.bounds.width, height: area.height)))
            } else if self.isLibraryScanning {
                // Redraw server bar only for the scan spinner
                let nativeY = self.bounds.height - self.Layout.titleBarHeight - self.Layout.serverBarHeight
                self.setNeedsDisplay(NSRect(x: 0, y: nativeY, width: self.bounds.width, height: self.Layout.serverBarHeight))
            } else {
                self.stopLoadingAnimation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        loadingAnimationTimer = timer
    }

    private func stopLoadingAnimation() {
        guard !isLibraryScanning && !youtubeVideoActions.hasFetchesInFlight && !YouTubeChannelUploads.shared.hasFetchesInFlight else { return }
        loadingAnimationTimer?.invalidate()
        loadingAnimationTimer = nil
        loadingAnimationFrame = 0
    }

    @objc private func connectedWindowHighlightDidChange(_ notification: Notification) {
        let highlighted = notification.userInfo?["highlightedWindows"] as? Set<NSWindow> ?? []
        let newValue = highlighted.contains { $0 === window }
        if isHighlighted != newValue {
            isHighlighted = newValue
            needsDisplay = true
        }
    }

    @objc private func libraryScanProgressChanged() {
        let scanning = MediaLibrary.shared.isScanning
        guard scanning != isLibraryScanning else { return }
        isLibraryScanning = scanning
        if scanning {
            startLoadingAnimation()
        } else {
            if !model.isLoading { stopLoadingAnimation() }
            needsDisplay = true
        }
    }

    /// Returns the display name of the currently relevant Jellyfin library based on browse mode.
    private var jellyfinCurrentLibraryName: String {
        let manager = JellyfinManager.shared
        switch model.browseMode {
        case .movies:
            return manager.currentMovieLibrary?.name ?? "All"
        case .shows:
            return manager.currentShowLibrary?.name ?? "All"
        default:
            return manager.currentMusicLibrary?.name ?? "All"
        }
    }

    /// Returns the display name of the currently relevant Emby library based on browse mode.
    private var embyCurrentLibraryName: String {
        let manager = EmbyManager.shared
        switch model.browseMode {
        case .movies:
            return manager.currentMovieLibrary?.name ?? "All"
        case .shows:
            return manager.currentShowLibrary?.name ?? "All"
        default:
            return manager.currentMusicLibrary?.name ?? "All"
        }
    }

    // MARK: - Server Name Scroll Animation
    
    private func startServerNameScroll() {
        guard serverScrollTimer == nil else { return }
        serverScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.067, repeats: true) { [weak self] _ in
            self?.handleServerNameScrollTick()
        }
    }
    
    private func stopServerNameScroll() {
        serverScrollTimer?.invalidate()
        serverScrollTimer = nil
        serverNameScrollOffset = 0
        libraryNameScrollOffset = 0
    }
    
    private func handleServerNameScrollTick() {
        guard let window = window,
              window.isVisible,
              window.occlusionState.contains(.visible) else { return }
        updateServerNameScroll()
    }
    
    private func updateServerNameScroll() {
        let serverBarArea = NSRect(x: 0, y: bounds.height - Layout.titleBarHeight - Layout.serverBarHeight,
                                   width: bounds.width, height: Layout.serverBarHeight)
        // The cycles are drawServerBar's: zero unless a server's name overflows its field.
        let serverNeedsScroll = serverNameCycleWidth > 0
        let libraryNeedsScroll = libraryNameCycleWidth > 0
        if !serverNeedsScroll && !libraryNeedsScroll {
            let hadOffset = serverNameScrollOffset != 0 || libraryNameScrollOffset != 0
            stopServerNameScroll()
            if hadOffset { setNeedsDisplay(serverBarArea) }
            return
        }

        if serverNeedsScroll {
            serverNameScrollOffset += 1
            if serverNameScrollOffset >= serverNameCycleWidth { serverNameScrollOffset = 0 }
        } else {
            serverNameScrollOffset = 0
        }
        if libraryNeedsScroll {
            libraryNameScrollOffset += 1
            if libraryNameScrollOffset >= libraryNameCycleWidth { libraryNameScrollOffset = 0 }
        } else {
            libraryNameScrollOffset = 0
        }
        setNeedsDisplay(serverBarArea)
    }
    
    // MARK: - Public Methods
    
    func skinDidChange() {
        refreshHistoryHostingColors()
        artLens.restyle()
        updateHistoryHostingFrame()
        needsDisplay = true
    }

    private func refreshHistoryHostingColors() {
        guard let historyHostingView else { return }
        let colors = currentPlaylistColors()
        historyHostingView.rootView = makeHistoryRootView(colors)
        historyHostingView.layer?.backgroundColor = colors.normalBackground.cgColor
        historyHostingView.appearance = classicAppearance(for: colors.normalBackground)
    }

    @objc private func playHistoryDidChange() {
        Task { @MainActor [weak self] in
            guard let self, self.model.browseMode.isHistoryMode else { return }
            self.historyAgent.scheduleRefresh()
        }
    }
    
    
    /// A `.wal` skin switched colour theme; the style is re-derived on each draw, so a repaint is
    /// the whole job.
    @objc private func hostedSurfaceStyleDidChange() {
        hasResolvedWindowWinampModernStyle = false
        // A colour-theme switch recolours the Data tab too. Classic windows resolve no style, and
        // their Data tab is recoloured by `skinDidChange` instead.
        if winampModernStyle != nil { refreshHistoryHostingColors() }
        // The palette resolved for Flow / Tiles may predate this style (a switch into `.wmz`).
        artLens.restyle()
        // A borrowed frame moves the content hole this view lays its list and its controls out
        // from, and it lands after the first layout pass — see the same note on the rest of the
        // hosted family (W220).
        needsLayout = true
        needsDisplay = true
    }

    // MARK: - Artwork Background
    
    @objc private func trackDidChange(_ notification: Notification) {
        let track = notification.userInfo?["track"] as? Track

        guard WindowManager.shared.showBrowserArtworkBackground else {
            // Clear artwork if feature is disabled
            if currentArtwork != nil {
                currentArtwork = nil
                artworkTrackId = nil
                needsDisplay = true
            }
            return
        }
        
        loadArtwork(for: track)
    }
    
    /// Load artwork for a track (Plex or local)
    private func loadArtwork(for track: Track?) {
        // Cancel any pending load
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
        
        guard let track = track else {
            // No track playing - keep selection artwork (if any), just clear track ID
            // This allows Plex Radio selection artwork to persist when nothing is playing
            artworkTrackId = nil
            return
        }
        
        // Skip if same track
        guard track.id != artworkTrackId else { return }
        
        // Don't clear artwork immediately - wait until new image is ready
        // This prevents the "flash and disappear" when switching from selection artwork to track artwork
        
        artworkLoadTask = Task { [weak self] in
            guard let self = self else { return }
            
            var image: NSImage?
            
            if let plexRatingKey = track.plexRatingKey {
                // Plex track - load from server
                // Pass track.artworkThumb directly - it's more reliable than searching caches
                image = await self.loadPlexArtwork(ratingKey: plexRatingKey, albumName: track.album, thumbPath: track.artworkThumb)
                
                // Fallback to TMDb for video tracks when Plex artwork fails
                if image == nil && track.mediaType == .video {
                    // Parse year from title if present (e.g., "Movie Name (2023)")
                    var movieTitle = track.title
                    var movieYear: Int?
                    if let range = movieTitle.range(of: #"\s*\(\d{4}\)\s*$"#, options: .regularExpression) {
                        let yearString = String(movieTitle[range]).trimmingCharacters(in: .whitespaces)
                        movieYear = Int(yearString.trimmingCharacters(in: CharacterSet(charactersIn: "()")))
                        movieTitle = String(movieTitle[..<range.lowerBound])
                    }
                    image = await self.loadMovieWebArtwork(title: movieTitle, year: movieYear)
                }
            } else if let subsonicId = track.subsonicId {
                // Subsonic track - load from server
                image = await self.loadSubsonicArtwork(songId: subsonicId, albumName: track.album)
            } else if track.jellyfinId != nil {
                // Jellyfin track - load from server
                if let itemId = track.artworkThumb { image = await self.loadJellyfinArtwork(itemId: itemId) }
            } else if track.embyId != nil {
                // Emby track - load from server
                if let itemId = track.artworkThumb { image = await self.loadEmbyArtwork(itemId: itemId) }
            } else if track.url.isFileURL {
                // Local file - extract embedded artwork
                image = await self.loadLocalArtwork(url: track.url)
                
                // If no embedded artwork, try fetching from web
                if image == nil {
                    if track.mediaType == .video {
                        // Video file - try TMDb
                        image = await self.loadMovieWebArtwork(title: track.title, year: nil)
                    } else {
                        // Audio file - try iTunes
                        image = await self.loadWebArtwork(artist: track.artist, album: track.album, title: track.title)
                    }
                }
            } else if RadioManager.shared.isActive {
                // Internet radio - use station icon URL or favicon fallback
                image = await self.loadRadioArtwork(for: track)
            } else if let thumb = track.artworkThumb {
                // Generic remote artwork URL fallback
                image = await self.loadRemoteArtwork(urlString: thumb, cacheNamespace: "generic")
            }
            
            // Check if task was cancelled
            guard !Task.isCancelled else { return }
            
            await MainActor.run {
                guard WindowManager.shared.audioEngine.currentTrack?.id == track.id else { return }
                self.currentArtwork = image
                self.artworkTrackId = track.id
                self.needsDisplay = true
            }
        }
    }
    
    /// Load artwork from web using iTunes Search API
    private func loadWebArtwork(artist: String?, album: String?, title: String?) async -> NSImage? {
        // Build search query - prefer album search, fall back to track
        var searchTerm: String
        if let artist = artist, !artist.isEmpty, let album = album, !album.isEmpty {
            searchTerm = "\(artist) \(album)"
        } else if let artist = artist, !artist.isEmpty, let title = title, !title.isEmpty {
            searchTerm = "\(artist) \(title)"
        } else if let album = album, !album.isEmpty {
            searchTerm = album
        } else {
            return nil
        }
        
        // Check cache first
        let cacheKey = NSString(string: "web:\(searchTerm)")
        if let cached = Self.artworkCache.object(forKey: cacheKey) {
            return cached
        }
        
        // URL encode the search term
        guard let encoded = searchTerm.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        
        // Use iTunes Search API
        let urlString = "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=album&limit=1"
        guard let url = URL(string: urlString) else { return nil }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            
            // Parse JSON response
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = json["results"] as? [[String: Any]],
               let firstResult = results.first,
               let artworkUrlString = firstResult["artworkUrl100"] as? String {
                
                // Get higher resolution artwork (600x600 instead of 100x100)
                let highResUrl = artworkUrlString.replacingOccurrences(of: "100x100", with: "600x600")
                
                if let artworkUrl = URL(string: highResUrl) {
                    let (imageData, _) = try await URLSession.shared.data(from: artworkUrl)
                    if let image = NSImage(data: imageData) {
                        // Cache the result
                        Self.artworkCache.setObject(image, forKey: cacheKey)
                        NSLog("PlexBrowserView: Loaded web artwork for: %@", searchTerm)
                        return image
                    }
                }
            }
        } catch {
            NSLog("PlexBrowserView: Failed to load web artwork: %@", error.localizedDescription.redactingSensitiveURLQueryItems)
        }
        
        return nil
    }
    
    /// Load artwork for a Plex track using its rating key
    /// - Parameters:
    ///   - ratingKey: The track's Plex rating key
    ///   - albumName: Optional album name for fallback lookup
    ///   - thumbPath: Optional thumb path from the track itself (most reliable source)
    private func loadPlexArtwork(ratingKey: String, albumName: String? = nil, thumbPath providedThumb: String? = nil) async -> NSImage? {
        // Check cache first
        let cacheKey = NSString(string: "plex:\(ratingKey)")
        if let cached = Self.artworkCache.object(forKey: cacheKey) {
            return cached
        }
        
        // Use provided thumb path first (from track.artworkThumb) - this is the most reliable
        // because it's the exact path the Plex API returned for this track
        var thumbPath: String? = providedThumb
        
        // Check album tracks cache
        if thumbPath == nil {
            for (_, tracks) in model.plex.albumTracks {
                if let plexTrack = tracks.first(where: { $0.id == ratingKey }) {
                    thumbPath = plexTrack.thumb
                    break
                }
            }
        }
        
        // Check cached albums by ID
        if thumbPath == nil {
            if let album = model.plex.albums.first(where: { $0.id == ratingKey }) {
                thumbPath = album.thumb
            }
        }
        
        // Try to find album by name (fallback when track not in cache)
        if thumbPath == nil, let albumName = albumName, !albumName.isEmpty {
            if let album = model.plex.albums.first(where: { $0.title.lowercased() == albumName.lowercased() }) {
                thumbPath = album.thumb
                NSLog("PlexBrowserView: Found album art by name match: %@", albumName)
            }
        }
        
        // If still not found, construct the thumb path directly from the rating key
        // Plex allows fetching artwork using /library/metadata/{ratingKey}/thumb
        if thumbPath == nil {
            thumbPath = "/library/metadata/\(ratingKey)/thumb"
            NSLog("PlexBrowserView: Using direct rating key path for artwork: %@", ratingKey)
        }
        
        guard let thumb = thumbPath,
              let artworkURL = PlexManager.shared.artworkURL(thumb: thumb, size: 400) else {
            NSLog("PlexBrowserView: Could not construct artwork URL for rating key: %@", ratingKey)
            return nil
        }
        
        NSLog("PlexBrowserView: Loading artwork from: %@", artworkURL.redacted)
        
        // Download the image
        do {
            var request = URLRequest(url: artworkURL)
            // Add Plex headers if needed
            if let headers = PlexManager.shared.streamingHeaders {
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                NSLog("PlexBrowserView: Non-HTTP response for artwork")
                return nil
            }
            
            guard httpResponse.statusCode == 200 else {
                NSLog("PlexBrowserView: Artwork request failed with status: %d", httpResponse.statusCode)
                return nil
            }
            
            guard let image = NSImage(data: data) else {
                NSLog("PlexBrowserView: Could not create image from data (%d bytes)", data.count)
                return nil
            }
            
            // Cache the image
            Self.artworkCache.setObject(image, forKey: cacheKey)
            NSLog("PlexBrowserView: Successfully loaded artwork for rating key: %@", ratingKey)
            
            return image
        } catch {
            NSLog("PlexBrowserView: Failed to load Plex artwork: %@", error.localizedDescription.redactingSensitiveURLQueryItems)
            return nil
        }
    }
    
    /// Load cover art from a Subsonic server
    private func loadSubsonicArtwork(songId: String, albumName: String? = nil) async -> NSImage? {
        // Check cache first
        let cacheKey = NSString(string: "subsonic:\(songId)")
        if let cached = Self.artworkCache.object(forKey: cacheKey) {
            return cached
        }
        
        // Find the cover art ID from cached data
        var coverArtId: String?
        
        // Check cached albums for this song
        for (_, songs) in model.subsonic.albumSongs {
            if let song = songs.first(where: { $0.id == songId }) {
                coverArtId = song.coverArt
                break
            }
        }
        
        // Check cached albums by name
        if coverArtId == nil, let albumName = albumName {
            if let album = model.subsonic.albums.first(where: { $0.name == albumName }) {
                coverArtId = album.coverArt
            }
        }
        
        // Try using the song ID as cover art ID (some servers support this)
        if coverArtId == nil {
            coverArtId = songId
        }
        
        guard let artworkURL = SubsonicManager.shared.coverArtURL(coverArtId: coverArtId, size: 400) else {
            NSLog("PlexBrowserView: Could not construct Subsonic artwork URL for song: %@", songId)
            return nil
        }
        
        NSLog("PlexBrowserView: Loading Subsonic artwork from: %@", artworkURL.redacted)
        
        // Download the image
        do {
            let (data, response) = try await URLSession.shared.data(from: artworkURL)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                NSLog("PlexBrowserView: Non-HTTP response for Subsonic artwork")
                return nil
            }
            
            guard httpResponse.statusCode == 200 else {
                NSLog("PlexBrowserView: HTTP %d for Subsonic artwork", httpResponse.statusCode)
                return nil
            }
            
            guard let image = NSImage(data: data) else {
                NSLog("PlexBrowserView: Could not create image from Subsonic artwork data")
                return nil
            }
            
            // Cache the image
            Self.artworkCache.setObject(image, forKey: cacheKey)
            
            return image
        } catch {
            NSLog("PlexBrowserView: Failed to load Subsonic artwork: %@", error.localizedDescription.redactingSensitiveURLQueryItems)
            return nil
        }
    }
    
    /// Load embedded artwork from a local audio file
    private func loadLocalArtwork(url: URL) async -> NSImage? {
        // Check cache first
        let cacheKey = NSString(string: "local:\(url.path)")
        if let cached = Self.artworkCache.object(forKey: cacheKey) {
            return cached
        }
        
        // Extract artwork using AVFoundation
        let asset = AVURLAsset(url: url)
        
        do {
            let metadata = try await asset.load(.metadata)
            
            for item in metadata {
                // Check for artwork in common metadata
                if item.commonKey == .commonKeyArtwork {
                    if let data = try await item.load(.dataValue),
                       let image = NSImage(data: data) {
                        // Cache the image
                        Self.artworkCache.setObject(image, forKey: cacheKey)
                        return image
                    }
                }
            }
            
            // Also check ID3 metadata format
            let id3Metadata = try await asset.loadMetadata(for: .id3Metadata)
            for item in id3Metadata {
                if item.commonKey == .commonKeyArtwork {
                    if let data = try await item.load(.dataValue),
                       let image = NSImage(data: data) {
                        Self.artworkCache.setObject(image, forKey: cacheKey)
                        return image
                    }
                }
            }
            
            // Check iTunes metadata format
            let itunesMetadata = try await asset.loadMetadata(for: .iTunesMetadata)
            for item in itunesMetadata {
                if item.commonKey == .commonKeyArtwork {
                    if let data = try await item.load(.dataValue),
                       let image = NSImage(data: data) {
                        Self.artworkCache.setObject(image, forKey: cacheKey)
                        return image
                    }
                }
            }
        } catch {
            NSLog("PlexBrowserView: Failed to load local artwork: %@", error.localizedDescription.redactingSensitiveURLQueryItems)
        }
        
        return nil
    }

    private func loadRemoteArtwork(urlString: String, cacheNamespace: String) async -> NSImage? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }

        let cacheKey = NSString(string: "\(cacheNamespace):\(trimmed)")
        if let cached = Self.artworkCache.object(forKey: cacheKey) { return cached }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let mime = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            let looksLikeIcon = url.path.lowercased().hasSuffix(".ico") || mime.contains("icon")
            guard mime.contains("image") || looksLikeIcon else { return nil }
            guard let image = NSImage(data: data) else { return nil }
            Self.artworkCache.setObject(image, forKey: cacheKey)
            return image
        } catch {
            return nil
        }
    }

    private func loadRadioArtwork(for track: Track, station: RadioStation? = nil) async -> NSImage? {
        if let thumb = track.artworkThumb,
           let image = await loadRemoteArtwork(urlString: thumb, cacheNamespace: "radio") {
            return image
        }

        let activeStation = station ?? RadioManager.shared.currentStation
        if let iconURL = activeStation?.iconURL?.absoluteString,
           let image = await loadRemoteArtwork(urlString: iconURL, cacheNamespace: "radio") {
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
            if let image = await loadRemoteArtwork(urlString: candidate, cacheNamespace: "radio-favicon") {
                return image
            }
        }

        return nil
    }
    
    /// Load artwork based on the currently selected item in the browser
    /// Called when selection changes to show artwork for browsed items (not just playing items)
    private func loadArtworkForSelection() {
        guard WindowManager.shared.showBrowserArtworkBackground else { return }
        guard let index = selectedIndices.first, index < model.displayItems.count else { return }
        
        let item = model.displayItems[index]
        
        // Cancel any pending load
        artworkLoadTask?.cancel()
        
        artworkLoadTask = Task { [weak self] in
            guard let self = self else { return }
            
            var image: NSImage?
            
            switch item.type {
            case .movie, .episode, .album, .artist, .show, .season, .track, .localAlbum,
                 .subsonicTrack, .subsonicAlbum, .subsonicArtist,
                 .jellyfinTrack, .jellyfinAlbum, .jellyfinArtist, .jellyfinMovie, .jellyfinShow, .jellyfinSeason, .jellyfinEpisode,
                 .embyTrack, .embyAlbum, .embyArtist, .embyMovie, .embyShow, .embySeason, .embyEpisode:
                image = await self.itemArtwork(for: item).load()

            case .localTrack(let track):
                image = await self.loadLocalArtwork(url: track.url)
                if image == nil {
                    image = await self.loadWebArtwork(artist: track.artist, album: track.album, title: track.title)
                }
                
            case .localArtist(let artist):
                // Load artwork from first track by this artist
                let firstTrack = await Task.detached {
                    MediaLibraryStore.shared.searchTracks(query: artist.name, limit: 1, offset: 0).first
                }.value
                if let firstTrack {
                    image = await self.loadLocalArtwork(url: firstTrack.url)
                    if image == nil {
                        image = await self.loadWebArtwork(artist: firstTrack.artist, album: firstTrack.album, title: firstTrack.title)
                    }
                }
                
            case .subsonicPlaylist(let playlist):
                if let coverArt = playlist.coverArt {
                    image = await self.loadSubsonicArtworkByCoverId(coverArt: coverArt, cacheKey: "subsonic:playlist:\(playlist.id)")
                }
                
            case .jellyfinPlaylist(let playlist):
                image = await self.jellyfinArtwork(playlist.artworkItemId).load()

            case .embyPlaylist(let playlist):
                image = await self.embyArtwork(playlist.artworkItemId).load()

            case .plexPlaylist(let playlist):
                if let thumb = playlist.thumb {
                    image = await self.loadPlexArtworkByThumb(thumb: thumb, cacheKey: "plex:playlist:\(playlist.id)")
                }
                
            case .localMovie, .localShow, .localSeason, .localEpisode:
                // Video artwork is loaded during playback via AVAssetImageGenerator
                break

            case .localFolder:
                // Folder rows have no artwork
                break

            case .radioStation(let station):
                let radioTrack = station.toTrack()
                image = await self.loadRadioArtwork(for: radioTrack, station: station)
            case .youtubeVideo(let video):
                // A download carries its own embedded art; otherwise the 16:9 thumbnail.
                if let fileURL = YouTubeManager.shared.coverArtFile(for: video.videoId) {
                    image = await self.loadLocalArtwork(url: fileURL)
                }
                if image == nil, let thumb = video.thumbnailURL {
                    image = await self.loadRemoteArtwork(urlString: thumb.absoluteString, cacheNamespace: "youtube")
                }
                image = image?.squareCenterCropped()
            case .youtubeChannel(let channel):
                if let avatar = channel.avatarURL(side: 512) {
                    image = await self.loadRemoteArtwork(urlString: avatar.absoluteString, cacheNamespace: "youtube")?.squareCenterCropped()
                }
            case .localPlaylist, .localPlaylistTrack,
                 .plexRadioStation,
                 .subsonicRadioStation,
                 .jellyfinRadioStation,
                 .embyRadioStation,
                 .localRadioStation,
                 .radioFolder,
                 .header:
                break
            }

            guard !Task.isCancelled else { return }
            
            await MainActor.run {
                if image != nil {
                    self.currentArtwork = image
                    self.artworkTrackId = nil  // Clear track ID since this is from selection
                    self.needsDisplay = true
                }
            }
        }
    }
    
    /// Load artwork from Plex using a thumb path directly
    private func loadPlexArtworkByThumb(thumb: String, cacheKey: String) async -> NSImage? {
        // Check cache first
        let cacheNSKey = NSString(string: cacheKey)
        if let cached = Self.artworkCache.object(forKey: cacheNSKey) {
            return cached
        }
        
        guard let artworkURL = PlexManager.shared.artworkURL(thumb: thumb, size: 400) else {
            return nil
        }
        
        do {
            var request = URLRequest(url: artworkURL)
            if let headers = PlexManager.shared.streamingHeaders {
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let image = NSImage(data: data) else {
                return nil
            }
            
            Self.artworkCache.setObject(image, forKey: cacheNSKey)
            return image
        } catch {
            return nil
        }
    }
    
    /// Load artwork from Subsonic using a cover art ID directly
    private func loadSubsonicArtworkByCoverId(coverArt: String, cacheKey: String) async -> NSImage? {
        // Check cache first
        let cacheNSKey = NSString(string: cacheKey)
        if let cached = Self.artworkCache.object(forKey: cacheNSKey) {
            return cached
        }
        
        guard let artworkURL = SubsonicManager.shared.coverArtURL(coverArtId: coverArt, size: 400) else {
            return nil
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(from: artworkURL)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let image = NSImage(data: data) else {
                return nil
            }
            
            Self.artworkCache.setObject(image, forKey: cacheNSKey)
            return image
        } catch {
            return nil
        }
    }
    
    /// Load the Primary image of a Jellyfin item (an `artworkItemId`)
    private func loadJellyfinArtwork(itemId: String) async -> NSImage? {
        let cacheKey = NSString(string: "jellyfin:\(itemId)")
        if let cached = Self.artworkCache.object(forKey: cacheKey) { return cached }
        guard let url = JellyfinManager.shared.imageURL(itemId: itemId, imageTag: nil, size: 400) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let image = NSImage(data: data) else { return nil }
            Self.artworkCache.setObject(image, forKey: cacheKey)
            return image
        } catch { return nil }
    }

    private func loadEmbyArtwork(itemId: String) async -> NSImage? {
        let cacheKey = NSString(string: "emby:\(itemId)")
        if let cached = Self.artworkCache.object(forKey: cacheKey) { return cached }
        guard let url = EmbyManager.shared.imageURL(itemId: itemId, imageTag: nil, size: 400) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let image = NSImage(data: data) else { return nil }
            Self.artworkCache.setObject(image, forKey: cacheKey)
            return image
        } catch { return nil }
    }
    
    /// Load movie poster from TMDb (The Movie Database) as fallback
    private func loadMovieWebArtwork(title: String, year: Int?) async -> NSImage? {
        // Build search query
        var searchTerm = title
        if let year = year {
            searchTerm += " \(year)"
        }
        
        // Check cache first
        let cacheKey = NSString(string: "tmdb:\(searchTerm)")
        if let cached = Self.artworkCache.object(forKey: cacheKey) {
            return cached
        }
        
        // URL encode the search term
        guard let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        
        // Use TMDb Search API
        // Note: This uses the public search endpoint which works without authentication for basic queries
        var urlString = "https://api.themoviedb.org/3/search/movie?query=\(encoded)"
        if let year = year {
            urlString += "&year=\(year)"
        }
        
        guard let url = URL(string: urlString) else { return nil }
        
        do {
            var request = URLRequest(url: url)
            // TMDb requires an API key - use the read-only public key for search
            // This is a standard read-only key that allows basic search functionality
            request.setValue("Bearer eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJlNjUyZmJjMjE3NTcxYTZjNzU4NmYwNzE1MWQ4ZmRjOCIsInN1YiI6IjY1YjUyYTc3MGYyZmJkMDE3YzQ0OGU1OSIsInNjb3BlcyI6WyJhcGlfcmVhZCJdLCJ2ZXJzaW9uIjoxfQ.tWcXq_3A4N4gP4Jz5MJNqVWfHBNZdEbwLZZGpZU9hTw", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            
            let (data, _) = try await URLSession.shared.data(for: request)
            
            // Parse JSON response
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = json["results"] as? [[String: Any]],
               let firstResult = results.first,
               let posterPath = firstResult["poster_path"] as? String {
                
                // Fetch poster image (w500 is a good size for display)
                let posterUrlString = "https://image.tmdb.org/t/p/w500\(posterPath)"
                
                if let posterUrl = URL(string: posterUrlString) {
                    let (imageData, _) = try await URLSession.shared.data(from: posterUrl)
                    if let image = NSImage(data: imageData) {
                        // Cache the result
                        Self.artworkCache.setObject(image, forKey: cacheKey)
                        NSLog("PlexBrowserView: Loaded TMDb poster for: %@", title)
                        return image
                    }
                }
            }
        } catch {
            NSLog("PlexBrowserView: Failed to load TMDb poster: %@", error.localizedDescription.redactingSensitiveURLQueryItems)
        }
        
        return nil
    }
    
    /// Calculate a centered fit rect for artwork - scales to fit entirely within bounds, centered
    private func calculateCenterFillRect(imageSize: NSSize, in targetRect: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return targetRect }
        
        let imageAspect = imageSize.width / imageSize.height
        let targetAspect = targetRect.width / targetRect.height
        
        var width: CGFloat
        var height: CGFloat
        
        if imageAspect > targetAspect {
            // Image is wider than target - fit to width, scale height proportionally
            width = targetRect.width
            height = width / imageAspect
        } else {
            // Image is taller than target - fit to height, scale width proportionally
            height = targetRect.height
            width = height * imageAspect
        }
        
        // Center the rect within the target
        let x = targetRect.minX + (targetRect.width - width) / 2
        let y = targetRect.minY + (targetRect.height - height) / 2
        
        return NSRect(x: x, y: y, width: width, height: height)
    }
    
    // MARK: - Hit Testing
    
    /// Check if point hits title bar (for dragging)
    private func hitTestTitleBar(at skinPoint: NSPoint) -> Bool {
        // Embedded: the skin owns the window frame, so there is no title bar of ours to grab and no
        // close button to press. Claiming those regions would eat clicks meant for the list.
        if isEmbeddedInSkin { return false }
        if hidesClassicTitleBar {
            // Invisible drag zone at the top of the visible window
            return skinPoint.y >= Layout.titleBarHeight && skinPoint.y < Layout.titleBarHeight + 6
        }
        let originalSize = originalWindowSize
        return skinPoint.y < Layout.titleBarHeight &&
               skinPoint.x < originalSize.width - 30  // Leave room for window buttons
    }
    
    /// Check if point hits close button (enlarged hit area extends to right edge and top)
    private func hitTestCloseButton(at skinPoint: NSPoint) -> Bool {
        if isEmbeddedInSkin { return false }
        if hidesClassicTitleBar { return false }
        let originalSize = originalWindowSize
        // 20x14 in our own flat chrome. Under a borrowed ring the column spans the skin's caption
        // band — 7px to 104px across the corpus — and sits inside its right border, which is where
        // the shared painter draws the glyph: what is clickable is what is drawn (W178).
        let closeRect = hostedFrame == nil && !closesFromCorner
            ? NSRect(x: originalSize.width - 20, y: 0, width: 20, height: 14)
            : SkinnedSurfaceChrome.closeButtonRect(in: NSRect(origin: .zero, size: originalSize),
                                                   captionHeight: Layout.titleBarHeight, width: 20)
        // The corner closes except where the server bar draws a control into it.
        if closesFromCorner, refreshButtonRect.contains(skinPoint) || viewModeButton(at: skinPoint) != nil {
            return false
        }
        return closeRect.contains(skinPoint)
    }

    private func viewModeButton(at skinPoint: NSPoint) -> LibraryViewMode? {
        viewModeButtonRects.first(where: { $0.rect.contains(skinPoint) })?.mode
    }

    /// Check if point is in server bar
    private func hitTestServerBar(at skinPoint: NSPoint) -> Bool {
        let serverBarY = Layout.titleBarHeight
        return skinPoint.y >= serverBarY && skinPoint.y < serverBarY + Layout.serverBarHeight
    }
    
    /// Check if point is in tab bar and return tab index
    private func hitTestTabBar(at skinPoint: NSPoint) -> LibraryBrowseMode? {
        let tabY = Layout.titleBarHeight + Layout.serverBarHeight
        guard skinPoint.y >= tabY && skinPoint.y < tabY + Layout.tabBarHeight else { return nil }

        for (index, rect) in tabButtonRects.enumerated()
        where rect.contains(skinPoint) && index < LibraryBrowseMode.tabs.count {
            return LibraryBrowseMode.tabs[index]
        }
        return nil
    }
    
    /// Check if point is in sort indicator area
    private func hitTestSortIndicator(at skinPoint: NSPoint) -> Bool {
        let tabY = Layout.titleBarHeight + Layout.serverBarHeight
        guard skinPoint.y >= tabY && skinPoint.y < tabY + Layout.tabBarHeight else { return false }
        return sortButtonRect.contains(skinPoint)
    }
    
    /// Check if point is in search bar
    private func hitTestSearchBar(at skinPoint: NSPoint) -> Bool {
        guard model.browseMode == .search else { return false }
        return skinPoint.y >= listTopY - Layout.searchBarHeight && skinPoint.y < listTopY
    }
    
    /// Check if point is in alphabet index
    private func hitTestAlphabetIndex(at skinPoint: NSPoint) -> Bool {
        guard !model.browseMode.isHistoryMode else { return false }
        return listLayout().alphabet.contains(skinPoint)
    }
    
    /// Check if point is in list area and return item index
    private func hitTestListArea(at skinPoint: NSPoint) -> Int? {
        guard !model.browseMode.isHistoryMode else { return nil }
        let rows = listLayout().rows
        guard rows.contains(skinPoint) else { return nil }
        
        let clickedIndex = Int((skinPoint.y - rows.minY + scrollOffset) / itemHeight)
        return model.displayItems.indices.contains(clickedIndex) ? clickedIndex : nil
    }

    private func hitTestInternetRadioRating(at skinPoint: NSPoint, itemIndex: Int) -> Int? {
        guard !model.browseMode.isHistoryMode else { return nil }
        guard model.hasInternetRadioColumns, itemIndex >= 0, itemIndex < model.displayItems.count else { return nil }
        let item = model.displayItems[itemIndex]
        let layout = listLayout()
        guard case .radioStation = item.type, let row = rowColumns(for: item, header: layout.header) else { return nil }

        let listRect = layout.rows
        let rowY = listRect.minY + CGFloat(itemIndex) * itemHeight - scrollOffset
        let rowRect = NSRect(x: listRect.minX, y: rowY, width: listRect.width, height: itemHeight)
        guard rowRect.contains(skinPoint) else { return nil }

        var x = rowRect.minX + 4 - horizontalScrollOffset
        for column in row.columns {
            let width = widthForColumn(column, availableWidth: rowRect.width, columns: row.columns, group: row.group)
            if column.id == "rating" {
                let cellRect = NSRect(x: x, y: rowRect.minY, width: width, height: rowRect.height)
                guard cellRect.contains(skinPoint) else { return nil }
                let innerWidth = max(1, cellRect.width - 8)
                let clampedX = min(max(skinPoint.x, cellRect.minX + 4), cellRect.maxX - 4)
                let normalized = (clampedX - (cellRect.minX + 4)) / innerWidth
                let star = min(5, max(1, Int(normalized * 5.0) + 1))
                return star
            }
            x += width
        }
        return nil
    }

    /// The column header when `skinPoint` is on it.
    private func columnHeader(at skinPoint: NSPoint) -> ListLayout.Header? {
        guard !model.browseMode.isHistoryMode, let header = listLayout().header, header.rect.contains(skinPoint) else { return nil }
        return header
    }
    
    /// Check if point hits a column resize handle (returns column id to resize)
    private func hitTestColumnResize(at skinPoint: NSPoint) -> String? {
        if model.hasInternetRadioColumns { return nil }
        guard let header = columnHeader(at: skinPoint) else { return nil }
        let columns = header.columns
        let group = header.group

        // Check if near a column separator (within 4 pixels)
        var x = header.rect.minX + 4
        let hitMargin: CGFloat = 4
        
        for (index, column) in columns.enumerated() {
            let width = widthForColumn(column, availableWidth: header.rect.width, columns: columns, group: group)
            let separatorX = x + width
            
            // YouTube's Time column is the final column, so resize it from its leading
            // edge (the separator after Title). Other groups keep their existing
            // trailing-edge resize behavior.
            if index < columns.count - 1,
               abs(skinPoint.x - separatorX) < hitMargin {
                if model.hasYouTubeColumns, column.id == "title" {
                    return columns[index + 1].id
                }
                if column.id != "title" {
                    return column.id
                }
            }
            x += width
        }
        
        return nil
    }
    
    /// Check if point hits a column header (returns column id for sorting)
    private func hitTestColumnHeader(at skinPoint: NSPoint) -> String? {
        guard let header = columnHeader(at: skinPoint) else { return nil }
        
        // Check if on a resize handle first (don't trigger sort)
        if hitTestColumnResize(at: skinPoint) != nil {
            return nil
        }

        let columns = header.columns
        let group = header.group
        
        // Find which column was clicked
        var x = header.rect.minX + 4
        
        for column in columns {
            let width = widthForColumn(column, availableWidth: header.rect.width, columns: columns, group: group)
            if skinPoint.x >= x && skinPoint.x < x + width {
                return column.id
            }
            x += width
        }
        
        return nil
    }

    private func hitTestColumnHeaderArea(at skinPoint: NSPoint) -> Bool {
        !model.hasInternetRadioColumns && columnHeader(at: skinPoint) != nil
    }
    
    // MARK: - Cursor Tracking
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        ))
    }
    
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let skinPoint = convertToSkinCoordinates(point)
        
        // Show resize cursor when over column resize handles
        if hitTestColumnResize(at: skinPoint) != nil {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
        let overList = hitTestListArea(at: skinPoint) != nil
        rowThumbnails.hover(at: overList ? skinPoint : nil) {
            window?.convertToScreen(convert(convertFromSkinCoordinates($0), to: nil))
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        RowThumbnailPreview.shared.hide()
    }
    
    // MARK: - Mouse Events
    
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
    
    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let skinPoint = convertToSkinCoordinates(point)
        
        // Right-click on column header: show column visibility menu
        if hitTestColumnHeaderArea(at: skinPoint) {
            showColumnConfigMenu(at: event)
            return
        }
        
        // Check list area for item context menu
        if !model.browseMode.isHistoryMode, let clickedIndex = hitTestListArea(at: skinPoint) {
            // Select the clicked item if not already selected
            if !selectedIndices.contains(clickedIndex) {
                selectedIndices = [clickedIndex]
                needsDisplay = true
            }
            
            let item = model.displayItems[clickedIndex]
            
            // Show context menu - uses search URLs as fallback for external links
            // Direct IMDB/TMDB links will be used if IDs are already available
            showContextMenu(for: item, at: event)
            return
        }
        
        // Local library empty-space right-click: show Manage Folders
        if !model.browseMode.isHistoryMode, case .local = model.currentSource {
            let menu = NSMenu()
            let manageFoldersItem = NSMenuItem(title: "Manage Folders...", action: #selector(manageWatchFolders), keyEquivalent: "")
            manageFoldersItem.target = self
            menu.addItem(manageFoldersItem)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        // Default right-click behavior
        super.rightMouseDown(with: event)
    }

    private func showColumnConfigMenu(at event: NSEvent) {
        if model.hasInternetRadioColumns { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        for group in columnGroupsForCurrentMenu() {
            addColumnVisibilityGroup(group, to: menu)
        }

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Only the header's own group: every row shows those columns, so nothing else is tickable.
    /// (This browser has never offered the fixed YouTube channel columns.)
    private func columnGroupsForCurrentMenu() -> [LibraryColumnVisibilityGroup] {
        guard let group = model.currentColumnGroup(), group != .youtube else { return [] }
        return [group]
    }

    private func addColumnVisibilityGroup(_ group: LibraryColumnVisibilityGroup, to menu: NSMenu) {
        if !menu.items.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }

        let header = NSMenuItem(title: group.headerTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let visibleIds = Set(model.visibleColumnIds(for: group))
        for column in LibraryBrowserColumn.all(for: group) {
            let item = NSMenuItem()
            item.view = ColumnVisibilityCheckboxView(
                title: column.title,
                isChecked: column.id == "title" || visibleIds.contains(column.id),
                isEnabled: column.id != "title"
            ) { [weak self] isVisible in
                self?.toggleColumnVisibility(group: group, columnId: column.id, visible: isVisible)
            }
            menu.addItem(item)
        }

        let resetItem = NSMenuItem(title: group.resetTitle, action: #selector(resetColumnGroup(_:)), keyEquivalent: "")
        resetItem.target = self
        resetItem.representedObject = group.rawValue
        menu.addItem(resetItem)
    }

    private func toggleColumnVisibility(group: LibraryColumnVisibilityGroup, columnId: String, visible: Bool) {
        guard columnId != "title" else { return }

        var ids = model.visibleColumnIds(for: group)
        if visible {
            if !ids.contains(columnId) {
                ids.append(columnId)
            }
        } else {
            ids.removeAll { $0 == columnId }
            LibraryBrowserTabSortStore.shared.dropColumn(columnId)
        }

        model.setVisibleColumnIds(ids, for: group)
        clampHorizontalScrollOffset()
        needsDisplay = true
    }

    @objc private func resetColumnGroup(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let group = LibraryColumnVisibilityGroup(rawValue: rawValue) else { return }

        model.setVisibleColumnIds(LibraryBrowserColumn.defaultIds(for: group), for: group)
        let prefix = "\(group.rawValue):"
        columnWidths = columnWidths.filter { !$0.key.hasPrefix(prefix) }
        clampHorizontalScrollOffset()
        needsDisplay = true
    }
    
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let skinPoint = convertToSkinCoordinates(point)
        
        // Check for column resize
        if let header = columnHeader(at: skinPoint), let columnId = hitTestColumnResize(at: skinPoint) {
            resizingColumnId = columnId
            resizingColumnGroup = header.group
            resizingColumnFromLeadingEdge = model.hasYouTubeColumns && columnId == "duration"
            resizeStartX = skinPoint.x
            resizeStartWidth = widthForColumn(
                LibraryBrowserColumn.findColumn(id: columnId) ?? .title,
                availableWidth: header.rect.width,
                columns: header.columns,
                group: resizingColumnGroup
            )
            NSCursor.resizeLeftRight.push()
            return
        }
        
        // Check for column header click (for sorting)
        if let columnId = hitTestColumnHeader(at: skinPoint) {
            model.sortByColumn(columnId)
            needsDisplay = true
            return
        }
        
        // Check window control buttons
        if hitTestCloseButton(at: skinPoint) {
            pressedButton = .close
            needsDisplay = true
            return
        }

        // Check server bar
        if hitTestServerBar(at: skinPoint) {
            if let mode = viewModeButton(at: skinPoint) {
                artLens.mode = mode
                needsDisplay = true
                return
            }
            // For local files, radio, or subsonic - always handle the click
            // For Plex - check if linked first
            if case .plex = model.currentSource, !PlexManager.shared.isLinked {
                presentLinkSheet()
            } else {
                handleServerBarClick(at: skinPoint, event: event)
            }
            return
        }

        // Check sort indicator (in tab bar area, on the right)
        if hitTestSortIndicator(at: skinPoint) {
            showSortMenu(at: event.locationInWindow)
            return
        }
        
        // Check tab bar
        if let slot = hitTestTabBar(at: skinPoint) {
            model.selectTab(slot, doubleClick: event.clickCount == 2)
            window?.makeFirstResponder(self)
            return
        }
        
        // Check search bar
        if hitTestSearchBar(at: skinPoint) {
            window?.makeFirstResponder(self)
            return
        }
        
        // Check alphabet index
        if hitTestAlphabetIndex(at: skinPoint) {
            handleAlphabetClick(at: skinPoint)
            return
        }
        
        // Check list area
        if let itemIndex = hitTestListArea(at: skinPoint) {
            handleListClick(at: itemIndex, event: event, skinPoint: skinPoint)
            return
        }
        
        // Title bar - start window drag (can undock)
        if hitTestTitleBar(at: skinPoint) {
            isDraggingWindow = true
            windowDragStartPoint = event.locationInWindow
            if let window = window {
                WindowManager.shared.windowWillStartDragging(window, fromTitleBar: true)
            }
        } else if isEmbeddedInSkin {
            embeddedWindowDrag.prime(event, window: window)
        }
    }
    private func handleServerBarClick(at skinPoint: NSPoint, event: NSEvent) {
        if refreshButtonRect.contains(skinPoint) {
            handleRefreshClick()
            return
        }

        switch model.currentSource {
        case .local:
            if addButtonRect.contains(skinPoint) { showAddFilesMenu(at: event) }
            else if sourceButtonRect.contains(skinPoint) { showSourceMenu(at: event) }
        case .plex:
            if libraryButtonRect.contains(skinPoint) { showLibraryMenu(at: event) }
            else if sourceButtonRect.contains(skinPoint) { showSourceMenu(at: event) }
        case .subsonic:
            if libraryButtonRect.contains(skinPoint) { showSubsonicFolderMenu(at: event) }
            else if sourceButtonRect.contains(skinPoint) { showSourceMenu(at: event) }
        case .jellyfin:
            if libraryButtonRect.contains(skinPoint) {
                if model.browseMode.isVideoMode {
                    showJellyfinVideoLibraryMenu(at: event)
                } else {
                    showJellyfinLibraryMenu(at: event)
                }
            } else if sourceButtonRect.contains(skinPoint) { showSourceMenu(at: event) }
        case .emby:
            if libraryButtonRect.contains(skinPoint) {
                if model.browseMode.isVideoMode {
                    showEmbyVideoLibraryMenu(at: event)
                } else {
                    showEmbyLibraryMenu(at: event)
                }
            } else if sourceButtonRect.contains(skinPoint) { showSourceMenu(at: event) }
        case .radio:
            if addButtonRect.contains(skinPoint) { showRadioAddMenu(at: event) }
            else if sourceButtonRect.contains(skinPoint) { showSourceMenu(at: event) }
        case .youtube:
            if addButtonRect.contains(skinPoint) { showYouTubeAddMenu(at: event) }
            else if sourceButtonRect.contains(skinPoint) { showSourceMenu(at: event) }
        }
    }
    

    /// Show the source selection dropdown menu
    private func showSourceMenu(at event: NSEvent) {
        let menu = NSMenu()
        
        // Local Files option
        let localItem = NSMenuItem(title: "Local Files", action: #selector(selectLocalSource), keyEquivalent: "")
        localItem.target = self
        if case .local = model.currentSource {
            localItem.state = .on
        }
        menu.addItem(localItem)
        menu.addItem(NSMenuItem.separator())
        
        // Internet Radio option
        let radioItem = NSMenuItem(title: "Internet Radio", action: #selector(selectRadioSource), keyEquivalent: "")
        radioItem.target = self
        if case .radio = model.currentSource {
            radioItem.state = .on
        }
        menu.addItem(radioItem)
        menu.addItem(NSMenuItem.separator())
        let youtubeItem = NSMenuItem(title: "YouTube", action: #selector(selectYouTubeSource), keyEquivalent: "")
        youtubeItem.target = self
        if case .youtube = model.currentSource {
            youtubeItem.state = .on
        }
        menu.addItem(youtubeItem)

        // Separator
        menu.addItem(NSMenuItem.separator())
        
        // Plex servers
        let plexServers = PlexManager.shared.servers
        if plexServers.isEmpty && !PlexManager.shared.isLinked {
            let linkItem = NSMenuItem(title: "Link Plex Account...", action: #selector(linkPlexAccount), keyEquivalent: "")
            linkItem.target = self
            menu.addItem(linkItem)
        } else {
            for server in plexServers {
                let serverItem = NSMenuItem(title: server.name, action: #selector(selectPlexServer(_:)), keyEquivalent: "")
                serverItem.target = self
                serverItem.representedObject = server.id
                if case .plex(let currentServerId) = model.currentSource, currentServerId == server.id {
                    serverItem.state = .on
                }
                menu.addItem(serverItem)
            }
        }
        
        // Subsonic/Navidrome servers
        let subsonicServers = SubsonicManager.shared.servers
        if !subsonicServers.isEmpty {
            menu.addItem(NSMenuItem.separator())
            for server in subsonicServers {
                let serverItem = NSMenuItem(title: "🎵 \(server.name)", action: #selector(selectSubsonicServer(_:)), keyEquivalent: "")
                serverItem.target = self
                serverItem.representedObject = server.id
                if case .subsonic(let currentServerId) = model.currentSource, currentServerId == server.id {
                    serverItem.state = .on
                }
                menu.addItem(serverItem)
            }
        } else {
            menu.addItem(NSMenuItem.separator())
            let addItem = NSMenuItem(title: "Add Navidrome/Subsonic...", action: #selector(addSubsonicServer), keyEquivalent: "")
            addItem.target = self
            menu.addItem(addItem)
        }
        
        // Jellyfin servers
        let jellyfinServers = JellyfinManager.shared.servers
        if !jellyfinServers.isEmpty {
            menu.addItem(NSMenuItem.separator())
            for server in jellyfinServers {
                let serverItem = NSMenuItem(title: "🟣 \(server.name)", action: #selector(selectJellyfinServer(_:)), keyEquivalent: "")
                serverItem.target = self
                serverItem.representedObject = server.id
                if case .jellyfin(let currentServerId) = model.currentSource, currentServerId == server.id {
                    serverItem.state = .on
                }
                menu.addItem(serverItem)
            }
        } else {
            menu.addItem(NSMenuItem.separator())
            let addItem = NSMenuItem(title: "Add Jellyfin Server...", action: #selector(addJellyfinServer), keyEquivalent: "")
            addItem.target = self
            menu.addItem(addItem)
        }

        // Emby servers
        let embyServers = EmbyManager.shared.servers
        if !embyServers.isEmpty {
            menu.addItem(NSMenuItem.separator())
            for server in embyServers {
                let serverItem = NSMenuItem(title: "🔵 \(server.name)", action: #selector(selectEmbyServer(_:)), keyEquivalent: "")
                serverItem.target = self
                serverItem.representedObject = server.id
                if case .emby(let currentServerId) = model.currentSource, currentServerId == server.id {
                    serverItem.state = .on
                }
                menu.addItem(serverItem)
            }
        } else {
            menu.addItem(NSMenuItem.separator())
            let addItem = NSMenuItem(title: "Add Emby Server...", action: #selector(addEmbyServer), keyEquivalent: "")
            addItem.target = self
            menu.addItem(addItem)
        }
        
        // Show menu
        let menuLocation = NSPoint(x: event.locationInWindow.x, y: event.locationInWindow.y - 5)
        menu.popUp(positioning: nil, at: menuLocation, in: window?.contentView)
    }
    
    /// Show the add files/folder menu
    private func showAddFilesMenu(at event: NSEvent) {
        let menu = NSMenu()
        
        let addFilesItem = NSMenuItem(title: "Add Files...", action: #selector(addFiles), keyEquivalent: "")
        addFilesItem.target = self
        menu.addItem(addFilesItem)
        
        let addVideoFilesItem = NSMenuItem(title: "Add Video Files...", action: #selector(addVideoFiles), keyEquivalent: "")
        addVideoFilesItem.target = self
        menu.addItem(addVideoFilesItem)

        let addFolderItem = NSMenuItem(title: "Add Folder...", action: #selector(addWatchFolder), keyEquivalent: "")
        addFolderItem.target = self
        menu.addItem(addFolderItem)

        let menuLocation = NSPoint(x: event.locationInWindow.x, y: event.locationInWindow.y - 5)
        menu.popUp(positioning: nil, at: menuLocation, in: window?.contentView)
    }

    /// Show the +ADD menu for radio mode
    private func showRadioAddMenu(at event: NSEvent) {
        let menu = NSMenu()
        
        let addStationItem = NSMenuItem(title: "Add Station...", action: #selector(showAddRadioStationDialog), keyEquivalent: "")
        addStationItem.target = self
        menu.addItem(addStationItem)

        let addFolderItem = NSMenuItem(title: "New Folder...", action: #selector(showCreateRadioFolderDialog), keyEquivalent: "")
        addFolderItem.target = self
        menu.addItem(addFolderItem)

        menu.addItem(NSMenuItem.separator())

        let addPlaylistItem = NSMenuItem(title: "Import Playlist URL...", action: #selector(showAddRadioPlaylistDialog), keyEquivalent: "")
        addPlaylistItem.target = self
        menu.addItem(addPlaylistItem)
        
        let importFileItem = NSMenuItem(title: "Import Playlist File...", action: #selector(importRadioPlaylistFile), keyEquivalent: "")
        importFileItem.target = self
        menu.addItem(importFileItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let addDefaultsItem = NSMenuItem(title: "Add Missing Defaults", action: #selector(addMissingRadioDefaults), keyEquivalent: "")
        addDefaultsItem.target = self
        menu.addItem(addDefaultsItem)
        
        let resetDefaultsItem = NSMenuItem(title: "Reset to Defaults", action: #selector(resetRadioToDefaults), keyEquivalent: "")
        resetDefaultsItem.target = self
        menu.addItem(resetDefaultsItem)
        
        let menuLocation = NSPoint(x: event.locationInWindow.x, y: event.locationInWindow.y - 5)
        menu.popUp(positioning: nil, at: menuLocation, in: window?.contentView)
    }

    private func promptForRadioFolderName(
        title: String,
        message: String,
        confirmTitle: String,
        defaultValue: String = ""
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        textField.stringValue = defaultValue
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func buildRadioStationFoldersSubmenu(for station: RadioStation) -> NSMenu {
        let submenu = NSMenu()
        let folders = RadioManager.shared.userRadioFolders()
        if folders.isEmpty {
            let emptyItem = NSMenuItem(title: "No Folders", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        } else {
            for folder in folders {
                let item = NSMenuItem(
                    title: folder.name,
                    action: #selector(contextMenuToggleStationFolderMembership(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = RadioFolderMembershipAction(station: station, folderID: folder.id)
                item.state = RadioManager.shared.isStation(station, inUserFolderID: folder.id) ? .on : .off
                submenu.addItem(item)
            }
        }

        submenu.addItem(NSMenuItem.separator())
        let newFolderItem = NSMenuItem(
            title: "New Folder...",
            action: #selector(contextMenuCreateRadioFolderAndAddStation(_:)),
            keyEquivalent: ""
        )
        newFolderItem.target = self
        newFolderItem.representedObject = RadioFolderStationAction(station: station)
        submenu.addItem(newFolderItem)
        return submenu
    }

    private func buildRadioStationSmartFoldersSubmenu(for station: RadioStation) -> NSMenu {
        let submenu = NSMenu()

        let genreItem = NSMenuItem(title: "By Genre", action: nil, keyEquivalent: "")
        genreItem.submenu = buildRadioStationSmartGenreSubmenu(for: station)
        submenu.addItem(genreItem)

        let regionItem = NSMenuItem(title: "By Region", action: nil, keyEquivalent: "")
        regionItem.submenu = buildRadioStationSmartRegionSubmenu(for: station)
        submenu.addItem(regionItem)

        return submenu
    }

    private func buildRadioStationSmartGenreSubmenu(for station: RadioStation) -> NSMenu {
        let submenu = NSMenu()
        let manager = RadioManager.shared
        let baseGenre = (station.genre ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Unknown"
            : (station.genre ?? "Unknown").trimmingCharacters(in: .whitespacesAndNewlines)
        let overrideGenre = manager.smartGenreOverride(for: station)
        let effectiveGenre = manager.normalizedGenre(for: station)

        let autoItem = NSMenuItem(
            title: "Use Station Genre (\(baseGenre))",
            action: #selector(contextMenuAssignStationSmartGenre(_:)),
            keyEquivalent: ""
        )
        autoItem.target = self
        autoItem.representedObject = RadioSmartGenreAction(station: station, genre: nil)
        autoItem.state = overrideGenre == nil ? .on : .off
        submenu.addItem(autoItem)
        submenu.addItem(NSMenuItem.separator())

        for genre in manager.smartGenreOptions(including: station) {
            let item = NSMenuItem(
                title: genre,
                action: #selector(contextMenuAssignStationSmartGenre(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = RadioSmartGenreAction(station: station, genre: genre)
            item.state = effectiveGenre.localizedCaseInsensitiveCompare(genre) == .orderedSame ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    private func buildRadioStationSmartRegionSubmenu(for station: RadioStation) -> NSMenu {
        let submenu = NSMenu()
        let manager = RadioManager.shared
        let baseRegion = manager.autoRegion(for: station)
        let overrideRegion = manager.smartRegionOverride(for: station)
        let effectiveRegion = manager.effectiveRegion(for: station)

        let autoItem = NSMenuItem(
            title: "Use Auto Region (\(baseRegion))",
            action: #selector(contextMenuAssignStationSmartRegion(_:)),
            keyEquivalent: ""
        )
        autoItem.target = self
        autoItem.representedObject = RadioSmartRegionAction(station: station, region: nil)
        autoItem.state = overrideRegion == nil ? .on : .off
        submenu.addItem(autoItem)
        submenu.addItem(NSMenuItem.separator())

        for region in manager.smartRegionOptions(including: station) {
            let item = NSMenuItem(
                title: region,
                action: #selector(contextMenuAssignStationSmartRegion(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = RadioSmartRegionAction(station: station, region: region)
            item.state = effectiveRegion.localizedCaseInsensitiveCompare(region) == .orderedSame ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }
    
    @objc private func showAddRadioPlaylistDialog() {
        // Show a simple dialog to enter a playlist URL (.m3u, .pls)
        let alert = NSAlert()
        alert.messageText = "Import Playlist URL"
        alert.informativeText = "Enter the URL of a .m3u or .pls playlist file containing radio streams:"
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.placeholderString = "https://example.com/playlist.m3u"
        alert.accessoryView = textField
        
        if alert.runModal() == .alertFirstButtonReturn {
            let urlString = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !urlString.isEmpty, let url = URL(string: urlString) else {
                let errorAlert = NSAlert()
                errorAlert.messageText = "Invalid URL"
                errorAlert.informativeText = "Please enter a valid URL."
                errorAlert.runModal()
                return
            }
            
            // Fetch and parse the playlist
            fetchAndParsePlaylist(from: url)
        }
    }
    
    @objc private func importRadioPlaylistFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            .init(filenameExtension: "m3u")!,
            .init(filenameExtension: "m3u8")!,
            .init(filenameExtension: "pls")!
        ]
        panel.message = "Select playlist files containing radio streams"
        
        if panel.runModal() == .OK {
            var totalStations = 0
            
            for url in panel.urls {
                do {
                    let content = try String(contentsOf: url, encoding: .utf8)
                    let stations = parsePlaylistContent(content, sourceURL: url)
                    
                    for station in stations {
                        RadioManager.shared.addStation(station)
                    }
                    totalStations += stations.count
                } catch {
                    NSLog("Failed to read playlist file %@: %@", url.path, error.localizedDescription.redactingSensitiveURLQueryItems)
                }
            }
            
            if totalStations > 0 {
                model.reloadInternetRadioForCurrentMode()
                
                let successAlert = NSAlert()
                successAlert.messageText = "Playlist Imported"
                successAlert.informativeText = "Added \(totalStations) station\(totalStations == 1 ? "" : "s") from the playlist\(panel.urls.count == 1 ? "" : "s")."
                successAlert.runModal()
            } else {
                showPlaylistError("No valid radio streams found in the selected file(s)")
            }
        }
    }
    
    private func fetchAndParsePlaylist(from url: URL) {
        Task { @MainActor in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let content = String(data: data, encoding: .utf8) else {
                    showPlaylistError("Could not read playlist content")
                    return
                }
                
                let stations = parsePlaylistContent(content, sourceURL: url)
                if stations.isEmpty {
                    showPlaylistError("No valid streams found in playlist")
                    return
                }
                
                // Add all stations
                for station in stations {
                    RadioManager.shared.addStation(station)
                }
                
                // Reload and show success
                model.reloadInternetRadioForCurrentMode()
                
                let successAlert = NSAlert()
                successAlert.messageText = "Playlist Added"
                successAlert.informativeText = "Added \(stations.count) station\(stations.count == 1 ? "" : "s") from the playlist."
                successAlert.runModal()
            } catch {
                showPlaylistError("Failed to fetch playlist: \(error.localizedDescription)")
            }
        }
    }
    
    private func parsePlaylistContent(_ content: String, sourceURL: URL) -> [RadioStation] {
        var stations: [RadioStation] = []
        let lines = content.components(separatedBy: .newlines)
        
        // Detect format
        let isM3U = content.hasPrefix("#EXTM3U") || sourceURL.pathExtension.lowercased() == "m3u" || sourceURL.pathExtension.lowercased() == "m3u8"
        let isPLS = content.lowercased().contains("[playlist]") || sourceURL.pathExtension.lowercased() == "pls"
        
        if isM3U {
            // Parse M3U format
            var currentTitle: String?
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#EXTINF:") {
                    // Extract title from #EXTINF:-1,Station Name
                    if let commaIndex = trimmed.firstIndex(of: ",") {
                        currentTitle = String(trimmed[trimmed.index(after: commaIndex)...])
                    }
                } else if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                    if let streamURL = URL(string: trimmed) {
                        let name = currentTitle ?? streamURL.lastPathComponent
                        stations.append(RadioStation(name: name, url: streamURL))
                    }
                    currentTitle = nil
                }
            }
        } else if isPLS {
            // Parse PLS format
            var files: [Int: String] = [:]
            var titles: [Int: String] = [:]
            
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().hasPrefix("file") {
                    // File1=http://...
                    if let equalIndex = trimmed.firstIndex(of: "=") {
                        let numPart = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<equalIndex]
                        if let num = Int(numPart) {
                            files[num] = String(trimmed[trimmed.index(after: equalIndex)...])
                        }
                    }
                } else if trimmed.lowercased().hasPrefix("title") {
                    // Title1=Station Name
                    if let equalIndex = trimmed.firstIndex(of: "=") {
                        let numPart = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 5)..<equalIndex]
                        if let num = Int(numPart) {
                            titles[num] = String(trimmed[trimmed.index(after: equalIndex)...])
                        }
                    }
                }
            }
            
            for (num, urlString) in files {
                if let url = URL(string: urlString) {
                    let name = titles[num] ?? url.lastPathComponent
                    stations.append(RadioStation(name: name, url: url))
                }
            }
        } else {
            // Try to extract any http URLs
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                    if let url = URL(string: trimmed) {
                        stations.append(RadioStation(name: url.lastPathComponent, url: url))
                    }
                }
            }
        }
        
        return stations
    }
    
    private func showPlaylistError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Playlist Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
    
    @objc private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff]
        panel.message = "Select audio files to add to your library"

        if panel.runModal() == .OK {
            MediaLibrary.shared.addTracks(urls: panel.urls)

            // Switch to local source if not already
            if case .plex = model.currentSource {
                model.currentSource = .local
            }
        }
    }

    @objc private func addVideoFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        var videoTypes: [UTType] = [.movie, .video]
        for ext in AudioFileValidator.supportedVideoExtensions {
            if let type = UTType(filenameExtension: ext) { videoTypes.append(type) }
        }
        panel.allowedContentTypes = videoTypes
        panel.message = "Select video files to add to your library"
        if panel.runModal() == .OK {
            MediaLibrary.shared.addVideoFiles(urls: panel.urls)
            revealLocalVideoCategory()
        }
    }

    private func revealLocalVideoCategory() {
        if case .local = model.currentSource {} else { model.currentSource = .local }
        if model.browseMode != .movies {
            model.browseMode = .movies
            selectedIndices.removeAll()
            scrollOffset = 0
        }
        model.loadDataForCurrentMode()
        needsDisplay = true
    }

    @objc private func selectLocalSource() {
        model.currentSource = .local
    }

    @objc private func selectRadioSource() {
        model.currentSource = .radio
    }

    @objc private func selectYouTubeSource() {
        model.currentSource = .youtube
    }

    private func showYouTubeAddMenu(at event: NSEvent) {
        let menu = NSMenu()
        let addItem = NSMenuItem(title: "Add Channel...", action: #selector(showAddYouTubeChannelDialog), keyEquivalent: "")
        addItem.target = self
        menu.addItem(addItem)
        let menuLocation = NSPoint(x: event.locationInWindow.x, y: event.locationInWindow.y - 5)
        menu.popUp(positioning: nil, at: menuLocation, in: window?.contentView)
    }


    @objc private func showAddRadioStationDialog() {
        activeRadioStationSheet = AddRadioStationSheet(station: nil)
        activeRadioStationSheet?.showDialog { [weak self] station in
            self?.activeRadioStationSheet = nil  // Release reference when done
            if let newStation = station {
                RadioManager.shared.addStation(newStation)
                // Switch to radio source if not already
                if case .radio = self?.model.currentSource {
                    self?.model.reloadInternetRadioForCurrentMode()
                } else {
                    self?.model.currentSource = .radio
                }
            }
        }
    }

    @objc private func showCreateRadioFolderDialog() {
        guard let name = promptForRadioFolderName(
            title: "New Folder",
            message: "Enter a folder name for Internet Radio:",
            confirmTitle: "Create"
        ) else { return }
        guard RadioManager.shared.createUserFolder(named: name) != nil else {
            let alert = NSAlert()
            alert.messageText = "Unable to Create Folder"
            alert.informativeText = "Use a unique, non-empty folder name."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        model.reloadInternetRadioForCurrentMode()
    }

    @objc private func showAddYouTubeChannelDialog() {
        activeYouTubeChannelSheet = AddYouTubeChannelSheet()
        activeYouTubeChannelSheet?.showDialog { [weak self] channel in
            self?.activeYouTubeChannelSheet = nil
            guard let self = self else { return }
            if channel != nil {
                if case .youtube = self.model.currentSource {
                    self.model.rebuildCurrentModeItems()
                } else {
                    self.model.currentSource = .youtube
                }
            }
        }
    }

    @objc private func addMissingRadioDefaults() {
        RadioManager.shared.addMissingDefaults()
        if case .radio = model.currentSource {
            model.reloadInternetRadioForCurrentMode()
        }
    }
    
    @objc private func resetRadioToDefaults() {
        // Show confirmation dialog
        let alert = NSAlert()
        alert.messageText = "Reset to Defaults"
        alert.informativeText = "This will remove all your saved radio stations and replace them with the default stations. Are you sure?"
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        
        if alert.runModal() == .alertFirstButtonReturn {
            RadioManager.shared.resetToDefaults()
            if case .radio = model.currentSource {
                model.reloadInternetRadioForCurrentMode()
            }
        }
    }
    
    @objc private func selectPlexServer(_ sender: NSMenuItem) {
        guard let serverId = sender.representedObject as? String else { return }
        model.currentSource = .plex(serverId: serverId)
    }
    
    @objc private func linkPlexAccount() {
        presentLinkSheet()
    }
    
    @objc private func selectSubsonicServer(_ sender: NSMenuItem) {
        guard let serverId = sender.representedObject as? String else { return }
        model.currentSource = .subsonic(serverId: serverId)
    }
    
    @objc private func addSubsonicServer() {
        WindowManager.shared.showSubsonicLinkSheet()
    }
    
    @objc private func selectJellyfinServer(_ sender: NSMenuItem) {
        guard let serverId = sender.representedObject as? String else { return }
        model.currentSource = .jellyfin(serverId: serverId)
    }
    
    @objc private func addJellyfinServer() {
        WindowManager.shared.showJellyfinLinkSheet()
    }

    @objc private func selectEmbyServer(_ sender: NSMenuItem) {
        guard let serverId = sender.representedObject as? String else { return }
        model.currentSource = .emby(serverId: serverId)
    }

    @objc private func addEmbyServer() {
        WindowManager.shared.showEmbyLinkSheet()
    }
    
    @objc private func addWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder to add to your library"

        let folderDelegate = TopLevelFolderPickerDelegate()
        panel.delegate = folderDelegate

        withExtendedLifetime(folderDelegate) {
            if panel.runModal() == .OK, let url = panel.url {
                MediaLibrary.shared.addWatchFolder(url)
                MediaLibrary.shared.scanFolder(url)

                // Switch to local source if not already
                if case .plex = model.currentSource {
                    model.currentSource = .local
                }
            }
        }
    }

    @objc private func manageWatchFolders() {
        WatchFolderManagerDialog.present { [weak self] in
            guard let self = self else { return }
            if case .local = self.model.currentSource {
                self.model.loadLocalData()
            }
        }
    }
    
    private func handleRefreshClick() {
        if model.browseMode.isHistoryMode {
            historyAgent.scheduleRefresh()
            return
        }
        model.refreshCurrentSource()
    }

    // MARK: - Sort Menu
    
    private func showSortMenu(at windowPoint: NSPoint) {
        let menu = NSMenu()
        
        for option in LibraryBrowserSortOption.allCases {
            let item = NSMenuItem(title: option.rawValue, action: #selector(selectSortOption(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option
            if option == model.currentSort {
                item.state = .on
            }
            menu.addItem(item)
        }
        
        let menuLocation = NSPoint(x: windowPoint.x, y: windowPoint.y - 5)
        menu.popUp(positioning: nil, at: menuLocation, in: window?.contentView)
    }
    
    private func handleAlphabetClick(at skinPoint: NSPoint) {
        let rect = listLayout().alphabet
        let relativeY = skinPoint.y - rect.minY
        let letterCount = CGFloat(alphabetLetters.count)
        let letterHeight = rect.height / letterCount
        let letterIndex = Int(relativeY / letterHeight)
        
        guard letterIndex >= 0 && letterIndex < alphabetLetters.count else { return }
        
        let targetLetter = alphabetLetters[letterIndex]
        scrollToLetter(targetLetter)
    }
    
    private func scrollToLetter(_ letter: String) {
        if artLens.jump(to: { LibraryBrowserModel.effectiveSortLetter(for: $0) == letter }) { return }
        // Paged local tabs load the letter's page
        if let moved = model.showLocalPage(atLetter: letter) {
            if moved { scrollOffset = 0 }
            return
        }
        for (index, item) in model.displayItems.enumerated() {
            if LibraryBrowserModel.effectiveSortLetter(for: item) == letter {
                let listHeight = listLayout().rows.height
                let maxScroll = max(0, CGFloat(model.displayItems.count) * itemHeight - listHeight)
                scrollOffset = min(maxScroll, CGFloat(index) * itemHeight)
                selectedIndices = [index]
                needsDisplay = true
                return
            }
        }
    }
    
    private func handleListClick(at index: Int, event: NSEvent, skinPoint: NSPoint) {
        let item = model.displayItems[index]

        if model.browseMode == .search {
            switch item.type {
            case .artist(let artist):
                model.navigateToArtistFromSearch(id: artist.id, name: artist.title)
                return
            case .subsonicArtist(let artist):
                model.navigateToArtistFromSearch(id: artist.id, name: artist.name)
                return
            case .jellyfinArtist(let artist):
                model.navigateToArtistFromSearch(id: artist.id, name: artist.name)
                return
            case .embyArtist(let artist):
                model.navigateToArtistFromSearch(id: artist.id, name: artist.name)
                return
            case .localArtist(let artist):
                model.navigateToArtistFromSearch(id: item.id, name: artist.name)
                return
            default:
                break
            }
        }

        if case .radioFolder(let folder) = item.type {
            let indent = CGFloat(item.indentLevel) * 16
            let inExpandZone = skinPoint.x < Layout.leftBorder + indent + 20
            if folder.hasChildren && inExpandZone {
                model.toggleExpand(item)
                return
            }
            if folder.hasChildren && event.clickCount == 2 {
                model.toggleExpand(item)
                return
            }
            if let updatedIndex = model.displayItems.firstIndex(where: { $0.id == folder.id }) {
                selectedIndices = [updatedIndex]
            } else {
                selectedIndices = [index]
            }
            needsDisplay = true
            return
        }

        if let clickedStar = hitTestInternetRadioRating(at: skinPoint, itemIndex: index),
           case .radioStation(let station) = item.type {
            let currentRating = RadioManager.shared.rating(for: station)
            let targetRating = currentRating == clickedStar ? 0 : clickedStar
            RadioManager.shared.setRating(targetRating, for: station)
            selectedIndices = [index]
            needsDisplay = true
            return
        }
        
        // Handle expand/collapse
        if item.hasChildren {
            let indent = CGFloat(item.indentLevel) * 16
            let inExpandZone = skinPoint.x < Layout.leftBorder + indent + 20
            if item.type.isAlbumItem {
                if event.clickCount == 1 { model.toggleExpand(item) }
                // Fall through to selection
            } else if inExpandZone {
                model.toggleExpand(item)
                return
            }
        }

        // Handle selection
        if event.modifierFlags.contains(.shift) {
            if let lastSelected = selectedIndices.max() {
                let start = min(lastSelected, index)
                let end = max(lastSelected, index)
                for i in start...end {
                    selectedIndices.insert(i)
                }
            } else {
                selectedIndices.insert(index)
            }
            // Load artwork for selection (shift-click multi-select)
            loadArtworkForSelection()
        } else if event.modifierFlags.contains(.command) {
            if selectedIndices.contains(index) {
                selectedIndices.remove(index)
            } else {
                selectedIndices.insert(index)
            }
            // Load artwork for selection (cmd-click multi-select)
            loadArtworkForSelection()
        } else {
            selectedIndices = [index]
            
            // A single click selects; tracks play on double-click, as in the Original browser.
            // Each play is a Play Now that inserts the track, so playing on the single click as
            // well played a double-clicked track three times and left three copies queued.
            switch item.type {
            case .plexRadioStation,
                 .subsonicRadioStation,
                 .jellyfinRadioStation,
                 .embyRadioStation,
                 .localRadioStation:
                // Radio stations don't load artwork on single-click - only on play (double-click)
                break
            case .radioStation(let station):
                if model.browseMode == .search && event.clickCount == 1 {
                    playRadioStation(station)
                }
            default:
                // Everything else — tracks included, which play on double-click — loads artwork
                loadArtworkForSelection()
            }
        }
        
        // Double-click to play a track, album or show, or expand an artist
        if event.clickCount == 2 {
            handleDoubleClick(on: item)
        }
        
        needsDisplay = true
    }
    
    override func mouseDragged(with event: NSEvent) {
        // Handle column resize dragging
        if let columnId = resizingColumnId, let group = resizingColumnGroup {
            let point = convert(event.locationInWindow, from: nil)
            let skinPoint = convertToSkinCoordinates(point)
            let rawDeltaX = skinPoint.x - resizeStartX
            let deltaX = resizingColumnFromLeadingEdge ? -rawDeltaX : rawDeltaX
            let minWidth = LibraryBrowserColumn.findColumn(id: columnId)?.minWidth ?? 30
            let newWidth = max(minWidth, resizeStartWidth + deltaX)
            setColumnWidth(newWidth, for: columnId, group: group)
            needsDisplay = true
            return
        }
        
        if embeddedWindowDrag.drag(event) { return }

        // Handle window dragging - snaps to other windows but doesn't dock
        if isDraggingWindow, let window = window {
            let currentPoint = event.locationInWindow
            let deltaX = currentPoint.x - windowDragStartPoint.x
            let deltaY = currentPoint.y - windowDragStartPoint.y
            
            var newOrigin = window.frame.origin
            newOrigin.x += deltaX
            newOrigin.y += deltaY
            
            // Apply snapping to other windows
            newOrigin = WindowManager.shared.windowWillMove(window, to: newOrigin)
            window.setFrameOrigin(newOrigin)
        }
    }
    
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let skinPoint = convertToSkinCoordinates(point)
        
        // End column resizing
        if resizingColumnId != nil {
            resizingColumnId = nil
            resizingColumnGroup = nil
            resizingColumnFromLeadingEdge = false
            NSCursor.pop()
        }
        
        // End window dragging
        if isDraggingWindow {
            isDraggingWindow = false
        }
        embeddedWindowDrag.end()
        
        // Handle button releases
        if let pressed = pressedButton {
            switch pressed {
            case .close:
                if hitTestCloseButton(at: skinPoint) {
                    window?.close()
                }
            }

            pressedButton = nil
            needsDisplay = true
        }
    }

    private func loadNextLocalPageIfNeeded(listHeight: CGFloat) {
        let threshold = itemHeight * 10
        let loadedHeight = CGFloat(model.displayItems.count) * itemHeight
        guard scrollOffset + listHeight + threshold >= loadedHeight else { return }
        model.appendNextLocalPage()
    }

    // MARK: - Drag and Drop (Local Files and Playlists)
    
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return []
        }
        return LocalFileDiscovery.hasSupportedDropContent(items, includeVideo: true, includePlaylists: true) ? .copy : []
    }
    
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return false
        }
        
        var audioURLs: [URL] = []
        var videoURLs: [URL] = []
        var playlistURLs: [URL] = []
        var processedDirectories = false
        
        for url in items {
            if LocalFileDiscovery.isDirectory(url) {
                // Add folder as watch folder and scan
                MediaLibrary.shared.addWatchFolder(url)
                MediaLibrary.shared.scanFolder(url)
                processedDirectories = true
            } else if LocalFileDiscovery.isSupportedPlaylistFile(url) {
                // Playlist file
                playlistURLs.append(url)
            } else if LocalFileDiscovery.isSupportedAudioFile(url) {
                // Audio file
                audioURLs.append(url)
            } else if LocalFileDiscovery.isSupportedVideoFile(url) {
                videoURLs.append(url)
            }
        }
        
        // Handle playlist files - import as radio stations
        if !playlistURLs.isEmpty {
            var totalStations = 0
            for url in playlistURLs {
                do {
                    let content = try String(contentsOf: url, encoding: .utf8)
                    let stations = parsePlaylistContent(content, sourceURL: url)
                    
                    for station in stations {
                        RadioManager.shared.addStation(station)
                    }
                    totalStations += stations.count
                } catch {
                    NSLog("Failed to read playlist file %@: %@", url.path, error.localizedDescription.redactingSensitiveURLQueryItems)
                }
            }
            
            if totalStations > 0 {
                // Switch to radio source to show added stations
                if case .radio = model.currentSource {
                    model.reloadInternetRadioForCurrentMode()
                } else {
                    model.currentSource = .radio
                }
                
                let alert = NSAlert()
                alert.messageText = "Playlist Imported"
                alert.informativeText = "Added \(totalStations) station\(totalStations == 1 ? "" : "s") from the playlist\(playlistURLs.count == 1 ? "" : "s")."
                alert.runModal()
            }
        }
        
        // Handle audio files
        if !audioURLs.isEmpty {
            MediaLibrary.shared.addTracks(urls: audioURLs)
            
            // Switch to local source to show added content
            if case .plex = model.currentSource {
                model.currentSource = .local
            }
        }

        if !videoURLs.isEmpty {
            MediaLibrary.shared.addVideoFiles(urls: videoURLs)
            revealLocalVideoCategory()
        }
        
        return !audioURLs.isEmpty || !videoURLs.isEmpty || !playlistURLs.isEmpty || processedDirectories
    }
    
    // MARK: - Right-Click Context Menu (for list items)
    
    // Note: rightMouseDown is now defined in the Mouse Events section above
    // This section just contains the showContextMenu helper
    
    // MARK: Detailed Metadata Fetching for Context Menu
    
    /// Fetch detailed movie metadata (with IMDB/TMDB IDs) for context menu
    private func fetchMovieDetailsForMenu(_ movie: PlexMovie) async -> PlexMovie {
        // If we already have the IMDB ID, no need to fetch
        if movie.imdbId != nil {
            return movie
        }
        
        do {
            if let detailed = try await PlexManager.shared.fetchMovieDetails(movieID: movie.id) {
                NSLog("Fetched movie details for %@: imdbId=%@, tmdbId=%@", movie.title, detailed.imdbId ?? "nil", detailed.tmdbId ?? "nil")
                return detailed
            }
        } catch {
            NSLog("Failed to fetch movie details: %@", error.localizedDescription.redactingSensitiveURLQueryItems)
        }
        return movie
    }
    
    /// Fetch detailed show metadata (with IMDB/TMDB/TVDB IDs) for context menu
    private func fetchShowDetailsForMenu(_ show: PlexShow) async -> PlexShow {
        // If we already have the IMDB ID, no need to fetch
        if show.imdbId != nil {
            return show
        }
        
        do {
            if let detailed = try await PlexManager.shared.fetchShowDetails(showID: show.id) {
                NSLog("Fetched show details for %@: imdbId=%@, tmdbId=%@", show.title, detailed.imdbId ?? "nil", detailed.tmdbId ?? "nil")
                return detailed
            }
        } catch {
            NSLog("Failed to fetch show details: %@", error.localizedDescription.redactingSensitiveURLQueryItems)
        }
        return show
    }
    
    /// Fetch detailed episode metadata (with IMDB ID) for context menu
    private func fetchEpisodeDetailsForMenu(_ episode: PlexEpisode) async -> PlexEpisode {
        // If we already have the IMDB ID, no need to fetch
        if episode.imdbId != nil {
            return episode
        }
        
        do {
            if let detailed = try await PlexManager.shared.fetchEpisodeDetails(episodeID: episode.id) {
                NSLog("Fetched episode details for %@: imdbId=%@", episode.title, detailed.imdbId ?? "nil")
                return detailed
            }
        } catch {
            NSLog("Failed to fetch episode details: %@", error.localizedDescription.redactingSensitiveURLQueryItems)
        }
        return episode
    }
    
    /// Show context menu with a specific item type (used when we've fetched detailed metadata)
    private func showContextMenu(for itemType: LibraryBrowserItem.ItemType, item: LibraryBrowserItem, at event: NSEvent) {
        // Create a new display item with the detailed type
        let detailedItem = LibraryBrowserItem(
            id: item.id,
            title: item.title,
            info: item.info,
            indentLevel: item.indentLevel,
            hasChildren: item.hasChildren,
            type: itemType,
            titlePrefix: item.titlePrefix
        )
        showContextMenu(for: detailedItem, at: event)
    }
    
    private func showContextMenu(for item: LibraryBrowserItem, at event: NSEvent) {
        let menu = NSMenu()
        if let playable = playable(for: item) {
            TrackVerb.addMenuItems(to: menu, resolve: resolver(for: playable))
            if let level = playable.eqProfileLevel {
                EQProfileMenu.addAssignItem(to: menu, level: level, resolve: resolver(for: playable))
            }
        }
        
        NSLog("showContextMenu: item.type = %@, title = %@", String(describing: item.type), item.title)
        
        switch item.type {
        case .track(let track):
            menu.addItem(NSMenuItem.separator())
            
            let radioItem = NSMenuItem(title: "Start Track Radio", action: #selector(contextMenuStartTrackRadio(_:)), keyEquivalent: "")
            radioItem.target = self
            radioItem.representedObject = track
            menu.addItem(radioItem)
            
        case .album(let album):
            menu.addItem(NSMenuItem.separator())
            
            let radioItem = NSMenuItem(title: "Start Album Radio", action: #selector(contextMenuStartAlbumRadio(_:)), keyEquivalent: "")
            radioItem.target = self
            radioItem.representedObject = album
            menu.addItem(radioItem)
            
        case .artist(let artist):
            let expandItem = NSMenuItem(title: model.isExpanded(item) ? "Collapse" : "Expand", action: #selector(contextMenuToggleExpand(_:)), keyEquivalent: "")
            expandItem.target = self
            expandItem.representedObject = item
            menu.addItem(expandItem)
            
            menu.addItem(NSMenuItem.separator())
            
            let radioItem = NSMenuItem(title: "Start Artist Radio", action: #selector(contextMenuStartArtistRadio(_:)), keyEquivalent: "")
            radioItem.target = self
            radioItem.representedObject = artist
            menu.addItem(radioItem)
            
        case .movie(let movie):
            // Cast submenu (for video-capable devices)
            let videoDevices = CastManager.shared.videoCapableDevices
            if !videoDevices.isEmpty {
                menu.addItem(NSMenuItem.separator())
                
                let castItem = NSMenuItem(title: "Cast to...", action: nil, keyEquivalent: "")
                let castMenu = NSMenu()
                
                for device in videoDevices {
                    let deviceItem = NSMenuItem(title: device.name, action: #selector(contextMenuCastMovie(_:)), keyEquivalent: "")
                    deviceItem.target = self
                    deviceItem.representedObject = (movie, device)
                    castMenu.addItem(deviceItem)
                }
                
                castItem.submenu = castMenu
                menu.addItem(castItem)
            }
            
            // External links submenu
            menu.addItem(NSMenuItem.separator())
            
            let linksItem = NSMenuItem(title: "View Online", action: nil, keyEquivalent: "")
            let linksMenu = NSMenu()
            
            let imdbItem = NSMenuItem(title: "IMDB", action: #selector(contextMenuOpenIMDB(_:)), keyEquivalent: "")
            imdbItem.target = self
            imdbItem.representedObject = movie
            linksMenu.addItem(imdbItem)
            
            let tmdbItem = NSMenuItem(title: "TMDB", action: #selector(contextMenuOpenTMDB(_:)), keyEquivalent: "")
            tmdbItem.target = self
            tmdbItem.representedObject = movie
            linksMenu.addItem(tmdbItem)
            
            let rtItem = NSMenuItem(title: "Rotten Tomatoes", action: #selector(contextMenuOpenRottenTomatoes(_:)), keyEquivalent: "")
            rtItem.target = self
            rtItem.representedObject = movie
            linksMenu.addItem(rtItem)
            
            linksItem.submenu = linksMenu
            menu.addItem(linksItem)
            
        case .show(let show):
            let expandItem = NSMenuItem(title: model.isExpanded(item) ? "Collapse" : "Expand", action: #selector(contextMenuToggleExpand(_:)), keyEquivalent: "")
            expandItem.target = self
            expandItem.representedObject = item
            menu.addItem(expandItem)

            // External links submenu
            menu.addItem(NSMenuItem.separator())
            
            let linksItem = NSMenuItem(title: "View Online", action: nil, keyEquivalent: "")
            let linksMenu = NSMenu()
            
            let imdbItem = NSMenuItem(title: "IMDB", action: #selector(contextMenuOpenIMDBShow(_:)), keyEquivalent: "")
            imdbItem.target = self
            imdbItem.representedObject = show
            linksMenu.addItem(imdbItem)
            
            let tmdbItem = NSMenuItem(title: "TMDB", action: #selector(contextMenuOpenTMDBShow(_:)), keyEquivalent: "")
            tmdbItem.target = self
            tmdbItem.representedObject = show
            linksMenu.addItem(tmdbItem)
            
            let rtItem = NSMenuItem(title: "Rotten Tomatoes", action: #selector(contextMenuOpenRottenTomatoesShow(_:)), keyEquivalent: "")
            rtItem.target = self
            rtItem.representedObject = show
            linksMenu.addItem(rtItem)
            
            linksItem.submenu = linksMenu
            menu.addItem(linksItem)
            
        case .season:
            let expandItem = NSMenuItem(title: model.isExpanded(item) ? "Collapse" : "Expand", action: #selector(contextMenuToggleExpand(_:)), keyEquivalent: "")
            expandItem.target = self
            expandItem.representedObject = item
            menu.addItem(expandItem)

        case .episode(let episode):
            // Cast submenu (for video-capable devices)
            let videoDevicesEpisode = CastManager.shared.videoCapableDevices
            if !videoDevicesEpisode.isEmpty {
                menu.addItem(NSMenuItem.separator())
                
                let castItem = NSMenuItem(title: "Cast to...", action: nil, keyEquivalent: "")
                let castMenu = NSMenu()
                
                for device in videoDevicesEpisode {
                    let deviceItem = NSMenuItem(title: device.name, action: #selector(contextMenuCastEpisode(_:)), keyEquivalent: "")
                    deviceItem.target = self
                    deviceItem.representedObject = (episode, device)
                    castMenu.addItem(deviceItem)
                }
                
                castItem.submenu = castMenu
                menu.addItem(castItem)
            }
            
            // External links submenu
            menu.addItem(NSMenuItem.separator())
            
            let linksItem = NSMenuItem(title: "View Online", action: nil, keyEquivalent: "")
            let linksMenu = NSMenu()
            
            let imdbItem = NSMenuItem(title: "IMDB", action: #selector(contextMenuOpenIMDBEpisode(_:)), keyEquivalent: "")
            imdbItem.target = self
            imdbItem.representedObject = episode
            linksMenu.addItem(imdbItem)
            
            let tmdbItem = NSMenuItem(title: "TMDB", action: #selector(contextMenuOpenTMDBEpisode(_:)), keyEquivalent: "")
            tmdbItem.target = self
            tmdbItem.representedObject = episode
            linksMenu.addItem(tmdbItem)
            
            let rtItem = NSMenuItem(title: "Rotten Tomatoes", action: #selector(contextMenuOpenRottenTomatoesEpisode(_:)), keyEquivalent: "")
            rtItem.target = self
            rtItem.representedObject = episode
            linksMenu.addItem(rtItem)
            
            linksItem.submenu = linksMenu
            menu.addItem(linksItem)
            
        case .localTrack(let track):
            menu.addItem(NSMenuItem.separator())
            
            let editTagsItem = NSMenuItem(title: "Edit Tags", action: #selector(contextMenuEditTags(_:)), keyEquivalent: "")
            editTagsItem.target = self
            editTagsItem.representedObject = track
            menu.addItem(editTagsItem)

            let tagsItem = NSMenuItem(title: "See Tags", action: #selector(contextMenuShowTags(_:)), keyEquivalent: "")
            tagsItem.target = self
            tagsItem.representedObject = track
            menu.addItem(tagsItem)
            
            let finderItem = NSMenuItem(title: "Show in Finder", action: #selector(contextMenuShowInFinder(_:)), keyEquivalent: "")
            finderItem.target = self
            finderItem.representedObject = track
            menu.addItem(finderItem)
            
            menu.addItem(NSMenuItem.separator())
            
            let removeItem = NSMenuItem(title: "Remove from Library", action: #selector(contextMenuRemoveLocalTrack(_:)), keyEquivalent: "")
            removeItem.target = self
            removeItem.representedObject = track
            menu.addItem(removeItem)
            
            let deleteItem = NSMenuItem(title: "Delete File from Disk...", action: #selector(contextMenuDeleteLocalTrack(_:)), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.representedObject = track
            menu.addItem(deleteItem)

        case .localFolder(let url, _):
            menu.addItem(NSMenuItem.separator())

            let finderItem = NSMenuItem(title: "Show in Finder", action: #selector(contextMenuRevealLocalFolderInFinder(_:)), keyEquivalent: "")
            finderItem.target = self
            finderItem.representedObject = url
            menu.addItem(finderItem)

        case .localAlbum(let album):
            menu.addItem(NSMenuItem.separator())

            let rateAlbumItem = NSMenuItem(title: "Rate", action: nil, keyEquivalent: "")
            rateAlbumItem.submenu = buildRateSubmenuForLocalAlbum(albumId: album.id)
            menu.addItem(rateAlbumItem)

            let editAlbumItem = NSMenuItem(title: "Edit Album Tags", action: #selector(contextMenuEditAlbumTags(_:)), keyEquivalent: "")
            editAlbumItem.target = self
            editAlbumItem.representedObject = album
            menu.addItem(editAlbumItem)

            menu.addItem(NSMenuItem.separator())
            
            let removeItem = NSMenuItem(title: "Remove Album from Library", action: #selector(contextMenuRemoveLocalAlbum(_:)), keyEquivalent: "")
            removeItem.target = self
            removeItem.representedObject = album
            menu.addItem(removeItem)
            
            let deleteItem = NSMenuItem(title: "Delete Album from Disk...", action: #selector(contextMenuDeleteLocalAlbum(_:)), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.representedObject = album
            menu.addItem(deleteItem)
            
        case .localArtist(let artist):
            let expandItem = NSMenuItem(title: model.isExpanded(item) ? "Collapse" : "Expand", action: #selector(contextMenuToggleExpand(_:)), keyEquivalent: "")
            expandItem.target = self
            expandItem.representedObject = item
            menu.addItem(expandItem)
            
            menu.addItem(NSMenuItem.separator())

            let rateArtistItem = NSMenuItem(title: "Rate", action: nil, keyEquivalent: "")
            rateArtistItem.submenu = buildRateSubmenuForLocalArtist(artistId: artist.id)
            menu.addItem(rateArtistItem)
            menu.addItem(NSMenuItem.separator())
            
            let removeItem = NSMenuItem(title: "Remove Artist from Library", action: #selector(contextMenuRemoveLocalArtist(_:)), keyEquivalent: "")
            removeItem.target = self
            removeItem.representedObject = artist
            menu.addItem(removeItem)
            
            let deleteItem = NSMenuItem(title: "Delete Artist from Disk...", action: #selector(contextMenuDeleteLocalArtist(_:)), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.representedObject = artist
            menu.addItem(deleteItem)
            
        case .subsonicArtist:
            let expandItem = NSMenuItem(title: model.isExpanded(item) ? "Collapse" : "Expand", action: #selector(contextMenuToggleExpand(_:)), keyEquivalent: "")
            expandItem.target = self
            expandItem.representedObject = item
            menu.addItem(expandItem)
            
        case .subsonicPlaylist:
            let expandItem = NSMenuItem(title: model.isExpanded(item) ? "Collapse" : "Expand", action: #selector(contextMenuToggleExpand(_:)), keyEquivalent: "")
            expandItem.target = self
            expandItem.representedObject = item
            menu.addItem(expandItem)
            
        case .jellyfinArtist:
            let expandItem2 = NSMenuItem(title: model.isExpanded(item) ? "Collapse" : "Expand", action: #selector(contextMenuToggleExpand(_:)), keyEquivalent: "")
            expandItem2.target = self
            expandItem2.representedObject = item
            menu.addItem(expandItem2)
            
        case .jellyfinPlaylist:
            let expandItem3 = NSMenuItem(title: model.isExpanded(item) ? "Collapse" : "Expand", action: #selector(contextMenuToggleExpand(_:)), keyEquivalent: "")
            expandItem3.target = self
            expandItem3.representedObject = item
            menu.addItem(expandItem3)
            
        case .jellyfinShow:
            let expandItem4 = NSMenuItem(title: "Expand/Collapse", action: #selector(contextMenuToggleExpand(_:)), keyEquivalent: "")
            expandItem4.target = self
            expandItem4.representedObject = item
            menu.addItem(expandItem4)
            
        case .jellyfinSeason:
            let expandItem5 = NSMenuItem(title: "Expand/Collapse", action: #selector(contextMenuToggleExpand(_:)), keyEquivalent: "")
            expandItem5.target = self
            expandItem5.representedObject = item
            menu.addItem(expandItem5)
            
        case .embyArtist:
            let ex = NSMenuItem(title: model.isExpanded(item) ? "Collapse" : "Expand", action: #selector(contextMenuToggleExpand(_:)), keyEquivalent: ""); ex.target = self; ex.representedObject = item; menu.addItem(ex)
        case .embyPlaylist:
            let ex = NSMenuItem(title: model.isExpanded(item) ? "Collapse" : "Expand", action: #selector(contextMenuToggleExpand(_:)), keyEquivalent: ""); ex.target = self; ex.representedObject = item; menu.addItem(ex)
        case .embyShow:
            let ex = NSMenuItem(title: "Expand/Collapse", action: #selector(contextMenuToggleExpand(_:)), keyEquivalent: ""); ex.target = self; ex.representedObject = item; menu.addItem(ex)
        case .embySeason:
            let ex = NSMenuItem(title: "Expand/Collapse", action: #selector(contextMenuToggleExpand(_:)), keyEquivalent: ""); ex.target = self; ex.representedObject = item; menu.addItem(ex)

        case .plexPlaylist:
            let expandItem = NSMenuItem(title: model.isExpanded(item) ? "Collapse" : "Expand", action: #selector(contextMenuToggleExpand(_:)), keyEquivalent: "")
            expandItem.target = self
            expandItem.representedObject = item
            menu.addItem(expandItem)
            
        case .radioStation(let station):
            let playItem = NSMenuItem(title: "Play Station", action: #selector(contextMenuPlayRadioStation(_:)), keyEquivalent: "")
            playItem.target = self
            playItem.representedObject = station
            menu.addItem(playItem)
            EQProfileMenu.addAssignItem(to: menu, level: .track, tracks: [station.toTrack()])
            
            menu.addItem(NSMenuItem.separator())
            
            let foldersItem = NSMenuItem(title: "Folders", action: nil, keyEquivalent: "")
            foldersItem.submenu = buildRadioStationFoldersSubmenu(for: station)
            menu.addItem(foldersItem)

            let smartFoldersItem = NSMenuItem(title: "Smart Folders", action: nil, keyEquivalent: "")
            smartFoldersItem.submenu = buildRadioStationSmartFoldersSubmenu(for: station)
            menu.addItem(smartFoldersItem)
            
            menu.addItem(NSMenuItem.separator())
            
            let editItem = NSMenuItem(title: "Edit Station...", action: #selector(contextMenuEditRadioStation(_:)), keyEquivalent: "")
            editItem.target = self
            editItem.representedObject = station
            menu.addItem(editItem)
            
            let deleteItem = NSMenuItem(title: "Delete Station", action: #selector(contextMenuDeleteRadioStation(_:)), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.representedObject = station
            menu.addItem(deleteItem)

        case .radioFolder(let folder):
            if folder.hasChildren {
                let expandItem = NSMenuItem(
                    title: model.isExpanded(item) ? "Collapse" : "Expand",
                    action: #selector(contextMenuToggleExpand(_:)),
                    keyEquivalent: ""
                )
                expandItem.target = self
                expandItem.representedObject = item
                menu.addItem(expandItem)
            }

            switch folder.kind {
            case .manual(let folderID):
                if !menu.items.isEmpty { menu.addItem(NSMenuItem.separator()) }
                let renameItem = NSMenuItem(title: "Rename Folder...", action: #selector(contextMenuRenameRadioFolder(_:)), keyEquivalent: "")
                renameItem.target = self
                renameItem.representedObject = RadioFolderRenameAction(folderID: folderID)
                menu.addItem(renameItem)

                let deleteItem = NSMenuItem(title: "Delete Folder", action: #selector(contextMenuDeleteRadioFolder(_:)), keyEquivalent: "")
                deleteItem.target = self
                deleteItem.representedObject = RadioFolderDeleteAction(folderID: folderID)
                menu.addItem(deleteItem)
            case .userFoldersRoot:
                if !menu.items.isEmpty { menu.addItem(NSMenuItem.separator()) }
                let newFolderItem = NSMenuItem(title: "New Folder...", action: #selector(showCreateRadioFolderDialog), keyEquivalent: "")
                newFolderItem.target = self
                menu.addItem(newFolderItem)
            default:
                break
            }

            if menu.items.isEmpty { return }

        case .youtubeChannel(let channel):
            let expandTitle = model.isExpanded(item) ? "Collapse" : "Expand"
            let expandItem = NSMenuItem(title: expandTitle, action: #selector(contextMenuToggleExpand(_:)), keyEquivalent: "")
            expandItem.target = self; expandItem.representedObject = item; menu.addItem(expandItem)
            menu.addItem(NSMenuItem.separator())
            if !YouTubeManager.shared.isSubscribed(channel) {
                let subscribeItem = NSMenuItem(title: "Subscribe", action: #selector(contextMenuSubscribeYouTubeChannel(_:)), keyEquivalent: "")
                subscribeItem.target = self; subscribeItem.representedObject = channel; menu.addItem(subscribeItem)
            } else if model.isYouTubeChannelSearch {
                // Refresh/Remove belong to the Channels tab.
                let subscribedItem = NSMenuItem(title: "Already Subscribed", action: nil, keyEquivalent: "")
                subscribedItem.isEnabled = false; menu.addItem(subscribedItem)
            } else {
                let refreshItem = NSMenuItem(title: "Refresh", action: #selector(contextMenuRefreshYouTubeChannel(_:)), keyEquivalent: "")
                refreshItem.target = self; refreshItem.representedObject = channel; menu.addItem(refreshItem)
                let removeItem = NSMenuItem(title: "Remove Channel", action: #selector(contextMenuRemoveYouTubeChannel(_:)), keyEquivalent: "")
                removeItem.target = self; removeItem.representedObject = channel; menu.addItem(removeItem)
            }

        case .youtubeVideo(let video):
            youtubeVideoActions.addMenuItems(for: video, to: menu)

        case .plexRadioStation(let radioType):
            let playItem = NSMenuItem(title: "Play \(radioType.displayName)", action: #selector(contextMenuPlayPlexRadioStation(_:)), keyEquivalent: "")
            playItem.target = self
            playItem.representedObject = item
            menu.addItem(playItem)

        case .subsonicRadioStation:
            let playItem = NSMenuItem(title: "Play", action: #selector(contextMenuPlaySubsonicRadioStation(_:)), keyEquivalent: "")
            playItem.target = self
            playItem.representedObject = item
            menu.addItem(playItem)

        case .jellyfinRadioStation:
            let playItem = NSMenuItem(title: "Play", action: #selector(contextMenuPlayJellyfinRadioStation(_:)), keyEquivalent: "")
            playItem.target = self
            playItem.representedObject = item
            menu.addItem(playItem)

        case .embyRadioStation:
            let playItem = NSMenuItem(title: "Play", action: #selector(contextMenuPlayEmbyRadioStation(_:)), keyEquivalent: "")
            playItem.target = self
            playItem.representedObject = item
            menu.addItem(playItem)

        case .localRadioStation:
            let playItem = NSMenuItem(title: "Play", action: #selector(contextMenuPlayLocalRadioStation(_:)), keyEquivalent: "")
            playItem.target = self
            playItem.representedObject = item
            menu.addItem(playItem)
            
        case .localMovie(let movie):
            let videoDevices = CastManager.shared.videoCapableDevices
            if !videoDevices.isEmpty {
                menu.addItem(NSMenuItem.separator())
                let castItem = NSMenuItem(title: "Cast to...", action: nil, keyEquivalent: "")
                let castMenu = NSMenu()
                for device in videoDevices {
                    let deviceItem = NSMenuItem(title: device.name, action: #selector(contextMenuCastLocalVideo(_:)), keyEquivalent: "")
                    deviceItem.target = self
                    deviceItem.representedObject = (movie.url, movie.title, device) as (URL, String, CastDevice)
                    castMenu.addItem(deviceItem)
                }
                castItem.submenu = castMenu
                menu.addItem(castItem)
            }
            menu.addItem(NSMenuItem.separator())
            let finderItem = NSMenuItem(title: "Show in Finder", action: #selector(contextMenuShowLocalVideoInFinder(_:)), keyEquivalent: "")
            finderItem.target = self
            finderItem.representedObject = movie.url as NSURL
            menu.addItem(finderItem)
            menu.addItem(NSMenuItem.separator())
            let editMovieItem = NSMenuItem(title: "Edit Tags", action: #selector(contextMenuEditVideoTags(_:)), keyEquivalent: "")
            editMovieItem.target = self
            editMovieItem.representedObject = movie
            menu.addItem(editMovieItem)

        case .localShow:
            let expandItem = NSMenuItem(title: model.isExpanded(item) ? "Collapse" : "Expand",
                                        action: #selector(contextMenuToggleExpand(_:)), keyEquivalent: "")
            expandItem.target = self
            expandItem.representedObject = item
            menu.addItem(expandItem)

        case .localSeason:
            let expandItem = NSMenuItem(title: model.isExpanded(item) ? "Collapse" : "Expand",
                                        action: #selector(contextMenuToggleExpand(_:)), keyEquivalent: "")
            expandItem.target = self
            expandItem.representedObject = item
            menu.addItem(expandItem)

        case .localEpisode(let episode):
            let videoDevices = CastManager.shared.videoCapableDevices
            if !videoDevices.isEmpty {
                menu.addItem(NSMenuItem.separator())
                let castItem = NSMenuItem(title: "Cast to...", action: nil, keyEquivalent: "")
                let castMenu = NSMenu()
                for device in videoDevices {
                    let deviceItem = NSMenuItem(title: device.name, action: #selector(contextMenuCastLocalVideo(_:)), keyEquivalent: "")
                    deviceItem.target = self
                    deviceItem.representedObject = (episode.url, episode.title, device) as (URL, String, CastDevice)
                    castMenu.addItem(deviceItem)
                }
                castItem.submenu = castMenu
                menu.addItem(castItem)
            }
            menu.addItem(NSMenuItem.separator())
            let finderItem = NSMenuItem(title: "Show in Finder", action: #selector(contextMenuShowLocalVideoInFinder(_:)), keyEquivalent: "")
            finderItem.target = self
            finderItem.representedObject = episode.url as NSURL
            menu.addItem(finderItem)
            menu.addItem(NSMenuItem.separator())
            let editEpisodeItem = NSMenuItem(title: "Edit Tags", action: #selector(contextMenuEditVideoTags(_:)), keyEquivalent: "")
            editEpisodeItem.target = self
            editEpisodeItem.representedObject = episode
            menu.addItem(editEpisodeItem)

        case .subsonicTrack, .subsonicAlbum, .jellyfinTrack, .jellyfinAlbum, .embyTrack, .embyAlbum, .localPlaylist, .localPlaylistTrack,
             .jellyfinMovie, .jellyfinEpisode, .embyMovie, .embyEpisode:
            break

        case .header:
            return
        }

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private static func goldStarAttributedTitle(_ label: String) -> NSAttributedString {
        let goldColor = NSColor(srgbRed: 0.98, green: 0.78, blue: 0.20, alpha: 1.0)
        let emptyColor = NSColor.secondaryLabelColor
        let font = NSFont.menuFont(ofSize: 0)
        let astr = NSMutableAttributedString(string: label,
                                             attributes: [.font: font,
                                                          .foregroundColor: emptyColor])
        for (i, ch) in label.enumerated() where ch == "★" {
            astr.addAttribute(.foregroundColor, value: goldColor,
                              range: NSRange(location: i, length: 1))
        }
        return astr
    }

    private func buildRateSubmenuForLocalAlbum(albumId: String) -> NSMenu {
        let menu = NSMenu(title: "Rate")
        for stars in 1...5 {
            let label = String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars)
            let item = NSMenuItem(title: label, action: #selector(contextMenuRateLocalAlbum(_:)), keyEquivalent: "")
            item.target = self
            item.tag = stars * 2
            item.representedObject = albumId
            item.attributedTitle = PlexBrowserView.goldStarAttributedTitle(label)
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(title: "Clear Rating", action: #selector(contextMenuRateLocalAlbum(_:)), keyEquivalent: "")
        clearItem.target = self
        clearItem.tag = -1
        clearItem.representedObject = albumId
        menu.addItem(clearItem)
        return menu
    }

    private func buildRateSubmenuForLocalArtist(artistId: String) -> NSMenu {
        let menu = NSMenu(title: "Rate")
        for stars in 1...5 {
            let label = String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars)
            let item = NSMenuItem(title: label, action: #selector(contextMenuRateLocalArtist(_:)), keyEquivalent: "")
            item.target = self
            item.tag = stars * 2
            item.representedObject = artistId
            item.attributedTitle = PlexBrowserView.goldStarAttributedTitle(label)
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(title: "Clear Rating", action: #selector(contextMenuRateLocalArtist(_:)), keyEquivalent: "")
        clearItem.target = self
        clearItem.tag = -1
        clearItem.representedObject = artistId
        menu.addItem(clearItem)
        return menu
    }

    @objc private func contextMenuShowTags(_ sender: NSMenuItem) {
        guard let track = sender.representedObject as? LibraryTrack else { return }
        // Close any existing tags panel first
        activeTagsPanel?.close()
        
        let tagsPanel = TagsPanel(track: track)
        tagsPanel.delegate = self
        activeTagsPanel = tagsPanel
        tagsPanel.show()
    }

    @objc private func contextMenuEditTags(_ sender: NSMenuItem) {
        guard let track = sender.representedObject as? LibraryTrack else { return }
        activeEditTagsPanel?.close()
        let panel = EditTagsPanel(track: track)
        panel.delegate = self
        panel.onSave = { [weak self] in self?.model.reloadLocalBrowserAfterMetadataEdit() }
        activeEditTagsPanel = panel
        panel.show()
    }

    @objc private func contextMenuEditAlbumTags(_ sender: NSMenuItem) {
        guard let album = sender.representedObject as? Album else { return }
        activeEditAlbumTagsPanel?.close()
        let panel = EditAlbumTagsPanel(album: album)
        panel.delegate = self
        panel.onSave = { [weak self] in self?.model.reloadLocalBrowserAfterMetadataEdit() }
        activeEditAlbumTagsPanel = panel
        panel.show()
    }

    @objc private func contextMenuEditVideoTags(_ sender: NSMenuItem) {
        let videoItem: EditVideoTagsPanel.VideoItem
        if let movie = sender.representedObject as? LocalVideo {
            videoItem = .movie(movie)
        } else if let episode = sender.representedObject as? LocalEpisode {
            videoItem = .episode(episode)
        } else {
            return
        }

        activeEditVideoTagsPanel?.close()
        let panel = EditVideoTagsPanel(item: videoItem)
        panel.delegate = self
        panel.onSave = { [weak self] in self?.model.reloadLocalBrowserAfterMetadataEdit() }
        activeEditVideoTagsPanel = panel
        panel.show()
    }

    @objc private func contextMenuRateLocalAlbum(_ sender: NSMenuItem) {
        guard let albumId = sender.representedObject as? String else { return }
        let rating = sender.tag
        MediaLibrary.shared.setAlbumRating(albumId: albumId, rating: rating >= 0 ? rating : nil)
        needsDisplay = true
    }

    @objc private func contextMenuRateLocalArtist(_ sender: NSMenuItem) {
        guard let artistId = sender.representedObject as? String else { return }
        let rating = sender.tag
        MediaLibrary.shared.setArtistRating(artistId: artistId, rating: rating >= 0 ? rating : nil)
        needsDisplay = true
    }
    
    @objc private func contextMenuShowInFinder(_ sender: NSMenuItem) {
        guard let track = sender.representedObject as? LibraryTrack else { return }
        NSWorkspace.shared.activateFileViewerSelecting([track.url])
    }
    
    @objc private func contextMenuRemoveLocalTrack(_ sender: NSMenuItem) {
        guard let track = sender.representedObject as? LibraryTrack else { return }
        let tracksToRemove = selectedLocalTracksForContextAction(fallback: track)
        if tracksToRemove.count == 1 {
            MediaLibrary.shared.removeTrack(track)
        } else {
            MediaLibrary.shared.removeTracks(urls: tracksToRemove.map { $0.url })
        }
    }
    
    @objc private func contextMenuDeleteLocalTrack(_ sender: NSMenuItem) {
        guard let track = sender.representedObject as? LibraryTrack else { return }
        let tracksToDelete = selectedLocalTracksForContextAction(fallback: track)
        deleteTracksFromDisk(tracksToDelete)
    }
    
    @objc private func contextMenuRemoveLocalAlbum(_ sender: NSMenuItem) {
        guard let album = sender.representedObject as? Album else { return }
        let tracks = LibraryPlayable.libraryTracks(of: album)

        let alert = NSAlert()
        alert.messageText = "Remove album from library?"
        alert.informativeText = "This will remove \(tracks.count) tracks from your library. The files will not be deleted from disk."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            MediaLibrary.shared.removeTracks(urls: tracks.map { $0.url })
        }
    }

    @objc private func contextMenuDeleteLocalAlbum(_ sender: NSMenuItem) {
        guard let album = sender.representedObject as? Album else { return }
        deleteTracksFromDisk(LibraryPlayable.libraryTracks(of: album))
    }

    @objc private func contextMenuRemoveLocalArtist(_ sender: NSMenuItem) {
        guard let artist = sender.representedObject as? Artist else { return }

        let artistsToRemove = selectedLocalArtistsForContextAction(fallback: artist)
        let store = MediaLibraryStore.shared
        let allTracks = dedupeTracksByURL(
            artistsToRemove.flatMap { a in
                store.albumsForArtist(a.name).flatMap { store.tracksForAlbum($0.id) }
            }
        )
        
        let alert = NSAlert()
        if artistsToRemove.count == 1 {
            alert.messageText = "Remove artist from library?"
        } else {
            alert.messageText = "Remove \(artistsToRemove.count) artists from library?"
        }
        alert.informativeText = "This will remove \(allTracks.count) tracks from your library. The files will not be deleted from disk."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            MediaLibrary.shared.removeTracks(urls: allTracks.map { $0.url })
        }
    }
    
    // MARK: - Radio Station Context Menu Actions
    
    @objc private func contextMenuPlayRadioStation(_ sender: NSMenuItem) {
        guard let station = sender.representedObject as? RadioStation else { return }
        playRadioStation(station)
    }
    
    @objc private func contextMenuEditRadioStation(_ sender: NSMenuItem) {
        guard let station = sender.representedObject as? RadioStation else { return }
        
        activeRadioStationSheet = AddRadioStationSheet(station: station)
        activeRadioStationSheet?.showDialog { [weak self] updatedStation in
            self?.activeRadioStationSheet = nil  // Release reference when done
            if let updated = updatedStation {
                RadioManager.shared.updateStation(updated)
                self?.model.reloadInternetRadioForCurrentMode()
            }
        }
    }
    
    @objc private func contextMenuDeleteRadioStation(_ sender: NSMenuItem) {
        guard let station = sender.representedObject as? RadioStation else { return }
        
        let alert = NSAlert()
        alert.messageText = "Delete radio station?"
        alert.informativeText = "Are you sure you want to delete '\(station.name)'?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            RadioManager.shared.removeStation(station)
            model.reloadInternetRadioForCurrentMode()
        }
    }

    @objc private func contextMenuRenameRadioFolder(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? RadioFolderRenameAction else { return }
        guard let existing = RadioManager.shared.userRadioFolders().first(where: { $0.id == action.folderID }) else { return }
        guard let name = promptForRadioFolderName(
            title: "Rename Folder",
            message: "Enter a new name:",
            confirmTitle: "Rename",
            defaultValue: existing.name
        ) else { return }
        guard RadioManager.shared.renameUserFolder(id: action.folderID, to: name) else {
            let alert = NSAlert()
            alert.messageText = "Unable to Rename Folder"
            alert.informativeText = "Use a unique, non-empty folder name."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        model.reloadInternetRadioForCurrentMode()
    }

    @objc private func contextMenuDeleteRadioFolder(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? RadioFolderDeleteAction else { return }
        guard let existing = RadioManager.shared.userRadioFolders().first(where: { $0.id == action.folderID }) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete Folder?"
        alert.informativeText = "Delete '\(existing.name)' and its station memberships?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = RadioManager.shared.deleteUserFolder(id: action.folderID)
        model.reloadInternetRadioForCurrentMode()
    }

    @objc private func contextMenuToggleStationFolderMembership(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? RadioFolderMembershipAction else { return }
        if RadioManager.shared.isStation(action.station, inUserFolderID: action.folderID) {
            _ = RadioManager.shared.removeStation(action.station, fromUserFolderID: action.folderID)
        } else {
            _ = RadioManager.shared.addStation(action.station, toUserFolderID: action.folderID)
        }
        model.reloadInternetRadioForCurrentMode()
    }

    @objc private func contextMenuRefreshYouTubeChannel(_ sender: NSMenuItem) {
        guard let channel = sender.representedObject as? YouTubeChannel else { return }
        model.refreshYouTubeChannel(channel)
    }

    @objc private func contextMenuRemoveYouTubeChannel(_ sender: NSMenuItem) {
        guard let channel = sender.representedObject as? YouTubeChannel else { return }
        model.removeYouTubeChannel(channel)
    }

    @objc private func contextMenuAssignStationSmartGenre(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? RadioSmartGenreAction else { return }
        _ = RadioManager.shared.setSmartGenreOverride(action.genre, for: action.station)
        model.reloadInternetRadioForCurrentMode()
    }

    @objc private func contextMenuAssignStationSmartRegion(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? RadioSmartRegionAction else { return }
        _ = RadioManager.shared.setSmartRegionOverride(action.region, for: action.station)
        model.reloadInternetRadioForCurrentMode()
    }

    @objc private func contextMenuCreateRadioFolderAndAddStation(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? RadioFolderStationAction else { return }
        guard let name = promptForRadioFolderName(
            title: "New Folder",
            message: "Create a folder and add '\(action.station.name)' to it:",
            confirmTitle: "Create"
        ) else { return }
        guard let folder = RadioManager.shared.createUserFolder(named: name) else {
            let alert = NSAlert()
            alert.messageText = "Unable to Create Folder"
            alert.informativeText = "Use a unique, non-empty folder name."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        _ = RadioManager.shared.addStation(action.station, toUserFolderID: folder.id)
        model.reloadInternetRadioForCurrentMode()
    }
    
    // MARK: - Plex Radio Station Context Menu Actions
    
    @objc private func contextMenuPlayPlexRadioStation(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? LibraryBrowserItem,
              case .plexRadioStation(let radioType) = item.type else { return }
        playPlexRadioStation(radioType)
    }

    @objc private func contextMenuPlaySubsonicRadioStation(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? LibraryBrowserItem,
              case .subsonicRadioStation(let radioType) = item.type else { return }
        playSubsonicRadioStation(radioType)
    }

    @objc private func contextMenuPlayJellyfinRadioStation(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? LibraryBrowserItem,
              case .jellyfinRadioStation(let radioType) = item.type else { return }
        playJellyfinRadioStation(radioType)
    }

    @objc private func contextMenuPlayEmbyRadioStation(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? LibraryBrowserItem,
              case .embyRadioStation(let radioType) = item.type else { return }
        playEmbyRadioStation(radioType)
    }

    @objc private func contextMenuPlayLocalRadioStation(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? LibraryBrowserItem,
              case .localRadioStation(let radioType) = item.type else { return }
        playLocalRadioStation(radioType)
    }
    
    
    @objc private func contextMenuDeleteLocalArtist(_ sender: NSMenuItem) {
        guard let artist = sender.representedObject as? Artist else { return }

        let artistsToDelete = selectedLocalArtistsForContextAction(fallback: artist)
        let store = MediaLibraryStore.shared
        let allTracks = dedupeTracksByURL(
            artistsToDelete.flatMap { a in
                store.albumsForArtist(a.name).flatMap { store.tracksForAlbum($0.id) }
            }
        )
        deleteTracksFromDisk(allTracks)
    }

    /// For local-track context actions, prefer current multi-selection when the
    /// clicked track is part of it; otherwise fall back to the clicked track.
    private func selectedLocalTracksForContextAction(fallback track: LibraryTrack) -> [LibraryTrack] {
        let selectedTracks = selectedIndices
            .filter { $0 >= 0 && $0 < model.displayItems.count }
            .sorted()
            .compactMap { index -> LibraryTrack? in
                guard case .localTrack(let selectedTrack) = model.displayItems[index].type else { return nil }
                return selectedTrack
            }

        guard selectedTracks.count > 1,
              selectedTracks.contains(where: { $0.url == track.url }) else {
            return [track]
        }

        var seen = Set<URL>()
        return selectedTracks.filter { seen.insert($0.url).inserted }
    }

    /// For local-artist context actions, prefer current multi-selection when the
    /// clicked artist is part of it; otherwise fall back to the clicked artist.
    private func selectedLocalArtistsForContextAction(fallback artist: Artist) -> [Artist] {
        let selectedArtists = selectedIndices
            .filter { $0 >= 0 && $0 < model.displayItems.count }
            .sorted()
            .compactMap { index -> Artist? in
                guard case .localArtist(let selectedArtist) = model.displayItems[index].type else { return nil }
                return selectedArtist
            }

        guard selectedArtists.count > 1,
              selectedArtists.contains(where: { $0.id == artist.id }) else {
            return [artist]
        }

        var seen = Set<String>()
        return selectedArtists.filter { seen.insert($0.id).inserted }
    }

    private func dedupeTracksByURL(_ tracks: [LibraryTrack]) -> [LibraryTrack] {
        var seen = Set<URL>()
        return tracks.filter { seen.insert($0.url).inserted }
    }
    
    /// Helper to delete tracks from disk with confirmation
    private func deleteTracksFromDisk(_ tracks: [LibraryTrack]) {
        guard !tracks.isEmpty else { return }
        
        let alert = NSAlert()
        alert.messageText = tracks.count == 1
            ? "Delete file from disk?"
            : "Delete \(tracks.count) files from disk?"
        alert.informativeText = "This will permanently delete the file(s) from your computer. This action cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        
        let moveToTrashCheckbox = NSButton(checkboxWithTitle: "Move to Trash instead of deleting permanently", target: nil, action: nil)
        moveToTrashCheckbox.state = .on
        alert.accessoryView = moveToTrashCheckbox
        
        if alert.runModal() != .alertFirstButtonReturn {
            return
        }
        
        let useTrash = moveToTrashCheckbox.state == .on
        var failedFiles: [String] = []
        var removedTrackURLs: [URL] = []
        
        for track in tracks {
            do {
                if useTrash {
                    try FileManager.default.trashItem(at: track.url, resultingItemURL: nil)
                } else {
                    try FileManager.default.removeItem(at: track.url)
                }
                removedTrackURLs.append(track.url)
            } catch {
                failedFiles.append(track.url.lastPathComponent)
            }
        }

        if !removedTrackURLs.isEmpty {
            if removedTrackURLs.count == 1, let firstURL = removedTrackURLs.first,
               let removedTrack = tracks.first(where: { $0.url == firstURL }) {
                MediaLibrary.shared.removeTrack(removedTrack)
            } else {
                MediaLibrary.shared.removeTracks(urls: removedTrackURLs)
            }
        }
        
        if !failedFiles.isEmpty {
            let errorAlert = NSAlert()
            errorAlert.messageText = "Some files could not be deleted"
            errorAlert.informativeText = "Failed to delete:\n" + failedFiles.prefix(5).joined(separator: "\n")
            if failedFiles.count > 5 {
                errorAlert.informativeText += "\n...and \(failedFiles.count - 5) more"
            }
            errorAlert.alertStyle = .warning
            errorAlert.runModal()
        }
    }
    
    @objc private func contextMenuShowLocalVideoInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? NSURL as URL? else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func contextMenuCastLocalVideo(_ sender: NSMenuItem) {
        guard let (url, title, device) = sender.representedObject as? (URL, String, CastDevice) else { return }
        if WindowManager.shared.isVideoCastingActive {
            let alert = NSAlert()
            alert.messageText = "Already Casting"
            alert.informativeText = "Stop the current cast before starting a new one."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        Task { @MainActor in
            do {
                try await CastManager.shared.castLocalVideo(url, title: title, to: device)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Cast Failed"
                alert.informativeText = error.localizedDescription.redactingSensitiveURLQueryItems
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    // MARK: - Plex Context Menu Actions

    @objc private func contextMenuRevealLocalFolderInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Keyboard Shortcut Helpers
    
    /// Shift+Enter / Option+Enter: the menu's Play Next / Add to Queue on the selected row.
    private func runVerbOnSelection(_ verb: TrackVerb) {
        guard let index = selectedIndices.first, index < model.displayItems.count,
              let playable = playable(for: model.displayItems[index]) else { return }
        verb.run(resolver(for: playable))
    }

    /// The row's tracks for a play verb, from its menu, Enter or double-click. A server playlist is
    /// fetched behind the loading screen, which shows the error if the fetch fails.
    private func resolver(for playable: LibraryPlayable) -> @MainActor () async throws -> [Track] {
        switch playable {
        case .plexPlaylist, .subsonicPlaylist, .jellyfinPlaylist, .embyPlaylist:
            return { [weak self] in
                guard let self else { throw CancellationError() }
                model.isLoading = true; model.errorMessage = nil; startLoadingAnimation(); needsDisplay = true
                defer { model.isLoading = false; stopLoadingAnimation(); needsDisplay = true }
                do {
                    return try await playable.tracks()
                } catch {
                    model.errorMessage = "Failed to load playlist: \(error.localizedDescription.redactingSensitiveURLQueryItems)"
                    throw error
                }
            }
        default:
            return { try await playable.tracks() }
        }
    }

    /// The row as tracks for the play verbs; nil for a row with no basic play menu (radio,
    /// YouTube, containers that only expand).
    private func playable(for item: LibraryBrowserItem) -> LibraryPlayable? {
        switch item.type {
        case .track(let t): return .plexTrack(t)
        case .album(let a): return .plexAlbum(a)
        case .artist(let a):
            return .plexArtistGroup(members: model.plexArtistGroup(for: a),
                                    albums: model.plexCountedAlbums(for: a))
        case .plexPlaylist(let p): return .plexPlaylist(p)
        case .localTrack(let t): return .localTrack(t)
        case .localAlbum(let a): return .localAlbum(a)
        case .localArtist(let a): return .localArtist(a)
        case .localFolder(let url, _): return .localFolder(url)
        case .localPlaylist(let p): return .localPlaylist(p.url)
        case .localPlaylistTrack(let t): return .tracks([t])
        case .subsonicTrack(let s): return .subsonicSong(s)
        case .subsonicAlbum(let a): return .subsonicAlbum(a)
        case .subsonicArtist(let a): return .subsonicArtist(a)
        case .subsonicPlaylist(let p): return .subsonicPlaylist(p)
        case .jellyfinTrack(let s): return .jellyfinSong(s)
        case .jellyfinAlbum(let a): return .jellyfinAlbum(a)
        case .jellyfinArtist(let a): return .jellyfinArtist(a)
        case .jellyfinPlaylist(let p): return .jellyfinPlaylist(p)
        case .embyTrack(let s): return .embySong(s)
        case .embyAlbum(let a): return .embyAlbum(a)
        case .embyArtist(let a): return .embyArtist(a)
        case .embyPlaylist(let p): return .embyPlaylist(p)
        case .movie(let m): return .plexMovie(m)
        case .episode(let e): return .plexEpisode(e)
        case .season(let s): return .plexSeason(s)
        case .show(let s): return .plexShow(s)
        case .localMovie(let m): return .localMovie(m)
        case .localEpisode(let e): return .localEpisodes([e])
        case .localSeason(let s, _): return .localEpisodes(s.episodes)
        case .localShow(let s): return .localEpisodes(s.episodes)
        case .jellyfinMovie(let m): return .jellyfinMovie(m)
        case .jellyfinEpisode(let e): return .jellyfinEpisode(e)
        case .jellyfinSeason(let s): return .jellyfinSeason(s)
        case .jellyfinShow(let s): return .jellyfinShow(s)
        case .embyMovie(let m): return .embyMovie(m)
        case .embyEpisode(let e): return .embyEpisode(e)
        case .embySeason(let s): return .embySeason(s)
        case .embyShow(let s): return .embyShow(s)
        case .header, .radioStation, .radioFolder, .youtubeChannel, .youtubeVideo, .plexRadioStation,
             .subsonicRadioStation, .jellyfinRadioStation, .embyRadioStation, .localRadioStation:
            return nil
        }
    }

    // MARK: - Plex Radio Actions
    
    @objc private func contextMenuStartTrackRadio(_ sender: NSMenuItem) {
        NSLog("contextMenuStartTrackRadio called, representedObject type: %@", String(describing: type(of: sender.representedObject)))
        guard let track = sender.representedObject as? PlexTrack else {
            NSLog("contextMenuStartTrackRadio: representedObject is NOT a PlexTrack, it's: %@", String(describing: sender.representedObject))
            return
        }
        NSLog("contextMenuStartTrackRadio: Starting radio for track: %@", track.title)
        startTrackRadio(track)
    }
    
    @objc private func contextMenuStartAlbumRadio(_ sender: NSMenuItem) {
        guard let album = sender.representedObject as? PlexAlbum else { return }
        startAlbumRadio(album)
    }
    
    @objc private func contextMenuStartArtistRadio(_ sender: NSMenuItem) {
        guard let artist = sender.representedObject as? PlexArtist else { return }
        startArtistRadio(artist)
    }
    
    /// Start a track radio - plays similar tracks based on the seed track
    private func startTrackRadio(_ track: PlexTrack) {
        NSLog("startTrackRadio called for: %@ (id: %@)", track.title, track.id)
        
        Task { @MainActor in
            NSLog("startTrackRadio: Creating radio playlist...")
            let tracks = await PlexManager.shared.createTrackRadio(from: track, limit: RadioPlaybackOptions.playlistLength)
            
            NSLog("startTrackRadio: Got %d tracks from PlexManager", tracks.count)
            
            if tracks.isEmpty {
                NSLog("Track Radio: No similar tracks found for '%@'", track.title)
                // Could show an alert here if desired
                return
            }
            
            // Clear current playlist, load radio tracks, and start playing
            NSLog("startTrackRadio: Loading tracks into audio engine...")
            let audioEngine = WindowManager.shared.audioEngine
            audioEngine.loadTracks(tracks)
            NSLog("Track Radio started with %d tracks", tracks.count)
        }
    }
    
    /// Start an album radio - plays tracks similar to the album's content
    private func startAlbumRadio(_ album: PlexAlbum) {
        NSLog("Starting Album Radio for: %@", album.title)
        
        Task { @MainActor in
            let tracks = await PlexManager.shared.createAlbumRadio(from: album, limit: RadioPlaybackOptions.playlistLength)
            
            if tracks.isEmpty {
                NSLog("Album Radio: No similar tracks found for '%@'", album.title)
                return
            }
            
            // Clear current playlist, load radio tracks, and start playing
            let audioEngine = WindowManager.shared.audioEngine
            audioEngine.loadTracks(tracks)
            NSLog("Album Radio started with %d tracks", tracks.count)
        }
    }
    
    /// Start an artist radio - plays tracks from similar artists
    private func startArtistRadio(_ artist: PlexArtist) {
        NSLog("Starting Artist Radio for: %@", artist.title)
        
        Task { @MainActor in
            let tracks = await PlexManager.shared.createArtistRadio(from: artist, limit: RadioPlaybackOptions.playlistLength)
            
            if tracks.isEmpty {
                NSLog("Artist Radio: No similar tracks found for '%@'", artist.title)
                return
            }
            
            // Clear current playlist, load radio tracks, and start playing
            let audioEngine = WindowManager.shared.audioEngine
            audioEngine.loadTracks(tracks)
            NSLog("Artist Radio started with %d tracks", tracks.count)
        }
    }
    
    /// Start a library radio - plays random sonically diverse tracks from the library
    private func startLibraryRadio() {
        guard let library = PlexManager.shared.currentLibrary else { return }
        NSLog("Starting Library Radio for: %@", library.title)
        
        Task { @MainActor in
            let tracks = await PlexManager.shared.createLibraryRadio()
            guard !tracks.isEmpty else { return }
            
            let audioEngine = WindowManager.shared.audioEngine
            audioEngine.loadTracks(tracks)
            NSLog("Library Radio started with %d tracks", tracks.count)
        }
    }
    
    @objc private func contextMenuToggleExpand(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? LibraryBrowserItem else { return }
        model.toggleExpand(item)
    }
    
    @objc private func contextMenuCastMovie(_ sender: NSMenuItem) {
        NSLog("PlexBrowserView: contextMenuCastMovie ENTER")
        guard let (movie, device) = sender.representedObject as? (PlexMovie, CastDevice) else {
            NSLog("PlexBrowserView: Failed to get movie/device from menu item")
            return
        }
        
        NSLog("PlexBrowserView: Casting movie '%@' to device '%@' (type: %@)", movie.title, device.name, device.type.rawValue)
        
        // Prevent dual casting - check if already casting
        if WindowManager.shared.isVideoCastingActive {
            NSLog("PlexBrowserView: Cannot cast - already casting")
            let alert = NSAlert()
            alert.messageText = "Already Casting"
            alert.informativeText = "Stop the current cast before starting a new one."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        
        Task { @MainActor in
            NSLog("PlexBrowserView: Starting cast Task")
            do {
                try await CastManager.shared.castPlexMovie(movie, to: device)
                NSLog("PlexBrowserView: Cast movie '%@' to %@ - SUCCESS", movie.title, device.name)
            } catch {
                NSLog("PlexBrowserView: Failed to cast movie: %@", error.localizedDescription.redactingSensitiveURLQueryItems)
                let alert = NSAlert()
                alert.messageText = "Cast Failed"
                alert.informativeText = error.localizedDescription.redactingSensitiveURLQueryItems
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
        NSLog("PlexBrowserView: contextMenuCastMovie EXIT (Task launched)")
    }
    
    @objc private func contextMenuCastEpisode(_ sender: NSMenuItem) {
        guard let (episode, device) = sender.representedObject as? (PlexEpisode, CastDevice) else { return }
        
        // Prevent dual casting - check if already casting
        if WindowManager.shared.isVideoCastingActive {
            NSLog("PlexBrowserView: Cannot cast - already casting")
            let alert = NSAlert()
            alert.messageText = "Already Casting"
            alert.informativeText = "Stop the current cast before starting a new one."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        
        Task {
            do {
                try await CastManager.shared.castPlexEpisode(episode, to: device)
                NSLog("PlexBrowserView: Cast episode '%@' to %@", episode.title, device.name)
            } catch {
                NSLog("PlexBrowserView: Failed to cast episode: %@", error.localizedDescription.redactingSensitiveURLQueryItems)
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Cast Failed"
                    alert.informativeText = error.localizedDescription.redactingSensitiveURLQueryItems
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }
    
    // MARK: - External Links Context Menu Actions
    
    @objc private func contextMenuOpenIMDB(_ sender: NSMenuItem) {
        guard let movie = sender.representedObject as? PlexMovie else { return }
        
        // If we already have the IMDB ID, open directly
        if let imdbId = movie.imdbId {
            if let url = URL(string: "https://www.imdb.com/title/\(imdbId)/") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        
        // Fetch detailed metadata to get IMDB ID
        Task { @MainActor in
            do {
                if let detailed = try await PlexManager.shared.fetchMovieDetails(movieID: movie.id),
                   let imdbId = detailed.imdbId,
                   let url = URL(string: "https://www.imdb.com/title/\(imdbId)/") {
                    NSWorkspace.shared.open(url)
                    return
                }
            } catch {
                NSLog("Failed to fetch movie details: %@", error.localizedDescription.redactingSensitiveURLQueryItems)
            }
            // Fallback to search if fetch fails
            if let url = movie.imdbURL {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    @objc private func contextMenuOpenTMDB(_ sender: NSMenuItem) {
        guard let movie = sender.representedObject as? PlexMovie else { return }
        
        if let tmdbId = movie.tmdbId {
            if let url = URL(string: "https://www.themoviedb.org/movie/\(tmdbId)") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        
        Task { @MainActor in
            do {
                if let detailed = try await PlexManager.shared.fetchMovieDetails(movieID: movie.id),
                   let tmdbId = detailed.tmdbId,
                   let url = URL(string: "https://www.themoviedb.org/movie/\(tmdbId)") {
                    NSWorkspace.shared.open(url)
                    return
                }
            } catch {
                NSLog("Failed to fetch movie details: %@", error.localizedDescription.redactingSensitiveURLQueryItems)
            }
            if let url = movie.tmdbURL {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    @objc private func contextMenuOpenRottenTomatoes(_ sender: NSMenuItem) {
        guard let movie = sender.representedObject as? PlexMovie,
              let url = movie.rottenTomatoesSearchURL else { return }
        NSWorkspace.shared.open(url)
    }
    
    @objc private func contextMenuOpenIMDBShow(_ sender: NSMenuItem) {
        guard let show = sender.representedObject as? PlexShow else { return }
        
        if let imdbId = show.imdbId {
            if let url = URL(string: "https://www.imdb.com/title/\(imdbId)/") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        
        Task { @MainActor in
            do {
                if let detailed = try await PlexManager.shared.fetchShowDetails(showID: show.id),
                   let imdbId = detailed.imdbId,
                   let url = URL(string: "https://www.imdb.com/title/\(imdbId)/") {
                    NSWorkspace.shared.open(url)
                    return
                }
            } catch {
                NSLog("Failed to fetch show details: %@", error.localizedDescription.redactingSensitiveURLQueryItems)
            }
            if let url = show.imdbURL {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    @objc private func contextMenuOpenTMDBShow(_ sender: NSMenuItem) {
        guard let show = sender.representedObject as? PlexShow else { return }
        
        if let tmdbId = show.tmdbId {
            if let url = URL(string: "https://www.themoviedb.org/tv/\(tmdbId)") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        
        Task { @MainActor in
            do {
                if let detailed = try await PlexManager.shared.fetchShowDetails(showID: show.id),
                   let tmdbId = detailed.tmdbId,
                   let url = URL(string: "https://www.themoviedb.org/tv/\(tmdbId)") {
                    NSWorkspace.shared.open(url)
                    return
                }
            } catch {
                NSLog("Failed to fetch show details: %@", error.localizedDescription.redactingSensitiveURLQueryItems)
            }
            if let url = show.tmdbURL {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    @objc private func contextMenuOpenRottenTomatoesShow(_ sender: NSMenuItem) {
        guard let show = sender.representedObject as? PlexShow,
              let url = show.rottenTomatoesSearchURL else { return }
        NSWorkspace.shared.open(url)
    }
    
    @objc private func contextMenuOpenIMDBEpisode(_ sender: NSMenuItem) {
        guard let episode = sender.representedObject as? PlexEpisode else { return }
        
        if let imdbId = episode.imdbId {
            if let url = URL(string: "https://www.imdb.com/title/\(imdbId)/") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        
        Task { @MainActor in
            do {
                if let detailed = try await PlexManager.shared.fetchEpisodeDetails(episodeID: episode.id),
                   let imdbId = detailed.imdbId,
                   let url = URL(string: "https://www.imdb.com/title/\(imdbId)/") {
                    NSWorkspace.shared.open(url)
                    return
                }
            } catch {
                NSLog("Failed to fetch episode details: %@", error.localizedDescription.redactingSensitiveURLQueryItems)
            }
            if let url = episode.imdbURL {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    @objc private func contextMenuOpenTMDBEpisode(_ sender: NSMenuItem) {
        guard let episode = sender.representedObject as? PlexEpisode else { return }
        
        // Episodes don't have individual TMDB IDs, use search
        if let url = episode.tmdbSearchURL {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc private func contextMenuOpenRottenTomatoesEpisode(_ sender: NSMenuItem) {
        guard let episode = sender.representedObject as? PlexEpisode,
              let url = episode.rottenTomatoesSearchURL else { return }
        NSWorkspace.shared.open(url)
    }
    
    // MARK: - Server/Library Selection Menus
    
    private func showServerMenu(at event: NSEvent) {
        let menu = NSMenu()
        
        let servers = PlexManager.shared.servers
        if servers.isEmpty {
            let noServers = NSMenuItem(title: "No servers available", action: nil, keyEquivalent: "")
            noServers.isEnabled = false
            menu.addItem(noServers)
        } else {
            for server in servers {
                let item = NSMenuItem(title: server.name, action: #selector(selectServer(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = server.id
                item.state = server.id == PlexManager.shared.currentServer?.id ? .on : .off
                menu.addItem(item)
            }
        }
        
        menu.addItem(NSMenuItem.separator())
        
        let refreshItem = NSMenuItem(title: "Refresh Servers", action: #selector(refreshServers), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)
        
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    
    private func showLibraryMenu(at event: NSEvent) {
        let menu = NSMenu()
        
        let libraries = PlexManager.shared.availableLibraries
        let currentLibraryId = PlexManager.shared.currentLibrary?.id
        
        if libraries.isEmpty {
            let noLibraries = NSMenuItem(title: "No libraries available", action: nil, keyEquivalent: "")
            noLibraries.isEnabled = false
            menu.addItem(noLibraries)
        } else {
            for library in libraries {
                // Show library type in parentheses
                let typeLabel: String
                if library.isMusicLibrary {
                    typeLabel = "Music"
                } else if library.isMovieLibrary {
                    typeLabel = "Movies"
                } else if library.isShowLibrary {
                    typeLabel = "TV Shows"
                } else {
                    typeLabel = library.type
                }
                
                let item = NSMenuItem(title: "\(library.title) (\(typeLabel))", action: #selector(selectLibrary(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = library
                item.state = library.id == currentLibraryId ? .on : .off
                menu.addItem(item)
            }
        }
        
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func showSubsonicFolderMenu(at event: NSEvent) {
        let menu = NSMenu()
        let folders = SubsonicManager.shared.musicFolders
        let currentId = SubsonicManager.shared.currentMusicFolder?.id

        let allItem = NSMenuItem(title: "All Folders", action: #selector(selectSubsonicMusicFolder(_:)), keyEquivalent: "")
        allItem.target = self
        allItem.representedObject = Optional<SubsonicMusicFolder>.none as Any
        allItem.state = currentId == nil ? .on : .off
        menu.addItem(allItem)

        if !folders.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }

        for folder in folders {
            let item = NSMenuItem(title: folder.name, action: #selector(selectSubsonicMusicFolder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = folder
            item.state = folder.id == currentId ? .on : .off
            menu.addItem(item)
        }

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func showJellyfinLibraryMenu(at event: NSEvent) {
        let menu = NSMenu()
        let libraries = JellyfinManager.shared.musicLibraries
        let currentId = JellyfinManager.shared.currentMusicLibrary?.id

        let allItem = NSMenuItem(title: "All Libraries", action: #selector(selectJellyfinMusicLibrary(_:)), keyEquivalent: "")
        allItem.target = self
        allItem.representedObject = Optional<JellyfinMusicLibrary>.none as Any
        allItem.state = currentId == nil ? .on : .off
        menu.addItem(allItem)

        if !libraries.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }

        for library in libraries {
            let item = NSMenuItem(title: "\(library.name) (Music)", action: #selector(selectJellyfinMusicLibrary(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = library
            item.state = library.id == currentId ? .on : .off
            menu.addItem(item)
        }

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func showJellyfinVideoLibraryMenu(at event: NSEvent) {
        let menu = NSMenu()
        let libraries = JellyfinManager.shared.videoLibraries
        let currentMovieId = JellyfinManager.shared.currentMovieLibrary?.id
        let currentShowId = JellyfinManager.shared.currentShowLibrary?.id
        let activeId = model.browseMode == .shows ? currentShowId : currentMovieId

        let allItem = NSMenuItem(title: "All Libraries", action: #selector(selectJellyfinVideoLibraryFromBrowser(_:)), keyEquivalent: "")
        allItem.target = self
        allItem.representedObject = Optional<JellyfinMusicLibrary>.none as Any
        allItem.state = activeId == nil ? .on : .off
        menu.addItem(allItem)

        if !libraries.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }

        for library in libraries {
            let typeLabel = library.collectionType == "tvshows" ? "TV Shows" : "Movies"
            let item = NSMenuItem(title: "\(library.name) (\(typeLabel))", action: #selector(selectJellyfinVideoLibraryFromBrowser(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = library
            item.state = library.id == activeId ? .on : .off
            menu.addItem(item)
        }

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func showEmbyLibraryMenu(at event: NSEvent) {
        let menu = NSMenu()
        let libraries = EmbyManager.shared.musicLibraries
        let currentId = EmbyManager.shared.currentMusicLibrary?.id

        let allItem = NSMenuItem(title: "All Libraries", action: #selector(selectEmbyMusicLibraryFromBrowser(_:)), keyEquivalent: "")
        allItem.target = self
        allItem.representedObject = Optional<EmbyMusicLibrary>.none as Any
        allItem.state = currentId == nil ? .on : .off
        menu.addItem(allItem)

        if !libraries.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }

        for library in libraries {
            let item = NSMenuItem(title: "\(library.name) (Music)", action: #selector(selectEmbyMusicLibraryFromBrowser(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = library
            item.state = library.id == currentId ? .on : .off
            menu.addItem(item)
        }

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func showEmbyVideoLibraryMenu(at event: NSEvent) {
        let menu = NSMenu()
        let libraries = EmbyManager.shared.videoLibraries
        let currentMovieId = EmbyManager.shared.currentMovieLibrary?.id
        let currentShowId = EmbyManager.shared.currentShowLibrary?.id
        let activeId = model.browseMode == .shows ? currentShowId : currentMovieId

        let allItem = NSMenuItem(title: "All Libraries", action: #selector(selectEmbyVideoLibraryFromBrowser(_:)), keyEquivalent: "")
        allItem.target = self
        allItem.representedObject = Optional<EmbyMusicLibrary>.none as Any
        allItem.state = activeId == nil ? .on : .off
        menu.addItem(allItem)

        if !libraries.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }

        for library in libraries {
            let typeLabel = library.collectionType == "tvshows" ? "TV Shows" : "Movies"
            let item = NSMenuItem(title: "\(library.name) (\(typeLabel))", action: #selector(selectEmbyVideoLibraryFromBrowser(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = library
            item.state = library.id == activeId ? .on : .off
            menu.addItem(item)
        }

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    
    @objc private func selectServer(_ sender: NSMenuItem) {
        guard let serverID = sender.representedObject as? String,
              let server = PlexManager.shared.servers.first(where: { $0.id == serverID }) else {
            return
        }
        model.currentSource = .plex(serverId: server.id)
    }
    
    @objc private func selectSortOption(_ sender: NSMenuItem) {
        guard let option = sender.representedObject as? LibraryBrowserSortOption else { return }
        model.selectMenuSort(option)
    }

    @objc private func selectLibrary(_ sender: NSMenuItem) {
        guard let library = sender.representedObject as? PlexLibrary else { return }
        model.selectPlexLibrary(library)
    }

    @objc private func selectSubsonicMusicFolder(_ sender: NSMenuItem) {
        model.selectSubsonicMusicFolder(sender.representedObject as? SubsonicMusicFolder)
    }

    @objc private func selectJellyfinMusicLibrary(_ sender: NSMenuItem) {
        model.selectJellyfinMusicLibrary(sender.representedObject as? JellyfinMusicLibrary)
    }

    @objc private func selectJellyfinVideoLibraryFromBrowser(_ sender: NSMenuItem) {
        model.selectJellyfinVideoLibrary(sender.representedObject as? JellyfinMusicLibrary)
    }

    @objc private func selectEmbyMusicLibraryFromBrowser(_ sender: NSMenuItem) {
        model.selectEmbyMusicLibrary(sender.representedObject as? EmbyMusicLibrary)
    }

    @objc private func selectEmbyVideoLibraryFromBrowser(_ sender: NSMenuItem) {
        model.selectEmbyVideoLibrary(sender.representedObject as? EmbyMusicLibrary)
    }

    @objc private func refreshServers() {
        Task { @MainActor in
            do {
                try await PlexManager.shared.refreshServers()
                needsDisplay = true
            } catch {
                NSLog("Failed to refresh servers: %@", error.localizedDescription.redactingSensitiveURLQueryItems)
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if model.browseMode.isHistoryMode {
            super.scrollWheel(with: event)
            return
        }

        let layout = listLayout()
        let listHeight = layout.rows.height
        let totalHeight = CGFloat(model.displayItems.count) * itemHeight
        let verticalDelta = verticalScrollDelta(from: event)
        let horizontalDelta = horizontalScrollDelta(from: event)
        var needsRedraw = false

        if let header = layout.header,
           event.modifierFlags.contains(.shift) || abs(horizontalDelta) > abs(verticalDelta) {
            let totalWidth = totalColumnsWidth(columns: header.columns, group: header.group)
            let maxOffset = max(0, totalWidth - header.rect.width)
            if maxOffset > 0 {
                let delta = event.modifierFlags.contains(.shift) ? verticalDelta : horizontalDelta
                horizontalScrollOffset = max(0, min(maxOffset, horizontalScrollOffset - delta))
                needsRedraw = true
            }
        }

        if totalHeight > listHeight && verticalDelta != 0 && !event.modifierFlags.contains(.shift) {
            scrollOffset = max(0, min(totalHeight - listHeight, scrollOffset - verticalDelta))
            needsRedraw = true
        }

        if needsRedraw {
            // The list and the status bar under it, full width so the side borders' scroll thumb follows.
            setNeedsDisplay(convertFromSkinCoordinates(NSRect(x: 0, y: layout.area.minY, width: bounds.width,
                                                              height: layout.area.height + Layout.statusBarHeight)))
        }

        if case .local = model.currentSource { loadNextLocalPageIfNeeded(listHeight: listHeight) }
    }

    private func verticalScrollDelta(from event: NSEvent) -> CGFloat {
        if event.hasPreciseScrollingDeltas, event.scrollingDeltaY != 0 {
            return event.scrollingDeltaY
        }
        return event.deltaY * 3
    }

    private func horizontalScrollDelta(from event: NSEvent) -> CGFloat {
        if event.hasPreciseScrollingDeltas, event.scrollingDeltaX != 0 {
            return event.scrollingDeltaX
        }
        return event.deltaX * 3
    }
    
    // MARK: - Keyboard Events
    
    override var acceptsFirstResponder: Bool { true }
    
    override func keyDown(with event: NSEvent) {
        if model.browseMode.isHistoryMode {
            super.keyDown(with: event)
            return
        }
        
        switch event.keyCode {
        case 36: // Enter
            if model.hasUnsubmittedYouTubeSearch {
                model.loadYouTubeSearchResults()
            } else if event.modifierFlags.contains(.shift) {
                runVerbOnSelection(.playNext)
            } else if event.modifierFlags.contains(.option) {
                runVerbOnSelection(.addToQueue)
            } else {
                if let index = selectedIndices.first, index < model.displayItems.count {
                    handleDoubleClick(on: model.displayItems[index])
                }
            }
            
        case 125: // Down arrow
            if let maxIndex = selectedIndices.max(), maxIndex < model.displayItems.count - 1 {
                selectedIndices = [maxIndex + 1]
                ensureVisible(index: maxIndex + 1)
                loadArtworkForSelection()
                needsDisplay = true
            }
            
        case 126: // Up arrow
            if let minIndex = selectedIndices.min(), minIndex > 0 {
                selectedIndices = [minIndex - 1]
                ensureVisible(index: minIndex - 1)
                loadArtworkForSelection()
                needsDisplay = true
            }
            
        default:
            guard let chars = event.characters, !chars.isEmpty else { break }
            if model.browseMode == .search {
                if event.keyCode == 51 { // Delete
                    if !model.searchQuery.isEmpty { model.searchQuery.removeLast(); searchQueryDidChange() }
                } else if chars.rangeOfCharacter(from: .alphanumerics) != nil ||
                          chars.rangeOfCharacter(from: .whitespaces) != nil {
                    model.searchQuery += chars; searchQueryDidChange()
                }
            } else {
                if event.keyCode == 53 { // Escape — clear type-ahead
                    typeAheadQuery = ""; typeAheadTimer?.invalidate(); typeAheadTimer = nil; needsDisplay = true
                } else if event.keyCode == 51 { // Backspace
                    if !typeAheadQuery.isEmpty { typeAheadQuery.removeLast(); jumpToTypeAhead() }
                } else if chars.rangeOfCharacter(from: .alphanumerics) != nil ||
                          chars.rangeOfCharacter(from: .whitespaces) != nil {
                    typeAheadQuery += chars; jumpToTypeAhead()
                }
            }
        }
    }
    
    private func ensureVisible(index: Int) {
        let listHeight = listLayout().rows.height

        let itemTop = CGFloat(index) * itemHeight
        let itemBottom = itemTop + itemHeight

        if itemTop < scrollOffset {
            scrollOffset = itemTop
        } else if itemBottom > scrollOffset + listHeight {
            scrollOffset = itemBottom - listHeight
        }
    }

    private func jumpToTypeAhead() {
        let query = typeAheadQuery.lowercased()
        guard !query.isEmpty else { return }
        if let idx = model.displayItems.firstIndex(where: { LibraryBrowserModel.titleMatchesTypeAhead($0.title, query: query) }) {
            selectedIndices = [idx]; ensureVisible(index: idx); loadArtworkForSelection(); needsDisplay = true
        }
        typeAheadTimer?.invalidate()
        typeAheadTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.typeAheadQuery = ""
        }
    }

    // MARK: - YouTube (shares the Radio tab UI as its own source)

    /// Search as you type — except a YouTube channel search, a network call that waits for Enter.
    private func searchQueryDidChange() {
        if model.isYouTubeChannelSearch { needsDisplay = true } else { model.loadDataForCurrentMode() }
    }

    @objc private func contextMenuSubscribeYouTubeChannel(_ sender: NSMenuItem) {
        guard let channel = sender.representedObject as? YouTubeChannel else { return }
        model.youtubeSearch.subscribe(to: channel)
    }

    @objc private func libraryRowThumbnailDidLoad() {
        needsDisplay = true
    }

    /// A channel's uploads started or finished loading: spin the per-row spinner. The model rebuilds the rows.
    @objc private func youtubeUploadsDidChange() {
        if YouTubeChannelUploads.shared.hasFetchesInFlight { startLoadingAnimation() }
    }

    // MARK: - Browse Artwork

    /// Load artwork from browsed local content
    private func loadLocalBrowseArtwork() {
        guard case .local = model.currentSource else { return }
        guard WindowManager.shared.showBrowserArtworkBackground else { return }
        
        // If a track is playing, use its artwork
        if let currentTrack = WindowManager.shared.audioEngine.currentTrack {
            loadArtwork(for: currentTrack)
            return
        }
        
        // Capture current state for async task
        let items = model.displayItems

        // Otherwise, try to find artwork from the current browse context
        artworkLoadTask?.cancel()
        artworkLoadTask = Task { [weak self] in
            guard let self = self else { return }

            var image: NSImage?

            // Try to get artwork from the first track we can find
            for item in items {
                switch item.type {
                case .localTrack(let track):
                    image = await self.loadLocalArtwork(url: track.url)
                    break
                case .localAlbum(let album):
                    let albumTracks = MediaLibraryStore.shared.tracksForAlbum(album.id)
                    if let track = albumTracks.first {
                        image = await self.loadLocalArtwork(url: track.url)
                    }
                    break
                case .localArtist(let artist):
                    let artistTracks = MediaLibraryStore.shared.searchTracks(query: artist.name, limit: 1, offset: 0)
                    if let track = artistTracks.first {
                        image = await self.loadLocalArtwork(url: track.url)
                    }
                    break
                default:
                    continue
                }
                if image != nil { break }
            }
            
            guard !Task.isCancelled else { return }
            
            await MainActor.run {
                if image != nil {
                    self.currentArtwork = image
                    self.needsDisplay = true
                }
            }
        }
    }
    
    // MARK: - Playback

    private func handleDoubleClick(on item: LibraryBrowserItem) {
        switch item.type {
        case .track, .album, .plexPlaylist, .localTrack, .localAlbum, .localPlaylist, .localPlaylistTrack,
             .subsonicTrack, .subsonicAlbum, .subsonicPlaylist, .jellyfinTrack, .jellyfinAlbum, .jellyfinPlaylist,
             .embyTrack, .embyAlbum, .embyPlaylist, .movie, .episode, .localMovie, .localEpisode,
             .jellyfinMovie, .jellyfinEpisode, .embyMovie, .embyEpisode:
            if let playable = playable(for: item) { TrackVerb.play.run(resolver(for: playable)) }

        case .artist(let artist):
            if model.browseMode == .search { model.navigateToArtistFromSearch(id: artist.id, name: artist.title) } else { model.toggleExpand(item) }
            
        case .show:
            model.toggleExpand(item)
            
        case .season:
            model.toggleExpand(item)
            
        case .header:
            break
            
        case .localArtist(let artist):
            if model.browseMode == .search { model.navigateToArtistFromSearch(id: item.id, name: artist.name) } else { model.toggleExpand(item) }

        case .localFolder:
            model.toggleExpand(item)

        case .localShow:
            model.toggleExpand(item)

        case .localSeason:
            model.toggleExpand(item)

        case .subsonicArtist(let artist):
            if model.browseMode == .search { model.navigateToArtistFromSearch(id: artist.id, name: artist.name) } else { model.toggleExpand(item) }
            
        case .jellyfinArtist(let artist):
            if model.browseMode == .search { model.navigateToArtistFromSearch(id: artist.id, name: artist.name) } else { model.toggleExpand(item) }
            
        case .jellyfinShow:
            model.toggleExpand(item)
            
        case .jellyfinSeason:
            model.toggleExpand(item)
            
        case .embyArtist(let artist):
            if model.browseMode == .search { model.navigateToArtistFromSearch(id: artist.id, name: artist.name) } else { model.toggleExpand(item) }

        case .embyShow:
            model.toggleExpand(item)

        case .embySeason:
            model.toggleExpand(item)

        case .radioStation(let station):
            playRadioStation(station)

        case .radioFolder(let folder):
            if folder.hasChildren {
                model.toggleExpand(item)
            }

        case .youtubeChannel(let channel):
            // A search result not yet subscribed: double-click / Enter subscribes it.
            if YouTubeManager.shared.isSubscribed(channel) {
                model.toggleExpand(item)
            } else {
                model.youtubeSearch.subscribe(to: channel)
            }
        case .youtubeVideo(let video):
            youtubeVideoActions.activate(video, in: self)

        case .plexRadioStation(let radioType):
            playPlexRadioStation(radioType)
        case .subsonicRadioStation(let radioType):
            playSubsonicRadioStation(radioType)
        case .jellyfinRadioStation(let radioType):
            playJellyfinRadioStation(radioType)
        case .embyRadioStation(let radioType):
            playEmbyRadioStation(radioType)
        case .localRadioStation(let radioType):
            playLocalRadioStation(radioType)
        }
    }

    // MARK: - Radio Playback
    
    private func playRadioStation(_ station: RadioStation) {
        NSLog("playRadioStation: %@", station.name)
        RadioManager.shared.play(station: station)
    }
    
    /// Play a Plex Radio station (dynamic playlist from Plex library)
    private func playPlexRadioStation(_ radioType: PlexRadioType) {
        NSLog("playPlexRadioStation: %@", radioType.displayName)
        radioPlayTask?.cancel()
        model.isLoading = true; startLoadingAnimation(); needsDisplay = true
        radioPlayTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            var tracks: [Track] = []
            switch radioType {
            case .libraryRadio:
                tracks = await PlexManager.shared.createLibraryRadio()
            case .libraryRadioSonic:
                tracks = await PlexManager.shared.createLibraryRadioSonic()
            case .hitsRadio:
                tracks = await PlexManager.shared.createHitsRadio()
            case .hitsRadioSonic:
                tracks = await PlexManager.shared.createHitsRadioSonic()
            case .deepCutsRadio:
                tracks = await PlexManager.shared.createDeepCutsRadio()
            case .deepCutsRadioSonic:
                tracks = await PlexManager.shared.createDeepCutsRadioSonic()
            case .genreRadio(let genre):
                tracks = await PlexManager.shared.createGenreRadio(genre: genre)
            case .genreRadioSonic(let genre):
                tracks = await PlexManager.shared.createGenreRadioSonic(genre: genre)
            case .decadeRadio(let start, let end, _):
                tracks = await PlexManager.shared.createDecadeRadio(startYear: start, endYear: end)
            case .decadeRadioSonic(let start, let end, _):
                tracks = await PlexManager.shared.createDecadeRadioSonic(startYear: start, endYear: end)
            case .ratingRadio(let minRating, _):
                tracks = await PlexManager.shared.createRatingRadio(minRating: minRating)
            case .ratingRadioSonic(let minRating, _):
                tracks = await PlexManager.shared.createRatingRadioSonic(minRating: minRating)
            }
            guard !Task.isCancelled else { return }
            guard !tracks.isEmpty else {
                NSLog("%@: No tracks found", radioType.displayName)
                self.model.isLoading = false; self.stopLoadingAnimation(); self.needsDisplay = true
                return
            }
            let audioEngine = WindowManager.shared.audioEngine
            audioEngine.loadTracks(tracks)
            NSLog("%@ started with %d tracks", radioType.displayName, tracks.count)
            self.model.isLoading = false; self.stopLoadingAnimation(); self.needsDisplay = true
            self.radioPlayTask = nil
        }
    }

    private func playSubsonicRadioStation(_ radioType: SubsonicRadioType) {
        radioPlayTask?.cancel()
        model.isLoading = true; startLoadingAnimation(); needsDisplay = true
        radioPlayTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            var tracks: [Track] = []
            switch radioType {
            case .libraryRadio:
                tracks = await SubsonicManager.shared.createLibraryRadio()
            case .librarySimilar:
                tracks = await SubsonicManager.shared.createLibraryRadioSimilar()
            case .genreRadio(let genre):
                tracks = await SubsonicManager.shared.createGenreRadio(genre: genre)
            case .genreSimilar(let genre):
                tracks = await SubsonicManager.shared.createGenreRadioSimilar(genre: genre)
            case .decadeRadio(let start, let end, _):
                tracks = await SubsonicManager.shared.createDecadeRadio(start: start, end: end)
            case .decadeSimilar(let start, let end, _):
                tracks = await SubsonicManager.shared.createDecadeRadioSimilar(start: start, end: end)
            case .starredRadio:
                tracks = await SubsonicManager.shared.createRatingRadio()
            case .starredSimilar:
                tracks = await SubsonicManager.shared.createRatingRadioSimilar()
            }
            guard !Task.isCancelled else { return }
            guard !tracks.isEmpty else {
                self.model.isLoading = false; self.stopLoadingAnimation(); self.needsDisplay = true
                return
            }
            let audioEngine = WindowManager.shared.audioEngine
            audioEngine.loadTracks(tracks)
            self.model.isLoading = false; self.stopLoadingAnimation(); self.needsDisplay = true
            self.radioPlayTask = nil
        }
    }

    private func playJellyfinRadioStation(_ radioType: JellyfinRadioType) {
        radioPlayTask?.cancel()
        model.isLoading = true; startLoadingAnimation(); needsDisplay = true
        radioPlayTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            var tracks: [Track] = []
            switch radioType {
            case .libraryRadio:
                tracks = await JellyfinManager.shared.createLibraryRadio()
            case .libraryInstantMix:
                tracks = await JellyfinManager.shared.createLibraryRadioInstantMix()
            case .genreRadio(let genre):
                tracks = await JellyfinManager.shared.createGenreRadio(genre: genre)
            case .genreInstantMix(let genre):
                tracks = await JellyfinManager.shared.createGenreRadioInstantMix(genre: genre)
            case .decadeRadio(let start, let end, _):
                tracks = await JellyfinManager.shared.createDecadeRadio(start: start, end: end)
            case .decadeInstantMix(let start, let end, _):
                tracks = await JellyfinManager.shared.createDecadeRadioInstantMix(start: start, end: end)
            case .favoritesRadio:
                tracks = await JellyfinManager.shared.createFavoritesRadio()
            case .favoritesInstantMix:
                tracks = await JellyfinManager.shared.createFavoritesRadioInstantMix()
            }
            guard !Task.isCancelled else { return }
            guard !tracks.isEmpty else {
                self.model.isLoading = false; self.stopLoadingAnimation(); self.needsDisplay = true
                return
            }
            let audioEngine = WindowManager.shared.audioEngine
            audioEngine.loadTracks(tracks)
            self.model.isLoading = false; self.stopLoadingAnimation(); self.needsDisplay = true
            self.radioPlayTask = nil
        }
    }

    private func playEmbyRadioStation(_ radioType: EmbyRadioType) {
        radioPlayTask?.cancel()
        model.isLoading = true; startLoadingAnimation(); needsDisplay = true
        radioPlayTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            var tracks: [Track] = []
            switch radioType {
            case .libraryRadio:
                tracks = await EmbyManager.shared.createLibraryRadio()
            case .libraryInstantMix:
                tracks = await EmbyManager.shared.createLibraryRadioInstantMix()
            case .genreRadio(let genre):
                tracks = await EmbyManager.shared.createGenreRadio(genre: genre)
            case .genreInstantMix(let genre):
                tracks = await EmbyManager.shared.createGenreRadioInstantMix(genre: genre)
            case .decadeRadio(let start, let end, _):
                tracks = await EmbyManager.shared.createDecadeRadio(start: start, end: end)
            case .decadeInstantMix(let start, let end, _):
                tracks = await EmbyManager.shared.createDecadeRadioInstantMix(start: start, end: end)
            case .favoritesRadio:
                tracks = await EmbyManager.shared.createFavoritesRadio()
            case .favoritesInstantMix:
                tracks = await EmbyManager.shared.createFavoritesRadioInstantMix()
            }
            guard !Task.isCancelled else { return }
            guard !tracks.isEmpty else {
                self.model.isLoading = false; self.stopLoadingAnimation(); self.needsDisplay = true
                return
            }
            let audioEngine = WindowManager.shared.audioEngine
            audioEngine.loadTracks(tracks)
            self.model.isLoading = false; self.stopLoadingAnimation(); self.needsDisplay = true
            self.radioPlayTask = nil
        }
    }

    private func playLocalRadioStation(_ radioType: LocalRadioType) {
        let tracks: [Track]
        switch radioType {
        case .libraryRadio:
            tracks = MediaLibrary.shared.createLocalLibraryRadio()
        case .genreRadio(let genre):
            tracks = MediaLibrary.shared.createLocalGenreRadio(genre: genre)
        case .decadeRadio(let start, let end, _):
            tracks = MediaLibrary.shared.createLocalDecadeRadio(start: start, end: end)
        }
        guard !tracks.isEmpty else { return }
        let audioEngine = WindowManager.shared.audioEngine
        audioEngine.loadTracks(tracks)
    }
    }

// MARK: - NSWindowDelegate

extension PlexBrowserView: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let closingWindow = notification.object as? NSWindow {
            if closingWindow === activeTagsPanel {
                activeTagsPanel = nil
            } else if closingWindow === activeEditTagsPanel {
                activeEditTagsPanel = nil
            } else if closingWindow === activeEditAlbumTagsPanel {
                activeEditAlbumTagsPanel = nil
            } else if closingWindow === activeEditVideoTagsPanel {
                activeEditVideoTagsPanel = nil
            }
        }
    }
}

