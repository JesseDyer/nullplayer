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
class ClassicLibraryBrowserView: NSView {
    
    // MARK: - Properties
    
    weak var controller: ClassicLibraryBrowserWindowController?

    /// The browser's source, tab, rows and caches; this view draws them. Column visibility and
    /// the tab-slot choices are kept apart from the modern browser's, under "Classic" keys.
    let model = LibraryBrowserModel(keyPrefix: "Classic")

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

    /// The bottom of the tab bar, or of the search bar in search mode.
    private var listTopY: CGFloat {
        Layout.titleBarHeight + Layout.serverBarHeight + Layout.tabBarHeight
            + (model.browseMode == .search ? Layout.searchBarHeight : 0)
    }

    /// Where the list sits, in skin coordinates (top-left origin).
    private func listLayout() -> LibraryBrowserListLayout {
        let size = originalWindowSize
        let (columns, group) = list.headerColumns()
        return LibraryBrowserListLayout(
            content: NSRect(x: Layout.leftBorder, y: listTopY,
                            width: size.width - Layout.leftBorder - Layout.rightBorder,
                            height: size.height - listTopY - Layout.statusBarHeight),
            bannerHeight: model.offlineBannerText == nil ? 0 : 18 * contentScale,
            columns: columns, group: group, headerHeight: columnHeaderHeight,
            scrollbarWidth: Layout.scrollbarWidth, alphabetWidth: Layout.alphabetWidth, alphabetBesideHeader: true,
            rowHeight: itemHeight, scale: contentScale, isFlipped: true
        )
    }

    /// What the rows do and the menus that offer it.
    private lazy var actions: LibraryBrowserActions = LibraryBrowserActions(model: model, host: .init(
        view: { [unowned self] in self },
        presentLinkSheet: { [unowned self] in presentLinkSheet() },
        ratingStarColor: { NSColor(srgbRed: 0.98, green: 0.78, blue: 0.20, alpha: 1.0) },
        busyChanged: { [unowned self] in coordinator.busyChanged() }
    ))

    /// Routes the model's changes, the window's events and the clicks above the list, and runs the
    /// names' scroll and the spinners. The controls are drawn here in skin coordinates, which
    /// `coordinator.rects` records.
    private lazy var coordinator = LibraryBrowserCoordinator(view: self, model: model, actions: actions, list: list, host: .init(
        redraw: { [unowned self] region in
            switch region {
            case .all:
                needsDisplay = true
            case .list:
                // Only the list area, so menu items don't shimmer on non-Retina displays.
                let area = listLayout().area
                setNeedsDisplay(convertFromSkinCoordinates(NSRect(x: 0, y: area.minY, width: bounds.width, height: area.height)))
            case .serverBar:
                setNeedsDisplay(NSRect(x: 0, y: bounds.height - Layout.titleBarHeight - Layout.serverBarHeight,
                                       width: bounds.width, height: Layout.serverBarHeight))
            }
        },
        updateHistory: { [unowned self] in updateHistoryHostingVisibility() },
        visibilityChanged: { [unowned self] in backdrop.reload() }
    ))

    private var historyHostingView: NSHostingView<StatsContentView>?

    /// Cached skin renderer — avoids recreating (and discarding its whiteTextImage cache) every frame
    private var cachedRenderer: SkinRenderer?
    private var cachedRendererSkinPath: String?

    /// Scrolling, clicks, keys and menus on the rows, and Flow / Tiles standing in for them.
    /// Classic's taller, freely stretchable window keeps the Flow label under the centred cover.
    private lazy var list = LibraryBrowserList(
        view: self, model: model, actions: actions, art: art, flowLabelPlacement: .belowCenteredCover, host: .init(
            layout: { [unowned self] in listLayout() },
            artStyle: { [unowned self] in
                let colors = currentPlaylistColors()
                return LibraryArtStyle(
                    titleColor: colors.normalText,
                    subtitleColor: colors.normalText.withAlphaComponent(0.6),
                    placeholderFill: colors.normalBackground.blended(withFraction: 0.15, of: .white) ?? colors.normalBackground,
                    placeholderTextColor: colors.normalText.withAlphaComponent(0.6)
                )
            },
            // Neither an embedded `.wal` browser nor Compact Mode has a library backdrop to offer.
            backdropMenu: { [unowned self] in
                controller?.isCompactMode == false
                    ? ContextMenuBuilder.browserBackdropMenuItem(compact: false, presenter: backdropPresenter) : nil
            }
        ))

