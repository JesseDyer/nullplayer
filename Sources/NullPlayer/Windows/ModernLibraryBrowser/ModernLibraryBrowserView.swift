import AppKit
import AVFoundation
import SwiftUI
import NullPlayerCore

// =============================================================================
// MODERN LIBRARY BROWSER VIEW - Library browser with modern skin chrome
// =============================================================================
// Comprehensive port of PlexBrowserView.swift to use the modern skin engine.
//
// Key differences from classic PlexBrowserView:
// 1. ZERO dependencies on classic skin system (Skin/, SkinRenderer, SkinLoader, SkinElements)
// 2. Uses ModernSkinRenderer for window chrome (title bar, borders, control buttons)
// 3. Uses ModernSkinEngine for skin loading and change notifications
// 4. Uses NSFont for text (not skin bitmap font)
// 5. Uses bottom-left origin coordinates (macOS native - NO coordinate flipping)
// 6. Uses modern skin palette colors (primaryColor, accentColor, textColor, etc.)
// 7. Tabs and selections use modern boxed toggle style
// 8. Shares its value types (source, tab, row) with the classic view: Windows/LibraryBrowser/
// =============================================================================

// MARK: - Button Type

enum LibraryBrowserButtonType {
    case close
}

// MARK: - Modern Library Browser View

class ModernLibraryBrowserView: NSView {
    
    // MARK: - Properties
    
    weak var controller: ModernLibraryBrowserWindowController?

    private var renderer: ModernSkinRenderer!

    /// Compact Mode: when true, a stripped-down player bar is embedded across the top
    /// (just below the title bar) and all content below shifts down to make room.
    /// The window itself is never resized -- only the list/content region shrinks.
    var compactMode: Bool = false {
        didSet {
            guard compactMode != oldValue else { return }
            refreshBackdrop()
            needsLayout = true
            needsDisplay = true
        }
    }
    private var compactPlayerBar: CompactPlayerBarView?
    private var backdropView: CompactBackdropView?

    var backdropPresenter: CavaPresenter? {
        backdropView?.presenter
    }

    /// Height of the embedded compact player bar (0 when not in compact mode).
    private var compactPlayerBarHeight: CGFloat {
        compactMode ? CompactPlayerBarView.preferredHeight(for: ModernSkinElements.sizeMultiplier) : 0
    }

    /// Y coordinate of the bottom of the top chrome (title bar + optional compact player bar).
    /// All content below the title bar measures down from here, so inserting the player bar
    /// shifts the server bar / tabs / search / list down without resizing the window.
    private var topChromeBottomY: CGFloat {
        bounds.height - Layout.titleBarHeight - compactPlayerBarHeight
    }

    /// Y coordinate of the bottom of the scrollable content region. Content measures up from
    /// here, so reserving the compact footer band shifts the list / alphabet / server bar up
    /// without any other layout math changing (mirrors `topChromeBottomY` for the bottom).
    private var contentRegionBottomY: CGFloat {
        Layout.statusBarHeight + compactFooterHeight
    }
    
    /// The browser's source, tab, rows and caches; this view draws them.
    let model = LibraryBrowserModel(keyPrefix: "")

    private var typeAheadQuery: String = ""
    private var typeAheadTimer: Timer?

    private var selectedIndices: Set<Int> = []
    private var scrollOffset: CGFloat = 0
    private var horizontalScrollOffset: CGFloat = 0
    private let historyAgent = PlayHistoryAgent()
    private var historyHostingView: NSHostingView<StatsContentView>?
    
    private var itemHeight: CGFloat { 18 * ModernSkinElements.sizeMultiplier }
    private var columnHeaderHeight: CGFloat { 18 * ModernSkinElements.sizeMultiplier }
    
    // Column state
    private var columnWidths: [String: CGFloat] = [:] { didSet { saveColumnWidths() } }
    private var resizingColumnId: String?
    private var resizingColumnGroup: LibraryColumnVisibilityGroup?
    private var resizeStartX: CGFloat = 0
    private var resizeStartWidth: CGFloat = 0

    /// Content shown below the compact player bar: the library browser or the play queue.
    /// Only consulted when `compactMode == true`; the full library window is unaffected.
    enum CompactContentMode: Int { case library = 0, queue = 1 }

