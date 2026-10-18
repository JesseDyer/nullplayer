import Foundation

/// Every `skin.ini` key Sonique reads, resolved at load: the skin's value, else the default
/// (`SoniqueSkinDefaults`). A value reads the way the oracle reads it (decision record § *INI rules*):
/// its leading integer (`33.5` is 33, `69 (Repeat Green)` is 69), a colour's `0x` hex with the alpha
/// byte dropped, or `NAME`, `NAME + n`, `NAME - n` naming another key of the same section. An empty
/// value is unwritten; anything else is `SQ0011` and takes the default.
struct SoniqueSkinSettings {
    private(set) var values: [String: [String: Int]] = [:]
    private(set) var findings: [SoniqueSkinFinding] = []
    private let ini: SoniqueSkinINI
    private var visiting: Set<String> = []

    init(_ ini: SoniqueSkinINI) {
        self.ini = ini
        for (section, keys) in SoniqueSkinDefaults.values.sorted(by: { $0.key < $1.key }) {
            for key in keys.keys.sorted() { _ = resolve(section, key) }
        }
    }

    /// A key Sonique reads; `section` and `key` as `misc.txt` names them, in any case.
    func int(_ section: String, _ key: String) -> Int {
        values[section.lowercased()]![key.lowercased()]!
    }

    /// `0xRRGGBB` from `[sonique colors]`.
    func colour(_ key: String) -> UInt32 {
        UInt32(truncatingIfNeeded: int("sonique colors", key)) & 0xFF_FFFF
    }

    /// Where the closed drawer's (0,0) sits on the navigator picture. `DRAWER_POS` wins whenever the
    /// skin writes it, whatever its version; `MISC_DRAWER_POS` only otherwise, and 0,0 there reads as
    /// unwritten (format.md § *Window outline*).
    var drawerPosition: (x: Int, y: Int) {
        if written("misc locations", "DRAWER_POS_x") != nil {
            return (int("misc locations", "DRAWER_POS_x"), int("misc locations", "DRAWER_POS_y"))
        }
        let misc = (int("misc values", "MISC_DRAWER_POS_x"), int("misc values", "MISC_DRAWER_POS_y"))
        return misc == (0, 0) ? (29, 229) : misc  // `MISC_DRAWER_POS`'s default (`SoniqueSkinDefaults`)
    }

    /// The skin's own value; an empty one (`MISC_DRAWER_POS_x=`; 8 skins write one) counts as unwritten.
    private func written(_ section: String, _ key: String) -> String? {
        ini.value(section, key).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Nil only for a key that is neither a default nor written, or one that names itself through a cycle.
    private mutating func resolve(_ section: String, _ key: String) -> Int? {
        if let value = values[section]?[key] { return value }
        guard visiting.insert(section + "/" + key).inserted else { return nil }
        defer { visiting.remove(section + "/" + key) }
        let fallback = SoniqueSkinDefaults.values[section]?[key]
        var value: Int?
        if let raw = written(section, key) {
            value = parse(raw, section)
            if value == nil, fallback != nil {
                findings.append(SoniqueSkinFinding(.iniValueMalformed, "[\(section)] \(key) = \(raw) does not parse; the default is used."))
            }
        }
        if value == nil, let fallback { value = parse(fallback, section) }
        if let value, fallback != nil { values[section, default: [:]][key] = value }
        return value
    }

    private mutating func parse(_ raw: String, _ section: String) -> Int? {
        let text = Substring(raw.trimmingCharacters(in: .whitespaces))
        if section == "sonique colors", text.lowercased().hasPrefix("0x") {
            let digits = text.dropFirst(2).prefix { $0.isHexDigit }
            return digits.isEmpty ? nil : UInt32(digits.suffix(8), radix: 16).map(Int.init)
        }
        if let number = Self.leadingInteger(text) { return number }
        let name = text.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        guard let first = name.first, first.isLetter || first == "_" else { return nil }
        var rest = text.dropFirst(name.count).drop { $0 == " " || $0 == "\t" }
        var offset = 0
        if let sign = rest.first, sign == "+" || sign == "-" {
            rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" }
            guard let n = Self.leadingInteger(rest), rest.allSatisfy({ $0.isNumber }) else { return nil }
            offset = sign == "+" ? n : -n
        } else if !rest.isEmpty {
            return nil
        }
        return resolve(section, name.lowercased()).map { $0 + offset }
    }

    /// C `atoi`'s reading: an optional sign and the digits after it; nil when there are none.
    private static func leadingInteger(_ text: Substring) -> Int? {
        let sign = text.first == "-" || text.first == "+" ? 1 : 0
        let digits = text.dropFirst(sign).prefix { $0.isASCII && $0.isNumber }.prefix(9)
        guard let value = Int(digits) else { return nil }
        return text.first == "-" ? -value : value
    }
}
