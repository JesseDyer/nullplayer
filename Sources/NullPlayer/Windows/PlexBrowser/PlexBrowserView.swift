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
    


    /// Column being resized (id) and resize state
    private var resizingColumnId: LibraryBrowserColumn.ID?
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
    
    private func widthForColumn(
        _ column: LibraryBrowserColumn,
        availableWidth: CGFloat,
        columns: [LibraryBrowserColumn],
        group: LibraryColumnVisibilityGroup?
    ) -> CGFloat {
        if column.id == .title {
            // Title column gets remaining space
            let fixedWidth = columns.filter { $0.id != .title }.reduce(0) { 
                $0 + (model.storedColumnWidth(for: $1, group: group) ?? $1.minWidth)
            }
            return max(column.minWidth, availableWidth - fixedWidth - 8)
        }
        return model.storedColumnWidth(for: column, group: group) ?? column.minWidth
    }
    
    /// Calculate total width needed for all columns
    private func totalColumnsWidth(columns: [LibraryBrowserColumn], group: LibraryColumnVisibilityGroup?) -> CGFloat {
        var total: CGFloat = 8  // Initial padding
        for column in columns {
            if column.id == .title {
                total += column.minWidth  // Title uses minWidth for total calculation
            } else {
                total += model.storedColumnWidth(for: column, group: group) ?? column.minWidth
            }
        }
        return total
    }

    private func clampHorizontalScrollOffset() {
        guard let header = listLayout().header else { horizontalScrollOffset = 0; return }
        let maxOffset = max(0, totalColumnsWidth(columns: header.columns, group: header.group) - header.rect.width)
        horizontalScrollOffset = max(0, min(horizontalScrollOffset, maxOffset))
    }
    
    


    

    
    


    /// What the rows do and the menus that offer it.
    private lazy var actions: LibraryBrowserActions = LibraryBrowserActions(model: model, host: .init(
        view: { [unowned self] in self },
        presentLinkSheet: { [unowned self] in presentLinkSheet() },
        ratingStarColor: { NSColor(srgbRed: 0.98, green: 0.78, blue: 0.20, alpha: 1.0) },
        busyChanged: { [unowned self] in
            updateLoadingAnimation()
            needsDisplay = true
        }
    ))

    private let historyAgent = PlayHistoryAgent()
    private var historyHostingView: NSHostingView<StatsContentView>?

    
    
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
            selectedIndex: { [unowned self] in model.selectedIndices.min() },
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
            play: { [unowned self] in actions.activate($0) },
            menu: { [unowned self] row, event in
                // As a right-click on the row in the list: select it, then its menu.
                if let index = model.displayItems.firstIndex(where: { $0.id == row.id }) { model.selectedIndices = [index] }
                showContextMenu(for: row, at: event)
            },
            albumInfo: { [unowned self] in actions.playable(for: $0).flatMap(LibraryAlbumInfo.init) },
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
            leftWidth = leadingInset + prefixWidth + textWidth(model.withItemCount(name)) + 28 + textWidth("+ADD")
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

    /// Per-tab widths across the tab area (which excludes the Sort indicator). Content-aware:
    /// each tab is sized to its own label plus padding, then leftover space is shared equally
    /// so every tab gets breathing room and short labels (e.g. "TV", "Data") don't hog width.
    /// Shared by `drawTabBar` and `hitTestTabBar` so they stay in sync.
    private func tabBarWidths(tabsWidth: CGFloat, textScale: CGFloat,
                              horizontalScale: CGFloat) -> [CGFloat] {
        let style = winampModernStyle
        let boxPadding = 18 * horizontalScale
        let natural = model.tabLabels.map { ClassicLibraryTab.textWidth($0, scale: textScale, style: style) + boxPadding }
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
        

        // A `.wal` colour-theme switch recolours this browser (Phase 16). The embedded case is told
        // directly through `applyWinampModernStyle`; a fallback window has no such handle.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hostedSurfaceStyleDidChange),
            name: .hostedSurfaceStyleDidChange,
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
            updateLoadingAnimation()
            needsDisplay = true
        case .rowsReplaced:
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
            ensureVisible(index: index)
            needsDisplay = true
        case .source:
            artLens.resetNavigation()
            scrollOffset = 0
            startServerNameScroll()
        case .columns:
            clampHorizontalScrollOffset()
            needsDisplay = true
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
        actions.cancelAll()

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
                              cachedArtwork: { cacheKey.flatMap { LibraryArtwork.cache.object(forKey: NSString(string: $0)) } },
                              art: rowThumbnailSource(for: item),
                              artAspect: item.type.isPoster ? LibraryArtItem.posterAspect : 1)
    }

    /// Resolve a display item to its artwork cache key and async loader (reusing the per-source
    /// loaders that back `loadArtworkForSelection`).
    private func itemArtwork(for item: LibraryBrowserItem) -> LibraryArtwork.ItemArtwork {
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
            return LibraryArtwork.jellyfinItem(album.artworkItemId)
        case .embyAlbum(let album):
            return LibraryArtwork.embyItem(album.artworkItemId)
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
            return LibraryArtwork.jellyfinItem(movie.artworkItemId)
        case .jellyfinShow(let show):
            return LibraryArtwork.jellyfinItem(show.artworkItemId)
        case .jellyfinSeason(let season):
            return LibraryArtwork.jellyfinItem(season.artworkItemId)
        case .jellyfinEpisode(let episode):
            return LibraryArtwork.jellyfinItem(episode.artworkItemId)
        case .embyMovie(let movie):
            return LibraryArtwork.embyItem(movie.artworkItemId)
        case .embyShow(let show):
            return LibraryArtwork.embyItem(show.artworkItemId)
        case .embySeason(let season):
            return LibraryArtwork.embyItem(season.artworkItemId)
        case .embyEpisode(let episode):
            return LibraryArtwork.embyItem(episode.artworkItemId)
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
            return LibraryArtwork.jellyfinItem(artist.artworkItemId)
        case .embyArtist(let artist):
            return LibraryArtwork.embyItem(artist.artworkItemId)
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
            return LibraryArtwork.jellyfinItem(song.artworkItemId)
        case .embyTrack(let song):
            return LibraryArtwork.embyItem(song.artworkItemId)
        default:
            return (nil, { nil })
        }
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
            let sourceText = model.withItemCount(name)
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
            let libraryText = model.withItemCount(library)
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
        let labels = model.tabLabels
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
            let isSelected = model.selectedIndices.contains(index)
            
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
            let isCenteredRadioColumn = (model.browseMode == .radio && column.id == .genre) ||
                (model.hasInternetRadioColumns && column.id == .rating)
            
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
        
        let hasArtColumn = columns.contains { $0.id == .thumbnail }
        let cells = LibraryColumnVisibility.cellFrames(
            widths: columns.map { widthForColumn($0, availableWidth: totalWidth, columns: columns, group: group) },
            titleIndex: columns.firstIndex { $0.id == .title }, indent: indent,
            spansLeadingCells: model.columnGroup(for: item) != group)
        for (column, cell) in zip(columns, cells) {
            let x = rect.minX + cell.start - horizontalScrollOffset, width = cell.width
            if column.id == .thumbnail {
                // Inside the counter-flip (y-up), centred on the row so the flip doesn't move it.
                if let thumbnail = rowThumbnailSource(for: item) {
                    rowThumbnails.draw(thumbnail, in: context, at: x + 4, rowRect: rect, side: min(width - 8, rect.height - 2))
                }
                continue
            }
            let value = column.id == .title ? item.shownTitle : item.columnValue(for: column)
            let isCenteredRadioColumn = (model.browseMode == .radio && column.id == .genre) ||
                (model.isInternetRadioItem(item) && column.id == .rating)
            
            // Title column uses normal color/font, others use dim color/smaller font
            let color = column.id == .title ? textColor : dimColor
            let useFont = column.id == .title ? font : smallFont
            
            let attrs: [NSAttributedString.Key: Any] = [
                .font: useFont,
                .foregroundColor: color
            ]

            // Per-row download spinner on the title column of a downloading YouTube video.
            var titleSpinnerInset: CGFloat = 0
            if column.id == .title, case .youtubeVideo(let video) = item.type,
               actions.youtubeVideos.isFetching(video.videoId) {
                let spinnerRadius = min(rect.height * 0.3, 6)
                let cx = x + 4 + spinnerRadius
                drawRowSpinner(in: context, center: CGPoint(x: cx, y: rect.midY), radius: spinnerRadius, colors: colors)
                titleSpinnerInset = spinnerRadius * 2 + 4
            }
            // Round art ahead of the title, unless the row has an Art column to hold it.
            if column.id == .title, !hasArtColumn, let thumbnail = rowThumbnailSource(for: item) {
                titleSpinnerInset += rowThumbnails.draw(thumbnail, in: context, at: x + 4 + titleSpinnerInset,
                                                        rowRect: rect, side: rect.height - 2)
            }

            let textSize = value.size(withAttributes: attrs)
            let textY = rect.minY + (rect.height - textSize.height) / 2

            let textX = isCenteredRadioColumn ? (x + (width - textSize.width) / 2) : (x + 4 + titleSpinnerInset)
            let maxTextWidth = width - 8 - titleSpinnerInset  // Padding on both sides
            
            // Draw with truncation if needed
            let drawRect = NSRect(x: textX, y: textY, width: maxTextWidth, height: textSize.height)
            if column.id == .rating && !isSelected && (value.contains("★") || value.contains("☆")) {
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
            if self.actions.rowsAreBusy {
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

    /// Run the spinner timer while the rows or the library scan have something in flight.
    private func updateLoadingAnimation() {
        if actions.rowsAreBusy || isLibraryScanning { startLoadingAnimation() } else { stopLoadingAnimation() }
    }

    private func stopLoadingAnimation() {
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
        updateLoadingAnimation()
        if !scanning { needsDisplay = true }
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
                if let itemId = track.artworkThumb { image = await LibraryArtwork.jellyfin(itemId: itemId) }
            } else if track.embyId != nil {
                // Emby track - load from server
                if let itemId = track.artworkThumb { image = await LibraryArtwork.emby(itemId: itemId) }
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
                image = await LibraryArtwork.radio(for: track)
            } else if let thumb = track.artworkThumb {
                // Generic remote artwork URL fallback
                image = await LibraryArtwork.remote(urlString: thumb, cacheNamespace: "generic")
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
        if let cached = LibraryArtwork.cache.object(forKey: cacheKey) {
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
                        LibraryArtwork.cache.setObject(image, forKey: cacheKey)
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
        if let cached = LibraryArtwork.cache.object(forKey: cacheKey) {
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
            LibraryArtwork.cache.setObject(image, forKey: cacheKey)
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
        if let cached = LibraryArtwork.cache.object(forKey: cacheKey) {
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
            LibraryArtwork.cache.setObject(image, forKey: cacheKey)
            
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
        if let cached = LibraryArtwork.cache.object(forKey: cacheKey) {
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
                        LibraryArtwork.cache.setObject(image, forKey: cacheKey)
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
                        LibraryArtwork.cache.setObject(image, forKey: cacheKey)
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
                        LibraryArtwork.cache.setObject(image, forKey: cacheKey)
                        return image
                    }
                }
            }
        } catch {
            NSLog("PlexBrowserView: Failed to load local artwork: %@", error.localizedDescription.redactingSensitiveURLQueryItems)
        }
        
        return nil
    }

    /// Load artwork based on the currently selected item in the browser
    /// Called when selection changes to show artwork for browsed items (not just playing items)
    private func loadArtworkForSelection() {
        guard WindowManager.shared.showBrowserArtworkBackground else { return }
        guard let index = model.selectedIndices.first, index < model.displayItems.count else { return }
        
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
                image = await LibraryArtwork.jellyfinItem(playlist.artworkItemId).load()

            case .embyPlaylist(let playlist):
                image = await LibraryArtwork.embyItem(playlist.artworkItemId).load()

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
                image = await LibraryArtwork.radio(for: radioTrack, station: station)
            case .youtubeVideo(let video):
                // A download carries its own embedded art; otherwise the 16:9 thumbnail.
                if let fileURL = YouTubeManager.shared.coverArtFile(for: video.videoId) {
                    image = await self.loadLocalArtwork(url: fileURL)
                }
                if image == nil, let thumb = video.thumbnailURL {
                    image = await LibraryArtwork.remote(urlString: thumb.absoluteString, cacheNamespace: "youtube")
                }
                image = image?.squareCenterCropped()
            case .youtubeChannel(let channel):
                if let avatar = channel.avatarURL(side: 512) {
                    image = await LibraryArtwork.remote(urlString: avatar.absoluteString, cacheNamespace: "youtube")?.squareCenterCropped()
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
        if let cached = LibraryArtwork.cache.object(forKey: cacheNSKey) {
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
            
            LibraryArtwork.cache.setObject(image, forKey: cacheNSKey)
            return image
        } catch {
            return nil
        }
    }
    
    /// Load artwork from Subsonic using a cover art ID directly
    private func loadSubsonicArtworkByCoverId(coverArt: String, cacheKey: String) async -> NSImage? {
        // Check cache first
        let cacheNSKey = NSString(string: cacheKey)
        if let cached = LibraryArtwork.cache.object(forKey: cacheNSKey) {
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
            
            LibraryArtwork.cache.setObject(image, forKey: cacheNSKey)
            return image
        } catch {
            return nil
        }
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
        if let cached = LibraryArtwork.cache.object(forKey: cacheKey) {
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
                        LibraryArtwork.cache.setObject(image, forKey: cacheKey)
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
            if column.id == .rating {
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
    private func hitTestColumnResize(at skinPoint: NSPoint) -> LibraryBrowserColumn.ID? {
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
                if model.hasYouTubeColumns, column.id == .title {
                    return columns[index + 1].id
                }
                if column.id != .title {
                    return column.id
                }
            }
            x += width
        }
        
        return nil
    }
    
    /// Check if point hits a column header (returns column id for sorting)
    private func hitTestColumnHeader(at skinPoint: NSPoint) -> LibraryBrowserColumn.ID? {
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
            if !model.selectedIndices.contains(clickedIndex) {
                model.selectedIndices = [clickedIndex]
                needsDisplay = true
            }
            
            let item = model.displayItems[clickedIndex]
            
            // Show context menu - uses search URLs as fallback for external links
            // Direct IMDB/TMDB links will be used if IDs are already available
            showContextMenu(for: item, at: event)
            return
        }
        
        // Local library empty-space right-click: show Manage Folders
        if !model.browseMode.isHistoryMode, let menu = actions.emptySpaceMenu() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        // Default right-click behavior
        super.rightMouseDown(with: event)
    }

    private func showColumnConfigMenu(at event: NSEvent) {
        guard let menu = actions.columnMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let skinPoint = convertToSkinCoordinates(point)
        
        // Check for column resize
        if let header = columnHeader(at: skinPoint), let columnId = hitTestColumnResize(at: skinPoint) {
            resizingColumnId = columnId
            resizingColumnGroup = header.group
            resizingColumnFromLeadingEdge = model.hasYouTubeColumns && columnId == .duration
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
            popDown(actions.sortMenu(), from: event)
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

        if addButtonRect.contains(skinPoint), let menu = actions.addMenu() {
            popDown(menu, from: event)
        } else if libraryButtonRect.contains(skinPoint), let menu = actions.libraryMenu() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else if sourceButtonRect.contains(skinPoint) {
            popDown(actions.sourceMenu(), from: event)
        }
    }

    /// A server-bar menu, dropped down from the click.
    private func popDown(_ menu: NSMenu, from event: NSEvent) {
        menu.popUp(positioning: nil, at: NSPoint(x: event.locationInWindow.x, y: event.locationInWindow.y - 5),
                   in: window?.contentView)
    }

    private func handleRefreshClick() {
        if model.browseMode.isHistoryMode {
            historyAgent.scheduleRefresh()
            return
        }
        model.refreshCurrentSource()
    }

    // MARK: - List Clicks

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
                model.selectedIndices = [index]
                needsDisplay = true
                return
            }
        }
    }
    
    private func handleListClick(at index: Int, event: NSEvent, skinPoint: NSPoint) {
        let item = model.displayItems[index]

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
                model.selectedIndices = [updatedIndex]
            } else {
                model.selectedIndices = [index]
            }
            needsDisplay = true
            return
        }

        if let clickedStar = hitTestInternetRadioRating(at: skinPoint, itemIndex: index),
           case .radioStation(let station) = item.type {
            let currentRating = RadioManager.shared.rating(for: station)
            let targetRating = currentRating == clickedStar ? 0 : clickedStar
            RadioManager.shared.setRating(targetRating, for: station)
            model.selectedIndices = [index]
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
            if let lastSelected = model.selectedIndices.max() {
                let start = min(lastSelected, index)
                let end = max(lastSelected, index)
                for i in start...end {
                    model.selectedIndices.insert(i)
                }
            } else {
                model.selectedIndices.insert(index)
            }
            // Load artwork for selection (shift-click multi-select)
            loadArtworkForSelection()
        } else if event.modifierFlags.contains(.command) {
            if model.selectedIndices.contains(index) {
                model.selectedIndices.remove(index)
            } else {
                model.selectedIndices.insert(index)
            }
            // Load artwork for selection (cmd-click multi-select)
            loadArtworkForSelection()
        } else {
            model.selectedIndices = [index]
            
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
                    RadioManager.shared.play(station: station)
                }
            default:
                // Everything else — tracks included, which play on double-click — loads artwork
                loadArtworkForSelection()
            }
        }
        
        // Double-click to play a track, album or show, or expand an artist
        if event.clickCount == 2 {
            actions.activate(item)
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
            model.setColumnWidth(newWidth, for: columnId, group: group)
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
        return actions.addDroppedItems(items)
    }
    
    // MARK: - Right-Click Context Menu (for list items)

    private func showContextMenu(for item: LibraryBrowserItem, at event: NSEvent) {
        guard let menu = actions.contextMenu(for: item) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Shift+Enter / Option+Enter: the menu's Play Next / Add to Queue on the selected row.
    private func runVerbOnSelection(_ verb: TrackVerb) {
        guard let index = model.selectedIndices.first, index < model.displayItems.count else { return }
        actions.run(verb, on: model.displayItems[index])
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
                if let index = model.selectedIndices.first, index < model.displayItems.count {
                    actions.activate(model.displayItems[index])
                }
            }
            
        case 125: // Down arrow
            if let maxIndex = model.selectedIndices.max(), maxIndex < model.displayItems.count - 1 {
                model.selectedIndices = [maxIndex + 1]
                ensureVisible(index: maxIndex + 1)
                loadArtworkForSelection()
                needsDisplay = true
            }
            
        case 126: // Up arrow
            if let minIndex = model.selectedIndices.min(), minIndex > 0 {
                model.selectedIndices = [minIndex - 1]
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
            model.selectedIndices = [idx]; ensureVisible(index: idx); loadArtworkForSelection(); needsDisplay = true
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

    @objc private func libraryRowThumbnailDidLoad() {
        needsDisplay = true
    }

    /// A channel's uploads started or finished loading: spin the per-row spinner. The model rebuilds the rows.

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
}
