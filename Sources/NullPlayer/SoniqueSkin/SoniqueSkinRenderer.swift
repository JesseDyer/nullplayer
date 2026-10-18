import CoreGraphics
import CoreText
import Foundation

/// A `SoniqueSkinScene` to pixels, one skin pixel per pixel. Pure CoreGraphics, so the harness and
/// the window draw through the same path. The loader has already keyed pure black out of every
/// picture; the outline clips everything.
enum SoniqueSkinRenderer {
    static func render(_ scene: SoniqueSkinScene) -> CGImage? {
        let w = scene.width, h = scene.height
        guard w > 0, h > 0,
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Skin pixels, top-left origin: flip once and move skin (0,0) to its place in the canvas.
        context.translateBy(x: 0, y: CGFloat(h))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: CGFloat(-scene.canvas.left), y: CGFloat(-scene.canvas.top))
        context.interpolationQuality = .none
        let painter = Painter(context: context, scene: scene)
        painter.clip(to: scene.outline)
        switch scene.mode {
        case .navigator: painter.navigator()
        case .mid: painter.mid()
        case .small: painter.small()
        }
        painter.balls()
        return context.makeImage()
    }

    /// A `[sonique colors]` value, `0xRRGGBB`.
    static func cgColor(_ rgb: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

private struct Painter {
    let context: CGContext
    let scene: SoniqueSkinScene
    var skin: SoniqueSkin { scene.skin }
    var host: SoniqueSkinHostState { scene.host }

    func clip(to rects: [SoniqueSkinRegion.Rect]) {
        context.clip(to: rects.map(\.cgRect))
    }

    /// `image` drawn with its top-left at (x, y), skin pixels.
    func draw(_ image: CGImage, x: Int, y: Int) {
        // The context is flipped, so the image is drawn flipped back about its own middle.
        context.saveGState()
        context.translateBy(x: CGFloat(x), y: CGFloat(y + image.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.restoreGState()
    }

    /// The part of `image` at `source` (top-left, skin pixels), drawn at (x, y) inside `clip`.
    func draw(_ image: CGImage, source: SoniqueSkinRegion.Rect, x: Int, y: Int, clip rects: [SoniqueSkinRegion.Rect]) {
        let bounded = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let part = image.cropping(to: source.cgRect.intersection(bounded)), !rects.isEmpty else { return }
        context.saveGState()
        clip(to: rects)
        draw(part, x: x + max(0, -source.left), y: y + max(0, -source.top))
        context.restoreGState()
    }

    // MARK: - Modes

    func navigator() {
        // The closed drawer first: the console is drawn over all of it but the tab below the frame.
        if let drawer = skin.drawerRegion, let misc = skin.image("/jpeg/misc") {
            let b = drawer.bounds
            let x = skin.settings.int("misc locations", "DRAWER_x"), y = skin.settings.int("misc locations", "DRAWER_y")
            draw(misc, source: .init(left: x, top: y, right: x + b.right - b.left, bottom: y + b.bottom - b.top),
                 x: b.left, y: b.top, clip: drawer.rects)
        }
        // The screen is Sonique's own surface, opaque: black in the picture there stays black (k2),
        // and nothing behind it, the drawer included, shows through (Trigun).
        if let display = skin.region("/rgn/nav/display") {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(display.rects.map(\.cgRect))
        }
        picture()
        litStates(prefix: "NAV_", upDown: true)
        let ownKnob = skin.image("/jpeg/nav_volumeknob") != nil
        knob(control: .volume, strip: ownKnob ? "/jpeg/nav_volumeknob" : "/jpeg/volumeknob",
             key: ownKnob ? "MISC_NAV_VOLUME_KNOB" : "MISC_VOLUME_KNOB", value: host.volume)
    }

    func mid() {
        picture()
        litStates(prefix: "", upDown: false)
        knob(control: .volume, strip: "/jpeg/volumeknob", key: "MISC_VOLUME_KNOB", value: host.volume)
        knob(control: .shuttle, strip: "/jpeg/shuttle", key: "MISC_SHUTTLE_KNOB", value: 0.5)
    }

    func small() {
        guard let picture = skin.image(SoniqueSkin.Mode.small.picture), let bar = skin.region(SoniqueSkin.Mode.small.frame) else { return }
        if let side = scene.smallDrawer { smallDrawer(side) }
        // `/jpeg/smallstate` is the bar twice: unlit above, lit below. The lit half shows through
        // the progress lines as far as they have come, and the blinker caps by loudness.
        let barHeight = bar.bounds.bottom
        let unlit = SoniqueSkinRegion.Rect(left: 0, top: 0, right: picture.width, bottom: barHeight)
        draw(picture, source: unlit, x: 0, y: 0, clip: bar.rects)
        let lit: (SoniqueSkinRegion.Rect) -> Void = { rect in
            draw(picture, source: rect.offset(0, barHeight), x: rect.left, y: rect.top, clip: [rect])
        }
        // ponytail: fixed spots measured on the oracle's default small frame (every corpus small
        // frame is that shape, `format.md`); read them from a skin if one ever moves its lines.
        let line = (left: 93, right: 184)
        let filled = { (fraction: Double) in line.left + Int(Double(line.right - line.left) * min(1, max(0, fraction))) }
        lit(.init(left: line.left, top: 3, right: filled(host.listProgress), bottom: 6))
        lit(.init(left: line.left, top: 18, right: filled(host.songProgress), bottom: 21))
        if host.blinkersLit {
            lit(.init(left: 9, top: 0, right: 15, bottom: barHeight))
            lit(.init(left: 186, top: 0, right: 192, bottom: barHeight))
        }
        let time = String(format: "%02d:%02d:%02d", host.elapsedSeconds / 3600, host.elapsedSeconds / 60 % 60, host.elapsedSeconds % 60)
        text(String(format: "%03d", host.trackNumber), x: 93, baseline: 16, size: 11, colour: "SystemColor_1")
        text(time, x: 125, baseline: 16, size: 11, colour: "SystemColor_1")
    }

    /// The open drawer: `/jpeg/extra`'s half for that side, then Sonique's icons and marquee on it.
    private func smallDrawer(_ side: SoniqueSmallDrawer) {
        guard let placement = skin.smallDrawerPlacement(side) else { return }
        if let extra = skin.image("/jpeg/extra") {
            let b = placement.region.bounds
            draw(extra, source: b, x: b.left + placement.dx, y: b.top + placement.dy,
                 clip: placement.region.rects.map { $0.offset(placement.dx, placement.dy) })
        }
        for (control, rect) in scene.drawerButtons {
            icon(control, in: rect, lit: scene.pressed == control)
        }
        if let marquee = scene.marqueeRect, !host.title.isEmpty {
            context.saveGState()
            clip(to: [marquee])
            text(host.title, x: marquee.left, baseline: marquee.bottom - 2, size: 9, colour: "SystemColor_1")
            context.restoreGState()
        }
    }

    private func picture() {
        guard let picture = skin.image(scene.mode.picture) else { return }
        context.saveGState()
        if let frame = skin.region(scene.mode.frame) { clip(to: frame.rects) }
        draw(picture, x: 0, y: 0)
        context.restoreGState()
    }

    // MARK: - Lit states

    /// Each control's lit state from `/jpeg/misc`: the key names the top-left of a rectangle the
    /// size of the control's bounds (skinpack `how-to-make-skins` § *misc locations*), drawn over
    /// the control and cut to its shape. The play button is a play/stop toggle: while playing it
    /// shows the stop picture, `…STOPOFF`, lit to `…STOPON` while pressed.
    private func litStates(prefix: String, upDown: Bool) {
        guard let misc = skin.image("/jpeg/misc") else { return }
        let pressed = scene.pressed
        var lit: [(SoniqueSkinControl, String)] = []
        if host.playState == .playing {
            lit.append((.play, pressed == .play ? "STOPON" : "STOPOFF"))
        } else if pressed == .play {
            lit.append((.play, "PLAYON"))
        }
        if host.playState == .paused || pressed == .pause { lit.append((.pause, "PAUSEON")) }
        if pressed == .prev { lit.append((.prev, "PREV")) }
        if pressed == .next { lit.append((.next, "NEXT")) }
        if pressed == .eject { lit.append((.eject, "ORANGEON")) }
        if host.shuffle { lit.append((.shuffle, "GREENON")) }
        // Sonique's loop-one, `GREENON2`, is unreachable: NullPlayer's repeat is on or off.
        if host.repeatAll { lit.append((.repeatButton, "CYANON")) }
        if pressed == .navButton { lit.append((.navButton, "REDON")) }
        for (control, key) in lit {
            draw(misc, lit: key, prefix: prefix, control: control)
        }
        if upDown {
            if pressed == .up { draw(misc, lit: "BIGUP", prefix: "", control: .up) }
            if pressed == .down { draw(misc, lit: "BIGON_DOWN", prefix: "", control: .down) }
        }
    }

    private func draw(_ misc: CGImage, lit key: String, prefix: String, control: SoniqueSkinControl) {
        guard let region = scene.region(for: control) else { return }
        let x = skin.settings.int("misc locations", prefix + key + "_x")
        let y = skin.settings.int("misc locations", prefix + key + "_y")
        let b = region.bounds
        draw(misc, source: .init(left: x, top: y, right: x + b.right - b.left, bottom: y + b.bottom - b.top),
             x: b.left, y: b.top, clip: region.rects)
    }

    /// A knob's frame from its horizontal strip (`<key>_width` px a frame, `<key>_images` frames),
    /// at the control's top-left and cut to its shape: a frame can be wider than the knob (BlueEyes:
    /// 29 px frames on a 15 px knob), and the oracle shows only the part inside it.
    private func knob(control: SoniqueSkinControl, strip name: String, key: String, value: Double) {
        guard let strip = skin.image(name), let region = scene.region(for: control) else { return }
        let width = max(1, skin.settings.int("misc values", key + "_width"))
        let frames = max(1, min(skin.settings.int("misc values", key + "_images"), strip.width / width))
        let frame = Int((min(1, max(0, value)) * Double(frames - 1)).rounded())
        let b = region.bounds
        draw(strip, source: .init(left: frame * width, top: 0, right: frame * width + width, bottom: strip.height),
             x: b.left, y: b.top, clip: region.rects)
    }

    // MARK: - What Sonique draws itself

    func balls() {
        let fill = colour("BlueBallsColor")
        for (ball, rect) in scene.ballRects {
            let r = rect.cgRect
            context.setFillColor(fill)
            context.fillEllipse(in: r)
            if scene.pressed == .ball(ball) {
                context.setFillColor(CGColor(gray: 0, alpha: 0.35))
                context.fillEllipse(in: r)
            }
            glyph(ball, in: r)
        }
    }

    /// The ball's mark in black, on a 9 px ball: arrows, a question mark, a bar, a cross.
    private func glyph(_ ball: SoniqueSkinControl.Ball, in r: CGRect) {
        context.saveGState()
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(1.5)
        let cx = r.midX, top = r.minY + 1.5, bottom = r.maxY - 1.5
        func arrow(tipY: CGFloat, baseY: CGFloat) {
            context.move(to: CGPoint(x: cx - 2.5, y: baseY))
            context.addLine(to: CGPoint(x: cx + 2.5, y: baseY))
            context.addLine(to: CGPoint(x: cx, y: tipY))
            context.fillPath()
        }
        switch ball {
        case .modeDown, .modeUp:
            let down = ball == .modeDown
            context.fill(CGRect(x: cx - 0.75, y: top, width: 1.5, height: bottom - top - 1))
            down ? arrow(tipY: bottom, baseY: bottom - 3) : arrow(tipY: top, baseY: top + 3)
        case .modeDownTwice, .modeUpTwice:
            let down = ball == .modeDownTwice
            context.fill(CGRect(x: cx - 0.75, y: top, width: 1.5, height: bottom - top))
            for step in [0.0, 3.0] as [CGFloat] {
                down ? arrow(tipY: bottom - step, baseY: bottom - step - 2.5) : arrow(tipY: top + step, baseY: top + step + 2.5)
            }
        case .help:
            text("?", x: Int(r.minX) + 2, baseline: Int(r.maxY) - 1, size: 9, rgb: 0)
        case .minimize:
            context.fill(CGRect(x: r.minX + 2, y: r.midY - 0.75, width: r.width - 4, height: 1.5))
        case .close:
            context.move(to: CGPoint(x: r.minX + 2.5, y: r.minY + 2.5))
            context.addLine(to: CGPoint(x: r.maxX - 2.5, y: r.maxY - 2.5))
            context.move(to: CGPoint(x: r.maxX - 2.5, y: r.minY + 2.5))
            context.addLine(to: CGPoint(x: r.minX + 2.5, y: r.maxY - 2.5))
            context.strokePath()
        }
        context.restoreGState()
    }

    /// Small mode's drawer icons: Sonique draws them as discs, open in `OpenFileColor`, the
    /// transport in `SystemColor_3`, each with its mark.
    private func icon(_ control: SoniqueSkinControl, in rect: SoniqueSkinRegion.Rect, lit: Bool) {
        let r = rect.cgRect
        context.saveGState()
        context.setFillColor(colour(control == .eject ? "OpenFileColor" : "SystemColor_3"))
        context.fillEllipse(in: r)
        context.setFillColor(CGColor(gray: lit ? 1 : 0, alpha: 1))
        let cx = r.midX, cy = r.midY
        func triangle(pointing right: Bool, at x: CGFloat) {
            context.move(to: CGPoint(x: x, y: cy - 3))
            context.addLine(to: CGPoint(x: x, y: cy + 3))
            context.addLine(to: CGPoint(x: right ? x + 3.5 : x - 3.5, y: cy))
            context.fillPath()
        }
        switch control {
        case .eject:
            context.move(to: CGPoint(x: cx - 3, y: cy))
            context.addLine(to: CGPoint(x: cx + 3, y: cy))
            context.addLine(to: CGPoint(x: cx, y: cy - 3))
            context.fillPath()
            context.fill(CGRect(x: cx - 3, y: cy + 1.5, width: 6, height: 1.5))
        case .prev:
            context.fill(CGRect(x: cx - 3, y: cy - 3, width: 1.5, height: 6))
            triangle(pointing: false, at: cx + 2.5)
        case .next:
            context.fill(CGRect(x: cx + 1.5, y: cy - 3, width: 1.5, height: 6))
            triangle(pointing: true, at: cx - 2.5)
        case .play:
            if host.playState == .playing {
                context.fill(CGRect(x: cx - 2.5, y: cy - 2.5, width: 5, height: 5))
            } else {
                triangle(pointing: true, at: cx - 1.5)
            }
        case .pause:
            context.fill(CGRect(x: cx - 2.5, y: cy - 3, width: 1.75, height: 6))
            context.fill(CGRect(x: cx + 0.75, y: cy - 3, width: 1.75, height: 6))
        default:
            break
        }
        context.restoreGState()
    }

    private func colour(_ key: String) -> CGColor { SoniqueSkinRenderer.cgColor(skin.settings.colour(key)) }

    private func text(_ string: String, x: Int, baseline: Int, size: CGFloat, colour key: String) {
        text(string, x: x, baseline: baseline, size: size, rgb: skin.settings.colour(key))
    }

    /// Sonique's own lettering: Verdana Bold, unsmoothed as GDI drew it, on the skin pixel grid.
    private func text(_ string: String, x: Int, baseline: Int, size: CGFloat, rgb: UInt32) {
        let font = CTFontCreateWithName("Verdana-Bold" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): SoniqueSkinRenderer.cgColor(rgb),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        context.saveGState()
        context.setShouldAntialias(false)
        context.setShouldSmoothFonts(false)
        // Text draws upright in an unflipped space: undo the flip around the baseline.
        context.textMatrix = .identity
        context.translateBy(x: CGFloat(x), y: CGFloat(baseline))
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

extension SoniqueSkinRegion.Rect {
    var cgRect: CGRect { CGRect(x: left, y: top, width: right - left, height: bottom - top) }
}
