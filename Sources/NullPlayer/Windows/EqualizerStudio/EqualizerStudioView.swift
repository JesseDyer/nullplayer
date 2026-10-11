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

/// The Studio's single view: header, buttons and two channel panels (L above R), each a per-channel
/// analyser over 31 band faders — or, in parametric mode, a response graph over a channel strip's
/// dials — plus a preamp, with its own FLAT and BYPASS under the channel name. Both stages are always
/// heard and every curve drawn is their sum; the mode only picks which controls are shown. Edits are
/// heard live (the profile controller's `audition`) and discarded unless saved.
final class EqualizerStudioView: NSView {
    private enum Button: CaseIterable {
        case link, mode, headroom, save, saveAs, rename, delete, revert, faceplate

        var title: String {
            switch self {
            case .link: return "LINK"
            case .mode: return "MODE"
            case .headroom: return "HEADROOM"
            case .save: return "SAVE"
            case .saveAs: return "SAVE AS"
            case .rename: return "RENAME"
            case .delete: return "DELETE"
            case .revert: return "REVERT"
            case .faceplate: return "FACEPLATE"
            }
        }
    }

    /// A band fader (`band` 0…30) or the preamp (`band` nil) of one channel.
    private struct Fader: Equatable {
        let channel: Int
        let band: Int?
    }

    private struct Panel {
        let frame: CGRect
        /// The left column, top to bottom.
        let name: CGRect
        let peakReadout: CGRect
        let preampReadout: CGRect
        let flat: CGRect
        let bypass: CGRect
        let analyser: CGRect
        let faders: CGRect
        let legend: CGRect
        let preamp: CGRect
        let bandX0: CGFloat
        let bandWidth: CGFloat

        /// Parametric mode's use of the fader and legend rows, and of what the analyser gives up.
        var strip: CGRect { CGRect(x: bandX0, y: analyser.maxY + 6, width: analyser.width, height: legend.maxY - analyser.maxY - 6) }

        func centreX(_ band: Int) -> CGFloat { bandX0 + (CGFloat(band) + 0.5) * bandWidth }
        /// Continuous x for a frequency: the ISO centres sit ⅓ octave apart.
        func x(frequency: Double) -> CGFloat { bandX0 + (CGFloat(log2(frequency / 20) * 3) + 0.5) * bandWidth }
    }

    private enum StripSwitch: Equatable {
        case highPass
        case shelf(Int)
    }

    private enum StripControl {
        case toggle(StripSwitch)
        case knob(EQParametric.Knob)
    }

    /// Parametric mode below the analyser: a response graph, then the high-pass and the four bands,
    /// each a title row (with its switch) over its dials.
    private struct Strip {
        let graph: CGRect
        let titles: [(String, CGRect)]
        let switches: [(StripSwitch, CGRect)]
        let knobs: [(EQParametric.Knob, CGRect)]
    }

    /// Which stage's controls are shown. Not part of the profile: both stages are always heard.
    private enum Mode: String { case graphic, parametric }

    private static let linkedKey = "equalizerStudioLinked"
    private static let modeKey = "equalizerStudioMode"
    /// Response and peaks are shown at this rate; the stream's own rate differs only above 20 kHz.
    private static let displayRate = 48000.0
    private static let gridFrequencies: [Double] = (0...180).map { 20 * pow(1000, Double($0) / 180) }
    private static let bandLabels = ["20", "25", "31", "40", "50", "63", "80", "100", "125", "160", "200",
                                     "250", "315", "400", "500", "630", "800", "1k", "1.2k", "1.6k", "2k",
                                     "2.5k", "3.1k", "4k", "5k", "6.3k", "8k", "10k", "12k", "16k", "20k"]
    private static let analyserRange: ClosedRange<Float> = -78...6

    private let store = EQProfileStore.shared
    private var controller: EQProfileController { WindowManager.shared.audioEngine.eqProfileController }
    private let rta = StudioRTA()

    private var edit = EQCurve.flat
    private var profileID: UUID?
    private var name = "New"
    /// Per channel: heard flat, for this session. A monitoring switch, not an edit, so LINK leaves it alone.
    private var bypass = [false, false]
    private var linked = true
    private var mode = Mode.graphic
    private var faceplate = StudioFaceplate.console
    private var dragging: Fader?
    /// A dial being turned, and the pointer's last y.
    private var turning: (channel: Int, knob: EQParametric.Knob, y: CGFloat)?
    /// Per channel: both stages' response (no preamp) on `gridFrequencies`, at the band centres, and its peak, dB.
    private var response: [[Double]] = [[], []]
    private var centreResponse: [[Double]] = [[], []]
    /// Per channel: the parametric strip alone at the band centres, dB. A band fader shows its graphic
    /// share on top of this, so the faders sit on the curve; dragging moves only the share.
    private var stripAtCentre = [[Float]](repeating: [Float](repeating: 0, count: EQProfileDesign.bandCount), count: 2)
    private var peakDB: [Double] = [0, 0]
    private var levels = [[Float]](repeating: [Float](repeating: StudioRTA.floorDB, count: EQProfileDesign.bandCount), count: 2)
    private var peaks = [[Float]](repeating: [Float](repeating: StudioRTA.floorDB, count: EQProfileDesign.bandCount), count: 2)

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Layout (fixed size)

