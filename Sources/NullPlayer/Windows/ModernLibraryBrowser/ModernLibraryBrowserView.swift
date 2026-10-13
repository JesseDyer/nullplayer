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

    private var scrollOffset: CGFloat = 0
    private var horizontalScrollOffset: CGFloat = 0
    private let historyAgent = PlayHistoryAgent()
    private var historyHostingView: NSHostingView<StatsContentView>?
    
    private var itemHeight: CGFloat { 18 * ModernSkinElements.sizeMultiplier }
    private var columnHeaderHeight: CGFloat { 18 * ModernSkinElements.sizeMultiplier }
    
    // Column state
    private var resizingColumnId: LibraryBrowserColumn.ID?
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

    /// What the rows do and the menus that offer it.
    private lazy var actions: LibraryBrowserActions = LibraryBrowserActions(model: model, host: .init(
        view: { [unowned self] in self },
        presentLinkSheet: { [unowned self] in controller?.showLinkSheet() },
        ratingStarColor: {
            ModernSkinEngine.shared.currentRenderStyle == .metal
                ? NSColor(calibratedRed: 0.34, green: 0.28, blue: 0.13, alpha: 1.0)
                : NSColor(srgbRed: 0.98, green: 0.78, blue: 0.20, alpha: 1.0)
        },
        busyChanged: { [unowned self] in
            updateLoadingAnimation()
            needsDisplay = true
        }
    ))


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
        selectedIndex: { [unowned self] in model.selectedIndices.min() },
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
    private var isPreparingForUITeardown = false
    private let rowThumbnails = LibraryRowThumbnailTracker()
    
    /// Which edges are adjacent to another docked window (for seamless border rendering)
    private var adjacentEdges: AdjacentEdges = [] { didSet { updateCornerMask() } }
    private var sharpCorners: CACornerMask = [] { didSet { updateCornerMask() } }
    private var edgeOcclusionSegments: EdgeOcclusionSegments = .empty
    
    // Button/drag state
    private var pressedButton: LibraryBrowserButtonType?
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
        

        // Register notifications
        NotificationCenter.default.addObserver(self, selector: #selector(modernSkinDidChange),
                                               name: ModernSkinEngine.skinDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(doubleSizeChanged),
                                               name: .doubleSizeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowLayoutDidChange),
                                               name: .windowLayoutDidChange, object: nil)
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
            // The offline banner (local source, a folder offline) takes list height from Flow / Tiles.
            needsLayout = true
        case .reveal(let index):
            ensureVisible(index: index)
            needsDisplay = true
        case .source:
            artLens.resetNavigation()
            needsLayout = true   // the offline banner shows on the local source only
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
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        stopLoadingAnimation()
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
        currentTrackArtworkLoadTask?.cancel(); artworkLoadTask?.cancel()
        currentTrackArtworkLoadTask = nil; artworkLoadTask = nil
        actions.cancelAll()

        // Timers (timers with a target/captured self can also pin the view alive).
        typeAheadTimer?.invalidate(); typeAheadTimer = nil
        stopLoadingAnimation()
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
            leftWidth = leadingInset + prefixWidth + textWidth(model.withItemCount(name)) + 28 * m + textWidth("+ADD")
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
        let labels = model.tabLabels
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
            let sourceText = model.withItemCount(name)
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
            let libraryText = model.withItemCount(library)
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
            let isSelected = model.selectedIndices.contains(index)

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
            let isCenteredRadioColumn = (model.browseMode == .radio && column.id == .genre) ||
                (model.hasInternetRadioColumns && column.id == .rating)
            
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
        
        let hasArtColumn = columns.contains { $0.id == .thumbnail }
        let cells = LibraryColumnVisibility.cellFrames(
            widths: columns.map { widthForColumn($0, availableWidth: totalWidth, columns: columns, group: group) },
            titleIndex: columns.firstIndex { $0.id == .title }, indent: indent,
            spansLeadingCells: model.columnGroup(for: item) != group)
        for (column, cell) in zip(columns, cells) {
            let x = rect.minX + cell.start - horizontalScrollOffset, width = cell.width
            if column.id == .thumbnail {
                if let thumbnail = rowThumbnailSource(for: item) {
                    rowThumbnails.draw(thumbnail, in: context, at: x + 4, rowRect: rect, side: min(width - 8, rect.height - 2))
                }
                continue
            }
            let value = column.id == .title ? item.shownTitle : item.columnValue(for: column)
            let isCenteredRadioColumn = (model.browseMode == .radio && column.id == .genre) ||
                (model.isInternetRadioItem(item) && column.id == .rating)
            
            let color = column.id == .title ? textColor : dimColor
            let useFont = column.id == .title ? font : smallFont

            let attrs: [NSAttributedString.Key: Any] = [
                .font: useFont,
                .foregroundColor: skin.applyTextOpacity(to: color)
            ]
            // Per-row download spinner on the title column of a downloading YouTube video.
            var titleSpinnerInset: CGFloat = 0
            if column.id == .title, case .youtubeVideo(let video) = item.type,
               actions.youtubeVideos.isFetching(video.videoId) {
                let spinnerRadius = min(rect.height * 0.3, 6)
                let cx = x + 4 + spinnerRadius
                drawRowSpinner(in: context, center: CGPoint(x: cx, y: rect.midY), radius: spinnerRadius, skin: skin)
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
            let maxTextWidth = width - 8 - titleSpinnerInset

            let drawRect = NSRect(x: textX, y: textY, width: maxTextWidth, height: textSize.height)
            if column.id == .rating && !isSelected && value.contains("★") {
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
    
    private func widthForColumn(
        _ column: LibraryBrowserColumn,
        availableWidth: CGFloat,
        columns: [LibraryBrowserColumn],
        group: LibraryColumnVisibilityGroup?
    ) -> CGFloat {
        if column.id == .title {
            // If a stored width exists for the title column (set when user resizes any column), use it
            if let storedWidth = model.storedColumnWidth(for: column, group: group) {
                return max(column.minWidth, storedWidth)
            }
            // Otherwise, title is flexible and fills remaining space
            let fixedWidth = columns.filter { $0.id != .title }.reduce(0) {
                $0 + (model.storedColumnWidth(for: $1, group: group) ?? $1.minWidth)
            }
            return max(column.minWidth, availableWidth - fixedWidth - 8)
        }
        return model.storedColumnWidth(for: column, group: group) ?? column.minWidth
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
            if column.id == .rating {
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
    
    private func hitTestColumnResize(at point: NSPoint) -> LibraryBrowserColumn.ID? {
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
            if index > 0 && column.id == .title {
                if abs(point.x - x) < threshold {
                    return columns[index - 1].id
                }
            }
            x += width
        }
        return nil
    }
    
    private func hitTestColumnHeader(at point: NSPoint) -> LibraryBrowserColumn.ID? {
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
        if hitTestSortIndicator(at: point) { popDown(actions.sortMenu(), from: event); return }
        
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
            if let group, model.storedColumnWidth(for: .title, group: group) == nil {
                let titleWidth = widthForColumn(.title, availableWidth: headerWidth, columns: columns, group: group)
                model.setColumnWidth(titleWidth, for: .title, group: group)
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
            model.setColumnWidth(max(minWidth, resizeStartWidth + deltaX), for: columnId, group: group)
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
            if !model.selectedIndices.contains(clickedIndex) { model.selectedIndices = [clickedIndex]; needsDisplay = true }
            let item = model.displayItems[clickedIndex]
            showContextMenu(for: item, at: event); return
        }
        let menu = actions.emptySpaceMenu() ?? NSMenu()
        prependBackdropMenu(to: menu)
        if !menu.items.isEmpty {
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
                if let index = model.selectedIndices.first, index < model.displayItems.count { actions.activate(model.displayItems[index]) }
            }
        case 124: // Right Arrow — expand or move into first child
            if let index = model.selectedIndices.first, index < model.displayItems.count {
                let item = model.displayItems[index]
                if item.hasChildren {
                    if model.isExpanded(item) {
                        // Move to first child
                        let nextIdx = index + 1
                        if nextIdx < model.displayItems.count {
                            model.selectedIndices = [nextIdx]; ensureVisible(index: nextIdx); loadArtworkForSelection(); needsDisplay = true
                        }
                    } else {
                        model.toggleExpand(item); needsDisplay = true
                    }
                }
            }
        case 123: // Left Arrow — collapse or jump to parent
            if let index = model.selectedIndices.first, index < model.displayItems.count {
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
                        model.selectedIndices = [p]; ensureVisible(index: p); loadArtworkForSelection(); needsDisplay = true
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
                model.selectedIndices.removeAll(); scrollOffset = 0
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
            if let maxIndex = model.selectedIndices.max(), maxIndex < model.displayItems.count - 1 {
                model.selectedIndices = [maxIndex + 1]; ensureVisible(index: maxIndex + 1); loadArtworkForSelection(); needsDisplay = true
            }
        case 126: // Up
            if let minIndex = model.selectedIndices.min(), minIndex > 0 {
                model.selectedIndices = [minIndex - 1]; ensureVisible(index: minIndex - 1); loadArtworkForSelection(); needsDisplay = true
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
            model.selectedIndices = [idx]; ensureVisible(index: idx); loadArtworkForSelection(); needsDisplay = true
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
        return actions.addDroppedItems(items)
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

        if addButtonRect.contains(point), let menu = actions.addMenu() {
            popDown(menu, from: event)
        } else if libraryButtonRect.contains(point), let menu = actions.libraryMenu() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else if sourceButtonRect.contains(point) {
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
                model.selectedIndices = [index]; needsDisplay = true; return
            }
        }
    }
    
    // MARK: - List Click
    
    private func handleListClick(at index: Int, event: NSEvent, point: NSPoint) {
        let item = model.displayItems[index]

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
                model.selectedIndices = [updatedIndex]
            } else {
                model.selectedIndices = [index]
            }
            needsDisplay = true
            return
        }

        if let clickedStar = hitTestInternetRadioRating(at: point, itemIndex: index),
           case .radioStation(let station) = item.type {
            let currentRating = RadioManager.shared.rating(for: station)
            let targetRating = currentRating == clickedStar ? 0 : clickedStar
            RadioManager.shared.setRating(targetRating, for: station)
            model.selectedIndices = [index]
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
            if let lastSelected = model.selectedIndices.max() {
                for i in min(lastSelected, index)...max(lastSelected, index) { model.selectedIndices.insert(i) }
            } else { model.selectedIndices.insert(index) }
        } else if event.modifierFlags.contains(.command) {
            if model.selectedIndices.contains(index) { model.selectedIndices.remove(index) }
            else { model.selectedIndices.insert(index) }
        } else {
            model.selectedIndices = [index]
            if model.browseMode == .search,
               case .radioStation(let station) = item.type,
               event.clickCount == 1 {
                RadioManager.shared.play(station: station)
            } else {
                loadArtworkForSelection()
            }
        }
        
        if event.clickCount == 2 { actions.activate(item) }
        needsDisplay = true
    }
    
    // MARK: - Menus

    private func showColumnConfigMenu(at event: NSEvent) {
        let menu = actions.columnMenu() ?? NSMenu()
        prependBackdropMenu(to: menu)
        guard !menu.items.isEmpty else { return }
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

    private func showContextMenu(for item: LibraryBrowserItem, at event: NSEvent) {
        guard let menu = actions.contextMenu(for: item) else { return }
        prependBackdropMenu(to: menu)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Shift+Enter / Option+Enter: the menu's Play Next / Add to Queue on the selected row.
    private func runVerbOnSelection(_ verb: TrackVerb) {
        guard let index = model.selectedIndices.first, index < model.displayItems.count else { return }
        actions.run(verb, on: model.displayItems[index])
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
            if self.actions.rowsAreBusy {
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

    /// Run the spinner timer while the rows or the library scan have something in flight.
    private func updateLoadingAnimation() {
        if actions.rowsAreBusy || isLibraryScanning { startLoadingAnimation() } else { stopLoadingAnimation() }
    }

    private func stopLoadingAnimation() {
        loadingAnimationTimer?.invalidate(); loadingAnimationTimer = nil; loadingAnimationFrame = 0
    }

    @objc private func libraryScanProgressChanged() {
        let scanning = MediaLibrary.shared.isScanning
        guard scanning != isLibraryScanning else { return }
        isLibraryScanning = scanning
        updateLoadingAnimation()
        if !scanning {
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
                if let itemId = track.artworkThumb { image = await LibraryArtwork.jellyfin(itemId: itemId) }
            } else if track.embyId != nil {
                if let itemId = track.artworkThumb { image = await LibraryArtwork.emby(itemId: itemId) }
            } else if track.url.isFileURL {
                image = await self.loadLocalArtwork(url: track.url)
            } else if RadioManager.shared.isActive {
                image = await LibraryArtwork.radio(for: track)
            } else if let thumb = track.artworkThumb {
                image = await LibraryArtwork.remote(urlString: thumb, cacheNamespace: "generic")
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
        if let cached = LibraryArtwork.cache.object(forKey: cacheKey) { return cached }
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
            LibraryArtwork.cache.setObject(image, forKey: cacheKey); return image
        } catch { return nil }
    }
    
    private func loadSubsonicArtwork(songId: String) async -> NSImage? {
        let cacheKey = NSString(string: "subsonic:\(songId)")
        if let cached = LibraryArtwork.cache.object(forKey: cacheKey) { return cached }
        guard let url = SubsonicManager.shared.coverArtURL(coverArtId: songId, size: 400) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let image = NSImage(data: data) else { return nil }
            LibraryArtwork.cache.setObject(image, forKey: cacheKey); return image
        } catch { return nil }
    }
    
    private func loadLocalArtwork(url: URL) async -> NSImage? {
        let cacheKey = NSString(string: "local:\(url.path)")
        if let cached = LibraryArtwork.cache.object(forKey: cacheKey) { return cached }
        let asset = AVURLAsset(url: url)
        do {
            let metadata = try await asset.load(.metadata)
            for item in metadata {
                if item.commonKey == .commonKeyArtwork {
                    if let data = try await item.load(.dataValue), let image = NSImage(data: data) {
                        LibraryArtwork.cache.setObject(image, forKey: cacheKey); return image
                    }
                }
            }
        } catch { }
        return nil
    }

    private func loadArtworkForSelection() {
        guard showsLegacyArtwork else { return }
        guard let index = model.selectedIndices.first, index < model.displayItems.count else { return }
        
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
            return LibraryArtwork.jellyfinItem(album.artworkItemId)
        case .embyAlbum(let album):
            return LibraryArtwork.embyItem(album.artworkItemId)
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
            return LibraryArtwork.jellyfinItem(artist.artworkItemId)
        case .embyArtist(let artist):
            return LibraryArtwork.embyItem(artist.artworkItemId)
        case .track(let track):
            guard let thumb = track.thumb else { return ("plex:\(track.id)", { nil }) }
            return ("plex:\(track.id)", { [weak self] in await self?.loadPlexArtwork(ratingKey: track.id, thumbPath: thumb) })
        case .localTrack(let track):
            return ("local:\(track.url.path)", { [weak self] in await self?.loadLocalArtwork(url: track.url) })
        case .subsonicTrack(let song):
            guard let coverArt = song.coverArt else { return (nil, { nil }) }
            return ("subsonic:\(coverArt)", { [weak self] in await self?.loadSubsonicArtwork(songId: coverArt) })
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
}
