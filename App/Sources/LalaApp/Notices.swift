import os
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

    /// `log show --predicate 'subsystem == "app.lala.mac"'`: what macOS answered about notifications.
    nonisolated static let log = Logger(subsystem: "app.lala.mac", category: "notifications")

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
            NoticePermission()
            ForEach(Notice.allCases, id: \.self) { NoticeToggle(kind: $0) }
            Text("Notifications show while ihatecrypto is in the background or in the menu bar; a click brings its window back.")
                .font(.ui(10)).foregroundStyle(.secondary)
        }
    }
}

/// What macOS allows, read when Settings opens and whenever ihatecrypto comes back to the front (from System Settings),
/// and the way to change it. macOS shows its «Allow notifications?» prompt only to an app in front, so a click here is
/// the sure way to get it; once asked, the switch lives in System Settings › Notifications › ihatecrypto.
private struct NoticePermission: View {
    @State private var status: UNAuthorizationStatus?
    @State private var sent = false

    var body: some View {
        HStack(spacing: 10) {
            Label(label, systemImage: on ? "bell.badge.fill" : "bell.slash")
                .foregroundStyle(on ? Brand.profit : Brand.jevInk).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if status == .notDetermined {
                Button("Allow notifications") { Task { await ask() } }.buttonStyle(.borderedProminent).tint(Brand.accent)
            } else if on {
                Button(sent ? "Sent" : "Send a test") { Task { await test() } }.disabled(sent)
            }
            Button("Notification Settings…") { Self.openSystemSettings() }
        }
        .task { await read() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await read() } }
    }

    private var on: Bool { status == .authorized || status == .provisional }

    private var label: String {
        switch status {
        case .authorized?, .provisional?: "Notifications are on"
        case .denied?: "macOS keeps ihatecrypto quiet: turn on «Allow notifications» in Notification Settings"
        case .notDetermined?: "macOS hasn’t asked yet: nothing can show until you allow it"
        default: "Checking…"
        }
    }

    private func read() async { status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }

    private func ask() async {
        NSApp.activate()
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        Notice.log.notice("asked from Settings: granted=\(granted)")
        await read()
    }

    private func test() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = NoticeDelegate.shared   // Settings are in front: without it macOS drops the banner
        let content = UNMutableNotificationContent()
        content.title = "ihatecrypto"
        content.body = "Notifications work: scheduled tasks, stops, alerts and moves waiting for Confirm show up here."
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        sent = true
    }

    /// System Settings › Notifications, on ihatecrypto's page once macOS lists it there.
    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "app.lala.mac"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!)
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

/// A click on a notification brings the main window back, even when only the menu bar item was left. Shown while
/// ihatecrypto is in front too: without `willPresent` macOS drops the banner of the frontmost app.
final class NoticeDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NoticeDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            NSApp.activate()
            StatusItem.shared.openWindow?(id: "main")
        }
    }
}
