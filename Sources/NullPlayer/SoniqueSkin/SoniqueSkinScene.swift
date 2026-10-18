import CoreGraphics
import Foundation

/// What the player is doing, as a Sonique skin shows it. The scene reads only this.
struct SoniqueSkinHostState: Equatable {
    enum PlayState { case stopped, playing, paused }

    var playState: PlayState = .stopped
    var shuffle = false
    var repeatAll = false
    /// 0–1.
    var volume = 1.0
    /// 0–1 through the track, and through the playlist.
    var songProgress = 0.0
    var listProgress = 0.0
    /// 1-based; 0 with nothing loaded.
    var trackNumber = 0
    var elapsedSeconds = 0
    var title = ""
    /// Loud enough to light small mode's blinkers.
    var blinkersLit = false
}

/// Everything a mode can be clicked on: a skin region, or one of the controls Sonique draws itself
/// (the window balls and small mode's drawer icons).
enum SoniqueSkinControl: Hashable {
    case play, pause, prev, next, eject, repeatButton, shuffle, volume
    /// The navigator's menu rocker.
    case up, down
    /// Mid mode's "nav" button (`/rgn/mid/eq`), and its vis and song windows (`top`, `bottom`).
    case navButton, vis, songInfo
    case shuttle, drawerTab, songRing, listRing
    case ball(Ball)

    /// Sonique's navigation balls: the mode jumps, help, minimise and close
    /// (help `02.htm` § *The Navigation Buttons*).
    enum Ball: CaseIterable {
        case modeUp, modeUpTwice, modeDown, modeDownTwice, help, minimize, close
    }

    /// A press that does something; a region with no action (the display, the rings) is chassis.
    var isActionable: Bool {
        switch self {
        case .songRing, .listRing, .drawerTab: return false
        default: return true
        }
    }
}

/// Which way small mode's drawer slid out, or nil while it is closed.
enum SoniqueSmallDrawer: Equatable { case top, bottom }

/// One mode of one skin in one state, laid out in skin pixels with a top-left origin: what to draw
/// (`SoniqueSkinRenderer`) and what each pixel hits. The canvas is the mode's window: its outline's
/// bounds, plus small mode's drawer room above and below the bar.
struct SoniqueSkinScene {
    let mode: SoniqueSkin.Mode
    /// The skin this mode draws: the default skin's whole for a mode left to it (`SQ0009`).
    let skin: SoniqueSkin
    var host: SoniqueSkinHostState
    var pressed: SoniqueSkinControl?
    var smallDrawer: SoniqueSmallDrawer?
    /// The canvas in skin pixels: its origin is skin (0,0)'s offset into the window.
    let canvas: SoniqueSkinRegion.Rect

    init(skin: SoniqueSkin, mode: SoniqueSkin.Mode, host: SoniqueSkinHostState = .init(),
         pressed: SoniqueSkinControl? = nil, smallDrawer: SoniqueSmallDrawer? = nil) {
        self.mode = mode
        self.skin = skin.source(for: mode)
        self.host = host
        self.pressed = pressed
        self.smallDrawer = smallDrawer
        canvas = Self.canvas(self.skin, mode)
    }

    var width: Int { canvas.right - canvas.left }
    var height: Int { canvas.bottom - canvas.top }

    // MARK: - Geometry

    /// The window outline in skin pixels (`format.md` § *Window outline*).
    var outline: [SoniqueSkinRegion.Rect] {
        var rects = skin.region(mode.frame)?.rects ?? []
        if mode == .navigator, let drawer = skin.drawerRegion { rects += drawer.rects }
        if mode == .small, let smallDrawer, let drawer = skin.smallDrawerPlacement(smallDrawer) {
            rects += drawer.region.rects.map { $0.offset(drawer.dx, drawer.dy) }
        }
        return rects
    }

    private static func canvas(_ skin: SoniqueSkin, _ mode: SoniqueSkin.Mode) -> SoniqueSkinRegion.Rect {
        let frame = skin.region(mode.frame)?.bounds
        let picture = skin.image(mode.picture).map { SoniqueSkinRegion.Rect(left: 0, top: 0, right: $0.width, bottom: $0.height) }
        var box = frame ?? picture ?? SoniqueSkinRegion.Rect(left: 0, top: 0, right: 1, bottom: 1)
        switch mode {
        case .navigator:
            if let drawer = skin.drawerRegion { box = box.union(drawer.bounds) }
        case .mid:
            break
        case .small:
            // The window keeps room for the drawer on both sides, as Sonique's does (the oracle's
            // small window spans them while they are closed); only the bar is drawn until one opens.
            for side in [SoniqueSmallDrawer.top, .bottom] {
                if let drawer = skin.smallDrawerPlacement(side, bar: box) {
                    box = box.union(drawer.region.bounds.offset(drawer.dx, drawer.dy))
                }
            }
        }
        return box
    }

