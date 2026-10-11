import AppKit

/// Parametric mode's controls in a channel panel, below the analyser: a response graph, then the
/// high-pass and the four bands, each a title row (with its switch) over its dials. Layout,
/// hit-testing and drawing; the Studio view owns the edit.
struct StudioStrip {
    let graph: CGRect
    private let titles: [(String, CGRect)]
    private let switches: [(EQParametric.Switch, CGRect)]
    private let knobs: [(EQParametric.Knob, CGRect)]

    private static let graphFrequencies: [(Double, String)] = [
        (50, "50"), (100, "100"), (200, "200"), (500, "500"), (1000, "1k"), (2000, "2k"), (5000, "5k"), (10000, "10k")]

    init(in region: CGRect) {
        let graph = CGRect(x: region.minX, y: region.minY, width: region.width, height: 50)
        self.graph = graph
        let top = graph.maxY + 8, height = region.maxY - top
        let highPassWidth: CGFloat = 56, gap: CGFloat = 8, dial: CGFloat = 38
        let bands = EQParametric.layout
        let bandWidth = (region.width - highPassWidth - gap * CGFloat(bands.count)) / CGFloat(bands.count)
        let sections = [("HPF", CGRect(x: region.minX, y: top, width: highPassWidth, height: height), [EQParametric.Knob.highPass])]
            + bands.indices.map { band in
                (bands[band].name,
                 CGRect(x: region.minX + highPassWidth + gap + CGFloat(band) * (bandWidth + gap), y: top,
                        width: bandWidth, height: height),
                 EQParametric.Knob.knobs(of: band))
            }
        titles = sections.map { ($0.0, CGRect(x: $0.1.minX, y: $0.1.minY, width: 30, height: 15)) }
        // Top right of its section: the high-pass's ON, a band's SHELF.
        func switchRect(_ section: Int, width: CGFloat) -> CGRect {
            let frame = sections[section].1
            return CGRect(x: frame.maxX - width, y: frame.minY, width: width, height: 15)
        }
        switches = EQParametric.Switch.all.map { toggle in
            switch toggle {
            case .highPass: return (toggle, switchRect(0, width: 26))
            case .shelf(let band): return (toggle, switchRect(band + 1, width: 40))
            }
        }
        knobs = sections.flatMap { _, frame, knobs in
            let cell = frame.width / CGFloat(knobs.count)
            return knobs.enumerated().map { index, knob in
                (knob, CGRect(x: frame.minX + (CGFloat(index) + 0.5) * cell - dial / 2, y: frame.minY + 21,
                              width: dial, height: dial))
            }
        }
    }

    func toggle(at point: CGPoint) -> EQParametric.Switch? {
        switches.first { $0.1.contains(point) }?.0
    }

    func knob(at point: CGPoint) -> EQParametric.Knob? {
        knobs.first { $0.1.insetBy(dx: -4, dy: -4).contains(point) }?.0
    }

