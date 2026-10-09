import Foundation
import Testing
import IOKit.pwr_mgt
@testable import AwakeKit

// MARK: - Countdown formatting

@Test(arguments: [
    (TimeInterval(-42), "00:00"),          // clamped, never negative
    (0.0, "00:00"),
    (0.4, "00:00"),
    (0.6, "00:01"),                        // rounds to the nearest second
    (59.4, "00:59"),
    (59.6, "01:00"),
    (60.0, "01:00"),
    (609.6, "10:10"),
    (3599.4, "59:59"),
    (3600.0, "01:00:00"),                  // hours are zero-padded too
    (3660.6, "01:01:01"),
    (45296.0, "12:34:56"),
])
func remainingTextFormatsIntervals(interval: TimeInterval, expected: String) {
    let now = Date(timeIntervalSinceReferenceDate: 0)
    #expect(AwakeKitPanelView.remainingText(until: now.addingTimeInterval(interval), from: now) == expected)
}

// MARK: - Duration catalog invariants

@Test func catalogHasExpectedShape() {
    #expect(DurationOption.catalog.count == 7)
    #expect(DurationOption.catalog.filter { $0.unit == .infinite }.count == 1)
    #expect(DurationOption.catalog.filter { $0.unit == .minute }.count == 3)
    #expect(DurationOption.catalog.filter { $0.unit == .hour }.count == 3)
}

@Test func catalogHasUniqueIDs() {
    let ids = DurationOption.catalog.map(\.id)
    #expect(ids.count == Set(ids).count)
}

@Test func catalogEndsWithInfiniteOption() {
    let last = DurationOption.catalog.last
    #expect(last?.isInfinite == true)
    #expect(last?.seconds == nil)
    #expect(DurationOption.infinite.id == "infinite")
}

@Test func catalogLabelsMatchSeconds() {
    for option in DurationOption.catalog where !option.isInfinite {
        let parts = option.label.split(separator: " ")
        #expect(parts.count == 2)
        let value = Int(parts[0])!
        let expected: TimeInterval = option.unit == .minute
            ? TimeInterval(value * 60)
            : TimeInterval(value * 3600)
        #expect(option.seconds == expected)
    }
    #expect(DurationOption.catalog.first { $0.isInfinite }?.label == "一直保持")
}

@Test func catalogMinutesAndHoursAreAscending() {
    let minutes = DurationOption.catalog.filter { $0.unit == .minute }.map { $0.seconds! }
    let hours = DurationOption.catalog.filter { $0.unit == .hour }.map { $0.seconds! }
    #expect(minutes == minutes.sorted())
    #expect(hours == hours.sorted())
}

// MARK: - Selection persistence

@MainActor @Test
func defaultSelectionIsThirtyMinutesWhenNothingPersisted() {
    let fixture = ManagerFixture()
    defer { fixture.cleanup() }
    #expect(fixture.manager.selectedDuration.id == "m30")
    // The status-notification toggle ships enabled (matching the design).
    #expect(fixture.manager.statusNotificationsEnabled)
}

@MainActor @Test
func selectionPersistsAndRestores() {
    let fixture = ManagerFixture()
    defer { fixture.cleanup() }
    let fourHours = DurationOption.catalog.first { $0.id == "h04" }!
    fixture.manager.select(fourHours)
    #expect(fixture.defaults.string(forKey: AwakeKitManager.selectedDurationDefaultsKey) == "h04")

    let reloaded = fixture.makeManager()
    #expect(reloaded.selectedDuration.id == "h04")
}

@MainActor @Test
func invalidPersistedSelectionFallsBackToDefault() {
    let fixture = ManagerFixture()
    defer { fixture.cleanup() }
    fixture.defaults.set("h12-removed", forKey: AwakeKitManager.selectedDurationDefaultsKey)
    #expect(fixture.makeManager().selectedDuration.id == "m30")
}

@MainActor @Test
func selectingWhileInactiveOnlyRecordsChoice() {
    let fixture = ManagerFixture()
    defer { fixture.cleanup() }
    let fortyFive = DurationOption.catalog.first { $0.id == "m45" }!
    fixture.manager.select(fortyFive)
    #expect(!fixture.manager.isActive)
    #expect(fixture.held.isEmpty)
    #expect(fixture.manager.expiryDate == nil)
    #expect(fixture.manager.selectedDuration.id == "m45")
    #expect(fixture.notifications.isEmpty)
}

// MARK: - Power and assertion lifecycle (no real power assertions or children)

@Test(arguments: [
    (Optional("AC Power"), true), // Also covers a desktop with no battery inventory.
    (Optional("Battery Power"), false),
    (Optional("UPS Power"), false),
    (Optional("Unknown"), false),
    (nil, false),
])
func providingSourceDeterminesAC(source: String?, expected: Bool) {
    #expect(PowerSource.isACPowerSource(source) == expected)
}