    // MARK: - Controls

    /// The region-backed controls of each mode, by entry name, in hit order.
    var regionControls: [(SoniqueSkinControl, String)] {
        switch mode {
        case .navigator:
            return [(.play, "play"), (.pause, "pause"), (.prev, "prev"), (.next, "next"), (.eject, "eject"),
                    (.repeatButton, "repeat"), (.shuffle, "shuffle"), (.volume, "volume"), (.up, "up"), (.down, "down")]
        case .mid:
            return [(.play, "play"), (.pause, "pause"), (.prev, "prev"), (.next, "next"), (.eject, "eject"),
                    (.repeatButton, "repeat"), (.shuffle, "shuffle"), (.volume, "volume"), (.navButton, "eq"),
                    (.shuttle, "shuttle"), (.songRing, "songposring"), (.listRing, "listposring"),
                    (.songInfo, "bottom"), (.vis, "top")]
        case .small:
            return []
        }
    }

    func region(for control: SoniqueSkinControl) -> SoniqueSkinRegion? {
        guard let name = regionControls.first(where: { $0.0 == control })?.1 else { return nil }
        return skin.region(mode.regions + name)
    }

    /// The balls each mode shows, left to right (help `02.htm`): the navigator jumps down, small mode
    /// up, mid mode either way once.
    var balls: [SoniqueSkinControl.Ball] {
        switch mode {
        case .navigator: return [.modeDown, .modeDownTwice, .help, .minimize, .close]
        case .mid: return [.modeUp, .modeDown, .help, .minimize, .close]
        case .small: return [.modeUp, .modeUpTwice, .help, .minimize, .close]
        }
    }

    static let ballSize = 9

    /// Each ball's square, in skin pixels. Navigator: a row along the display's top right,
    /// `NC_BB_DIST_FROM_RIGHT` in. Mid: `[msm locations]`, from the vis window's corner. Small: in the
    /// open drawer only.
    var ballRects: [(SoniqueSkinControl.Ball, SoniqueSkinRegion.Rect)] {
        let s = Self.ballSize
        func square(_ x: Int, _ y: Int) -> SoniqueSkinRegion.Rect { .init(left: x, top: y, right: x + s, bottom: y + s) }
        switch mode {
        case .navigator:
            guard let display = skin.region("/rgn/nav/display")?.bounds else { return [] }
            let right = display.right - skin.settings.int("misc values", "NC_BB_DIST_FROM_RIGHT") - 4
            return balls.enumerated().map { i, ball in (ball, square(right - s - (balls.count - 1 - i) * 12, display.top + 1)) }
        case .mid:
            guard let top = skin.region("/rgn/mid/top")?.bounds else { return [] }
            let keys = ["MSM_SINGLEUP", "MSM_SINGLEDOWN", "MSM_HELP", "MSM_MINIMIZE", "MSM_CLOSE"]
            return zip(balls, keys).map { ball, key in
                (ball, square(top.left + skin.settings.int("msm locations", key + "_x"),
                              top.top + skin.settings.int("msm locations", key + "_y")))
            }
        case .small:
            guard let smallDrawer, let drawer = skin.smallDrawerPlacement(smallDrawer) else { return [] }
            let b = drawer.region.bounds.offset(drawer.dx, drawer.dy)
            let y = smallDrawer == .top ? b.top + 12 : b.bottom - 12 - s
            return balls.enumerated().map { i, ball in (ball, square(b.right - 14 - s - (balls.count - 1 - i) * 12, y)) }
        }
    }