    private var content: CGRect { bounds.insetBy(dx: SkinnedSurfaceChrome.glossBorder, dy: SkinnedSurfaceChrome.glossBorder) }
    private var nameRect: CGRect { CGRect(x: content.minX + 12, y: content.minY + 8, width: 330, height: 26) }
    private var closeRect: CGRect { CGRect(x: content.maxX - 28, y: content.minY + 10, width: 18, height: 18) }

    private var buttonRects: [(Button, CGRect)] {
        let count = CGFloat(Button.allCases.count), gap: CGFloat = 6
        let width = (content.width - 24 - gap * (count - 1)) / count
        return Button.allCases.enumerated().map { index, button in
            (button, CGRect(x: content.minX + 12 + CGFloat(index) * (width + gap), y: content.minY + 42,
                            width: width, height: 20))
        }
    }

    private var panels: [Panel] {
        let top = content.minY + 72
        let height = (content.maxY - 6 - top) / 2
        return (0..<2).map { channel in
            let frame = CGRect(x: content.minX + 8, y: top + CGFloat(channel) * height,
                               width: content.width - 16, height: height - 6)
            let inner = frame.insetBy(dx: 8, dy: 8)
            let column: CGFloat = 52
            let bandX0 = inner.minX + column + 8
            // Parametric mode shortens the analyser to give the strip's dials room.
            let analyser = CGRect(x: bandX0, y: inner.minY, width: inner.maxX - bandX0,
                                  height: mode == .graphic ? 74 : 56)
            let faders = CGRect(x: bandX0, y: inner.minY + 82, width: analyser.width, height: 112)
            func row(_ y: CGFloat, _ height: CGFloat) -> CGRect {
                CGRect(x: inner.minX, y: inner.minY + y, width: column, height: height)
            }
            return Panel(frame: frame,
                         name: row(0, 18), peakReadout: row(19, 11), preampReadout: row(30, 11),
                         flat: row(44, 14), bypass: row(60, 14),
                         analyser: analyser, faders: faders,
                         legend: CGRect(x: bandX0, y: faders.maxY + 3, width: analyser.width, height: 11),
                         preamp: CGRect(x: inner.minX + 14, y: faders.minY, width: 24, height: faders.height),
                         // The analyser's dB labels sit in a gutter right of the 20 kHz band.
                         bandX0: bandX0, bandWidth: (analyser.width - 24) / CGFloat(EQProfileDesign.bandCount))
        }
    }

    private func strip(_ panel: Panel) -> Strip {
        let region = panel.strip
        let graph = CGRect(x: region.minX, y: region.minY, width: region.width, height: 50)
        let top = graph.maxY + 8, height = region.maxY - top
        let highPassWidth: CGFloat = 56, gap: CGFloat = 8, dial: CGFloat = 38
        let bandWidth = (region.width - highPassWidth - gap * 4) / 4
        var sections = [("HPF", CGRect(x: region.minX, y: top, width: highPassWidth, height: height), [EQParametric.Knob.highPass])]
        for band in 0..<4 {
            let frame = CGRect(x: region.minX + highPassWidth + gap + CGFloat(band) * (bandWidth + gap), y: top,
                               width: bandWidth, height: height)
            sections.append((EQParametric.bandNames[band], frame, [.frequency(band), .gain(band), .q(band)]))
        }
        func switchRect(_ frame: CGRect, width: CGFloat) -> CGRect {
            CGRect(x: frame.maxX - width, y: frame.minY, width: width, height: 15)
        }
        return Strip(
            graph: graph,
            titles: sections.map { ($0.0, CGRect(x: $0.1.minX, y: $0.1.minY, width: 30, height: 15)) },
            switches: [(.highPass, switchRect(sections[0].1, width: 26))]
                + EQParametric.shelvingBands.map { (.shelf($0), switchRect(sections[$0 + 1].1, width: 40)) },
            knobs: sections.flatMap { _, frame, knobs in
                let cell = frame.width / CGFloat(knobs.count)
                return knobs.enumerated().map { index, knob in
                    (knob, CGRect(x: frame.minX + (CGFloat(index) + 0.5) * cell - dial / 2, y: frame.minY + 21,
                                  width: dial, height: dial))
                }
            })
    }

    private func y(gain: Float, in rect: CGRect) -> CGFloat {
        rect.minY + 6 + CGFloat((12 - gain) / 24) * (rect.height - 12)
    }

