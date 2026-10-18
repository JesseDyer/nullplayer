import AppKit
import UniformTypeIdentifiers

/// The Sonique-mode main window: one borderless window in three modes, as Sonique's own. Loads the
/// selected `.sgf` off the main thread and shows it through `SoniqueSkinMainView`; with none
/// selected, or one that fails to load, it shows NullPlayer's default Sonique skin, which is the
/// family's unskinned fallback (decision record § *Omitted entries and the default skin*). The
/// window's size is the mode's canvas times the UI scale; a mode switch, a reload or a restored
/// frame keeps its top-left corner.
final class SoniqueSkinMainWindowController: NSWindowController, MainWindowProviding, NSWindowDelegate {
    static let modeKey = "soniqueSkinMode"
    /// The window's size until the first skin is presented, which sizes it to its mode.
    static let placeholderSize = NSSize(width: 400, height: 300)

    private let importer = SoniqueSkinImporter()
    private let skinView = SoniqueSkinMainView()
    private var loadTask: Task<Void, Never>?
    private var uiScale: CGFloat = 1
    /// The `.sgf` on screen, nil while the default skin stands in.
    private(set) var loadedSkinURL: URL?
    /// NullPlayer's own windows, coloured from the skin on screen (`SoniqueSkinPalette`).
    private(set) var surfaceStyle = SoniqueSkinPalette.surfaceStyle(for: .defaultSkin)
    /// Small mode's blinkers, so a spectrum frame redraws only when they change.
    private var blinkersLit = false

    static let effectKey = "soniqueEffect"
    /// The visual mode screen's effect and preset, remembered across launches: Sonique had one
    /// visualizer choice, not one per skin. Restored once, then saved on every change.
    @MainActor private static let effectPersistence: NSObjectProtocol = {
        let selection = SkinEffectSelection.sonique, defaults = UserDefaults.standard
        selection.restore(effect: defaults.string(forKey: effectKey), preset: defaults.integer(forKey: effectKey + "Preset"))
        return NotificationCenter.default.addObserver(forName: SkinEffectSelection.didChange, object: selection,
                                                      queue: .main) { _ in
            MainActor.assumeIsolated {
                defaults.set(selection.current.id, forKey: effectKey)
                defaults.set(selection.preset, forKey: effectKey + "Preset")
            }
        }
    }()

