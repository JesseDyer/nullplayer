import AppKit

/// How a `.wal` window gets its pixels: recorded on the main thread, rasterized off it.
///
/// The scene walk reads the live object graph, so it stays on the main thread and records into a
/// `WasabiDrawList`. Rasterizing that list, which is most of a frame's cost, runs on the window's
/// own serial queue into its `WinampModernCanvas`, at device resolution. The finished picture is the
/// view's layer `contents` (`updateLayer`), so showing it costs the main thread nothing: no backing
/// store, no display-list replay, no colour match. The replay of a copied picture measured 15.7% of
/// cPro Bento's main thread in Device RGB, 8.8% in the window's own space.
///
/// - **Every invalidation asks for a frame.** `setNeedsDisplay(_:)` keeps the rect and schedules a
///   frame for the end of the runloop turn, so a burst of script writes is recorded once.
/// - **One frame in flight.** Dirt that arrives while a frame renders waits, and is recorded fresh
///   when that frame lands. A frame never renders from a stale recording, and frames never queue
///   up behind a slow one.
/// - **A new canvas is drawn on the main thread, whole.** A resize, a move to another display or a
///   UI Size change render synchronously, as every frame used to, so the window never shows a
///   picture of the wrong size. Steady-state repaints (meters, readouts, slides) take the queue.
final class WinampModernFrames {
    let canvas = WinampModernCanvas()
    let queue = DispatchQueue(label: "NullPlayer.WinampModernCanvas", qos: .userInteractive)

    /// Rects owed a new frame, in view points.
    var pendingDirty: [NSRect] = []
    var isScheduled = false
    var isInFlight = false
    /// The window is too large for a canvas and draws itself (`drawDirectly`).
    var drawsDirectly = false

    /// The newest picture, and the number of the frame it came from. Frames render in order on
    /// `queue`, so a later number is a newer picture; one that lands behind a newer one is dropped.
    var picture: CGImage?
    /// The newest outline a frame reported, for the drop shadow (`WinampModernMainView+Shadow`),
    /// numbered apart from the picture: a frame whose picture lands behind a newer one still carries
    /// the outline change the newer frame, compared after it, did not see.
    var outline: CGImage?
    var outlineNumber = 0
    var pictureNumber = 0
    var nextNumber = 0

    /// `WINAMP_MODERN_SYNC_FRAMES=1`: render every frame on the main thread. The A/B switch for "did
    /// rendering off the main thread cause this?".
    static let rendersSynchronously = ProcessInfo.processInfo.environment["WINAMP_MODERN_SYNC_FRAMES"] == "1"
}

extension WinampModernMainView {
    func requestFrame(_ rect: NSRect) {
        let rect = rect.intersection(bounds)
        guard !rect.isNull, !rect.isEmpty, !isTornDown else { return }
        // A hidden window keeps no dirt: `occlusionDidChange` asks for a whole frame on reveal, and
        // a script repainting 30 times a second would otherwise grow the list for as long as it hides.
        guard isOnScreen else {
            repaintDeferredWhileHidden = true
            return
        }
        frames.pendingDirty.append(rect)
        guard !frames.isScheduled else { return }
        frames.isScheduled = true
        DispatchQueue.main.async { [weak self] in self?.pumpFrame() }
    }

    /// Record a frame for the pending dirt and send it to the queue, unless one is in flight.
    private func pumpFrame() {
        frames.isScheduled = false
        guard !isTornDown, !frames.isInFlight, !frames.pendingDirty.isEmpty else { return }
        // Hidden since the dirt was queued: dropped, as `requestFrame` drops it.
        guard isOnScreen else {
            frames.pendingDirty = []
            repaintDeferredWhileHidden = true
            return
        }
        let dirty = frames.pendingDirty
        frames.pendingDirty = []
        guard let job = makeJob(dirty: dirty) else { return }
        let number = nextFrameNumber()
        if job.isWhole || WinampModernFrames.rendersSynchronously {
            show(frames.queue.sync { frames.canvas.render(job.job) }, number: number, rects: job.viewRects)
            return
        }
        frames.isInFlight = true
        let canvas = frames.canvas
        frames.queue.async { [weak self] in
            let frame = canvas.render(job.job)
            DispatchQueue.main.async {
                guard let self else { return }
                self.frames.isInFlight = false
                self.show(frame, number: number, rects: job.viewRects)
                self.pumpFrame()
            }
        }
    }

