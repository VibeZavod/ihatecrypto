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

    /// The edit distance between two names: Levenshtein's, with two neighbours swapped as one slip («реесрч» for
    /// «ресерч»), the typo a hand makes most.
    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[a.count][b.count]
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