/// Test-only process: all access and simulated exit callbacks originate on MainActor.
private final class StubProcess: Process, @unchecked Sendable {
    private var simulatedRunning = false
    private var status: Int32 = 0
    private var stubURL: URL?
    private var stubArguments: [String]?
    private var stubHandler: (@Sendable (Process) -> Void)?
    var failsToStart = false
    override var executableURL: URL? {
        get { stubURL }
        set { stubURL = newValue }
    }
    override var arguments: [String]? {
        get { stubArguments }
        set { stubArguments = newValue }
    }
    override var terminationHandler: (@Sendable (Process) -> Void)? {
        get { stubHandler }
        set { stubHandler = newValue }
    }
    var terminateCount = 0
    override var isRunning: Bool { simulatedRunning }
    override var terminationStatus: Int32 { status }
    override func run() throws {
        if failsToStart { throw CocoaError(.executableNotLoadable) }
        simulatedRunning = true
    }
    override func terminate() { terminateCount += 1 }
    func finish(status: Int32 = 0) {
        simulatedRunning = false
        self.status = status
        terminationHandler?(self)
    }
}

@MainActor
private final class ManagerFixture {
    let suite = "AwakeKitTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    var onAC = true
    var failDisplay = false
    var failSystem = false
    var failProcess = false
    var nextID: IOPMAssertionID = 0
    var held: [IOPMAssertionID: String] = [:]
    var processes: [StubProcess] = []
    var notifications: [(title: String, body: String)] = []
    var manager: AwakeKitManager!

    init(monitorsPowerChanges: Bool = false) {
        defaults = UserDefaults(suiteName: suite)!
        // Verify compatibility with the existing preference key.
        defaults.set(true, forKey: "lidKeepAwakeEnabled")
        manager = makeManager(monitorsPowerChanges: monitorsPowerChanges)
    }

    func makeManager(monitorsPowerChanges: Bool = false) -> AwakeKitManager {
        AwakeKitManager(
            defaults: defaults,
            assertions: PowerAssertions(
                create: { [unowned self] type, _ in
                    let type = type as String
                    if failDisplay && type == kIOPMAssertionTypePreventUserIdleDisplaySleep as String { return nil }
                    if failSystem && type == kIOPMAssertionTypePreventSystemSleep as String { return nil }
                    nextID += 1
                    held[nextID] = type
                    return nextID
                },
                release: { [unowned self] id in
                    #expect(held.removeValue(forKey: id) != nil)
                }
            ),
            readACPower: { [unowned self] in onAC },
            makeProcess: { [unowned self] in
                let process = StubProcess()
                process.failsToStart = failProcess
                processes.append(process)
                return process
            },
            monitorsPowerChanges: monitorsPowerChanges,
            postNotification: { [unowned self] title, body in
                notifications.append((title, body))
            }
        )
    }

    var systemCount: Int {
        held.values.filter { $0 == kIOPMAssertionTypePreventSystemSleep as String }.count
    }

