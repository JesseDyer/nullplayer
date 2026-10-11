import AppKit

/// **Equalizer Studio** — the one place EQ profiles are made and edited. One controller for every
/// skin family: a resizable borderless window in the running family's auxiliary chrome
/// (`AuxiliaryWindowChrome`), around a faceplate of its own in the skin's colours. It snaps, docks
/// and group-drags with the other windows, but is not a centre-stack window.
final class EqualizerStudioWindowController: NSWindowController, NSWindowDelegate {
    fileprivate static var current: EqualizerStudioWindowController?

    fileprivate let chromeView: EqualizerStudioWindowView
    private var studioView: EqualizerStudioView { chromeView.studioView }

    init() {
        let window = BorderlessWindow(contentRect: NSRect(origin: .zero, size: EqualizerStudioView.designSize),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasSkinShadow = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        window.allowedResizeEdges = [.left, .right, .bottom]
        window.collectionBehavior = [.managed, .fullScreenPrimary]
        window.title = "Equalizer Studio"
        chromeView = EqualizerStudioWindowView(frame: NSRect(origin: .zero, size: window.frame.size))
        chromeView.autoresizingMask = [.width, .height]
        window.contentView = chromeView
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        if window?.isVisible != true { studioView.studioDidOpen() }
        super.showWindow(sender)
    }

    func windowWillClose(_ notification: Notification) {
        studioView.studioDidClose()
        WindowManager.shared.notifyMainWindowVisibilityChanged()
    }

    func windowDidMove(_ notification: Notification) {
        guard let window else { return }
        let origin = WindowManager.shared.windowWillMove(window, to: window.frame.origin)
        WindowManager.shared.applySnappedPosition(window, to: origin)
    }

    func windowDidResize(_ notification: Notification) {
        chromeView.needsLayout = true
        WindowManager.shared.postWindowLayoutDidChange()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        chromeView.needsDisplay = true
        WindowManager.shared.bringAllWindowsToFront(keepingWindowOnTop: window)
    }

    func windowDidResignKey(_ notification: Notification) { chromeView.needsDisplay = true }
}

/// The Studio window's content: the chrome, its close and title drag, and the faceplate framed in
/// the chrome's content rect. The faceplate hands this view any click it does not use, so dragging
/// an empty area moves the window like its title does.
final class EqualizerStudioWindowView: NSView {
    let studioView = EqualizerStudioView(frame: NSRect(origin: .zero, size: EqualizerStudioView.designSize))
    private var dragStart: NSPoint?
    private var closePressed = false
    private var chrome: AuxiliaryWindowChrome { AuxiliaryWindowChrome(window: window, title: "EQUALIZER STUDIO") }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // The skin shadow reads the window's outline from this layer; without it the Studio casts none.
        wantsLayer = true
        addSubview(studioView)
        for name: Notification.Name in [.classicSkinDidChange, ModernSkinEngine.skinDidChangeNotification,
                                        .hostedSurfaceStyleDidChange, .windowLayoutDidChange, .doubleSizeDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(chromeDidChange), name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    /// The window size that gives the faceplate exactly `content`, in this mode's chrome.
    func windowSize(content: NSSize) -> NSSize {
        let probe = NSRect(x: 0, y: 0, width: 2000, height: 2000)
        let inner = chrome.contentRect(probe)
        return NSSize(width: content.width + probe.width - inner.width, height: content.height + probe.height - inner.height)
    }

    /// The chrome's insets change with the mode and hide-title-bars, so the minimum does too; a
    /// window left below it grows downward, keeping its title where it was.
    @objc func chromeDidChange() {
        if let window {
            let minimum = windowSize(content: EqualizerStudioView.designSize)
            window.minSize = minimum
            var frame = window.frame
            if frame.width < minimum.width || frame.height < minimum.height {
                frame.origin.y = frame.maxY - max(frame.height, minimum.height)
                frame.size = NSSize(width: max(frame.width, minimum.width), height: max(frame.height, minimum.height))
                window.setFrame(frame, display: true)
            }
        }
        needsLayout = true
        needsDisplay = true
        studioView.needsDisplay = true
    }

    override func layout() {
        super.layout()
        studioView.frame = chrome.contentRect(bounds)
        (window as? BorderlessWindow)?.titleBarHeight = chrome.titleHeight
    }

    override func draw(_ dirtyRect: NSRect) { chrome.draw(bounds, closePressed: closePressed) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A titleless WMP window's close sits over the faceplate, so it has to win against it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        if SkinnedSurfaceChrome.hidesPaletteTitleBar, chrome.closeRect(bounds).contains(local) { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if chrome.closeRect(bounds).contains(point) { closePressed = true; needsDisplay = true; return }
        dragStart = event.locationInWindow
        if let window { WindowManager.shared.windowWillStartDragging(window, fromTitleBar: true) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let window else { return }
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(WindowManager.shared.windowWillMove(window, to: NSPoint(x: mouse.x - start.x, y: mouse.y - start.y)))
    }

    override func mouseUp(with event: NSEvent) {
        if closePressed && chrome.closeRect(bounds).contains(convert(event.locationInWindow, from: nil)) {
            window?.close()
        }
        closePressed = false
        if dragStart != nil, let window { WindowManager.shared.windowDidFinishDragging(window) }
        dragStart = nil
        needsDisplay = true
    }
}

extension WindowManager {
    var equalizerStudioWindow: NSWindow? { EqualizerStudioWindowController.current?.window }

    var isEqualizerStudioVisible: Bool { equalizerStudioWindow?.isVisible ?? false }

    var equalizerStudioWindowFrame: NSRect? { equalizerStudioWindow?.frame }

    func showEqualizerStudio(at restoredFrame: NSRect? = nil) {
        let controller = EqualizerStudioWindowController.current ?? EqualizerStudioWindowController()
        EqualizerStudioWindowController.current = controller
        guard let window = controller.window else { return }
        if let restoredFrame {
            window.setFrame(restoredFrame, display: false)
        } else if !window.isVisible {
            window.setContentSize(controller.chromeView.windowSize(content: EqualizerStudioView.designSize))
            window.center()
        }
        controller.chromeView.chromeDidChange()
        window.level = isAlwaysOnTop ? .floating : .normal
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func toggleEqualizerStudio() {
        if isEqualizerStudioVisible {
            equalizerStudioWindow?.close()
        } else {
            showEqualizerStudio()
        }
    }
}