    private var compactContentMode: CompactContentMode {
        get { CompactContentMode(rawValue: UserDefaults.standard.integer(forKey: "compactContentMode")) ?? .library }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "compactContentMode")
            updateCompactPlaylistFrame()   // show/hide + size the embedded queue
            // Hand keyboard focus to whichever view is now visible.
            window?.makeFirstResponder(newValue == .queue ? (compactPlaylistView ?? self) : self)
            needsLayout = true
            needsDisplay = true
        }
    }

    /// Height of the Library|Playlist toggle footer at the bottom of the compact window
    /// (0 outside compact mode).
    private var compactFooterHeight: CGFloat {
        compactMode ? 24 * ModernSkinElements.sizeMultiplier : 0
    }

    /// Embedded compact-sized play queue, shown in place of the library chrome in queue mode.
    private var compactPlaylistView: ModernPlaylistView?

    private var activeRadioStationSheet: AddRadioStationSheet?
    private var activeYouTubeChannelSheet: AddYouTubeChannelSheet?

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


    // Animation
    private var loadingAnimationTimer: Timer?
    private var loadingAnimationFrame: Int = 0
    /// Local library scan animation (server bar spinner)
    private var isLibraryScanning = false
    private var serverNameScrollOffset: CGFloat = 0
    private var libraryNameScrollOffset: CGFloat = 0
    private var serverScrollTimer: Timer?
    private var lastServerName: String = ""
    private var lastLibraryName: String = ""

    /// Cached server bar font and attribute dictionaries — invalidated when skin changes
    private var cachedServerBarFont: NSFont?
    private var cachedServerBarFontSkinName: String?
    private var cachedServerBarFontScale: CGFloat?
    private var cachedServerBarIsMetal: Bool?
    private var cachedServerBarCompact: Bool?
    private var cachedServerBarChromeScale: CGFloat?
    private var cachedPrefixAttrs: [NSAttributedString.Key: Any]?
    private var cachedDataAttrs: [NSAttributedString.Key: Any]?
    private var cachedActiveAttrs: [NSAttributedString.Key: Any]?
    /// Server and library text and field widths, written by drawServerBar each draw for the scroll
    /// tick; zero while the bar shows no server.
    private var serverNameTextWidth: CGFloat = 0
    private var libraryNameTextWidth: CGFloat = 0
    private var serverNameMaxWidth: CGFloat = 0
    private var libraryNameMaxWidth: CGFloat = 0

    /// Highlight state for drag-mode visual feedback
    private var isHighlighted = false
    
    /// List, Flow or Tiles, and the Flow / Tiles view standing in for the list (see LibraryArtLens).
    private lazy var artLens = LibraryArtLens<LibraryBrowserItem>(container: self, host: .init(
        rows: { [unowned self] in model.displayItems },
        isSearch: { [unowned self] in model.browseMode == .search },
        selectedIndex: { [unowned self] in selectedIndices.min() },
        isBlocked: { [unowned self] in
            model.isLoading || model.errorMessage != nil || (model.currentSource.isPlex && !PlexManager.shared.isLinked)
        },
        style: { [unowned self] in
            let skin = currentSkin()
            return LibraryArtStyle(titleColor: skin.textColor, subtitleColor: skin.textDimColor,
                                   placeholderFill: skin.surfaceColor, placeholderTextColor: skin.textDimColor)
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
    /// The List / Flow / Tiles buttons in the server bar, as last drawn.
    private var viewModeButtonRects: [(mode: LibraryViewMode, rect: NSRect)] = []

    private var refreshButtonRect: NSRect = .zero
    private var sourceButtonRect: NSRect = .zero
    private var libraryButtonRect: NSRect = .zero
    private var addButtonRect: NSRect = .zero
    private var tabButtonRects: [NSRect] = []
    private var sortButtonRect: NSRect = .zero
    
    // Artwork
    private var currentArtwork: NSImage?
    /// Artwork for the playing track, kept separate from selection-driven browser artwork.
    private var currentTrackArtwork: NSImage?
    private var artworkTrackId: UUID?
    private var currentTrackArtworkLoadTask: Task<Void, Never>?
    private var artworkLoadTask: Task<Void, Never>?
    private var artworkDisplayGeneration = 0
    private var radioPlayTask: Task<Void, Never>?
    private var isPreparingForUITeardown = false
    private static let artworkCache = NSCache<NSString, NSImage>()
    private let rowThumbnails = LibraryRowThumbnailTracker()
    
    /// Which edges are adjacent to another docked window (for seamless border rendering)
    private var adjacentEdges: AdjacentEdges = [] { didSet { updateCornerMask() } }
    private var sharpCorners: CACornerMask = [] { didSet { updateCornerMask() } }
    private var edgeOcclusionSegments: EdgeOcclusionSegments = .empty
    
    // Button/drag state
    private var pressedButton: LibraryBrowserButtonType?
    private var activeTagsPanel: TagsPanel?
    private var activeEditTagsPanel: EditTagsPanel?
    private var activeEditAlbumTagsPanel: EditAlbumTagsPanel?
    private var activeEditVideoTagsPanel: EditVideoTagsPanel?
    private struct SeasonRef { let season: LocalSeason; let showTitle: String }
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
    private var isDraggingWindow = false
    /// True when hide-title-bars mode primed drag hold timing on mouseDown.
    private var didPrimeWindowDragHold = false
    private var windowDragStartPoint: NSPoint = .zero
    private let alphabetLetters = ["#"] + (65...90).map { String(UnicodeScalar($0)) }
    
    // MARK: - Layout Constants (independent of classic skin)
    
    private struct Layout {
        static var titleBarHeight: CGFloat {
            WindowManager.shared.hideTitleBars ? Layout.borderWidth : ModernSkinElements.libraryTitleBarHeight
        }
        static var tabBarHeight: CGFloat { 24 * ModernSkinElements.sizeMultiplier }
        static var serverBarHeight: CGFloat { 24 * ModernSkinElements.sizeMultiplier }
        static var searchBarHeight: CGFloat { 26 * ModernSkinElements.sizeMultiplier }
        static var statusBarHeight: CGFloat { 6 * ModernSkinElements.sizeMultiplier }
        static var offlineBannerHeight: CGFloat { 18 * ModernSkinElements.sizeMultiplier }
        static let scrollbarWidth: CGFloat = 0
        static var alphabetWidth: CGFloat { 16 * ModernSkinElements.sizeMultiplier }
        static var borderWidth: CGFloat { ModernSkinElements.libraryBorderWidth }
        static var padding: CGFloat { 3 * ModernSkinElements.sizeMultiplier }
    }
    
    // MARK: - Initialization
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    
    private func commonInit() {
        wantsLayer = true
        layer?.isOpaque = false
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        
        // Load skin
        let skin = ModernSkinEngine.shared.currentSkin ?? ModernSkinLoader.shared.loadDefault()
        renderer = ModernSkinRenderer(skin: skin)
        
        loadColumnWidths()

        // Register notifications
        NotificationCenter.default.addObserver(self, selector: #selector(modernSkinDidChange),
                                               name: ModernSkinEngine.skinDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(doubleSizeChanged),
                                               name: .doubleSizeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowLayoutDidChange),
                                               name: .windowLayoutDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(youtubeUploadsDidChange),
                                               name: YouTubeChannelUploads.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(libraryRowThumbnailDidLoad),
                                               name: LibraryRowThumbnails.didLoadNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(trackDidChange),
                                               name: .audioTrackDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(playHistoryDidChange),
                                               name: MediaLibraryStore.playHistoryDidChangeNotification, object: nil)

        // Window visibility notifications
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidMiniaturize),
                                               name: NSWindow.didMiniaturizeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidDeminiaturize),
                                               name: NSWindow.didDeminiaturizeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidChangeOcclusionState),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(libraryScanProgressChanged),
                                               name: MediaLibrary.scanProgressNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(connectedWindowHighlightDidChange(_:)),
                                               name: .connectedWindowHighlightDidChange, object: nil)

        // Register for drag and drop
        registerForDraggedTypes([.fileURL])
        
        // Initial data load
        model.onChange = { [weak self] in self?.modelDidChange($0) }
        model.reloadData()
        
        // Start server name scroll animation
        startServerNameScroll()
        
        // Load artwork for current track
        if showsLegacyArtwork {
            loadArtwork(for: WindowManager.shared.audioEngine.currentTrack)
        }
        
        // Set accessibility
        setAccessibilityIdentifier("modernLibraryBrowserView")
        setAccessibilityRole(.group)
        setAccessibilityLabel("Library Browser")
        updateCornerMask()
        updateHistoryHostingVisibility()
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
            // The offline banner (local source, a folder offline) takes list height from Flow / Tiles.
            needsLayout = true
        case .reveal(let index):
            selectedIndices = [index]
            ensureVisible(index: index)
            needsDisplay = true
        case .source:
            artLens.resetNavigation()
            needsLayout = true   // the offline banner shows on the local source only
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
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        stopLoadingAnimation(force: true)
        stopServerNameScroll()
        backdropView?.stop()
    }

    /// Synchronously cancel every in-flight task, work item, and timer this view and its model
    /// own so they can be deallocated immediately when the controller is torn down for a UI
    /// reload — rather than being pinned alive (and mutating dead UI state) by a detached
    /// `@MainActor` expand/load task or a self-retaining repeating timer. `deinit` is deferred by
    /// AppKit's autorelease pool, so `WindowManager.teardownModeDependentWindows()` calls this
    /// *before* closing the window.
    func prepareForUITeardown() {
        isPreparingForUITeardown = true
        model.cancelAll()
        for task in [currentTrackArtworkLoadTask, artworkLoadTask, radioPlayTask] {
            task?.cancel()
        }
        youtubeVideoActions.cancel()
        currentTrackArtworkLoadTask = nil; artworkLoadTask = nil; radioPlayTask = nil

        // Timers (timers with a target/captured self can also pin the view alive).
        typeAheadTimer?.invalidate(); typeAheadTimer = nil
        stopLoadingAnimation(force: true)
        stopServerNameScroll()
        backdropView?.stop()
        backdropView?.removeFromSuperview()
        backdropView = nil
        artLens.teardown()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        updateCornerMask()
        updateEmbeddedSubviewFrames()
        refreshBackdrop()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        startServerNameScroll()
        updateEmbeddedSubviewFrames()
    }

    override func layout() {
        super.layout()
        updateEmbeddedSubviewFrames()
    }

    // MARK: - Current Skin Helper
    
    private func currentSkin() -> ModernSkin {
        return ModernSkinEngine.shared.currentSkin ?? ModernSkinLoader.shared.loadDefault()
    }

    private let backdropScrimAlpha: CGFloat = 0.72

    private var backdropActive: Bool {
        WindowManager.shared.isRunningModernUI && effectiveBackdropMode.showsCava
    }

    private var showsLegacyArtwork: Bool {
        WindowManager.shared.isRunningModernUI && effectiveBackdropMode.showsArt
    }

    private var effectiveBackdropMode: BrowserBackdropMode {
        compactMode
            ? WindowManager.shared.compactBackdropMode
            : WindowManager.shared.libraryBackdropMode
    }

    private var backdropScope: CavaSettings.Scope {
        compactMode ? .compactWindow : .libraryWindow
    }

    private func contentFill(_ base: NSColor) -> NSColor {
        guard backdropActive else { return base }
        return base.withAlphaComponent(base.alphaComponent * backdropScrimAlpha)
    }

    private func updateHistoryHostingBackground() {
        guard let historyHostingView else { return }
        let background = contentFill(currentSkin().backgroundColor)
        historyHostingView.layer?.backgroundColor = background.cgColor
        historyHostingView.layer?.isOpaque = !backdropActive && background.alphaComponent >= 1
    }

    private func updateCornerMask() {
        guard let layer = self.layer else { return }
        let cornerRadius = currentSkin().config.window.cornerRadius ?? 0
        layer.cornerRadius = cornerRadius
        layer.masksToBounds = cornerRadius > 0
        backdropView?.setSharpCorners(sharpCorners)
        guard cornerRadius > 0 else { return }
        let allCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                         .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer.maskedCorners = allCorners.subtracting(sharpCorners)
    }

    private func skinAppearance(for skin: ModernSkin) -> NSAppearance? {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        skin.backgroundColor.usingColorSpace(.deviceRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        let brightness = 0.299 * r + 0.587 * g + 0.114 * b
        return NSAppearance(named: brightness < 0.5 ? .darkAqua : .aqua)
    }

    private func makeHistoryHostingView() -> NSHostingView<StatsContentView> {
        let skin = currentSkin()
        let rootView = StatsContentView(agent: historyAgent,
                                        skinTextColor: Color(skin.textColor),
                                        headerTitle: "Library Data",
                                        heatmapTheme: ContributionHeatmapTheme(modernSkin: skin))
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        let background = contentFill(skin.backgroundColor)
        hostingView.layer?.backgroundColor = background.cgColor
        hostingView.layer?.isOpaque = !backdropActive && background.alphaComponent >= 1
        hostingView.appearance = skinAppearance(for: skin)
        hostingView.setAccessibilityIdentifier("modernLibraryBrowser.data")
        hostingView.setAccessibilityLabel("Library Data")
        return hostingView
    }

    private func ensureHistoryHostingView() {
        guard historyHostingView == nil else { return }
        let hostingView = makeHistoryHostingView()
        addSubview(hostingView)
        historyHostingView = hostingView
        updateEmbeddedSubviewFrames()
    }

    private func updateHistoryHostingVisibility() {
        if model.browseMode.isHistoryMode {
            ensureHistoryHostingView()
        }
        // The embedded queue covers the content region in Playlist mode, so the SwiftUI
        // history subview must stay hidden there regardless of browseMode.
        let inQueueMode = compactMode && compactContentMode == .queue
        let isVisible = model.browseMode.isHistoryMode && !inQueueMode
        historyHostingView?.isHidden = !isVisible
        updateEmbeddedSubviewFrames()
    }

    private func embeddedHistoryContentRect() -> NSRect {
        NSRect(
            x: Layout.borderWidth,
            y: contentRegionBottomY,
            width: bounds.width - Layout.borderWidth * 2,
            height: max(0, listTopY - contentRegionBottomY)
        )
    }

    private func updateEmbeddedSubviewFrames() {
        historyHostingView?.frame = embeddedHistoryContentRect()
        // Flow / Tiles leave the alphabet index beside them.
        artLens.frame = listLayout().area.divided(atDistance: Layout.alphabetWidth, from: .maxXEdge).remainder
        updateCompactPlayerBarFrame()
        updateCompactPlaylistFrame()
        updateBackdropFrame()
    }

    private func updateBackdropFrame() {
        guard let backdropView, let container = superview else { return }
        backdropView.frame = container.bounds
    }

    /// Switching from an opaque browser to a translucent backdrop composition can leave portions
    /// of AppKit's layer cache untouched on the first selection. Repaint the complete sibling
    /// hierarchy now and once more after menu tracking/layout has returned to the main run loop.
    private func redrawBackdropComposition(in container: NSView?) {
        guard let container else {
            needsDisplay = true
            return
        }

        container.markSubtreeForDisplayAndLayout()
        container.layoutSubtreeIfNeeded()
        container.window?.displayIfNeeded()

        DispatchQueue.main.async { [weak self, weak container] in
            guard let self, let container, self.superview === container else { return }
            self.updateBackdropFrame()
            container.markSubtreeForDisplayAndLayout()
            container.layoutSubtreeIfNeeded()
            container.window?.displayIfNeeded()
        }
    }

    func refreshBackdrop() {
        let container = superview
        guard !isPreparingForUITeardown,
              WindowManager.shared.isRunningModernUI,
              effectiveBackdropMode.showsCava,
              let container else {
            backdropView?.stop()
            backdropView?.removeFromSuperview()
            backdropView = nil
            updateHistoryHostingBackground()
            if showsLegacyArtwork,
               let track = WindowManager.shared.audioEngine.currentTrack,
               artworkTrackId != track.id || currentTrackArtwork == nil {
                loadArtwork(for: track)
            }
            redrawBackdropComposition(in: container)
            return
        }

        let backdrop: CompactBackdropView
        if let existing = backdropView, existing.scope == backdropScope {
            backdrop = existing
        } else {
            backdropView?.stop()
            backdropView?.removeFromSuperview()
            backdrop = CompactBackdropView(
                frame: container.bounds,
                scope: backdropScope,
                modeProvider: { [weak self] in self?.effectiveBackdropMode ?? .off }
            )
            container.addSubview(backdrop, positioned: .below, relativeTo: self)
            backdropView = backdrop
        }
        backdrop.frame = container.bounds
        backdrop.setSharpCorners(sharpCorners)
        backdrop.reload()
        updateHistoryHostingBackground()

        if showsLegacyArtwork,
           let track = WindowManager.shared.audioEngine.currentTrack,
           artworkTrackId != track.id || currentTrackArtwork == nil {
            loadArtwork(for: track)
        }
        redrawBackdropComposition(in: container)
    }

    func stopBackdrop() {
        backdropView?.stop()
    }

    /// Create/position/remove the embedded compact player bar to match the current mode.
    private func updateCompactPlayerBarFrame() {
        guard compactMode else {
            compactPlayerBar?.removeFromSuperview()
            compactPlayerBar = nil
            return
        }
        let bar: CompactPlayerBarView
        if let existing = compactPlayerBar {
            bar = existing
        } else {
            bar = CompactPlayerBarView(frame: .zero)
            addSubview(bar)
            compactPlayerBar = bar
            seedCompactPlayerBar(bar)
        }
        bar.frame = NSRect(x: Layout.borderWidth, y: topChromeBottomY,
                           width: bounds.width - Layout.borderWidth * 2,
                           height: compactPlayerBarHeight)
    }

    /// Create/position/remove the embedded compact play queue to match the current mode.
    /// It fills the content region below the toggle strip and covers the library chrome
    /// (server bar / tabs / alphabet index) when shown, so queue mode hides library chrome.
    private func updateCompactPlaylistFrame() {
        guard compactMode else {
            compactPlaylistView?.removeFromSuperview()
            compactPlaylistView = nil
            return
        }
        let queue: ModernPlaylistView
        let didCreateQueue: Bool
        if let existing = compactPlaylistView {
            queue = existing
            didCreateQueue = false
        } else {
            queue = ModernPlaylistView(frame: .zero)
            queue.isEmbedded = true
            // Render above the library chrome and the Cava/art backdrop.
            addSubview(queue)
            compactPlaylistView = queue
            didCreateQueue = true
        }
        let border = Layout.borderWidth
        queue.frame = NSRect(x: border, y: contentRegionBottomY,
                             width: bounds.width - border * 2,
                             height: max(0, topChromeBottomY - contentRegionBottomY))
        queue.isHidden = (compactContentMode != .queue)
        if didCreateQueue {
            // `reloadData()` needs the final frame so it can scroll the current track into view.
            queue.reloadData()
            if compactContentMode == .queue {
                window?.makeFirstResponder(queue)
            }
        }
    }

    /// Refresh the private playlist presentation after the shared audio-engine queue mutates.
    func reloadCompactPlaylist() {
        compactPlaylistView?.reloadData()
    }

    /// Seed the bar with the engine's current state so it isn't blank until the next update tick.
    private func seedCompactPlayerBar(_ bar: CompactPlayerBarView) {
        let engine = WindowManager.shared.audioEngine
        bar.updateTrackInfo(engine.currentTrack)
        bar.updateTime(current: engine.currentTime, duration: engine.duration)
        bar.updatePlaybackState()
    }

    // MARK: - Compact Player Bar Forwarding

    func compactBarUpdateTime(current: TimeInterval, duration: TimeInterval) {
        compactPlayerBar?.updateTime(current: current, duration: duration)
    }

    func compactBarUpdateTrack(_ track: Track?) {
        compactPlayerBar?.updateTrackInfo(track)
    }

    func compactBarUpdatePlaybackState() {
        compactPlayerBar?.updatePlaybackState()
    }

    private var isMetalRenderStyle: Bool {
        // Read from the skin we actually draw with (currentSkin()), not the engine's global
        // currentRenderStyle. The two can momentarily disagree across a skin swap, which let
        // the modern darkened top-chrome band paint over the metal brushed surface.
        currentSkin().renderStyle == .metal
    }

    /// Active metal finish (falls back to Brushed Steel). The control colors below are
    /// derived from its per-finish EQ control palette so they adapt to dark finishes:
    /// on Anodized Black / Gunmetal the band fills go dark and the strokes go light, so
    /// the tab/control boxes stay visible instead of washing out against the chrome.
    private var metalMaterial: MetalMaterial {
        ModernSkinEngine.shared.currentSkin?.metalMaterial ?? .brushedSteel
    }

    // Header/alphabet band — the strip wrapping the top and the right-side alphabet index.
    // In metal mode the top chrome and alphabet index blend into the brushed-metal panel
    // (no darker overlay) so the whole window reads as a single continuous surface.
    private var metalControlBandFill: NSColor {
        .clear
    }

    private var metalControlFill: NSColor {
        metalMaterial.eqControlFill
    }

    private var metalControlActiveFill: NSColor {
        metalMaterial.eqActiveFill
    }

    private var metalControlStroke: NSColor {
        metalMaterial.eqStroke
    }

    private var metalRatingColor: NSColor {
        NSColor(calibratedRed: 0.34, green: 0.28, blue: 0.13, alpha: 1.0)
    }
    
    // MARK: - Drawing
    
    override func draw(_ dirtyRect: NSRect) {
        let capturedArtwork = currentArtwork
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        
        let skin = currentSkin()
        let mainOpacity = skin.resolvedOpacity(for: .mainWindow)
        let backgroundOpacity = backdropActive
            ? mainOpacity.background * backdropScrimAlpha
            : mainOpacity.background
        let isShowingCompactPlaylist = compactMode && compactContentMode == .queue

        // Fast path: scroll timer marks only server bar dirty — skip full window redraw.
        // Always fill the full background first (copy blend mode) so the layer is never
        // left partially transparent from accumulated alpha on repeated scroll-tick draws.
        let serverBarY = topChromeBottomY - Layout.serverBarHeight
        let sbRect = NSRect(x: 0, y: serverBarY, width: bounds.width, height: Layout.serverBarHeight)
        if !isShowingCompactPlaylist, sbRect.contains(dirtyRect) {
            // Build the renderer from the current skin (not the cached instance) so the
            // background can't lag a skin swap and render the wrong surface under the bands.
            let renderer = ModernSkinRenderer(skin: skin)
            renderer.drawWindowBackground(
                in: bounds,
                context: context,
                adjacentEdges: adjacentEdges,
                sharpCorners: sharpCorners,
                backgroundOpacity: backgroundOpacity,
                drawMetalAccentStrip: false
            )
            context.saveGState()
            context.setAlpha(mainOpacity.content)
            drawServerBar(in: context, serverBarY: serverBarY, skin: skin)
            context.restoreGState()
            return
        }

        // Normal mode - bottom-left origin (no coordinate flipping)
        let renderer = ModernSkinRenderer(skin: skin)
        renderer.drawWindowBackground(
            in: bounds,
            context: context,
            adjacentEdges: adjacentEdges,
            sharpCorners: sharpCorners,
            backgroundOpacity: backgroundOpacity,
            drawMetalAccentStrip: false
        )
        renderer.drawWindowBorder(
            in: bounds,
            context: context,
            adjacentEdges: adjacentEdges,
            sharpCorners: sharpCorners,
            occlusionSegments: edgeOcclusionSegments,
            borderOpacity: mainOpacity.border
        )

        context.saveGState()
        context.setAlpha(mainOpacity.content)
        
        // Title bar, close button use base (unscaled) coordinates
        // because the renderer's scaledRect() multiplies by scaleFactor
        let scale = ModernSkinElements.scaleFactor
        let baseWidth = bounds.width / scale
        let baseHeight = bounds.height / scale
        
        // Draw title bar
        if !WindowManager.shared.hideTitleBars {
            // Title bar at TOP in base space
            let tbh = ModernSkinElements.titleBarBaseHeight
            let titleBarRect = NSRect(x: 0, y: baseHeight - tbh, width: baseWidth, height: tbh)
            renderer.drawTitleBar(in: titleBarRect, title: "NULLPLAYER LIBRARY", prefix: "library_", context: context)

            // Close button in title bar (base space)
            let closeBtnRect = NSRect(x: baseWidth - 14, y: baseHeight - tbh / 2 - 5, width: 10, height: 10)
            let closeState = pressedButton == .close ? "pressed" : "normal"
            renderer.drawWindowControlButton("library_btn_close", state: closeState, in: closeBtnRect, context: context)
        }
        
        updateHistoryHostingVisibility()

        // In the compact window's Playlist mode the embedded queue subview fills the content
        // region, so skip drawing the library chrome (server bar / tabs / search / list /
        // alphabet) behind it — the shared Cava/art backdrop then shows through the queue,
        // matching how it shows behind the library list.
        let showLibraryContent = !isShowingCompactPlaylist

        if showLibraryContent {
            // Server bar (below title bar in screen coords)
            drawServerBar(in: context, serverBarY: serverBarY, skin: skin)

            // Tab bar (below server bar)
            let tabBarY = serverBarY - Layout.tabBarHeight
            drawTabBar(in: context, tabBarY: tabBarY, skin: skin)

            // Search bar (below tab bar, only in search mode)
            if model.browseMode == .search {
                drawSearchBar(in: context, searchBarY: listTopY, skin: skin)
            }

            let layout = listLayout()
            let listRect = layout.area

            // Offline volume banner (local source only, under the list)
            if let bannerRect = layout.banner {
                drawOfflineBanner(in: context, rect: bannerRect, skin: skin)
            }

            if model.browseMode.isHistoryMode {
                drawArtworkBackground(in: context, listRect: listRect, artwork: capturedArtwork)
                // SwiftUI-hosted history content is rendered via an embedded subview.
            } else if model.currentSource.isPlex && !PlexManager.shared.isLinked {
                drawNotLinkedState(in: context, listRect: listRect, skin: skin)
            } else if model.isLoading {
                drawLoadingState(in: context, listRect: listRect, skin: skin)
            } else if let error = model.errorMessage {
                drawErrorState(in: context, message: error, listRect: listRect, skin: skin)
            } else if artLens.isPresenting {
                // The Flow / Tiles view renders the art. Draw nothing here: the window
                // background (already filled above — translucent when a Cava backdrop is active,
                // opaque otherwise) is exactly what should sit behind the covers, so the Cava
                // backdrop shows through at full strength instead of behind a second scrim.
                drawAlphabetIndex(in: context, rect: layout.alphabet, skin: skin)
            } else {
                drawListArea(in: context, layout: layout, skin: skin, artwork: capturedArtwork)
            }

            // Status bar text
            drawStatusBarText(in: context, skin: skin)
        }

        // Library | Playlist toggle footer at the bottom (compact window only).
        if compactMode {
            drawCompactFooter(in: context, skin: skin)
        }

        context.restoreGState()

        if isHighlighted {
            NSColor.white.withAlphaComponent(0.15).setFill()
            bounds.fill()
        }
    }

    // MARK: - Tab Bar Drawing (Modern Boxed Toggle Style)
    
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

    /// Per-tab widths across the tab bar. Content-aware: each tab is sized to its own label
    /// plus padding, then any leftover space is shared equally so every tab gets some
    /// breathing room and short labels (e.g. "TV", "Data") don't hog equal width.
    private func tabBarWidths(totalWidth: CGFloat, labels: [String], font: NSFont,
                              horizontalScale: CGFloat) -> [CGFloat] {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let padding = 18 * ModernSkinElements.sizeMultiplier * horizontalScale
        let natural = labels.map { $0.size(withAttributes: attrs).width + padding }
        let naturalSum = natural.reduce(0, +)
        if naturalSum > totalWidth {
            let scale = totalWidth / naturalSum
            return natural.map { $0 * scale }
        }
        let extra = (totalWidth - naturalSum) / CGFloat(labels.count)
        return natural.map { $0 + extra }
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
            case "movie":  count = model.plex.movies.count
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
        /// A configured server: its name in a fixed field, then its library.
        case server(name: String, library: String)
        /// A server source with nothing configured: a centred prompt.
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
            return .server(name: server?.name ?? "Select Server", library: manager.currentLibrary?.title ?? "Select")
        case .subsonic(let serverId):
            let manager = SubsonicManager.shared
            guard let server = manager.servers.first(where: { $0.id == serverId }) else {
                return .unconfigured(prompt: "Click to add a Subsonic server")
            }
            return .server(name: server.name, library: manager.currentMusicFolder?.name ?? "All")
        case .jellyfin(let serverId):
            guard let server = JellyfinManager.shared.servers.first(where: { $0.id == serverId }) else {
                return .unconfigured(prompt: "Click to add a Jellyfin server")
            }
            return .server(name: server.name, library: jellyfinCurrentLibraryName)
        case .emby(let serverId):
            guard let server = EmbyManager.shared.servers.first(where: { $0.id == serverId }) else {
                return .unconfigured(prompt: "Click to add an Emby server")
            }
            return .server(name: server.name, library: embyCurrentLibraryName)
        }
    }

    /// Server-bar field widths at full size, in points before scaling.
    private static let serverFieldWidth: CGFloat = 100
    /// The library field's narrowest width; it grows into the free space before the right-side buttons.
    private static let minLibraryFieldWidth: CGFloat = 80

    /// The side of the square refresh and List / Flow / Tiles buttons.
    private func serverBarButtonSide(m: CGFloat) -> CGFloat {
        Layout.serverBarHeight - 6 * m
    }

    /// Full-size content width needed by the current server-bar state.
    private func serverBarNaturalWidth(font: NSFont) -> CGFloat {
        let m = ModernSkinElements.sizeMultiplier
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textWidth: (String) -> CGFloat = { $0.size(withAttributes: attrs).width }
        let prefixWidth = textWidth("Source: ")
        let leadingInset = 4 * m
        let minimumGap = 12 * m

        var rightWidth = 8 * m + serverBarButtonSide(m: m)
        if artLens.hasItems {
            rightWidth += 12 * m + viewModeButtonsWidth(m: m)
        }

        let leftWidth: CGFloat
        switch serverBarContent {
        case .builtIn(let name):
            leftWidth = leadingInset + prefixWidth + textWidth(withItemCount(name)) + 28 * m + textWidth("+ADD")
        case .server:
            leftWidth = leadingInset + prefixWidth + Self.serverFieldWidth * m + 16 * m +
                textWidth("Lib:") + 4 * m + Self.minLibraryFieldWidth * m
        case .unconfigured(let prompt):
            leftWidth = leadingInset + prefixWidth
            return max(leftWidth + minimumGap + rightWidth,
                       textWidth(prompt) + 2 * max(leftWidth, rightWidth) + 2 * minimumGap)
        }
        return leftWidth + minimumGap + rightWidth
    }

    private func tabRowNaturalWidth(font: NSFont) -> CGFloat {
        let m = ModernSkinElements.sizeMultiplier
        let attrs: [NSAttributedString.Key: Any] = [.font: font]

        var labels = LibraryBrowseMode.tabs.map { $0.title }
        labels.append("Channels")
        labels.append("Folders")
        let maxLabelWidth = labels.map { $0.size(withAttributes: attrs).width }.max() ?? 0

        let sortWidth = "Sort".size(withAttributes: attrs).width + 16 * m
        let perTab = maxLabelWidth + 12 * m
        return perTab * CGFloat(LibraryBrowseMode.tabs.count) + sortWidth
    }

    private func topChromeScale(for skin: ModernSkin) -> CGFloat {
        let font = skin.libraryFont(size: compactMode ? 11 : 12)
        let referenceWidth = max(tabRowNaturalWidth(font: font),
                                 serverBarNaturalWidth(font: font))
        let availableWidth = max(0, bounds.width - Layout.borderWidth * 2)
        guard referenceWidth > 0 else { return 1 }
        return min(1, max(0.66, availableWidth / referenceWidth))
    }

    /// Smallest window width at which every full-size compact tab label fits its outline.
    var minimumCompactContentWidth: CGFloat {
        let font = currentSkin().libraryFont(size: 11)
        return ceil(tabRowNaturalWidth(font: font) + Layout.borderWidth * 2)
    }

    private func drawTabBar(in context: CGContext, tabBarY: CGFloat, skin: ModernSkin) {
        let tabBarRect = NSRect(x: Layout.borderWidth, y: tabBarY,
                                width: bounds.width - Layout.borderWidth * 2, height: Layout.tabBarHeight)
        
        // Background
        contentFill(isMetalRenderStyle ? metalControlBandFill : skin.surfaceColor.withAlphaComponent(0.4)).setFill()
        context.fill(tabBarRect)

        let chromeScale = topChromeScale(for: skin)
        let font = ModernLibraryTab.font(skin: skin, compact: compactMode, scale: chromeScale)
        
        // Sort indicator width on right
        let sortText = "Sort"
        let sortAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: skin.applyTextOpacity(to: skin.textDimColor)
        ]
        let sortSize = sortText.size(withAttributes: sortAttrs)
        let sortWidth = sortSize.width + 16 * ModernSkinElements.sizeMultiplier * chromeScale
        
        let tabsWidth = tabBarRect.width - sortWidth

        let modes = LibraryBrowseMode.tabs
        // Resolved (possibly dynamic) labels + content-aware widths, shared with hit-testing.
        let labels = currentTabLabels()
        let widths = tabBarWidths(totalWidth: tabsWidth, labels: labels, font: font,
                                  horizontalScale: chromeScale)
        var tabX = tabBarRect.minX
        tabButtonRects.removeAll(keepingCapacity: true)

        for (index, mode) in modes.enumerated() {
            let tabWidth = widths[index]
            let tabRect = NSRect(x: tabX, y: tabBarY,
                                 width: tabWidth, height: Layout.tabBarHeight)
            tabX += tabWidth

            let label = labels[index]
            var isSelected = mode == model.browseMode
            // Highlight the plists slot when browseMode is .folders (local source only).
            if mode == .plists, model.browseMode == .folders, case .local = model.currentSource {
                isSelected = true
            }
            let tabInset = 2 * ModernSkinElements.sizeMultiplier * chromeScale
            ModernLibraryTab.draw(label, isActive: isSelected,
                          rect: tabRect.insetBy(dx: tabInset,
                                               dy: 2 * ModernSkinElements.sizeMultiplier),
                          font: font, skin: skin, context: context)
            tabButtonRects.append(tabRect)
        }
        
        // Sort indicator
        let sortRect = NSRect(x: tabBarRect.maxX - sortWidth, y: tabBarY,
                              width: sortWidth, height: Layout.tabBarHeight)
        sortButtonRect = sortRect
        drawInlineTabBarLabel(label: sortText, rect: sortRect,
                              font: font, skin: skin, context: context)
    }
    
    /// Full band of the Library|Playlist toggle footer at the bottom (compact window only),
    /// sitting just above the thin status-bar margin.
    private var compactFooterRect: NSRect {
        NSRect(x: Layout.borderWidth, y: Layout.statusBarHeight,
               width: bounds.width - Layout.borderWidth * 2,
               height: compactFooterHeight)
    }

    /// The two full-width halves of the footer band — (.library, .queue) — used for both
    /// hit-testing and (after insetting to the tab-box size) drawing, mirroring the tab bar.
    private func compactToggleSegmentRects() -> (library: NSRect, queue: NSRect) {
        let strip = compactFooterRect
        let halfWidth = (strip.width / 2).rounded()
        let library = NSRect(x: strip.minX, y: strip.minY, width: halfWidth, height: strip.height)
        let queue = NSRect(x: strip.minX + halfWidth, y: strip.minY,
                           width: strip.width - halfWidth, height: strip.height)
        return (library, queue)
    }

    private func drawCompactFooter(in context: CGContext, skin: ModernSkin) {
        guard compactFooterHeight > 0 else { return }

        // Fill the band to match the tab-bar row so the footer reads as part of the chrome.
        contentFill(isMetalRenderStyle ? metalControlBandFill : skin.surfaceColor.withAlphaComponent(0.4)).setFill()
        context.fill(compactFooterRect)

        let chromeScale = topChromeScale(for: skin)
        let font = ModernLibraryTab.font(skin: skin, compact: compactMode, scale: chromeScale)
        let m = ModernSkinElements.sizeMultiplier
        // Same box insets the tab bar uses (drawTabBar), so the toggle boxes match the tabs.
        let insetX = 2 * m * chromeScale
        let insetY = 2 * m
        let segments = compactToggleSegmentRects()
        ModernLibraryTab.draw("Library", isActive: compactContentMode == .library,
                      rect: segments.library.insetBy(dx: insetX, dy: insetY),
                      font: font, skin: skin, context: context)
        ModernLibraryTab.draw("Playlist", isActive: compactContentMode == .queue,
                      rect: segments.queue.insetBy(dx: insetX, dy: insetY),
                      font: font, skin: skin, context: context)
    }

    /// The List / Flow / Tiles buttons: three squares the server bar's height, 2 pt apart.
    private func viewModeButtonsWidth(m: CGFloat) -> CGFloat {
        let count = CGFloat(LibraryViewMode.allCases.count)
        return count * serverBarButtonSide(m: m) + (count - 1) * 2 * m
    }

    private func drawInlineTabBarLabel(label: String, rect: NSRect,
                                       font: NSFont, skin: ModernSkin, context: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: skin.applyTextOpacity(to: skin.textDimColor)
        ]
        let textSize = label.size(withAttributes: attrs)
        let textOrigin = NSPoint(x: rect.midX - textSize.width / 2,
                                 y: rect.midY - textSize.height / 2)
        drawText(label, at: textOrigin, withAttributes: attrs, context: context)
    }
    
    // MARK: - Server Bar Drawing
    
    private func drawServerBar(in context: CGContext, serverBarY: CGFloat, skin: ModernSkin) {
        let barRect = NSRect(x: Layout.borderWidth, y: serverBarY,
                            width: bounds.width - Layout.borderWidth * 2,
                            height: Layout.serverBarHeight)
        
        contentFill(isMetalRenderStyle ? metalControlBandFill : skin.surfaceColor.withAlphaComponent(0.4)).setFill()
        context.fill(barRect)

        let dimColor = skin.textDimColor
        let dataColor = skin.dataColor
        let accentColor = skin.accentColor

        let skinName = ModernSkinEngine.shared.currentSkinName ?? "default"
        let currentScale = ModernSkinElements.sizeMultiplier
        let chromeScale = topChromeScale(for: skin)
        let isMetal = isMetalRenderStyle
        if cachedServerBarFont == nil ||
            cachedServerBarFontSkinName != skinName ||
            cachedServerBarFontScale != currentScale ||
            cachedServerBarIsMetal != isMetal ||
            cachedServerBarCompact != compactMode ||
            cachedServerBarChromeScale != chromeScale {
            let font = skin.libraryFont(size: (compactMode ? 11 : 12) * chromeScale)
            cachedServerBarFont = font
            cachedServerBarFontSkinName = skinName
            cachedServerBarFontScale = currentScale
            cachedServerBarIsMetal = isMetal
            cachedServerBarCompact = compactMode
            cachedServerBarChromeScale = chromeScale
            cachedPrefixAttrs = [.font: font, .foregroundColor: skin.applyTextOpacity(to: dimColor)]
            cachedDataAttrs   = [.font: font, .foregroundColor: skin.applyTextOpacity(to: dataColor)]
            cachedActiveAttrs = [.font: font, .foregroundColor: skin.applyTextOpacity(to: isMetal ? skin.textColor : accentColor)]
        }
        let font = cachedServerBarFont!
        let prefixAttrs = cachedPrefixAttrs!
        let dataAttrs   = cachedDataAttrs!
        let activeAttrs = cachedActiveAttrs!

        let m = ModernSkinElements.sizeMultiplier
        let hm = m * chromeScale
        let textY = barRect.minY + (barRect.height - font.pointSize - 2 * m) / 2

        refreshButtonRect = .zero
        sourceButtonRect = .zero
        libraryButtonRect = .zero
        addButtonRect = .zero
        serverNameTextWidth = 0
        serverNameMaxWidth = 0
        libraryNameTextWidth = 0
        libraryNameMaxWidth = 0

        // Common prefix
        let prefix = "Source: "
        drawText(prefix, at: NSPoint(x: barRect.minX + 4 * hm, y: textY), withAttributes: prefixAttrs, context: context)
        let prefixWidth = prefix.size(withAttributes: prefixAttrs).width
        let sourceNameStartX = barRect.minX + 4 * hm + prefixWidth
        
        // Right side: refresh button (F5), boxed like the view-mode buttons
        let buttonSide = serverBarButtonSide(m: m)
        let refreshX = barRect.maxX - buttonSide - 8 * hm
        let refreshBox = NSRect(x: refreshX, y: barRect.minY + 3 * m, width: buttonSide, height: buttonSide)
        let refreshColor = ModernLibraryTab.drawBox(isActive: false, rect: refreshBox, skin: skin, context: context)
        LibraryBarIcon.fill(LibraryBarIcon.refresh,
                            in: refreshBox.insetBy(dx: buttonSide * 0.28, dy: buttonSide * 0.28),
                            color: skin.applyTextOpacity(to: refreshColor), context: context)
        refreshButtonRect = NSRect(x: refreshX, y: barRect.minY,
                                   width: barRect.maxX - refreshX, height: barRect.height)
        
        var visEndX = refreshX

        // List / Flow / Tiles — shown when the current list has art to show.
        viewModeButtonRects = []
        if artLens.hasItems {
            let leadingX = refreshX - 12 * hm - viewModeButtonsWidth(m: m)
            var x = leadingX
            for mode in LibraryViewMode.allCases {
                let rect = NSRect(x: x, y: barRect.minY + 3 * m, width: buttonSide, height: buttonSide)
                let color = ModernLibraryTab.drawBox(isActive: artLens.mode == mode, rect: rect, skin: skin, context: context)
                mode.drawIcon(in: rect.insetBy(dx: buttonSide * 0.28, dy: buttonSide * 0.28),
                              color: skin.applyTextOpacity(to: color), context: context)
                viewModeButtonRects.append((mode, rect))
                x += buttonSide + 2 * m
            }
            visEndX = leadingX
        }

        // Source-specific content
        switch serverBarContent {
        case .builtIn(let name):
            let sourceText = withItemCount(name)
            drawText(sourceText, at: NSPoint(x: sourceNameStartX, y: textY), withAttributes: dataAttrs, context: context)
            let sourceTextWidth = sourceText.size(withAttributes: dataAttrs).width
            sourceButtonRect = NSRect(x: barRect.minX, y: barRect.minY,
                                      width: sourceNameStartX + sourceTextWidth - barRect.minX,
                                      height: barRect.height)

            let addText = "+ADD"
            let addX = sourceNameStartX + sourceTextWidth + 28 * hm
            drawText(addText, at: NSPoint(x: addX, y: textY), withAttributes: activeAttrs, context: context)
            addButtonRect = NSRect(x: addX, y: barRect.minY,
                                   width: max(addText.size(withAttributes: activeAttrs).width, 50 * hm),
                                   height: barRect.height)

            // Scan animation: small spinner at center of bar while library is scanning
            if case .local = model.currentSource, isLibraryScanning {
                let cx = barRect.midX
                let cy = barRect.midY
                let innerR: CGFloat = 3 * m
                let outerR: CGFloat = 8 * m
                let n = 8
                let step = CGFloat.pi * 2 / CGFloat(n)
                for i in 0..<n {
                    let angle = CGFloat(i) * step - CGFloat.pi / 2 + CGFloat(loadingAnimationFrame) * step
                    let spinnerColor = isMetalRenderStyle ? skin.textColor : skin.accentColor
                    spinnerColor.withAlphaComponent(CGFloat(i + 1) / CGFloat(n) * 0.9).setStroke()
                    context.setLineWidth(1.5 * m)
                    context.move(to: CGPoint(x: cx + cos(angle) * innerR, y: cy + sin(angle) * innerR))
                    context.addLine(to: CGPoint(x: cx + cos(angle) * outerR, y: cy + sin(angle) * outerR))
                    context.strokePath()
                }
                let scanText = "SCANNING"
                let scanTextX = cx + outerR + 6 * m
                drawText(scanText, at: NSPoint(x: scanTextX, y: textY), withAttributes: prefixAttrs, context: context)
            }

        case .server(let serverName, let library):
            // A changed name scrolls from its start.
            if serverName != lastServerName {
                lastServerName = serverName
                serverNameScrollOffset = 0
            }
            if library != lastLibraryName {
                lastLibraryName = library
                libraryNameScrollOffset = 0
            }
            let textH = font.pointSize + 4 * m

            serverNameMaxWidth = Self.serverFieldWidth * hm
            serverNameTextWidth = (serverName as NSString).size(withAttributes: dataAttrs).width
            drawScrollingText(serverName, startX: sourceNameStartX, textY: textY,
                              availableWidth: serverNameMaxWidth, scrollOffset: serverNameScrollOffset,
                              textHeight: textH, attributes: dataAttrs, in: context)

            let libLabel = "Lib:"
            let libraryLabelX = sourceNameStartX + serverNameMaxWidth + 16 * hm
            drawText(libLabel, at: NSPoint(x: libraryLabelX, y: textY), withAttributes: prefixAttrs, context: context)

            let libraryX = libraryLabelX + libLabel.size(withAttributes: prefixAttrs).width + 4 * hm
            let libraryText = withItemCount(library)
            // The field grows into the free space before the right cluster; it scrolls when even that is short.
            libraryNameMaxWidth = max(Self.minLibraryFieldWidth * hm, visEndX - 24 * hm - libraryX)
            libraryNameTextWidth = (libraryText as NSString).size(withAttributes: dataAttrs).width
            drawScrollingText(libraryText, startX: libraryX, textY: textY,
                              availableWidth: libraryNameMaxWidth, scrollOffset: libraryNameScrollOffset,
                              textHeight: textH, attributes: dataAttrs, in: context)

            sourceButtonRect = NSRect(x: barRect.minX, y: barRect.minY,
                                      width: sourceNameStartX + serverNameMaxWidth - barRect.minX,
                                      height: barRect.height)
            libraryButtonRect = NSRect(x: libraryLabelX, y: barRect.minY,
                                       width: libraryX + libraryNameMaxWidth - libraryLabelX,
                                       height: barRect.height)
            if serverNameTextWidth > serverNameMaxWidth || libraryNameTextWidth > libraryNameMaxWidth {
                startServerNameScroll()
            }

        case .unconfigured(let prompt):
            let promptWidth = prompt.size(withAttributes: prefixAttrs).width
            drawText(prompt, at: NSPoint(x: barRect.midX - promptWidth / 2, y: textY), withAttributes: prefixAttrs, context: context)
            sourceButtonRect = barRect
        }
    }
    
    /// Draw text with circular scrolling when it overflows the available width.
    /// Uses NSAttributedString drawing (system font) rather than bitmap sprites.
    private func drawScrollingText(_ text: String,
                                   startX: CGFloat, textY: CGFloat,
                                   availableWidth: CGFloat,
                                   scrollOffset: CGFloat,
                                   textHeight: CGFloat,
                                   attributes: [NSAttributedString.Key: Any],
                                   in context: CGContext) {
        let textWidth = (text as NSString).size(withAttributes: attributes).width

        // Text fits — draw once with a simple clip, no scrolling artifacts.
        guard textWidth > availableWidth else {
            context.saveGState()
            context.clip(to: NSRect(x: startX, y: textY, width: availableWidth, height: textHeight))
            drawText(text, at: NSPoint(x: startX, y: textY), withAttributes: attributes, context: context)
            context.restoreGState()
            return
        }

        let separatorWidth = textWidth * 0.3  // 30% gap before repeat
        let totalCycleWidth = textWidth + separatorWidth

        context.saveGState()
        context.clip(to: NSRect(x: startX, y: textY, width: availableWidth, height: textHeight))

        // Two passes for seamless circular wrap
        for pass in 0..<2 {
            let baseX = startX - scrollOffset + CGFloat(pass) * totalCycleWidth
            if baseX + totalCycleWidth < startX || baseX > startX + availableWidth { continue }
            drawText(text, at: NSPoint(x: baseX, y: textY), withAttributes: attributes, context: context)
        }

        context.restoreGState()
    }

    /// Draw string text without inheriting parent content alpha attenuation.
    private func drawText(_ text: String, at point: NSPoint,
                          withAttributes attributes: [NSAttributedString.Key: Any],
                          context: CGContext) {
        context.saveGState()
        context.setAlpha(1.0)
        text.draw(at: point, withAttributes: attributes)
        context.restoreGState()
    }

    /// Draw wrapped/truncated string text without inheriting parent content alpha attenuation.
    private func drawText(_ text: String, in rect: NSRect,
                          withAttributes attributes: [NSAttributedString.Key: Any],
                          context: CGContext) {
        context.saveGState()
        context.setAlpha(1.0)
        text.draw(in: rect, withAttributes: attributes)
        context.restoreGState()
    }

    /// Draw wrapped/truncated text without inheriting parent content alpha attenuation.
    private func drawText(_ text: String, in rect: NSRect,
                          options: NSString.DrawingOptions,
                          withAttributes attributes: [NSAttributedString.Key: Any],
                          context: CGContext) {
        context.saveGState()
        context.setAlpha(1.0)
        text.draw(with: rect, options: options, attributes: attributes)
        context.restoreGState()
    }

    // MARK: - Search Bar Drawing
    
    private func drawSearchBar(in context: CGContext, searchBarY: CGFloat, skin: ModernSkin) {
        let searchRect = NSRect(x: Layout.borderWidth + Layout.padding, y: searchBarY + 3,
                               width: bounds.width - Layout.borderWidth * 2 - Layout.padding * 2,
                               height: Layout.searchBarHeight - 6)
        
        let isFocused = window?.firstResponder === self
        let bgColor: NSColor
        if isMetalRenderStyle {
            bgColor = isFocused ? metalControlActiveFill : metalControlFill
        } else {
            bgColor = isFocused
                ? skin.accentColor.withAlphaComponent(0.15)
                : skin.surfaceColor.withAlphaComponent(0.3)
        }
        contentFill(bgColor).setFill()
        let path = NSBezierPath(roundedRect: searchRect, xRadius: 3, yRadius: 3)
        path.fill()
        
        if isFocused {
            (isMetalRenderStyle ? metalControlStroke : skin.accentColor.withAlphaComponent(0.5)).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        
        let font = skin.libraryFont(size: 9)
        let placeholder = model.currentSource.isYouTube ? "Search YouTube channels — press ↵" : "Type and press ↵ to search..."
        let displayText = model.searchQuery.isEmpty ? placeholder : model.searchQuery
        let textColor = model.searchQuery.isEmpty ? skin.textDimColor : skin.textColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: skin.applyTextOpacity(to: textColor)
        ]
        let textSize = displayText.size(withAttributes: attrs)
        let textY = searchRect.minY + (searchRect.height - textSize.height) / 2
        drawText(displayText, at: NSPoint(x: searchRect.minX + 6, y: textY), withAttributes: attrs, context: context)
        
        // Draw cursor
        if isFocused && !model.searchQuery.isEmpty {
            let cursorX = searchRect.minX + 6 + model.searchQuery.size(withAttributes: attrs).width + 1
            skin.textColor.setFill()
            context.fill(CGRect(x: cursorX, y: textY, width: 1, height: textSize.height))
        }
    }
    
    // MARK: - Offline Volume Banner

    private func drawOfflineBanner(in context: CGContext, rect: NSRect, skin: ModernSkin) {
        // Background — amber tint
        NSColor.systemOrange.withAlphaComponent(0.18).setFill()
        context.fill(rect)

        let offlineCount = model.offlineWatchFolders.reduce(0) { $0 + $1.totalCount }
        let names = model.offlineWatchFolders.map { $0.url.lastPathComponent }.joined(separator: ", ")
        let label = "⚠  \"\(names)\" offline — \(offlineCount) track\(offlineCount == 1 ? "" : "s") unavailable"

        let font = skin.scaledSystemFont(size: 7.5)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: skin.applyTextOpacity(to: skin.textColor)
        ]
        let textSize = label.size(withAttributes: attrs)
        let textOrigin = NSPoint(x: rect.minX + 6, y: rect.midY - textSize.height / 2)
        drawText(label, at: textOrigin, withAttributes: attrs, context: context)
    }

    // MARK: - List Area Drawing

    private func drawListArea(in context: CGContext, layout: ListLayout, skin: ModernSkin, artwork: NSImage?) {
        // An empty list has no columns, so `rows` is the whole list here.
        if model.displayItems.isEmpty {
            drawEmptyState(in: context, listRect: layout.rows, skin: skin)
            return
        }

        if let header = layout.header {
            drawColumnHeaders(in: context, header: header, skin: skin)
            // Fill the header-row gap above the alphabet index (and scrollbar) so it
            // matches the column-header band instead of showing the panel background.
            let gapRect = NSRect(x: header.rect.maxX, y: header.rect.minY,
                                 width: layout.area.maxX - header.rect.maxX, height: header.rect.height)
            contentFill(isMetalRenderStyle ? metalControlBandFill : skin.surfaceColor.withAlphaComponent(0.4)).setFill()
            context.fill(gapRect)
        }

        let listRect = layout.rows

        // Clip to content area
        context.saveGState()
        context.clip(to: listRect)
        
        drawArtworkBackground(in: context, listRect: listRect, artwork: artwork)
        rowThumbnails.beginPass(placeholder: skin.textDimColor.withAlphaComponent(0.15))
        
        // Draw items (bottom-left origin: item 0 at top of list, so we draw from top down)
        let visibleStart = max(0, Int(scrollOffset / itemHeight))
        let visibleEnd = min(model.displayItems.count, visibleStart + Int(listRect.height / itemHeight) + 2)
        
        guard visibleStart < visibleEnd else {
            context.restoreGState()
            drawAlphabetIndex(in: context, rect: layout.alphabet, skin: skin)
            return
        }
        
        let font = skin.scaledSystemFont(size: 8)
        let smallFont = skin.scaledSystemFont(size: 7.2)
        
        for index in visibleStart..<visibleEnd {
            // In bottom-left coords: item 0 is at top, so y decreases as index increases
            let itemTopY = listRect.maxY - CGFloat(index) * itemHeight + scrollOffset
            let y = itemTopY - itemHeight
            
            if y + itemHeight < listRect.minY || y > listRect.maxY { continue }
            
            let itemRect = NSRect(x: listRect.minX, y: y, width: listRect.width, height: itemHeight)
            let item = model.displayItems[index]
            let isSelected = selectedIndices.contains(index)

            // Dim tracks/episodes whose file lives on an offline volume
            let isOffline: Bool
            switch item.type {
            case .localTrack(let track):
                isOffline = model.offlineVolumePrefixes.contains { track.url.path.hasPrefix($0) }
            case .localEpisode(let ep):
                isOffline = model.offlineVolumePrefixes.contains { ep.url.path.hasPrefix($0) }
            default:
                isOffline = false
            }
            if isOffline { context.saveGState(); context.setAlpha(0.35) }

            // Selection background - subtle to keep accent text readable.
            // In metal mode, highlight with the green LCD display color (matching the
            // playlist's now-playing row) instead of the metal control fill.
            if isSelected {
                (isMetalRenderStyle ? metalMaterial.displayFill.withAlphaComponent(0.30) : skin.primaryColor.withAlphaComponent(0.06)).setFill()
                context.fill(itemRect)
            }

            if let row = rowColumns(for: item, header: layout.header) {
                let indent = CGFloat(item.indentLevel) * 16
                drawColumnRow(item: item, columns: row.columns, group: row.group,
                              in: context, rect: itemRect, isSelected: isSelected, skin: skin, indent: indent)
            } else {
                // Simple list rendering
                let indent = CGFloat(item.indentLevel) * 16
                let textX = itemRect.minX + indent + 4

                // Expand/collapse indicator — or an inline spinner while a YouTube channel's uploads load.
                let isLoadingChannel: Bool = {
                    if case .youtubeChannel(let channel) = item.type { return YouTubeChannelUploads.shared.isFetching(channel.id) }
                    return false
                }()
                var titleSpinnerInset: CGFloat = 0
                if isLoadingChannel {
                    let spinnerRadius = min(itemHeight * 0.3, 6)
                    drawRowSpinner(in: context, center: CGPoint(x: textX + spinnerRadius, y: itemRect.midY),
                                   radius: spinnerRadius, skin: skin)
                    titleSpinnerInset = spinnerRadius * 2 + 4
                } else if item.hasChildren {
                    let expanded = model.isExpanded(item)
                    let indicator = expanded ? "▼" : "▶"
                    let indicatorAttrs: [NSAttributedString.Key: Any] = [
                        .foregroundColor: skin.applyTextOpacity(to: skin.textDimColor),
                        .font: skin.scaledSystemFont(size: 6.4)
                    ]
                    drawText(indicator, at: NSPoint(x: textX - 12, y: itemRect.midY - 5), withAttributes: indicatorAttrs, context: context)
                }

                // Round thumbnail ahead of the title: a YouTube channel's avatar, or the item's art.
                if let thumbnail = rowThumbnailSource(for: item) {
                    titleSpinnerInset += rowThumbnails.draw(thumbnail, in: context, at: textX + titleSpinnerInset,
                                                            rowRect: itemRect, side: itemHeight - 2)
                }

                // Main text
                let textColor = isSelected ? (isMetalRenderStyle ? skin.textColor : skin.accentColor) : skin.textColor
                let attrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: skin.applyTextOpacity(to: textColor),
                    .font: font
                ]
                let textRect = NSRect(x: textX + titleSpinnerInset, y: itemRect.minY + 2,
                                     width: itemRect.width - indent - 60 - titleSpinnerInset, height: itemHeight - 4)
                drawText(item.shownTitle, in: textRect, withAttributes: attrs, context: context)

                // Secondary info
                if let info = item.info {
                    let infoColor = isSelected ? (isMetalRenderStyle ? skin.textColor : skin.accentColor) : skin.textDimColor
                    let infoAttrs: [NSAttributedString.Key: Any] = [
                        .foregroundColor: skin.applyTextOpacity(to: infoColor),
                        .font: smallFont
                    ]
                    let infoSize = info.size(withAttributes: infoAttrs)
                    let infoX = model.browseMode == .radio
                        ? (itemRect.midX - infoSize.width / 2)
                        : (itemRect.maxX - infoSize.width - 4)
                    drawText(info, at: NSPoint(x: infoX, y: itemRect.midY - infoSize.height / 2), withAttributes: infoAttrs, context: context)
                }
            }

            if isOffline { context.restoreGState() }
        }
        rowThumbnails.endPass(visible: visibleStart..<visibleEnd, count: model.displayItems.count) {
            rowThumbnailSource(for: model.displayItems[$0])
        }
        
        context.restoreGState()
        
        // Draw alphabet index (exclude column header zone so # appears below column headers)
        drawAlphabetIndex(in: context, rect: layout.alphabet, skin: skin)
    }

    private func drawArtworkBackground(in context: CGContext, listRect: NSRect, artwork: NSImage?) {
        guard showsLegacyArtwork,
              let artworkImage = artwork,
              let cgImage = artworkImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        context.saveGState()
        context.clip(to: listRect)
        let imageSize = NSSize(width: cgImage.width, height: cgImage.height)
        let artworkRect = calculateCenterFillRect(imageSize: imageSize, in: listRect)
        context.setAlpha(0.12)
        context.draw(cgImage, in: artworkRect)
        context.restoreGState()
    }
    
    // MARK: - Column Headers
    
    private func drawColumnHeaders(in context: CGContext, header: ListLayout.Header, skin: ModernSkin) {
        let rect = header.rect, columns = header.columns, group = header.group
        context.saveGState()
        context.clip(to: rect)
        
        contentFill(isMetalRenderStyle ? metalControlBandFill : skin.surfaceColor.withAlphaComponent(0.4)).setFill()
        context.fill(rect)

        let headerFont = skin.scaledSystemFont(size: 7.2, weight: .medium)
        let headerColor = skin.textDimColor.withAlphaComponent(0.7)
        let sortedHeaderColor = skin.textColor.withAlphaComponent(0.9)
        let separatorColor = skin.textDimColor.withAlphaComponent(0.2)
        
        var x = rect.minX + 4 - horizontalScrollOffset
        for (index, column) in columns.enumerated() {
            let width = widthForColumn(column, availableWidth: rect.width, columns: columns, group: group)
            let isSortColumn = model.activeColumnSortId == column.id
            let isCenteredRadioColumn = (model.browseMode == .radio && column.id == "genre") ||
                (model.hasInternetRadioColumns && column.id == "rating")
            
            let attrs: [NSAttributedString.Key: Any] = [
                .font: headerFont,
                .foregroundColor: skin.applyTextOpacity(to: isSortColumn ? sortedHeaderColor : headerColor)
            ]
            
            let textSize = column.title.size(withAttributes: attrs)
            let textY = rect.minY + (columnHeaderHeight - textSize.height) / 2
            let textX = isCenteredRadioColumn ? (x + (width - textSize.width) / 2) : (x + 4)
            drawText(column.title, at: NSPoint(x: textX, y: textY), withAttributes: attrs, context: context)
            
            if isSortColumn {
                let indicator = model.activeColumnSortAscending ? "▲" : "▼"
                let indicatorAttrs: [NSAttributedString.Key: Any] = [
                    .font: skin.scaledSystemFont(size: 5.6),
                    .foregroundColor: skin.applyTextOpacity(to: sortedHeaderColor)
                ]
                drawText(indicator, at: NSPoint(x: textX + textSize.width + 3, y: textY + 1), withAttributes: indicatorAttrs, context: context)
            }
            
            if index < columns.count - 1 {
                context.setStrokeColor(separatorColor.cgColor)
                context.setLineWidth(1)
                context.move(to: CGPoint(x: x + width - 1, y: rect.minY + 3))
                context.addLine(to: CGPoint(x: x + width - 1, y: rect.maxY - 3))
                context.strokePath()
            }
            
            x += width
        }
        
        // Bottom separator
        context.setStrokeColor(skin.textDimColor.withAlphaComponent(0.3).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: rect.minX, y: rect.minY))
        context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        context.strokePath()
        
        context.restoreGState()
    }
    
    // MARK: - Column Row Drawing
    
    private func drawColumnRow(item: LibraryBrowserItem, columns: [LibraryBrowserColumn], group: LibraryColumnVisibilityGroup?,
                               in context: CGContext, rect: NSRect, isSelected: Bool, skin: ModernSkin, indent: CGFloat = 0) {
        let totalWidth = rect.width
        let textColor = isSelected ? (isMetalRenderStyle ? skin.textColor : skin.accentColor) : skin.textColor
        let dimColor = isSelected ? (isMetalRenderStyle ? skin.textColor : skin.accentColor) : skin.textDimColor
        let font = skin.scaledSystemFont(size: 8)
        let smallFont = skin.scaledSystemFont(size: 7.2)
        
        let hasArtColumn = columns.contains { $0.id == "thumbnail" }
        let cells = LibraryColumnVisibility.cellFrames(
            widths: columns.map { widthForColumn($0, availableWidth: totalWidth, columns: columns, group: group) },
            titleIndex: columns.firstIndex { $0.id == "title" }, indent: indent,
            spansLeadingCells: model.columnGroup(for: item) != group)
        for (column, cell) in zip(columns, cells) {
            let x = rect.minX + cell.start - horizontalScrollOffset, width = cell.width
            if column.id == "thumbnail" {
                if let thumbnail = rowThumbnailSource(for: item) {
                    rowThumbnails.draw(thumbnail, in: context, at: x + 4, rowRect: rect, side: min(width - 8, rect.height - 2))
                }
                continue
            }
            let value = column.id == "title" ? item.shownTitle : item.columnValue(for: column)
            let isCenteredRadioColumn = (model.browseMode == .radio && column.id == "genre") ||
                (model.isInternetRadioItem(item) && column.id == "rating")
            
            let color = column.id == "title" ? textColor : dimColor
            let useFont = column.id == "title" ? font : smallFont

            let attrs: [NSAttributedString.Key: Any] = [
                .font: useFont,
                .foregroundColor: skin.applyTextOpacity(to: color)
            ]
            // Per-row download spinner on the title column of a downloading YouTube video.
            var titleSpinnerInset: CGFloat = 0
            if column.id == "title", case .youtubeVideo(let video) = item.type,
               youtubeVideoActions.isFetching(video.videoId) {
                let spinnerRadius = min(rect.height * 0.3, 6)
                let cx = x + 4 + spinnerRadius
                drawRowSpinner(in: context, center: CGPoint(x: cx, y: rect.midY), radius: spinnerRadius, skin: skin)
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
            let maxTextWidth = width - 8 - titleSpinnerInset

            let drawRect = NSRect(x: textX, y: textY, width: maxTextWidth, height: textSize.height)
            if column.id == "rating" && !isSelected && value.contains("★") {
                let goldColor = isMetalRenderStyle
                    ? metalRatingColor
                    : NSColor(srgbRed: 0.98, green: 0.78, blue: 0.20, alpha: 1.0)
                let emptyColor = skin.applyTextOpacity(to: dimColor).withAlphaComponent(0.4)
                let astr = NSMutableAttributedString(string: value, attributes: attrs)
                for (i, ch) in value.enumerated() {
                    let range = NSRange(location: i, length: 1)
                    astr.addAttribute(.foregroundColor, value: ch == "★" ? goldColor : emptyColor, range: range)
                }
                context.saveGState()
                context.setAlpha(1.0)
                astr.draw(with: drawRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                context.restoreGState()
            } else {
                drawText(
                    value,
                    in: drawRect,
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                    withAttributes: attrs,
                    context: context
                )
            }
        }
    }
    
    // MARK: - State Drawing Methods
    
    private func drawNotLinkedState(in context: CGContext, listRect: NSRect, skin: ModernSkin) {
        let message = "Link your Plex account to browse your music library"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: skin.applyTextOpacity(to: skin.textDimColor),
            .font: NSFont.systemFont(ofSize: 12)
        ]
        let size = message.size(withAttributes: attrs)
        drawText(message, at: NSPoint(x: listRect.midX - size.width / 2, y: listRect.midY - size.height / 2), withAttributes: attrs, context: context)
        
        let hint = "Click the server bar above to link"
        let hintColor = isMetalRenderStyle ? metalRatingColor : skin.warningColor
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: skin.applyTextOpacity(to: hintColor),
            .font: NSFont.systemFont(ofSize: 10)
        ]
        let hintSize = hint.size(withAttributes: hintAttrs)
        drawText(hint, at: NSPoint(x: listRect.midX - hintSize.width / 2, y: listRect.midY - size.height / 2 - 20), withAttributes: hintAttrs, context: context)
    }
    
    private func drawLoadingState(in context: CGContext, listRect: NSRect, skin: ModernSkin) {
        let centerY = listRect.midY
        let centerX = listRect.midX
        
        let innerRadius: CGFloat = 5
        let outerRadius: CGFloat = 12
        let numSegments = 8
        let segmentAngle = CGFloat.pi * 2 / CGFloat(numSegments)
        
        for i in 0..<numSegments {
            let angle = CGFloat(i) * segmentAngle - CGFloat.pi / 2 + CGFloat(loadingAnimationFrame) * segmentAngle
            let alpha = CGFloat(i + 1) / CGFloat(numSegments)
            
            skin.textColor.withAlphaComponent(alpha).setStroke()
            context.setLineWidth(2.5)
            
            let startX = centerX + cos(angle) * innerRadius
            let startY = centerY + sin(angle) * innerRadius
            let endX = centerX + cos(angle) * outerRadius
            let endY = centerY + sin(angle) * outerRadius
            
            context.move(to: CGPoint(x: startX, y: startY))
            context.addLine(to: CGPoint(x: endX, y: endY))
            context.strokePath()
        }
        
        startLoadingAnimation()
    }

    /// Small inline spinner used on a downloading YouTube video row.
    private func drawRowSpinner(in context: CGContext, center: CGPoint, radius: CGFloat, skin: ModernSkin) {
        let innerRadius = radius * 0.45
        let outerRadius = radius
        let numSegments = 8
        let segmentAngle = CGFloat.pi * 2 / CGFloat(numSegments)
        context.saveGState()
        for i in 0..<numSegments {
            let angle = CGFloat(i) * segmentAngle - CGFloat.pi / 2 + CGFloat(loadingAnimationFrame) * segmentAngle
            let alpha = CGFloat(i + 1) / CGFloat(numSegments)
            skin.applyTextOpacity(to: skin.textColor).withAlphaComponent(alpha).setStroke()
            context.setLineWidth(1.5)
            context.move(to: CGPoint(x: center.x + cos(angle) * innerRadius, y: center.y + sin(angle) * innerRadius))
            context.addLine(to: CGPoint(x: center.x + cos(angle) * outerRadius, y: center.y + sin(angle) * outerRadius))
            context.strokePath()
        }
        context.restoreGState()
    }

    private func drawErrorState(in context: CGContext, message: String, listRect: NSRect, skin: ModernSkin) {
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: skin.applyTextOpacity(to: skin.textDimColor),
            .font: NSFont.systemFont(ofSize: 11)
        ]
        let size = message.size(withAttributes: attrs)
        drawText(message, at: NSPoint(x: listRect.midX - size.width / 2, y: listRect.midY - size.height / 2), withAttributes: attrs, context: context)
    }
    
    private func drawEmptyState(in context: CGContext, listRect: NSRect, skin: ModernSkin) {
        let library = PlexManager.shared.currentLibrary
        let message: String
        switch model.browseMode {
        case .artists, .albums:
            if model.currentSource.isPlex && library?.isMusicLibrary == true {
                message = "No \(model.browseMode.title.lowercased()) found"
            } else if model.currentSource.isSubsonic || model.currentSource.isJellyfin || model.currentSource.isEmby || (model.currentSource.isPlex && library?.isMusicLibrary != true) {
                message = "No \(model.browseMode.title.lowercased()) found"
            } else {
                message = "No \(model.browseMode.title.lowercased()) found"
            }
        case .movies: message = "No movies found"
        case .shows: message = "No TV shows found"
        case .folders: message = "No folders found"
        case .plists: message = "No playlists found"
        case .search:
            message = model.searchQuery.isEmpty || model.hasUnsubmittedYouTubeSearch ? "Type and press ↵ to search" : "No results found"
        case .radio: message = "No radio stations found"
        case .history: message = "No play history recorded yet"
        }
        
        let font = skin.libraryFont(size: 10)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: skin.applyTextOpacity(to: skin.textDimColor)
        ]
        let textSize = message.size(withAttributes: attrs)
        let textX = listRect.midX - textSize.width / 2
        let textY = listRect.midY - textSize.height / 2
        drawText(message, at: NSPoint(x: textX, y: textY), withAttributes: attrs, context: context)
    }
    
    // MARK: - Alphabet Index
    
    private func drawAlphabetIndex(in context: CGContext, rect: NSRect, skin: ModernSkin) {
        // Metal: let the brushed-metal panel show through so the index reads as part of
        // the single continuous surface rather than a darker inset strip.
        contentFill(isMetalRenderStyle ? NSColor.clear : skin.surfaceColor.withAlphaComponent(0.3)).setFill()
        context.fill(rect)
        
        let letterCount = CGFloat(alphabetLetters.count)
        let letterHeight = rect.height / letterCount
        let fontSize = min(9 * ModernSkinElements.sizeMultiplier, letterHeight * 0.8)
        
        var availableLetters = Set<String>()
        if case .local = model.currentSource, model.browseMode == .artists {
            availableLetters = Set(model.localArtistLetterOffsets.keys)
        } else if case .local = model.currentSource, model.browseMode == .albums {
            availableLetters = Set(model.localAlbumLetterOffsets.keys)
        } else {
            for item in model.displayItems {
                availableLetters.insert(LibraryBrowserModel.effectiveSortLetter(for: item))
            }
        }

        for (index, letter) in alphabetLetters.enumerated() {
            // Bottom-left origin: # at top, Z at bottom
            let y = rect.maxY - CGFloat(index + 1) * letterHeight
            let letterRect = NSRect(x: rect.minX, y: y, width: rect.width, height: letterHeight)
            
            let hasItems = availableLetters.contains(letter)
            let color = hasItems ? (isMetalRenderStyle ? skin.textColor : skin.accentColor) : skin.textDimColor.withAlphaComponent(0.3)
            
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: skin.applyTextOpacity(to: color),
                .font: NSFont.boldSystemFont(ofSize: fontSize)
            ]
            let letterSize = letter.size(withAttributes: attrs)
            let drawPoint = NSPoint(
                x: letterRect.midX - letterSize.width / 2,
                y: letterRect.midY - letterSize.height / 2
            )
            drawText(letter, at: drawPoint, withAttributes: attrs, context: context)
        }
    }
    
    private func drawStatusBarText(in context: CGContext, skin: ModernSkin) {
        // Status info shown in server bar; this is kept for future use
    }
    
    // MARK: - List Layout

    /// Where the list sits, worked out in one place. Drawing, every hit test and every scroll
    /// range read it, so a click lands on the row drawn under it (PR #480: hit tests reserved the
    /// header on a different condition than drawing, and every click landed one row up).
    private struct ListLayout {
        /// Below the tab bar (and search bar), above the offline banner, the window's full inner
        /// width. Loading, error and art views fill it.
        let area: NSRect
        /// The column header band and the columns it shows, when the list has columns.
        let header: Header?
        /// Where rows are drawn: under the header, left of the scrollbar and alphabet index.
        let rows: NSRect
        /// The alphabet index, beside the rows.
        let alphabet: NSRect
        /// The offline-volume banner under `area`, when a local watch folder is offline.
        let banner: NSRect?

        struct Header {
            let rect: NSRect
            let columns: [LibraryBrowserColumn]
            /// The group the columns' widths are keyed by; nil for radio's fixed columns.
            let group: LibraryColumnVisibilityGroup?
        }
    }

    /// The bottom of the tab bar, or of the search bar in search mode.
    private var listTopY: CGFloat {
        topChromeBottomY - Layout.serverBarHeight - Layout.tabBarHeight
            - (model.browseMode == .search ? Layout.searchBarHeight : 0)
    }

    private func listLayout() -> ListLayout {
        let showsBanner = model.isLocalSource && !model.offlineWatchFolders.isEmpty
        let bottomY = contentRegionBottomY + (showsBanner ? Layout.offlineBannerHeight : 0)
        let area = NSRect(x: Layout.borderWidth, y: bottomY,
                          width: bounds.width - Layout.borderWidth * 2, height: listTopY - bottomY)
        // Flow / Tiles draw no column header, so the alphabet index beside them runs full height.
        let group = model.currentColumnGroup()
        let columns = artLens.isPresenting ? [] : model.headerColumns(for: group)
        let headerHeight = columns.isEmpty ? 0 : columnHeaderHeight
        let rows = NSRect(x: area.minX, y: area.minY,
                          width: area.width - Layout.scrollbarWidth - Layout.alphabetWidth,
                          height: area.height - headerHeight)
        return ListLayout(
            area: area,
            header: columns.isEmpty ? nil : .init(rect: NSRect(x: rows.minX, y: rows.maxY, width: rows.width, height: headerHeight),
                                                  columns: columns, group: group),
            rows: rows,
            alphabet: NSRect(x: rows.maxX, y: rows.minY, width: Layout.alphabetWidth, height: rows.height),
            banner: showsBanner ? NSRect(x: area.minX, y: contentRegionBottomY, width: area.width, height: Layout.offlineBannerHeight) : nil
        )
    }

    // MARK: - Column Support

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
            // If a stored width exists for the title column (set when user resizes any column), use it
            if let storedWidth = storedColumnWidth(for: column, group: group) {
                return max(column.minWidth, storedWidth)
            }
            // Otherwise, title is flexible and fills remaining space
            let fixedWidth = columns.filter { $0.id != "title" }.reduce(0) {
                $0 + (storedColumnWidth(for: $1, group: group) ?? $1.minWidth)
            }
            return max(column.minWidth, availableWidth - fixedWidth - 8)
        }
        return storedColumnWidth(for: column, group: group) ?? column.minWidth
    }
    
    private func totalColumnsWidth(
        columns: [LibraryBrowserColumn],
        availableWidth: CGFloat,
        group: LibraryColumnVisibilityGroup?
    ) -> CGFloat {
        8 + columns.reduce(0) { total, column in
            total + widthForColumn(column, availableWidth: availableWidth, columns: columns, group: group)
        }
    }

    private func clampHorizontalScrollOffset() {
        guard let header = listLayout().header else { horizontalScrollOffset = 0; return }
        let availableWidth = header.rect.width
        let maxOffset = max(0, totalColumnsWidth(columns: header.columns, availableWidth: availableWidth, group: header.group) - availableWidth)
        horizontalScrollOffset = max(0, min(horizontalScrollOffset, maxOffset))
    }
    
    private func saveColumnWidths() {
        UserDefaults.standard.set(columnWidths, forKey: "BrowserColumnWidths")
    }
    
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
    
    // MARK: - Utility
    
    private func calculateCenterFillRect(imageSize: NSSize, in targetRect: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return targetRect }
        let imageAspect = imageSize.width / imageSize.height
        let targetAspect = targetRect.width / targetRect.height
        var width: CGFloat
        var height: CGFloat
        if imageAspect > targetAspect {
            width = targetRect.width
            height = width / imageAspect
        } else {
            height = targetRect.height
            width = height * imageAspect
        }
        let x = targetRect.minX + (targetRect.width - width) / 2
        let y = targetRect.minY + (targetRect.height - height) / 2
        return NSRect(x: x, y: y, width: width, height: height)
    }
    
    // MARK: - Hit Testing (Bottom-Left Origin)
    
    private func hitTestTitleBar(at point: NSPoint) -> Bool {
        let m = ModernSkinElements.sizeMultiplier
        return point.y > bounds.height - Layout.titleBarHeight &&
               point.x < bounds.width - 30 * m
    }
    
    private func hitTestCloseButton(at point: NSPoint) -> Bool {
        let m = ModernSkinElements.sizeMultiplier
        let closeRect = NSRect(x: bounds.width - 20 * m, y: bounds.height - Layout.titleBarHeight, width: 20 * m, height: Layout.titleBarHeight)
        return closeRect.contains(point)
    }
    
    private func hitTestServerBar(at point: NSPoint) -> Bool {
        let serverBarY = topChromeBottomY - Layout.serverBarHeight
        return point.y >= serverBarY && point.y < topChromeBottomY
    }
    
    private func hitTestTabBar(at point: NSPoint) -> LibraryBrowseMode? {
        let tabBarTopY = topChromeBottomY - Layout.serverBarHeight
        let tabBarBottomY = tabBarTopY - Layout.tabBarHeight
        guard point.y >= tabBarBottomY && point.y < tabBarTopY else { return nil }

        for (index, rect) in tabButtonRects.enumerated()
        where rect.contains(point) && index < LibraryBrowseMode.tabs.count {
            return LibraryBrowseMode.tabs[index]
        }
        return nil
    }
    
    private func hitTestSortIndicator(at point: NSPoint) -> Bool {
        let tabBarTopY = topChromeBottomY - Layout.serverBarHeight
        let tabBarBottomY = tabBarTopY - Layout.tabBarHeight
        guard point.y >= tabBarBottomY && point.y < tabBarTopY else { return false }
        return sortButtonRect.contains(point)
    }
    
    private func hitTestSearchBar(at point: NSPoint) -> Bool {
        guard model.browseMode == .search else { return false }
        return point.y >= listTopY && point.y < listTopY + Layout.searchBarHeight
    }
    
    private func hitTestListArea(at point: NSPoint) -> Int? {
        let rows = listLayout().rows
        guard rows.contains(point) else { return nil }
        
        // In bottom-left origin, items are rendered from top down
        let clickedIndex = Int((rows.maxY - point.y + scrollOffset) / itemHeight)
        return model.displayItems.indices.contains(clickedIndex) ? clickedIndex : nil
    }

    private func hitTestInternetRadioRating(at point: NSPoint, itemIndex: Int) -> Int? {
        guard model.hasInternetRadioColumns, itemIndex >= 0, itemIndex < model.displayItems.count else { return nil }
        let item = model.displayItems[itemIndex]
        let layout = listLayout()
        guard case .radioStation = item.type, let row = rowColumns(for: item, header: layout.header) else { return nil }

        let listRect = layout.rows
        let itemTopY = listRect.maxY - CGFloat(itemIndex) * itemHeight + scrollOffset
        let rowRect = NSRect(x: listRect.minX, y: itemTopY - itemHeight, width: listRect.width, height: itemHeight)
        guard rowRect.contains(point) else { return nil }

        var x = rowRect.minX + 4 - horizontalScrollOffset
        for column in row.columns {
            let width = widthForColumn(column, availableWidth: rowRect.width, columns: row.columns, group: row.group)
            if column.id == "rating" {
                let cellRect = NSRect(x: x, y: rowRect.minY, width: width, height: rowRect.height)
                guard cellRect.contains(point) else { return nil }
                let innerWidth = max(1, cellRect.width - 8)
                let clampedX = min(max(point.x, cellRect.minX + 4), cellRect.maxX - 4)
                let normalized = (clampedX - (cellRect.minX + 4)) / innerWidth
                let star = min(5, max(1, Int(normalized * 5.0) + 1))
                return star
            }
            x += width
        }
        return nil
    }

    private func hitTestAlphabetIndex(at point: NSPoint) -> Bool {
        return listLayout().alphabet.contains(point)
    }
    
    /// The column header when `point` is in its band, at any x — so a right-click above the
    /// alphabet index still opens the column menu.
    private func columnHeader(at point: NSPoint) -> ListLayout.Header? {
        guard let header = listLayout().header, point.y >= header.rect.minY, point.y < header.rect.maxY else { return nil }
        return header
    }
    
    private func hitTestColumnResize(at point: NSPoint) -> String? {
        if model.hasInternetRadioColumns { return nil }
        guard let header = columnHeader(at: point), header.columns.count > 1 else { return nil }
        let columns = header.columns
        let group = header.group
        
        let threshold: CGFloat = 4 * ModernSkinElements.sizeMultiplier
        var x = header.rect.minX + 4 - horizontalScrollOffset
        
        for (index, column) in columns.enumerated() {
            let width = widthForColumn(column, availableWidth: header.rect.width, columns: columns, group: group)
            let edgeX = x + width
            
            // Allow resizing any non-last column by dragging its right edge
            if index < columns.count - 1 {
                if abs(point.x - edgeX) < threshold {
                    return column.id
                }
            }
            // Allow resizing column to the left of title (drag left edge of title = resize previous column)
            if index > 0 && column.id == "title" {
                if abs(point.x - x) < threshold {
                    return columns[index - 1].id
                }
            }
            x += width
        }
        return nil
    }
    
    private func hitTestColumnHeader(at point: NSPoint) -> String? {
        guard let header = columnHeader(at: point) else { return nil }
        let columns = header.columns
        let group = header.group
        
        var x = header.rect.minX + 4 - horizontalScrollOffset
        for column in columns {
            let width = widthForColumn(column, availableWidth: header.rect.width, columns: columns, group: group)
            if point.x >= x && point.x < x + width { return column.id }
            x += width
        }
        return nil
    }
    
    // MARK: - Mouse Events
    
    override var acceptsFirstResponder: Bool { true }
    
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    
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
    
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // When HT is on, record drag start point early so mouseDragged can move the window
        // from anywhere (title bar is hidden so there's no dedicated drag handle)
        if WindowManager.shared.hideTitleBars {
            windowDragStartPoint = event.locationInWindow
            if let window = window {
                WindowManager.shared.windowWillPrimeDragging(window)
                didPrimeWindowDragHold = true
            }
        }

        // Window buttons (only when titlebar is visible)
        if !WindowManager.shared.hideTitleBars {
            if hitTestCloseButton(at: point) { pressedButton = .close; needsDisplay = true; return }
        }

        // Library | Playlist toggle footer (compact window only). The footer band sits below
        // the content region, outside the embedded queue subview's frame, so its clicks
        // always reach the parent regardless of z-order.
        if compactMode, compactFooterHeight > 0 {
            let segments = compactToggleSegmentRects()
            if segments.library.contains(point) {
                if compactContentMode != .library { compactContentMode = .library }
                return
            }
            if segments.queue.contains(point) {
                if compactContentMode != .queue { compactContentMode = .queue }
                return
            }
        }

        // Server bar (check before content area so ART/VIS/source buttons work)
        if hitTestServerBar(at: point) {
            if case .plex = model.currentSource, !PlexManager.shared.isLinked {
                controller?.showLinkSheet()
            } else {
                handleServerBarClick(at: point, event: event)
            }
            return
        }
        
        // Sort indicator
        if hitTestSortIndicator(at: point) { showSortMenu(at: event.locationInWindow); return }
        
        // Tab bar
        if let slot = hitTestTabBar(at: point) {
            model.selectTab(slot, doubleClick: event.clickCount == 2)
            window?.makeFirstResponder(self)
            return
        }
        
        // Search bar
        if hitTestSearchBar(at: point) { window?.makeFirstResponder(self); return }
        
        // Column resize (check before sort so edge-drag doesn't trigger sort)
        if let header = columnHeader(at: point), let columnId = hitTestColumnResize(at: point) {
            resizingColumnId = columnId
            resizingColumnGroup = header.group
            resizeStartX = point.x
            let columns = header.columns
            let group = resizingColumnGroup
            let headerWidth = header.rect.width
            resizeStartWidth = widthForColumn(LibraryBrowserColumn.findColumn(id: columnId)!, availableWidth: headerWidth, columns: columns, group: group)
            // Freeze the title column's current width so it doesn't flex during resize
            if let group, storedColumnWidth(for: .title, group: group) == nil {
                let titleWidth = widthForColumn(.title, availableWidth: headerWidth, columns: columns, group: group)
                setColumnWidth(titleWidth, for: "title", group: group)
            }
            NSCursor.resizeLeftRight.push()
            return
        }
        
        // Column header click for sorting
        if let columnId = hitTestColumnHeader(at: point) {
            model.sortByColumn(columnId)
            needsDisplay = true
            return
        }
        
        // Alphabet index
        if hitTestAlphabetIndex(at: point) { handleAlphabetClick(at: point); return }
        
        // List area
        if let itemIndex = hitTestListArea(at: point) {
            handleListClick(at: itemIndex, event: event, point: point); return
        }
        
        // Title bar drag
        if hitTestTitleBar(at: point) {
            isDraggingWindow = true; windowDragStartPoint = event.locationInWindow
            if let window = window { WindowManager.shared.windowWillStartDragging(window, fromTitleBar: true) }
        }
    }
    
    override func mouseDragged(with event: NSEvent) {
        if let columnId = resizingColumnId, let group = resizingColumnGroup {
            let point = convert(event.locationInWindow, from: nil)
            let deltaX = point.x - resizeStartX
            let minWidth = LibraryBrowserColumn.findColumn(id: columnId)?.minWidth ?? 30
            setColumnWidth(max(minWidth, resizeStartWidth + deltaX), for: columnId, group: group)
            needsDisplay = true; return
        }

        // When HT is on, lazily start window drag on first mouseDragged (handles content-area drags)
        if !isDraggingWindow && WindowManager.shared.hideTitleBars {
            isDraggingWindow = true
            if let window = window { WindowManager.shared.windowWillStartDragging(window, fromTitleBar: true) }
        }

        if isDraggingWindow, let window = window {
            let currentPoint = event.locationInWindow
            let deltaX = currentPoint.x - windowDragStartPoint.x
            let deltaY = currentPoint.y - windowDragStartPoint.y
            var newOrigin = window.frame.origin
            newOrigin.x += deltaX; newOrigin.y += deltaY
            newOrigin = WindowManager.shared.windowWillMove(window, to: newOrigin)
            window.setFrameOrigin(newOrigin)
        }
    }
    
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        
        if resizingColumnId != nil { resizingColumnId = nil; resizingColumnGroup = nil; NSCursor.pop() }
        if isDraggingWindow {
            isDraggingWindow = false
            if let window = window { WindowManager.shared.windowDidFinishDragging(window) }
            didPrimeWindowDragHold = false
        } else if didPrimeWindowDragHold {
            if let window = window { WindowManager.shared.windowDidCancelDragPrime(window) }
            didPrimeWindowDragHold = false
        }

        if let pressed = pressedButton {
            switch pressed {
            case .close: if hitTestCloseButton(at: point) { window?.close() }
            }
            pressedButton = nil; needsDisplay = true
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if hitTestColumnResize(at: point) != nil {
            NSCursor.resizeLeftRight.set()
        } else if hitTestAlphabetIndex(at: point) {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
        let overList = hitTestListArea(at: point) != nil
        rowThumbnails.hover(at: overList ? point : nil) { window?.convertToScreen(convert($0, to: nil)) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        RowThumbnailPreview.shared.hide()
    }
    
    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        
        // Right-click on column header: show column visibility menu
        if columnHeader(at: point) != nil {
            showColumnConfigMenu(at: event); return
        }
        
        if let clickedIndex = hitTestListArea(at: point) {
            if !selectedIndices.contains(clickedIndex) { selectedIndices = [clickedIndex]; needsDisplay = true }
            let item = model.displayItems[clickedIndex]
            showContextMenu(for: item, at: event); return
        }
        if case .local = model.currentSource {
            let menu = NSMenu()
            let manageFoldersItem = NSMenuItem(title: "Manage Folders...", action: #selector(manageWatchFolders), keyEquivalent: "")
            manageFoldersItem.target = self; menu.addItem(manageFoldersItem)
            prependBackdropMenu(to: menu)
            NSMenu.popUpContextMenu(menu, with: event, for: self); return
        }
        if backdropMenuIsAvailable {
            let menu = NSMenu()
            prependBackdropMenu(to: menu)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        super.rightMouseDown(with: event)
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
        // The list with its header and the offline banner: a horizontal scroll moves the header too.
        let dirtyRect = layout.banner.map { layout.area.union($0) } ?? layout.area

        if totalHeight > listHeight && verticalDelta != 0 {
            scrollOffset = max(0, min(totalHeight - listHeight, scrollOffset - verticalDelta))
            setNeedsDisplay(dirtyRect)
        }

        let horizontalDelta = horizontalScrollDelta(from: event)
        if horizontalDelta != 0, let header = layout.header {
            let availableWidth = header.rect.width
            let totalWidth = totalColumnsWidth(columns: header.columns, availableWidth: availableWidth, group: header.group)
            let maxOffset = max(0, totalWidth - availableWidth)
            if maxOffset > 0 {
                horizontalScrollOffset = max(0, min(maxOffset, horizontalScrollOffset - horizontalDelta))
                setNeedsDisplay(dirtyRect)
            }
        }

        // Trigger next-page load when scrolled near the bottom of a local paginated list
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

    private func loadNextLocalPageIfNeeded(listHeight: CGFloat) {
        let threshold = itemHeight * 10   // start loading 10 rows from bottom
        let loadedHeight = CGFloat(model.displayItems.count) * itemHeight
        guard scrollOffset + listHeight + threshold >= loadedHeight else { return }
        model.appendNextLocalPage()
    }

    // MARK: - Keyboard Events
    
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36: // Enter
            if model.browseMode == .search && !model.searchQuery.isEmpty && (!model.isYouTubeChannelSearch || model.hasUnsubmittedYouTubeSearch) {
                model.loadDataForCurrentMode()
            } else if event.modifierFlags.contains(.shift) {
                runVerbOnSelection(.playNext)
            } else if event.modifierFlags.contains(.option) {
                runVerbOnSelection(.addToQueue)
            } else {
                if let index = selectedIndices.first, index < model.displayItems.count { handleDoubleClick(on: model.displayItems[index]) }
            }
        case 124: // Right Arrow — expand or move into first child
            if let index = selectedIndices.first, index < model.displayItems.count {
                let item = model.displayItems[index]
                if item.hasChildren {
                    if model.isExpanded(item) {
                        // Move to first child
                        let nextIdx = index + 1
                        if nextIdx < model.displayItems.count {
                            selectedIndices = [nextIdx]; ensureVisible(index: nextIdx); loadArtworkForSelection(); needsDisplay = true
                        }
                    } else {
                        model.toggleExpand(item); needsDisplay = true
                    }
                }
            }
        case 123: // Left Arrow — collapse or jump to parent
            if let index = selectedIndices.first, index < model.displayItems.count {
                let item = model.displayItems[index]
                if model.isExpanded(item) {
                    model.toggleExpand(item); needsDisplay = true
                } else if item.indentLevel > 0 {
                    // Scan backward for parent (first item with indentLevel == current - 1, skipping .header)
                    let parentLevel = item.indentLevel - 1
                    var parentIdx: Int? = nil
                    for i in stride(from: index - 1, through: 0, by: -1) {
                        let candidate = model.displayItems[i]
                        if case .header = candidate.type { continue }
                        if candidate.indentLevel == parentLevel { parentIdx = i; break }
                    }
                    if let p = parentIdx {
                        selectedIndices = [p]; ensureVisible(index: p); loadArtworkForSelection(); needsDisplay = true
                    }
                }
            }
        case 48: // Tab — cycle browse tabs
            let allModes = LibraryBrowseMode.tabs
            // Treat .folders as .plists for tab cycling (they occupy the same slot)
            let effectiveMode = model.browseMode == .folders ? .plists : model.browseMode
            if let currentIdx = allModes.firstIndex(of: effectiveMode) {
                let shift = event.modifierFlags.contains(.shift)
                let nextIdx = shift
                    ? (currentIdx - 1 + allModes.count) % allModes.count
                    : (currentIdx + 1) % allModes.count
                let nextMode = allModes[nextIdx]
                model.browseMode = nextMode == .plists ? model.effectivePlistsSlotMode : nextMode
                selectedIndices.removeAll(); scrollOffset = 0
                model.loadDataForCurrentMode()
            }
        case 49: // Space — search input when searching, otherwise play/pause
            if model.browseMode == .search {
                if let chars = event.characters, !chars.isEmpty {
                    model.searchQuery += chars; needsDisplay = true
                }
            } else if WindowManager.shared.isVideoActivePlayback {
                WindowManager.shared.toggleVideoPlayPause()
            } else if WindowManager.shared.audioEngine.state == .playing {
                WindowManager.shared.audioEngine.pause()
            } else {
                WindowManager.shared.audioEngine.play()
            }
        case 125: // Down
            if let maxIndex = selectedIndices.max(), maxIndex < model.displayItems.count - 1 {
                selectedIndices = [maxIndex + 1]; ensureVisible(index: maxIndex + 1); loadArtworkForSelection(); needsDisplay = true
            }
        case 126: // Up
            if let minIndex = selectedIndices.min(), minIndex > 0 {
                selectedIndices = [minIndex - 1]; ensureVisible(index: minIndex - 1); loadArtworkForSelection(); needsDisplay = true
            }
        default:
            if model.browseMode == .search, let chars = event.characters, !chars.isEmpty {
                if event.keyCode == 51 {
                    if !model.searchQuery.isEmpty { model.searchQuery.removeLast(); needsDisplay = true }
                } else if chars.rangeOfCharacter(from: .alphanumerics) != nil ||
                          chars.rangeOfCharacter(from: .whitespaces) != nil {
                    model.searchQuery += chars; needsDisplay = true
                }
            } else if model.browseMode != .search, let chars = event.characters, !chars.isEmpty {
                if event.keyCode == 53 { // Escape — clear type-ahead
                    typeAheadQuery = ""; typeAheadTimer?.invalidate(); typeAheadTimer = nil; needsDisplay = true
                } else if event.keyCode == 51 { // Backspace
                    if !typeAheadQuery.isEmpty {
                        typeAheadQuery.removeLast()
                        jumpToTypeAhead()
                    }
                } else if chars.rangeOfCharacter(from: .alphanumerics) != nil ||
                          chars.rangeOfCharacter(from: .whitespaces) != nil {
                    typeAheadQuery += chars
                    jumpToTypeAhead()
                }
            }
        }
    }
    
    private func ensureVisible(index: Int) {
        let effectiveHeight = listLayout().rows.height

        let itemTop = CGFloat(index) * itemHeight
        let itemBottom = itemTop + itemHeight

        if itemTop < scrollOffset { scrollOffset = itemTop }
        else if itemBottom > scrollOffset + effectiveHeight { scrollOffset = itemBottom - effectiveHeight }
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

    // MARK: - Drag and Drop
    
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else { return [] }
        return LocalFileDiscovery.hasSupportedDropContent(items, includeVideo: true, includePlaylists: true) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else { return false }
        var audioURLs: [URL] = []
        var videoURLs: [URL] = []
        var processedDirectories = false
        for url in items {
            if LocalFileDiscovery.isDirectory(url) {
                MediaLibrary.shared.addWatchFolder(url)
                MediaLibrary.shared.scanFolder(url)
                processedDirectories = true
            } else if LocalFileDiscovery.isSupportedAudioFile(url) {
                audioURLs.append(url)
            } else if LocalFileDiscovery.isSupportedVideoFile(url) {
                videoURLs.append(url)
            }
        }
        if !audioURLs.isEmpty {
            MediaLibrary.shared.addTracks(urls: audioURLs)
            if case .plex = model.currentSource { model.currentSource = .local }
        }
        if !videoURLs.isEmpty {
            MediaLibrary.shared.addVideoFiles(urls: videoURLs)
            revealLocalVideoCategory()
        }
        return !audioURLs.isEmpty || !videoURLs.isEmpty || processedDirectories
    }
    
    // MARK: - Server Bar Click Handling
    
    private func handleServerBarClick(at point: NSPoint, event: NSEvent) {
        if refreshButtonRect.contains(point) {
            handleRefreshClick()
            return
        }
        if let hit = viewModeButtonRects.first(where: { $0.rect.contains(point) }) {
            artLens.mode = hit.mode
            needsDisplay = true
            return
        }

        switch model.currentSource {
        case .local:
            if addButtonRect.contains(point) { showAddFilesMenu(at: event) }
            else if sourceButtonRect.contains(point) { showSourceMenu(at: event) }
        case .plex:
            if libraryButtonRect.contains(point) { showLibraryMenu(at: event) }
            else if sourceButtonRect.contains(point) { showSourceMenu(at: event) }
        case .subsonic:
            if libraryButtonRect.contains(point) { showSubsonicFolderMenu(at: event) }
            else if sourceButtonRect.contains(point) { showSourceMenu(at: event) }
        case .jellyfin:
            if libraryButtonRect.contains(point) {
                if model.browseMode.isVideoMode { showJellyfinVideoLibraryMenu(at: event) }
                else { showJellyfinLibraryMenu(at: event) }
            } else if sourceButtonRect.contains(point) { showSourceMenu(at: event) }
        case .emby:
            if libraryButtonRect.contains(point) {
                if model.browseMode.isVideoMode { showEmbyVideoLibraryMenu(at: event) }
                else { showEmbyLibraryMenu(at: event) }
            } else if sourceButtonRect.contains(point) { showSourceMenu(at: event) }
        case .radio:
            if addButtonRect.contains(point) { showRadioAddMenu(at: event) }
            else if sourceButtonRect.contains(point) { showSourceMenu(at: event) }
        case .youtube:
            if addButtonRect.contains(point) { showYouTubeAddMenu(at: event) }
            else if sourceButtonRect.contains(point) { showSourceMenu(at: event) }
        }
    }

    private func handleRefreshClick() {
        if model.browseMode.isHistoryMode {
            historyAgent.scheduleRefresh()
            return
        }
        model.refreshCurrentSource()
    }
    
    // MARK: - Alphabet Click
    
    private func handleAlphabetClick(at point: NSPoint) {
        let rect = listLayout().alphabet
        let letterCount = CGFloat(alphabetLetters.count)
        let letterHeight = rect.height / letterCount
        guard letterHeight > 0 else { return }

        // Screen coords: maxY is the top of the strip (# at top, Z at bottom).
        let relativeFromTop = rect.maxY - point.y
        let letterIndex = Int(relativeFromTop / letterHeight)

        guard letterIndex >= 0 && letterIndex < alphabetLetters.count else { return }
        scrollToLetter(alphabetLetters[letterIndex])
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
                let effectiveHeight = listLayout().rows.height
                let maxScroll = max(0, CGFloat(model.displayItems.count) * itemHeight - effectiveHeight)
                scrollOffset = min(maxScroll, CGFloat(index) * itemHeight)
                selectedIndices = [index]; needsDisplay = true; return
            }
        }
    }
    
    // MARK: - List Click
    
    private func handleListClick(at index: Int, event: NSEvent, point: NSPoint) {
        let item = model.displayItems[index]

        // In search mode, clicking an artist navigates to the Artists tab
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
            default: break
            }
        }

        if case .radioFolder(let folder) = item.type {
            let indent = CGFloat(item.indentLevel) * 16
            let inExpandZone = point.x < Layout.borderWidth + indent + 20

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

        if let clickedStar = hitTestInternetRadioRating(at: point, itemIndex: index),
           case .radioStation(let station) = item.type {
            let currentRating = RadioManager.shared.rating(for: station)
            let targetRating = currentRating == clickedStar ? 0 : clickedStar
            RadioManager.shared.setRating(targetRating, for: station)
            selectedIndices = [index]
            needsDisplay = true
            return
        }

        if item.hasChildren {
            let indent = CGFloat(item.indentLevel) * 16
            let inExpandZone = point.x < Layout.borderWidth + indent + 20
            if item.type.isAlbumItem {
                if event.clickCount == 1 { model.toggleExpand(item) }
                // Fall through to selection
            } else if inExpandZone {
                model.toggleExpand(item); return
            }
        }

        if event.modifierFlags.contains(.shift) {
            if let lastSelected = selectedIndices.max() {
                for i in min(lastSelected, index)...max(lastSelected, index) { selectedIndices.insert(i) }
            } else { selectedIndices.insert(index) }
        } else if event.modifierFlags.contains(.command) {
            if selectedIndices.contains(index) { selectedIndices.remove(index) }
            else { selectedIndices.insert(index) }
        } else {
            selectedIndices = [index]
            if model.browseMode == .search,
               case .radioStation(let station) = item.type,
               event.clickCount == 1 {
                playRadioStation(station)
            } else {
                loadArtworkForSelection()
            }
        }
        
        if event.clickCount == 2 { handleDoubleClick(on: item) }
        needsDisplay = true
    }
    
    // MARK: - Menus
    
    private func showSourceMenu(at event: NSEvent) {
        let menu = NSMenu()
        let localItem = NSMenuItem(title: "Local Files", action: #selector(selectLocalSource), keyEquivalent: "")
        localItem.target = self; if case .local = model.currentSource { localItem.state = .on }
        menu.addItem(localItem)
        menu.addItem(NSMenuItem.separator())
        let radioItem = NSMenuItem(title: "Internet Radio", action: #selector(selectRadioSource), keyEquivalent: "")
        radioItem.target = self; if case .radio = model.currentSource { radioItem.state = .on }
        menu.addItem(radioItem)
        menu.addItem(NSMenuItem.separator())
        let youtubeItem = NSMenuItem(title: "YouTube", action: #selector(selectYouTubeSource), keyEquivalent: "")
        youtubeItem.target = self; if case .youtube = model.currentSource { youtubeItem.state = .on }
        menu.addItem(youtubeItem)

        menu.addItem(NSMenuItem.separator())
        for server in PlexManager.shared.servers {
            let item = NSMenuItem(title: server.name, action: #selector(selectPlexServer(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = server.id
            if case .plex(let id) = model.currentSource, id == server.id { item.state = .on }
            menu.addItem(item)
        }
        if PlexManager.shared.servers.isEmpty && !PlexManager.shared.isLinked {
            let linkItem = NSMenuItem(title: "Link Plex Account...", action: #selector(linkPlexAccount), keyEquivalent: "")
            linkItem.target = self; menu.addItem(linkItem)
        }
        if !SubsonicManager.shared.servers.isEmpty {
            menu.addItem(NSMenuItem.separator())
            for server in SubsonicManager.shared.servers {
                let item = NSMenuItem(title: "🎵 \(server.name)", action: #selector(selectSubsonicServer(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = server.id
                if case .subsonic(let id) = model.currentSource, id == server.id { item.state = .on }
                menu.addItem(item)
            }
        }
        if !JellyfinManager.shared.servers.isEmpty {
            menu.addItem(NSMenuItem.separator())
            for server in JellyfinManager.shared.servers {
                let item = NSMenuItem(title: "🟣 \(server.name)", action: #selector(selectJellyfinServer(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = server.id
                if case .jellyfin(let id) = model.currentSource, id == server.id { item.state = .on }
                menu.addItem(item)
            }
        }
        if !EmbyManager.shared.servers.isEmpty {
            menu.addItem(NSMenuItem.separator())
            for server in EmbyManager.shared.servers {
                let item = NSMenuItem(title: "🔵 \(server.name)", action: #selector(selectEmbyServer(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = server.id
                if case .emby(let id) = model.currentSource, id == server.id { item.state = .on }
                menu.addItem(item)
            }
        }
        let menuLocation = NSPoint(x: event.locationInWindow.x, y: event.locationInWindow.y - 5)
        menu.popUp(positioning: nil, at: menuLocation, in: window?.contentView)
    }
    
    private func showLibraryMenu(at event: NSEvent) {
        let menu = NSMenu()
        let libraries = PlexManager.shared.availableLibraries
        let currentLibraryId = PlexManager.shared.currentLibrary?.id
        for library in libraries {
            let typeLabel: String
            if library.isMusicLibrary { typeLabel = "Music" }
            else if library.isMovieLibrary { typeLabel = "Movies" }
            else if library.isShowLibrary { typeLabel = "TV Shows" }
            else { typeLabel = library.type }
            let item = NSMenuItem(title: "\(library.title) (\(typeLabel))", action: #selector(selectLibrary(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = library
            item.state = library.id == currentLibraryId ? .on : .off
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    
    private func showJellyfinLibraryMenu(at event: NSEvent) {
        let menu = NSMenu()
        let libraries = JellyfinManager.shared.musicLibraries
        let currentId = JellyfinManager.shared.currentMusicLibrary?.id
        let allItem = NSMenuItem(title: "All Libraries", action: #selector(selectJellyfinMusicLibrary(_:)), keyEquivalent: "")
        allItem.target = self; allItem.representedObject = Optional<JellyfinMusicLibrary>.none as Any
        allItem.state = currentId == nil ? .on : .off
        menu.addItem(allItem)
        if !libraries.isEmpty { menu.addItem(NSMenuItem.separator()) }
        for library in libraries {
            let item = NSMenuItem(title: "\(library.name) (Music)", action: #selector(selectJellyfinMusicLibrary(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = library
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
        allItem.target = self; allItem.representedObject = Optional<JellyfinMusicLibrary>.none as Any
        allItem.state = activeId == nil ? .on : .off
        menu.addItem(allItem)
        if !libraries.isEmpty { menu.addItem(NSMenuItem.separator()) }
        for library in libraries {
            let typeLabel = library.collectionType == "tvshows" ? "TV Shows" : "Movies"
            let item = NSMenuItem(title: "\(library.name) (\(typeLabel))", action: #selector(selectJellyfinVideoLibraryFromBrowser(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = library
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
        allItem.target = self; allItem.representedObject = Optional<EmbyMusicLibrary>.none as Any
        allItem.state = currentId == nil ? .on : .off
        menu.addItem(allItem)
        if !libraries.isEmpty { menu.addItem(NSMenuItem.separator()) }
        for library in libraries {
            let item = NSMenuItem(title: "\(library.name) (Music)", action: #selector(selectEmbyMusicLibraryFromBrowser(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = library
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
        allItem.target = self; allItem.representedObject = Optional<EmbyMusicLibrary>.none as Any
        allItem.state = activeId == nil ? .on : .off
        menu.addItem(allItem)
        if !libraries.isEmpty { menu.addItem(NSMenuItem.separator()) }
        for library in libraries {
            let typeLabel = library.collectionType == "tvshows" ? "TV Shows" : "Movies"
            let item = NSMenuItem(title: "\(library.name) (\(typeLabel))", action: #selector(selectEmbyVideoLibraryFromBrowser(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = library
            item.state = library.id == activeId ? .on : .off
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func showSubsonicFolderMenu(at event: NSEvent) {
        let menu = NSMenu()
        let folders = SubsonicManager.shared.musicFolders
        let currentId = SubsonicManager.shared.currentMusicFolder?.id
        let allItem = NSMenuItem(title: "All Folders", action: #selector(selectSubsonicMusicFolder(_:)), keyEquivalent: "")
        allItem.target = self; allItem.representedObject = Optional<SubsonicMusicFolder>.none as Any
        allItem.state = currentId == nil ? .on : .off
        menu.addItem(allItem)
        if !folders.isEmpty { menu.addItem(NSMenuItem.separator()) }
        for folder in folders {
            let item = NSMenuItem(title: folder.name, action: #selector(selectSubsonicMusicFolder(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = folder
            item.state = folder.id == currentId ? .on : .off
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    
    private func showSortMenu(at windowPoint: NSPoint) {
        let menu = NSMenu()
        for option in LibraryBrowserSortOption.allCases {
            let item = NSMenuItem(title: option.rawValue, action: #selector(selectSortOption(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = option
            if option == model.currentSort { item.state = .on }
            menu.addItem(item)
        }
        let menuLocation = NSPoint(x: windowPoint.x, y: windowPoint.y - 5)
        menu.popUp(positioning: nil, at: menuLocation, in: window?.contentView)
    }
    
    private func showAddFilesMenu(at event: NSEvent) {
        let menu = NSMenu()
        let addFilesItem = NSMenuItem(title: "Add Files...", action: #selector(addFiles), keyEquivalent: "")
        addFilesItem.target = self; menu.addItem(addFilesItem)
        let addVideoFilesItem = NSMenuItem(title: "Add Video Files...", action: #selector(addVideoFiles), keyEquivalent: "")
        addVideoFilesItem.target = self; menu.addItem(addVideoFilesItem)
        let addFolderItem = NSMenuItem(title: "Add Folder...", action: #selector(addWatchFolder), keyEquivalent: "")
        addFolderItem.target = self; menu.addItem(addFolderItem)
        let menuLocation = NSPoint(x: event.locationInWindow.x, y: event.locationInWindow.y - 5)
        menu.popUp(positioning: nil, at: menuLocation, in: window?.contentView)
    }
    
    private func showRadioAddMenu(at event: NSEvent) {
        let menu = NSMenu()
        let addItem = NSMenuItem(title: "Add Station...", action: #selector(showAddRadioStationDialog), keyEquivalent: "")
        addItem.target = self; menu.addItem(addItem)
        let addFolderItem = NSMenuItem(title: "New Folder...", action: #selector(showCreateRadioFolderDialog), keyEquivalent: "")
        addFolderItem.target = self; menu.addItem(addFolderItem)
        menu.addItem(NSMenuItem.separator())
        let addDefaultsItem = NSMenuItem(title: "Add Missing Defaults", action: #selector(addMissingRadioDefaults), keyEquivalent: "")
        addDefaultsItem.target = self; menu.addItem(addDefaultsItem)
        let resetItem = NSMenuItem(title: "Reset to Defaults", action: #selector(resetRadioToDefaults), keyEquivalent: "")
        resetItem.target = self; menu.addItem(resetItem)
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
    
    private func showColumnConfigMenu(at event: NSEvent) {
        if model.hasInternetRadioColumns {
            guard backdropMenuIsAvailable else { return }
            let menu = NSMenu()
            prependBackdropMenu(to: menu)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        let menu = NSMenu()
        menu.autoenablesItems = false

        for group in columnGroupsForCurrentMenu() {
            addColumnVisibilityGroup(group, to: menu)
        }

        prependBackdropMenu(to: menu)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private var backdropMenuIsAvailable: Bool {
        !compactMode || AppCapabilities.supports(.compactWindowVisualsMenu)
    }

    private func prependBackdropMenu(to menu: NSMenu) {
        guard backdropMenuIsAvailable else { return }
        if !menu.items.isEmpty {
            menu.insertItem(.separator(), at: 0)
        }
        let item = NSMenuItem(
            title: compactMode ? "Compact Background" : "Library Background",
            action: nil,
            keyEquivalent: ""
        )
        item.submenu = compactMode
            ? ContextMenuBuilder.buildCompactBackdropMenu(presenter: backdropPresenter)
            : ContextMenuBuilder.buildLibraryBackdropMenu(presenter: backdropPresenter)
        menu.insertItem(item, at: 0)
    }

    /// Only the header's own group: every row shows those columns, so nothing else is tickable.
    private func columnGroupsForCurrentMenu() -> [LibraryColumnVisibilityGroup] {
        model.currentColumnGroup().map { [$0] } ?? []
    }

    private func addColumnVisibilityGroup(_ group: LibraryColumnVisibilityGroup, to menu: NSMenu) {
        if !menu.items.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }

        let header = NSMenuItem(title: group.headerTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let visibleIds = Set(model.visibleColumnIds(for: group))
        // YouTube's columns are fixed: its section offers only the width reset.
        let tickableColumns = group == .youtube ? [] : LibraryBrowserColumn.all(for: group)
        for column in tickableColumns {
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
    
    private func showContextMenu(for item: LibraryBrowserItem, at event: NSEvent) {
        let menu = NSMenu()
        if let playable = playable(for: item) {
            TrackVerb.addMenuItems(to: menu, for: playable)
            if let level = playable.eqProfileLevel {
                EQProfileMenu.addAssignItem(to: menu, level: level) { try await playable.tracks() }
            }
        }
        switch item.type {
        case .track(let track):
            menu.addItem(NSMenuItem.separator())
            let rateItem = NSMenuItem(title: "Rate", action: nil, keyEquivalent: "")
            rateItem.submenu = buildRateSubmenuForPlex(ratingKey: track.id); menu.addItem(rateItem)
        case .album(let album):
            menu.addItem(NSMenuItem.separator())
            let rateItem = NSMenuItem(title: "Rate", action: nil, keyEquivalent: "")
            rateItem.submenu = buildRateSubmenuForPlex(ratingKey: album.id); menu.addItem(rateItem)
        case .artist:
            let expandItem = NSMenuItem(title: model.isExpanded(item) ? "Collapse" : "Expand",
                                         action: #selector(contextMenuToggleExpand(_:)), keyEquivalent: "")
            expandItem.target = self; expandItem.representedObject = item; menu.addItem(expandItem)
        case .localTrack(let track):
            menu.addItem(NSMenuItem.separator())
            let rateItem = NSMenuItem(title: "Rate", action: nil, keyEquivalent: "")
            rateItem.submenu = buildRateSubmenuForLocal(trackId: track.id); menu.addItem(rateItem)
            menu.addItem(NSMenuItem.separator())
            let tagsItem = NSMenuItem(title: "Edit Tags", action: #selector(contextMenuEditTags(_:)), keyEquivalent: "")
            tagsItem.target = self; tagsItem.representedObject = track; menu.addItem(tagsItem)
            let finderItem = NSMenuItem(title: "Show in Finder", action: #selector(contextMenuShowInFinder(_:)), keyEquivalent: "")
            finderItem.target = self; finderItem.representedObject = track; menu.addItem(finderItem)
            menu.addItem(NSMenuItem.separator())
            let removeTrackItem = NSMenuItem(title: "Remove from Library", action: #selector(contextMenuRemoveLocalTrack(_:)), keyEquivalent: "")
            removeTrackItem.target = self; removeTrackItem.representedObject = track; menu.addItem(removeTrackItem)
        case .localFolder(let url, _):
            menu.addItem(NSMenuItem.separator())
            let finderItem = NSMenuItem(title: "Show in Finder", action: #selector(contextMenuRevealLocalFolderInFinder(_:)), keyEquivalent: "")
            finderItem.target = self; finderItem.representedObject = url; menu.addItem(finderItem)
        case .localAlbum(let album):
            menu.addItem(NSMenuItem.separator())
            let rateAlbumItem = NSMenuItem(title: "Rate", action: nil, keyEquivalent: "")
            rateAlbumItem.submenu = buildRateSubmenuForLocalAlbum(albumId: album.id); menu.addItem(rateAlbumItem)
            let editAlbumItem = NSMenuItem(title: "Edit Album Tags", action: #selector(contextMenuEditAlbumTags(_:)), keyEquivalent: "")
            editAlbumItem.target = self; editAlbumItem.representedObject = album; menu.addItem(editAlbumItem)
            let removeAlbumItem = NSMenuItem(title: "Remove Album from Library", action: #selector(contextMenuRemoveLocalAlbum(_:)), keyEquivalent: "")
            removeAlbumItem.target = self; removeAlbumItem.representedObject = album; menu.addItem(removeAlbumItem)
        case .localArtist(let artist):
            menu.addItem(NSMenuItem.separator())
            let rateArtistItem = NSMenuItem(title: "Rate", action: nil, keyEquivalent: "")
            rateArtistItem.submenu = buildRateSubmenuForLocalArtist(artistId: artist.id); menu.addItem(rateArtistItem)
            let removeArtistItem = NSMenuItem(title: "Remove Artist from Library", action: #selector(contextMenuRemoveLocalArtist(_:)), keyEquivalent: "")
            removeArtistItem.target = self; removeArtistItem.representedObject = artist; menu.addItem(removeArtistItem)
        case .subsonicTrack(let song):
            menu.addItem(NSMenuItem.separator())
            if song.albumId != nil {
                let albumItem = NSMenuItem(title: "Play Album", action: #selector(contextMenuPlaySubsonicSongAlbum(_:)), keyEquivalent: "")
                albumItem.target = self; albumItem.representedObject = song; menu.addItem(albumItem)
            }
            if song.artistId != nil {
                let artistItem = NSMenuItem(title: "Play All by Artist", action: #selector(contextMenuPlaySubsonicSongArtist(_:)), keyEquivalent: "")
                artistItem.target = self; artistItem.representedObject = song; menu.addItem(artistItem)
            }
            menu.addItem(NSMenuItem.separator())
            let rateItem = NSMenuItem(title: "Rate", action: nil, keyEquivalent: "")
            rateItem.submenu = buildRateSubmenuForSubsonic(songId: song.id); menu.addItem(rateItem)
        case .subsonicAlbum(let album):
            menu.addItem(NSMenuItem.separator())
            let rateItem = NSMenuItem(title: "Rate", action: nil, keyEquivalent: "")
            rateItem.submenu = buildRateSubmenuForSubsonic(songId: album.id); menu.addItem(rateItem)
        case .jellyfinTrack(let song):
            if song.albumId != nil {
                menu.addItem(NSMenuItem.separator())
                let albumItem = NSMenuItem(title: "Play Album", action: #selector(contextMenuPlayJellyfinSongAlbum(_:)), keyEquivalent: "")
                albumItem.target = self; albumItem.representedObject = song; menu.addItem(albumItem)
            }
            if song.artistId != nil {
                let artistItem = NSMenuItem(title: "Play All by Artist", action: #selector(contextMenuPlayJellyfinSongArtist(_:)), keyEquivalent: "")
                artistItem.target = self; artistItem.representedObject = song; menu.addItem(artistItem)
            }
            menu.addItem(NSMenuItem.separator())
            let rateItem = NSMenuItem(title: "Rate", action: nil, keyEquivalent: "")
            rateItem.submenu = buildRateSubmenuForJellyfin(itemId: song.id); menu.addItem(rateItem)
        case .embyTrack(let song):
            if song.albumId != nil {
                menu.addItem(NSMenuItem.separator())
                let albumItem = NSMenuItem(title: "Play Album", action: #selector(contextMenuPlayEmbySongAlbum(_:)), keyEquivalent: "")
                albumItem.target = self; albumItem.representedObject = song; menu.addItem(albumItem)
            }
            if song.artistId != nil {
                let artistItem = NSMenuItem(title: "Play All by Artist", action: #selector(contextMenuPlayEmbySongArtist(_:)), keyEquivalent: "")
                artistItem.target = self; artistItem.representedObject = song; menu.addItem(artistItem)
            }
            menu.addItem(NSMenuItem.separator())
            let rateItem = NSMenuItem(title: "Rate", action: nil, keyEquivalent: "")
            rateItem.submenu = buildRateSubmenuForEmby(itemId: song.id); menu.addItem(rateItem)
        case .subsonicArtist, .subsonicPlaylist, .jellyfinAlbum, .jellyfinArtist, .jellyfinPlaylist,
             .embyAlbum, .embyArtist, .embyPlaylist, .plexPlaylist, .localPlaylist, .localPlaylistTrack,
             .movie, .episode, .jellyfinMovie, .jellyfinEpisode, .embyMovie, .embyEpisode:
            break
        case .radioStation(let station):
            let playItem = NSMenuItem(title: "Play Station", action: #selector(contextMenuPlayRadioStation(_:)), keyEquivalent: "")
            playItem.target = self; playItem.representedObject = station; menu.addItem(playItem)
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
            editItem.target = self; editItem.representedObject = station; menu.addItem(editItem)
            let deleteItem = NSMenuItem(title: "Delete Station", action: #selector(contextMenuDeleteRadioStation(_:)), keyEquivalent: "")
            deleteItem.target = self; deleteItem.representedObject = station; menu.addItem(deleteItem)
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
        case .plexRadioStation:
            let playItem = NSMenuItem(title: "Play", action: #selector(contextMenuPlayPlexRadioStation(_:)), keyEquivalent: "")
            playItem.target = self; playItem.representedObject = item; menu.addItem(playItem)
        case .show, .season, .jellyfinShow, .jellyfinSeason, .embyShow, .embySeason:
            let expandItem = NSMenuItem(title: "Expand/Collapse", action: #selector(contextMenuToggleExpand(_:)), keyEquivalent: "")
            expandItem.target = self; expandItem.representedObject = item; menu.addItem(expandItem)
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
            finderItem.target = self; finderItem.representedObject = movie.url as NSURL; menu.addItem(finderItem)
            menu.addItem(NSMenuItem.separator())
            let editMovieItem = NSMenuItem(title: "Edit Tags", action: #selector(contextMenuEditVideoTags(_:)), keyEquivalent: "")
            editMovieItem.target = self; editMovieItem.representedObject = movie; menu.addItem(editMovieItem)
            let removeMovieItem = NSMenuItem(title: "Remove from Library", action: #selector(contextMenuRemoveLocalMovie(_:)), keyEquivalent: "")
            removeMovieItem.target = self; removeMovieItem.representedObject = movie; menu.addItem(removeMovieItem)
        case .localShow(let show):
            let expandItem = NSMenuItem(title: "Expand/Collapse", action: #selector(contextMenuToggleExpand(_:)), keyEquivalent: "")
            expandItem.target = self; expandItem.representedObject = item; menu.addItem(expandItem)
            menu.addItem(NSMenuItem.separator())
            let removeShowItem = NSMenuItem(title: "Remove Show from Library", action: #selector(contextMenuRemoveLocalShow(_:)), keyEquivalent: "")
            removeShowItem.target = self; removeShowItem.representedObject = show; menu.addItem(removeShowItem)
        case .localSeason(let season, let showTitle):
            let expandItem = NSMenuItem(title: "Expand/Collapse", action: #selector(contextMenuToggleExpand(_:)), keyEquivalent: "")
            expandItem.target = self; expandItem.representedObject = item; menu.addItem(expandItem)
            menu.addItem(NSMenuItem.separator())
            let removeSeasonItem = NSMenuItem(title: "Remove Season from Library", action: #selector(contextMenuRemoveLocalSeason(_:)), keyEquivalent: "")
            removeSeasonItem.target = self; removeSeasonItem.representedObject = SeasonRef(season: season, showTitle: showTitle); menu.addItem(removeSeasonItem)
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
            finderItem.target = self; finderItem.representedObject = episode.url as NSURL; menu.addItem(finderItem)
            menu.addItem(NSMenuItem.separator())
            let editEpItem = NSMenuItem(title: "Edit Tags", action: #selector(contextMenuEditVideoTags(_:)), keyEquivalent: "")
            editEpItem.target = self; editEpItem.representedObject = episode; menu.addItem(editEpItem)
            let removeEpItem = NSMenuItem(title: "Remove from Library", action: #selector(contextMenuRemoveLocalEpisode(_:)), keyEquivalent: "")
            removeEpItem.target = self; removeEpItem.representedObject = episode; menu.addItem(removeEpItem)
        case .subsonicRadioStation:
            let playItem = NSMenuItem(title: "Play", action: #selector(contextMenuPlaySubsonicRadioStation(_:)), keyEquivalent: "")
            playItem.target = self; playItem.representedObject = item; menu.addItem(playItem)
        case .jellyfinRadioStation:
            let playItem = NSMenuItem(title: "Play", action: #selector(contextMenuPlayJellyfinRadioStation(_:)), keyEquivalent: "")
            playItem.target = self; playItem.representedObject = item; menu.addItem(playItem)
        case .embyRadioStation:
            let playItem = NSMenuItem(title: "Play", action: #selector(contextMenuPlayEmbyRadioStation(_:)), keyEquivalent: "")
            playItem.target = self; playItem.representedObject = item; menu.addItem(playItem)
        case .localRadioStation:
            let playItem = NSMenuItem(title: "Play", action: #selector(contextMenuPlayLocalRadioStation(_:)), keyEquivalent: "")
            playItem.target = self; playItem.representedObject = item; menu.addItem(playItem)
        case .header: return
        }
        prependBackdropMenu(to: menu)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: - @objc Menu Actions
    
    @objc private func selectLocalSource() { model.currentSource = .local }
    @objc private func selectRadioSource() { model.currentSource = .radio }
    @objc private func selectYouTubeSource() { model.currentSource = .youtube }

    private func showYouTubeAddMenu(at event: NSEvent) {
        let menu = NSMenu()
        let addItem = NSMenuItem(title: "Add Channel...", action: #selector(showAddYouTubeChannelDialog), keyEquivalent: "")
        addItem.target = self; menu.addItem(addItem)
        let menuLocation = NSPoint(x: event.locationInWindow.x, y: event.locationInWindow.y - 5)
        menu.popUp(positioning: nil, at: menuLocation, in: window?.contentView)
    }
    @objc private func selectPlexServer(_ sender: NSMenuItem) {
        guard let serverId = sender.representedObject as? String else { return }
        model.currentSource = .plex(serverId: serverId)
    }
    @objc private func selectSubsonicServer(_ sender: NSMenuItem) {
        guard let serverId = sender.representedObject as? String else { return }
        model.currentSource = .subsonic(serverId: serverId)
    }
    @objc private func selectJellyfinServer(_ sender: NSMenuItem) {
        guard let serverId = sender.representedObject as? String else { return }
        model.currentSource = .jellyfin(serverId: serverId)
    }
    @objc private func selectEmbyServer(_ sender: NSMenuItem) {
        guard let serverId = sender.representedObject as? String else { return }
        model.currentSource = .emby(serverId: serverId)
    }
    @objc private func linkPlexAccount() { controller?.showLinkSheet() }
    @objc private func selectSortOption(_ sender: NSMenuItem) {
        guard let option = sender.representedObject as? LibraryBrowserSortOption else { return }
        model.selectMenuSort(option)
    }
    @objc private func selectLibrary(_ sender: NSMenuItem) {
        guard let library = sender.representedObject as? PlexLibrary else { return }
        model.selectPlexLibrary(library)
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
    @objc private func selectSubsonicMusicFolder(_ sender: NSMenuItem) {
        model.selectSubsonicMusicFolder(sender.representedObject as? SubsonicMusicFolder)
    }
    @objc private func addFiles() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff]; panel.message = "Select audio files"
        if panel.runModal() == .OK { MediaLibrary.shared.addTracks(urls: panel.urls) }
    }
    @objc private func addVideoFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        // Build the allowed types from every container we actually support so
        // formats like .mkv/.avi/.webm aren't greyed out in the panel.
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

    /// Switch the browser to the local Movies category and reload so freshly-added
    /// videos are actually visible. Without this the add succeeds but the user stays
    /// on whatever tab they were on (e.g. Artists), so nothing appears to happen.
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
    @objc private func showAddRadioStationDialog() {
        activeRadioStationSheet = AddRadioStationSheet(station: nil)
        activeRadioStationSheet?.showDialog { [weak self] station in
            self?.activeRadioStationSheet = nil
            if let newStation = station {
                RadioManager.shared.addStation(newStation)
                if case .radio = self?.model.currentSource { self?.model.reloadInternetRadioForCurrentMode() }
                else { self?.model.currentSource = .radio }
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
    @objc private func addMissingRadioDefaults() { RadioManager.shared.addMissingDefaults(); if case .radio = model.currentSource { model.reloadInternetRadioForCurrentMode() } }
    @objc private func resetRadioToDefaults() {
        let alert = NSAlert(); alert.messageText = "Reset to Defaults"; alert.informativeText = "Replace all stations with defaults?"
        alert.addButton(withTitle: "Reset"); alert.addButton(withTitle: "Cancel"); alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn { RadioManager.shared.resetToDefaults(); if case .radio = model.currentSource { model.reloadInternetRadioForCurrentMode() } }
    }
    @objc private func contextMenuToggleExpand(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? LibraryBrowserItem else { return }; model.toggleExpand(item)
    }
    @objc private func contextMenuShowTags(_ sender: NSMenuItem) {
        guard let track = sender.representedObject as? LibraryTrack else { return }
        activeTagsPanel?.close()
        let tagsPanel = TagsPanel(track: track); activeTagsPanel = tagsPanel; tagsPanel.show()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: tagsPanel, queue: .main) { [weak self] _ in
            self?.activeTagsPanel = nil
        }
    }
    @objc private func contextMenuEditTags(_ sender: NSMenuItem) {
        guard let track = sender.representedObject as? LibraryTrack else { return }
        activeEditTagsPanel?.close()
        let panel = EditTagsPanel(track: track)
        panel.onSave = { [weak self] in self?.model.reloadLocalBrowserAfterMetadataEdit() }
        activeEditTagsPanel = panel; panel.show()
    }
    @objc private func contextMenuEditAlbumTags(_ sender: NSMenuItem) {
        guard let album = sender.representedObject as? Album else { return }
        activeEditAlbumTagsPanel?.close()
        let panel = EditAlbumTagsPanel(album: album)
        panel.onSave = { [weak self] in self?.model.reloadLocalBrowserAfterMetadataEdit() }
        activeEditAlbumTagsPanel = panel; panel.show()
    }
    @objc private func contextMenuEditVideoTags(_ sender: NSMenuItem) {
        let videoItem: EditVideoTagsPanel.VideoItem
        if let movie = sender.representedObject as? LocalVideo { videoItem = .movie(movie) }
        else if let ep = sender.representedObject as? LocalEpisode { videoItem = .episode(ep) }
        else { return }
        activeEditVideoTagsPanel?.close()
        let panel = EditVideoTagsPanel(item: videoItem)
        panel.onSave = { [weak self] in self?.model.reloadLocalBrowserAfterMetadataEdit() }
        activeEditVideoTagsPanel = panel; panel.show()
    }
    @objc private func contextMenuRemoveLocalTrack(_ sender: NSMenuItem) {
        guard let track = sender.representedObject as? LibraryTrack else { return }
        let tracksToRemove = selectedLocalTracksForContextAction(fallback: track)
        if tracksToRemove.count == 1 {
            MediaLibrary.shared.removeTrack(track)
        } else {
            MediaLibrary.shared.removeTracks(urls: tracksToRemove.map { $0.url })
        }
        model.loadLocalData()
    }
    @objc private func contextMenuRemoveLocalAlbum(_ sender: NSMenuItem) {
        guard let album = sender.representedObject as? Album else { return }
        let tracks = LibraryPlayable.libraryTracks(of: album)
        let count = tracks.count
        let alert = NSAlert()
        alert.messageText = "Remove \"\(album.name)\" from Library?"
        alert.informativeText = "This will remove \(count) track\(count == 1 ? "" : "s"). Files will not be deleted."
        alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        MediaLibrary.shared.removeTracks(urls: tracks.map { $0.url }); model.loadLocalData()
    }
    @objc private func contextMenuRemoveLocalArtist(_ sender: NSMenuItem) {
        guard let artist = sender.representedObject as? Artist else { return }
        let artistsToRemove = selectedLocalArtistsForContextAction(fallback: artist)
        let store = MediaLibraryStore.shared
        let trackURLs: [URL] = artistsToRemove.flatMap { a -> [URL] in
            if a.albums.isEmpty {
                // Paginated stub — load tracks from store
                let summaries = store.albumsForArtist(a.name)
                return summaries.flatMap { store.tracksForAlbum($0.id) }.map { $0.url }
            } else {
                return a.albums.flatMap { $0.tracks }.map { $0.url }
            }
        }
        let dedupedTrackURLs = dedupeURLsPreservingOrder(trackURLs)
        let count = dedupedTrackURLs.count

        let alert = NSAlert()
        if artistsToRemove.count == 1 {
            alert.messageText = "Remove \"\(artist.name)\" from Library?"
        } else {
            alert.messageText = "Remove \(artistsToRemove.count) Artists from Library?"
        }
        alert.informativeText = "This will remove \(count) track\(count == 1 ? "" : "s"). Files will not be deleted."
        alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        MediaLibrary.shared.removeTracks(urls: dedupedTrackURLs); model.loadLocalData()
    }
    @objc private func contextMenuRemoveLocalMovie(_ sender: NSMenuItem) {
        guard let movie = sender.representedObject as? LocalVideo else { return }
        let moviesToRemove = selectedLocalMoviesForContextAction(fallback: movie)
        if moviesToRemove.count == 1 {
            MediaLibrary.shared.removeMovie(movie)
        } else {
            MediaLibrary.shared.removeMovies(urls: moviesToRemove.map { $0.url })
        }
        model.loadLocalData()
    }
    @objc private func contextMenuRemoveLocalEpisode(_ sender: NSMenuItem) {
        guard let episode = sender.representedObject as? LocalEpisode else { return }
        MediaLibrary.shared.removeEpisode(episode); model.loadLocalData()
    }
    @objc private func contextMenuRemoveLocalShow(_ sender: NSMenuItem) {
        guard let show = sender.representedObject as? LocalShow else { return }
        let count = show.episodeCount
        let alert = NSAlert()
        alert.messageText = "Remove \"\(show.title)\" from Library?"
        alert.informativeText = "This will remove \(count) episode\(count == 1 ? "" : "s"). Files will not be deleted."
        alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        MediaLibrary.shared.removeShow(title: show.title); model.loadLocalData()
    }
    @objc private func contextMenuRemoveLocalSeason(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? SeasonRef else { return }
        let count = ref.season.episodes.count
        let alert = NSAlert()
        alert.messageText = "Remove Season \(ref.season.number) of \"\(ref.showTitle)\" from Library?"
        alert.informativeText = "This will remove \(count) episode\(count == 1 ? "" : "s"). Files will not be deleted."
        alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        MediaLibrary.shared.removeSeason(showTitle: ref.showTitle, seasonNumber: ref.season.number); model.loadLocalData()
    }
    @objc private func contextMenuShowInFinder(_ sender: NSMenuItem) {
        guard let track = sender.representedObject as? LibraryTrack else { return }
        NSWorkspace.shared.activateFileViewerSelecting([track.url])
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

        // De-duplicate by file URL while preserving visual selection order.
        return dedupeByURL(selectedTracks, keyPath: \.url)
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

    /// For local-movie context actions, prefer current multi-selection when the
    /// clicked movie is part of it; otherwise fall back to the clicked movie.
    private func selectedLocalMoviesForContextAction(fallback movie: LocalVideo) -> [LocalVideo] {
        let selectedMovies = selectedIndices
            .filter { $0 >= 0 && $0 < model.displayItems.count }
            .sorted()
            .compactMap { index -> LocalVideo? in
                guard case .localMovie(let selectedMovie) = model.displayItems[index].type else { return nil }
                return selectedMovie
            }

        guard selectedMovies.count > 1,
              selectedMovies.contains(where: { $0.id == movie.id }) else {
            return [movie]
        }

        var seen = Set<UUID>()
        return selectedMovies.filter { seen.insert($0.id).inserted }
    }

    private func dedupeURLsPreservingOrder(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }

    private func dedupeByURL<T>(_ items: [T], keyPath: KeyPath<T, URL>) -> [T] {
        var seen = Set<URL>()
        return items.filter { seen.insert($0[keyPath: keyPath]).inserted }
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
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
    @objc private func contextMenuPlaySubsonicSongAlbum(_ sender: NSMenuItem) {
        guard let song = sender.representedObject as? SubsonicSong,
              let albumId = song.albumId else { return }
        if let album = model.subsonic.albums.first(where: { $0.id == albumId }) {
            TrackVerb.play.run(.subsonicAlbum(album))
            return
        }
        TrackVerb.play.run {
            let (_, songs) = try await SubsonicManager.shared.serverClient?.fetchAlbum(id: albumId) ?? (nil, [])
            return SubsonicManager.shared.convertToTracks(songs)
        }
    }
    @objc private func contextMenuPlaySubsonicSongArtist(_ sender: NSMenuItem) {
        guard let song = sender.representedObject as? SubsonicSong,
              let artistId = song.artistId else { return }
        if let artist = model.subsonic.artists.first(where: { $0.id == artistId }) {
            TrackVerb.play.run(.subsonicArtist(artist))
            return
        }
        TrackVerb.play.run {
            let results = try await SubsonicManager.shared.search(query: song.artist ?? "")
            return SubsonicManager.shared.convertToTracks(results.songs)
        }
    }
    @objc private func contextMenuPlayJellyfinSongAlbum(_ sender: NSMenuItem) {
        guard let song = sender.representedObject as? JellyfinSong,
              let albumId = song.albumId else { return }
        if let album = model.jellyfin.albums.first(where: { $0.id == albumId }) {
            TrackVerb.play.run(.jellyfinAlbum(album))
            return
        }
        TrackVerb.play.run {
            let (_, songs) = try await JellyfinManager.shared.serverClient?.fetchAlbum(id: albumId) ?? (nil, [])
            return JellyfinManager.shared.convertToTracks(songs)
        }
    }
    @objc private func contextMenuPlayJellyfinSongArtist(_ sender: NSMenuItem) {
        guard let song = sender.representedObject as? JellyfinSong,
              let artistId = song.artistId else { return }
        if let artist = model.jellyfin.artists.first(where: { $0.id == artistId }) {
            TrackVerb.play.run(.jellyfinArtist(artist))
            return
        }
        TrackVerb.play.run {
            let results = try await JellyfinManager.shared.search(query: song.artist ?? "")
            return JellyfinManager.shared.convertToTracks(results.songs)
        }
    }
    @objc private func contextMenuPlayRadioStation(_ sender: NSMenuItem) {
        guard let station = sender.representedObject as? RadioStation else { return }; playRadioStation(station)
    }
    @objc private func contextMenuEditRadioStation(_ sender: NSMenuItem) {
        guard let station = sender.representedObject as? RadioStation else { return }
        activeRadioStationSheet = AddRadioStationSheet(station: station)
        activeRadioStationSheet?.showDialog { [weak self] updated in
            self?.activeRadioStationSheet = nil
            if let u = updated { RadioManager.shared.updateStation(u); self?.model.reloadInternetRadioForCurrentMode() }
        }
    }
    @objc private func contextMenuDeleteRadioStation(_ sender: NSMenuItem) {
        guard let station = sender.representedObject as? RadioStation else { return }
        let alert = NSAlert(); alert.messageText = "Delete '\(station.name)'?"; alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { RadioManager.shared.removeStation(station); model.reloadInternetRadioForCurrentMode() }
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
    @objc private func contextMenuRefreshYouTubeChannel(_ sender: NSMenuItem) {
        guard let channel = sender.representedObject as? YouTubeChannel else { return }
        model.refreshYouTubeChannel(channel)
    }

    @objc private func contextMenuRemoveYouTubeChannel(_ sender: NSMenuItem) {
        guard let channel = sender.representedObject as? YouTubeChannel else { return }
        model.removeYouTubeChannel(channel)
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
    @objc private func contextMenuPlayEmbySongAlbum(_ sender: NSMenuItem) {
        guard let song = sender.representedObject as? EmbySong,
              let albumId = song.albumId else { return }
        if let album = model.emby.albums.first(where: { $0.id == albumId }) {
            TrackVerb.play.run(.embyAlbum(album))
            return
        }
        TrackVerb.play.run {
            let (_, songs) = try await EmbyManager.shared.serverClient?.fetchAlbum(id: albumId) ?? (nil, [])
            return EmbyManager.shared.convertToTracks(songs)
        }
    }
    @objc private func contextMenuPlayEmbySongArtist(_ sender: NSMenuItem) {
        guard let song = sender.representedObject as? EmbySong,
              let artistId = song.artistId else { return }
        if let artist = model.emby.artists.first(where: { $0.id == artistId }) {
            TrackVerb.play.run(.embyArtist(artist))
            return
        }
        TrackVerb.play.run {
            let results = try await EmbyManager.shared.search(query: song.artist ?? "")
            return EmbyManager.shared.convertToTracks(results.songs)
        }
    }

    @objc private func contextMenuRevealLocalFolderInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Keyboard Shortcut Helpers
    
    /// Shift+Enter / Option+Enter: the menu's Play Next / Add to Queue on the selected row.
    private func runVerbOnSelection(_ verb: TrackVerb) {
        guard let index = selectedIndices.first, index < model.displayItems.count,
              let playable = playable(for: model.displayItems[index]) else { return }
        verb.run(playable)
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

    // MARK: - Notification Handlers
    
    private func invalidateServerBarFontCache() {
        cachedServerBarFont = nil
        cachedServerBarFontSkinName = nil
        cachedServerBarFontScale = nil
        cachedServerBarIsMetal = nil
        cachedServerBarCompact = nil
        cachedPrefixAttrs = nil
        cachedDataAttrs = nil
        cachedActiveAttrs = nil
    }

    @objc private func modernSkinDidChange() {
        let skin = currentSkin()
        renderer = ModernSkinRenderer(skin: skin)
        historyHostingView?.rootView = StatsContentView(agent: historyAgent,
                                                        skinTextColor: Color(skin.textColor),
                                                        headerTitle: "Library Data",
                                                        heatmapTheme: ContributionHeatmapTheme(modernSkin: skin))
        historyHostingView?.appearance = skinAppearance(for: skin)
        updateHistoryHostingBackground()
        artLens.restyle()
        backdropView?.reload()
        invalidateServerBarFontCache()
        updateCornerMask()
        updateEmbeddedSubviewFrames()
        compactPlayerBar?.skinDidChange()
        needsDisplay = true
    }
    
    @objc private func doubleSizeChanged() {
        modernSkinDidChange()
    }

    @objc private func playHistoryDidChange() {
        Task { @MainActor [weak self] in
            guard let self, self.model.browseMode.isHistoryMode else { return }
            self.historyAgent.scheduleRefresh()
        }
    }
    
    @objc private func windowLayoutDidChange() {
        guard let window = window else { return }
        let newEdges = WindowManager.shared.computeAdjacentEdges(for: window)
        let newSharp = WindowManager.shared.computeSharpCorners(for: window)
        let newSegments = WindowManager.shared.computeEdgeOcclusionSegments(for: window)
        let cornersChanged = newSharp != sharpCorners
        if newEdges != adjacentEdges || cornersChanged || newSegments != edgeOcclusionSegments {
            adjacentEdges = newEdges
            sharpCorners = newSharp
            edgeOcclusionSegments = newSegments
            needsDisplay = true
        }
        if cornersChanged { window.invalidateSkinShadowShape("corners") }
        updateEmbeddedSubviewFrames()
    }

    @objc private func connectedWindowHighlightDidChange(_ notification: Notification) {
        let highlighted = notification.userInfo?["highlightedWindows"] as? Set<NSWindow> ?? []
        let newValue = highlighted.contains { $0 === window }
        if isHighlighted != newValue {
            isHighlighted = newValue
            needsDisplay = true
        }
    }

    func skinDidChange() { modernSkinDidChange() }

    @objc private func libraryRowThumbnailDidLoad() {
        needsDisplay = true
    }

    /// A channel's uploads started or finished loading: spin the per-row spinner. The model rebuilds the rows.
    @objc private func youtubeUploadsDidChange() {
        if YouTubeChannelUploads.shared.hasFetchesInFlight { startLoadingAnimation() }
    }

    @objc private func trackDidChange(_ notification: Notification) {
        let track = notification.userInfo?["track"] as? Track
        let needsCurrentTrackArtwork = showsLegacyArtwork
        guard needsCurrentTrackArtwork else {
            artworkDisplayGeneration &+= 1
            if currentArtwork != nil || currentTrackArtwork != nil {
                currentArtwork = nil
                currentTrackArtwork = nil
                artworkTrackId = nil
                needsDisplay = true
            }
            return
        }
        loadArtwork(for: track)
    }
    
    @objc private func windowDidMiniaturize(_ notification: Notification) {
        guard notification.object as? NSWindow == window else { return }
        stopServerNameScroll()
        backdropView?.reload()
    }
    
    @objc private func windowDidDeminiaturize(_ notification: Notification) {
        guard notification.object as? NSWindow == window else { return }
        startServerNameScroll()
        backdropView?.reload()
    }
    
    @objc private func windowDidChangeOcclusionState(_ notification: Notification) {
        guard notification.object as? NSWindow == window else { return }
        if window?.occlusionState.contains(.visible) == true {
            startServerNameScroll()
        } else {
            stopServerNameScroll()
        }
        backdropView?.reload()
    }
    
    // MARK: - Loading Animation
    
    private func startLoadingAnimation() {
        guard loadingAnimationTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.loadingAnimationFrame += 1
            if self.model.isLoading {
                self.needsDisplay = true
            } else if self.youtubeVideoActions.hasFetchesInFlight || YouTubeChannelUploads.shared.hasFetchesInFlight {
                // Redraw the list area for the per-row download/channel-load spinner(s)
                self.needsDisplay = true
            } else if self.isLibraryScanning {
                // Redraw server bar only for the scan spinner
                let serverBarY = self.topChromeBottomY - Layout.serverBarHeight
                self.setNeedsDisplay(NSRect(x: 0, y: serverBarY, width: self.bounds.width, height: Layout.serverBarHeight))
            } else {
                self.stopLoadingAnimation()
            }
        }
        RunLoop.main.add(timer, forMode: .common); loadingAnimationTimer = timer
    }

    private func stopLoadingAnimation(force: Bool = false) {
        guard force || (!isLibraryScanning && !youtubeVideoActions.hasFetchesInFlight && !YouTubeChannelUploads.shared.hasFetchesInFlight) else { return }
        loadingAnimationTimer?.invalidate(); loadingAnimationTimer = nil; loadingAnimationFrame = 0
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
        let mgr = JellyfinManager.shared
        switch model.browseMode {
        case .movies: return mgr.currentMovieLibrary?.name ?? "All"
        case .shows:  return mgr.currentShowLibrary?.name ?? "All"
        default:      return mgr.currentMusicLibrary?.name ?? "All"
        }
    }

    /// Returns the display name of the currently relevant Emby library based on browse mode.
    private var embyCurrentLibraryName: String {
        let mgr = EmbyManager.shared
        switch model.browseMode {
        case .movies: return mgr.currentMovieLibrary?.name ?? "All"
        case .shows:  return mgr.currentShowLibrary?.name ?? "All"
        default:      return mgr.currentMusicLibrary?.name ?? "All"
        }
    }

    // MARK: - Server Name Scroll
    
    private func startServerNameScroll() {
        guard serverScrollTimer == nil else { return }
        serverScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.067, repeats: true) { [weak self] _ in
            self?.handleServerNameScrollTick()
        }
    }

    private func stopServerNameScroll() {
        serverScrollTimer?.invalidate(); serverScrollTimer = nil
        serverNameScrollOffset = 0; libraryNameScrollOffset = 0
    }

    private func handleServerNameScrollTick() {
        guard let window = window,
              window.isVisible,
              window.occlusionState.contains(.visible) else { return }
        updateServerNameScroll()
    }

    private func updateServerNameScroll() {
        // The widths are drawServerBar's: zero unless a server's fields are showing.
        let serverNeedsScroll = serverNameTextWidth > serverNameMaxWidth
        let libraryNeedsScroll = libraryNameTextWidth > libraryNameMaxWidth
        if !serverNeedsScroll && !libraryNeedsScroll {
            let hadOffset = serverNameScrollOffset != 0 || libraryNameScrollOffset != 0
            stopServerNameScroll()
            if hadOffset { setNeedsDisplay(serverBarRect()) }
            return
        }

        // A scrolling name cycles through itself and drawScrollingText's 30% gap.
        if serverNeedsScroll {
            serverNameScrollOffset += 1
            if serverNameScrollOffset >= serverNameTextWidth * 1.3 { serverNameScrollOffset = 0 }
        } else {
            serverNameScrollOffset = 0
        }
        if libraryNeedsScroll {
            libraryNameScrollOffset += 1
            if libraryNameScrollOffset >= libraryNameTextWidth * 1.3 { libraryNameScrollOffset = 0 }
        } else {
            libraryNameScrollOffset = 0
        }
        setNeedsDisplay(serverBarRect())
    }

    /// Returns the rect of the server bar for targeted redraws.
    private func serverBarRect() -> NSRect {
        let barY = topChromeBottomY - Layout.serverBarHeight
        return NSRect(x: 0, y: barY, width: bounds.width, height: Layout.serverBarHeight)
    }

    // MARK: - Rate Submenus

    private static func goldStarAttributedTitle(_ label: String) -> NSAttributedString {
        let goldColor = ModernSkinEngine.shared.currentRenderStyle == .metal
            ? NSColor(calibratedRed: 0.34, green: 0.28, blue: 0.13, alpha: 1.0)
            : NSColor(srgbRed: 0.98, green: 0.78, blue: 0.20, alpha: 1.0)
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

    /// Build rate submenu for a Plex track
    private func buildRateSubmenuForPlex(ratingKey: String) -> NSMenu {
        let menu = NSMenu(title: "Rate")
        for stars in 1...5 {
            let label = String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars)
            let item = NSMenuItem(title: label, action: #selector(contextMenuRatePlex(_:)), keyEquivalent: "")
            item.target = self; item.tag = stars * 2; item.representedObject = ratingKey
            item.attributedTitle = ModernLibraryBrowserView.goldStarAttributedTitle(label)
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())
        let clearItem = NSMenuItem(title: "Clear Rating", action: #selector(contextMenuRatePlex(_:)), keyEquivalent: "")
        clearItem.target = self; clearItem.tag = 0; clearItem.representedObject = ratingKey
        menu.addItem(clearItem)
        return menu
    }
    
    /// Build rate submenu for a Subsonic track
    private func buildRateSubmenuForSubsonic(songId: String) -> NSMenu {
        let menu = NSMenu(title: "Rate")
        for stars in 1...5 {
            let label = String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars)
            let item = NSMenuItem(title: label, action: #selector(contextMenuRateSubsonic(_:)), keyEquivalent: "")
            item.target = self; item.tag = stars; item.representedObject = songId  // tag is 1-5 for Subsonic
            item.attributedTitle = ModernLibraryBrowserView.goldStarAttributedTitle(label)
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())
        let clearItem = NSMenuItem(title: "Clear Rating", action: #selector(contextMenuRateSubsonic(_:)), keyEquivalent: "")
        clearItem.target = self; clearItem.tag = 0; clearItem.representedObject = songId
        menu.addItem(clearItem)
        return menu
    }
    
    private func buildRateSubmenuForJellyfin(itemId: String) -> NSMenu {
        let menu = NSMenu(title: "Rate")
        for stars in 1...5 {
            let label = String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars)
            let item = NSMenuItem(title: label, action: #selector(contextMenuRateJellyfin(_:)), keyEquivalent: "")
            item.target = self; item.tag = stars * 20; item.representedObject = itemId  // Jellyfin uses 0-100 scale
            item.attributedTitle = ModernLibraryBrowserView.goldStarAttributedTitle(label)
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())
        let clearItem = NSMenuItem(title: "Clear Rating", action: #selector(contextMenuRateJellyfin(_:)), keyEquivalent: "")
        clearItem.target = self; clearItem.tag = 0; clearItem.representedObject = itemId
        menu.addItem(clearItem)
        return menu
    }

    private func buildRateSubmenuForEmby(itemId: String) -> NSMenu {
        let menu = NSMenu(title: "Rate")
        for stars in 1...5 {
            let label = String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars)
            let item = NSMenuItem(title: label, action: #selector(contextMenuRateEmby(_:)), keyEquivalent: "")
            item.target = self; item.tag = stars * 20; item.representedObject = itemId  // Emby uses 0-100 scale
            item.attributedTitle = ModernLibraryBrowserView.goldStarAttributedTitle(label)
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())
        let clearItem = NSMenuItem(title: "Clear Rating", action: #selector(contextMenuRateEmby(_:)), keyEquivalent: "")
        clearItem.target = self; clearItem.tag = 0; clearItem.representedObject = itemId
        menu.addItem(clearItem)
        return menu
    }

    private func buildRateSubmenuForLocalAlbum(albumId: String) -> NSMenu {
        let menu = NSMenu(title: "Rate")
        for stars in 1...5 {
            let rating = stars * 2
            let label = String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars)
            let item = NSMenuItem(title: label, action: #selector(contextMenuRateLocalAlbum(_:)), keyEquivalent: "")
            item.target = self; item.tag = rating; item.representedObject = albumId
            item.attributedTitle = ModernLibraryBrowserView.goldStarAttributedTitle(label)
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())
        let clearItem = NSMenuItem(title: "Clear Rating", action: #selector(contextMenuRateLocalAlbum(_:)), keyEquivalent: "")
        clearItem.target = self; clearItem.tag = -1; clearItem.representedObject = albumId
        menu.addItem(clearItem)
        return menu
    }

    private func buildRateSubmenuForLocalArtist(artistId: String) -> NSMenu {
        let menu = NSMenu(title: "Rate")
        for stars in 1...5 {
            let label = String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars)
            let item = NSMenuItem(title: label, action: #selector(contextMenuRateLocalArtist(_:)), keyEquivalent: "")
            item.target = self; item.tag = stars * 2; item.representedObject = artistId
            item.attributedTitle = ModernLibraryBrowserView.goldStarAttributedTitle(label)
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())
        let clearItem = NSMenuItem(title: "Clear Rating", action: #selector(contextMenuRateLocalArtist(_:)), keyEquivalent: "")
        clearItem.target = self; clearItem.tag = -1; clearItem.representedObject = artistId
        menu.addItem(clearItem)
        return menu
    }

    /// Build rate submenu for a local track
    private func buildRateSubmenuForLocal(trackId: UUID) -> NSMenu {
        let menu = NSMenu(title: "Rate")
        for stars in 1...5 {
            let label = String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars)
            let item = NSMenuItem(title: label, action: #selector(contextMenuRateLocal(_:)), keyEquivalent: "")
            item.target = self; item.tag = stars * 2; item.representedObject = trackId  // 0-10 scale
            item.attributedTitle = ModernLibraryBrowserView.goldStarAttributedTitle(label)
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())
        let clearItem = NSMenuItem(title: "Clear Rating", action: #selector(contextMenuRateLocal(_:)), keyEquivalent: "")
        clearItem.target = self; clearItem.tag = -1; clearItem.representedObject = trackId  // -1 = clear
        menu.addItem(clearItem)
        return menu
    }
    
    @objc private func contextMenuRatePlex(_ sender: NSMenuItem) {
        guard let ratingKey = sender.representedObject as? String else { return }
        let rating = sender.tag  // 0-10 scale
        Task {
            do {
                try await PlexManager.shared.serverClient?.rateItem(ratingKey: ratingKey, rating: rating > 0 ? rating : nil)
                await MainActor.run {
                    updateCachedPlexRating(ratingKey: ratingKey, rating: rating)
                }
            } catch { NSLog("Plex rating failed: %@", error.localizedDescription.redactingSensitiveURLQueryItems) }
        }
    }
    
    @objc private func contextMenuRateSubsonic(_ sender: NSMenuItem) {
        guard let songId = sender.representedObject as? String else { return }
        let subsonicRating = sender.tag  // 0-5 scale for Subsonic
        Task {
            do {
                try await SubsonicManager.shared.setRating(songId: songId, rating: subsonicRating)
                await MainActor.run {
                    // Update the cached song in displayItems
                    updateCachedSubsonicRating(songId: songId, rating: subsonicRating)
                }
            } catch { NSLog("Subsonic rating failed: %@", error.localizedDescription.redactingSensitiveURLQueryItems) }
        }
    }
    
    @objc private func contextMenuRateJellyfin(_ sender: NSMenuItem) {
        guard let itemId = sender.representedObject as? String else { return }
        let rating = sender.tag  // 0-100 scale (0 = clear, 20/40/60/80/100 for 1-5 stars)
        Task {
            do {
                try await JellyfinManager.shared.setRating(itemId: itemId, rating: rating)
                await MainActor.run {
                    updateCachedJellyfinRating(itemId: itemId, rating: rating)
                }
            } catch { NSLog("Jellyfin rating failed: %@", error.localizedDescription.redactingSensitiveURLQueryItems) }
        }
    }

    @objc private func contextMenuRateEmby(_ sender: NSMenuItem) {
        guard let itemId = sender.representedObject as? String else { return }
        let rating = sender.tag  // 0-100 scale (0 = clear, 20/40/60/80/100 for 1-5 stars)
        Task {
            do {
                try await EmbyManager.shared.setRating(itemId: itemId, rating: rating)
                await MainActor.run {
                    updateCachedEmbyRating(itemId: itemId, rating: rating)
                }
            } catch { NSLog("Emby rating failed: %@", error.localizedDescription.redactingSensitiveURLQueryItems) }
        }
    }

    @objc private func contextMenuRateLocal(_ sender: NSMenuItem) {
        guard let trackId = sender.representedObject as? UUID else { return }
        let rating = sender.tag  // 0-10, or -1 for clear
        MediaLibrary.shared.setRating(for: trackId, rating: rating >= 0 ? rating : nil)
        updateCachedLocalTrackRating(trackId: trackId, rating: rating)
        needsDisplay = true
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
    
    /// Update cached SubsonicSong rating in displayItems after a rating change
    private func updateCachedSubsonicRating(songId: String, rating: Int) {
        for (index, item) in model.displayItems.enumerated() {
            if case .subsonicTrack(let song) = item.type, song.id == songId {
                let updatedSong = SubsonicSong(
                    id: song.id, parent: song.parent, title: song.title,
                    album: song.album, artist: song.artist, albumArtist: song.albumArtist,
                    albumId: song.albumId, artistId: song.artistId, track: song.track, year: song.year,
                    genre: song.genre, coverArt: song.coverArt, size: song.size,
                    contentType: song.contentType, suffix: song.suffix,
                    duration: song.duration, bitRate: song.bitRate,
                    samplingRate: song.samplingRate, path: song.path,
                    discNumber: song.discNumber, created: song.created,
                    starred: song.starred, playCount: song.playCount,
                    userRating: rating > 0 ? rating : nil
                )
                model.displayItems[index] = LibraryBrowserItem(
                    id: item.id, title: item.title, info: item.info,
                    indentLevel: item.indentLevel, hasChildren: item.hasChildren,
                    type: .subsonicTrack(updatedSong)
                )
                break
            }
        }
    }

    private func updateCachedPlexRating(ratingKey: String, rating: Int) {
        for (index, item) in model.displayItems.enumerated() {
            if case .track(let track) = item.type, track.id == ratingKey {
                let updatedTrack = PlexTrack(
                    id: track.id, key: track.key, title: track.title,
                    parentTitle: track.parentTitle, grandparentTitle: track.grandparentTitle,
                    parentKey: track.parentKey, grandparentKey: track.grandparentKey,
                    summary: track.summary, duration: track.duration,
                    index: track.index, parentIndex: track.parentIndex,
                    thumb: track.thumb, media: track.media,
                    addedAt: track.addedAt, updatedAt: track.updatedAt,
                    genre: track.genre, parentYear: track.parentYear,
                    ratingCount: track.ratingCount,
                    userRating: rating > 0 ? Double(rating) : nil
                )
                model.displayItems[index] = LibraryBrowserItem(
                    id: item.id, title: item.title, info: item.info,
                    indentLevel: item.indentLevel, hasChildren: item.hasChildren,
                    type: .track(updatedTrack)
                )
                break
            }
        }
    }

    private func updateCachedJellyfinRating(itemId: String, rating: Int) {
        for (index, item) in model.displayItems.enumerated() {
            if case .jellyfinTrack(let song) = item.type, song.id == itemId {
                let updatedSong = JellyfinSong(
                    id: song.id, title: song.title, album: song.album,
                    artist: song.artist, albumArtist: song.albumArtist,
                    albumId: song.albumId, artistId: song.artistId,
                    track: song.track, year: song.year, genre: song.genre,
                    imageTag: song.imageTag, size: song.size, contentType: song.contentType,
                    duration: song.duration, bitRate: song.bitRate,
                    sampleRate: song.sampleRate, channels: song.channels,
                    path: song.path, discNumber: song.discNumber, created: song.created,
                    isFavorite: song.isFavorite, playCount: song.playCount,
                    userRating: rating > 0 ? rating : nil
                )
                model.displayItems[index] = LibraryBrowserItem(
                    id: item.id, title: item.title, info: item.info,
                    indentLevel: item.indentLevel, hasChildren: item.hasChildren,
                    type: .jellyfinTrack(updatedSong)
                )
                break
            }
        }
    }

    private func updateCachedEmbyRating(itemId: String, rating: Int) {
        for (index, item) in model.displayItems.enumerated() {
            if case .embyTrack(let song) = item.type, song.id == itemId {
                let updatedSong = EmbySong(
                    id: song.id, title: song.title, album: song.album,
                    artist: song.artist, albumArtist: song.albumArtist,
                    albumId: song.albumId, artistId: song.artistId,
                    track: song.track, year: song.year, genre: song.genre,
                    imageTag: song.imageTag, size: song.size, contentType: song.contentType,
                    duration: song.duration, bitRate: song.bitRate,
                    sampleRate: song.sampleRate, channels: song.channels,
                    path: song.path, discNumber: song.discNumber, created: song.created,
                    isFavorite: song.isFavorite, playCount: song.playCount,
                    userRating: rating > 0 ? rating : nil
                )
                model.displayItems[index] = LibraryBrowserItem(
                    id: item.id, title: item.title, info: item.info,
                    indentLevel: item.indentLevel, hasChildren: item.hasChildren,
                    type: .embyTrack(updatedSong)
                )
                break
            }
        }
    }

    private func updateCachedLocalTrackRating(trackId: UUID, rating: Int) {
        for (index, item) in model.displayItems.enumerated() {
            if case .localTrack(var track) = item.type, track.id == trackId {
                track.rating = rating >= 0 ? rating : nil
                model.displayItems[index] = LibraryBrowserItem(
                    id: item.id, title: item.title, info: item.info,
                    indentLevel: item.indentLevel, hasChildren: item.hasChildren,
                    type: .localTrack(track)
                )
                break
            }
        }
    }
    
    // MARK: - Artwork Loading
    
    private func loadArtwork(for track: Track?) {
        currentTrackArtworkLoadTask?.cancel(); currentTrackArtworkLoadTask = nil
        guard let track = track else {
            artworkDisplayGeneration &+= 1
            currentArtwork = nil
            currentTrackArtwork = nil
            artworkTrackId = nil
            needsDisplay = true
            return
        }
        guard track.id != artworkTrackId || currentTrackArtwork == nil else {
            return
        }
        artworkDisplayGeneration &+= 1
        let displayGeneration = artworkDisplayGeneration
        currentTrackArtworkLoadTask = Task { [weak self] in
            guard let self = self else { return }
            var image: NSImage?
            if let plexRatingKey = track.plexRatingKey {
                image = await self.loadPlexArtwork(ratingKey: plexRatingKey, thumbPath: track.artworkThumb)
            } else if let subsonicId = track.subsonicId {
                image = await self.loadSubsonicArtwork(songId: subsonicId)
            } else if track.jellyfinId != nil {
                if let itemId = track.artworkThumb { image = await self.loadJellyfinArtwork(itemId: itemId) }
            } else if track.embyId != nil {
                if let itemId = track.artworkThumb { image = await self.loadEmbyArtwork(itemId: itemId) }
            } else if track.url.isFileURL {
                image = await self.loadLocalArtwork(url: track.url)
            } else if RadioManager.shared.isActive {
                image = await self.loadRadioArtwork(for: track)
            } else if let thumb = track.artworkThumb {
                image = await self.loadRemoteArtwork(urlString: thumb, cacheNamespace: "generic")
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard WindowManager.shared.audioEngine.currentTrack?.id == track.id,
                      self.artworkDisplayGeneration == displayGeneration else { return }
                self.currentTrackArtwork = image
                self.artworkTrackId = track.id
                self.currentArtwork = image
                self.needsDisplay = true
            }
        }
    }

    private func loadPlexArtwork(ratingKey: String, thumbPath: String? = nil) async -> NSImage? {
        let cacheKey = NSString(string: "plex:\(ratingKey)")
        if let cached = Self.artworkCache.object(forKey: cacheKey) { return cached }
        let thumb = thumbPath ?? "/library/metadata/\(ratingKey)/thumb"
        guard let url = PlexManager.shared.artworkURL(thumb: thumb, size: 400) else { return nil }
        do {
            var request = URLRequest(url: url)
            if let headers = PlexManager.shared.streamingHeaders {
                for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let image = NSImage(data: data) else { return nil }
            Self.artworkCache.setObject(image, forKey: cacheKey); return image
        } catch { return nil }
    }
    
    private func loadSubsonicArtwork(songId: String) async -> NSImage? {
        let cacheKey = NSString(string: "subsonic:\(songId)")
        if let cached = Self.artworkCache.object(forKey: cacheKey) { return cached }
        guard let url = SubsonicManager.shared.coverArtURL(coverArtId: songId, size: 400) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let image = NSImage(data: data) else { return nil }
            Self.artworkCache.setObject(image, forKey: cacheKey); return image
        } catch { return nil }
    }
    
    private func loadJellyfinArtwork(itemId: String) async -> NSImage? {
        let cacheKey = NSString(string: "jellyfin:\(itemId)")
        if let cached = Self.artworkCache.object(forKey: cacheKey) { return cached }
        guard let url = JellyfinManager.shared.imageURL(itemId: itemId, imageTag: nil, size: 400) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let image = NSImage(data: data) else { return nil }
            Self.artworkCache.setObject(image, forKey: cacheKey); return image
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
            Self.artworkCache.setObject(image, forKey: cacheKey); return image
        } catch { return nil }
    }

    private func loadLocalArtwork(url: URL) async -> NSImage? {
        let cacheKey = NSString(string: "local:\(url.path)")
        if let cached = Self.artworkCache.object(forKey: cacheKey) { return cached }
        let asset = AVURLAsset(url: url)
        do {
            let metadata = try await asset.load(.metadata)
            for item in metadata {
                if item.commonKey == .commonKeyArtwork {
                    if let data = try await item.load(.dataValue), let image = NSImage(data: data) {
                        Self.artworkCache.setObject(image, forKey: cacheKey); return image
                    }
                }
            }
        } catch { }
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
    
    private func loadArtworkForSelection() {
        guard showsLegacyArtwork else { return }
        guard let index = selectedIndices.first, index < model.displayItems.count else { return }
        
        let item = model.displayItems[index]
        artworkLoadTask?.cancel()
        artworkDisplayGeneration &+= 1
        let displayGeneration = artworkDisplayGeneration
        
        artworkLoadTask = Task { [weak self] in
            guard let self = self else { return }
            var image: NSImage?
            
            switch item.type {
            case .localMovie, .localShow, .localSeason, .localEpisode:
                // Video artwork is loaded during playback via AVAssetImageGenerator
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
            default:
                image = await self.itemArtwork(for: item).load()
            }

            guard !Task.isCancelled else { return }
            if let image = image {
                await MainActor.run {
                    guard self.artworkDisplayGeneration == displayGeneration else { return }
                    self.currentArtwork = image
                    self.needsDisplay = true
                }
            }
        }
    }
    
    // MARK: - YouTube (shares the Radio tab UI as its own source)

    @objc private func contextMenuSubscribeYouTubeChannel(_ sender: NSMenuItem) {
        guard let channel = sender.representedObject as? YouTubeChannel else { return }
        model.youtubeSearch.subscribe(to: channel)
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
            return ("plex:\(album.id)", { [weak self] in await self?.loadPlexArtwork(ratingKey: album.id, thumbPath: album.thumb) })
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
            return ("subsonic:\(coverArt)", { [weak self] in await self?.loadSubsonicArtwork(songId: coverArt) })
        case .jellyfinAlbum(let album):
            return jellyfinArtwork(album.artworkItemId)
        case .embyAlbum(let album):
            return embyArtwork(album.artworkItemId)
        case .movie(let movie):
            return ("plex:\(movie.id)", { [weak self] in await self?.loadPlexArtwork(ratingKey: movie.id, thumbPath: movie.thumb) })
        case .show(let show):
            return ("plex:\(show.id)", { [weak self] in await self?.loadPlexArtwork(ratingKey: show.id, thumbPath: show.thumb) })
        case .season(let season):
            return ("plex:\(season.id)", { [weak self] in await self?.loadPlexArtwork(ratingKey: season.id, thumbPath: season.thumb) })
        case .episode(let episode):
            return ("plex:\(episode.id)", { [weak self] in await self?.loadPlexArtwork(ratingKey: episode.id, thumbPath: episode.thumb) })
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
            return ("plex:\(artist.id)", { [weak self] in await self?.loadPlexArtwork(ratingKey: artist.id, thumbPath: thumb) })
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
            return ("subsonic:\(coverArt)", { [weak self] in await self?.loadSubsonicArtwork(songId: coverArt) })
        case .jellyfinArtist(let artist):
            return jellyfinArtwork(artist.artworkItemId)
        case .embyArtist(let artist):
            return embyArtwork(artist.artworkItemId)
        case .track(let track):
            guard let thumb = track.thumb else { return ("plex:\(track.id)", { nil }) }
            return ("plex:\(track.id)", { [weak self] in await self?.loadPlexArtwork(ratingKey: track.id, thumbPath: thumb) })
        case .localTrack(let track):
            return ("local:\(track.url.path)", { [weak self] in await self?.loadLocalArtwork(url: track.url) })
        case .subsonicTrack(let song):
            guard let coverArt = song.coverArt else { return (nil, { nil }) }
            return ("subsonic:\(coverArt)", { [weak self] in await self?.loadSubsonicArtwork(songId: coverArt) })
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

    private func playRadioStation(_ station: RadioStation) { RadioManager.shared.play(station: station) }
    private func playPlexRadioStation(_ radioType: PlexRadioType) {
        radioPlayTask?.cancel()
        model.isLoading = true; startLoadingAnimation(); needsDisplay = true
        radioPlayTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            var tracks: [Track] = []
            switch radioType {
            case .libraryRadio: tracks = await PlexManager.shared.createLibraryRadio()
            case .libraryRadioSonic: tracks = await PlexManager.shared.createLibraryRadioSonic()
            case .hitsRadio: tracks = await PlexManager.shared.createHitsRadio()
            case .hitsRadioSonic: tracks = await PlexManager.shared.createHitsRadioSonic()
            case .deepCutsRadio: tracks = await PlexManager.shared.createDeepCutsRadio()
            case .deepCutsRadioSonic: tracks = await PlexManager.shared.createDeepCutsRadioSonic()
            case .genreRadio(let g): tracks = await PlexManager.shared.createGenreRadio(genre: g)
            case .genreRadioSonic(let g): tracks = await PlexManager.shared.createGenreRadioSonic(genre: g)
            case .decadeRadio(let s, let e, _): tracks = await PlexManager.shared.createDecadeRadio(startYear: s, endYear: e)
            case .decadeRadioSonic(let s, let e, _): tracks = await PlexManager.shared.createDecadeRadioSonic(startYear: s, endYear: e)
            case .ratingRadio(let r, _): tracks = await PlexManager.shared.createRatingRadio(minRating: r)
            case .ratingRadioSonic(let r, _): tracks = await PlexManager.shared.createRatingRadioSonic(minRating: r)
            }
            guard !Task.isCancelled else { return }
            guard !tracks.isEmpty else {
                self.model.isLoading = false; self.stopLoadingAnimation(); self.needsDisplay = true
                return
            }
            WindowManager.shared.audioEngine.loadTracks(tracks)
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
            case .libraryRadio: tracks = await SubsonicManager.shared.createLibraryRadio()
            case .librarySimilar: tracks = await SubsonicManager.shared.createLibraryRadioSimilar()
            case .genreRadio(let g): tracks = await SubsonicManager.shared.createGenreRadio(genre: g)
            case .genreSimilar(let g): tracks = await SubsonicManager.shared.createGenreRadioSimilar(genre: g)
            case .decadeRadio(let s, let e, _): tracks = await SubsonicManager.shared.createDecadeRadio(start: s, end: e)
            case .decadeSimilar(let s, let e, _): tracks = await SubsonicManager.shared.createDecadeRadioSimilar(start: s, end: e)
            case .starredRadio: tracks = await SubsonicManager.shared.createRatingRadio()
            case .starredSimilar: tracks = await SubsonicManager.shared.createRatingRadioSimilar()
            }
            guard !Task.isCancelled else { return }
            guard !tracks.isEmpty else {
                self.model.isLoading = false; self.stopLoadingAnimation(); self.needsDisplay = true
                return
            }
            WindowManager.shared.audioEngine.loadTracks(tracks)
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
            case .libraryRadio: tracks = await JellyfinManager.shared.createLibraryRadio()
            case .libraryInstantMix: tracks = await JellyfinManager.shared.createLibraryRadioInstantMix()
            case .genreRadio(let g): tracks = await JellyfinManager.shared.createGenreRadio(genre: g)
            case .genreInstantMix(let g): tracks = await JellyfinManager.shared.createGenreRadioInstantMix(genre: g)
            case .decadeRadio(let s, let e, _): tracks = await JellyfinManager.shared.createDecadeRadio(start: s, end: e)
            case .decadeInstantMix(let s, let e, _): tracks = await JellyfinManager.shared.createDecadeRadioInstantMix(start: s, end: e)
            case .favoritesRadio: tracks = await JellyfinManager.shared.createFavoritesRadio()
            case .favoritesInstantMix: tracks = await JellyfinManager.shared.createFavoritesRadioInstantMix()
            }
            guard !Task.isCancelled else { return }
            guard !tracks.isEmpty else {
                self.model.isLoading = false; self.stopLoadingAnimation(); self.needsDisplay = true
                return
            }
            WindowManager.shared.audioEngine.loadTracks(tracks)
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
            case .libraryRadio: tracks = await EmbyManager.shared.createLibraryRadio()
            case .libraryInstantMix: tracks = await EmbyManager.shared.createLibraryRadioInstantMix()
            case .genreRadio(let g): tracks = await EmbyManager.shared.createGenreRadio(genre: g)
            case .genreInstantMix(let g): tracks = await EmbyManager.shared.createGenreRadioInstantMix(genre: g)
            case .decadeRadio(let s, let e, _): tracks = await EmbyManager.shared.createDecadeRadio(start: s, end: e)
            case .decadeInstantMix(let s, let e, _): tracks = await EmbyManager.shared.createDecadeRadioInstantMix(start: s, end: e)
            case .favoritesRadio: tracks = await EmbyManager.shared.createFavoritesRadio()
            case .favoritesInstantMix: tracks = await EmbyManager.shared.createFavoritesRadioInstantMix()
            }
            guard !Task.isCancelled else { return }
            guard !tracks.isEmpty else {
                self.model.isLoading = false; self.stopLoadingAnimation(); self.needsDisplay = true
                return
            }
            WindowManager.shared.audioEngine.loadTracks(tracks)
            self.model.isLoading = false; self.stopLoadingAnimation(); self.needsDisplay = true
            self.radioPlayTask = nil
        }
    }

    private func playLocalRadioStation(_ radioType: LocalRadioType) {
        let tracks: [Track]
        switch radioType {
        case .libraryRadio: tracks = MediaLibrary.shared.createLocalLibraryRadio()
        case .genreRadio(let g): tracks = MediaLibrary.shared.createLocalGenreRadio(genre: g)
        case .decadeRadio(let s, let e, _): tracks = MediaLibrary.shared.createLocalDecadeRadio(start: s, end: e)
        }
        if !tracks.isEmpty {
            WindowManager.shared.audioEngine.loadTracks(tracks)
        }
    }

    private func handleDoubleClick(on item: LibraryBrowserItem) {
        switch item.type {
        case .track, .album, .plexPlaylist, .localTrack, .localAlbum, .localPlaylist, .localPlaylistTrack,
             .subsonicTrack, .subsonicAlbum, .subsonicPlaylist, .jellyfinTrack, .jellyfinAlbum, .jellyfinPlaylist,
             .embyTrack, .embyAlbum, .embyPlaylist, .movie, .episode, .localMovie, .localEpisode,
             .jellyfinMovie, .jellyfinEpisode, .embyMovie, .embyEpisode:
            if let playable = playable(for: item) { TrackVerb.play.run(playable) }
        case .artist(let a): if model.browseMode == .search { model.navigateToArtistFromSearch(id: a.id, name: a.title) } else { model.toggleExpand(item) }
        case .show: model.toggleExpand(item)
        case .season: model.toggleExpand(item)
        case .header: break
        case .localArtist(let a): if model.browseMode == .search { model.navigateToArtistFromSearch(id: item.id, name: a.name) } else { model.toggleExpand(item) }
        case .localFolder: model.toggleExpand(item)
        case .localShow: model.toggleExpand(item)
        case .localSeason: model.toggleExpand(item)
        case .subsonicArtist(let a): if model.browseMode == .search { model.navigateToArtistFromSearch(id: a.id, name: a.name) } else { model.toggleExpand(item) }
        case .jellyfinArtist(let a): if model.browseMode == .search { model.navigateToArtistFromSearch(id: a.id, name: a.name) } else { model.toggleExpand(item) }
        case .jellyfinShow: model.toggleExpand(item)
        case .jellyfinSeason: model.toggleExpand(item)
        case .embyArtist(let a): if model.browseMode == .search { model.navigateToArtistFromSearch(id: a.id, name: a.name) } else { model.toggleExpand(item) }
        case .embyShow: model.toggleExpand(item)
        case .embySeason: model.toggleExpand(item)
        case .radioStation(let s): playRadioStation(s)
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
        case .plexRadioStation(let r): playPlexRadioStation(r)
        case .subsonicRadioStation(let r): playSubsonicRadioStation(r)
        case .jellyfinRadioStation(let r): playJellyfinRadioStation(r)
        case .embyRadioStation(let r): playEmbyRadioStation(r)
        case .localRadioStation(let r): playLocalRadioStation(r)
        }
    }
}

// MARK: - Tags Panel Cleanup

extension ModernLibraryBrowserView {
    func tagsPanelDidClose(_ panel: TagsPanel) {
        if panel === activeTagsPanel { activeTagsPanel = nil }
    }
}