    private func gain(y: CGFloat, in rect: CGRect) -> Float {
        let g = 12 - Float((y - rect.minY - 6) / (rect.height - 12)) * 24
        return EQCurve.clamp((g * 10).rounded() / 10)
    }

    // MARK: - Open / close

    func studioDidOpen() {
        linked = UserDefaults.standard.object(forKey: Self.linkedKey) as? Bool ?? true
        mode = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(Mode.init) ?? .graphic
        faceplate = .stored
        bypass = [false, false]
        if let track = WindowManager.shared.audioEngine.currentTrack, let profile = EQProfileResolver.shared.resolve(track)?.profile {
            load(profile)
        } else {
            loadNew()
        }
        rta.onUpdate = { [weak self] levels, peaks in
            self?.levels = levels
            self?.peaks = peaks
            self?.needsDisplay = true
        }
        rta.start()
    }

    func studioDidClose() {
        rta.stop()
        rta.onUpdate = nil
        bypass = [false, false]
        controller.audition = nil
    }

    private func load(_ profile: EQProfile) {
        profileID = profile.id
        name = profile.name
        edit = profile.curve
        editDidChange()
    }

    private func loadNew() {
        profileID = nil
        name = "New"
        edit = .flat
        editDidChange()
    }

    private var savedCurve: EQCurve { profileID.flatMap { store.profile($0)?.curve } ?? .flat }
    private var isDirty: Bool { edit != savedCurve }

    private func editDidChange() {
        for channel in 0..<2 {
            let sections = EQProfileDesign.sections(for: edit, channel: channel, sampleRate: Self.displayRate)
            func respond(_ frequency: Double) -> Double {
                EQProfileDesign.responseDB(sections, frequency: frequency, sampleRate: Self.displayRate)
            }
            response[channel] = Self.gridFrequencies.map(respond)
            centreResponse[channel] = EQProfileDesign.frequencies.map(respond)
            let strip = edit[channel].parametric.sections(sampleRate: Self.displayRate)
            stripAtCentre[channel] = EQProfileDesign.frequencies.map {
                Float(EQProfileDesign.responseDB(strip, frequency: $0, sampleRate: Self.displayRate))
            }
            peakDB[channel] = response[channel].max() ?? 0
        }
        pushAudition()
    }

    private func pushAudition() {
        var heard = edit
        for channel in 0..<2 where bypass[channel] { heard[channel] = .flat }
        controller.audition = heard
        needsDisplay = true
    }

    // MARK: - Editing

    /// Where a fader's cap is drawn and dragged: a band fader adds the strip at its centre; the preamp is itself.
    private func offset(_ fader: Fader) -> Float {
        fader.band.map { stripAtCentre[fader.channel][$0] } ?? 0
    }

    private func value(_ fader: Fader) -> Float {
        fader.band.map { edit[fader.channel].bands[$0] } ?? edit[fader.channel].preamp
    }

    private func set(_ fader: Fader, _ value: Float) {
        let value = EQCurve.clamp(value)
        if let band = fader.band { edit[fader.channel].bands[band] = value } else { edit[fader.channel].preamp = value }
    }

    /// LINK lit moves the other channel's fader by the same amount, so channels that differ keep
    /// their difference.
    private func move(_ fader: Fader, to newValue: Float) {
        let old = value(fader)
        let new = EQCurve.clamp(newValue)
        guard new != old else { return }
        set(fader, new)
        if linked {
            let other = Fader(channel: 1 - fader.channel, band: fader.band)
            set(other, value(other) + (new - old))
        }
        editDidChange()
    }

    private func reset(_ fader: Fader) {
        set(fader, 0)
        if linked { set(Fader(channel: 1 - fader.channel, band: fader.band), 0) }
        editDidChange()
    }

    /// LINK lit turns the other channel's dial by the same travel, as with faders.
    private func turn(_ knob: EQParametric.Knob, channel: Int, by travel: Float) {
        let old = edit[channel].parametric[knob]
        edit[channel].parametric[knob] = knob.value(at: knob.position(of: old) + travel)
        let moved = knob.position(of: edit[channel].parametric[knob]) - knob.position(of: old)
        guard moved != 0 else { return }
        if linked {
            let other = edit[1 - channel].parametric[knob]
            edit[1 - channel].parametric[knob] = knob.value(at: knob.position(of: other) + moved)
        }
        editDidChange()
    }

    private func reset(_ knob: EQParametric.Knob, channel: Int) {
        for channel in linked ? [0, 1] : [channel] { edit[channel].parametric[knob] = EQParametric.flat[knob] }
        editDidChange()
    }

    private func isOn(_ toggle: StripSwitch, channel: Int) -> Bool {
        switch toggle {
        case .highPass: return edit[channel].parametric.highPassOn
        case .shelf(let band): return edit[channel].parametric.bands[band].shelf
        }
    }

