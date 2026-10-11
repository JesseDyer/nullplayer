import AppKit

/// One of the Studio's two looks. Fixed colours and type — only the rim around it takes the skin's
/// colours. One layout reads it, and the looks differ in these values, except for the three things
/// drawn per `kind`: the analyser (bars or a filled curve), the fader caps, and the fader scale's
/// engraving.
struct StudioFaceplate {
    enum Kind: String { case console, boutique }

    let kind: Kind
    let panel: NSColor
    let well: NSColor
    let edge: NSColor
    let text: NSColor
    let dimText: NSColor
    let accent: NSColor
    let scale: NSColor
    let slot: NSColor
    /// Fader caps by range: low, mid, high.
    let caps: [NSColor]
    let peak: NSColor
    /// Colours at analyser levels (dB), coolest first: Console's bars step through them, Boutique
    /// grades its analyser fill and peak embers with them.
    let heat: [(db: Float, color: NSColor)]
    let legendFont: NSFont
    let buttonFont: NSFont
    let titleFont: NSFont
    /// The analyser's dB lines: their spacing, weight and colour (0 dB's own). Labelled every 12 dB.
    let graticuleStep: Float
    let graticuleWeight: CGFloat
    let graticule: NSColor
    let graticuleZero: NSColor
    /// A hairline at every octave behind the analyser.
    let octaveGrid: Bool
    /// The fader scale's lines and the dB labels beside the preamp.
    let faderTicks: [Float]
    let faderTickLabels: [Float]
    let slotWidth: CGFloat
    let capWidth: CGFloat

