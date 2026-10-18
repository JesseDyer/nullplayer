import AppKit

/// Shows one mode of a Sonique skin: blits `SoniqueSkinRenderer`'s output, the same draw path the
/// harness measures. A press on a control runs it on release; the knobs turn with vertical or
/// horizontal motion, as Sonique's do; a press anywhere else inside the outline drags the window
/// through `WindowManager`, and a double-click there jumps a mode (help `02.htm` § *Jumping Between
/// Modes*). A pixel outside the outline is not part of the window.
final class SoniqueSkinMainView: NSView {
    var skin: SoniqueSkin? { didSet { pressed = nil; smallDrawer = nil; redraw() } }
    var mode: SoniqueSkin.Mode = .navigator { didSet { if mode != oldValue { pressed = nil; smallDrawer = nil; redraw() } } }
    var host = SoniqueSkinHostState() { didSet { if host != oldValue { redraw() } } }
    /// Window points per skin pixel.
    var uiScale: CGFloat = 1 { didSet { if uiScale != oldValue { redraw() } } }
    var onCommand: ((SoniqueSkinControl) -> Void)?
    var onVolume: ((Double) -> Void)?
    var onMode: ((SoniqueSkin.Mode) -> Void)?
    /// Small mode's drawer changes the outline, so the window's shadow is rebuilt.
    var onOutlineChange: (() -> Void)?

    private var pressed: SoniqueSkinControl? { didSet { if pressed != oldValue { redraw() } } }
    private var smallDrawer: SoniqueSmallDrawer? { didSet { if smallDrawer != oldValue { redraw(); onOutlineChange?() } } }
    private var drawerClose: DispatchWorkItem?
    private var image: CGImage?
    private var drag = SkinnedWindowDrag()
    private var knobDrag: (start: NSPoint, volume: Double)?
    private let windowShadow = SkinWindowShadow()

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityIdentifier("SoniqueSkinMainView")
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }

    /// The scene on screen: what was drawn, and what every hit reads.
    private(set) var scene: SoniqueSkinScene?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        guard let window else { return windowShadow.detach() }
        windowShadow.attach(to: window, name: "sonique") { [weak self] in self?.image.map { [$0] } ?? [] }
    }

    private func redraw() {
        scene = skin.map { SoniqueSkinScene(skin: $0, mode: mode, host: host, pressed: pressed, smallDrawer: smallDrawer) }
        image = scene.flatMap(SoniqueSkinRenderer.render)
        needsDisplay = true
        windowShadow.invalidateShape("redraw")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = uiScale == uiScale.rounded() ? .none : .default
        context.draw(image, in: bounds)
    }

    // MARK: - Hit testing, skin pixels

    private func hit(_ event: NSEvent) -> (inside: Bool, control: SoniqueSkinControl?)? {
        hit(at: convert(event.locationInWindow, from: nil))
    }

    private func hit(at point: NSPoint) -> (inside: Bool, control: SoniqueSkinControl?)? {
        guard let scene, bounds.width > 0, bounds.height > 0 else { return nil }
        let x = Int(point.x * CGFloat(scene.width) / bounds.width), y = Int(point.y * CGFloat(scene.height) / bounds.height)
        return scene.hit(x: x, y: y)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let local = superview.map({ convert(point, from: $0) }), bounds.contains(local) else { return super.hitTest(point) }
        return hit(at: local)?.inside == true ? self : nil
    }

    // MARK: - Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    /// Small mode's drawer slides out while the pointer is over the bar or the open drawer, upward
    /// unless the screen's top edge leaves it no room.
    override func mouseMoved(with event: NSEvent) {
        guard mode == .small else { return }
        if hit(event)?.inside == true {
            drawerClose?.cancel()
            if smallDrawer == nil { smallDrawer = roomAbove ? .top : .bottom }
        } else {
            scheduleDrawerClose()
        }
    }

    override func mouseExited(with event: NSEvent) { scheduleDrawerClose() }

    private func scheduleDrawerClose() {
        guard smallDrawer != nil, drawerClose == nil || drawerClose!.isCancelled else { return }
        let work = DispatchWorkItem { [weak self] in self?.smallDrawer = nil; self?.drawerClose = nil }
        drawerClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private var roomAbove: Bool {
        guard let window, let screen = window.screen ?? NSScreen.main else { return true }
        return window.frame.maxY <= screen.visibleFrame.maxY + 1
    }

    override func mouseDown(with event: NSEvent) {
        guard let hit = hit(event), hit.inside else { return }
        if let control = hit.control, control.isActionable {
            pressed = control
            if control == .volume { knobDrag = (event.locationInWindow, host.volume) }
            return
        }
        if event.clickCount == 2 {
            onMode?(Self.mode(after: mode))
            return
        }
        drag.begin(event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let knobDrag {
            // Up or right turns clockwise (help `02.htm` § *Using Knobs*); 150 points spans the knob.
            let dx = event.locationInWindow.x - knobDrag.start.x, dy = event.locationInWindow.y - knobDrag.start.y
            onVolume?(min(1, max(0, knobDrag.volume + Double(dx + dy) / 150)))
            return
        }
        drag.move(event)
    }

    override func mouseUp(with event: NSEvent) {
        drag.end(event)
        let wasKnob = knobDrag != nil
        knobDrag = nil
        guard let pressed else { return }
        self.pressed = nil
        guard !wasKnob, hit(event)?.control == pressed else { return }
        onCommand?(pressed)
    }

    /// A left double-click on the chassis: navigator to mid to small, and small back to the navigator.
    static func mode(after mode: SoniqueSkin.Mode) -> SoniqueSkin.Mode {
        switch mode {
        case .navigator: return .mid
        case .mid: return .small
        case .small: return .navigator
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        ContextMenuBuilder.buildMenu(includeOutputDevices: false, includeRepeatShuffle: false)
    }

    override func keyDown(with event: NSEvent) {
        if !MainWindowKeys.perform(event) { super.keyDown(with: event) }
    }
}
