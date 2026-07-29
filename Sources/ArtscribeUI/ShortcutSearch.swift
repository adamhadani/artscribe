import Foundation

/// **The filter**, which narrows the keyboard and the list beside it at once.
///
/// A keyboard picture answers *"what can I press"* very well and *"what is the
/// shortcut for X"* very badly — you have to already know where to look. So the
/// window offers both surfaces and one field over them: type "loop" and the
/// list shows the loop actions while every key that is not one goes quiet.
///
/// What a query is matched against is the whole of what someone might type: the
/// action's name, the group it is in, the note under it, the chord both as it
/// is written (`⌥⇧A`) and as it is spoken ("option shift"), and the stable
/// identifier, which is what a bug report quotes.
public enum ShortcutSearch {

    /// Whether one action survives a query. An empty or all-whitespace query
    /// hides nothing.
    public static func matches(_ entry: ActionEntry, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return haystack(entry).range(
            of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// The catalog, filtered and grouped the way the list draws it: category
    /// order, no empty groups.
    ///
    /// **Unbound actions are included.** Stop, Clear Loop and the two Scroll
    /// items are menu items with no chord, and a window headed "Keyboard
    /// Shortcuts" that could not find them at all would send you to hunt
    /// through the menu bar for something it claims to be the index of. They
    /// are drawn as menu-only rather than with a blank where the key should be.
    public static func grouped(
        query: String
    ) -> [(category: ActionCategory, entries: [ActionEntry])] {
        ActionCategory.allCases.compactMap { category in
            let rows = ActionCatalog.entries.filter {
                $0.category == category && matches($0, query: query)
            }
            return rows.isEmpty ? nil : (category, rows)
        }
    }

    private static func haystack(_ entry: ActionEntry) -> String {
        var parts = [entry.title, entry.category.title, entry.id.rawValue]
        if let note = entry.note { parts.append(note) }
        parts.append(contentsOf: entry.chords.map(\.searchText))
        return parts.joined(separator: " ")
    }
}

extension KeyChord {
    /// The chord as written *and* as spoken, so both "⌥⇧A" and "option shift"
    /// find it. Nobody types `⌥` on the way to looking something up.
    var searchText: String {
        var parts = [display, key.display]
        if modifiers.contains(.control) { parts.append("control ctrl") }
        if modifiers.contains(.option) { parts.append("option alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("command cmd") }
        return parts.joined(separator: " ")
    }
}
