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
    private lazy var backdrop = BrowserBackdrop(mode: { [weak self] in self?.effectiveBackdropMode ?? .off },
                                                look: Self.backdropLook)

    var backdropPresenter: CavaPresenter? {
        backdrop.presenter
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

    private var historyHostingView: NSHostingView<StatsContentView>?

    private var itemHeight: CGFloat { 18 * ModernSkinElements.sizeMultiplier }
    private var columnHeaderHeight: CGFloat { 18 * ModernSkinElements.sizeMultiplier }

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
    
    /// Scrolling, clicks, keys and menus on the rows, and Flow / Tiles standing in for them.
    private lazy var list = LibraryBrowserList(view: self, model: model, actions: actions, art: art, host: .init(
        layout: { [unowned self] in listLayout() },
        artStyle: { [unowned self] in
            let skin = currentSkin()
            return LibraryArtStyle(titleColor: skin.textColor, subtitleColor: skin.textDimColor,
                                   placeholderFill: skin.surfaceColor, placeholderTextColor: skin.textDimColor)
        },
        backdropMenu: { [unowned self] in
            ContextMenuBuilder.browserBackdropMenuItem(compact: compactMode, presenter: backdropPresenter)
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
    
    /// Row art and the art drawn behind the list.
    private lazy var art = LibraryBrowserArt(model: model, isBackgroundEnabled: { [unowned self] in effectiveBackdropMode.showsArt })
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
        art.onBackgroundChange = { [weak self] in self?.needsDisplay = true }
        art.showPlayingTrack(WindowManager.shared.audioEngine.currentTrack)
        
        // Set accessibility
        setAccessibilityIdentifier("modernLibraryBrowserView")
        setAccessibilityRole(.group)
        setAccessibilityLabel("Library Browser")
        updateCornerMask()
        updateHistoryHostingVisibility()
    }

    /// The model's rows, loading state, source or tab changed.
    private func modelDidChange(_ change: LibraryBrowserModel.Change) {
        list.modelDidChange(change)
        switch change {
        case .rows, .reveal, .columns:
            needsDisplay = true
        case .loading:
            updateLoadingAnimation()
            needsDisplay = true
        case .rowsReplaced:
            if model.browseMode.isHistoryMode { updateHistoryHostingVisibility() }
        case .rebuilt:
            break
        case .loaded, .source:
            // The offline banner (local source, a folder offline) takes list height from Flow / Tiles.
            needsLayout = true
            if case .source = change { startServerNameScroll() }
        case .browseMode:
            updateHistoryHostingVisibility()
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        stopLoadingAnimation()
        stopServerNameScroll()
        backdrop.stop()
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
        art.cancel()
        actions.cancelAll()

        // Timers (timers with a target/captured self can also pin the view alive).
        stopLoadingAnimation()
        stopServerNameScroll()
        backdrop.remove()
        list.teardown()
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
        list.clampHorizontalScrollOffset()
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
        effectiveBackdropMode.showsCava
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
        backdrop.view?.setSharpCorners(sharpCorners)
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
        let rootView = StatsContentView(agent: model.history,
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
        list.lens.frame = listLayout().area.divided(atDistance: Layout.alphabetWidth, from: .maxXEdge).remainder
        updateCompactPlayerBarFrame()
        updateCompactPlaylistFrame()
        backdrop.updateFrame()
    }

    func refreshBackdrop() {
        updateHistoryHostingBackground()
        art.showPlayingTrack(WindowManager.shared.audioEngine.currentTrack)
        backdrop.refresh(beneath: self, showsCava: !isPreparingForUITeardown && backdropActive,
                         scope: backdropScope, sharpCorners: sharpCorners)
    }

    /// The Original or Metal skin's colours and corners for the Cava backdrop.
    private static func backdropLook() -> BrowserBackdropLook {
        let skin = ModernSkinEngine.shared.currentSkin ?? ModernSkinLoader.shared.loadDefault()
        return BrowserBackdropLook(background: skin.backgroundColor, low: skin.primaryColor, high: skin.accentColor,
                                   cornerRadius: skin.config.window.cornerRadius ?? 0)
    }

    func stopBackdrop() {
        backdrop.stop()
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
            if let bannerRect = layout.banner, let label = model.offlineBannerText {
                drawOfflineBanner(label, in: context, rect: bannerRect, skin: skin)
            }

            if model.browseMode.isHistoryMode {
                art.drawBackground(in: context, rect: listRect, flipped: false)
                // SwiftUI-hosted history content is rendered via an embedded subview.
            } else if model.currentSource.isPlex && !PlexManager.shared.isLinked {
                drawNotLinkedState(in: context, listRect: listRect, skin: skin)
            } else if model.isLoading {
                drawLoadingState(in: context, listRect: listRect, skin: skin)
            } else if let error = model.errorMessage {
                drawErrorState(in: context, message: error, listRect: listRect, skin: skin)
            } else if list.lens.isPresenting {
                // The Flow / Tiles view renders the art. Draw nothing here: the window
                // background (already filled above — translucent when a Cava backdrop is active,
                // opaque otherwise) is exactly what should sit behind the covers, so the Cava
                // backdrop shows through at full strength instead of behind a second scrim.
                drawAlphabetIndex(in: context, rect: layout.alphabet, skin: skin)
            } else {
                drawListArea(in: context, layout: layout, skin: skin)
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
        if list.lens.hasItems {
            rightWidth += 12 * m + viewModeButtonsWidth(m: m)
        }

        let leftWidth: CGFloat
        switch model.sourceBarContent {
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
        if list.lens.hasItems {
            let leadingX = refreshX - 12 * hm - viewModeButtonsWidth(m: m)
            var x = leadingX
            for mode in LibraryViewMode.allCases {
                let rect = NSRect(x: x, y: barRect.minY + 3 * m, width: buttonSide, height: buttonSide)
                let color = ModernLibraryTab.drawBox(isActive: list.lens.mode == mode, rect: rect, skin: skin, context: context)
                mode.drawIcon(in: rect.insetBy(dx: buttonSide * 0.28, dy: buttonSide * 0.28),
                              color: skin.applyTextOpacity(to: color), context: context)
                viewModeButtonRects.append((mode, rect))
                x += buttonSide + 2 * m
            }
            visEndX = leadingX
        }

        // Source-specific content
        switch model.sourceBarContent {
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

    private func drawOfflineBanner(_ label: String, in context: CGContext, rect: NSRect, skin: ModernSkin) {
        // Background — amber tint
        NSColor.systemOrange.withAlphaComponent(0.18).setFill()
        context.fill(rect)

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

    private func drawListArea(in context: CGContext, layout: LibraryBrowserListLayout, skin: ModernSkin) {
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
        
        art.drawBackground(in: context, rect: listRect, flipped: false)
        rowThumbnails.beginPass(placeholder: skin.textDimColor.withAlphaComponent(0.15))
        
        // Draw items (bottom-left origin: item 0 at top of list, so we draw from top down)
        let visibleStart = max(0, Int(list.scrollOffset / itemHeight))
        let visibleEnd = min(model.displayItems.count, visibleStart + Int(listRect.height / itemHeight) + 2)
        
        guard visibleStart < visibleEnd else {
            context.restoreGState()
            drawAlphabetIndex(in: context, rect: layout.alphabet, skin: skin)
            return
        }
        
        let font = skin.scaledSystemFont(size: 8)
        let smallFont = skin.scaledSystemFont(size: 7.2)
        
        for index in visibleStart..<visibleEnd {
            let itemRect = layout.rowRect(index, scrollOffset: list.scrollOffset)
            if itemRect.maxY < listRect.minY || itemRect.minY > listRect.maxY { continue }
            let item = model.displayItems[index]
            let isSelected = model.selectedIndices.contains(index)

            // Dim tracks/episodes whose file lives on an offline volume
            let isOffline = model.isOffline(item)
            if isOffline { context.saveGState(); context.setAlpha(0.35) }

            // Selection background - subtle to keep accent text readable.
            // In metal mode, highlight with the green LCD display color (matching the
            // playlist's now-playing row) instead of the metal control fill.
            if isSelected {
                (isMetalRenderStyle ? metalMaterial.displayFill.withAlphaComponent(0.30) : skin.primaryColor.withAlphaComponent(0.06)).setFill()
                context.fill(itemRect)
            }

            if let row = list.rowColumns(for: item, header: layout.header) {

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
                if let thumbnail = art.rowThumbnailSource(for: item) {
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
            art.rowThumbnailSource(for: model.displayItems[$0])
        }
        
        context.restoreGState()
        
        // Draw alphabet index (exclude column header zone so # appears below column headers)
        drawAlphabetIndex(in: context, rect: layout.alphabet, skin: skin)
    }

    // MARK: - Column Headers
    
    private func drawColumnHeaders(in context: CGContext, header: LibraryBrowserListLayout.Header, skin: ModernSkin) {
        let rect = header.rect, columns = header.columns
        context.saveGState()
        context.clip(to: rect)
        
        contentFill(isMetalRenderStyle ? metalControlBandFill : skin.surfaceColor.withAlphaComponent(0.4)).setFill()
        context.fill(rect)

        let headerFont = skin.scaledSystemFont(size: 7.2, weight: .medium)
        let headerColor = skin.textDimColor.withAlphaComponent(0.7)
        let sortedHeaderColor = skin.textColor.withAlphaComponent(0.9)
        let separatorColor = skin.textDimColor.withAlphaComponent(0.2)
        
        for (index, (column, x, width)) in list.columnSpans(columns, group: header.group, in: rect).enumerated() {
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
        let textColor = isSelected ? (isMetalRenderStyle ? skin.textColor : skin.accentColor) : skin.textColor
        let dimColor = isSelected ? (isMetalRenderStyle ? skin.textColor : skin.accentColor) : skin.textDimColor
        let font = skin.scaledSystemFont(size: 8)
        let smallFont = skin.scaledSystemFont(size: 7.2)
        
        let hasArtColumn = columns.contains { $0.id == .thumbnail }
        let cells = LibraryColumnVisibility.cellFrames(
            widths: model.widths(of: columns, group: group, available: rect.width),
            titleIndex: columns.firstIndex { $0.id == .title }, indent: indent,
            spansLeadingCells: model.columnGroup(for: item) != group)
        for (column, cell) in zip(columns, cells) {
            let x = rect.minX + cell.start - list.horizontalScrollOffset, width = cell.width

            if column.id == .thumbnail {
                if let thumbnail = art.rowThumbnailSource(for: item) {
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
            if column.id == .title, !hasArtColumn, let thumbnail = art.rowThumbnailSource(for: item) {
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
        
        let letters = LibraryBrowserList.alphabetLetters
        let letterHeight = rect.height / CGFloat(letters.count)
        let fontSize = min(9 * ModernSkinElements.sizeMultiplier, letterHeight * 0.8)
        let availableLetters = model.lettersWithRows

        for (index, letter) in letters.enumerated() {

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

    /// The bottom of the tab bar, or of the search bar in search mode.
    private var listTopY: CGFloat {
        topChromeBottomY - Layout.serverBarHeight - Layout.tabBarHeight
            - (model.browseMode == .search ? Layout.searchBarHeight : 0)
    }

    private func listLayout() -> LibraryBrowserListLayout {
        let showsBanner = model.offlineBannerText != nil
        let bottomY = contentRegionBottomY + (showsBanner ? Layout.offlineBannerHeight : 0)
        let area = NSRect(x: Layout.borderWidth, y: bottomY,
                          width: bounds.width - Layout.borderWidth * 2, height: listTopY - bottomY)
        // Flow / Tiles draw no column header, so the alphabet index beside them runs full height.
        let (columns, group) = list.headerColumns()
        let headerHeight = columns.isEmpty ? 0 : columnHeaderHeight
        let rows = NSRect(x: area.minX, y: area.minY,
                          width: area.width - Layout.scrollbarWidth - Layout.alphabetWidth,
                          height: area.height - headerHeight)
        return LibraryBrowserListLayout(
            area: area,
            header: columns.isEmpty ? nil : .init(rect: NSRect(x: rows.minX, y: rows.maxY, width: rows.width, height: headerHeight),
                                                  columns: columns, group: group),
            rows: rows,
            alphabet: NSRect(x: rows.maxX, y: rows.minY, width: Layout.alphabetWidth, height: rows.height),
            banner: showsBanner ? NSRect(x: area.minX, y: contentRegionBottomY, width: area.width, height: Layout.offlineBannerHeight) : nil,
            rowHeight: itemHeight, scale: ModernSkinElements.sizeMultiplier, isFlipped: false
        )
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
        
        // The column header, alphabet index and rows
        if list.mouseDown(at: point, event: event) { return }

        // Title bar drag

        if hitTestTitleBar(at: point) {
            isDraggingWindow = true; windowDragStartPoint = event.locationInWindow
            if let window = window { WindowManager.shared.windowWillStartDragging(window, fromTitleBar: true) }
        }
    }
    
    override func mouseDragged(with event: NSEvent) {
        if list.mouseDragged(at: convert(event.locationInWindow, from: nil)) { return }

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
        
        list.mouseUp()
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
        list.cursor(at: point).set()
        rowThumbnails.hover(at: list.rowIndex(at: point) != nil ? point : nil) { window?.convertToScreen(convert($0, to: nil)) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        RowThumbnailPreview.shared.hide()
    }
    
    override func rightMouseDown(with event: NSEvent) {
        if !list.rightMouseDown(at: convert(event.locationInWindow, from: nil), event: event) {
            super.rightMouseDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard list.scrollWheel(event) else {
            if model.browseMode.isHistoryMode { super.scrollWheel(with: event) }
            return
        }
        // The list with its header and the offline banner: a horizontal scroll moves the header too.
        let layout = listLayout()
        setNeedsDisplay(layout.banner.map { layout.area.union($0) } ?? layout.area)
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        if !list.keyDown(event) { super.keyDown(with: event) }
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
            model.refreshCurrentSource()
            return
        }
        if let hit = viewModeButtonRects.first(where: { $0.rect.contains(point) }) {
            list.lens.mode = hit.mode
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
        historyHostingView?.rootView = StatsContentView(agent: model.history,
                                                        skinTextColor: Color(skin.textColor),
                                                        headerTitle: "Library Data",
                                                        heatmapTheme: ContributionHeatmapTheme(modernSkin: skin))
        historyHostingView?.appearance = skinAppearance(for: skin)
        updateHistoryHostingBackground()
        list.lens.restyle()
        backdrop.reload()
        invalidateServerBarFontCache()
        updateCornerMask()
        updateEmbeddedSubviewFrames()
        compactPlayerBar?.skinDidChange()
        needsDisplay = true
    }
    
    @objc private func doubleSizeChanged() {
        modernSkinDidChange()
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

    @objc private func windowDidMiniaturize(_ notification: Notification) {
        guard notification.object as? NSWindow == window else { return }
        stopServerNameScroll()
        backdrop.reload()
    }
    
    @objc private func windowDidDeminiaturize(_ notification: Notification) {
        guard notification.object as? NSWindow == window else { return }
        startServerNameScroll()
        backdrop.reload()
    }
    
    @objc private func windowDidChangeOcclusionState(_ notification: Notification) {
        guard notification.object as? NSWindow == window else { return }
        if window?.occlusionState.contains(.visible) == true {
            startServerNameScroll()
        } else {
            stopServerNameScroll()
        }
        backdrop.reload()
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

}
