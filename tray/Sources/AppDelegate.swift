import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, PaseoClientDelegate, MenuControllerDelegate {
    private let isDemo: Bool
    private let store = AgentStore()
    /// Flowly dispatchers (background agents); the menu and Quick Ask read it.
    let dispatcherStore = DispatcherStore()
    private let botsClient = BotsClient()
    private var quickAskPanelCreated = false
    private lazy var quickAskPanel: QuickAskPanel = {
        quickAskPanelCreated = true
        let panel = QuickAskPanel()
        panel.avatarProvider = { [weak self] bot in
            self?.botsClient.avatarImage(for: bot) ?? NSImage()
        }
        panel.onSubmit = { [weak self] bot, prompt in
            self?.submitPrompt(bot: bot, prompt: prompt)
        }
        panel.onAsk = { [weak self] bot, prompt in
            self?.askBot(bot, prompt: prompt)
        }
        panel.onFollowUp = { [weak self] text in
            self?.sendFollowUp(text)
        }
        panel.onStop = { [weak self] in
            self?.timelineClient.stop()
        }
        panel.onOpenInPaseo = { [weak self] in
            self?.openQuickAskChat()
        }
        panel.onClose = { [weak self] in
            self?.timelineClient.stopWatching()
        }
        return panel
    }()
    /// Streams one agent's timeline over the same daemon connection (the Quick Ask panel drives it).
    private(set) lazy var timelineClient: TimelineClient = {
        let timeline = TimelineClient(send: { [weak self] message in
            self?.client?.sendSessionMessage(message) ?? false
        })
        timeline.onChange = { [weak self] state in
            guard let self, self.isQuickAskChatCurrent else { return }
            self.quickAskPanel.render(state)
        }
        timeline.onError = { [weak self] message in
            guard let self, self.isQuickAskChatCurrent else { return }
            self.quickAskPanel.followUpFailed()
            self.quickAskPanel.showError(message)
        }
        return timeline
    }()
    private var configStore: TrayConfigStore!
    private var config = TrayConfig.defaults
    private var menuController: MenuController!
    private var hotKey: GlobalHotKey?
    private var hotKeyString: String??
    /// Whether tray.json existed at the last registration check.
    private var hotKeyAvailable = false
    private var hotKeyRecheckTimer: Timer?
    private var defaultsObserver: NSObjectProtocol?
    private var client: PaseoClient?
    private var notifier: Notifier!
    private var connection = PaseoConnectionStatus()
    private var serverId: String?
    private var wakeObserver: NSObjectProtocol?
    private let announceGate = AttentionGate()

    init(demo: Bool) {
        self.isDemo = demo
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The tray is an accessory app so the menu bar never shows this; it exists only so Cmd+C/X/V/A/Z reach text views.
        NSApp.mainMenu = EditMenu.makeMainMenu()
        configStore = TrayConfigStore()
        let loaded = configStore.load()
        config = loaded.config
        if let error = loaded.error {
            trayLog(error)
        }

        notifier = Notifier(config: config)
        notifier.isPaseoFrontmost = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "sh.paseo.desktop"
        }
        notifier.openURL = { [weak self] url in
            self?.open(url)
        }
        notifier.fallback = { [weak self] in
            NSSound.beep()
            self?.menuController.flash()
        }

        if isDemo {
            store.replace(entries: AgentStore.demoEntries(), hasMore: false)
            connection = PaseoConnectionStatus(
                phase: .connected,
                detail: "Demo",
                serverVersion: "demo",
                subscriptionError: nil
            )
            serverId = "srv_demo"
        }

        menuController = MenuController(
            store: store,
            config: config,
            connection: connection,
            serverId: serverId,
            isDemo: isDemo,
            botsClient: botsClient
        )
        menuController.delegate = self
        // MenuController owns the avatar callback; chain the Quick Ask picker after it.
        let menuImageLoaded = botsClient.onImageLoaded
        botsClient.onImageLoaded = { [weak self] in
            menuImageLoaded?()
            guard let self, self.quickAskPanelCreated else { return }
            self.quickAskPanel.refreshAvatars()
        }

        configStore.startWatching { [weak self] config, error in
            guard let self else { return }
            self.config = config
            self.notifier.updateConfig(config)
            self.menuController.update(
                store: self.store,
                config: config,
                connection: self.connection,
                serverId: self.serverId
            )
            if let error {
                trayLog(error)
            }
        }

        if !isDemo {
            let client = PaseoClient(delegate: self)
            self.client = client
            client.start()
        }

        registerHotKey()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.registerHotKey()
        }
        // tray.json can appear or disappear when the paseo-bots plugin is toggled; a 30 s
        // poll (plus a check on every menu open) is the simplest robust way to follow it.
        if !isDemo {
            hotKeyRecheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.registerHotKey()
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.client?.reconnectNow()
        }

        if ProcessInfo.processInfo.environment["PASEOTRAY_OPEN_MENU"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.menuController.openMenu()
            }
        }

        if isDemo {
            trayLog("Demo mode started")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        client?.stop()
        configStore?.stopWatching()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    // MARK: - PaseoClientDelegate

    func paseoClient(_ client: PaseoClient, event: PaseoClientEvent) {
        switch event {
        case .status(let status):
            let reconnected = status.phase == .connected && connection.phase != .connected
            connection = status
            if status.phase != .connected { dispatcherStore.clear() }
            refreshMenu()
            if reconnected { timelineClient.resubscribe() }
        case .timelineMessage(let type, let payload):
            timelineClient.handle(type: type, payload: payload)
        case .snapshot(let entries, let hasMore, let serverId):
            store.replace(entries: entries, hasMore: hasMore)
            self.serverId = serverId
            refreshMenu()
        case .agentUpdate(let payload):
            store.apply(update: payload)
            refreshMenu()
        case .dispatcherSnapshot(let entries):
            dispatcherStore.replace(entries: entries)
            refreshMenu()
        case .dispatcherUpdate(let payload):
            dispatcherStore.apply(update: payload)
            refreshMenu()
        case .attention(let payload):
            store.applyAttention(payload: payload)
            refreshMenu()
            guard let agentId = payload["agentId"] as? String,
                  let reason = payload["reason"] as? String else { return }
            let timestamp = TrayDate.parse(payload["timestamp"]) ?? Date()
            let isNew = announceGate.accept(
                agentId: agentId,
                reason: reason,
                timestamp: timestamp
            )
            let paseoFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == "sh.paseo.desktop"
            if NotificationPolicy.shouldAnnounce(isNew: isNew, paseoFrontmost: paseoFrontmost) {
                menuController.flash()
            }
            if isNew && !paseoFrontmost {
                notifier.notify(
                    agent: store.agents[agentId],
                    agentId: agentId,
                    reason: reason,
                    timestamp: timestamp,
                    deepLink: deepLink(agentId: agentId)
                )
            }
        }
    }

    private func refreshMenu() {
        menuController.update(
            store: store,
            config: config,
            connection: connection,
            serverId: serverId
        )
    }

    // MARK: - MenuControllerDelegate

    func menuControllerOpenAgent(_ agentId: String) {
        guard let url = deepLink(agentId: agentId) else {
            NSSound.beep()
            return
        }
        open(url)
    }

    func menuControllerOpenBot(_ botId: String) {
        guard let serverId, !serverId.isEmpty else {
            menuController.setBotChatError(L("Paseo isn't connected; can't open the chat", "Paseo 未连接，无法打开对话"))
            NSSound.beep()
            return
        }
        botsClient.startChat(botId: botId) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let agentId):
                self.menuController.setBotChatError(nil)
                guard let url = self.deepLink(agentId: agentId) else {
                    NSSound.beep()
                    return
                }
                self.open(url)
            case .failure(let error):
                self.menuController.setBotChatError(error.message)
                NSSound.beep()
            }
        }
    }

    func menuControllerNewChatWithPrompt(_ bot: TrayBot) {
        quickAskPanel.present(mode: .prompt(bot: bot))
    }

    private func submitPrompt(bot: TrayBot, prompt: String) {
        guard let serverId, !serverId.isEmpty else {
            quickAskPanel.showError(L("Paseo isn't connected; can't open the chat", "Paseo 未连接，无法打开对话"))
            return
        }
        let session = quickAskPanel.session
        quickAskPanel.setSending(true)
        botsClient.startChat(botId: bot.id, prompt: prompt, newChat: true) { [weak self] result in
            guard let self else { return }
            // The panel was closed or reused since this send: still open the chat that was
            // started, but leave the panel alone.
            let current = self.quickAskPanel.session == session
            if current { self.quickAskPanel.setSending(false) }
            switch result {
            case .success(let agentId):
                guard let url = self.deepLink(agentId: agentId) else {
                    if current {
                        self.quickAskPanel.showError(L("Paseo isn't connected; can't open the chat", "Paseo 未连接，无法打开对话"))
                    }
                    return
                }
                self.open(url)
                if current { self.quickAskPanel.close() }
            case .failure(let error):
                if current { self.quickAskPanel.showError(error.message) }
            }
        }
    }

    // MARK: - Quick Ask

    /// (Re)registers the global hotkey from the `QuickAskHotkey` default; does nothing when the setting is unchanged.
    /// Registers only while tray.json exists (paseo-bots installed) and never in demo mode.
    private func registerHotKey() {
        guard !isDemo else { return }
        let setting = QuickAskHotkeySetting.resolve()
        let available = TrayBotsFile.load() != nil
        if let previous = hotKeyString, previous == setting.string, hotKeyAvailable == available { return }
        hotKeyString = .some(setting.string)
        hotKeyAvailable = available
        hotKey = nil
        if available, let spec = setting.spec {
            hotKey = GlobalHotKey(spec: spec) { [weak self] in
                self?.toggleQuickAsk()
            }
        }
        // A failed registration leaves the menu item without a shortcut.
        menuController.setQuickAskShortcut(hotKey != nil ? setting.spec : nil)
    }

    /// Hotkey: closes the panel when it is already visible and key; otherwise shows it.
    private func toggleQuickAsk() {
        if quickAskPanelCreated, quickAskPanel.isQuickAskVisible, quickAskPanel.isKeyWindow {
            quickAskPanel.close()
        } else {
            showQuickAsk()
        }
    }

    func menuControllerWillOpen() {
        registerHotKey()
    }

    func menuControllerQuickAsk() {
        showQuickAsk()
    }

    /// Shows the Quick Ask panel. Does nothing when paseo-bots isn't installed (no tray.json).
    func showQuickAsk() {
        guard TrayBotsFile.load() != nil else { return }
        if quickAskPanel.isQuickAskVisible {
            quickAskPanel.present(mode: .quickAsk)
            // An earlier fetch failed: try again instead of leaving an empty picker.
            if quickAskPanel.bots.isEmpty, quickAskPanel.chatAgentId == nil {
                loadQuickAskBots()
            }
            return
        }
        quickAskPanel.present(mode: .quickAsk)
        loadQuickAskBots()
    }

    private func loadQuickAskBots() {
        let session = quickAskPanel.session
        botsClient.fetchBots { [weak self] result in
            guard let self, self.quickAskPanel.session == session else { return }
            switch result {
            case .loaded(let bots):
                self.quickAskPanel.clearError()
                self.quickAskPanel.setBots(BotRecents.ordered(bots))
            case .notInstalled:
                self.quickAskPanel.setBots([])
                self.quickAskPanel.showError(BotsError.notInstalled.message)
            case .unreachable:
                self.quickAskPanel.setBots([])
                self.quickAskPanel.showError(BotsError.unreachable.message)
            case .failed(let message):
                self.quickAskPanel.setBots([])
                self.quickAskPanel.showError(message)
            }
        }
    }

    /// True when the timeline client is streaming the chat the Quick Ask panel shows.
    private var isQuickAskChatCurrent: Bool {
        guard let agentId = quickAskPanel.chatAgentId else { return false }
        return timelineClient.agentId == agentId
    }

    /// Always a new chat; the panel streams it and never brings Paseo forward.
    private func askBot(_ bot: TrayBot, prompt: String) {
        guard connection.phase == .connected else {
            quickAskPanel.showError(L("Paseo isn't connected", "Paseo 未连接"))
            return
        }
        BotRecents.markUsed(bot.id)
        let session = quickAskPanel.session
        quickAskPanel.setSending(true)
        botsClient.startChat(botId: bot.id, prompt: prompt, newChat: true) { [weak self] result in
            // Closed or reset while starting: nobody is waiting for this chat.
            guard let self, self.quickAskPanel.session == session else { return }
            self.quickAskPanel.setSending(false)
            switch result {
            case .success(let agentId):
                self.quickAskPanel.chatStarted(agentId: agentId)
                self.timelineClient.watch(agentId: agentId)
            case .failure(let error):
                self.quickAskPanel.showError(error.message)
            }
        }
    }

    private func sendFollowUp(_ text: String) {
        guard connection.phase == .connected, isQuickAskChatCurrent else {
            quickAskPanel.showError(L("Paseo isn't connected", "Paseo 未连接"))
            return
        }
        quickAskPanel.clearError()
        // Keep the typed text when nothing was sent (the socket dropped after the check above).
        if timelineClient.sendFollowUp(text) {
            quickAskPanel.clearFollowUp()
        }
    }

    private func openQuickAskChat() {
        guard let agentId = quickAskPanel.chatAgentId, let url = deepLink(agentId: agentId) else {
            quickAskPanel.showError(L("Paseo isn't connected; can't open the chat", "Paseo 未连接，无法打开对话"))
            return
        }
        open(url)
    }

    func menuControllerOpenPaseo() {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "sh.paseo.desktop"
        ) else {
            showAlert(title: L("Paseo Not Found", "未找到 Paseo"), message: L("Make sure /Applications/Paseo.app is installed.", "请确认 /Applications/Paseo.app 已安装。"))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                DispatchQueue.main.async {
                    self.showAlert(title: L("Can’t Open Paseo", "无法打开 Paseo"), message: error.localizedDescription)
                }
            }
        }
    }

    func menuControllerToggleLoginItem() {
        switch LoginItem.status {
        case .enabled:
            do {
                try LoginItem.unregister()
                menuController.setLoginItemError(nil)
            } catch {
                menuController.setLoginItemError(error.localizedDescription)
                showAlert(title: L("Couldn’t Disable Launch at Login", "关闭登录自启失败"), message: error.localizedDescription)
            }
        case .requiresApproval:
            menuController.setLoginItemError(nil)
            LoginItem.openSystemSettings()
        default:
            do {
                try LoginItem.register()
                menuController.setLoginItemError(nil)
                if LoginItem.status == .requiresApproval {
                    LoginItem.openSystemSettings()
                }
            } catch {
                menuController.setLoginItemError(error.localizedDescription)
                showAlert(title: L("Couldn’t Enable Launch at Login", "开启登录自启失败"), message: error.localizedDescription)
            }
        }
        refreshMenu()
    }

    func menuControllerRevealConfig() {
        configStore.revealInFinder()
    }

    func menuControllerQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func deepLink(agentId: String) -> URL? {
        guard let serverId, !serverId.isEmpty else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let server = serverId.addingPercentEncoding(withAllowedCharacters: allowed),
              let agent = agentId.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "paseo://h/\(server)/agent/\(agent)")
    }

    private func open(_ url: URL) {
        if !NSWorkspace.shared.open(url) {
            trayLog("Couldn't open deep link: \(url.absoluteString)")
            NSSound.beep()
        }
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("OK", "好"))
        alert.runModal()
    }
}
