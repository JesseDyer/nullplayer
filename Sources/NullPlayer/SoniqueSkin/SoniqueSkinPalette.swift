import AppKit

/// The colours NullPlayer's own windows wear beside a Sonique skin, read straight from its
/// `[sonique colors]` (decision record § *Auxiliary-window policy*): the screen's ground and its
/// playlist colours, the roles Sonique's own playlist screen paints with. `SkinnedSurfaceStyle` runs
/// every foreground through `legible`.
enum SoniqueSkinPalette {
    static func surfaceStyle(for skin: SoniqueSkin) -> SkinnedSurfaceStyle {
        let source = skin.source(for: .navigator)
        func colour(_ key: String) -> NSColor { NSColor(cgColor: SoniqueSkinRenderer.cgColor(source.settings.colour(key)))! }
        let text = colour("PlayListColor_1"), current = colour("PlayListColor_2"), selection = colour("SystemBkColor_2")
        return SkinnedSurfaceStyle(roles: SkinnedSurfaceRoles(
            background: colour("SystemBkColor_1"), text: text, currentText: current,
            selectionBackground: selection, selectionText: colour("SystemColor_1"),
            treeText: text, treeSelection: selection))
    }
}