    /// Small mode's drawer icons, Sonique's own (help image `11.0`): open, back, play/stop, pause,
    /// ahead, 14 px apart along the drawer's outer row.
    var drawerButtons: [(SoniqueSkinControl, SoniqueSkinRegion.Rect)] {
        guard mode == .small, let smallDrawer, let drawer = skin.smallDrawerPlacement(smallDrawer) else { return [] }
        let b = drawer.region.bounds.offset(drawer.dx, drawer.dy)
        let y = smallDrawer == .top ? b.top + 10 : b.bottom - 10 - 12
        let controls: [SoniqueSkinControl] = [.eject, .prev, .play, .pause, .next]
        return controls.enumerated().map { i, control in
            (control, SoniqueSkinRegion.Rect(left: b.left + 17 + i * 14, top: y, right: b.left + 29 + i * 14, bottom: y + 12))
        }
    }

    /// Small mode's marquee line inside the open drawer.
    var marqueeRect: SoniqueSkinRegion.Rect? {
        guard mode == .small, let smallDrawer, let drawer = skin.smallDrawerPlacement(smallDrawer) else { return nil }
        let b = drawer.region.bounds.offset(drawer.dx, drawer.dy)
        let y = smallDrawer == .top ? b.top + 26 : b.bottom - 26 - 11
        return .init(left: b.left + 16, top: y, right: b.right - 12, bottom: y + 11)
    }

    /// What a canvas pixel hits: a control, the chassis (nil control, inside the outline), or
    /// nothing at all (outside it, which is not part of the window).
    func hit(x canvasX: Int, y canvasY: Int) -> (inside: Bool, control: SoniqueSkinControl?) {
        let x = canvasX + canvas.left, y = canvasY + canvas.top
        if let ball = ballRects.first(where: { $0.1.contains(x, y) }) { return (true, .ball(ball.0)) }
        if let button = drawerButtons.first(where: { $0.1.contains(x, y) }) { return (true, button.0) }
        let inside = outline.contains { $0.contains(x, y) }
        guard inside else { return (false, nil) }
        if mode == .navigator, let tab = skin.region("/rgn/nav/drawertop") {
            let at = skin.settings.drawerPosition
            if tab.offset(at.x, at.y).contains(x, y) { return (true, .drawerTab) }
        }
        for (control, name) in regionControls {
            if skin.region(mode.regions + name)?.contains(x, y) == true { return (true, control) }
        }
        return (true, nil)
    }
}

/// The drawers' placement depends on the skin alone, so the canvas can be worked out from it.
extension SoniqueSkin {
    /// The navigator's closed drawer, placed at `DRAWER_POS`.
    var drawerRegion: SoniqueSkinRegion? {
        guard let drawer = region("/rgn/nav/drawer") else { return nil }
        let at = settings.drawerPosition
        return drawer.offset(at.x, at.y)
    }

    /// Where small mode's drawer sits open: centred on the bar, its far edge on the bar's (Sonique's
    /// help, image `11.0`). `region` is in `/jpeg/extra` pixels; `dx`, `dy` move it onto the skin.
    func smallDrawerPlacement(_ side: SoniqueSmallDrawer, bar: SoniqueSkinRegion.Rect? = nil)
        -> (region: SoniqueSkinRegion, dx: Int, dy: Int)? {
        let name = side == .top ? "/rgn/small/extratop" : "/rgn/small/extrabottom"
        guard let drawer = region(name),
              let bar = bar ?? region(Mode.small.frame)?.bounds else { return nil }
        let b = drawer.bounds
        let dx = bar.left + (bar.right - bar.left - (b.right - b.left) + 1) / 2 - b.left
        let dy = side == .top ? bar.top - b.bottom : bar.bottom - b.top
        return (drawer, dx, dy)
    }
}

extension SoniqueSkinRegion.Rect {
    func contains(_ x: Int, _ y: Int) -> Bool { x >= left && x < right && y >= top && y < bottom }
    func offset(_ dx: Int, _ dy: Int) -> Self { .init(left: left + dx, top: top + dy, right: right + dx, bottom: bottom + dy) }
    func union(_ o: Self) -> Self {
        .init(left: min(left, o.left), top: min(top, o.top), right: max(right, o.right), bottom: max(bottom, o.bottom))
    }
}

extension SoniqueSkinRegion {
    func contains(_ x: Int, _ y: Int) -> Bool { bounds.contains(x, y) && rects.contains { $0.contains(x, y) } }
    func offset(_ dx: Int, _ dy: Int) -> SoniqueSkinRegion {
        var moved = self
        moved.bounds = bounds.offset(dx, dy)
        moved.rects = rects.map { $0.offset(dx, dy) }
        return moved
    }
}
