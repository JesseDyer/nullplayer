import Foundation

/// What a Wasabi object is, parsed once from its tag when the object is made (B228).
///
/// A tag is a local name and an optional namespace: `Wasabi:Button` is `button` in `wasabi`, a bare
/// `<button>` is `button` in `none`. The two answer different questions, and a compare used to pick
/// one by spelling — the full name or the namespace-dropped one — at each site, which is how B217
/// found the two spellings matching differently from one line to the next. Now a site says which
/// it means: `object.kind == .button` for either spelling, `object.is(.button)` for the bare tag
/// only, `object.is(.button, in: .wasabi)` for the standard library's.
///
/// The cases are the tags the engine treats specially; every other tag is `.other`. A skin's own
/// XUI tags are not cases: they are the skin's, looked up in its registry.
enum WasabiKind: String {
    case albumArt = "albumart"
    case animatedLayer = "animatedlayer"
    case browser
    case button
    case component
    case componentBucket = "componentbucket"
    case container
    case customObject = "customobject"
    case edit
    case editBox = "editbox"
    case eqVis = "eqvis"
    case frame
    case gradient
    case grid
    case group
    case groupList = "grouplist"
    case images
    case layer
    case layout
    case layoutStatus = "layoutstatus"
    case list
    case menu
    case nStatesButton = "nstatesbutton"
    case noStatus = "nostatus"
    case progressGrid = "progressgrid"
    case rect
    case scripts
    case slider
    case songticker
    case staticFrame = "static"
    case status
    case tabSheet = "tabsheet"
    case text
    case titleBox = "titlebox"
    case toggleButton = "togglebutton"
    case tree
    case vis
    case windowHolder = "windowholder"
    case other
}

/// The namespace a tag was written in: `Wasabi:`, `Wasabi:StandardFrame:`, `Winamp:`,
/// `ColorThemes:`, or none.
enum WasabiNamespace {
    case none
    case wasabi
    case wasabiStandardFrame
    case winamp
    case colorThemes
    case other
}

extension WasabiKind {
    /// `tag` split into its kind and namespace, ignoring case.
    static func parse(_ tag: String) -> (kind: WasabiKind, namespace: WasabiNamespace) {
        let lower = tag.lowercased()
        guard let colon = lower.lastIndex(of: ":") else { return (WasabiKind(rawValue: lower) ?? .other, .none) }
        let namespace: WasabiNamespace
        switch lower[..<colon] {
        case "wasabi": namespace = .wasabi
        case "wasabi:standardframe": namespace = .wasabiStandardFrame
        case "winamp": namespace = .winamp
        case "colorthemes": namespace = .colorThemes
        default: namespace = .other
        }
        return (WasabiKind(rawValue: String(lower[lower.index(after: colon)...])) ?? .other, namespace)
    }
}
