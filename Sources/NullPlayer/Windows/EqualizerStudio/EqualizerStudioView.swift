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
    private enum Mode: String, CaseIterable { case graphic, parametric }

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
    /// What an unsaved profile is called until it is saved under a name of its own.
    private static let newName = "New EQ Profile"
    private var name = EqualizerStudioView.newName
    /// Per channel: heard flat, for this session. A monitoring switch, not an edit, but LINK lit
    /// sets both channels to the clicked one's new state, as it does FLAT.
    private var bypass = [false, false]
    private var linked = true
    private var mode = Mode.graphic
    private var faceplateKind = StudioFaceplate.Kind.console
    private let bloom = StudioBloom()
    /// A fader or dial held, and the pointer's last y.
    private var drag: (control: Control, y: CGFloat)?
    private var responses = [ChannelResponse.flat, .flat]
    private var levels = [[Float]](repeating: [Float](repeating: StudioRTA.floorDB, count: EQProfileDesign.bandCount), count: 2)
    private var peaks = [[Float]](repeating: [Float](repeating: StudioRTA.floorDB, count: EQProfileDesign.bandCount), count: 2)

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Layout

    /// The smallest the faceplate lays out at; the window's minimum adds its chrome to this.
    static let designSize = NSSize(width: 688, height: 548)
    /// A channel panel's inner height at `designSize`. Height beyond it goes to the analyser and the
    /// fader field (in parametric mode, the strip's graph).
    private static let designPanelHeight: CGFloat = 213

    private var nameRect: CGRect { CGRect(x: bounds.minX + 12, y: bounds.minY + 10, width: 220, height: 22) }

    private var buttonRects: [(Button, CGRect)] {
        let count = CGFloat(Button.allCases.count), gap: CGFloat = 6
        let width = (bounds.width - 24 - gap * (count - 1)) / count
        return Button.allCases.enumerated().map { index, button in
            (button, CGRect(x: bounds.minX + 12 + CGFloat(index) * (width + gap), y: bounds.minY + 42,
                            width: width, height: 20))
        }
    }

    private var panels: [Panel] {
        let top = bounds.minY + 72
        let height = (bounds.maxY - 6 - top) / 2
        return (0..<2).map { channel in
            let frame = CGRect(x: bounds.minX + 8, y: top + CGFloat(channel) * height,
                               width: bounds.width - 16, height: height - 6)
            let inner = frame.insetBy(dx: 8, dy: 8)
            let column: CGFloat = 52
            let bandX0 = inner.minX + column + 8
            let spare = max(0, inner.height - Self.designPanelHeight)
            let grow = (spare * 0.4).rounded()
            // Parametric mode shortens the analyser to give the strip's dials room.
            let analyser = CGRect(x: bandX0, y: inner.minY, width: inner.maxX - bandX0,
                                  height: (mode == .graphic ? 74 : 56) + grow)
            let faders = CGRect(x: bandX0, y: inner.minY + 82 + grow, width: analyser.width, height: 112 + spare - grow)
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
        faceplateKind = StudioFaceplate.storedKind
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
        name = Self.newName
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
            for channel in 0..<2 { edit[channel].preamp = headroomPreamp(channel) }
            editDidChange()
        case .save:
            guard let profileID else { return }
            store.update(profileID, curve: edit)
            needsDisplay = true
        case .saveAs:
            saveAs()
        case .rename:
            guard let profileID, let newName = promptName("Rename Profile", initial: name) else { return }
            name = newName
            store.update(profileID, name: newName)
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
            faceplateKind = faceplateKind == .console ? .boutique : .console
            UserDefaults.standard.set(faceplateKind.rawValue, forKey: StudioFaceplate.defaultsKey)
            needsDisplay = true
        }
    }

    /// FLAT is an edit, so LINK lit flattens both channels, as double-clicking a fader resets both.
    /// It flattens the whole curve — both stages — whichever controls are shown.
    private func flatten(_ channel: Int) {
        for channel in targets(channel) { edit[channel] = .flat }
        editDidChange()
    }

    /// The preamp that puts a channel's response peak at 0 dB.
    private func headroomPreamp(_ channel: Int) -> Float {
        EQCurve.clamp(Float(-responses[channel].peak))
    }

    private func isEnabled(_ button: Button) -> Bool {
        switch button {
        // Lit only while a preamp is off its headroom setting, so a press always changes something.
        case .headroom: return (0..<2).contains { abs(edit[$0].preamp - headroomPreamp($0)) >= 0.05 }
        // An unsaved profile has nothing stored to save over, rename or delete; Save As names it.
        case .save: return profileID != nil && isDirty
        case .rename, .delete: return profileID != nil
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
        if nameRect.contains(point) {
            showProfileMenu()
        } else if let (button, _) = buttonRects.first(where: { $0.1.contains(point) }) {
            if isEnabled(button) { perform(button) }
        } else if let channel = panels.firstIndex(where: { $0.flat.contains(point) }) {
            flatten(channel)
        } else if let channel = panels.firstIndex(where: { $0.bypass.contains(point) }) {
            let on = !bypass[channel]
            for channel in targets(channel) { bypass[channel] = on }
            pushAudition()
        } else if let control = control(at: point) {
            press(control, at: point.y, clickCount: event.clickCount)
        } else {
            // An empty area: the window view behind drags the window, snapping as its title does.
            super.mouseDown(with: event)
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
        guard let (control, lastY) = drag else { super.mouseDragged(with: event); return }
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

    override func mouseUp(with event: NSEvent) {
        if drag == nil { super.mouseUp(with: event) }
        drag = nil
    }

    // MARK: - Drawing

    private static let neutralStyle = SkinnedSurfaceStyle(roles: SkinnedSurfaceRoles(
        background: NSColor(white: 0.22, alpha: 1), text: .white, currentText: .white,
        selectionBackground: .gray, selectionText: .white, treeText: .white, treeSelection: .gray))

    /// The faceplate's colours: the hosting skin's own surface style where it lends one, else the
    /// Classic skin's or the Original skin's surface roles. Not a Classic case in
    /// `hostedSurfaceStyle`, which would put Classic's Playlist and EQ windows in the gloss frame too.
    private var surfaceStyle: SkinnedSurfaceStyle {
        let wm = WindowManager.shared
        if let style = wm.hostedSurfaceStyle { return style }
        switch wm.uiMode.controllerFamily {
        case .classic:
            return SkinnedSurfaceStyle(roles: SkinnedSurfaceRoles(classic: wm.currentSkin?.playlistColors ?? .default))
        case .nullPlayerModern:
            return ModernSkinEngine.shared.currentSkin.map {
                SkinnedSurfaceStyle(roles: SkinnedSurfaceRoles(modern: $0.config.palette))
            } ?? Self.neutralStyle
        case .winampModern, .wmp, .audion:
            // These lend a style once their skin is up; until then, the neutral one.
            return Self.neutralStyle
        }
    }

    /// Winamp's own EQ and spectrum colours: green, yellow, red.
    private static let winampMeter = [NSColor(srgbRed: 0, green: 0.85, blue: 0, alpha: 1),
                                      NSColor(srgbRed: 0.85, green: 0.85, blue: 0, alpha: 1),
                                      NSColor(srgbRed: 0.85, green: 0.15, blue: 0, alpha: 1)]

    /// The skin's own low, mid and high level colours where it declares them: an Original skin's EQ
    /// colours, or a Classic skin's spectrum (`viscolor.txt`'s bottom, middle and top bar rows).
    /// The families that lend only surface roles take Winamp's.
    private var meterColors: [NSColor] {
        let wm = WindowManager.shared
        switch wm.uiMode.controllerFamily {
        case .classic:
            if let colors = wm.currentSkin?.visColors, colors.count >= 18 { return [colors[17], colors[9], colors[2]] }
        case .nullPlayerModern:
            if let skin = ModernSkinEngine.shared.currentSkin { return [skin.eqLowColor, skin.eqMidColor, skin.eqHighColor] }
        case .winampModern, .wmp, .audion:
            break
        }
        return Self.winampMeter
    }

    /// The classic Library's renderer, cached per skin as the Library caches it: the white text sheet
    /// is built once per renderer.
    private var tabRenderer: (path: String, renderer: SkinRenderer)?

    /// The Library's tab in this family, which the buttons are drawn as.
    private var tab: StudioTab {
        let wm = WindowManager.shared
        if wm.uiMode.controllerFamily == .nullPlayerModern {
            return .original(ModernSkinEngine.shared.currentSkin ?? ModernSkinLoader.shared.loadDefault())
        }
        let skin = wm.currentSkin ?? SkinLoader.shared.loadDefault()
        let path = wm.currentSkinPath ?? "default"
        if tabRenderer?.path != path { tabRenderer = (path, SkinRenderer(skin: skin)) }
        let style = wm.hostedSurfaceStyle
        return .classic(renderer: tabRenderer!.renderer, style: style, colors: style?.playlistColors ?? skin.playlistColors)
    }

    /// The running Original-Metal skin; nil in every other family and render style.
    private var metalSkin: ModernSkin? {
        guard WindowManager.shared.uiMode.controllerFamily == .nullPlayerModern,
              let skin = ModernSkinEngine.shared.currentSkin, skin.renderStyle == .metal else { return nil }
        return skin
    }

    override func draw(_ dirtyRect: NSRect) {
        let f = StudioFaceplate(faceplateKind, style: surfaceStyle, meter: meterColors, tab: tab, metalSkin: metalSkin)
        // Over, not copied: Metal's clear panel must leave the chrome's surface behind it.
        f.panel.setFill()
        bounds.fill(using: .sourceOver)

        drawHeader(f)
        for (channel, panel) in panels.enumerated() { drawPanel(panel, channel: channel, f) }
    }

    /// Draws `body` into `rect` through the bloom where the faceplate glows, else as it is.
    private func glow(_ f: StudioFaceplate, _ rect: CGRect, _ body: () -> Void) {
        guard f.glows else { body(); return }
        bloom.draw(rect, scale: window?.backingScaleFactor ?? 2, ground: f.panel, body)
    }

    private func drawHeader(_ f: StudioFaceplate) {
        // Name display: the profile, a dirty marker, and the menu it opens.
        f.well.setFill()
        NSBezierPath(roundedRect: nameRect, xRadius: 3, yRadius: 3).fill()
        f.edge.setStroke()
        NSBezierPath(roundedRect: nameRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke()
        f.drawText(name + (isDirty ? "  ●" : ""), font: f.titleFont, color: f.wellText,
                   in: CGRect(x: nameRect.minX + 10, y: nameRect.minY, width: nameRect.width - 40, height: nameRect.height))
        f.drawText("▾", font: f.buttonFont, color: f.wellDimText, in: CGRect(x: nameRect.maxX - 22, y: nameRect.minY, width: 14, height: nameRect.height))

        // One label scale for the row, as the Library's tab row shrinks as a whole — fitted to every
        // title a button can show, so switching MODE does not resize the row.
        let rowScale = buttonRects.flatMap { button, rect in
            (button == .mode ? Mode.allCases.map { $0.rawValue.capitalized } : [title(button)])
                .map { f.tab.scale(fitting: $0, in: rect.size) }
        }.min() ?? 1
        for (button, rect) in buttonRects {
            f.drawButton(title(button), in: rect, lit: button == .link && linked, enabled: isEnabled(button),
                         scale: rowScale)
        }
    }

    /// MODE shows its current setting; FACEPLATE is "View", which switches between the two looks.
    private func title(_ button: Button) -> String {
        switch button {
        case .link: return "Link"
        case .mode: return mode.rawValue.capitalized
        case .headroom: return "Headroom"
        case .save: return "Save"
        case .saveAs: return "Save As"
        case .rename: return "Rename"
        case .delete: return "Delete"
        case .revert: return "Revert"
        case .faceplate: return "View"
        }
    }

    private func drawPanel(_ panel: Panel, channel: Int, _ f: StudioFaceplate) {
        f.edge.withAlphaComponent(0.6).setStroke()
        NSBezierPath(roundedRect: panel.frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke()

        // Channel name (lit, as the LINK tab is, while LINK is on), the peak response readout, and the
        // channel's FLAT and BYPASS.
        // The name is a tab lit with LINK, so the two read as one state; only the lighting changes.
        f.drawButton(channel == 0 ? "LEFT" : "RIGHT", in: panel.name, lit: linked)
        let peak = responses[channel].peak + Double(edit[channel].preamp)
        f.drawText(String(format: "PK %+.1f", peak), font: f.legendFont, color: peak > 0.05 ? f.peak : f.dimText,
                   in: panel.peakReadout)
        f.drawText(String(format: "PRE %+.1f", edit[channel].preamp), font: f.legendFont, color: f.dimText,
                   in: panel.preampReadout)
        f.drawButton("Flat", in: panel.flat, lit: false)
        f.drawButton("Bypass", in: panel.bypass, lit: bypass[channel])

        drawAnalyser(panel, channel: channel, f)
        switch mode {
        case .graphic:
            drawFaders(panel, channel: channel, f)
        case .parametric:
            let strip = panel.strip, parametric = edit[channel].parametric
            glow(f, strip.graph) {
                strip.drawGraph(parametric, x: panel.x(frequency:),
                                drawResponse: { drawResponse(panel, channel: channel, in: $0, f) }, f)
            }
            strip.drawControls(parametric, f)
        }
        drawPreamp(panel, channel: channel, f)
    }

    private func drawPreamp(_ panel: Panel, channel: Int, _ f: StudioFaceplate) {
        // A guide across the slot at each labelled step, in its label's colour; 0 dB the strongest.
        for tick in f.faderTickLabels {
            let y = panel.preamp.y(gain: tick).rounded()
            f.dimText.withAlphaComponent(tick == 0 ? 1 : 0.55).setFill()
            NSRect(x: panel.preamp.minX, y: y, width: panel.preamp.width, height: 1).fill()
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
    /// — post-profile, post-EQ, post-SRS — so it is shown as-is.
    private func drawAnalyser(_ panel: Panel, channel: Int, _ f: StudioFaceplate) {
        let rect = panel.analyser
        let graticule = stride(from: Self.analyserRange.upperBound - 6, to: Self.analyserRange.lowerBound, by: -f.graticuleStep)
        let streaming = WindowManager.shared.audioEngine.isStreamingPlayback
        let bypassed = bypass[channel]
        let added = responses[channel].centres.map { streaming || bypassed ? 0 : Float($0) + edit[channel].preamp }
        let levels = zip(self.levels[channel], added).map(+), peaks = zip(self.peaks[channel], added).map(+)

        glow(f, rect) {
            f.well.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            for db in graticule {
                (db == 0 ? f.graticuleZero : f.graticule).setFill()
                NSRect(x: rect.minX, y: analyserY(db, in: rect), width: rect.width, height: f.graticuleWeight).fill()
            }
            if f.octaveGrid {
                f.scale.setFill()
                for band in stride(from: 0, to: EQProfileDesign.bandCount, by: 3) {
                    NSRect(x: panel.centreX(band), y: rect.minY, width: 0.5, height: rect.height).fill()
                }
            }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            switch f.kind {
            case .console: drawBars(levels, peaks: peaks, panel, f)
            case .boutique: drawHeatCurve(levels, peaks: peaks, panel, f)
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        // The labels sit on top, unbloomed.
        for db in graticule where db.truncatingRemainder(dividingBy: 12) == 0 {
            f.drawText(String(format: "%.0f", db), font: f.legendFont, color: f.wellDimText,
                       in: CGRect(x: rect.maxX - 22, y: analyserY(db, in: rect) - 6, width: 20, height: 12), alignment: .right)
        }
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
        // Peak holds are embers in their level's heat; the bloom makes the hot ones glow.
        for (band, db) in peaks.enumerated() {
            heat.interpolatedColor(atLocation: CGFloat(Self.analyserPosition(db))).setFill()
            NSBezierPath(roundedRect: CGRect(x: panel.centreX(band) - 4, y: analyserY(db, in: rect) - 1, width: 8, height: 2),
                         xRadius: 1, yRadius: 1).fill()
        }
    }

    private func drawFaders(_ panel: Panel, channel: Int, _ f: StudioFaceplate) {
        let rect = panel.faders
        let bands = edit[channel].bands

        glow(f, rect) {
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
            }
            drawResponse(panel, channel: channel, in: rect, f)
        }
        for band in 0..<EQProfileDesign.bandCount {
            f.drawText(Self.bandLabels[band], font: f.legendFont, color: f.dimText,
                       in: CGRect(x: panel.centreX(band) - panel.bandWidth / 2 - 2, y: panel.legend.minY,
                                  width: panel.bandWidth + 4, height: panel.legend.height), alignment: .center)
        }
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
