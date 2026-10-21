import Foundation

/// Sandboxed persistence surface shared by MAKI private values, configuration
/// objects, active color theme, and the active layout. Keys are scoped to the
/// imported skin and never expose arbitrary UserDefaults access to a script.
final class WinampModernConfiguration {
    let namespace: String
    private let defaults: UserDefaults

    init(namespace: String, defaults: UserDefaults = WinampModernConfiguration.processDefaults) {
        self.namespace = Self.safeComponent(namespace)
        self.defaults = defaults
    }

    /// Where a skin's settings live: the app's own domain, except in an `xctest` process — the corpus
    /// harnesses and the unit tests — which keeps them in memory. They all used to share the test
    /// tool's one domain, so what a skin's scripts stored in one run (the opensource notifier saves
    /// its checkboxes at `onScriptUnloading`) was the next run's starting state, and two sweeps of one
    /// tree differed (B211). In memory rather than cleared at start, because a sweep's shards run side
    /// by side, and rather than a suite per process, which leaves a plist behind every run.
    static let processDefaults: UserDefaults = Bundle.main.bundleIdentifier == "com.apple.dt.xctest.tool"
        ? VolatileDefaults(suiteName: nil) ?? .standard : .standard

    func integer(section: String, key: String, default defaultValue: Int32 = 0) -> Int32 {
        let name = storageKey(section: section, key: key)
        guard defaults.object(forKey: name) != nil else { return defaultValue }
        return Int32(clamping: Int64(defaults.integer(forKey: name)))
    }

    func setInteger(_ value: Int32, section: String, key: String) {
        defaults.set(Int(value), forKey: storageKey(section: section, key: key))
    }

    func string(section: String, key: String, default defaultValue: String = "") -> String {
        defaults.string(forKey: storageKey(section: section, key: key)) ?? defaultValue
    }

    func setString(_ value: String, section: String, key: String) {
        defaults.set(value, forKey: storageKey(section: section, key: key))
    }

    /// Genuinely unset a key, rather than storing a value that means "unset".
    ///
    /// Every other entry here has a free value it can spell "never set" with — `-1` for the integers,
    /// the empty string for the strings. A **colour** has none: every `#rrggbb` is a legal thing for a
    /// user to have chosen, so a user colour override can only be cleared by removing the key (B146).
    func removeValue(section: String, key: String) {
        defaults.removeObject(forKey: storageKey(section: section, key: key))
    }

    /// Unset every key in one section — the whole-skin reset behind a per-theme store.
    ///
    /// Still sandboxed: the prefix is built from `storageKey`'s own components, so the sweep can only
    /// ever reach keys this configuration could itself have written, inside its own namespace.
    func removeSection(_ section: String) {
        let prefix = sectionPrefix(section)
        for name in defaults.dictionaryRepresentation().keys where name.hasPrefix(prefix) {
            defaults.removeObject(forKey: name)
        }
        spellingsByFoldedKey = nil
    }

    static let keyPrefix = "winampModern.config."

    private func sectionPrefix(_ section: String) -> String {
        "\(Self.keyPrefix)\(namespace).\(Self.safeComponent(section))."
    }

    private func storageKey(section: String, key: String) -> String {
        storedSpelling(of: sectionPrefix(section) + Self.safeComponent(key))
    }

    /// Wasabi names an attribute case-insensitively, and so does the old MAKI compiler, which folds
    /// strings differing only in case into one: Anunaki's `main.maki` registers "Normal" as `normal`
    /// (sharing its layout id's string) while `inits.maki` and the Config Panel spell it `Normal`.
    /// Stored under the exact spelling those were two settings — Party! cleared one, the player-mode
    /// script read the other and switched straight back to normal. A key resolves to the spelling
    /// already stored, so nothing persisted is lost; a new key keeps the spelling it arrives with.
    private var spellingsByFoldedKey: [String: String]?

    private func storedSpelling(of key: String) -> String {
        if spellingsByFoldedKey == nil {
            let prefix = "\(Self.keyPrefix)\(namespace)."
            var index: [String: String] = [:]
            for name in defaults.dictionaryRepresentation().keys.sorted() where name.hasPrefix(prefix) {
                index[name.lowercased()] = index[name.lowercased()] ?? name
            }
            spellingsByFoldedKey = index
        }
        let folded = key.lowercased()
        if let stored = spellingsByFoldedKey?[folded] { return stored }
        spellingsByFoldedKey?[folded] = key
        return key
    }

    /// `static`, for the reason `WinampModernComponentRegistry.normalize` is written over bytes:
    /// this used to be rebuilt on every call, and `CharacterSet.alphanumerics.union(_:)` is not a
    /// cheap constant — it materializes Unicode bitmap planes (`CFUniCharGetBitmapForPlane`). Two
    /// calls per `storageKey`, and a `storageKey` per config read, puts it on the frame path for
    /// every `cfgattrib` in the scene: 2.5% of the main thread on cPro Bento (B105).
    private static let allowedComponentCharacters: CharacterSet =
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_ -"))

    private static func safeComponent(_ value: String) -> String {
        guard !value.isEmpty else { return "default" }
        // Section and key names are overwhelmingly already safe, and rebuilding an identical string
        // one `Character` at a time is the rest of the cost. Answer with the original when it is.
        if value.unicodeScalars.allSatisfy(allowedComponentCharacters.contains) { return value }
        var result = ""
        result.unicodeScalars.reserveCapacity(value.unicodeScalars.count)
        for scalar in value.unicodeScalars {
            result.unicodeScalars.append(allowedComponentCharacters.contains(scalar) ? scalar : "_")
        }
        return result
    }
}

/// A `UserDefaults` that keeps its values in memory, for `WinampModernConfiguration.processDefaults`.
/// It answers the calls the configuration and the harnesses make, and nothing reaches disk.
private final class VolatileDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    private let lock = NSLock()

    override func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    override func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    override func set(_ value: Int, forKey key: String) { set(value as Any?, forKey: key) }
    override func set(_ value: Bool, forKey key: String) { set(value as Any?, forKey: key) }
    override func set(_ value: Double, forKey key: String) { set(value as Any?, forKey: key) }
    override func removeObject(forKey key: String) { lock.withLock { values[key] = nil } }
    // Both convert between strings and numbers the way `UserDefaults` does: a setting written as
    // "1" reads back as 1, and one written as 1 reads back as "1".
    override func string(forKey key: String) -> String? {
        let value = object(forKey: key)
        return value as? String ?? (value as? NSNumber)?.stringValue
    }
    override func integer(forKey key: String) -> Int {
        let value = object(forKey: key)
        if let number = value as? NSNumber { return number.intValue }
        guard let text = value as? String else { return 0 }
        return Int(text) ?? Int(Double(text) ?? 0)
    }
    override func dictionaryRepresentation() -> [String: Any] { lock.withLock { values } }
}
