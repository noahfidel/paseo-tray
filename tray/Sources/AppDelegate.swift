import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, PaseoClientDelegate, MenuControllerDelegate {
    private let isDemo: Bool
    private let store = AgentStore()
    /// Flowly dispatchers (background agents); the menu and Quick Ask read it.
    let dispatcherStore = DispatcherStore()
    private let botsClient = BotsClient()
    /// Open Quick Ask panels, one per target, oldest first (each with its own timeline client).
    private var quickAskWindows: [QuickAskWindow] = []
    private var promptPanelCreated = false
    /// "New chat with prompt…" has its own panel so it never disturbs a Quick Ask panel.
    private lazy var promptPanel: QuickAskPanel = {
        promptPanelCreated = true
        let panel = QuickAskPanel()
        panel.avatarProvider = { [weak self] bot in
            self?.botsClient.avatarImage(for: bot) ?? NSImage()
        }
        panel.onSubmit = { [weak self] bot, prompt in
            self?.submitPrompt(bot: bot, prompt: prompt)
        }
        return panel
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
            guard let self else { return }
            for window in self.quickAskWindows { window.panel.refreshAvatars() }
            if self.promptPanelCreated { self.promptPanel.refreshAvatars() }
        }

        configStore.startWatching { [weak self] config, error in
            guard let self else { return }
            self.config = config
            self.notifier.updateConfig(config)
            self.menuController.update(
                store: self.store,
                config: config,
                connection: self.connection,
                serverId: self.serverId,
                dispatchers: self.dispatcherStore.dispatchers()
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
            if status.phase != .connected {
                dispatcherStore.clear()
                registerHotKey()
            }
            refreshMenu()
            if reconnected {
                for window in quickAskWindows { window.timeline.resubscribe() }
            }
        case .timelineMessage(let type, let payload):
            var claimed = false
            for window in quickAskWindows where window.timeline.handle(type: type, payload: payload) { claimed = true }
            // A panel closed before its subscribe answer came: release that subscription here.
            TimelineClient.releaseUnclaimedSubscription(type: type, payload: payload, claimed: claimed) { [weak self] in
                self?.client?.sendSessionMessage($0) ?? false
            }
        case .snapshot(let entries, let hasMore, let serverId):
            store.replace(entries: entries, hasMore: hasMore)
            self.serverId = serverId
            refreshMenu()
        case .agentUpdate(let payload):
            store.apply(update: payload)
            refreshMenu()
        case .dispatcherSnapshot(let entries):
            dispatcherStore.replace(entries: entries)
            registerHotKey()
            refreshMenu()
        case .dispatcherUpdate(let payload):
            dispatcherStore.apply(update: payload)
            registerHotKey()
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
            serverId: serverId,
            dispatchers: dispatcherStore.dispatchers()
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
        promptPanel.present(mode: .prompt(bot: bot))
    }

    private func submitPrompt(bot: TrayBot, prompt: String) {
        guard let serverId, !serverId.isEmpty else {
            promptPanel.showError(L("Paseo isn't connected; can't open the chat", "Paseo 未连接，无法打开对话"))
            return
        }
        let session = promptPanel.session
        promptPanel.setSending(true)
        botsClient.startChat(botId: bot.id, prompt: prompt, newChat: true) { [weak self] result in
            guard let self else { return }
            // The panel was closed or reused since this send: still open the chat that was
            // started, but leave the panel alone.
            let current = self.promptPanel.session == session
            if current { self.promptPanel.setSending(false) }
            switch result {
            case .success(let agentId):
                guard let url = self.deepLink(agentId: agentId) else {
                    if current {
                        self.promptPanel.showError(L("Paseo isn't connected; can't open the chat", "Paseo 未连接，无法打开对话"))
                    }
                    return
                }
                self.open(url)
                if current { self.promptPanel.close() }
            case .failure(let error):
                if current { self.promptPanel.showError(error.message) }
            }
        }
    }

    // MARK: - Quick Ask

    /// (Re)registers the global hotkey from the `QuickAskHotkey` default; does nothing when the setting is unchanged.
    /// Registers only while Quick Ask has a target (tray.json exists, or at least one Flowly
    /// dispatcher is known) and never in demo mode.
    private func registerHotKey() {
        guard !isDemo else { return }
        let setting = QuickAskHotkeySetting.resolve()
        let available = TrayBotsFile.load() != nil || !dispatcherStore.dispatchers().isEmpty
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

    /// Hotkey: the last-used target's panel, closing it when it is already visible and key. When
    /// that panel is in a chat, a pre-chat panel or a new one is used instead (see `routeLastUsed`).
    private func toggleQuickAsk() {
        openLastUsedQuickAsk(toggle: true)
    }

    func menuControllerWillOpen() {
        registerHotKey()
    }

    func menuControllerQuickAsk() {
        openLastUsedQuickAsk(toggle: false)
    }

    func menuControllerQuickAsk(targetId: String) {
        openQuickAsk(targetId: targetId, toggle: false)
    }

    /// The recent targets that still resolve, most recent first (a dispatcher must be known; bots need tray.json).
    private func recentTargetIds() -> [String] {
        QuickAskPanelRouter.resolvedTargetIds(
            recent: BotRecents.recentIds(),
            dispatchers: dispatcherStore.dispatchers().map { (agentId: $0.agentId, groupId: $0.groupId) },
            botsAvailable: TrayBotsFile.load() != nil)
    }

    private func panelStates() -> [QuickAskPanelRouter.Panel] {
        quickAskWindows.map {
            QuickAskPanelRouter.Panel(
                targetId: $0.panel.targetId,
                busy: $0.panel.chatAgentId != nil || $0.panel.isSending,
                isVisible: $0.panel.isQuickAskVisible,
                isKey: $0.panel.isKeyWindow,
                hasDraft: $0.panel.hasDraft)
        }
    }

    /// Opens or brings forward the panel for `targetId` (one panel per target; see `QuickAskPanelRouter`).
    /// Does nothing when there is no target: no tray.json (paseo-bots) and no Flowly dispatchers.
    private func openQuickAsk(targetId: String?, toggle: Bool) {
        guard prepareQuickAsk() else { return }
        apply(QuickAskPanelRouter.route(panels: panelStates(), target: targetId, toggle: toggle), targetId: targetId)
    }

    /// Hotkey / plain "Quick Ask…" row: routes on the recent targets (see `QuickAskPanelRouter.routeLastUsed`).
    private func openLastUsedQuickAsk(toggle: Bool) {
        guard prepareQuickAsk() else { return }
        let routed = QuickAskPanelRouter.routeLastUsed(
            panels: panelStates(), recent: recentTargetIds(), toggle: toggle)
        apply(routed.action, targetId: routed.target)
    }

    /// False when there is no target: no tray.json (paseo-bots) and no Flowly dispatchers.
    /// Otherwise drops closed panels, so indices match `panelStates()`.
    private func prepareQuickAsk() -> Bool {
        // Dispatchers don't need paseo-bots, so they keep Quick Ask usable without it.
        guard TrayBotsFile.load() != nil || !dispatcherStore.dispatchers().isEmpty else { return false }
        quickAskWindows.removeAll { !$0.panel.isQuickAskVisible }
        return true
    }

    private func apply(_ action: QuickAskPanelRouter.Action, targetId: String?) {
        switch action {
        case .close(let index):
            quickAskWindows[index].panel.close()
        case .focus(let index):
            focusQuickAsk(quickAskWindows[index])
        case .retarget(let index):
            focusQuickAsk(quickAskWindows[index], selecting: targetId)
        case .open:
            let window = makeQuickAskWindow()
            let cascadeFrom = quickAskWindows.last?.panel.frame
            quickAskWindows.append(window)
            window.panel.present(mode: .quickAsk, cascadeFrom: cascadeFrom)
            // Before the bots load this stays pending; the picker selects it once it has it.
            if let targetId { window.panel.selectTarget(id: targetId) }
            refreshQuickAskDispatchers(window)
            loadQuickAskBots(window)
        }
    }

    /// Brings an open panel forward as it is (keeps a chat in progress); `targetId` retargets a
    /// pre-chat panel's picker.
    private func focusQuickAsk(_ window: QuickAskWindow, selecting targetId: String? = nil) {
        let panel = window.panel
        panel.present(mode: .quickAsk)
        // Dispatchers that appeared since the panel opened must be in the picker before selecting.
        if panel.chatAgentId == nil { refreshQuickAskDispatchers(window) }
        // An earlier fetch failed: try again instead of leaving an empty picker. Started before
        // selecting, so a bot target stays pending until this refetch ends.
        if panel.bots.isEmpty, panel.chatAgentId == nil {
            loadQuickAskBots(window)
        }
        if let targetId, panel.chatAgentId == nil { panel.selectTarget(id: targetId) }
    }

    private func makeQuickAskWindow() -> QuickAskWindow {
        let panel = QuickAskPanel()
        let timeline = TimelineClient(send: { [weak self] message in
            self?.client?.sendSessionMessage(message) ?? false
        })
        let window = QuickAskWindow(panel: panel, timeline: timeline)
        panel.avatarProvider = { [weak self] bot in
            self?.botsClient.avatarImage(for: bot) ?? NSImage()
        }
        panel.onAsk = { [weak self, weak window] target, prompt in
            guard let self, let window else { return }
            // The picker can sit on another panel's target (a default selection, or a pending
            // target that never arrived): that panel's chat wins, bring it forward instead.
            if self.focusOwner(of: target, otherThan: window) { return }
            switch target {
            case .bot(let bot): self.askBot(bot, prompt: prompt, in: window)
            case .dispatcher(let dispatcher): self.askDispatcher(dispatcher, prompt: prompt, in: window)
            }
        }
        panel.onFollowUp = { [weak self, weak window] text in
            guard let self, let window else { return }
            self.sendFollowUp(text, in: window)
        }
        panel.onStop = { [weak window] in
            window?.timeline.stop()
        }
        panel.onOpenInPaseo = { [weak self, weak window] in
            guard let self, let window else { return }
            self.openQuickAskChat(window)
        }
        panel.onPickTarget = { [weak self, weak window] targetId in
            guard let self, let window else { return true }
            return self.quickAskPickerChose(targetId, in: window)
        }
        panel.onChatEnded = { [weak window] in
            // New chat: this panel's chat is no longer watched; its owned subscription is released.
            window?.timeline.stopWatching()
        }
        panel.onClose = { [weak self, weak window] in
            guard let window else { return }
            // Only this panel's watch ends (its own subscription is released); the others keep theirs.
            window.timeline.stopWatching()
            // Drop it after close() returns, so the panel isn't freed while it is still closing.
            DispatchQueue.main.async {
                guard let self, !window.panel.isVisible else { return }
                self.quickAskWindows.removeAll { $0 === window }
            }
        }
        timeline.onChange = { [weak window] state in
            guard let window, window.isChatCurrent else { return }
            window.panel.render(state)
        }
        timeline.onError = { [weak window] message in
            guard let window, window.isChatCurrent else { return }
            window.panel.followUpFailed()
            window.panel.showError(message)
        }
        return window
    }

    /// When another open panel owns `target`, brings it forward and returns true.
    private func focusOwner(of target: QuickAskTarget, otherThan window: QuickAskWindow) -> Bool {
        let targetId: String
        switch target {
        case .bot(let bot): targetId = QuickAskTargets.botId(bot.id)
        case .dispatcher(let dispatcher): targetId = QuickAskTargets.dispatcherId(dispatcher.agentId)
        }
        guard let index = quickAskWindows.firstIndex(where: { $0 === window }),
              let owner = QuickAskPanelRouter.owner(of: targetId, panels: panelStates(), excluding: index)
        else { return false }
        focusQuickAsk(quickAskWindows[owner])
        return true
    }

    /// A pick in a panel's picker: when another open panel already has that target, bring that
    /// panel forward and refuse the pick (the picker goes back to its previous selection).
    private func quickAskPickerChose(_ targetId: String, in window: QuickAskWindow) -> Bool {
        guard let index = quickAskWindows.firstIndex(where: { $0 === window }),
              let owner = QuickAskPanelRouter.owner(of: targetId, panels: panelStates(), excluding: index)
        else { return true }
        focusQuickAsk(quickAskWindows[owner])
        return false
    }

    /// Dispatchers are known immediately (the store is live); an empty list leaves the picker as it is.
    private func refreshQuickAskDispatchers(_ window: QuickAskWindow) {
        let list = dispatcherStore.dispatchers()
        if !list.isEmpty || !window.panel.dispatchers.isEmpty {
            window.panel.setDispatchers(list)
        }
    }

    private func loadQuickAskBots(_ window: QuickAskWindow) {
        let panel = window.panel
        // A target asked for while this fetch runs must wait for it, even after an earlier failure.
        // One fetch per panel at a time; only the latest may fill the picker or show an error.
        guard let token = panel.botsFetchStarted() else { return }
        let session = panel.session
        botsClient.fetchBots { [weak panel] result in
            guard let panel, panel.session == session, panel.botsFetchFinished(token) else { return }
            switch result {
            case .loaded(let bots):
                panel.clearError()
                panel.setBots(bots)
            case .notInstalled:
                panel.setBots([])
                panel.showError(BotsError.notInstalled.message)
            case .unreachable:
                panel.setBots([])
                panel.showError(BotsError.unreachable.message)
            case .failed(let message):
                panel.setBots([])
                panel.showError(message)
            }
        }
    }

    /// Always a new chat; the panel streams it and never brings Paseo forward.
    private func askBot(_ bot: TrayBot, prompt: String, in window: QuickAskWindow) {
        let panel = window.panel
        guard connection.phase == .connected else {
            panel.showError(L("Paseo isn't connected", "Paseo 未连接"))
            return
        }
        BotRecents.markUsed(bot.id)
        let session = panel.session
        panel.setSending(true)
        botsClient.startChat(botId: bot.id, prompt: prompt, newChat: true) { [weak window] result in
            // Closed or reset while starting: nobody is waiting for this chat.
            guard let window, window.panel.session == session else { return }
            window.panel.setSending(false)
            switch result {
            case .success(let agentId):
                window.panel.chatStarted(agentId: agentId, targetId: QuickAskTargets.botId(bot.id))
                window.timeline.watch(agentId: agentId)
            case .failure(let error):
                window.panel.showError(error.message)
            }
        }
    }

    /// Continues the dispatcher's one existing chat; never interrupts a running turn and never
    /// answers a permission request (the panel's banner only points to Paseo).
    /// Sends steer: Flowly can start a turn between the isAskable check and the send, and the
    /// server's default would interrupt it. The server also clears pending permissions on any
    /// human message, so a permission that appears in that gap is cleared by the server; the tray
    /// never answers one deliberately.
    private func askDispatcher(_ dispatcher: TrayDispatcher, prompt: String, in window: QuickAskWindow) {
        let panel = window.panel
        guard connection.phase == .connected else {
            panel.showError(L("Paseo isn't connected", "Paseo 未连接"))
            return
        }
        guard let current = dispatcherStore.dispatchers().first(where: { $0.agentId == dispatcher.agentId }) else {
            panel.showError(L("That dispatcher is no longer available", "该调度器已不可用"))
            return
        }
        if current.needsYou {
            panel.showError(L("\(current.name) is waiting for you in Paseo",
                              "\(current.name) 正在 Paseo 中等你处理"))
            return
        }
        if !current.isAskable {
            panel.showError(L("\(current.name) is busy; try again when it finishes",
                              "\(current.name) 正在处理中，请稍后再试"))
            return
        }
        BotRecents.markDispatcherUsed(groupId: current.groupId)
        panel.clearError()
        // Send before the panel switches to chat mode is not possible (the client needs the watch
        // first), so on failure put the prompt back into the input.
        panel.chatStarted(agentId: current.agentId, targetId: QuickAskTargets.dispatcherId(current.agentId))
        window.timeline.watch(agentId: current.agentId, activeTurnBehavior: "steer")
        if window.timeline.sendFollowUp(prompt) {
            panel.clearFollowUp()
        } else {
            panel.restoreInput(prompt)
            panel.showError(L("Paseo isn't connected", "Paseo 未连接"))
        }
    }

    private func sendFollowUp(_ text: String, in window: QuickAskWindow) {
        let panel = window.panel
        guard connection.phase == .connected, window.isChatCurrent else {
            panel.showError(L("Paseo isn't connected", "Paseo 未连接"))
            return
        }
        panel.clearError()
        // Keep the typed text when nothing was sent (the socket dropped after the check above).
        if window.timeline.sendFollowUp(text) {
            panel.clearFollowUp()
        }
    }

    private func openQuickAskChat(_ window: QuickAskWindow) {
        guard let agentId = window.panel.chatAgentId, let url = deepLink(agentId: agentId) else {
            window.panel.showError(L("Paseo isn't connected; can't open the chat", "Paseo 未连接，无法打开对话"))
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

/// One Quick Ask panel and the timeline client that streams its chat.
private final class QuickAskWindow {
    let panel: QuickAskPanel
    let timeline: TimelineClient

    init(panel: QuickAskPanel, timeline: TimelineClient) {
        self.panel = panel
        self.timeline = timeline
    }

    /// True when the timeline client is streaming the chat the panel shows.
    var isChatCurrent: Bool {
        guard let agentId = panel.chatAgentId else { return false }
        return timeline.agentId == agentId
    }
}
