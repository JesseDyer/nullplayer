import Foundation

/// Typing over the list jumps to the first row whose title starts with what was typed. The typed
/// text clears after a second without a key.
@MainActor
final class LibraryTypeAhead {
    private var query = ""
    private var timer: Timer?

    /// Apply a key: Escape clears, Delete drops the last character, and letters, digits and spaces
    /// are added. Returns the row to select, or nil when the selection stays.
    func handle(keyCode: UInt16, characters: String, in items: [LibraryBrowserItem]) -> Int? {
        switch keyCode {
        case 53: // Escape
            cancel()
            return nil
        case 51: // Delete
            guard !query.isEmpty else { return nil }
            query.removeLast()
        default:
            guard characters.rangeOfCharacter(from: .alphanumerics) != nil ||
                  characters.rangeOfCharacter(from: .whitespaces) != nil else { return nil }
            query += characters
        }

        let lowered = query.lowercased()
        guard !lowered.isEmpty else { return nil }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.query = "" }
        }
        return items.firstIndex { LibraryBrowserModel.titleMatchesTypeAhead($0.title, query: lowered) }
    }

    func cancel() {
        query = ""
        timer?.invalidate()
        timer = nil
    }
}
