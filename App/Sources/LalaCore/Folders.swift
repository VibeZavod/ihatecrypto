import Foundation

/// Canvas folders from the chat: «save this canvas to folder Research» moves the open canvas there, «write to folder
/// Research: …» keeps the text there as a note of its own, without leaving the open canvas. A folder that isn't there yet
/// is made.
public enum FolderCommand: Equatable, Sendable {
    case save(folder: String)
    case note(folder: String, text: String)

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
