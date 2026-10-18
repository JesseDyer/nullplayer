import AppKit

/// `AudioEngine` to `SoniqueSkinHostState`. A press goes the other way through
/// `SoniqueSkinMainWindowController.perform`.
@MainActor
enum SoniqueSkinAudioEngineHost {
    static func snapshot(_ engine: AudioEngine, blinkersLit: Bool) -> SoniqueSkinHostState {
        var state = SoniqueSkinHostState()
        switch engine.state {
        case .stopped: state.playState = .stopped
        case .playing: state.playState = .playing
        case .paused: state.playState = .paused
        }
        state.shuffle = engine.shuffleEnabled
        state.repeatAll = engine.repeatEnabled
        state.volume = Double(engine.volume)
        let elapsed = finite(engine.currentTime), duration = finite(engine.duration)
        state.elapsedSeconds = Int(elapsed)
        state.songProgress = duration > 0 ? elapsed / duration : 0
        // ponytail: by track count, not playlist time as Sonique's ring is; sum durations if it matters.
        let count = engine.playlist.count
        state.trackNumber = engine.currentIndex >= 0 ? engine.currentIndex + 1 : 0
        state.listProgress = count > 0 && engine.currentIndex >= 0 ? (Double(engine.currentIndex) + state.songProgress) / Double(count) : 0
        state.title = engine.currentTrack.map { track in
            [track.artist, track.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " - ")
        } ?? ""
        state.blinkersLit = blinkersLit
        state.version = BundleHelper.appVersion
        state.amp = Double(engine.getPreamp() / 24 + 0.5)
        state.balance = Double(engine.balance / 2 + 0.5)
        state.pitch = log2(Double(engine.playbackSpeed)) / speedOctaves + 0.5
        state.eq = (0..<SoniqueSkinScene.eqSliders).map { Double(engine.getEQBand(band(forSlider: $0, engine)) / 24 + 0.5) }
        return state
    }

    /// A dial turned to `value` (0–1), as NullPlayer's control (decision record § *Control mapping*):
    /// volume, the preamp and each EQ band across ±12 dB, balance, and the pitch knob as playback
    /// speed over NullPlayer's own range (`PitchTuningController`, 0.25×–4×, as the speed menu offers
    /// it) on a log scale, 1.0× at the middle with a detent there. The skin sets the look, not the
    /// behaviour: Sonique's own 50–200 % is not copied.
    static func setDial(_ control: SoniqueSkinControl, to value: Double, _ engine: AudioEngine) {
        let v = min(1, max(0, value))
        switch control {
        case .volume: engine.volume = Float(v)
        case .amp: engine.setPreamp(Float((v - 0.5) * 24))
        case .balance: engine.balance = Float(v * 2 - 1)
        case .pitch: engine.setPlaybackSpeed(abs(v - 0.5) < 0.03 ? 1 : Float(pow(2, (v - 0.5) * speedOctaves)))
        case .eqSlider(let slider): engine.setEQBand(band(forSlider: slider, engine), gain: Float((v - 0.5) * 24))
        default: break
        }
    }

    /// Octaves of playback speed across the pitch knob: 0.25× to 4×.
    private static let speedOctaves = Double(log2(PitchTuningController.maxRate / PitchTuningController.minRate))

    /// Sonique's 20 sliders over NullPlayer's 10 or 21 bands: each drives the band at its share.
    private static func band(forSlider slider: Int, _ engine: AudioEngine) -> Int {
        slider * engine.eqConfiguration.bandCount / SoniqueSkinScene.eqSliders
    }

    private static func finite(_ t: TimeInterval) -> Double { t.isFinite && t > 0 ? t : 0 }
}