    /// `x` places a frequency on the analyser's axis; `drawResponse` strokes the curve heard into a rect.
    func draw(_ parametric: EQParametric, x: (Double) -> CGFloat, drawResponse: (CGRect) -> Void, _ f: StudioFaceplate) {
        // Graph: a fine grid, the response, and a dot per band at its frequency and gain.
        f.well.setFill()
        NSBezierPath(roundedRect: graph, xRadius: 2, yRadius: 2).fill()
        for db: Float in [-12, -6, 0, 6, 12] {
            let y = graph.y(gain: db).rounded() + 0.5
            (db == 0 ? f.graticuleZero : f.graticule).setFill()
            NSRect(x: graph.minX, y: y - 0.25, width: graph.width - 24, height: db == 0 ? 1 : 0.5).fill()
            if db.truncatingRemainder(dividingBy: 12) == 0 {
                f.drawText(StudioFaceplate.dbLabel(db), font: f.legendFont, color: f.dimText.withAlphaComponent(0.7),
                           in: CGRect(x: graph.maxX - 22, y: y - 6, width: 20, height: 12), alignment: .right)
            }
        }
        for (frequency, label) in Self.graphFrequencies {
            let x = x(frequency)
            f.graticule.setFill()
            NSRect(x: x, y: graph.minY, width: 0.5, height: graph.height).fill()
            f.drawText(label, font: f.legendFont, color: f.dimText.withAlphaComponent(0.7),
                       in: CGRect(x: x + 2, y: graph.maxY - 11, width: 24, height: 10))
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: graph).addClip()
        drawResponse(graph)
        for band in parametric.bands {
            let centre = CGPoint(x: x(Double(band.frequency)), y: graph.y(gain: band.gain))
            (band.gain == 0 ? f.dimText : f.accent).setFill()
            NSBezierPath(ovalIn: CGRect(x: centre.x - 2.5, y: centre.y - 2.5, width: 5, height: 5)).fill()
        }
        if parametric.highPassOn {
            f.accent.setFill()
            NSRect(x: x(Double(parametric.highPass)) - 0.5, y: graph.minY, width: 1, height: graph.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        for (title, rect) in titles {
            f.drawText(title, font: f.buttonFont, color: f.text, in: rect)
        }
        for (toggle, rect) in switches {
            f.drawButton(toggle == .highPass ? "ON" : "SHELF", in: rect, lit: parametric[toggle])
        }
        for (knob, rect) in knobs {
            let active = parametric.isActive(knob)
            Self.drawKnob(knob, value: parametric[knob], active: active, in: rect, f)
            f.drawText(Self.readout(knob, parametric[knob]), font: f.legendFont,
                       color: active ? f.dimText : f.dimText.withAlphaComponent(0.4),
                       in: CGRect(x: rect.midX - 24, y: rect.maxY + 4, width: 48, height: 11), alignment: .center)
        }
    }

    private static func readout(_ knob: EQParametric.Knob, _ value: Float) -> String {
        switch knob {
        case .highPass, .frequency:
            return value >= 1000 ? String(format: "%.2f kHz", value / 1000) : String(format: "%.0f Hz", value)
        case .gain: return String(format: "%+.1f dB", value)
        case .q: return String(format: "Q %.2f", value)
        }
    }

    /// A thin ring over 270° of travel, lit from its origin (12 o'clock for gain, the stop otherwise)
    /// to the value, with a hairline pointer.
    private static func drawKnob(_ knob: EQParametric.Knob, value: Float, active: Bool, in rect: CGRect, _ f: StudioFaceplate) {
        let centre = CGPoint(x: rect.midX, y: rect.midY), radius = rect.width / 2
        func point(_ position: Float, _ r: CGFloat) -> CGPoint {
            let angle = CGFloat(-135 + 270 * position) * .pi / 180
            return CGPoint(x: centre.x + r * sin(angle), y: centre.y - r * cos(angle))
        }
        func arc(_ from: Float, _ to: Float) -> NSBezierPath {
            let path = NSBezierPath()
            let steps = max(1, Int(abs(to - from) * 48))
            for i in 0...steps {
                let p = point(from + (to - from) * Float(i) / Float(steps), radius - 1)
                i == 0 ? path.move(to: p) : path.line(to: p)
            }
            return path
        }
        let alpha: CGFloat = active ? 1 : 0.35
        let position = knob.position(of: value)
        let origin: Float
        if case .gain = knob { origin = 0.5 } else { origin = 0 }

        let track = arc(0, 1)
        track.lineWidth = 1
        f.slot.withAlphaComponent(alpha).setStroke()
        track.stroke()
        let lit = arc(origin, position)
        lit.lineWidth = 2
        f.accent.withAlphaComponent(alpha).setStroke()
        lit.stroke()

        let body = NSBezierPath(ovalIn: rect.insetBy(dx: 5, dy: 5))
        f.well.setFill()
        body.fill()
        body.lineWidth = 0.5
        f.edge.setStroke()
        body.stroke()
        let pointer = NSBezierPath()
        pointer.move(to: point(position, radius * 0.2))
        pointer.line(to: point(position, radius - 6))
        pointer.lineWidth = 1
        f.text.withAlphaComponent(alpha).setStroke()
        pointer.stroke()
    }
}
