import AppKit
import LalaCore
import SwiftUI
@preconcurrency import UserNotifications

extension Workspace {
    /// Settings → Chat and notifications: Auto (the language the user writes in), English or Russian.
    var chatLanguage: ChatLanguage { ChatLanguage(rawValue: UserDefaults.standard.string(forKey: "chatLanguage") ?? "") ?? .auto }
    private var ownWords: [String] { messages.filter(\.fromUser).suffix(8).map(\.text) }
    /// One of LALA's own replies in the user's language; tickers, amounts and addresses stay as they are.
    func say(_ english: String, _ russian: String) -> String { chatLanguage.isRussian(recentUserMessages: ownWords) ? russian : english }
    /// «Russian» or «English», for the model's instructions.
    var replyLanguage: String { chatLanguage.name(recentUserMessages: ownWords) }
}

/// What a notification is about; each kind can be turned off in Settings.
enum Notice: String, CaseIterable {
    case incoming, positions, orders, alerts, moves, hlp, signature, confirm

    var title: String {
        switch self {
        case .incoming: "Money arrived"
        case .positions: "A position closed, or its stop moved"
        case .orders: "A limit order filled"
        case .alerts: "A price alert fired"
        case .moves: "A confirmed move finished or failed"
        case .hlp: "The HLP deposit unlocked"
        case .signature: "A scheduled buy waits for Touch ID"
        case .confirm: "A move or a trade waits for your Confirm"
        }
    }

    var isOn: Bool { UserDefaults.standard.object(forKey: "notice.\(rawValue)") as? Bool ?? true }
}

/// Settings → Chat and notifications.
struct ChatAndNoticeSettings: View {
    @AppStorage("chatLanguage") private var language = ChatLanguage.auto.rawValue

    var body: some View {
        Section("Chat and notifications") {
            Picker("Reply language", selection: $language) {
                Text("Auto — the language you write in").tag(ChatLanguage.auto.rawValue)
                Text("English").tag(ChatLanguage.en.rawValue)
                Text("Русский").tag(ChatLanguage.ru.rawValue)
            }
            ForEach(Notice.allCases, id: \.self) { NoticeToggle(kind: $0) }
            Text("Notifications show while ihatecrypto is in the background or in the menu bar; a click brings its window back.")
                .font(.ui(10)).foregroundStyle(.secondary)
        }
    }
}

private struct NoticeToggle: View {
    let kind: Notice
    @AppStorage private var on: Bool

    init(kind: Notice) {
        self.kind = kind
        _on = AppStorage(wrappedValue: true, "notice.\(kind.rawValue)")
    }

    var body: some View { Toggle(kind.title, isOn: $on) }
}

/// A click on a notification brings the main window back, even when only the menu bar item was left.
final class NoticeDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NoticeDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            NSApp.activate()
            StatusItem.shared.openWindow?(id: "main")
        }
    }
}
