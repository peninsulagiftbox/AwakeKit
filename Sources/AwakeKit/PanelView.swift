import SwiftUI
import AppKit

// MARK: - Panel visibility environment

/// Hover highlights must not outlive the panel: when the window orders out,
/// the pointer's mouse-exited event may never reach the (hidden) SwiftUI
/// views, leaving stale `hovering` state behind. MenuPanelController flips
/// this via the root view so rows render unhighlighted while hidden.
private struct PanelVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var panelVisible: Bool {
        get { self[PanelVisibleKey.self] }
        set { self[PanelVisibleKey.self] = newValue }
    }
}

// MARK: - Panel content

struct AwakeKitPanelView: View {
    @ObservedObject var manager: AwakeKitManager
    /// Kept in sync by MenuPanelController so rows can drop stale hover state.
    var panelIsVisible: Bool = true
    var onSettings: () -> Void
    var onAbout: () -> Void
    var onQuit: () -> Void

    private var hasErrors: Bool {
        manager.activationError != nil || manager.systemSleepPreventionError != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let error = manager.activationError {
                hint(error, color: .red)
            }
            if let error = manager.systemSleepPreventionError {
                hint(error, color: .red)
            }

            StatusCard(manager: manager, onSettings: onSettings)
                .padding(.top, hasErrors ? 8 : 12)

            if manager.isActive, manager.systemSleepPreventionEnabled, !manager.onACPower,
               manager.activationError == nil {
                hint("未接通电源 · 增强防休眠已暂停", color: .secondary)
            }

            Text("选择持续时间")
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, 16)

            DurationGrid(
                options: DurationOption.catalog,
                selected: manager.selectedDuration,
                onSelect: { manager.select($0) }
            )
            .padding(.top, 9)

            divider.padding(.top, 14)

            VStack(spacing: 2) {
                MenuRow(title: "偏好设置", systemImage: "gearshape", action: onSettings)
                MenuRow(title: "关于 AwakeKit", systemImage: "info.circle", action: onAbout)
                MenuRow(title: "退出 AwakeKit", systemImage: "power", action: onQuit)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(width: Metrics.width, alignment: .leading)
        .environment(\.panelVisible, panelIsVisible)
    }

