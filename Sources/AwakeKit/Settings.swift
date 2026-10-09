import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Settings window

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let manager: AwakeKitManager

    init(manager: AwakeKitManager) {
        self.manager = manager
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: AwakeKitSettingsView(manager: manager))
        let created = NSWindow(contentViewController: hosting)
        created.title = "AwakeKit 设置"
        created.styleMask = [.titled, .closable]
        created.isReleasedWhenClosed = false
        created.center()
        window = created

        created.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Settings

struct AwakeKitSettingsView: View {
    @ObservedObject var manager: AwakeKitManager
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    /// SMAppService can only register a real .app bundle; a bare executable
    /// straight out of `.build` cannot be a login item.
    private var runningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCard(
                icon: SettingsIcon(systemName: "bolt.fill", tint: Color(red: 1.0, green: 0.72, blue: 0.10)),
                title: "增强防休眠（仅接通电源）",
                description: "接通电源后启用更强的防休眠保护，防止系统因长时间无操作而进入睡眠；使用电池供电时不会启用。",
                error: manager.systemSleepPreventionError
            ) {
                Toggle("", isOn: Binding(
                    get: { manager.systemSleepPreventionEnabled },
                    set: { manager.setSystemSleepPreventionEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("增强防休眠")
            }

            SettingsCard(
                icon: SettingsIcon(systemName: "power", tint: Color(red: 0.10, green: 0.45, blue: 0.95)),
                title: "登录时启动",
                description: "在系统登录后自动启动 AwakeKit。",
                footnote: runningFromAppBundle
                    ? nil
                    : "当前以裸可执行文件运行，登录时启动需要通过 AwakeKit.app 启动后开启。",
                error: launchAtLoginError
            ) {
                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: launchAtLogin) { enabled in
                        // The toggle also fires for rollback assignments below;
                        // don't re-run (and clobber errorMessage) for a no-op.
                        guard enabled != LaunchAtLogin.isEnabled else { return }
                        do {
                            try LaunchAtLogin.setEnabled(enabled)
                            launchAtLoginError = nil
                        } catch {
                            launchAtLoginError = error.localizedDescription
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                    .accessibilityLabel("登录时启动")
            }

            SettingsCard(
                icon: SettingsIcon(systemName: "clock.fill", tint: Color(red: 0.13, green: 0.69, blue: 0.35)),
                title: "默认持续时间",
                description: "打开菜单时默认选择的持续时间。"
            ) {
                Picker("", selection: Binding(
                    get: { manager.selectedDuration.id },
                    set: { id in
                        if let option = DurationOption.catalog.first(where: { $0.id == id }) {
                            manager.select(option)
                        }
                    }
                )) {
                    ForEach(DurationOption.catalog) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 120)
                .accessibilityLabel("默认持续时间")
            }

            SettingsCard(
                icon: SettingsIcon(systemName: "bell.fill", tint: Color(red: 0.90, green: 0.26, blue: 0.26)),
                title: "显示状态通知",
                description: "在开始或停止保持唤醒时显示系统通知。"
            ) {
                Toggle("", isOn: Binding(
                    get: { manager.statusNotificationsEnabled },
                    set: { manager.setStatusNotificationsEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("显示状态通知")
            }

            Text("关于")
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 4)
                .padding(.top, 4)

            AboutCard()
        }
        .padding(16)
        .frame(width: 420, alignment: .leading)
        .onAppear {
            // The settings windows outlive their open/close cycles, so
            // re-sync the toggle with the real registration state each time.
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    @State private var launchAtLoginError: String?
}

// MARK: - Card building blocks

/// One settings row: tinted icon tile, title with a trailing control, and a
/// description aligned under the title, on a floating white card.
private struct SettingsCard<Control: View>: View {
    let icon: SettingsIcon
    let title: String
    let description: String
    var footnote: String?
    var error: String?
    var control: Control

    init(
        icon: SettingsIcon,
        title: String,
        description: String,
        footnote: String? = nil,
        error: String? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.icon = icon
        self.title = title
        self.description = description
        self.footnote = footnote
        self.error = error
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                icon
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                control
            }
            Text(description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, 42)
            if let footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 42)
            }
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.leading, 42)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
            .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }
}

/// Rounded icon tile whose glyph and background share one tint.
private struct SettingsIcon: View {
    let systemName: String
    let tint: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.14)))
    }
}

/// The "关于" card: app icon, name, version, tagline; clicking opens the
/// standard About panel.
private struct AboutCard: View {
    @State private var hovering = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    var body: some View {
        Button {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        } label: {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AwakeKit")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.primary)
                    Text("版本 \(version)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("一款简单高效的防休眠工具，让你的 Mac 保持清醒。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(cardBackground)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关于 AwakeKit")
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(hovering ? 0.12 : 0.06))
            )
            .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }
}

// MARK: - Launch at login

/// Registers the app as a login item via SMAppService (macOS 13+), which owns
/// the underlying LaunchServices bookkeeping — no hand-written plist.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status == .requiresApproval {
                throw LaunchAtLoginError.requiresApproval
            }
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    enum LaunchAtLoginError: LocalizedError {
        case requiresApproval

        var errorDescription: String? {
            switch self {
            case .requiresApproval:
                return "需要先在 系统设置 → 通用 → 登录项与扩展 中允许 AwakeKit。"
            }
        }
    }
}
