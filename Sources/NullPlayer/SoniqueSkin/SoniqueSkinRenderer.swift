import CoreGraphics
import CoreText
import Foundation

/// A `SoniqueSkinScene` to pixels, one skin pixel per pixel. Pure CoreGraphics, so the harness and
/// the window draw through the same path. The loader has already keyed pure black out of every
/// picture; the outline clips everything, and is black under it all.
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
        // Inside the window Sonique paints black where a picture is pure black; only the outline
        // is transparent.
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: scene.canvas.left, y: scene.canvas.top, width: w, height: h))
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
        // The drawer first: the console is drawn over all of it but what hangs below the frame.
        if let drawer = scene.drawer, let misc = skin.image("/jpeg/misc") {
            let b = drawer.bounds, origin = scene.drawerOrigin
            let x = skin.settings.int("misc locations", "DRAWER_x") + b.left - origin.x
            let y = skin.settings.int("misc locations", "DRAWER_y") + b.top - origin.y
            draw(misc, source: .init(left: x, top: y, right: x + b.right - b.left, bottom: y + b.bottom - b.top),
                 x: b.left, y: b.top, clip: drawer.rects)
            if scene.navDrawerOpen { drawerDials(misc, clip: drawer.rects) }
        }
        // The screen is Sonique's own surface, opaque: black in the picture there stays black (k2),
        // and nothing behind it, the drawer included, shows through (Trigun).
        if let display = skin.region("/rgn/nav/display") {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(display.rects.map(\.cgRect))
        }
        picture()
        statusLine()
        litStates(prefix: "NAV_", upDown: true)
        let ownKnob = skin.image("/jpeg/nav_volumeknob") != nil
        knob(control: .volume, strip: ownKnob ? "/jpeg/nav_volumeknob" : "/jpeg/volumeknob",
             key: ownKnob ? "MISC_NAV_VOLUME_KNOB" : "MISC_VOLUME_KNOB", value: host.volume)
    }

    /// The navigator's status line, Sonique's own, along the display's bottom edge: a band in
    /// `StatusBarBgColor` dotted with `StatusBarFgColor`, and the title (`Sonique 1.96` idle; NullPlayer
    /// writes its own name) in `StatusBarTextColor`, centred on the display's span 7 px left of its
    /// middle (Trigun, Danzig and sonique all measure so).
    private func statusLine() {
        guard let display = skin.region("/rgn/nav/display") else { return }
        let bottom = display.bounds.bottom, band = CGRect(x: display.bounds.left, y: bottom - 13,
                                                         width: display.bounds.right - display.bounds.left, height: 13)
        context.saveGState()
        clip(to: display.rects)
        context.clip(to: band)
        context.setFillColor(colour("StatusBarBgColor"))
        context.fill(band)
        context.setFillColor(colour("StatusBarFgColor"))
        // A 2 px dot grid over the band (stopping 3 rows short, as sonique looks at 6x, made 301
        // captures worse).
        context.fill(stride(from: Int(band.minY), to: bottom, by: 2).flatMap { y in
            stride(from: Int(band.minX), to: Int(band.maxX), by: 2).map { CGRect(x: $0, y: y, width: 1, height: 1) }
        })
        let span = display.rects.filter { $0.top <= bottom - 5 && $0.bottom > bottom - 5 }
        let left = span.map(\.left).min() ?? display.bounds.left, right = span.map(\.right).max() ?? display.bounds.right
        text(host.title.isEmpty ? "NullPlayer" : host.title, centreX: (left + right) / 2 - 7, minX: left + 2,
             baseline: bottom - 3, size: 9, colour: "StatusBarTextColor")
        context.restoreGState()
    }

    /// The open drawer's EQ slider handles (`SLIDEROFF`, `SLIDERON` while held), centred on their
    /// tracks and see-through by their darkness (`handle(_:)`), and its three knobs, `/jpeg/smallknob`'s
    /// grey frames tinted with each knob's colour (skinpack § *animations*).
    private func drawerDials(_ misc: CGImage, clip drawer: [SoniqueSkinRegion.Rect]) {
        let w = skin.settings.int("misc values", "MISC_DRAWER_SLIDER_HANDLE_SIZE_width")
        let h = skin.settings.int("misc values", "MISC_DRAWER_SLIDER_HANDLE_SIZE_height")
        let handles = ["SLIDEROFF", "SLIDERON"].map { key -> CGImage? in
            let x = skin.settings.int("misc locations", key + "_x"), y = skin.settings.int("misc locations", key + "_y")
            return misc.cropping(to: CGRect(x: x, y: y, width: w, height: h)).flatMap(Self.handle)
        }
        for (index, value) in host.eq.prefix(SoniqueSkinScene.eqSliders).enumerated() {
            guard let handle = handles[scene.pressed == .eqSlider(index) ? 1 : 0] else { continue }
            let track = scene.eqSliderTrack(index)
            let top = track.top + Int((1 - min(1, max(0, value))) * Double(track.bottom - track.top - h))
            context.saveGState()
            clip(to: drawer)
            draw(handle, x: track.left + (track.right - track.left - w) / 2, y: top)
            context.restoreGState()
        }
        for (control, value, colour) in [(SoniqueSkinControl.amp, host.amp, "AmpKnobColor"),
                                         (.balance, host.balance, "BalKnobColor"), (.pitch, host.pitch, "PitchKnobColor")] {
            // A drawer knob's strip is a full turn, of which the knob sweeps 250° about its middle frame
            // (oracle: frames 5–30 of sonique's 36, 3–16 of metrobin's 20, 2–8 of bluehorizon's 11).
            knob(control: control, strip: "/jpeg/smallknob", key: "MISC_SMALL_KNOB", value: value, tint: colour,
                 turn: 250.0 / 360)
        }
    }

    /// A slider handle as Sonique blends it: each pixel's opacity is its luminance over 128, so the
    /// near-black frame vanishes, mid-greys are half there and the light face is solid (sonique's
    /// grey handle within 1 level, BlueEyes' blue ball within 5, over screen 6's open drawer).
    private static func handle(_ sprite: CGImage) -> CGImage? {
        let w = sprite.width, h = sprite.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(sprite, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for i in stride(from: 0, to: w * h * 4, by: 4) where p[i + 3] == 255 {
            let luma = (299 * Int(p[i]) + 587 * Int(p[i + 1]) + 114 * Int(p[i + 2])) / 1000
            let alpha = min(255, luma * 2)
            for c in 0..<4 { p[i + c] = UInt8(Int(p[i + c]) * alpha / 255) }
        }
        return context.makeImage()
    }

    func mid() {
        picture()
        litStates(prefix: "", upDown: false)
        knob(control: .volume, strip: "/jpeg/volumeknob", key: "MISC_VOLUME_KNOB", value: host.volume)
        // The shuttle at rest is its first frame (258 mid captures closer than the middle one).
        knob(control: .shuttle, strip: "/jpeg/shuttle", key: "MISC_SHUTTLE_KNOB", value: 0, opaque: false)
        ring(.songRing, progress: host.songProgress, colour: "ProgressColor_1")
        ring(.listRing, progress: host.listProgress, colour: "PlayListColor_1")
        songDisplay()
    }

    /// A progress ring: the part come so far in `colour`, clockwise from the top (`mid_playlistmode`
    /// 0) or across 270° from the bottom left (1). An empty ring is the picture, as the oracle draws it
    /// (a flat `ProgressBkColor` there made 239 mid captures worse).
    /// ponytail: the start angle and the fill colour are guesses, since the oracle captures only the
    /// stopped state, where both rings are empty; measure them from a playing oracle.
    private func ring(_ control: SoniqueSkinControl, progress: Double, colour key: String) {
        guard progress > 0, let region = scene.region(for: control) else { return }
        context.saveGState()
        clip(to: region.rects)
        let b = region.bounds.cgRect
        // Skin pixels run top-down, so angles grow clockwise; -90° is the top.
        let (start, sweep) = skin.settings.int("misc values", "mid_playlistmode") == 0
            ? (-Double.pi / 2, 2 * Double.pi) : (3 * Double.pi / 4, 1.5 * Double.pi)
        let centre = CGPoint(x: b.midX, y: b.midY)
        context.move(to: centre)
        context.addArc(center: centre, radius: max(b.width, b.height), startAngle: start,
                       endAngle: start + sweep * min(1, progress), clockwise: false)
        context.closePath()
        context.setFillColor(colour(key))
        context.fillPath()
        context.restoreGState()
    }

    /// Mid mode's song window, Sonique's own drawing at fixed offsets from `/rgn/mid/bottom`'s top-left
    /// whatever its size (measured on sonique, sTek2k, musicman, k2, carrot): a tab in
    /// `SystemBkColor_2` edged in `BorderColor` (pure black is not drawn), the track number, the time
    /// and the status line in `SystemColor_1`.
    /// ponytail: ~37 skins have a song window too small for this, and Sonique lays those out tighter
    /// (Trigun shows the time alone, CougarKW drops the hundredths); here they get it cut to the region.
    private func songDisplay() {
        guard let region = scene.region(for: .songInfo) else { return }
        let x = region.bounds.left, y = region.bounds.top
        context.saveGState()
        clip(to: region.rects)
        // The tab hangs from the window's top edge: open at the top, 3 px sides and bottom.
        let tab = { (inset: Int) in
            CGPath(roundedRect: CGRect(x: x + 13 + inset, y: y - 8, width: 68 - 2 * inset, height: 39 - inset),
                   cornerWidth: 5, cornerHeight: 5, transform: nil)
        }
        if skin.settings.colour("SystemBkColor_2") != 0 {
            context.addPath(tab(3))
            context.setFillColor(colour("SystemBkColor_2"))
            context.fillPath()
        }
        if skin.settings.colour("BorderColor") != 0 {
            context.addPath(tab(0))
            context.addPath(tab(3))
            context.setFillColor(colour("BorderColor"))
            context.fillPath(using: .evenOdd)
        }
        let seconds = host.elapsedSeconds
        let lines = [(String(format: "%03d", host.trackNumber), 15, CGFloat(14)),
                     (String(format: "%02d:%02d.00", seconds / 60 % 100, seconds % 60), 25, 10),
                     (host.title.isEmpty ? "NullPlayer" : host.title, 41, 9)]
        for (string, baseline, size) in lines {
            text(string, centreX: x + 47, minX: x + 13, baseline: y + baseline, size: size, colour: "SystemColor_1")
        }
        context.restoreGState()
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
    /// `tint` multiplies the frame by a `[sonique colors]` key: the drawer's knobs are grey strips.
    /// A knob's frame is opaque, its pure black drawn black over the picture (257 captures closer); the
    /// shuttle's is not (26 mid captures worse opaque), so it passes `opaque: false`. `turn` is the
    /// share of the strip, centred on its middle, that the value spans.
    private func knob(control: SoniqueSkinControl, strip name: String, key: String, value: Double,
                      tint: String? = nil, opaque: Bool = true, turn: Double = 1) {
        guard let strip = skin.image(name), let region = scene.region(for: control) else { return }
        let width = max(1, skin.settings.int("misc values", key + "_width"))
        let frames = max(1, min(skin.settings.int("misc values", key + "_images"), strip.width / width))
        let frame = Int(((0.5 + (min(1, max(0, value)) - 0.5) * turn) * Double(frames - 1)).rounded())
        let b = region.bounds
        if opaque {
            let face = CGRect(x: b.left, y: b.top, width: width, height: strip.height)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(region.rects.map { $0.cgRect.intersection(face) })
        }
        draw(strip, source: .init(left: frame * width, top: 0, right: frame * width + width, bottom: strip.height),
             x: b.left, y: b.top, clip: region.rects)
        guard let tint else { return }
        context.saveGState()
        clip(to: region.rects)
        context.setBlendMode(.multiply)
        context.setFillColor(colour(tint))
        context.fill(CGRect(x: b.left, y: b.top, width: width, height: strip.height))
        context.restoreGState()
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

    /// Centred on `centreX`, but starting no further left than `minX`: a long title keeps its start.
    private func text(_ string: String, centreX: Int, minX: Int, baseline: Int, size: CGFloat, colour key: String) {
        let width = CTLineGetTypographicBounds(line(string, size: size, rgb: 0), nil, nil, nil)
        text(string, x: max(minX, centreX - Int((width / 2).rounded())), baseline: baseline, size: size, rgb: skin.settings.colour(key))
    }

    private func line(_ string: String, size: CGFloat, rgb: UInt32) -> CTLine {
        let font = CTFontCreateWithName("Verdana-Bold" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): SoniqueSkinRenderer.cgColor(rgb),
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    }

    /// Sonique's own lettering: Verdana Bold, unsmoothed as GDI drew it, on the skin pixel grid.
    private func text(_ string: String, x: Int, baseline: Int, size: CGFloat, rgb: UInt32) {
        let line = line(string, size: size, rgb: rgb)
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
