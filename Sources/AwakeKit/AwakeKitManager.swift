import Foundation
import Combine
import IOKit.pwr_mgt
import UserNotifications
import os

// MARK: - Duration model

enum DurationUnit: String, Codable, Sendable {
    case infinite
    case minute
    case hour
}

/// One selectable duration. `seconds == nil` means "no auto-off" (∞).
struct DurationOption: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let label: String
    let seconds: TimeInterval?
    let unit: DurationUnit

    var isInfinite: Bool { seconds == nil }

    /// Structured catalog, in the order the selector renders:
    /// 15/30/45 分钟 │ 1/4/8 小时 │ 一直保持.
    static let catalog: [DurationOption] = [
        DurationOption(id: "m15",      label: "15 分钟", seconds: 15 * 60,  unit: .minute),
        DurationOption(id: "m30",      label: "30 分钟", seconds: 30 * 60,  unit: .minute),
        DurationOption(id: "m45",      label: "45 分钟", seconds: 45 * 60,  unit: .minute),
        DurationOption(id: "h01",      label: "1 小时",  seconds: 1 * 3600, unit: .hour),
        DurationOption(id: "h04",      label: "4 小时",  seconds: 4 * 3600, unit: .hour),
        DurationOption(id: "h08",      label: "8 小时",  seconds: 8 * 3600, unit: .hour),
        DurationOption(id: "infinite", label: "一直保持", seconds: nil,     unit: .infinite),
    ]

    static var infinite: DurationOption { catalog.last! }
    /// Preselected duration when nothing (valid) is persisted.
    static var standard: DurationOption { catalog.first { $0.id == "m30" }! }
}

// MARK: - Status notifications

/// Posts the optional "keeping awake started/stopped" notifications. The
/// first post also requests authorization, so the whole feature sits behind
/// a single system prompt.
enum StatusNotifier {
    static func post(title: String, body: String) {
        // UNUserNotificationCenter needs a real bundle; bare .build runs skip.
        guard Bundle.main.bundleIdentifier != nil else { return }
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}

// MARK: - Manager

/// Injectable IOKit boundary so lifecycle tests do not alter machine sleep state.
@MainActor
struct PowerAssertions {
    var create: (CFString, String) -> IOPMAssertionID?
    var release: (IOPMAssertionID) -> Void

    static let live = PowerAssertions(
        create: { type, reason in
            var id: IOPMAssertionID = 0
            let status = IOPMAssertionCreateWithName(
                type, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id
            )
            return status == kIOReturnSuccess ? id : nil
        },
        release: { _ = IOPMAssertionRelease($0) }
    )
}

/// Owns the power assertion and the countdown. UI observes this object only;
/// it never touches IOKit or `caffeinate` directly.
@MainActor
final class AwakeKitManager: ObservableObject {
    @Published private(set) var isActive: Bool = false
    @Published private(set) var selectedDuration: DurationOption
    /// When non-nil the view renders a live countdown via `TimelineView`.
    @Published private(set) var expiryDate: Date?
    /// When the countdown last expired on its own, so the view can flash a
    /// brief "已结束" hint. Only ever set by the auto-off timer.
    @Published private(set) var autoOffAt: Date?
    /// Set when activation failed on every path; the panel shows it as a red
    /// hint row. Cleared at the start of the next activation attempt.
    @Published private(set) var activationError: String?

    /// Extra AC-only system-sleep assertion; it does not guarantee closed-lid operation.
    @Published private(set) var systemSleepPreventionEnabled: Bool
    /// Last known power state: true on AC power (desktops always report AC).
    @Published private(set) var onACPower: Bool
    /// Indicates assertion ownership, not a guarantee that macOS will honor it.
    @Published private(set) var systemSleepPreventionActive = false
    @Published private(set) var systemSleepPreventionError: String?
    /// Post a user notification when keeping awake starts or stops.
    @Published private(set) var statusNotificationsEnabled: Bool

    static let selectedDurationDefaultsKey = "selectedDurationID"
    static let statusNotificationsDefaultsKey = "showStatusNotifications"
    /// Keep the legacy key so existing preferences survive the corrected label.
    static let systemSleepPreventionDefaultsKey = "lidKeepAwakeEnabled"

    private let logger = Logger(subsystem: "com.local.awakekit", category: "manager")

