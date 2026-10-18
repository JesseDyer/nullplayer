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
        return state
    }

    private static func finite(_ t: TimeInterval) -> Double { t.isFinite && t > 0 ? t : 0 }
}
