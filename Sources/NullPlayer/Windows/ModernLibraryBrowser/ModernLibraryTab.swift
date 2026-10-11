import AppKit

/// The Original Library's tab: a boxed toggle, glowing while active, its label centred in the
/// Library's font. The Equalizer Studio draws its buttons with it, so the two windows' tabs are
/// the same.
enum ModernLibraryTab {
    /// The Library's tab font at `scale` (its narrow-window shrink).
    static func font(skin: ModernSkin, compact: Bool = false, scale: CGFloat = 1) -> NSFont {
        skin.libraryFont(size: (compact ? 11 : 12) * scale)
    }

    static func draw(_ label: String, isActive: Bool, rect: NSRect, font: NSFont, skin: ModernSkin,
                     context: CGContext) {
        let color = drawBox(isActive: isActive, rect: rect, skin: skin, context: context)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: skin.applyTextOpacity(to: color)]
        let textSize = label.size(withAttributes: attrs)
        // Drawn at full alpha, so a parent's content alpha does not dim it.
        context.saveGState()
        context.setAlpha(1.0)
        label.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
                   withAttributes: attrs)
        context.restoreGState()
    }

    /// The colour a tab's label is drawn in, lit or not.
    static func labelColor(isActive: Bool, skin: ModernSkin) -> NSColor {
        guard isActive else { return skin.textDimColor }
        return skin.renderStyle == .metal ? skin.metalMaterial.lcdInk : skin.elementColor(for: "tab_text", fallback: skin.accentColor)
    }

    /// The boxed outline of a toggle button; returns the color its label is drawn in.
    @discardableResult
    static func drawBox(isActive: Bool, rect: NSRect, skin: ModernSkin, context: CGContext) -> NSColor {
        let isMetal = skin.renderStyle == .metal
        let metal = skin.metalMaterial
        let scale = ModernSkinElements.scaleFactor
        // Metal lights an active box the way it lights the main window's display — the backlit LCD,
        // in its ink, outlined in the text colour. In the material's own stroke and control fill a
        // selected tab could not be told from the rest.
        let outlineColor = isMetal ? skin.textColor : skin.elementColor(for: "tab_outline", fallback: skin.accentColor)
        let color = labelColor(isActive: isActive, skin: skin)
        let strokeRect = rect.insetBy(dx: scale, dy: scale)
        let cornerRadius = 2 * scale
        let strokePath = CGPath(roundedRect: strokeRect,
                                cornerWidth: cornerRadius,
                                cornerHeight: cornerRadius,
                                transform: nil)
        let lineWidth = max(0.5, 0.8 * scale)

        context.saveGState()

        if isActive {
            context.setFillColor((isMetal ? metal.displayFill : outlineColor.withAlphaComponent(0.12)).cgColor)
            context.addPath(strokePath)
            context.fillPath()

            if !isMetal {
                context.setShadow(offset: .zero, blur: 6, color: outlineColor.withAlphaComponent(0.6).cgColor)
            }
            context.setStrokeColor(outlineColor.withAlphaComponent(0.8).cgColor)
            context.setLineWidth(lineWidth)
            context.addPath(strokePath)
            context.strokePath()
            context.restoreGState()

            context.saveGState()
            context.setStrokeColor(outlineColor.withAlphaComponent(0.6).cgColor)
            context.setLineWidth(lineWidth)
            context.addPath(strokePath)
            context.strokePath()
        } else {
            context.setStrokeColor((isMetal ? metal.eqStroke : skin.textDimColor.withAlphaComponent(0.4)).cgColor)
            context.setLineWidth(lineWidth)
            context.addPath(strokePath)
            context.strokePath()
        }
        context.restoreGState()
        return color
    }
}