    private func nextFrameNumber() -> Int {
        frames.nextNumber += 1
        return frames.nextNumber
    }

    private func show(_ frame: WinampModernCanvas.Frame?, number: Int, rects: [NSRect]) {
        guard !isTornDown, let frame else { return }
        if let outline = frame.outline, number > frames.outlineNumber {
            frames.outline = outline
            frames.outlineNumber = number
            windowShadow.invalidateShape("draw")
        }
        guard number > frames.pictureNumber else { return }
        frames.picture = frame.picture
        frames.pictureNumber = number
        if Self.paintRateProbe { recordPaint(rects) }
        setLayerContents(frame.picture)
    }

    /// `updateLayer`'s job: show the newest picture. A picture of the wrong size — the first display,
    /// a resize AppKit displays before any frame lands — is replaced on the spot, whole, and so is
    /// every rect still waiting for a frame.
    func showFrame() {
        let size = pixelSize(scale: window?.backingScaleFactor ?? 1)
        if frames.picture.map({ $0.width != size.width || $0.height != size.height }) ?? true,
           let job = makeJob(dirty: [bounds]) {
            frames.pendingDirty = []
            show(frames.queue.sync { frames.canvas.render(job.job) }, number: nextFrameNumber(),
                 rects: job.viewRects)
        } else if let picture = frames.picture {
            setLayerContents(picture)
        }
    }

    private func setLayerContents(_ picture: CGImage) {
        guard let layer else { return }
        let scale = window?.backingScaleFactor ?? 1
        // The picture is whole device pixels, so it can overhang the bounds by a fraction of one at
        // the top; pinned to the bottom-left it is never stretched.
        if layer.contentsScale != scale { layer.contentsScale = scale }
        if layer.contentsGravity != .bottomLeft { layer.contentsGravity = .bottomLeft }
        layer.contents = picture
    }

    /// A turn's dirt without the rects another one already covers: the same meter box invalidated
    /// by every script write in the turn is one rect to draw, not twenty. Past a handful the bounding
    /// box is cheaper than the list.
    static func coalesced(_ rects: [CGRect]) -> [CGRect] {
        var kept: [CGRect] = []
        for rect in rects.sorted(by: { $0.width * $0.height > $1.width * $1.height })
        where !kept.contains(where: { $0.contains(rect) }) {
            kept.append(rect)
        }
        guard kept.count > 8 else { return kept }
        return [kept.dropFirst().reduce(kept[0]) { $0.union($1) }]
    }

    private func pixelSize(scale: CGFloat) -> (width: Int, height: Int) {
        (Int((bounds.width * scale).rounded(.up)), Int((bounds.height * scale).rounded(.up)))
    }

