import CoreGraphics
import Foundation

/// A loaded `.sgf`: what the skin itself supplies, immutable, built off the main thread by
/// `SoniqueSkinLoader`. An entry it omits is the default skin's (decision record § *Omitted entries
/// and the default skin*): read entries through `image(_:)` and `region(_:)`, and a mode through
/// `source(for:)`.
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
    /// Every `skin.ini` key Sonique reads, the skin's or the default.
    let settings: SoniqueSkinSettings
    /// Decoded JPEGs, keyed by lowercased entry name (`/jpeg/misc`).
    let images: [String: CGImage]
    /// Parsed regions, keyed by lowercased entry name (`/rgn/nav/play`), clipped to their mode picture.
    let regions: [String: SoniqueSkinRegion]
    /// Modes this skin does not draw (`SQ0009`): no picture, or `Touch…Mode = 0`.
    let defaultModes: Set<Mode>
    let findings: [SoniqueSkinFinding]

    /// NullPlayer's own default Sonique skin, which every omitted entry falls back to. A placeholder
    /// with no entries and `misc.txt`'s settings until S11 draws it.
    static let defaultSkin = SoniqueSkin(ini: SoniqueSkinINI(""), settings: SoniqueSkinSettings(SoniqueSkinINI("")),
                                         images: [:], regions: [:], defaultModes: [], findings: [])

    /// The entry, else the default skin's.
    func image(_ name: String) -> CGImage? { images[name] ?? Self.defaultSkin.images[name] }

    /// The entry, else the default skin's.
    func region(_ name: String) -> SoniqueSkinRegion? { regions[name] ?? Self.defaultSkin.regions[name] }

    /// The skin a mode is drawn from, settings included: the default skin for a mode this one leaves
    /// to it (`SQ0009`), so its picture, lit states and their positions stay one skin's.
    func source(for mode: Mode) -> SoniqueSkin { defaultModes.contains(mode) ? Self.defaultSkin : self }
}