    var mode: SoniqueSkin.Mode {
        get { skinView.mode }
        set {
            guard newValue != skinView.mode else { return }
            skinView.mode = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.modeKey)
            fitWindow()
        }
    }

    init() {
        let window = SkinnedBorderlessWindow(contentRect: NSRect(origin: .zero, size: Self.placeholderSize),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        // The skin casts its own, from what it draws (`SoniqueSkinMainView`).
        window.hasShadow = false
        window.isMovableByWindowBackground = false
        window.title = "NullPlayer — Sonique"
        window.setAccessibilityIdentifier("SoniqueSkinMainWindow")
        window.center()
        _ = MainActor.assumeIsolated { Self.effectPersistence }
        super.init(window: window)
        window.delegate = self
        window.contentView = skinView
        skinView.mode = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(SoniqueSkin.Mode.init(rawValue:)) ?? .navigator
        skinView.onCommand = { [weak self] control in MainActor.assumeIsolated { self?.perform(control) } }
        skinView.onDial = { [weak self] control, value in
            MainActor.assumeIsolated { SoniqueSkinAudioEngineHost.setDial(control, to: value, WindowManager.shared.audioEngine) }
            self?.refreshHostState()
        }
        skinView.onMode = { [weak self] mode in self?.mode = mode }
        skinView.onOutlineChange = { [weak window] in window?.invalidateSkinShadowShape("drawer") }
        reloadSelectedSkin()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Choosing a skin

    func reloadSelectedSkin() {
        loadTask?.cancel()
        let url: URL?
        do {
            url = try importer.selectedSkinURL()
        } catch {
            NSLog("SoniqueSkin: %@", error.localizedDescription)
            return present(nil)
        }
        guard let url else { return present(nil) }
        loadTask = Task { @MainActor [weak self] in
            do {
                let skin = try await SoniqueSkinLoader.load(file: url)
                try Task.checkCancellation()
                self?.present((skin, url))
                NSLog("SoniqueSkin: loaded '%@' (%d findings)", url.lastPathComponent, skin.findings.count)
            } catch is CancellationError {
                return
            } catch {
                NSLog("SoniqueSkin: '%@' failed: %@", url.lastPathComponent, "\(error)")
                self?.present(nil)
            }
        }
    }

    func selectSkin(named name: String) {
        importer.select(name)
        reloadSelectedSkin()
    }

    func importSkinFromPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "sgf") ?? .data]
        panel.message = "Select a Sonique skin (.sgf)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importSkin(from: url)
    }

    func importSkin(from url: URL) {
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            do {
                _ = try await self?.importer.importSkin(from: url)
                try Task.checkCancellation()
                self?.reloadSelectedSkin()
            } catch is CancellationError {
                return
            } catch {
                let alert = NSAlert()
                alert.messageText = "“\(url.lastPathComponent)” could not be loaded."
                alert.informativeText = "\(error)"
                alert.runModal()
            }
        }
    }

    func resetToUnskinned() {
        loadTask?.cancel()
        importer.resetSelection()
        present(nil)
    }

    // MARK: - Presenting

    private func present(_ shown: (skin: SoniqueSkin, url: URL)?) {
        let skin = shown?.skin ?? .defaultSkin
        loadedSkinURL = shown?.url
        let style = SoniqueSkinPalette.surfaceStyle(for: skin)
        if style != surfaceStyle {
            surfaceStyle = style
            NotificationCenter.default.post(name: .hostedSurfaceStyleDidChange, object: nil)
        }
        skinView.skin = skin
        fitWindow()
        refreshHostState()
    }

    func applyUIScale(_ scale: CGFloat) {
        uiScale = max(0.1, scale)
        skinView.uiScale = uiScale
        fitWindow()
    }

    func mainWindowSize(atScale scale: CGFloat) -> NSSize? {
        guard let scene = skinView.scene else { return nil }
        return NSSize(width: CGFloat(scene.width) * scale, height: CGFloat(scene.height) * scale)
    }

    /// Sizes the window to the mode at the current scale, holding its top-left corner.
    private func fitWindow() {
        guard let window, let size = mainWindowSize(atScale: uiScale) else { return }
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.setContentSize(size)
        window.setFrameTopLeftPoint(topLeft)
        window.invalidateSkinShadowShape("fit")
    }

    // MARK: - The drawer is the equaliser

    /// Whether the equaliser is on screen: the navigator with its drawer open.
    var isEqualizerShowing: Bool { mode == .navigator && skinView.navDrawerOpen }

    /// NullPlayer's Equalizer request, answered with the drawer, which is this family's equaliser
    /// (decision record § *Auxiliary-window policy*). A toggle goes to the navigator first; a show is
    /// the restore path, which never changes the mode the user left.
    func revealEqualizer(toggle: Bool) {
        if toggle {
            if isEqualizerShowing { skinView.navDrawerOpen = false; return }
            mode = .navigator
        }
        if mode == .navigator { skinView.navDrawerOpen = true }
    }

    // MARK: - Controls

    /// Every press, in one place (decision record § *Control mapping*). The mode jumps and minimise
    /// are the window's; mid mode's nav button goes to the navigator, its vis window to visual mode
    /// and its song window to the Playlist Editor, as the menu screen's items do. Play is Sonique's
    /// play/stop toggle; pause resumes a paused track (help `02.htm`).
    @MainActor
    private func perform(_ control: SoniqueSkinControl) {
        let engine = WindowManager.shared.audioEngine
        switch control {
        case .ball(.modeUp): mode = mode == .small ? .mid : .navigator
        case .ball(.modeUpTwice), .navButton: mode = .navigator
        case .ball(.back): skinView.navScreen = .menu
        case .vis, .menu(.visualMode):
            mode = .navigator
            skinView.navScreen = .visualMode
        case .songInfo, .menu(.playlist): WindowManager.shared.togglePlaylist()
        case .menu(.library): WindowManager.shared.toggleMediaLibrary()
        case .menu(.setup):
            skinView.popUp(ContextMenuBuilder.buildMenu(includeOutputDevices: false, includeRepeatShuffle: false), under: .setup)
        case .menu(.audio): skinView.navDrawerOpen = true
        case .menu(.spectrum): WindowManager.shared.toggleSpectrum()
        case .menu(.peppyMeter): WindowManager.shared.togglePeppyMeter()
        case .menu(.art): WindowManager.shared.toggleArt()
        case .menu(.waveform): WindowManager.shared.toggleWaveform()
        case .menu(.skins): skinView.popUp(ContextMenuBuilder.buildSoniqueSkinsMenu(), under: .skins)
        case .menu(.history): WindowManager.shared.showLibraryHistory()
        case .menu(.about): (NSApp.delegate as? AppDelegate)?.showAbout()
        case .ball(.modeDown): mode = mode == .navigator ? .mid : .small
        case .ball(.modeDownTwice): mode = .small
        case .ball(.minimize): window?.miniaturize(nil)
        // NullPlayer has no help book; its About panel is the nearest thing.
        case .ball(.help): (NSApp.delegate as? AppDelegate)?.showAbout()
        case .ball(.close): NSApp.terminate(nil)
        case .play: engine.state == .playing ? engine.stop() : engine.play()
        case .pause: engine.state == .paused ? engine.play() : engine.pause()
        case .prev: engine.previous()
        case .next: engine.next()
        case .eject: MenuActions.shared.openFile()
        case .shuffle: engine.shuffleEnabled.toggle()
        case .repeatButton: engine.repeatEnabled.toggle()
        case .drawerTab: skinView.navDrawerOpen.toggle()
        // The rocker (S17): on the visual mode screen it steps the effect, as ⌘↓/⌘↑ do; anywhere
        // else it pages the Playlist Editor when that is open. Sonique paged its display with it.
        case .up, .down:
            let step = control == .down ? 1 : -1
            if skinView.navScreen == .visualMode {
                SkinEffectSelection.sonique.step(by: step)
            } else if let playlist = WindowManager.shared.playlistWindowController, playlist.window?.isVisible == true {
                playlist.page(by: step)
            }
        // The dials turn by dragging (`onDial`); the shuttle and rings do nothing yet.
        case .volume, .amp, .balance, .pitch, .eqSlider, .shuttle, .songRing, .listRing: break
        }
        refreshHostState()
    }

    // MARK: - Host state

    private func refreshHostState() {
        skinView.host = MainActor.assumeIsolated {
            SoniqueSkinAudioEngineHost.snapshot(WindowManager.shared.audioEngine, blinkersLit: blinkersLit)
        }
    }

    func updateTrackInfo(_ track: Track?) { refreshHostState() }
    func updateVideoTrackInfo(title: String, artworkTrack: Track?) {}
    func clearVideoTrackInfo() {}
    func updateTime(current: TimeInterval, duration: TimeInterval) { refreshHostState() }
    func updatePlaybackState() { refreshHostState() }

    func updateSpectrum(_ levels: [Float]) {
        skinView.updateSpectrum(levels)
        guard mode == .small else { return }
        let lit = (levels.prefix(4).max() ?? 0) > 0.6
        guard lit != blinkersLit else { return }
        blinkersLit = lit
        refreshHostState()
    }

    func skinDidChange() {}
    func windowVisibilityDidChange() {}

    func prepareForUITeardown() {
        loadTask?.cancel()
        loadTask = nil
    }

    // MARK: - Window delegate

    func windowDidMove(_ notification: Notification) {
        guard let window else { return }
        WindowManager.shared.applySnappedPosition(window, to: WindowManager.shared.windowWillMove(window, to: window.frame.origin))
    }
}