    private var assertionID: IOPMAssertionID = 0
    private var systemAssertionID: IOPMAssertionID = 0
    private let assertions: PowerAssertions
    private let defaults: UserDefaults
    private let readACPower: () -> Bool
    private let makeProcess: () -> Process
    private let postNotification: (String, String) -> Void
    private let monitorsPowerChanges: Bool
    /// IOPS notification run-loop source, installed on first activation.
    private var powerSourceSource: CFRunLoopSource?
    private var caffeinateProcess: Process?

    init(
        defaults: UserDefaults = .standard,
        assertions: PowerAssertions = .live,
        readACPower: @escaping () -> Bool = { PowerSource.isOnACPower },
        makeProcess: @escaping () -> Process = { Process() },
        monitorsPowerChanges: Bool = true,
        postNotification: @escaping (String, String) -> Void = StatusNotifier.post
    ) {
        self.defaults = defaults
        self.assertions = assertions
        self.readACPower = readACPower
        self.makeProcess = makeProcess
        self.postNotification = postNotification
        self.monitorsPowerChanges = monitorsPowerChanges
        systemSleepPreventionEnabled = defaults.bool(forKey: Self.systemSleepPreventionDefaultsKey)
        onACPower = readACPower()
        let savedID = defaults.string(forKey: Self.selectedDurationDefaultsKey)
        selectedDuration = DurationOption.catalog.first { $0.id == savedID } ?? .standard
        statusNotificationsEnabled = defaults.object(forKey: Self.statusNotificationsDefaultsKey) as? Bool ?? true
    }

    isolated deinit {
        if let source = powerSourceSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            CFRunLoopSourceInvalidate(source)
        }
        deactivate()
    }

    /// Retain stopped children until reaped, separately from the active session.
    private var stoppingProcesses: [ObjectIdentifier: Process] = [:]
    private var expiryTimer: Timer?

    // MARK: Toggle

    func setActive(_ active: Bool) {
        active ? activate() : deactivate()
    }

    func activate() {
        guard !isActive else { return }
        activationError = nil

        installPowerSourceMonitoring()
        onACPower = readACPower()

        assertionID = assertions.create(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            "AwakeKit: keeping the Mac awake"
        ) ?? 0
        if assertionID == 0 {
            guard startCaffeinate() else {
                activationError = "防休眠开启失败，请稍后重试"
                logger.error("activation failed: IOKit assertion and caffeinate both unavailable")
                return
            }
            logger.warning("IOKit assertion failed, using caffeinate fallback")
        }

        isActive = true
        autoOffAt = nil
        logger.info("active, duration=\(self.selectedDuration.label, privacy: .public)")
        restartCountdown()
        updateSystemAssertion()
        if statusNotificationsEnabled {
            let detail = selectedDuration.isInfinite ? "一直保持" : selectedDuration.label
            postNotification("AwakeKit", "已开始保持唤醒 · \(detail)")
        }
    }

    func deactivate() {
        guard isActive || assertionID != 0 || systemAssertionID != 0 || caffeinateProcess != nil else { return }
        let wasActive = isActive

        if assertionID != 0 {
            assertions.release(assertionID)
            assertionID = 0
        }
        if let process = caffeinateProcess {
            caffeinateProcess = nil
            stoppingProcesses[ObjectIdentifier(process)] = process
            if process.isRunning { process.terminate() }
        }

        cancelCountdown()
        isActive = false
        updateSystemAssertion()
        if wasActive, statusNotificationsEnabled {
            postNotification("AwakeKit", "已停止保持唤醒，系统可正常休眠")
        }
        logger.info("inactive")
    }

    // MARK: Extra system-sleep assertion (AC power only)

    /// Same request as caffeinate -s. macOS controls whether it is honored;
    /// neither an assertion ID nor AC power establishes closed-lid support.
    func setSystemSleepPreventionEnabled(_ enabled: Bool) {
        guard enabled != systemSleepPreventionEnabled else { return }
        systemSleepPreventionEnabled = enabled
        defaults.set(enabled, forKey: Self.systemSleepPreventionDefaultsKey)
        updateSystemAssertion()
        logger.info("extra system-sleep prevention: \(enabled, privacy: .public)")
    }

