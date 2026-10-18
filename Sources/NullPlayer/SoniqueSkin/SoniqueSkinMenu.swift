import CoreGraphics
import Foundation

/// The navigator's menu screen: Sonique's layout and colours (`format.md` § *The navigator's menu
/// screen*), measured from the oracle's k2 capture in skin pixels from the display's top-left, with
/// NullPlayer's items in Sonique's places (decision record § *Control mapping*). Lycos's logo, icons
/// and quick links are not copied: NullPlayer's wordmark takes the logo's place and colours, and the
/// icons are NullPlayer's own marks in Sonique's boxes.
enum SoniqueSkinMenu {
    enum Item: Hashable, CaseIterable {
        case visualMode, playlist, library, setup, audio
        case spectrum, peppyMeter, art, waveform
        case skins, history, about
    }

    /// One line of Sonique's lettering (Verdana Bold): its left at `x`, on `baseline`, `spacing`
    /// extra points between letters (the right column is letter-spaced).
    struct Text: Equatable {
        let string: String, x: Int, baseline: Int, size: CGFloat, colour: String
        var spacing: CGFloat = 0
    }

    struct Entry {
        let item: Item
        /// The boxed icon beside a left-column item; nil for a link.
        let icon: SoniqueSkinRegion.Rect?
        let lines: [Text]
        /// What a press on the entry hits.
        let hit: SoniqueSkinRegion.Rect
    }

    /// The right column's headings, where Sonique's read *quick links* and *my sonique*.
    /// "my nullplayer" is three letters longer than Sonique's "my sonique": spaced as "windows" it
    /// runs past the display's edge, so it is spaced a quarter pixel.
    static let headings = [Text(string: "windows", x: 214, baseline: 38, size: 11, colour: "SystemColor_2", spacing: 1),
                           Text(string: "my nullplayer", x: 214, baseline: 110, size: 11, colour: "SystemColor_2",
                                spacing: 0.25)]

    static let entries: [Entry] = {
        func large(_ item: Item, _ title: String, _ subtitle: String, top: Int) -> Entry {
            Entry(item: item, icon: .init(left: 45, top: top, right: 66, bottom: top + 21),
                  lines: [Text(string: title, x: 75, baseline: top + 11, size: 14, colour: "SystemColor_3"),
                          Text(string: subtitle, x: 76, baseline: top + 20, size: 8, colour: "SystemColor_3")],
                  hit: .init(left: 45, top: top, right: 205, bottom: top + 21))
        }
        func small(_ item: Item, _ first: String, _ second: String, icon x: Int, right: Int) -> Entry {
            Entry(item: item, icon: .init(left: x, top: 169, right: x + 19, bottom: 188),
                  lines: [Text(string: first, x: x + 25, baseline: 177, size: 11, colour: "SystemColor_3"),
                          Text(string: second, x: x + 25, baseline: 186, size: 11, colour: "SystemColor_3")],
                  hit: .init(left: x, top: 168, right: right, bottom: 189))
        }
        func links(_ items: [(Item, String)], first baseline: Int) -> [Entry] {
            items.enumerated().map { i, link in
                let y = baseline + i * 11
                return Entry(item: link.0, icon: nil,
                             lines: [Text(string: link.1, x: 218, baseline: y, size: 9, colour: "SystemColor_3", spacing: 1)],
                             hit: .init(left: 214, top: y - 9, right: 300, bottom: y + 2))
            }
        }
        return [large(.visualMode, "visual mode", "visuals & spectrum", top: 74),
                large(.playlist, "playlist editor", "create & edit playlists", top: 104),
                large(.library, "find music", "library browser", top: 134),
                small(.setup, "setup", "options", icon: 21, right: 110),
                small(.audio, "audio", "controls", icon: 117, right: 205)]
            + links([(.spectrum, "spectrum"), (.peppyMeter, "peppymeter"), (.art, "art"), (.waveform, "waveform")], first: 51)
            + links([(.skins, "skins"), (.history, "play history"), (.about, "about")], first: 124)
    }()

    /// NullPlayer's wordmark where Sonique's *LYCOS sonique* sits (x 28–181, y 24–51 on k2): a small
    /// label where *LYCOS* is, a large word outlined in `LogoColor` over a ring in `LogoRingColor`.
    /// The ring is Sonique's swoosh, measured on its menu capture: a crescent between two ellipses,
    /// a hairline across the top that swells to 5 px underneath the word.
    enum Logo {
        static let label = Text(string: "null", x: 28, baseline: 31, size: 9, colour: "LogoColor", spacing: 1)
        static let word = Text(string: "player", x: 28, baseline: 51, size: 28, colour: "LogoColor")
        static let ring = SoniqueSkinRegion.Rect(left: 45, top: 22, right: 157, bottom: 57)
        static let ringHole = SoniqueSkinRegion.Rect(left: 46, top: 23, right: 156, bottom: 52)
    }

    /// NullPlayer's version where Sonique's own sits, bottom centre above the status line.
    static func version(_ string: String) -> Text {
        Text(string: string, x: 191, baseline: 209, size: 10, colour: "SystemColor_2")
    }
}
