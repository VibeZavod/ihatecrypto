import os
import AppKit
import IhatecryptoCore
import SwiftUI
@preconcurrency import UserNotifications

extension Workspace {
    /// Settings → Chat and notifications: Auto (the language the user writes in), English or Russian.
    var chatLanguage: ChatLanguage { ChatLanguage(rawValue: UserDefaults.standard.string(forKey: "chatLanguage") ?? "") ?? .auto }
    private var ownWords: [String] { messages.filter(\.fromUser).suffix(8).map(\.text) }
    /// One of ihatecrypto's own replies in the user's language; tickers, amounts and addresses stay as they are.
    /// `spanish` where it's given: the lines a conversation meets most, so a Spanish chat isn't answered in English.
    func say(_ english: String, _ russian: String, _ spanish: String? = nil) -> String {
        if chatLanguage.isRussian(recentUserMessages: ownWords) { return russian }
        if let spanish, replyLanguage == "Spanish" { return spanish }
        return english
    }
    /// «Russian» or «English», for the model's instructions.
    var replyLanguage: String { chatLanguage.name(recentUserMessages: ownWords) }
}

/// What a notification is about; each kind can be turned off in Settings.
enum Notice: String, CaseIterable {
    case incoming, positions, orders, alerts, moves, hlp, signature, confirm, update

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
        case .update: "A new version of ihatecrypto is ready"
        }
    }

    var icon: String {
        switch self {
        case .incoming: "tray.and.arrow.down"
        case .positions: "chart.line.uptrend.xyaxis"
        case .orders: "checkmark.circle"
        case .alerts: "bell.badge"
        case .moves: "arrow.left.arrow.right"
        case .hlp: "lock.open"
        case .signature: "touchid"
        case .confirm: "hand.raised"
        case .update: "arrow.down.app"
        }
    }

    /// `log show --predicate 'subsystem == "app.ihatecrypto.mac"'`: what macOS answered about notifications.
    nonisolated static let log = Logger(subsystem: "app.ihatecrypto.mac", category: "notifications")

    var isOn: Bool { UserDefaults.standard.object(forKey: "notice.\(rawValue)") as? Bool ?? true }

    /// Sounds/, drawn by App/Tools/make-sounds.py: a coin when money arrived or moved, a chime when something wants a
    /// look, a low knock when a move failed. A changed sound gets a new name: macOS keeps playing the old one otherwise.
    func sound(failed: Bool = false) -> UNNotificationSound {
        let name = failed ? "knock-1.caf" : [.incoming, .orders, .moves, .hlp].contains(self) ? "coin-1.caf" : "chime-1.caf"
        return UNNotificationSound(named: UNNotificationSoundName(name))
    }
}

/// Settings › General › Notifications.
struct NoticeSettings: View {
    @State private var showingEvents = false
    @State private var enabledCount = Notice.allCases.filter(\.isOn).count

    var body: some View {
        SettingsSection(icon: "bell", title: "Notifications", line: "When the assistant taps you, even with the window closed.") {
            SettingsGroup {
                NoticePermission()
                SettingsRow("Which events", icon: "list.bullet") {
                    Button { showingEvents.toggle() } label: {
                        HStack(spacing: 8) {
                            Text("\(enabledCount) of \(Notice.allCases.count)").monospacedDigit()
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Which events, \(enabledCount) of \(Notice.allCases.count) enabled")
                    .popover(isPresented: $showingEvents) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                SettingsIcon(icon: "bell", size: 30)
                                Text("Which events").font(.ui(17, .bold))
                                Spacer()
                                Button("Done") { showingEvents = false }
                            }
                            SettingsGroup {
                                ForEach(Notice.allCases, id: \.self) { NoticeToggle(kind: $0) }
                            }
                        }
                        .padding(18).frame(width: 540)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            enabledCount = Notice.allCases.filter(\.isOn).count
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
        SettingsRow("Notifications", icon: "bell", info: "\(label). Notifications appear while the app is in the background or menu bar. Click one to return to the window. macOS controls whether they can appear.") {
            SettingsPill(text: status == nil ? "Checking…" : on ? "On" : "Off", good: on)
            if status == .notDetermined {
                Button("Allow…") { Task { await ask() } }
            } else if on {
                Button(sent ? "Sent" : "Send a test") { Task { await test() } }.disabled(sent)
            }
            Button("System Settings…") { Self.openSystemSettings() }
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
        content.sound = Notice.incoming.sound()
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        sent = true
    }

    /// System Settings › Notifications, on ihatecrypto's page once macOS lists it there.
    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "app.ihatecrypto.mac"
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

    var body: some View {
        SettingsRow(kind.title, icon: kind.icon) { Toggle(kind.title, isOn: $on).toggleStyle(AccentSwitch()) }
    }
}

/// A click on a notification brings the main window back, even when only the menu bar item was left. Shown while
/// ihatecrypto is in front too: without `willPresent` macOS drops the banner of the frontmost app.
final class NoticeDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NoticeDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let update = response.notification.request.content.threadIdentifier == Notice.update.rawValue
        await MainActor.run {
            NSApp.activate()
            StatusItem.shared.openWindow?(id: "main")
            // «ihatecrypto 0.3 is ready»: Sparkle's window with the notes and Install.
            if update { Updater.shared.check() }
        }
    }
}