    /// Button being pressed (for visual feedback)
    private var pressedButton: SkinRenderer.PlexBrowserButtonType?
    
    /// Window dragging state
    private var isDraggingWindow = false
    private var windowDragStartPoint: NSPoint = .zero
    /// Embedded in a `.wal` holder there is no title bar of ours, so background the browser does not
    /// consume — the blank area below the last row — moves the skin's window instead (B60).
    private var embeddedWindowDrag = WinampModernHostedWindowDrag()

    // MARK: - Art

    /// Row art and the art drawn behind the list.
    private lazy var art = LibraryBrowserArt(model: model,
                                             isBackgroundEnabled: { WindowManager.shared.libraryBackdropMode.showsArt })
    private let rowThumbnails = LibraryRowThumbnailTracker()

    // MARK: - Cava backdrop

    /// Cava beneath the list, in a sibling view the controller's content container holds. It
    /// covers the list alone, so a hosted frame's keyed-out corners stay clear.
    private lazy var backdrop = BrowserBackdrop(
        mode: { WindowManager.shared.libraryBackdropMode }, look: Self.backdropLook,
        region: { [weak self] in
            guard let self else { return .zero }
            return convert(convertFromSkinCoordinates(listLayout().area), to: superview)
        })
    var backdropPresenter: CavaPresenter? { backdrop.presenter }
    private static let backdropScrimAlpha: CGFloat = 0.72

    /// Cava shows in a library window of its own: never embedded in a `.wal` holder (which has no
    /// controller) or in Compact Mode.
    private var showsCavaBackdrop: Bool {
        controller?.isCompactMode == false && WindowManager.shared.libraryBackdropMode.showsCava
    }

    /// The list's background: translucent over a Cava backdrop, so the bars show through.
    private func listBackground(_ colors: PlaylistColors) -> NSColor {
        let base = colors.normalBackground
        return showsCavaBackdrop ? base.withAlphaComponent(base.alphaComponent * Self.backdropScrimAlpha) : base
    }

    /// The backdrop mode, skin or window changed: show, restyle or remove the backdrop.
    func refreshBackdrop() {
        guard controller != nil else { return }
        refreshHistoryHostingColors()
        art.showPlayingTrack(WindowManager.shared.audioEngine.currentTrack)
        backdrop.refresh(beneath: self, showsCava: showsCavaBackdrop, scope: .libraryWindow, sharpCorners: [])
        needsDisplay = true
    }

    func stopBackdrop() {
        backdrop.stop()
    }

    /// The classic look for the Cava backdrop: the hosted surface style's in a `.wal`, `.wmz` or
    /// Audion window, else the playlist colours and the Winamp Green bars, as the Cava window uses.
    private static func backdropLook() -> BrowserBackdropLook {
        if let style = WindowManager.shared.hostedSurfaceStyle {
            return BrowserBackdropLook(background: style.playlistColors.normalBackground,
                                       low: style.visualizationLow, high: style.visualizationHigh, cornerRadius: 0)
        }
        let skin = WindowManager.shared.currentSkin ?? SkinLoader.shared.loadDefault()
        let green = CavaSettings.scheme(named: "Winamp Green")
        return BrowserBackdropLook(background: skin.playlistColors.normalBackground,
                                   low: green?.low ?? .green, high: green?.high ?? .green, cornerRadius: 0)
    }
    
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
        list.lens.restyle()
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