    func cleanup() {
        manager?.deactivate()
        for process in processes where process.isRunning { process.finish() }
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor @Test(arguments: [false, true])
func settingAndPowerChangesReleaseExtraAssertion(fallback: Bool) {
    let fixture = ManagerFixture()
    defer { fixture.cleanup() }
    fixture.failDisplay = fallback
    let manager = fixture.manager!
    #expect(manager.systemSleepPreventionEnabled)
    #expect(fixture.held.isEmpty) // Saved setting alone never activates an assertion.
    manager.activate()
    #expect(manager.isActive)
    #expect(manager.systemSleepPreventionActive)
    #expect(fixture.systemCount == 1)

    manager.setSystemSleepPreventionEnabled(false)
    #expect(!manager.systemSleepPreventionActive)
    #expect(fixture.systemCount == 0)
    #expect(manager.isActive)
    #expect(!fixture.defaults.bool(forKey: "lidKeepAwakeEnabled"))

    manager.setSystemSleepPreventionEnabled(true)
    fixture.onAC = false
    manager.handlePowerSourceChange()
    #expect(!manager.onACPower)
    #expect(fixture.systemCount == 0)
    #expect(!manager.systemSleepPreventionActive)
    #expect(manager.isActive)

    fixture.onAC = true
    manager.handlePowerSourceChange()
    manager.handlePowerSourceChange() // Repeated notification must not duplicate ownership.
    #expect(fixture.systemCount == 1)
    if fallback {
        #expect(fixture.processes.count == 1)
        #expect(fixture.processes[0].arguments == ["-d", "-i", "-m", "-w", "\(ProcessInfo.processInfo.processIdentifier)"])
        #expect(fixture.processes[0].terminateCount == 0)
    }
    manager.deactivate()
    #expect(fixture.held.isEmpty)
    #expect(!manager.isActive)
}

@MainActor @Test
func failedExtraAssertionIsVisibleWithoutDisablingBasicPrevention() {
    let fixture = ManagerFixture()
    defer { fixture.cleanup() }
    fixture.failSystem = true
    fixture.manager.activate()
    #expect(fixture.manager.isActive)
    #expect(!fixture.manager.systemSleepPreventionActive)
    #expect(fixture.manager.systemSleepPreventionError != nil)
    fixture.manager.setSystemSleepPreventionEnabled(false)
    #expect(fixture.manager.systemSleepPreventionError == nil)
}

@MainActor @Test
func oldFallbackExitCannotDisableNewSession() async {
    let fixture = ManagerFixture()
    defer { fixture.cleanup() }
    fixture.failDisplay = true
    fixture.manager.activate()
    let oldProcess = fixture.processes[0]
    fixture.manager.deactivate()
    fixture.manager.activate()
    #expect(fixture.processes.count == 2)
    oldProcess.finish()
    // Exit handling is enqueued on MainActor by the production callback.
    try? await Task.sleep(for: .milliseconds(20))
    #expect(fixture.manager.isActive)
    #expect(fixture.manager.activationError == nil)
    #expect(fixture.systemCount == 1)

    fixture.processes[1].finish(status: 1)
    try? await Task.sleep(for: .milliseconds(20))
    #expect(!fixture.manager.isActive)
    #expect(fixture.held.isEmpty)
    #expect(fixture.manager.activationError != nil)
}

@MainActor @Test
func managerDestructionReleasesAssertionsAndMonitoring() {
    let fixture = ManagerFixture(monitorsPowerChanges: true)
    defer { fixture.cleanup() }
    fixture.manager.activate()
    #expect(fixture.held.count == 2)
    weak let manager = fixture.manager
    fixture.manager = nil
    #expect(manager == nil)
    #expect(fixture.held.isEmpty)
}

@MainActor @Test
func activationFailureCanBeRetried() {
    let fixture = ManagerFixture()
    defer { fixture.cleanup() }
    fixture.failDisplay = true
    fixture.failProcess = true
    fixture.manager.activate()
    #expect(!fixture.manager.isActive)
    #expect(fixture.manager.activationError != nil)
    #expect(fixture.held.isEmpty)
    #expect(fixture.manager.expiryDate == nil)
    fixture.failProcess = false
    fixture.manager.activate()
    #expect(fixture.manager.isActive)
    #expect(fixture.manager.activationError == nil)
}

@MainActor @Test
func changingDurationWhileActiveReplansCountdown() async throws {
    let fixture = ManagerFixture()
    defer { fixture.cleanup() }
    let manager = fixture.manager!
    let short = DurationOption(id: "test-short", label: "1 分钟", seconds: 0.05, unit: .minute)
    manager.select(short)
    manager.activate()
    #expect(manager.expiryDate != nil)
    manager.select(.infinite)
    #expect(manager.expiryDate == nil)
    try await Task.sleep(for: .milliseconds(100))
    #expect(manager.isActive)
    #expect(manager.autoOffAt == nil)

    manager.select(short)
    #expect(manager.expiryDate != nil)
    let timeout = Date().addingTimeInterval(2)
    while manager.isActive && Date() < timeout {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!manager.isActive)
    #expect(manager.autoOffAt != nil)
    #expect(manager.expiryDate == nil)
    #expect(fixture.held.isEmpty)
}

// MARK: - Status notifications

@MainActor @Test
func notificationsPostOnTransitionsWhenEnabled() {
    let fixture = ManagerFixture()
    defer { fixture.cleanup() }
    // Default selection is 30 分钟, so the start notification names it.
    fixture.manager.activate()
    #expect(fixture.notifications.count == 1)
    #expect(fixture.notifications[0].title == "AwakeKit")
    #expect(fixture.notifications[0].body.contains("30 分钟"))

    fixture.manager.deactivate()
    #expect(fixture.notifications.count == 2)
    #expect(fixture.notifications[1].body.contains("已停止"))

    fixture.manager.activate()
    #expect(fixture.notifications.count == 3)
}

@MainActor @Test
func notificationsStaySilentWhenDisabled() {
    let fixture = ManagerFixture()
    defer { fixture.cleanup() }
    fixture.manager.setStatusNotificationsEnabled(false)
    #expect(fixture.manager.statusNotificationsEnabled == false)
    #expect(fixture.defaults.bool(forKey: AwakeKitManager.statusNotificationsDefaultsKey) == false)

    fixture.manager.activate()
    fixture.manager.deactivate()
    #expect(fixture.notifications.isEmpty)

    fixture.manager.setStatusNotificationsEnabled(true)
    fixture.manager.activate()
    #expect(fixture.notifications.count == 1)
}

@MainActor @Test
func infiniteStartNotificationSaysForever() {
    let fixture = ManagerFixture()
    defer { fixture.cleanup() }
    fixture.manager.select(.infinite)
    fixture.manager.activate()
    #expect(fixture.notifications.count == 1)
    #expect(fixture.notifications[0].body.contains("一直保持"))
}
