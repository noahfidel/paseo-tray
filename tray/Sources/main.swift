import AppKit
import Foundation
import UserNotifications

let arguments = CommandLine.arguments

func hasFlag(_ flag: String) -> Bool {
    arguments.contains(flag)
}

if hasFlag("--version") {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    print("PaseoTray \(version)")
    exit(0)
}

if hasFlag("--bundle-info") {
    print("bundleIdentifier=\(Bundle.main.bundleIdentifier ?? "nil")")
    print("bundlePath=\(Bundle.main.bundlePath)")
    print("infoIdentifier=\(Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? "nil")")
    exit(0)
}

if hasFlag("--icon-info") {
    let tray = NSImage(named: "trayTemplate")
    print("trayTemplate loaded=\(tray != nil) size=\(tray?.size ?? .zero) template=\(tray?.isTemplate ?? false)")
    let appIcon = NSImage(named: "PaseoIcon")
    print("appIcon loaded=\(appIcon != nil) size=\(appIcon?.size ?? .zero)")
    exit(0)
}

if hasFlag("--notification-status") {
    let semaphore = DispatchSemaphore(value: 0)
    UNUserNotificationCenter.current().getNotificationSettings { settings in
        print("authorizationStatus=\(settings.authorizationStatus.rawValue)")
        print("alertSetting=\(settings.alertSetting.rawValue)")
        print("soundSetting=\(settings.soundSetting.rawValue)")
        print("notificationCenterSetting=\(settings.notificationCenterSetting.rawValue)")
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

if hasFlag("--delivered-notifications") {
    let semaphore = DispatchSemaphore(value: 0)
    UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
        for notification in notifications {
            print("\(notification.request.identifier) | \(notification.request.content.title) | \(notification.request.content.body)")
        }
        print("count=\(notifications.count)")
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

if hasFlag("--clear-notifications") {
    UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    print("cleared")
    exit(0)
}

if hasFlag("--bots-list") {
    BotsCLI.list()
    exit(0)
}

if let index = arguments.firstIndex(of: "--bots-chat") {
    guard index + 1 < arguments.count else {
        fputs("usage: --bots-chat <botId> [--prompt <text>]\n", stderr)
        exit(2)
    }
    var prompt: String?
    if let promptIndex = arguments.firstIndex(of: "--prompt") {
        guard promptIndex + 1 < arguments.count else {
            fputs("usage: --bots-chat <botId> [--prompt <text>]\n", stderr)
            exit(2)
        }
        prompt = arguments[promptIndex + 1]
    }
    exit(BotsCLI.chat(botId: arguments[index + 1], prompt: prompt))
}

if hasFlag("--quick-ask-status") {
    // Headless: registers the hotkey in-process (Carbon needs no window), reports, then unregisters on exit.
    let available = TrayBotsFile.load() != nil
    let setting = QuickAskHotkeySetting.resolve()
    var registered = false
    var hotKey: GlobalHotKey?
    if let spec = setting.spec {
        hotKey = GlobalHotKey(spec: spec) {}
        registered = hotKey != nil
    }
    print("available=\(available) hotkey=\(setting.string ?? "disabled") registered=\(registered)")
    hotKey = nil
    exit(0)
}

if hasFlag("--self-check") {
    exit(AgentStore.runSelfCheck() ? 0 : 1)
}

if hasFlag("--login-item-status") {
    print(LoginItem.statusText)
    exit(0)
}

if hasFlag("--login-item-register") {
    do {
        try LoginItem.register()
        print("register: \(LoginItem.statusText)")
        exit(0)
    } catch {
        fputs("register failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if hasFlag("--login-item-unregister") {
    do {
        try LoginItem.unregister()
        print("unregister: \(LoginItem.statusText)")
        exit(0)
    } catch {
        fputs("unregister failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

/// `--timeline-watch <agentId> [--seconds N]`: read-only headless transcript stream.
final class TimelineWatch: PaseoClientDelegate {
    private let agentId: String
    private var client: PaseoClient?
    private var timeline: TimelineClient?
    private var printed: [String: ChatRow] = [:]
    private var lastTurn: TurnState?
    private var connected = false
    private var watching = false
    private var lastDetail = ""

    init(agentId: String) { self.agentId = agentId }

    private func escaped(_ text: String) -> String {
        String(text.replacingOccurrences(of: "\n", with: "\\n").prefix(80))
    }

    private func line(_ row: ChatRow) -> (key: String, text: String) {
        switch row {
        case .user(let id, let text): return (id, "user: \(escaped(text))")
        case .assistant(let id, let text): return (id, "assistant: \(escaped(text))")
        case .tool(let callId, let name, let status, _): return (callId, "tool[\(status)]: \(name)")
        case .error(let id, let message): return (id, "error: \(escaped(message))")
        case .notice(let id, let text): return (id, "notice: \(escaped(text))")
        case .unsupported(let id, let type): return (id, "unsupported: \(type)")
        }
    }

    private func render(_ state: TimelineState) {
        for row in state.rows {
            let (key, text) = line(row)
            if printed[key] == row { continue }
            printed[key] = row
            print(text)
        }
        if lastTurn != state.turn {
            lastTurn = state.turn
            print("turn=\(state.turn)")
        }
        fflush(stdout)
    }

    func start(seconds: Double) {
        let timeline = TimelineClient(send: { [weak self] in self?.client?.sendSessionMessage($0) ?? false })
        timeline.onChange = { [weak self] in self?.render($0) }
        timeline.onError = { message in
            fputs("error: \(message)\n", stderr)
        }
        self.timeline = timeline
        let client = PaseoClient(delegate: self)
        self.client = client
        client.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { exit(1) }
            if !self.connected {
                fputs("not connected: \(self.lastDetail)\n", stderr)
                exit(1)
            }
            exit(self.timeline?.state.hasSnapshot == true ? 0 : 1)
        }
    }

    func paseoClient(_ client: PaseoClient, event: PaseoClientEvent) {
        switch event {
        case .status(let status):
            lastDetail = status.detail
            let nowConnected = status.phase == .connected
            if nowConnected && !connected {
                if watching { timeline?.resubscribe() } else { watching = true; timeline?.watch(agentId: agentId) }
            }
            connected = nowConnected
        case .timelineMessage(let type, let payload):
            timeline?.handle(type: type, payload: payload)
        default:
            break
        }
    }
}

let app = NSApplication.shared
let diagnosticsMode = hasFlag("--selftest") || hasFlag("--watch-json")
let demoMode = hasFlag("--demo")

if hasFlag("--test-notification") {
    app.setActivationPolicy(.prohibited)
    let notifier = Notifier(config: TrayConfig.defaults)
    notifier.sendTestNotification()
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        exit(0)
    }
    app.run()
    exit(0)
}

if let index = arguments.firstIndex(of: "--timeline-watch") {
    guard index + 1 < arguments.count else {
        fputs("usage: --timeline-watch <agentId> [--seconds N]\n", stderr)
        exit(2)
    }
    var seconds = 15.0
    if let secondsIndex = arguments.firstIndex(of: "--seconds") {
        guard secondsIndex + 1 < arguments.count, let value = Double(arguments[secondsIndex + 1]), value > 0 else {
            fputs("usage: --timeline-watch <agentId> [--seconds N]\n", stderr)
            exit(2)
        }
        seconds = value
    }
    app.setActivationPolicy(.prohibited)
    let watch = TimelineWatch(agentId: arguments[index + 1])
    watch.start(seconds: seconds)
    app.run()
    exit(0)
}

app.setActivationPolicy(diagnosticsMode ? .prohibited : .accessory)

if diagnosticsMode {
    let diagnostics = Diagnostics(watch: hasFlag("--watch-json"))
    diagnostics.start()
    app.run()
    exit(0)
}

let delegate = AppDelegate(demo: demoMode)
app.delegate = delegate
app.run()