    /// The server-name field's width, in characters: Plex's is narrower.
    private var serverFieldChars: CGFloat {
        model.currentSource.isPlex ? 12 : 20
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
        if list.lens.hasItems {
            rightWidth += 12 + viewModeButtonsWidth(textScale: textScale, chromeScale: 1)
        }

        let leftWidth: CGFloat
        switch model.sourceBarContent {
        case .builtIn(let name):
            leftWidth = leadingInset + prefixWidth + textWidth(model.withItemCount(name)) + 28 + textWidth("+ADD")
        case .server:
            leftWidth = leadingInset + prefixWidth + serverFieldChars * charWidth + 16 +

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
    /// `ClassicLibraryBrowserWindowController` here: the palette and the content scale come from the skin, and
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

        // Register for drag and drop (local files)
        registerForDraggedTypes([.fileURL])

        coordinator.start()

        // Load artwork for currently playing track (if any)
        art.onBackgroundChange = { [weak self] in self?.needsDisplay = true }
        art.showPlayingTrack(WindowManager.shared.audioEngine.currentTrack)

        // Set up accessibility identifiers for UI testing
        setupAccessibility()
        updateHistoryHostingVisibility()
    }

    // MARK: - Accessibility

    /// Set up accessibility identifiers for UI testing
    private func setupAccessibility() {
        setAccessibilityIdentifier("plexBrowserView")
        setAccessibilityRole(.group)
        setAccessibilityLabel("Plex Browser")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        backdrop.stop()
    }

    /// Synchronously cancel every in-flight task, work item, and timer this view and its model
    /// own so they can be deallocated immediately when the controller is torn down for a UI
    /// reload — rather than being pinned alive (and mutating dead UI state) by a detached
    /// `@MainActor` expand/load task or a self-retaining repeating timer. `deinit` is deferred by
    /// AppKit's autorelease pool, so `WindowManager.teardownModeDependentWindows()` calls this
    /// *before* closing the window.
    func prepareForUITeardown() {
        coordinator.teardown()
        art.cancel()
        backdrop.remove()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        coordinator.startMarquee()
        updateHistoryHostingFrame()
        list.clampHorizontalScrollOffset()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        refreshBackdrop()
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
        StatsContentView(agent: model.history,
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
        hostingView.layer?.backgroundColor = listBackground(colors).cgColor
        hostingView.layer?.isOpaque = !showsCavaBackdrop
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
        backdrop.updateFrame()
        // Flow / Tiles leave the alphabet index beside them, and the offline banner below.
        let bannerHeight = listLayout().banner?.height ?? 0
        list.lens.frame = embeddedContentRect()
            .divided(atDistance: Layout.alphabetWidth * scaleFactor, from: .maxXEdge).remainder
            .divided(atDistance: bannerHeight, from: .minYEdge).remainder
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
                drawWindowChromeIfNeeded(renderer: renderer, context: context, bounds: drawBounds,
                                         isActive: isActive, scrollPosition: list.scrollPosition)
                drawServerBar(in: context, drawBounds: drawBounds, colors: colors, renderer: renderer)
            } else {
                // Draw window frame using skin sprites
                drawWindowChromeIfNeeded(renderer: renderer, context: context, bounds: drawBounds,
                                         isActive: isActive, scrollPosition: list.scrollPosition)

                // The list goes translucent over a Cava backdrop, which shows through it.
                if showsCavaBackdrop {
                    context.saveGState()
                    context.setBlendMode(.copy)
                    listBackground(colors).setFill()
                    context.fill(listLayout().area)
                    context.restoreGState()
                }

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

                    // The Data tab's SwiftUI-hosted history content is rendered via an embedded subview.
                    if !model.browseMode.isHistoryMode {
                        switch model.listState {
                        case .notLinked:
                            drawNotLinkedState(in: context, colors: colors, renderer: renderer)
                        case .loading:
                            drawLoadingState(in: context, colors: colors, renderer: renderer)
                        case .error(let error):
                            drawErrorState(in: context, message: error, colors: colors, renderer: renderer)
                        case .rows where list.lens.isPresenting:
                            // The Flow / Tiles view renders the art; just fill the list area
                            // background so the interior isn't left stale behind it.
                            let layout = listLayout()
                            if !showsCavaBackdrop {
                                colors.normalBackground.setFill()
                                context.fill(layout.area)
                            }
                            drawAlphabetIndex(in: context, rect: layout.alphabet, colors: colors, renderer: renderer)
                        case .rows:
                            drawListArea(in: context, layout: listLayout(), colors: colors, renderer: renderer)
                        }
                    }

                    // Offline volume banner (local source only, under the list)
                    if let banner = listLayout().banner, let label = model.offlineBannerText {
                        drawOfflineBanner(label, in: context, rect: banner, colors: colors)
                    }

                    // Draw status bar text
                    drawStatusBarText(in: context, drawBounds: drawBounds, colors: colors, renderer: renderer)
                }
            }

        context.restoreGState()

        if coordinator.isHighlighted {
            NSColor.white.withAlphaComponent(0.15).setFill()
            bounds.fill()
        }
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
        guard list.lens.hasItems else { return trailingX }
        let side = viewModeIconSide(textScale: textScale)
        let leadingX = trailingX - 12 * chromeScale - viewModeButtonsWidth(textScale: textScale, chromeScale: chromeScale)
        let colors = currentPlaylistColors()
        var x = leadingX
        for mode in LibraryViewMode.allCases {
            // Centred on the bitmap text's line, padded out to a comfortable hit target.
            let icon = NSRect(x: x, y: textY - textScale, width: side, height: side)
            mode.drawIcon(in: icon, color: list.lens.mode == mode ? colors.currentText : colors.normalText,
                          context: context)
            coordinator.rects.viewModes.append((mode, icon.insetBy(dx: -1.5 * chromeScale, dy: -3 * textScale)))
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
        
        coordinator.beginServerBar(in: NSRect(x: 0, y: barY, width: drawBounds.width, height: Layout.serverBarHeight))

        let content = model.sourceBarContent
        if case .unconfigured(let prompt) = content {
            let promptWidth = ClassicLibraryTab.textWidth(prompt, scale: textScale, style: winampModernStyle)
            drawScaledSkinText(prompt, at: NSPoint(x: barRect.midX - promptWidth / 2, y: textY), scale: textScale, renderer: renderer, in: context)
            coordinator.rects.source = barRect
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
        coordinator.rects.refresh = NSRect(x: refreshX, y: barRect.minY, width: refreshWidth, height: barRect.height)
        let accessoryX = drawViewModeButtons(
            before: refreshX, textY: textY, textScale: textScale, chromeScale: chromeScale,
            context: context
        )

        switch content {
        case .builtIn(let name):
            let sourceText = model.withItemCount(name)
            drawScaledWhiteSkinText(sourceText, at: NSPoint(x: sourceNameStartX, y: textY), scale: textScale, renderer: renderer, in: context)
            let sourceTextWidth = ClassicLibraryTab.textWidth(sourceText, scale: textScale, style: winampModernStyle)
            coordinator.rects.source = NSRect(x: barRect.minX, y: barRect.minY,
                                      width: sourceNameStartX + sourceTextWidth - barRect.minX,
                                      height: barRect.height)

            // +ADD button after source name with balanced spacing (green text)
            let addText = "+ADD"
            let addX = sourceNameStartX + sourceTextWidth + 28 * chromeScale
            drawScaledSkinText(addText, at: NSPoint(x: addX, y: textY), scale: textScale, renderer: renderer, in: context)
            coordinator.rects.add = NSRect(x: addX, y: barRect.minY,
                                   width: ClassicLibraryTab.textWidth(addText, scale: textScale, style: winampModernStyle) + 8 * chromeScale,
                                   height: barRect.height)

            // Scan animation: small spinner at center of bar while library is scanning
            if case .local = model.currentSource, coordinator.isLibraryScanning {
                let outerR: CGFloat = 8
                coordinator.drawSpinner(in: context, center: CGPoint(x: barRect.midX, y: barRect.midY),
                                        innerRadius: 3, outerRadius: outerR, lineWidth: 2,
                                        color: accentTextColor(renderer), maxAlpha: 0.9)
                let scanText = "SCANNING"
                let scanX = barRect.midX + outerR + 6
                drawScaledSkinText(scanText, at: NSPoint(x: scanX, y: textY), scale: textScale, renderer: renderer, in: context)
            }

        case .server(let serverName, let library):
            coordinator.showNames(server: serverName, library: library)

            // Server name right after "Source:", in a fixed-width field
            let serverNameMaxWidth = serverFieldChars * scaledCharWidth
            let serverCycle = drawScrollingText(serverName, startX: sourceNameStartX, textY: textY,
                              availableWidth: serverNameMaxWidth, scale: textScale,
                              scrollOffset: coordinator.serverName.offset,
                              renderer: renderer, in: context)

            // Library label and name after the server field
            let libLabel = "Lib:"
            let libraryLabelX = sourceNameStartX + serverNameMaxWidth + 16 * chromeScale
            drawScaledSkinText(libLabel, at: NSPoint(x: libraryLabelX, y: textY), scale: textScale, renderer: renderer, in: context)

            let libraryX = libraryLabelX + ClassicLibraryTab.textWidth(libLabel, scale: textScale, style: winampModernStyle) + 4 * chromeScale
            let libraryText = model.withItemCount(library)
            // The field grows into the free space before the right cluster; it scrolls when even that is short.
            let libraryNameMaxWidth = max(Self.minLibraryFieldChars * scaledCharWidth, accessoryX - 24 * chromeScale - libraryX)
            let libraryCycle = drawScrollingText(libraryText, startX: libraryX, textY: textY,
                              availableWidth: libraryNameMaxWidth, scale: textScale,
                              scrollOffset: coordinator.libraryName.offset,
                              renderer: renderer, in: context)

            coordinator.rects.source = NSRect(x: barRect.minX, y: barRect.minY,
                                      width: libraryLabelX - barRect.minX,
                                      height: barRect.height)
            coordinator.rects.library = NSRect(x: libraryLabelX, y: barRect.minY,
                                       width: libraryX + libraryNameMaxWidth - libraryLabelX,
                                       height: barRect.height)
            coordinator.namesDrawn(serverCycle: serverCycle, libraryCycle: libraryCycle)

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
        coordinator.rects.tabs.removeAll(keepingCapacity: true)
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
            coordinator.rects.tabs.append(tabRect)
        }
        
        // Draw sort indicator on the right
        let sortRect = NSRect(x: tabBarRect.maxX - tabRightInset - sortWidth,
                              y: tabBarY, width: sortWidth, height: Layout.tabBarHeight)
        coordinator.rects.sort = sortRect
        let rawSortX = sortRect.minX + 4 * chromeScale
        let rawSortY = tabBarY + (Layout.tabBarHeight - scaledCharHeight) / 2
        let sortX = shouldRound ? round(rawSortX) : rawSortX
        let sortY = shouldRound ? round(rawSortY) : rawSortY
        drawScaledSkinText(sortText, at: NSPoint(x: sortX, y: sortY), scale: textScale, renderer: renderer, in: context)

    }
    
    private func drawSearchBar(in context: CGContext, drawBounds: NSRect, colors: PlaylistColors, renderer: SkinRenderer) {
        let searchY = listTopY - Layout.searchBarHeight
        coordinator.rects.searchBar = NSRect(x: 0, y: searchY, width: drawBounds.width, height: Layout.searchBarHeight)
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
        
        // The same size as the server bar's and tab labels' text, following UI Size.
        let textScale = bitmapTextScale
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
        coordinator.drawSpinner(in: context, center: CGPoint(x: listRect.midX, y: listRect.midY),
                                innerRadius: 5, outerRadius: 12, lineWidth: 2.5, color: colors.normalText)
    }

    /// Small inline spinner used on a downloading YouTube video row.
    private func drawRowSpinner(in context: CGContext, center: CGPoint, radius: CGFloat, colors: PlaylistColors) {
        coordinator.drawSpinner(in: context, center: center, innerRadius: radius * 0.45, outerRadius: radius,
                                lineWidth: 1.5, color: colors.normalText)
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
        let message = model.emptyMessage(enterKey: "Enter")

        // Draw using green skin text, centered
        let charHeight = SkinElements.TextFont.charHeight
        let textScale = bitmapTextScale
        let scaledCharHeight = charHeight * textScale
        let textWidth = ClassicLibraryTab.textWidth(message, scale: textScale, style: winampModernStyle)
        let textX = listRect.midX - textWidth / 2
        let textY = listRect.midY - scaledCharHeight / 2
        
        drawScaledSkinText(message, at: NSPoint(x: textX, y: textY), scale: textScale, renderer: renderer, in: context)
    }
    
    private func drawListArea(in context: CGContext, layout: LibraryBrowserListLayout, colors: PlaylistColors, renderer: SkinRenderer) {
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
        if backingScale < 1.5 && !showsCavaBackdrop {
            colors.normalBackground.setFill()
            context.fill(listRect)
        }
        
        art.drawBackground(in: context, rect: listRect, flipped: true)

        // Draw items
        // Round scroll offset to integer pixels to prevent text shimmering on non-Retina displays
        let scrollOffset = list.scrollOffset
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

            // Dim tracks/episodes whose file lives on an offline volume
            let isOffline = model.isOffline(item)
            if isOffline { context.saveGState(); context.setAlpha(0.35) }
            defer { if isOffline { context.restoreGState() } }
            
            // On non-Retina displays, fill item background to prevent gaps/lines
            // BUT skip this when artwork background is showing (it already provides a continuous background)
            // On Retina, only fill background for selected items
            let hasArtworkBackground = art.background != nil
            if backingScale < 1.5 && !hasArtworkBackground && !showsCavaBackdrop {
                // Fill with normal or selected background (only when no artwork)
                let bgColor = isSelected ? colors.selectedBackground : colors.normalBackground
                bgColor.setFill()
                context.fill(itemRect)
            } else if isSelected {
                colors.selectedBackground.setFill()
                context.fill(itemRect)
            }
            
            if let row = list.rowColumns(for: item, header: layout.header) {

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
                if let thumbnail = art.rowThumbnailSource(for: item) {
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
            art.rowThumbnailSource(for: model.displayItems[$0])
        }
        
        context.restoreGState()
        
        drawAlphabetIndex(in: context, rect: layout.alphabet, colors: colors, renderer: renderer)
    }
    
    /// Draw column headers with separator line and resize handles
    private func drawColumnHeaders(in context: CGContext, header: LibraryBrowserListLayout.Header, colors: PlaylistColors) {
        let rect = header.rect, columns = header.columns
        // Clip to the header rect to prevent drawing over scrollbar/alphabet index
        context.saveGState()
        context.clip(to: rect)

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
        
        for (index, (column, x, width)) in list.columnSpans(columns, group: header.group, in: rect).enumerated() {
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
            widths: model.widths(of: columns, group: group, available: rect.width),
            titleIndex: columns.firstIndex { $0.id == .title }, indent: indent,
            spansLeadingCells: model.columnGroup(for: item) != group)
        for (column, cell) in zip(columns, cells) {
            let x = rect.minX + cell.start - list.horizontalScrollOffset, width = cell.width
            if column.id == .thumbnail {
                // Inside the counter-flip (y-up), centred on the row so the flip doesn't move it.
                if let thumbnail = art.rowThumbnailSource(for: item) {
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
            if column.id == .title, !hasArtColumn, let thumbnail = art.rowThumbnailSource(for: item) {
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
        let letters = LibraryBrowserList.alphabetLetters
        let letterHeight = rect.height / CGFloat(letters.count)
        let fontSize = min(9 * contentScale, letterHeight * 0.8)
        
        let availableLetters = model.lettersWithRows

        
        for (index, letter) in letters.enumerated() {

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
    
    /// The amber strip under the list while a local watch folder is offline.
    private func drawOfflineBanner(_ label: String, in context: CGContext, rect: NSRect, colors: PlaylistColors) {
        colors.normalBackground.setFill()
        context.fill(rect)
        NSColor.systemOrange.withAlphaComponent(0.18).setFill()
        context.fill(rect)

        // Counter-flip for text
        context.saveGState()
        context.translateBy(x: 0, y: rect.midY)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -rect.midY)
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: colors.normalText,
            .font: contentFont(ofSize: 9)
        ]
        let size = label.size(withAttributes: attrs)
        label.draw(at: NSPoint(x: rect.minX + 6, y: rect.midY - size.height / 2), withAttributes: attrs)
        context.restoreGState()
    }

    private func drawStatusBarText(in context: CGContext, drawBounds: NSRect, colors: PlaylistColors, renderer: SkinRenderer) {
        // Status info is now shown in the top server bar
        // This function is kept for potential future use but draws nothing
    }
    
    // MARK: - Public Methods
    
    func skinDidChange() {
        refreshHistoryHostingColors()
        backdrop.reload()
        list.lens.restyle()
        updateHistoryHostingFrame()
        needsDisplay = true
    }

    private func refreshHistoryHostingColors() {
        guard let historyHostingView else { return }
        let colors = currentPlaylistColors()
        historyHostingView.rootView = makeHistoryRootView(colors)
        historyHostingView.layer?.backgroundColor = listBackground(colors).cgColor
        historyHostingView.layer?.isOpaque = !showsCavaBackdrop
        historyHostingView.appearance = classicAppearance(for: colors.normalBackground)
    }

    
    /// A `.wal` skin switched colour theme; the style is re-derived on each draw, so a repaint is
    /// the whole job.
    @objc private func hostedSurfaceStyleDidChange() {
        hasResolvedWindowWinampModernStyle = false
        // A colour-theme switch recolours the Data tab too. Classic windows resolve no style, and
        // their Data tab is recoloured by `skinDidChange` instead.
        if winampModernStyle != nil { refreshHistoryHostingColors() }
        backdrop.reload()
        // The palette resolved for Flow / Tiles may predate this style (a switch into `.wmz`).
        list.lens.restyle()
        // A borrowed frame moves the content hole this view lays its list and its controls out
        // from, and it lands after the first layout pass — see the same note on the rest of the
        // hosted family (W220).
        needsLayout = true
        needsDisplay = true
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
        let rects = coordinator.rects
        if closesFromCorner, rects.refresh.contains(skinPoint) || rects.viewModes.contains(where: { $0.rect.contains(skinPoint) }) {
            return false
        }
        return closeRect.contains(skinPoint)
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
        let skinPoint = convertToSkinCoordinates(convert(event.locationInWindow, from: nil))
        list.cursor(at: skinPoint).set()
        rowThumbnails.hover(at: list.rowIndex(at: skinPoint) != nil ? skinPoint : nil) {
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
        let skinPoint = convertToSkinCoordinates(convert(event.locationInWindow, from: nil))
        if !list.rightMouseDown(at: skinPoint, event: event) {
            super.rightMouseDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let skinPoint = convertToSkinCoordinates(point)

        // Check window control buttons
        if hitTestCloseButton(at: skinPoint) {
            pressedButton = .close
            needsDisplay = true
            return
        }

        // The server bar, tabs, Sort and search; then the column header, alphabet index and rows
        if coordinator.mouseDown(at: skinPoint, event: event) || list.mouseDown(at: skinPoint, event: event) { return }

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

    override func mouseDragged(with event: NSEvent) {
        if list.mouseDragged(at: convertToSkinCoordinates(convert(event.locationInWindow, from: nil))) { return }
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
        
        list.mouseUp()

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

    // MARK: - Drag and Drop (Local Files and Playlists)
    
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        coordinator.dragOperation(for: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        coordinator.performDrop(sender)
    }
    
    override func scrollWheel(with event: NSEvent) {
        guard list.scrollWheel(event) else {
            if model.browseMode.isHistoryMode { super.scrollWheel(with: event) }
            return
        }
        // The list and the status bar under it, full width so the side borders' scroll thumb follows.
        let area = listLayout().area
        setNeedsDisplay(convertFromSkinCoordinates(NSRect(x: 0, y: area.minY, width: bounds.width,
                                                          height: area.height + Layout.statusBarHeight)))
    }

    // MARK: - Keyboard Events

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if !list.keyDown(event) { super.keyDown(with: event) }
    }
}