    static let defaultsKey = "equalizerStudioFaceplate"

    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    private static func font(_ name: String, _ size: CGFloat, fallback weight: NSFont.Weight) -> NSFont {
        NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    func capColor(band: Int) -> NSColor { caps[band < 10 ? 0 : band < 21 ? 1 : 2] }

    /// Console: SSL / Neve / Manley mastering — matte grey-blue, engraved scales, colour-coded caps,
    /// condensed legends, bar metering on a dB graticule.
    static let console = StudioFaceplate(
        kind: .console, panel: rgb(0x4a5463), well: rgb(0x1b2027), edge: rgb(0x2b313a),
        text: rgb(0xe6e9ec), dimText: rgb(0x9ba5b0), accent: rgb(0xf2b33d), scale: rgb(0xc9ced4),
        slot: rgb(0x14181d), caps: [rgb(0xd9822b), rgb(0xe9e3d1), rgb(0x3f7fd9)],
        peak: rgb(0xff5a4a),
        heat: [(-78, rgb(0x4fc36b)), (-12, rgb(0xe6c341)), (-3, rgb(0xff5a4a))],
        legendFont: font("AvenirNextCondensed-DemiBold", 8, fallback: .semibold),
        buttonFont: font("AvenirNextCondensed-Bold", 10, fallback: .bold),
        titleFont: font("AvenirNextCondensed-DemiBold", 14, fallback: .semibold),
        graticuleStep: 12, graticuleWeight: 1,
        graticule: rgb(0xc9ced4, 0.15), graticuleZero: rgb(0xc9ced4, 0.35), octaveGrid: false,
        faderTicks: [12, 6, 3, 0, -3, -6, -12], faderTickLabels: [12, 6, 0, -6, -12],
        slotWidth: 3, capWidth: 14)

    /// Boutique DSP: Weiss / Dangerous / Bricasti — flat black glass, thin type, one Nixie-orange
    /// accent, slim line faders, the analyser as a curve filled with heat on a fine grid.
    static let boutique = StudioFaceplate(
        kind: .boutique, panel: rgb(0x0b0c0e), well: rgb(0x050607), edge: rgb(0x1c1e22),
        text: rgb(0xd9dbde), dimText: rgb(0x6d727a), accent: rgb(0xff8c42), scale: rgb(0x23262b),
        slot: rgb(0x2a2d33), caps: [rgb(0xff8c42), rgb(0xff8c42), rgb(0xff8c42)],
        peak: rgb(0xfff2d6),
        heat: [(-78, rgb(0x140503)), (-48, rgb(0x4a0f06)), (-30, rgb(0x9a2a0c)), (-18, rgb(0xe0521a)),
               (-9, rgb(0xff8c42)), (-3, rgb(0xffc65c)), (0, rgb(0xfff2d6))],
        legendFont: font("HelveticaNeue-Light", 8, fallback: .light),
        buttonFont: font("HelveticaNeue-Light", 9.5, fallback: .light),
        titleFont: font("HelveticaNeue-Thin", 15, fallback: .thin),
        graticuleStep: 6, graticuleWeight: 0.5,
        graticule: rgb(0x23262b), graticuleZero: rgb(0x23262b), octaveGrid: true,
        faderTicks: [0], faderTickLabels: [],
        slotWidth: 1, capWidth: 10)

    static var stored: StudioFaceplate {
        UserDefaults.standard.string(forKey: defaultsKey) == Kind.boutique.rawValue ? .boutique : .console
    }
}

/// The Studio's drawing primitives: they read only the faceplate.
extension StudioFaceplate {
    func drawText(_ string: String, font: NSFont, color: NSColor, in rect: CGRect,
                  alignment: NSTextAlignment = .left) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let height = (string as NSString).size(withAttributes: attributes).height
        (string as NSString).draw(in: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height),
                                  withAttributes: attributes)
    }

    func drawButton(_ title: String, in rect: CGRect, lit: Bool, enabled: Bool = true) {
        (lit ? accent : well).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        edge.setStroke()
        NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke()
        let color = lit ? panel : enabled ? text : dimText.withAlphaComponent(0.5)
        drawText(title, font: buttonFont, color: color, in: rect, alignment: .center)
    }

    func drawFader(x: CGFloat, value: Float, in rect: CGRect, cap: NSColor, width: CGFloat) {
        slot.setFill()
        NSRect(x: x - slotWidth / 2, y: rect.minY + 4, width: slotWidth, height: rect.height - 8).fill()
        let y = rect.y(gain: value)
        switch kind {
        case .console:
            let capRect = CGRect(x: x - width / 2, y: y - 4.5, width: width, height: 9)
            NSColor.black.withAlphaComponent(0.4).setFill()
            capRect.offsetBy(dx: 0, dy: 1).fill()
            cap.setFill()
            NSBezierPath(roundedRect: capRect, xRadius: 1.5, yRadius: 1.5).fill()
            NSColor.white.withAlphaComponent(0.45).setFill()
            NSRect(x: capRect.minX + 1, y: capRect.minY + 1, width: capRect.width - 2, height: 1).fill()
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSRect(x: capRect.minX + 1, y: capRect.midY - 0.5, width: capRect.width - 2, height: 1).fill()
        case .boutique:
            let zero = rect.y(gain: 0)
            cap.withAlphaComponent(0.35).setFill()
            NSRect(x: x - 0.5, y: min(y, zero), width: 1, height: abs(y - zero)).fill()
            cap.setFill()
            NSRect(x: x - width / 2, y: y - 1, width: width, height: 2).fill()
        }
    }

    /// A dB scale label: signed, but a bare 0.
    static func dbLabel(_ db: Float) -> String {
        String(format: "%+.0f", db).replacingOccurrences(of: "+0", with: "0")
    }
}

/// The Studio's ±12 dB scale — faders, the preamp, the response curves — inset 6 points at each end.
extension CGRect {
    func y(gain: Float) -> CGFloat {
        minY + 6 + CGFloat((12 - gain) / 24) * (height - 12)
    }

    /// To 0.1 dB, clamped.
    func gain(y: CGFloat) -> Float {
        let g = 12 - Float((y - minY - 6) / (height - 12)) * 24
        return EQCurve.clamp((g * 10).rounded() / 10)
    }
}
