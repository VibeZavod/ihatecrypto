import Foundation

/// Instructions the chat follows for one kind of work, switched on and off in Settings › Skills (the owner, 2026-10-16:
/// «было бы неплохо сделать в настройках скиллы»). The model is told each switched-on skill's name and what it is for;
/// when a message is that work it loads the whole text (the `skill` lookup), which then comes with every message on that
/// canvas. A skill only steers the chat: Confirm, the risk rules and the checks are code and stay as they are.
public struct Skill: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    /// What it is for, in a line: all the model sees of it until it loads it.
    public var about: String
    public var text: String
    public var builtIn = false

    public init(id: String, name: String, about: String, text: String, builtIn: Bool = false) {
        self.id = id; self.name = name; self.about = about; self.text = text; self.builtIn = builtIn
    }

    /// A skill from a file: a SKILL.md's front matter (`name:`, `description:`) when it has one, else the file's name
    /// and its first line of text.
    public static func parse(_ file: String, fileName: String) -> Skill {
        var body = file, fields: [String: String] = [:]
        if let m = file.firstMatch(of: /(?s)\A\s*---\n(.*?)\n---[ \t]*\n?/) {
            for line in m.1.split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                fields[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                    line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            }
            body = String(file[m.range.upperBound...])
        }
        let stem = (fileName as NSString).deletingPathExtension.replacing(/[_\-]+/, with: " ").trimmingCharacters(in: .whitespaces)
        let name = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? (stem.isEmpty ? "Skill" : stem.prefix(1).uppercased() + stem.dropFirst())
        let first = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("---") }
        let about = fields["description"].flatMap { $0.isEmpty ? nil : $0 } ?? first.map { String($0.prefix(200)) } ?? ""
        return Skill(id: slug(name), name: name, about: about, text: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// «Trading study» → «trading-study»: how the model names it in the lookup.
    public static func slug(_ s: String) -> String {
        let parts = s.lowercased().split { !$0.isLetter && !$0.isNumber }
        return parts.isEmpty ? "skill" : parts.joined(separator: "-")
    }

    /// The skills that come with ihatecrypto.
    public static let builtIn = [tradingStudy]
}
