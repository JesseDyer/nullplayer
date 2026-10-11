import AppKit

/// Boutique's glow: a region of the faceplate drawn offscreen, run through the Metal bloom, and put
/// back. Without Metal the region is drawn as it is.
final class StudioBloom {
    private let processor: BloomPostProcessor = {
        let processor = BloomPostProcessor()
        processor.intensity = 0.9
        return processor
    }()

    /// Tuned for the heat ramp, whose upper half blooms; always clear of the ground, which would
    /// otherwise bloom the whole region on a mid-dark skin.
    private static func threshold(over ground: NSColor) -> CGFloat {
        guard let rgb = ground.usingColorSpace(.sRGB) else { return 0.45 }
        let luma = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return min(0.9, max(0.45, luma + 0.25))
    }

    /// Draws `body` — which draws in the current (flipped) view's coordinates — bloomed into `rect`,
    /// over `ground`, so the offscreen region is opaque as the bloom's composite requires.
    func draw(_ rect: CGRect, scale: CGFloat, ground: NSColor, _ body: () -> Void) {
        let width = Int((rect.width * scale).rounded(.up)), height = Int((rect.height * scale).rounded(.up))
        guard processor.isAvailable, width > 0, height > 0, let target = NSGraphicsContext.current?.cgContext,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { body(); return }

        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: rect.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        ground.setFill()
        rect.fill()
        body()
        NSGraphicsContext.restoreGraphicsState()

        processor.radius = 6 * scale
        processor.threshold = Self.threshold(over: ground)
        guard let image = context.makeImage(), let bloomed = processor.apply(to: image) else { body(); return }
        // The view is flipped; a CGImage draws upright only in an unflipped space.
        target.saveGState()
        target.translateBy(x: rect.minX, y: rect.maxY)
        target.scaleBy(x: 1, y: -1)
        target.draw(bloomed, in: CGRect(origin: .zero, size: rect.size))
        target.restoreGState()
    }
}