    /// A switch is an edit, so LINK lit sets both channels to the clicked one's new state.
    private func flip(_ toggle: StripSwitch, channel: Int) {
        let on = !isOn(toggle, channel: channel)
        for channel in linked ? [0, 1] : [channel] {
            switch toggle {
            case .highPass: edit[channel].parametric.highPassOn = on
            case .shelf(let band): edit[channel].parametric.bands[band].shelf = on
            }
        }
        editDidChange()
    }

    private func perform(_ button: Button) {
        switch button {
        case .link:
            linked.toggle()
            UserDefaults.standard.set(linked, forKey: Self.linkedKey)
            needsDisplay = true
        case .mode:
            mode = mode == .graphic ? .parametric : .graphic
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            needsDisplay = true
        case .headroom:
            for channel in 0..<2 { edit[channel].preamp = EQCurve.clamp(Float(-peakDB[channel])) }
            editDidChange()
        case .save:
            if let profileID { store.update(profileID, curve: edit); needsDisplay = true } else { saveAs() }
        case .saveAs:
            saveAs()
        case .rename:
            guard let newName = promptName("Rename Profile", initial: name) else { return }
            name = newName
            if let profileID { store.update(profileID, name: newName) }
            needsDisplay = true
        case .delete:
            guard let profileID else { return }
            let alert = NSAlert()
            alert.messageText = "Delete “\(name)”?"
            alert.informativeText = "Everything assigned to it falls back to the next level down."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            store.delete(profileID)
            loadNew()
        case .revert:
            edit = savedCurve
            editDidChange()
        case .faceplate:
            faceplate = faceplate.kind == .console ? .boutique : .console
            UserDefaults.standard.set(faceplate.kind.rawValue, forKey: StudioFaceplate.defaultsKey)
            needsDisplay = true
        }
    }

    /// FLAT is an edit, so LINK lit flattens both channels, as double-clicking a fader resets both.
    /// It flattens the whole curve — both stages — whichever controls are shown.
    private func flatten(_ channel: Int) {
        for channel in linked ? [0, 1] : [channel] { edit[channel] = .flat }
        editDidChange()
    }

    private func isEnabled(_ button: Button) -> Bool {
        switch button {
        case .save: return isDirty || profileID == nil
        case .delete: return profileID != nil
        case .revert: return isDirty
        default: return true
        }
    }

    private func saveAs() {
        guard let newName = promptName("Save Profile As", initial: profileID == nil ? "" : name),
              let profile = store.add(name: newName, curve: edit) else { return }
        load(profile)
    }