    /// The scene recorded for `dirty` (view points). Nil for a window too large to hold a canvas;
    /// no corpus window comes near the limit.
    private func makeJob(dirty: [NSRect]) -> (job: WinampModernCanvas.Job, viewRects: [NSRect], isWhole: Bool)? {
        let scale = window?.backingScaleFactor ?? 1
        let (pixelWidth, pixelHeight) = pixelSize(scale: scale)
        let fits = pixelWidth * pixelHeight <= WasabiSceneRenderer.maximumPrescaledPixels
        if frames.drawsDirectly == fits {
            frames.drawsDirectly = !fits
            if !fits { Self.logOversizedCanvasOnce(pixelWidth: pixelWidth, pixelHeight: pixelHeight) }
            layer?.contents = nil
            super.setNeedsDisplay(bounds)
        }
        guard pixelWidth > 0, pixelHeight > 0, fits else { return nil }
        let whole = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        // Snapped out to whole device pixels, so a partial repaint's edges land on the grid the
        // canvas is drawn on. A new canvas is drawn whole: only the dirty rects would be filled.
        let colorSpace = WinampModernCanvas.colorSpace(matching: window?.colorSpace?.cgColorSpace)
        let isWhole = frames.canvas.isFresh(pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                            colorSpace: colorSpace)
        let rects = isWhole
            ? [whole]
            : Self.coalesced(dirty.map { $0.applying(CGAffineTransform(scaleX: scale, y: scale)).integral.intersection(whole) }
                .filter { !$0.isNull && !$0.isEmpty })
        guard !rects.isEmpty else { return nil }
        let clip = rects.dropFirst().reduce(rects[0]) { $0.union($1) }

        // Which of `activealpha`/`inactivealpha` every object paints at. Read here rather than
        // cached on the notification: a window can lose key without either notification reaching us
        // (the app deactivating, a sheet), and the read is one Boolean.
        renderer.isWindowActive = window?.isKeyWindow ?? true
        let base = CGAffineTransform(scaleX: scale, y: scale)
        let scene = WasabiDrawList(ctm: base, clip: clip)
        scene.saveGState()
        if skinScale != 1 { scene.scaleBy(x: skinScale, y: skinScale) }
        renderer.record(into: scene, pressed: pressedObject?.stableID, hovered: hoveredObject?.stableID)
        scene.restoreGState()
        var chrome: WasabiDrawList?
        if drawsHostChrome {
            let list = WasabiDrawList(ctm: base, clip: clip)
            if skinScale != 1 { list.scaleBy(x: skinScale, y: skinScale) }
            drawHostChrome(in: list)
            chrome = list
        }
        let job = WinampModernCanvas.Job(
            pixelWidth: pixelWidth, pixelHeight: pixelHeight, colorSpace: colorSpace, scale: scale, rects: rects,
            scene: scene, chrome: chrome, promotesAlpha: renderer.layoutWantsOpaqueBacking)
        let viewRects = rects.map { $0.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)) }
        return (job, viewRects, isWhole)
    }

    /// A window too large for a canvas draws straight into AppKit's context, as a translucent layout
    /// once did. Its shadow keeps its last shape.
    func drawDirectly(in context: CGContext) {
        renderer.isWindowActive = window?.isKeyWindow ?? true
        // A display-list context arrives at CTM 1.0 and is replayed at the backing scale, a bitmap
        // one already carries it (B80).
        let contextScale = abs(context.ctm.a)
        let pixelsPerUnit = contextScale > 0 ? max(1, (window?.backingScaleFactor ?? 1) / contextScale) : 1
        context.saveGState()
        if skinScale != 1 { context.scaleBy(x: skinScale, y: skinScale) }
        let clip = context.boundingBoxOfClipPath.applying(context.ctm)
        if drawsHostChrome {
            let chrome = WasabiDrawList(ctm: context.ctm, clip: clip, devicePixelsPerUnit: pixelsPerUnit)
            drawHostChrome(in: chrome)
            chrome.replay(into: context)
        }
        let scene = WasabiDrawList(ctm: context.ctm, clip: clip, interpolationQuality: context.interpolationQuality,
                                   devicePixelsPerUnit: pixelsPerUnit)
        renderer.record(into: scene, pressed: pressedObject?.stableID, hovered: hoveredObject?.stableID)
        scene.replay(into: context)
        context.restoreGState()
    }

    private static var oversizedCanvasLogged = false

    private static func logOversizedCanvasOnce(pixelWidth: Int, pixelHeight: Int) {
        guard !oversizedCanvasLogged else { return }
        oversizedCanvasLogged = true
        NSLog("[wal] canvas %dx%d is over the pixel limit; drawing the window directly", pixelWidth, pixelHeight)
    }
}
