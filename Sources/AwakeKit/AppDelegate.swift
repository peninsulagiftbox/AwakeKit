import AppKit
import Combine
import Darwin

// MARK: - Metrics

enum Metrics {
    static let width: CGFloat = 264
    /// Used only until the first layout pass measures the real fitting size.
    static let initialHeight: CGFloat = 420
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let manager = AwakeKitManager()
    private var panelController: MenuPanelController?
    private var settingsController: SettingsWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var refreshPending = false
    /// Kept open for the process lifetime; closing the handle drops the lock.
    private var instanceLock: FileHandle?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard acquireSingleInstanceLock() else {
            activateExistingInstance()
            NSApp.terminate(self)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()
        setupStatusItem()
        setupPanel()
        observeState()
        autoOpenForDebug()
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.deactivate()
    }

    // MARK: Single instance

    /// flock-based single-instance guard. The kernel drops the lock when the
    /// process dies (even SIGKILL), so there is nothing to clean up, and two
    /// simultaneous launches can no longer both pass a running-app scan.
    /// Bare .build runs have no bundle identifier and skip the lock, so they
    /// can still run beside the packaged app.
    private func acquireSingleInstanceLock() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return true }
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent(bundleID, isDirectory: true) else { return true }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lockURL = dir.appendingPathComponent("instance.lock")
        if !FileManager.default.fileExists(atPath: lockURL.path) {
            FileManager.default.createFile(atPath: lockURL.path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: lockURL.path) else { return true }
        guard flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            try? handle.close()
            return false
        }
        instanceLock = handle
        return true
    }

    private func activateExistingInstance() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first?
            .activate()
    }

    // MARK: Main menu

    /// Accessory apps ship no default menu bar; this one exists for the brief
    /// periods the app is active (e.g. the settings window is focused) and
    /// gives the settings window real Cmd+, / Cmd+W / Cmd+Q handling. Items
    /// with a nil target ride the responder chain (NSApp / key window).
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "AwakeKit")
        appMenuItem.submenu = appMenu

        appMenu.addItem(NSMenuItem(
            title: "关于 AwakeKit",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(.separator())

        let settings = NSMenuItem(title: "设置…", action: #selector(showSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())

        appMenu.addItem(NSMenuItem(
            title: "退出 AwakeKit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(NSMenuItem(
            title: "关闭窗口",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        ))

        NSApp.mainMenu = mainMenu
    }

    @objc private func showSettingsFromMenu() {
        showSettings()
    }

    // MARK: Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = statusIcon(active: false)
            button.action = #selector(togglePanel(_:))
            button.target = self
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        statusItem = item
    }

    /// Colored (non-template) menu-bar glyphs matching the panel's status
    /// card: a blue crescent while dormant, a yellow sun while keeping the
    /// Mac awake. Palette-tinted symbol configurations stay vector-crisp.
    private func statusIcon(active: Bool) -> NSImage? {
        let symbol = active ? "sun.max.fill" : "moon.fill"
        let tint = active
            ? NSColor(srgbRed: 1.0, green: 0.72, blue: 0.10, alpha: 1)
            : NSColor(srgbRed: 0.15, green: 0.45, blue: 0.95, alpha: 1)
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(.init(paletteColors: [tint]))
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "AwakeKit")?
            .withSymbolConfiguration(config)
        image?.isTemplate = false
        return image
    }

    // MARK: Menu panel

    private func setupPanel() {
        let root = AwakeKitPanelView(
            manager: manager,
            onSettings: { [weak self] in
                self?.panelController?.close()
                self?.showSettings()
            },
            onAbout: { [weak self] in
                self?.panelController?.close()
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(nil)
            },
            onQuit: { NSApp.terminate(nil) }
        )
        panelController = MenuPanelController(content: root)
    }

    @objc private func togglePanel(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseDown {
            panelController?.close()
            presentStatusMenu()
            return
        }
        guard let item = statusItem, let panelController else { return }
        panelController.toggle(item)
    }

    // MARK: Right-click menu

    private func presentStatusMenu() {
        guard let button = statusItem?.button else { return }

        let toggle = NSMenuItem(
            title: manager.isActive ? "关闭防休眠" : "开启防休眠",
            action: #selector(toggleActiveFromMenu),
            keyEquivalent: ""
        )
        toggle.target = self

        let quit = NSMenuItem(
            title: "退出 AwakeKit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp

        let menu = NSMenu()
        menu.addItem(toggle)
        menu.addItem(.separator())
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func toggleActiveFromMenu() {
        manager.setActive(!manager.isActive)
    }

    // MARK: State

    private func observeState() {
        manager.objectWillChange
            .sink { [weak self] in self?.scheduleRefresh() }
            .store(in: &cancellables)
    }

    /// Published values and SwiftUI layout settle on the next run-loop pass.
    /// Coalesce a state transition's multiple notifications into one refresh.
    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            self.statusItem?.button?.image = self.statusIcon(active: self.manager.isActive)
            self.panelController?.updateSize()
        }
    }

    private func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(manager: manager)
        }
        settingsController?.show()
    }

    // MARK: Debug harness

    /// Scripted-screenshot entry points: `AwakeKit --debug-open-panel` or
    /// `--debug-open-settings` auto-open the UI shortly after launch.
    private func autoOpenForDebug() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--debug-open-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, let item = self.statusItem else { return }
                self.panelController?.show(item)
            }
        }
        if arguments.contains("--debug-open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showSettings()
            }
        }
    }
}
