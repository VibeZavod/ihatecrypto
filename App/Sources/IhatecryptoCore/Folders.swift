import Foundation

/// Canvas folders from the chat: «save this canvas to folder Research» moves the open canvas there, «write to folder
/// Research: …» keeps the text there as a note of its own, without leaving the open canvas. A folder that isn't there yet
/// is made.
public enum FolderCommand: Equatable, Sendable {
    case save(folder: String)
    case note(folder: String, text: String)

    /// The folder a name means among those there: itself, the same name in other letter case, or one a typo away —
    /// one letter wrong, missing or extra, two in a name of eight or more («Reesarch», «Ресеррч» → «Research»,
    /// «Ресерч»). Without one it's a new folder. A closest name, never a guess between two.
    public static func existing(_ name: String, among folders: [String]) -> String? {
        let want = Array(name.lowercased())
        if let same = folders.first(where: { $0.lowercased() == name.lowercased() }) { return same }
        let near = folders.filter { f in
            let have = Array(f.lowercased())
            return min(want.count, have.count) >= 4 && distance(want, have) <= (max(want.count, have.count) >= 8 ? 2 : 1)
        }
        return near.count == 1 ? near[0] : nil
    }

    /// Levenshtein's edit distance between two names.
    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var prev = row[0]
            row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let keep = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = keep
            }
        }
        return a.isEmpty ? b.count : row[b.count]
    }

    public static func parse(_ text: String) -> FolderCommand? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = t.firstMatch(of: /(?is)^(?:write|note|add\s+a\s+note|запиши\w*|напиши\w*|заметк\w*|добавь\s+заметку)\s+(?:(?:to|in|into)\s+(?:the\s+)?folder|в\s+папк[уе])\s+[«"“]?([^:«»"“”]+?)[»"”]?\s*:\s*(.+)$/),
           let folder = name(String(m.1)) {
            let note = String(m.2).trimmingCharacters(in: .whitespacesAndNewlines)
            return note.isEmpty ? nil : .note(folder: folder, text: note)
        }
        if let m = t.firstMatch(of: /(?i)^(?:save|put|move|keep|сохрани\w*|положи\w*|перенеси\w*|перемести\w*|убери\w*|добавь)\s+(?:(?:this|the|my|этот|это|мой)\s+)?(?:canvas|chat|it|холст|канвас|чат|его)?\s*(?:to|in|into|в)\s+(?:the\s+)?(?:folder|папк[уе])\s+[«"“]?(.+?)[»"”]?\s*[.!]?$/),
           let folder = name(String(m.1)) {
            return .save(folder: folder)
        }
        return nil
    }

    /// Up to 40 characters, as the sidebar keeps it; nil for an empty one.
    static func name(_ raw: String) -> String? {
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? nil : String(n.prefix(40))
    }
}
