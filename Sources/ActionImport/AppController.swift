import ActionImportCore
@preconcurrency import AppKit
import ServiceManagement
import UserNotifications

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private var settings = AppSettings()
    private var cameras: [CameraVolume] = []
    private var statusItem: NSStatusItem!
    private let panel = ImportPanelView()
    private let popover = NSPopover()
    private let contextMenu = NSMenu()
    private var cameraPicker: NSPopUpButton { panel.cameraPicker }
    private var summaryLabel: NSTextField { panel.summaryLabel }
    private var stateLabel: NSTextField { panel.stateLabel }
    private var fileLabel: NSTextField { panel.fileLabel }
    private var progressBar: ImportProgressLine { panel.progressBar }
    private var autoButton: NSButton { panel.autoButton }
    private var proxyButton: NSButton { panel.proxyButton }
    private var loginButton: NSButton { panel.loginButton }
    private var destinationButton: NSButton { panel.destinationButton }
    private var primaryAction = ImportPresentation.Action.configure
    private var displayPhase = ImportPresentation.Phase.waiting
    private var lastImported = 0
    private var worker: Task<ImportResult, Error>?
    private var scanning = false
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var terminating = false
    private var activeImport: UUID?
    private var scannedFiles = 0
    private var settingsRevision = 0
    private var statusRevision = 0
    private var settingsTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        setupPanel()
        refreshControls()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] notification in
            let mountedURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(1))
                await self.refreshCameras()
                if self.configuredCamera?.url.standardizedFileURL == mountedURL?.standardizedFileURL {
                    self.scanAndMaybeStart(automatically: true)
                }
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshCameras()
                if self.configuredCamera == nil {
                    self.worker?.cancel()
                    if self.worker == nil { self.scanAndMaybeStart(automatically: false) }
                }
            }
        })
        Task { @MainActor in
            do { settings = try await RuntimeStore.shared.loadSettings() }
            catch { panel.settingsFeedback.stringValue = "设置读取失败：\(error.localizedDescription)" }
            await refreshCameras()
            if settings.autoImport { requestNotifications() }
            if settings.volumeIdentifier == nil || settings.destinationPath == nil {
                panel.showSettings(true)
                showPanel()
            }
            scanAndMaybeStart(automatically: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard worker != nil || settingsTask != nil else { return .terminateNow }
        terminating = true
        let pendingWorker = worker
        let pendingSettings = settingsTask
        pendingWorker?.cancel()
        Task { @MainActor in
            _ = try? await pendingWorker?.value
            await pendingSettings?.value
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private var configuredCamera: CameraVolume? {
        cameras.first { $0.identifier == settings.volumeIdentifier }
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = ImportPanelView.menuIcon()
        statusItem.button?.toolTip = "ActionImport · 相机素材自动导入"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        for (title, action) in [("ActionImport", #selector(showPanel)), ("立即导入 / 重试", #selector(retryImport)), ("完整核对已导入素材", #selector(fullVerifyImport)), ("打开保存目录", #selector(openDestination))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            contextMenu.addItem(item)
        }
        contextMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 ActionImport", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        contextMenu.addItem(quit)
    }

    private func setupPanel() {
        let controller = NSViewController()
        controller.view = panel
        popover.contentViewController = controller
        popover.contentSize = panel.frame.size
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown, event.keyCode == 53 else { return event }
            self.popover.performClose(nil)
            return nil
        }
        cameraPicker.target = self
        cameraPicker.action = #selector(selectCamera)
        destinationButton.target = self
        destinationButton.action = #selector(chooseDestination)
        for button in [autoButton, panel.mainAutoButton, proxyButton, loginButton] {
            button.target = self
            button.action = button == loginButton ? #selector(changeLogin) : #selector(changeOptions)
        }
        for (button, action) in [
            (panel.primaryButton, #selector(performPrimaryAction)),
            (panel.refreshButton, #selector(refreshCamera)),
            (panel.settingsButton, #selector(showSettings)),
            (panel.backButton, #selector(showMain)),
            (panel.mainDestinationButton, #selector(chooseDestination)),
            (panel.quitButton, #selector(NSApplication.terminate(_:))),
        ] {
            button.target = button == panel.quitButton ? NSApp : self
            button.action = action
        }
    }

    private func refreshControls() {
        cameraPicker.removeAllItems()
        cameraPicker.addItem(withTitle: "选择自动导入的相机")
        for camera in cameras { cameraPicker.addItem(withTitle: camera.name) }
        if let index = cameras.firstIndex(where: { $0.identifier == settings.volumeIdentifier }) { cameraPicker.selectItem(at: index + 1) }
        autoButton.state = settings.autoImport ? .on : .off
        proxyButton.state = settings.includeProxies ? .on : .off
        loginButton.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let idle = worker == nil && !scanning
        cameraPicker.isEnabled = idle
        destinationButton.isEnabled = idle
        panel.mainDestinationButton.isEnabled = idle
        panel.refreshButton.isEnabled = idle
        proxyButton.isEnabled = idle
        autoButton.isEnabled = idle && settings.volumeIdentifier != nil && settings.destinationPath != nil
        updatePresentation()
    }

    private func refreshCameras() async {
        cameras = await RuntimeStore.shared.connectedCameras()
        refreshControls()
    }

    @objc private func showPanel() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            panel.window?.makeKey()
            panel.showSettings(panel.showingSettings)
        }
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            contextMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
        } else if popover.isShown { popover.performClose(nil) }
        else { showPanel() }
    }

    @objc private func showSettings() { panel.showSettings(true) }
    @objc private func showMain() { panel.showSettings(false) }

    @objc private func performPrimaryAction() {
        switch primaryAction {
        case .configure: showSettings()
        case .start: startImport()
        case .retry: retryImport()
        case .stop: stopImport()
        case .open: openDestination()
        }
    }

    @objc private func retryImport() {
        scanAndMaybeStart(automatically: false, startWhenReady: true)
    }

    /// Rereads every source and archive instead of trusting unchanged metadata.
    @objc private func fullVerifyImport() {
        guard worker == nil, !scanning else { return }
        scanAndMaybeStart(automatically: false, startWhenReady: true, verification: .full)
    }

    @objc private func refreshCamera() {
        Task { @MainActor in
            await refreshCameras()
            scanAndMaybeStart(automatically: false)
        }
    }

    @objc private func selectCamera() {
        let index = cameraPicker.indexOfSelectedItem - 1
        guard cameras.indices.contains(index) else { return }
        settings.volumeIdentifier = cameras[index].identifier
        settings.volumeName = cameras[index].name
        saveSettings()
        scanAndMaybeStart(automatically: false)
    }

    @objc private func chooseDestination() {
        guard worker == nil, !scanning else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "保存到这里"
        panel.directoryURL = URL(fileURLWithPath: settings.destinationPath ?? NSHomeDirectory() + "/Movies")
        popover.performClose(nil)
        defer { self.panel.showSettings(true); showPanel() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.destinationPath = url.path
        saveSettings()
        scanAndMaybeStart(automatically: false)
    }

    @objc private func changeOptions(_ sender: NSButton) {
        if sender == panel.mainAutoButton { autoButton.state = sender.state }
        settings.includeProxies = proxyButton.state == .on
        settings.autoImport = autoButton.state == .on
        saveSettings()
        if settings.autoImport { requestNotifications() }
        scanAndMaybeStart(automatically: false)
    }

    @objc private func changeLogin() {
        do {
            if loginButton.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { panel.settingsFeedback.stringValue = "登录启动设置失败：\(error.localizedDescription)" }
        refreshControls()
    }

    private func saveSettings() {
        settingsRevision += 1
        let revision = settingsRevision
        let snapshot = settings
        settingsTask = Task { @MainActor in
            do { try await RuntimeStore.shared.saveSettings(snapshot, revision: revision) }
            catch {
                if revision == settingsRevision { panel.settingsFeedback.stringValue = "设置保存失败：\(error.localizedDescription)" }
            }
        }
        refreshControls()
    }

    private func request(verification: ImportRequest.Verification = .quick) -> ImportRequest? {
        guard let camera = configuredCamera, let path = settings.destinationPath else { return nil }
        return ImportRequest(source: camera.url, destination: URL(fileURLWithPath: path), includeProxies: settings.includeProxies, verification: verification)
    }

    private func scanAndMaybeStart(automatically: Bool, startWhenReady: Bool = false, verification: ImportRequest.Verification = .quick) {
        guard worker == nil, !scanning else { return }
        guard let request = request() else {
            summaryLabel.stringValue = settings.volumeIdentifier == nil ? "选择相机和保存目录后可查看素材" : "等待 \(settings.volumeName ?? "相机") 接入"
            stateLabel.stringValue = settings.volumeIdentifier == nil || settings.destinationPath == nil ? "选择相机和保存目录" : "连接相机并选择文件传输"
            statusItem.button?.title = ""
            progressBar.doubleValue = 0
            fileLabel.stringValue = ""
            writeStatus(.waiting, message: summaryLabel.stringValue)
            return
        }
        scanning = true
        scannedFiles = 0
        stateLabel.stringValue = "扫描中…"
        summaryLabel.stringValue = "正在查找相机中的视频素材"
        fileLabel.stringValue = ""
        progressBar.doubleValue = 0
        statusItem.button?.title = " 扫描"
        writeStatus(.scanning)
        refreshControls()
        Task { @MainActor in
            do {
                let plan = try await Task.detached(priority: .utility) { try ImportEngine().scan(request) }.value
                scannedFiles = plan.files.count
                summaryLabel.stringValue = "检测到 \(plan.files.count) 个素材 · \(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))"
                stateLabel.stringValue = plan.files.isEmpty ? "相机中没有可导入的素材" : "\(plan.files.count) 个文件 · \(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))"
                statusItem.button?.title = ""
                writeStatus(.ready, total: plan.files.count, message: stateLabel.stringValue)
                scanning = false
                refreshControls()
                if !plan.files.isEmpty && (startWhenReady || (automatically && settings.autoImport)) { startImport(verification: verification) }
            } catch {
                scanning = false
                stateLabel.stringValue = "扫描失败：\(error.localizedDescription)"
                statusItem.button?.title = " !"
                writeStatus(.failed, message: error.localizedDescription)
                refreshControls()
            }
        }
    }

    private func startImport(verification: ImportRequest.Verification = .quick) {
        guard worker == nil, !scanning, scannedFiles > 0, let request = request(verification: verification) else { return }
        progressBar.doubleValue = 0
        stateLabel.stringValue = "开始导入…"
        let throttle = ProgressThrottle()
        let importID = UUID()
        activeImport = importID
        let controller = self
        let work = Task.detached(priority: .utility) {
            try ImportEngine().run(request, cancelled: { Task.isCancelled }) { event in
                guard throttle.shouldPublish(event) else { return }
                Task { @MainActor in controller.updateProgress(event, importID: importID) }
            }
        }
        worker = work
        writeStatus(.copying)
        refreshControls()
        Task { @MainActor in
            do {
                let result = try await work.value
                activeImport = nil
                if !terminating {
                    stateLabel.stringValue = result.imported > 0 ? "新增 \(result.imported) 个 · 已有 \(result.skipped) 个" : "已核对 \(result.skipped) 个文件"
                    fileLabel.stringValue = ""
                    progressBar.doubleValue = 1
                    statusItem.button?.title = " ✓"
                    writeStatus(.completed, imported: result.imported, skipped: result.skipped)
                    notify("素材已导入", body: stateLabel.stringValue)
                }
            } catch {
                activeImport = nil
                stateLabel.stringValue = "导入未完成：\(error.localizedDescription)"
                statusItem.button?.title = " !"
                writeStatus(.failed, message: error.localizedDescription)
                if !terminating { notify("导入需要处理", body: error.localizedDescription) }
            }
            worker = nil
            refreshControls()
        }
    }

    private func updateProgress(_ event: ImportProgress, importID: UUID) {
        guard activeImport == importID, worker != nil, !terminating else { return }
        stateLabel.stringValue = "\(ImportPresentation.progressLabel(event.phase)) · \(event.finishedFiles)/\(event.totalFiles)"
        fileLabel.stringValue = event.fileName
        progressBar.doubleValue = event.fraction
        statusItem.button?.title = " \(Int(event.fraction * 100))%"
        writeStatus(Self.phase(for: event.phase), finished: event.finishedFiles, total: event.totalFiles)
    }

    @objc private func stopImport() { worker?.cancel() }

    @objc private func openDestination() {
        guard let path = settings.destinationPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func requestNotifications() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    private func notify(_ title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private static func phase(for phase: ImportProgress.Phase) -> ImportPresentation.Phase {
        switch phase {
        case .copying: .copying
        case .verifying: .verifying
        case .checking: .checking
        case .completed: .completed
        }
    }

    private func writeStatus(_ phase: ImportPresentation.Phase, imported: Int = 0, skipped: Int = 0, finished: Int = 0, total: Int = 0, message: String = "") {
        displayPhase = phase
        if phase == .completed && activeImport == nil { lastImported = imported }
        updatePresentation()
        statusRevision += 1
        let revision = statusRevision
        let status = RuntimeStatus(phase: phase.rawValue, imported: imported, skipped: skipped, finished: finished, total: total, message: message, updatedAt: ISO8601DateFormatter().string(from: Date()))
        Task { await RuntimeStore.shared.writeStatus(status, revision: revision) }
    }

    private func updatePresentation() {
        let configured = settings.volumeIdentifier != nil && settings.destinationPath != nil
        let busy = worker != nil
        let presentation = ImportPresentation(ImportPresentation.State(
            phase: displayPhase,
            configured: configured,
            busy: busy,
            scanning: scanning,
            importActive: activeImport != nil,
            cameraConnected: configuredCamera != nil,
            scannedFiles: scannedFiles,
            lastImported: lastImported
        ))
        primaryAction = presentation.primaryAction
        panel.primaryButton.title = presentation.primaryTitle
        panel.primaryButton.symbolName = presentation.primarySymbol?.rawValue
        panel.primaryButton.isEnabled = presentation.primaryEnabled
        panel.present(title: presentation.headline, cameraName: configuredCamera?.name ?? settings.volumeName,
                      connected: configuredCamera != nil, destinationPath: settings.destinationPath,
                      busy: busy, scanning: scanning)
    }
}

private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTime = 0.0
    private var lastPhase: ImportProgress.Phase?
    private var lastFile = ""
    func shouldPublish(_ event: ImportProgress) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date.timeIntervalSinceReferenceDate
        guard event.phase != lastPhase || event.fileName != lastFile || now - lastTime > 0.2 else { return false }
        lastTime = now
        lastPhase = event.phase
        lastFile = event.fileName
        return true
    }
}
