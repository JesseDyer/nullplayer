import AppKit

/// The Studio's single view: header, buttons and two channel panels (L above R), each a per-channel
/// analyser over 31 band faders — or, in parametric mode, a response graph over a channel strip's
/// dials — plus a preamp, with its own FLAT and BYPASS under the channel name. Both stages are always
/// heard and every curve drawn is their sum; the mode only picks which controls are shown. Edits are
/// heard live (the profile controller's `audition`) and discarded unless saved.
final class EqualizerStudioView: NSView {
    private enum Button: CaseIterable {
        case link, mode, headroom, save, saveAs, rename, delete, revert, faceplate
    }

    /// A band fader (`band` 0…30) or the preamp (`band` nil) of one channel.
    private struct Fader: Equatable {
        let channel: Int
        let band: Int?
    }

    /// What a click in a channel panel lands on.
    private enum Control {
        case fader(Fader)
        case knob(channel: Int, EQParametric.Knob)
        case toggle(channel: Int, EQParametric.Switch)
    }

    /// One channel's curve heard — both stages, no preamp — in dB, as drawn.
    private struct ChannelResponse {
        /// On `gridFrequencies`.
        let grid: [Double]
        /// At the band centres.
        let centres: [Double]
        /// The parametric strip alone at the band centres. A band fader shows its graphic share on
        /// top of this, so the faders sit on the curve; dragging moves only the share.
        let stripAtCentres: [Float]
        let peak: Double

        static let flat = ChannelResponse(.flat, channel: 0)

        init(_ curve: EQCurve, channel: Int) {
            let rate = EqualizerStudioView.displayRate
            let sections = EQProfileDesign.sections(for: curve, channel: channel, sampleRate: rate)
            let strip = curve[channel].parametric.sections(sampleRate: rate)
            grid = EqualizerStudioView.gridFrequencies.map { EQProfileDesign.responseDB(sections, frequency: $0, sampleRate: rate) }
            centres = EQProfileDesign.frequencies.map { EQProfileDesign.responseDB(sections, frequency: $0, sampleRate: rate) }
            stripAtCentres = EQProfileDesign.frequencies.map { Float(EQProfileDesign.responseDB(strip, frequency: $0, sampleRate: rate)) }
            peak = grid.max() ?? 0
        }
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
        var strip: StudioStrip {
            StudioStrip(in: CGRect(x: bandX0, y: analyser.maxY + 6, width: analyser.width, height: legend.maxY - analyser.maxY - 6))
        }

        func centreX(_ band: Int) -> CGFloat { bandX0 + (CGFloat(band) + 0.5) * bandWidth }
        /// Continuous x for a frequency: the ISO centres sit ⅓ octave apart.
        func x(frequency: Double) -> CGFloat { bandX0 + (CGFloat(log2(frequency / 20) * 3) + 0.5) * bandWidth }
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
    /// A fader or dial held, and the pointer's last y.
    private var drag: (control: Control, y: CGFloat)?
    private var responses = [ChannelResponse.flat, .flat]
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
        responses = (0..<2).map { ChannelResponse(edit, channel: $0) }
        pushAudition()
    }

    private func pushAudition() {
        var heard = edit
        for channel in 0..<2 where bypass[channel] { heard[channel] = .flat }
        controller.audition = heard
        needsDisplay = true
    }

    // MARK: - Editing

    /// The channel an edit is made on, then — LINK lit — the other.
    private func targets(_ channel: Int) -> [Int] { linked ? [channel, 1 - channel] : [channel] }

    /// Where a fader's cap is drawn and dragged: a band fader adds the strip at its centre; the preamp is itself.
    private func offset(_ fader: Fader) -> Float {
        fader.band.map { responses[fader.channel].stripAtCentres[$0] } ?? 0
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
        let moved = EQCurve.clamp(newValue) - value(fader)
        guard moved != 0 else { return }
        for channel in targets(fader.channel) {
            let target = Fader(channel: channel, band: fader.band)
            set(target, value(target) + moved)
        }
        editDidChange()
    }

    private func reset(_ fader: Fader) {
        for channel in targets(fader.channel) { set(Fader(channel: channel, band: fader.band), 0) }
        editDidChange()
    }

