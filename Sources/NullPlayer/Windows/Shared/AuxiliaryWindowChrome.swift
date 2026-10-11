import AppKit

/// The titled frame a free-standing NullPlayer window (Sonos, the Equalizer Studio) wears, from
/// whichever renderer the running family lends; the window's content owns no skin assets.
struct AuxiliaryWindowChrome {
    let window: NSWindow?
    let title: String
    private var modern: Bool { WindowManager.shared.isModernUIEnabled }
    /// A `.wmz` session, or a `.wal` one with its palette loaded: the skin's palette in the titleless
    /// gloss frame, and a `.wmz`'s borrowed frame wherever it lends one.
    private var wmp: Bool { SkinnedSurfaceChrome.hidesPaletteTitleBar }
    private var classicScale: CGFloat { WindowManager.shared.playlistChromeScale }
    private var wmpMetrics: SkinnedSurfaceChrome.Metrics {
        SkinnedSurfaceChrome.metrics(for: CGRect(origin: .zero, size: window?.frame.size ?? .zero),
                                     fallback: .spectrumFamily)
    }
    var titleHeight: CGFloat {
        if modern {
            return WindowManager.shared.effectiveHideTitleBars(for: window)
                ? ModernSkinElements.auxiliaryWindowBorderWidth
                : ModernSkinElements.titleBarBaseHeight * ModernSkinElements.scaleFactor
        }
        if wmp { return WindowManager.shared.hideTitleBars ? 0 : wmpMetrics.titleHeight }
        return WindowManager.shared.hideTitleBars ? 0 : SkinElements.SpectrumWindow.Layout.titleBarHeight
    }
    var textColor: NSColor {
        if modern { return ModernSkinEngine.shared.currentSkin?.textColor ?? .labelColor }
        if wmp, let style = WindowManager.shared.hostedSurfaceStyle { return style.text }
        if let style = WindowManager.shared.winampModernSurfaceStyle { return style.text }
        return WindowManager.shared.currentSkin?.playlistColors.normalText ?? .green
    }
    var backgroundColor: NSColor {
        if modern { return ModernSkinEngine.shared.currentSkin?.backgroundColor ?? .black }
        if wmp, let style = WindowManager.shared.hostedSurfaceStyle { return style.background }
        if let style = WindowManager.shared.winampModernSurfaceStyle { return style.background }
        return WindowManager.shared.currentSkin?.playlistColors.normalBackground ?? .black
    }
    func contentRect(_ bounds: NSRect) -> NSRect {
        if wmp {
            let metrics = wmpMetrics
            return NSRect(x: metrics.leftBorder, y: metrics.bottomBorder,
                          width: max(0, bounds.width - metrics.leftBorder - metrics.rightBorder),
                          height: max(0, bounds.height - titleHeight - metrics.bottomBorder))
        }
        let border = modern ? ModernSkinElements.auxiliaryWindowBorderWidth : SkinElements.SpectrumWindow.Layout.leftBorder
        let bottom = modern ? border : SkinElements.SpectrumWindow.Layout.bottomBorder
        return NSRect(x: border, y: bottom, width: max(0, bounds.width - 2 * border),
                      height: max(0, bounds.height - titleHeight - bottom))
    }
    /// Where the content may draw, where that is not simply `contentRect`: inside an Original
    /// frame's rounded border, which the square content rect overlaps at the corners. The other
    /// families' frames are square.
    func contentClip(_ bounds: NSRect) -> CGPath? {
        modern ? ModernAuxiliaryChrome.contentClip(in: bounds, window: window) : nil
    }
    func closeRect(_ bounds: NSRect) -> NSRect {
        if wmp {
            // Stated top-left, like the chrome that draws it; flipped into the view's space. A
            // titleless palette frame keeps its corner hit area, so this never waits on a title bar.
            let rect = SkinnedSurfaceChrome.closeButtonRect(in: bounds, captionHeight: titleHeight)
            return NSRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
        guard titleHeight > 4 else { return .zero }
        let size: CGFloat = modern ? 14 * ModernSkinElements.scaleFactor : 9 * classicScale
        return NSRect(x: bounds.maxX - size - (modern ? 5 : 3) * (modern ? ModernSkinElements.scaleFactor : classicScale),
                      y: bounds.maxY - titleHeight + (titleHeight - size) / 2, width: size, height: size)
    }
    func draw(_ bounds: NSRect, closePressed: Bool) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if modern {
            ModernAuxiliaryChrome.draw(in: bounds, window: window, title: title, closePressed: closePressed,
                                   titleHeight: titleHeight, closeRect: closeRect(bounds), context: context)
            return
        }
        if wmp, let style = WindowManager.shared.hostedSurfaceStyle {
            drawWMP(bounds, style: style, closePressed: closePressed, context: context)
            return
        }
        let skin = WindowManager.shared.currentSkin ?? SkinLoader.shared.loadDefault()
        (WindowManager.shared.winampModernSurfaceStyle?.background ?? skin.playlistColors.normalBackground).setFill()
        bounds.fill()
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        if WindowManager.shared.hideTitleBars {
            context.translateBy(x: 0, y: -SkinElements.SpectrumWindow.Layout.titleBarHeight)
        }
        if let style = WindowManager.shared.winampModernSurfaceStyle {
            WinampModernChrome(style: style).drawSpectrumFamilyWindow(
                in: context, bounds: bounds, metrics: .spectrumFamily,
                isActive: window?.isKeyWindow ?? false, isClosePressed: closePressed,
                controlScale: classicScale, title: title, fillBackground: false)
        } else {
            SkinRenderer(skin: skin).drawSpectrumAnalyzerWindowChromeOverlay(
                in: context, bounds: bounds, isActive: window?.isKeyWindow ?? false,
                pressedButton: closePressed ? .close : nil, controlScale: classicScale, title: title)
        }
        context.restoreGState()
    }

    /// The hosted-window contract (`wmp-skin-guide/reference/windows/native-windows.md` § *Adding a NullPlayer-native window in WMP
    /// mode*): ground only in the hole, then the borrowed frame over it.
    private func drawWMP(_ bounds: NSRect, style: SkinnedSurfaceStyle, closePressed: Bool, context: CGContext) {
        style.background.setFill()
        SkinnedSurfaceChrome.hostedGroundRect(in: bounds).fill()
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        if WindowManager.shared.hideTitleBars {
            context.translateBy(x: 0, y: -wmpMetrics.titleHeight)
        }
        SkinnedSurfaceChrome(style: style, artwork: WindowManager.shared.hostedSurfaceFrameArtwork(for: bounds.size))
            .drawSpectrumFamilyWindow(
                in: context, bounds: bounds, metrics: .spectrumFamily,
                isActive: window?.isKeyWindow ?? true, isClosePressed: closePressed,
                controlScale: classicScale, title: title, fillBackground: false)
        context.restoreGState()
    }
}