    // MARK: Header — title, tagline, settings gear

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AwakeKit")
                    .font(.system(size: 15, weight: .bold))
                Text("让你的 Mac 保持清醒")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            GearButton(action: onSettings)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }

    private func hint(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .padding(.top, 5)
    }

    /// Precise countdown for the status card: "29:59" / "01:00:00",
    /// ticking every second via the surrounding TimelineView.
    nonisolated static func remainingText(until expiry: Date, from now: Date) -> String {
        let total = max(0, Int(expiry.timeIntervalSince(now).rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%02d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Header gear button

private struct GearButton: View {
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.panelVisible) private var panelVisible

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(
                        hovering && panelVisible
                            ? Color.primary.opacity(0.12)
                            : Color.primary.opacity(0.06)
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("偏好设置")
    }
}

// MARK: - Status card

/// Moon/sun glyph + state line + master switch, with the enhanced-mode
/// entry row docked underneath, all on one rounded card.
private struct StatusCard: View {
    @ObservedObject var manager: AwakeKitManager
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                StatusGlyph(isActive: manager.isActive)

                VStack(alignment: .leading, spacing: 2) {
                    Text(manager.isActive ? "保持唤醒中" : "未保持唤醒")
                        .font(.system(size: 16, weight: .bold))
                    subtitle
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Toggle("", isOn: Binding(
                    get: { manager.isActive },
                    set: { manager.setActive($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("防休眠")
            }

            EnhanceRow(onSettings: onSettings)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder private var subtitle: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if manager.isActive {
                // Brief "已结束" right after the timer auto-expires.
                if let autoOff = manager.autoOffAt,
                   context.date.timeIntervalSince(autoOff) < 3 {
                    Text("已结束")
                        .fontWeight(.semibold)
                } else if let expiry = manager.expiryDate {
                    HStack(spacing: 3) {
                        Text("剩余")
                        Text(AwakeKitPanelView.remainingText(until: expiry, from: context.date))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                } else {
                    Text("一直保持唤醒")
                }
            } else {
                Text("系统可正常休眠")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
}

/// Round gradient badge: blue crescent while dormant, warm yellow sun while
/// keeping the Mac awake.
private struct StatusGlyph: View {
    let isActive: Bool

    var body: some View {
        ZStack {
            Circle().fill(
                LinearGradient(
                    colors: isActive
                        ? [Color(red: 1.00, green: 0.84, blue: 0.33), Color(red: 0.98, green: 0.64, blue: 0.09)]
                        : [Color(red: 0.25, green: 0.44, blue: 0.91), Color(red: 0.07, green: 0.21, blue: 0.62)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            Image(systemName: isActive ? "sun.max.fill" : "moon.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.white)
        }
        .frame(width: 46, height: 46)
    }
}

/// Entry point to the enhanced (AC-only) setting; always navigates to
/// Preferences where the real toggle lives.
private struct EnhanceRow: View {
    let onSettings: () -> Void

    @State private var hovering = false
    @Environment(\.panelVisible) private var panelVisible

    var body: some View {
        Button(action: onSettings) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.10))
                Text("接通电源后可启用增强模式")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primary.opacity(0.85))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        hovering && panelVisible
                            ? Color.primary.opacity(0.10)
                            : Color(nsColor: .controlBackgroundColor)
                    )
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("增强防休眠设置")
    }
}

// MARK: - Duration selector (grid)

/// Finite durations as three pills per row, then one full-width ∞ row.
struct DurationGrid: View {
    let options: [DurationOption]
    let selected: DurationOption
    let onSelect: (DurationOption) -> Void

    private var finite: [DurationOption] { options.filter { !$0.isInfinite } }
    private var infinite: DurationOption? { options.first { $0.isInfinite } }
    /// Finite options laid out three per row.
    private var rows: [[DurationOption]] {
        stride(from: 0, to: finite.count, by: 3).map { start in
            Array(finite[start..<min(start + 3, finite.count)])
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    ForEach(rows[index]) { option in
                        DurationPill(
                            option: option,
                            isSelected: option.id == selected.id,
                            action: { onSelect(option) }
                        )
                    }
                }
            }
            if let infinite {
                DurationPill(
                    option: infinite,
                    isSelected: infinite.id == selected.id,
                    action: { onSelect(infinite) }
                )
            }
        }
    }
}

/// One pill: accent-filled when selected, soft gray otherwise.
struct DurationPill: View {
    let option: DurationOption
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.panelVisible) private var panelVisible

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if option.isInfinite {
                    Image(systemName: "infinity")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(option.label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 10).fill(background))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
    }

    private var background: Color {
        // NSColor.controlAccentColor rather than Color.accentColor: the panel
        // is a borderless non-activating window where SwiftUI's semantic
        // accent fails to resolve, leaving the selected pill invisible.
        if isSelected { return Color(nsColor: .controlAccentColor) }
        if hovering, panelVisible { return Color.primary.opacity(0.10) }
        return Color.primary.opacity(0.06)
    }
}

// MARK: - Standard menu row

/// Light menu row with a subtle hover highlight, matching native popover rows.
struct MenuRow: View {
    let title: String
    var systemImage: String?
    var trailingChevron: Bool
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.panelVisible) private var panelVisible

    init(
        title: String,
        systemImage: String? = nil,
        trailingChevron: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.trailingChevron = trailingChevron
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                Text(title)
                    .font(.system(size: 12.5))
                Spacer(minLength: 0)
                if trailingChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hovering && panelVisible ? Color.primary.opacity(0.07) : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
        .buttonStyle(.plain)
    }
}