    /// LINK lit turns the other channel's dial by the same travel, as with faders.
    private func turn(_ knob: EQParametric.Knob, channel: Int, by travel: Float) {
        let old = edit[channel].parametric[knob]
        edit[channel].parametric[knob] = knob.value(at: knob.position(of: old) + travel)
        let moved = knob.position(of: edit[channel].parametric[knob]) - knob.position(of: old)
        guard moved != 0 else { return }
        for channel in targets(channel).dropFirst() {
            let value = edit[channel].parametric[knob]
            edit[channel].parametric[knob] = knob.value(at: knob.position(of: value) + moved)
        }
        editDidChange()
    }

    private func reset(_ knob: EQParametric.Knob, channel: Int) {
        for channel in targets(channel) { edit[channel].parametric[knob] = EQParametric.flat[knob] }
        editDidChange()
    }

    /// A switch is an edit, so LINK lit sets both channels to the clicked one's new state.
    private func flip(_ toggle: EQParametric.Switch, channel: Int) {
        let on = !edit[channel].parametric[toggle]
        for channel in targets(channel) { edit[channel].parametric[toggle] = on }
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
            for channel in 0..<2 { edit[channel].preamp = EQCurve.clamp(Float(-responses[channel].peak)) }
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
        for channel in targets(channel) { edit[channel] = .flat }
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

    /// The preamp in either mode; then the band faders or the strip, whichever the mode shows.
    private func control(at point: CGPoint) -> Control? {
        for (channel, panel) in panels.enumerated() {
            if panel.preamp.insetBy(dx: -8, dy: -4).contains(point) { return .fader(Fader(channel: channel, band: nil)) }
            switch mode {
            case .graphic:
                guard panel.faders.insetBy(dx: 0, dy: -4).contains(point) else { continue }
                let band = Int((point.x - panel.bandX0) / panel.bandWidth)
                if (0..<EQProfileDesign.bandCount).contains(band) { return .fader(Fader(channel: channel, band: band)) }
            case .parametric:
                let strip = panel.strip
                if let toggle = strip.toggle(at: point) { return .toggle(channel: channel, toggle) }
                if let knob = strip.knob(at: point) { return .knob(channel: channel, knob) }
            }
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
        } else if let control = control(at: point) {
            press(control, at: point.y, clickCount: event.clickCount)
        } else {
            window?.performDrag(with: event)
        }
    }

    /// A double-click resets a fader or dial; a single one starts dragging it. A switch flips.
    private func press(_ control: Control, at y: CGFloat, clickCount: Int) {
        switch control {
        case .fader(let fader):
            if clickCount == 2 {
                reset(fader)
            } else {
                drag = (control, y)
                move(fader, to: faderRect(fader).gain(y: y) - offset(fader))
            }
        case .knob(let channel, let knob):
            if clickCount == 2 {
                reset(knob, channel: channel)
            } else if edit[channel].parametric.isActive(knob) {
                drag = (control, y)
            }
        case .toggle(let channel, let toggle):
            flip(toggle, channel: channel)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let (control, lastY) = drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        drag?.y = point.y
        switch control {
        case .fader(let fader):
            move(fader, to: faderRect(fader).gain(y: point.y) - offset(fader))
        case .knob(let channel, let knob):
            // Up turns clockwise; 200 points is the whole travel.
            turn(knob, channel: channel, by: Float(lastY - point.y) / 200)
        case .toggle:
            break
        }
    }

    override func mouseUp(with event: NSEvent) { drag = nil }

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

    private func drawHeader(_ f: StudioFaceplate) {
        // Name display: the profile, a dirty marker, and the menu it opens.
        f.well.setFill()
        NSBezierPath(roundedRect: nameRect, xRadius: 3, yRadius: 3).fill()
        f.edge.setStroke()
        NSBezierPath(roundedRect: nameRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke()
        f.drawText(name + (isDirty ? "  ●" : ""), font: f.titleFont, color: f.text,
                   in: CGRect(x: nameRect.minX + 10, y: nameRect.minY, width: nameRect.width - 40, height: nameRect.height))
        f.drawText("▾", font: f.buttonFont, color: f.dimText, in: CGRect(x: nameRect.maxX - 22, y: nameRect.minY, width: 14, height: nameRect.height))

        let heading = CGRect(x: nameRect.maxX + 16, y: nameRect.minY, width: closeRect.minX - nameRect.maxX - 28, height: nameRect.height)
        let bypassed = bypass == [true, true] ? " — BYPASS" : bypass[0] ? " — BYPASS L" : bypass[1] ? " — BYPASS R" : ""
        f.drawText("EQUALIZER STUDIO" + bypassed, font: f.buttonFont,
                   color: bypassed.isEmpty ? f.dimText : f.accent, in: heading, alignment: .right)

        // Close: a drawn ×.
        let x = closeRect.insetBy(dx: 5, dy: 5)
        let cross = NSBezierPath()
        cross.move(to: x.origin); cross.line(to: CGPoint(x: x.maxX, y: x.maxY))
        cross.move(to: CGPoint(x: x.maxX, y: x.minY)); cross.line(to: CGPoint(x: x.minX, y: x.maxY))
        cross.lineWidth = 1.5
        f.dimText.setStroke()
        cross.stroke()

        for (button, rect) in buttonRects {
            f.drawButton(title(button), in: rect, lit: button == .link && linked, enabled: isEnabled(button))
        }
    }

    /// MODE and FACEPLATE show their current setting.
    private func title(_ button: Button) -> String {
        switch button {
        case .link: return "LINK"
        case .mode: return mode.rawValue.uppercased()
        case .headroom: return "HEADROOM"
        case .save: return "SAVE"
        case .saveAs: return "SAVE AS"
        case .rename: return "RENAME"
        case .delete: return "DELETE"
        case .revert: return "REVERT"
        case .faceplate: return faceplate.kind.rawValue.uppercased()
        }
    }

    private func drawPanel(_ panel: Panel, channel: Int, _ f: StudioFaceplate) {
        f.edge.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: panel.frame, xRadius: 3, yRadius: 3).fill()
        f.panel.setFill()
        NSBezierPath(roundedRect: panel.frame.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()

        // Channel name (in the accent while LINK is lit), the peak response readout, and the
        // channel's FLAT and BYPASS.
        f.drawText(channel == 0 ? "LEFT" : "RIGHT", font: f.titleFont, color: linked ? f.accent : f.text, in: panel.name)
        let peak = responses[channel].peak + Double(edit[channel].preamp)
        f.drawText(String(format: "PK %+.1f", peak), font: f.legendFont, color: peak > 0.05 ? f.peak : f.dimText,
                   in: panel.peakReadout)
        f.drawText(String(format: "PRE %+.1f", edit[channel].preamp), font: f.legendFont, color: f.dimText,
                   in: panel.preampReadout)
        f.drawButton("FLAT", in: panel.flat, lit: false)
        f.drawButton("BYPASS", in: panel.bypass, lit: bypass[channel])

        drawAnalyser(panel, channel: channel, f)
        switch mode {
        case .graphic:
            drawFaders(panel, channel: channel, f)
        case .parametric:
            panel.strip.draw(edit[channel].parametric, x: panel.x(frequency:),
                             drawResponse: { drawResponse(panel, channel: channel, in: $0, f) }, f)
        }
        drawPreamp(panel, channel: channel, f)
    }

    private func drawPreamp(_ panel: Panel, channel: Int, _ f: StudioFaceplate) {
        for tick in f.faderTickLabels {
            f.drawText(StudioFaceplate.dbLabel(tick), font: f.legendFont, color: f.dimText,
                       in: CGRect(x: panel.preamp.maxX + 2, y: panel.preamp.y(gain: tick) - 6, width: 18, height: 12))
        }
        f.drawFader(x: panel.preamp.midX, value: edit[channel].preamp, in: panel.preamp, cap: f.text, width: 18)
        f.drawText("PRE", font: f.legendFont, color: f.dimText,
                   in: CGRect(x: panel.preamp.minX - 8, y: panel.legend.minY, width: panel.preamp.width + 16,
                              height: panel.legend.height), alignment: .center)
    }

    /// 0…1 up the analyser's dB scale, clamped.
    private static func analyserPosition(_ db: Float) -> Float {
        let range = analyserRange
        return (min(range.upperBound, max(range.lowerBound, db)) - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func analyserY(_ db: Float, in rect: CGRect) -> CGFloat {
        rect.maxY - CGFloat(Self.analyserPosition(db)) * rect.height
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
                f.drawText(String(format: "%.0f", db), font: f.legendFont, color: f.dimText.withAlphaComponent(0.7),
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
        let added = responses[channel].centres.map { streaming || bypassed ? 0 : Float($0) + edit[channel].preamp }
        f.drawText(streaming ? "OUTPUT" : bypassed ? "SOURCE" : "SOURCE + PROFILE", font: f.legendFont,
                   color: f.dimText, in: CGRect(x: rect.minX + 4, y: rect.minY + 2, width: 120, height: 11))

        let levels = zip(self.levels[channel], added).map(+), peaks = zip(self.peaks[channel], added).map(+)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        switch f.kind {
        case .console: drawBars(levels, peaks: peaks, panel, f)
        case .boutique: drawHeatCurve(levels, peaks: peaks, panel, f)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Console: a bar per band, coloured by the heat step its level reaches, with a peak line.
    private func drawBars(_ levels: [Float], peaks: [Float], _ panel: Panel, _ f: StudioFaceplate) {
        let rect = panel.analyser
        for band in 0..<EQProfileDesign.bandCount {
            let top = analyserY(levels[band], in: rect)
            let bar = CGRect(x: panel.centreX(band) - panel.bandWidth / 2 + 1.5, y: top,
                             width: panel.bandWidth - 3, height: rect.maxY - top)
            (f.heat.last { levels[band] > $0.db } ?? f.heat[0]).color.setFill()
            bar.fill()
            f.peak.setFill()
            NSRect(x: bar.minX, y: analyserY(peaks[band], in: rect), width: bar.width, height: 1.5).fill()
        }
    }

    /// Boutique: the levels as a curve filled with heat, and the peak holds as embers.
    private func drawHeatCurve(_ levels: [Float], peaks: [Float], _ panel: Panel, _ f: StudioFaceplate) {
        let rect = panel.analyser
        var locations = f.heat.map { CGFloat(Self.analyserPosition($0.db)) }
        guard let heat = NSGradient(colors: f.heat.map(\.color), atLocations: &locations, colorSpace: .sRGB) else { return }
        let points = levels.indices.map { CGPoint(x: panel.centreX($0), y: analyserY(levels[$0], in: rect)) }
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
        for (band, db) in peaks.enumerated() {
            let color = heat.interpolatedColor(atLocation: CGFloat(Self.analyserPosition(db)))
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

    private func drawFaders(_ panel: Panel, channel: Int, _ f: StudioFaceplate) {
        let rect = panel.faders
        let bands = edit[channel].bands

        // Scale: engraved on Console, a fine line on Boutique.
        for tick in f.faderTicks {
            let y = rect.y(gain: tick).rounded() + 0.5
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
            f.drawFader(x: panel.centreX(band), value: EQCurve.clamp(bands[band] + responses[channel].stripAtCentres[band]),
                        in: rect, cap: f.capColor(band: band), width: min(panel.bandWidth - 4, f.capWidth))
            f.drawText(Self.bandLabels[band], font: f.legendFont, color: f.dimText,
                       in: CGRect(x: panel.centreX(band) - panel.bandWidth / 2 - 2, y: panel.legend.minY,
                                  width: panel.bandWidth + 4, height: panel.legend.height), alignment: .center)
        }
        drawResponse(panel, channel: channel, in: rect, f)
    }

    /// The response actually applied — both stages, without the preamp, at 48 kHz — on a ±12 dB scale in `rect`.
    private func drawResponse(_ panel: Panel, channel: Int, in rect: CGRect, _ f: StudioFaceplate) {
        let path = NSBezierPath()
        for (index, (frequency, db)) in zip(Self.gridFrequencies, responses[channel].grid).enumerated() {
            let point = CGPoint(x: panel.x(frequency: frequency), y: rect.y(gain: Float(max(-12, min(12, db)))))
            index == 0 ? path.move(to: point) : path.line(to: point)
        }
        path.lineWidth = 1.2
        f.accent.withAlphaComponent(bypass[channel] ? 0.25 : 0.85).setStroke()
        path.stroke()
    }
}