    private func promptName(_ message: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func showProfileMenu() {
        let menu = NSMenu()
        for profile in store.sortedProfiles {
            let item = NSMenuItem(title: profile.name, action: #selector(chooseProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.id
            item.state = profile.id == profileID ? .on : .off
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let new = NSMenuItem(title: "New", action: #selector(chooseNew(_:)), keyEquivalent: "")
        new.target = self
        menu.addItem(new)
        menu.popUp(positioning: nil, at: NSPoint(x: nameRect.minX, y: nameRect.maxY + 2), in: self)
    }

    @objc private func chooseProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let profile = store.profile(id) else { return }
        load(profile)
    }

    @objc private func chooseNew(_ sender: NSMenuItem) { loadNew() }

    // MARK: - Mouse

    private func fader(at point: CGPoint) -> Fader? {
        for (channel, panel) in panels.enumerated() {
            if panel.preamp.insetBy(dx: -8, dy: -4).contains(point) { return Fader(channel: channel, band: nil) }
            guard mode == .graphic, panel.faders.insetBy(dx: 0, dy: -4).contains(point) else { continue }
            let band = Int((point.x - panel.bandX0) / panel.bandWidth)
            if (0..<EQProfileDesign.bandCount).contains(band) { return Fader(channel: channel, band: band) }
        }
        return nil
    }

    private func faderRect(_ fader: Fader) -> CGRect {
        let panel = panels[fader.channel]
        return fader.band == nil ? panel.preamp : panel.faders
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if closeRect.insetBy(dx: -4, dy: -4).contains(point) {
            window?.close()
        } else if nameRect.contains(point) {
            showProfileMenu()
        } else if let (button, _) = buttonRects.first(where: { $0.1.contains(point) }) {
            if isEnabled(button) { perform(button) }
        } else if let channel = panels.firstIndex(where: { $0.flat.contains(point) }) {
            flatten(channel)
        } else if let channel = panels.firstIndex(where: { $0.bypass.contains(point) }) {
            bypass[channel].toggle()
            pushAudition()
        } else if mode == .parametric, let hit = stripHit(at: point) {
            switch hit.control {
            case .toggle(let toggle):
                flip(toggle, channel: hit.channel)
            case .knob(let knob):
                if event.clickCount == 2 {
                    reset(knob, channel: hit.channel)
                } else if edit[hit.channel].parametric.isActive(knob) {
                    turning = (hit.channel, knob, point.y)
                }
            }
        } else if let fader = fader(at: point) {
            if event.clickCount == 2 {
                reset(fader)
            } else {
                dragging = fader
                move(fader, to: gain(y: point.y, in: faderRect(fader)) - offset(fader))
            }
        } else {
            window?.performDrag(with: event)
        }
    }

    private func stripHit(at point: CGPoint) -> (channel: Int, control: StripControl)? {
        for (channel, panel) in panels.enumerated() where panel.strip.contains(point) {
            let strip = strip(panel)
            if let toggle = strip.switches.first(where: { $0.1.contains(point) })?.0 { return (channel, .toggle(toggle)) }
            if let knob = strip.knobs.first(where: { $0.1.insetBy(dx: -4, dy: -4).contains(point) })?.0 {
                return (channel, .knob(knob))
            }
        }
        return nil
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let turning {
            // Up turns clockwise; 200 points is the whole travel.
            self.turning?.y = point.y
            turn(turning.knob, channel: turning.channel, by: Float(turning.y - point.y) / 200)
            return
        }
        guard let dragging else { return }
        move(dragging, to: gain(y: point.y, in: faderRect(dragging)) - offset(dragging))
    }

    override func mouseUp(with event: NSEvent) {
        dragging = nil
        turning = nil
    }

    // MARK: - Drawing

    private static let neutralRim = SkinnedSurfaceStyle(roles: SkinnedSurfaceRoles(
        background: NSColor(white: 0.22, alpha: 1), text: .white, currentText: .white,
        selectionBackground: .gray, selectionText: .white, treeText: .white, treeSelection: .gray))

    /// The rim's colours: the hosting skin's own surface style where it lends one, else the Classic
    /// skin's or the Original skin's surface roles. Not a Classic case in `hostedSurfaceStyle`, which
    /// would put Classic's Playlist and EQ windows in the gloss frame too.
    private var rimStyle: SkinnedSurfaceStyle {
        let wm = WindowManager.shared
        if let style = wm.hostedSurfaceStyle { return style }
        switch wm.uiMode.controllerFamily {
        case .classic:
            return SkinnedSurfaceStyle(roles: SkinnedSurfaceRoles(classic: wm.currentSkin?.playlistColors ?? .default))
        case .nullPlayerModern:
            return ModernSkinEngine.shared.currentSkin.map {
                SkinnedSurfaceStyle(roles: SkinnedSurfaceRoles(modern: $0.config.palette))
            } ?? Self.neutralRim
        case .winampModern, .wmp, .audion:
            // These lend a style once their skin is up; until then, the neutral rim.
            return Self.neutralRim
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let f = faceplate
        SkinnedSurfaceChrome.drawGlossFrame(in: context, bounds: bounds, style: rimStyle,
                                            isActive: window?.isKeyWindow ?? true, fillGround: false)
        f.panel.setFill()
        NSBezierPath(roundedRect: content, xRadius: 2, yRadius: 2).fill()

        drawHeader(f)
        for (channel, panel) in panels.enumerated() { drawPanel(panel, channel: channel, f) }
    }

    private func drawText(_ string: String, font: NSFont, color: NSColor, in rect: CGRect,
                          alignment: NSTextAlignment = .left) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let height = (string as NSString).size(withAttributes: attributes).height
        (string as NSString).draw(in: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height),
                                  withAttributes: attributes)
    }

    private func drawHeader(_ f: StudioFaceplate) {
        // Name display: the profile, a dirty marker, and the menu it opens.
        f.well.setFill()
        NSBezierPath(roundedRect: nameRect, xRadius: 3, yRadius: 3).fill()
        f.edge.setStroke()
        NSBezierPath(roundedRect: nameRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke()
        drawText(name + (isDirty ? "  ●" : ""), font: f.titleFont, color: f.text,
                 in: CGRect(x: nameRect.minX + 10, y: nameRect.minY, width: nameRect.width - 40, height: nameRect.height))
        drawText("▾", font: f.buttonFont, color: f.dimText, in: CGRect(x: nameRect.maxX - 22, y: nameRect.minY, width: 14, height: nameRect.height))

        let title = CGRect(x: nameRect.maxX + 16, y: nameRect.minY, width: closeRect.minX - nameRect.maxX - 28, height: nameRect.height)
        let bypassed = bypass == [true, true] ? " — BYPASS" : bypass[0] ? " — BYPASS L" : bypass[1] ? " — BYPASS R" : ""
        drawText("EQUALIZER STUDIO" + bypassed, font: f.buttonFont,
                 color: bypassed.isEmpty ? f.dimText : f.accent, in: title, alignment: .right)

        // Close: a drawn ×.
        let x = closeRect.insetBy(dx: 5, dy: 5)
        let cross = NSBezierPath()
        cross.move(to: x.origin); cross.line(to: CGPoint(x: x.maxX, y: x.maxY))
        cross.move(to: CGPoint(x: x.maxX, y: x.minY)); cross.line(to: CGPoint(x: x.minX, y: x.maxY))
        cross.lineWidth = 1.5
        f.dimText.setStroke()
        cross.stroke()

        for (button, rect) in buttonRects {
            let title = button == .faceplate ? f.kind.rawValue.uppercased()
                : button == .mode ? mode.rawValue.uppercased() : button.title
            drawButton(title, in: rect, lit: button == .link && linked, enabled: isEnabled(button), f)
        }
    }

    private func drawButton(_ title: String, in rect: CGRect, lit: Bool, enabled: Bool = true, _ f: StudioFaceplate) {
        (lit ? f.accent : f.well).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        f.edge.setStroke()
        NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke()
        let color = lit ? f.panel : enabled ? f.text : f.dimText.withAlphaComponent(0.5)
        drawText(title, font: f.buttonFont, color: color, in: rect, alignment: .center)
    }

    private func drawPanel(_ panel: Panel, channel: Int, _ f: StudioFaceplate) {
        f.edge.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: panel.frame, xRadius: 3, yRadius: 3).fill()
        f.panel.setFill()
        NSBezierPath(roundedRect: panel.frame.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()

        // Channel name (in the accent while LINK is lit), the peak response readout, and the
        // channel's FLAT and BYPASS.
        drawText(channel == 0 ? "LEFT" : "RIGHT", font: f.titleFont, color: linked ? f.accent : f.text, in: panel.name)
        let peak = peakDB[channel] + Double(edit[channel].preamp)
        drawText(String(format: "PK %+.1f", peak), font: f.legendFont, color: peak > 0.05 ? f.peak : f.dimText,
                 in: panel.peakReadout)
        drawText(String(format: "PRE %+.1f", edit[channel].preamp), font: f.legendFont, color: f.dimText,
                 in: panel.preampReadout)
        drawButton("FLAT", in: panel.flat, lit: false, f)
        drawButton("BYPASS", in: panel.bypass, lit: bypass[channel], f)

        drawAnalyser(panel, channel: channel, f)
        switch mode {
        case .graphic: drawFaders(panel, channel: channel, f)
        case .parametric: drawStrip(panel, channel: channel, f)
        }
        drawPreamp(panel, channel: channel, f)
    }

    private func drawPreamp(_ panel: Panel, channel: Int, _ f: StudioFaceplate) {
        for tick in f.faderTickLabels {
            drawText(String(format: "%+.0f", tick).replacingOccurrences(of: "+0", with: "0"), font: f.legendFont,
                     color: f.dimText, in: CGRect(x: panel.preamp.maxX + 2, y: y(gain: tick, in: panel.preamp) - 6, width: 18, height: 12))
        }
        drawFader(x: panel.preamp.midX, value: edit[channel].preamp, in: panel.preamp, cap: f.text, width: 18, f)
        drawText("PRE", font: f.legendFont, color: f.dimText,
                 in: CGRect(x: panel.preamp.minX - 8, y: panel.legend.minY, width: panel.preamp.width + 16,
                            height: panel.legend.height), alignment: .center)
    }

    private func analyserY(_ db: Float, in rect: CGRect) -> CGFloat {
        let range = Self.analyserRange
        let t = (min(range.upperBound, max(range.lowerBound, db)) - range.lowerBound) / (range.upperBound - range.lowerBound)
        return rect.maxY - CGFloat(t) * rect.height
    }

    /// What the ladder shows depends on where the feed sits: the local feed is pre-profile, so the
    /// auditioned curve is added (BYPASS shows the source); the streaming feed is already the output
    /// — post-profile, post-EQ, post-SRS — so it is shown as-is and labelled so.
    private func drawAnalyser(_ panel: Panel, channel: Int, _ f: StudioFaceplate) {
        let rect = panel.analyser
        f.well.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()

        for db in stride(from: Self.analyserRange.upperBound - 6, to: Self.analyserRange.lowerBound, by: -f.graticuleStep) {
            let y = analyserY(db, in: rect)
            (db == 0 ? f.graticuleZero : f.graticule).setFill()
            NSRect(x: rect.minX, y: y, width: rect.width, height: f.graticuleWeight).fill()
            if db.truncatingRemainder(dividingBy: 12) == 0 {
                drawText(String(format: "%.0f", db), font: f.legendFont, color: f.dimText.withAlphaComponent(0.7),
                         in: CGRect(x: rect.maxX - 22, y: y - 6, width: 20, height: 12), alignment: .right)
            }
        }
        if f.octaveGrid {
            f.scale.setFill()
            for band in stride(from: 0, to: EQProfileDesign.bandCount, by: 3) {
                NSRect(x: panel.centreX(band), y: rect.minY, width: 0.5, height: rect.height).fill()
            }
        }

        let streaming = WindowManager.shared.audioEngine.isStreamingPlayback
        let bypassed = bypass[channel]
        let added: (Int) -> Float = { [edit, centreResponse] band in
            streaming || bypassed ? 0 : Float(centreResponse[channel][band]) + edit[channel].preamp
        }
        drawText(streaming ? "OUTPUT" : bypassed ? "SOURCE" : "SOURCE + PROFILE", font: f.legendFont,
                 color: f.dimText, in: CGRect(x: rect.minX + 4, y: rect.minY + 2, width: 120, height: 11))

        let levels = self.levels[channel], peaks = self.peaks[channel]
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        switch f.kind {
        case .console:
            for band in 0..<EQProfileDesign.bandCount {
                let level = levels[band] + added(band)
                let top = analyserY(level, in: rect)
                let bar = CGRect(x: panel.centreX(band) - panel.bandWidth / 2 + 1.5, y: top,
                                 width: panel.bandWidth - 3, height: rect.maxY - top)
                (f.heat.last { level > $0.db } ?? f.heat[0]).color.setFill()
                bar.fill()
                f.peak.setFill()
                NSRect(x: bar.minX, y: analyserY(peaks[band] + added(band), in: rect), width: bar.width, height: 1.5).fill()
            }
        case .boutique:
            let range = Self.analyserRange
            var locations = f.heat.map { CGFloat(($0.db - range.lowerBound) / (range.upperBound - range.lowerBound)) }
            guard let heat = NSGradient(colors: f.heat.map(\.color), atLocations: &locations, colorSpace: .sRGB) else { break }
            let points = (0..<EQProfileDesign.bandCount).map {
                CGPoint(x: panel.centreX($0), y: analyserY(levels[$0] + added($0), in: rect))
            }
            let line = NSBezierPath()
            for (band, point) in points.enumerated() { band == 0 ? line.move(to: point) : line.line(to: point) }
            let curve = NSBezierPath()
            curve.append(line)
            curve.line(to: CGPoint(x: points[points.count - 1].x, y: rect.maxY))
            curve.line(to: CGPoint(x: points[0].x, y: rect.maxY))
            curve.close()
            // The fill is graded on the analyser's own dB scale, so a loud band burns white-hot.
            NSGraphicsContext.saveGraphicsState()
            curve.addClip()
            heat.draw(from: CGPoint(x: rect.minX, y: rect.maxY), to: CGPoint(x: rect.minX, y: rect.minY), options: [])
            NSGraphicsContext.restoreGraphicsState()
            line.lineWidth = 1
            f.accent.withAlphaComponent(0.8).setStroke()
            line.stroke()
            // Peak holds are embers in their level's heat; from -12 dB they glow, wider the hotter.
            for band in 0..<EQProfileDesign.bandCount {
                let db = peaks[band] + added(band)
                let color = heat.interpolatedColor(atLocation: CGFloat((min(range.upperBound, max(range.lowerBound, db))
                    - range.lowerBound) / (range.upperBound - range.lowerBound)))
                NSGraphicsContext.saveGraphicsState()
                if db > -12 {
                    let glow = NSShadow()
                    glow.shadowColor = color
                    glow.shadowBlurRadius = CGFloat(min(12, 3 + (db + 12) * 0.6))
                    glow.set()
                }
                color.setFill()
                NSBezierPath(roundedRect: CGRect(x: panel.centreX(band) - 4, y: analyserY(db, in: rect) - 1, width: 8, height: 2),
                             xRadius: 1, yRadius: 1).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawFaders(_ panel: Panel, channel: Int, _ f: StudioFaceplate) {
        let rect = panel.faders
        let bands = edit[channel].bands

        // Scale: engraved on Console, a fine line on Boutique.
        for tick in f.faderTicks {
            let y = self.y(gain: tick, in: rect).rounded() + 0.5
            switch f.kind {
            case .console:
                f.scale.withAlphaComponent(tick == 0 ? 0.55 : 0.28).setFill()
                NSRect(x: rect.minX, y: y - 0.5, width: rect.width, height: 1).fill()
                NSColor.black.withAlphaComponent(0.35).setFill()
                NSRect(x: rect.minX, y: y + 0.5, width: rect.width, height: 1).fill()
            case .boutique:
                f.scale.setFill()
                NSRect(x: rect.minX, y: y - 0.25, width: rect.width, height: 0.5).fill()
            }
        }

        for band in 0..<EQProfileDesign.bandCount {
            drawFader(x: panel.centreX(band), value: EQCurve.clamp(bands[band] + stripAtCentre[channel][band]), in: rect, cap: f.capColor(band: band),
                      width: min(panel.bandWidth - 4, f.capWidth), f)
            drawText(Self.bandLabels[band], font: f.legendFont, color: f.dimText,
                     in: CGRect(x: panel.centreX(band) - panel.bandWidth / 2 - 2, y: panel.legend.minY,
                                width: panel.bandWidth + 4, height: panel.legend.height), alignment: .center)
        }
        drawResponse(panel, channel: channel, in: rect, f)
    }

    private func drawFader(x: CGFloat, value: Float, in rect: CGRect, cap: NSColor, width: CGFloat, _ f: StudioFaceplate) {
        f.slot.setFill()
        NSRect(x: x - f.slotWidth / 2, y: rect.minY + 4, width: f.slotWidth, height: rect.height - 8).fill()
        let y = self.y(gain: value, in: rect)
        switch f.kind {
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
            let zero = self.y(gain: 0, in: rect)
            cap.withAlphaComponent(0.35).setFill()
            NSRect(x: x - 0.5, y: min(y, zero), width: 1, height: abs(y - zero)).fill()
            cap.setFill()
            NSRect(x: x - width / 2, y: y - 1, width: width, height: 2).fill()
        }
    }

    /// The response actually applied — both stages, without the preamp, at 48 kHz — on a ±12 dB scale in `rect`.
    private func drawResponse(_ panel: Panel, channel: Int, in rect: CGRect, _ f: StudioFaceplate) {
        guard response[channel].count == Self.gridFrequencies.count else { return }
        let path = NSBezierPath()
        for (index, frequency) in Self.gridFrequencies.enumerated() {
            let point = CGPoint(x: panel.x(frequency: frequency),
                                y: y(gain: Float(max(-12, min(12, response[channel][index]))), in: rect))
            index == 0 ? path.move(to: point) : path.line(to: point)
        }
        path.lineWidth = 1.2
        f.accent.withAlphaComponent(bypass[channel] ? 0.25 : 0.85).setStroke()
        path.stroke()
    }

    // MARK: - Parametric strip (Boutique look)

    private static let stripGraphFrequencies: [(Double, String)] = [
        (50, "50"), (100, "100"), (200, "200"), (500, "500"), (1000, "1k"), (2000, "2k"), (5000, "5k"), (10000, "10k")]

    private func drawStrip(_ panel: Panel, channel: Int, _ f: StudioFaceplate) {
        let strip = strip(panel)
        let parametric = edit[channel].parametric
        let graph = strip.graph

        // Graph: a fine grid, the response, and a dot per band at its frequency and gain.
        f.well.setFill()
        NSBezierPath(roundedRect: graph, xRadius: 2, yRadius: 2).fill()
        for db: Float in [-12, -6, 0, 6, 12] {
            let y = self.y(gain: db, in: graph).rounded() + 0.5
            (db == 0 ? f.graticuleZero : f.graticule).setFill()
            NSRect(x: graph.minX, y: y - 0.25, width: graph.width - 24, height: db == 0 ? 1 : 0.5).fill()
            if db.truncatingRemainder(dividingBy: 12) == 0 {
                drawText(String(format: "%+.0f", db).replacingOccurrences(of: "+0", with: "0"), font: f.legendFont,
                         color: f.dimText.withAlphaComponent(0.7),
                         in: CGRect(x: graph.maxX - 22, y: y - 6, width: 20, height: 12), alignment: .right)
            }
        }
        for (frequency, label) in Self.stripGraphFrequencies {
            let x = panel.x(frequency: frequency)
            f.graticule.setFill()
            NSRect(x: x, y: graph.minY, width: 0.5, height: graph.height).fill()
            drawText(label, font: f.legendFont, color: f.dimText.withAlphaComponent(0.7),
                     in: CGRect(x: x + 2, y: graph.maxY - 11, width: 24, height: 10))
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: graph).addClip()
        drawResponse(panel, channel: channel, in: graph, f)
        for band in parametric.bands {
            let centre = CGPoint(x: panel.x(frequency: Double(band.frequency)), y: y(gain: band.gain, in: graph))
            (band.gain == 0 ? f.dimText : f.accent).setFill()
            NSBezierPath(ovalIn: CGRect(x: centre.x - 2.5, y: centre.y - 2.5, width: 5, height: 5)).fill()
        }
        if parametric.highPassOn {
            f.accent.setFill()
            NSRect(x: panel.x(frequency: Double(parametric.highPass)) - 0.5, y: graph.minY, width: 1, height: graph.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        for (title, rect) in strip.titles {
            drawText(title, font: f.buttonFont, color: f.text, in: rect)
        }
        for (toggle, rect) in strip.switches {
            drawButton(toggle == .highPass ? "ON" : "SHELF", in: rect, lit: isOn(toggle, channel: channel), f)
        }
        for (knob, rect) in strip.knobs {
            let active = parametric.isActive(knob)
            drawKnob(knob, value: parametric[knob], active: active, in: rect, f)
            drawText(Self.readout(knob, parametric[knob]), font: f.legendFont,
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
    private func drawKnob(_ knob: EQParametric.Knob, value: Float, active: Bool, in rect: CGRect, _ f: StudioFaceplate) {
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
