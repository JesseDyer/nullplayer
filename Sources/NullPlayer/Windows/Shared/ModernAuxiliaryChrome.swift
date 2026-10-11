import AppKit

/// `AuxiliaryWindowChrome`'s Original (Metal skin) frame.
enum ModernAuxiliaryChrome {
    /// Inside the frame's border, rounded with its corners.
    static func contentClip(in bounds: NSRect, window: NSWindow?) -> CGPath {
        let skin = ModernSkinEngine.shared.currentSkin ?? ModernSkinLoader.shared.loadDefault()
        return ModernSkinRenderer(skin: skin).windowContentClipPath(
            in: bounds, sharpCorners: window.map { WindowManager.shared.computeSharpCorners(for: $0) } ?? [])
    }

    static func draw(in bounds: NSRect, window: NSWindow?, title: String, closePressed: Bool,
                     titleHeight: CGFloat, closeRect: NSRect, context: CGContext) {
        let skin = ModernSkinEngine.shared.currentSkin ?? ModernSkinLoader.shared.loadDefault()
        let renderer = ModernSkinRenderer(skin: skin)
        let edges = window.map { WindowManager.shared.computeAdjacentEdges(for: $0) } ?? []
        let corners = window.map { WindowManager.shared.computeSharpCorners(for: $0) } ?? []
        // The main window's ground opacity, as the EQ and Library take it, so the surfaces match.
        renderer.drawWindowBackground(in: bounds, context: context, adjacentEdges: edges, sharpCorners: corners,
                                      backgroundOpacity: skin.resolvedOpacity(for: .mainWindow).background)
        renderer.drawWindowBorder(in: bounds, context: context, adjacentEdges: edges, sharpCorners: corners,
                                  occlusionSegments: window.map { WindowManager.shared.computeEdgeOcclusionSegments(for: $0) } ?? .empty)
        guard !WindowManager.shared.effectiveHideTitleBars(for: window) else { return }
        let scale = ModernSkinElements.scaleFactor
        renderer.drawTitleBar(in: NSRect(x: 0, y: (bounds.height - titleHeight) / scale,
                                         width: bounds.width / scale, height: titleHeight / scale),
                              title: title, prefix: "spectrum_", context: context)
        renderer.drawWindowControlButton("spectrum_btn_close", state: closePressed ? "pressed" : "normal",
            in: NSRect(x: closeRect.minX / scale, y: closeRect.minY / scale,
                       width: closeRect.width / scale, height: closeRect.height / scale), context: context)
    }
}
