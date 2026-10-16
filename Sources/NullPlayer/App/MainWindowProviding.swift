import AppKit

/// Protocol abstracting the main player window.
/// Both the classic `MainWindowController` and modern `ModernMainWindowController`
/// conform to this protocol. `WindowManager` holds a reference to whichever is active,
/// allowing the rest of the app to be agnostic about which UI system is in use.
protocol MainWindowProviding: ModeDependentWindow {
    /// The underlying window
    var window: NSWindow? { get }

    /// Whether the window is currently visible
    var isWindowVisible: Bool { get }

    /// Show the window
    func showWindow(_ sender: Any?)

    /// Update the displayed track info (title, artist, bitrate, etc.)
    func updateTrackInfo(_ track: Track?)

    /// Update video track info display
    func updateVideoTrackInfo(title: String, artworkTrack: Track?)

    /// Clear video track info and revert to audio display
    func clearVideoTrackInfo()

    /// Update the time display
    func updateTime(current: TimeInterval, duration: TimeInterval)

    /// Update playback state indicators (play/pause/stop)
    func updatePlaybackState()

    /// Feed spectrum analyzer data for visualization
    func updateSpectrum(_ levels: [Float])

    /// Notify that the skin has changed and views should redraw
    func skinDidChange()

    /// Notify that window visibility of sibling windows changed (for toggle button states)
    func windowVisibilityDidChange()

    /// Mark the window content as needing redraw
    func setNeedsDisplay()

    /// Constrain a frame restored from saved state to what this window can actually render.
    ///
    /// Classic and NullPlayer-modern main windows are fixed-size, so their saved frame is always
    /// valid. A `.wal` skin sizes itself from its own layout and is freely resizable between that
    /// layout's `minimum_*`/`maximum_*`, so a frame saved in another session (or another skin) can
    /// be smaller than anything the scene can draw. The saved top-left is always preserved.
    func clampRestoredFrame(_ frame: NSRect) -> NSRect

    /// The play queue changed. A skin that draws its own queue (`.wal`, `.wmz`) re-bases its
    /// selection onto the playing row and repaints, as the Classic and Modern playlists' `reloadData`
    /// do (M48). Classic, Original and Audion keep no queue here.
    func playlistContentDidChange()

    /// The queue's ∿ EQ profile row markers changed; the queue and its selection did not. A skin
    /// that draws its own queue repaints it.
    func playlistMarkersDidChange()
}

// MARK: - Default Implementations

extension MainWindowProviding {
    var isWindowVisible: Bool {
        window?.isVisible == true
    }

    func setNeedsDisplay() {
        window?.contentView?.needsDisplay = true
    }

    func clampRestoredFrame(_ frame: NSRect) -> NSRect { frame }

    func playlistContentDidChange() {}

    func playlistMarkersDidChange() {}
}

/// A main window whose size is its skin's own canvas (`.wal`, `.wmz`, an Audion face): UI Size
/// multiplies that canvas, not `Skin.mainWindowSize`. `WindowManager.applyDoubleSize` tells the
/// controller the scale, then sets the player's frame from `mainWindowSize(atScale:)`.
protocol SkinSizedMainWindow: MainWindowProviding {
    func applyUIScale(_ scale: CGFloat)
    /// The window size the skin wants at `scale`; nil when it cannot answer yet.
    func mainWindowSize(atScale scale: CGFloat) -> NSSize?
}

extension WinampModernMainWindowController: SkinSizedMainWindow {}
extension WMPMainWindowController: SkinSizedMainWindow {}
extension AudionFaceMainWindowController: SkinSizedMainWindow {}
