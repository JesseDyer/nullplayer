import CoreGraphics
import Foundation

/// A loaded `.sgf`: what the skin itself supplies, immutable, built off the main thread by
/// `SoniqueSkinLoader`. Anything absent here is the default skin's (decision record § *Omitted
/// entries and the default skin*); resolving that is S4's.
struct SoniqueSkin {
    /// Sonique's three window modes and the entries each one is drawn from.
    enum Mode: CaseIterable {
        case navigator, mid, small

        /// The mode's picture, buttons drawn unlit.
        var picture: String {
            switch self {
            case .navigator: return "/jpeg/navigator"
            case .mid: return "/jpeg/midsonique"
            case .small: return "/jpeg/smallstate"
            }
        }

        /// The prefix of the mode's `/rgn/` entries; `frame` under it is the window shape.
        var regions: String {
            switch self {
            case .navigator: return "/rgn/nav/"
            case .mid: return "/rgn/mid/"
            case .small: return "/rgn/small/"
            }
        }

        var frame: String { regions + "frame" }

        /// The `[skin]` key that, at 0, leaves the whole mode on the default skin.
        var touchKey: String {
            switch self {
            case .navigator: return "TouchNavMode"
            case .mid: return "TouchMidMode"
            case .small: return "TouchSmallMode"
            }
        }
    }

    let ini: SoniqueSkinINI
    /// Decoded JPEGs, keyed by lowercased entry name (`/jpeg/misc`).
    let images: [String: CGImage]
    /// Parsed regions, keyed by lowercased entry name (`/rgn/nav/play`), clipped to their mode picture.
    let regions: [String: SoniqueSkinRegion]
    /// Modes this skin does not draw (`SQ0009`): no picture, or `Touch…Mode = 0`.
    let defaultModes: Set<Mode>
    let findings: [SoniqueSkinFinding]
}