    func setStatusNotificationsEnabled(_ enabled: Bool) {
        guard enabled != statusNotificationsEnabled else { return }
        statusNotificationsEnabled = enabled
        defaults.set(enabled, forKey: Self.statusNotificationsDefaultsKey)
    }

    func handlePowerSourceChange() {
        onACPower = readACPower()
        updateSystemAssertion()
    }

    /// Installs the IOPS notification source once; it fires on every power
    /// source change for the rest of the process lifetime, keeping the extra
    /// assertion in sync (battery → release, AC → re-create).
    private func installPowerSourceMonitoring() {
        guard monitorsPowerChanges, powerSourceSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource(
            { context in
                guard let context else { return }
                // This source is registered exclusively on the main run loop.
                MainActor.assumeIsolated {
                    Unmanaged<AwakeKitManager>.fromOpaque(context)
                        .takeUnretainedValue().handlePowerSourceChange()
                }
            },
            context
        )?.takeRetainedValue() else {
            logger.warning("power source monitoring unavailable")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSourceSource = source
    }

    private func updateSystemAssertion() {
        let wanted = isActive && systemSleepPreventionEnabled && onACPower
        systemSleepPreventionError = nil
        if wanted, systemAssertionID == 0 {
            if let newID = assertions.create(
                kIOPMAssertionTypePreventSystemSleep as CFString,
                "AwakeKit: requesting extra system-sleep prevention on AC power"
            ) {
                systemAssertionID = newID
                logger.info("extra system-sleep assertion created")
            } else {
                systemSleepPreventionError = "额外防休眠请求失败，基础防闲置睡眠仍开启"
                logger.warning("PreventSystemSleep assertion failed")
            }
        } else if !wanted, systemAssertionID != 0 {
            assertions.release(systemAssertionID)
            systemAssertionID = 0
            logger.info("extra system-sleep assertion released")
        }
        systemSleepPreventionActive = systemAssertionID != 0
    }

    // MARK: Duration

    /// Records the selected duration; while active it re-plans the countdown.
    /// Selecting while inactive only records the choice — the master toggle
    /// in the status card is what starts a session.
    func select(_ option: DurationOption) {
        guard option.id != selectedDuration.id else { return }
        selectedDuration = option
        defaults.set(option.id, forKey: Self.selectedDurationDefaultsKey)
        if isActive {
            restartCountdown()
        }
    }

    // MARK: Countdown

    private func cancelCountdown() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        expiryDate = nil
    }

    private func restartCountdown() {
        cancelCountdown()
        guard let seconds = selectedDuration.seconds else { return }

        expiryDate = Date().addingTimeInterval(seconds)
        // The timer is scheduled on RunLoop.main, so the closure always runs
        // on the main thread and may assume MainActor isolation.
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.autoOffAt = Date()
                self?.deactivate()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    // MARK: Power assertion

    private func startCaffeinate() -> Bool {
        let process = makeProcess()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -w <our pid>: if this app dies without cleanup (force quit, crash),
        // caffeinate exits on its own instead of orphaning the assertion.
        // The extra AC-only assertion is owned exclusively by this manager.
        // Never duplicate it via -s: settings/power changes must release it.
        process.arguments = ["-d", "-i", "-m", "-w", "\(ProcessInfo.processInfo.processIdentifier)"]
        // Only Sendable values (the process identity and its already-recorded
        // exit status) may cross into the MainActor task; capturing the
        // Process itself would fail under strict concurrency checking.
        process.terminationHandler = { [weak self] terminated in
            let identity = ObjectIdentifier(terminated)
            let status = terminated.terminationStatus
            Task { @MainActor in
                self?.handleCaffeinateTermination(matching: identity, status: status)
            }
        }
        do {
            try process.run()
            caffeinateProcess = process
            return true
        } catch {
            logger.error("caffeinate failed to start: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func handleCaffeinateTermination(matching identity: ObjectIdentifier, status: Int32) {
        if stoppingProcesses.removeValue(forKey: identity) != nil { return }
        guard let current = caffeinateProcess, ObjectIdentifier(current) == identity else { return }
        caffeinateProcess = nil
        // Caffeinate died on its own — the Mac is no longer being kept awake,
        // so sync state and UI instead of showing a stale "active".
        logger.warning("caffeinate exited unexpectedly (status \(status))")
        deactivate()
        activationError = "防休眠辅助进程已退出，请重新开启"
    }
}
