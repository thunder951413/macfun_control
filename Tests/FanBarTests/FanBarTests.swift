import FanBarHardware
import Foundation
import Testing

@testable import FanBar

final class MockFanHardware: FanHardware, @unchecked Sendable {
  var isOpen = false
  var count = 2
  var temperature = 70.0
  var actual = [3_000.0, 3_200.0]
  var minimum = [1_800.0, 2_000.0]
  var maximum = [6_500.0, 6_800.0]
  var modes = [UInt8](repeating: 0, count: 2)
  var targets = [Double](repeating: 0, count: 2)
  var failTargetFan: Int?
  var failAutomaticFan: Int?
  var resetCount = 0
  var automaticWriteCount = 0
  var overrideActive = false
  var sensorReadings: [TemperatureReading] = []
  var hotspotReading = TemperatureReading(key: "TCMz", value: 70)
  var power: PowerReading?

  func open() throws { isOpen = true }
  func close() { isOpen = false }
  func fanCount() throws -> Int { count }
  func cpuTemperature() throws -> Double { temperature }
  func cpuHotspotReading() throws -> TemperatureReading { hotspotReading }
  func allTemperatureReadings() -> [TemperatureReading] { sensorReadings }
  func powerReading() -> PowerReading? { power }
  func fanActualRPM(fan index: Int) throws -> Double { actual[index] }
  func fanMinimumRPM(fan index: Int) throws -> Double { minimum[index] }
  func fanMaximumRPM(fan index: Int) throws -> Double { maximum[index] }
  func fanMode(fan index: Int) throws -> UInt8 { modes[index] }
  func setManualMode(fan index: Int) throws { modes[index] = 1 }
  func setTargetRPM(_ rpm: Double, fan index: Int) throws {
    if failTargetFan == index { throw TestError.injected }
    targets[index] = rpm
  }
  func setAutomaticMode(fan index: Int) throws {
    if failAutomaticFan == index { throw TestError.injected }
    automaticWriteCount += 1
    modes[index] = 0
  }
  func controlOverrideActive() throws -> Bool { overrideActive }
  func resetControlOverride() throws {
    resetCount += 1
    overrideActive = false
  }

  enum TestError: Error { case injected }
}

@Suite("Fan safety policy")
struct FanSafetyPolicyTests {
  private let policy = FanSafetyPolicy()

  @Test("manual control never reduces existing speed")
  func neverReducesExistingSpeed() throws {
    let fan = FanReading(index: 0, actualRPM: 5_000, minimumRPM: 1_800, maximumRPM: 6_500)
    let snapshot = FanSnapshot(temperature: 69, fans: [fan])
    let decision = policy.decision(for: snapshot, threshold: 68, wasManual: false)
    let targets = try #require(manualTargets(decision))
    #expect(abs(targets[0] - 5_000) < 0.01)
  }

  @Test("90°C requests maximum fan speed")
  func emergencyRequestsMaximumSpeed() throws {
    let fan = FanReading(index: 0, actualRPM: 2_000, minimumRPM: 1_800, maximumRPM: 6_500)
    let decision = policy.decision(
      for: FanSnapshot(temperature: 90, fans: [fan]), threshold: 68, wasManual: false
    )
    #expect(try #require(manualTargets(decision)) == [6_500])
  }

  @Test("hysteresis prevents mode chatter")
  func hysteresisPreventsModeChatter() {
    let fan = FanReading(index: 0, actualRPM: 2_000, minimumRPM: 1_800, maximumRPM: 6_500)
    #expect(
      policy.decision(
        for: .init(temperature: 67, fans: [fan]),
        threshold: 68, wasManual: false) == .automatic)
    #expect(
      manualTargets(
        policy.decision(
          for: .init(temperature: 67, fans: [fan]),
          threshold: 68, wasManual: true)) != nil)
    #expect(
      policy.decision(
        for: .init(temperature: 65, fans: [fan]),
        threshold: 68, wasManual: true) == .automatic)
  }

  @Test("threshold is clamped to safe range")
  func thresholdClampsToSafeRange() {
    let fan = FanReading(index: 0, actualRPM: 2_000, minimumRPM: 1_800, maximumRPM: 6_500)
    let decision = policy.decision(
      for: .init(temperature: 81, fans: [fan]),
      threshold: 120, wasManual: false)
    #expect(manualTargets(decision) != nil)
    #expect(FanSafetyPolicy.thresholdRange.lowerBound == 40)
    #expect(
      manualTargets(
        policy.decision(
          for: .init(temperature: 41, fans: [fan]), threshold: 20, wasManual: false)) != nil)
  }

  private func manualTargets(_ decision: FanSafetyPolicy.Decision) -> [Double]? {
    guard case .manual(let targets) = decision else { return nil }
    return targets
  }

  @Test("temperature filter rejects a single transient spike")
  func temperatureFilterRejectsSpike() {
    var filter = TemperatureSafetyFilter(capacity: 3)
    #expect(filter.record(78) == 78)
    #expect(filter.record(54) == 78)
    #expect(filter.record(53) == 54)
    #expect(filter.record(52) == 53)
  }

  @Test("unselected hotspot does not override a cool control temperature")
  func unselectedHotspotDoesNotControl() {
    let fan = FanReading(index: 0, actualRPM: 2_000, minimumRPM: 1_800, maximumRPM: 6_500)
    let decision = policy.decision(
      for: FanSnapshot(temperature: 53, hotspotTemperature: 110, fans: [fan]),
      threshold: 68, wasManual: false)
    #expect(decision == .automatic)
  }

  @Test("slew limiter raises faster than it lowers")
  func asymmetricSlewLimiter() {
    let limiter = FanTargetSlewLimiter()
    let fan = FanReading(index: 0, actualRPM: 2_000, minimumRPM: 1_500, maximumRPM: 6_000)
    #expect(
      limiter.limit(
        desired: [5_000], previous: [3_000], fans: [fan], interval: 2, bypass: false)
        == [3_500])
    #expect(
      limiter.limit(
        desired: [2_000], previous: [3_000], fans: [fan], interval: 2, bypass: false)
        == [2_800])
  }

  @Test("emergency bypasses slew limiting")
  func emergencyBypassesSlewLimiter() {
    let limiter = FanTargetSlewLimiter()
    let fan = FanReading(index: 0, actualRPM: 2_000, minimumRPM: 1_500, maximumRPM: 6_000)
    #expect(
      limiter.limit(
        desired: [6_000], previous: [2_000], fans: [fan], interval: 2, bypass: true)
        == [6_000])
  }

  @Test("curve preview maps threshold to zero and 90°C to maximum")
  func curvePreviewFractions() {
    #expect(policy.curveFraction(temperature: 40, threshold: 40) == nil)
    #expect(policy.curveFraction(temperature: 50, threshold: 40) == 0.2)
    #expect(policy.curveFraction(temperature: 68, threshold: 68) == nil)
    #expect(policy.curveFraction(temperature: 79, threshold: 68) == 0.5)
    #expect(policy.curveFraction(temperature: 90, threshold: 68) == 1)
    #expect(policy.curveFraction(temperature: 100, threshold: 68) == 1)
  }

  @Test("acceleration factor reshapes the curve smoothly without moving endpoints")
  func accelerationFactorReshapesCurve() throws {
    #expect(FanAccelerationProfile.clamp(0.1) == 0.5)
    #expect(FanAccelerationProfile.clamp(3) == 2)
    #expect(FanAccelerationProfile.adjustedFraction(0, factor: 2) == 0)
    #expect(FanAccelerationProfile.adjustedFraction(1, factor: 0.5) == 1)

    let gentle = try #require(
      policy.curveFraction(temperature: 79, threshold: 68, accelerationFactor: 0.5))
    let standard = try #require(
      policy.curveFraction(temperature: 79, threshold: 68, accelerationFactor: 1))
    let strong = try #require(
      policy.curveFraction(temperature: 79, threshold: 68, accelerationFactor: 2))
    #expect(gentle == 0.25)
    #expect(standard == 0.5)
    #expect(abs(strong * strong - 0.5) < 0.000_001)
  }

  @Test("acceleration factor changes targets while the slew limiter remains authoritative")
  func accelerationFactorStillUsesSlewLimiter() throws {
    let fan = FanReading(index: 0, actualRPM: 2_000, minimumRPM: 1_500, maximumRPM: 6_000)
    let snapshot = FanSnapshot(temperature: 79, fans: [fan])
    let desired = try #require(
      manualTargets(
        policy.decision(
          for: snapshot, threshold: 68, wasManual: false, accelerationFactor: 2)))
    #expect(desired[0] > 4_500)
    let limited = FanTargetSlewLimiter().limit(
      desired: desired, previous: [2_000], fans: [fan], interval: 2, bypass: false)
    #expect(limited == [2_500])
  }

  @Test("battery curve starts at its threshold and reaches maximum at 50°C")
  func batteryCurve() throws {
    let batteryPolicy = BatteryFanPolicy()
    let fan = FanReading(index: 0, actualRPM: 1_500, minimumRPM: 1_500, maximumRPM: 5_500)
    #expect(batteryPolicy.curveFraction(temperature: 38, threshold: 38) == nil)
    #expect(batteryPolicy.curveFraction(temperature: 44, threshold: 38) == 0.5)
    #expect(batteryPolicy.curveFraction(temperature: 50, threshold: 38) == 1)
    let targets = try #require(
      manualTargets(
        batteryPolicy.decision(
          temperature: 44, fans: [fan], threshold: 38, wasManual: false)))
    #expect(targets == [3_500])
  }
}

@Suite("Menu bar display preferences")
struct MenuBarDisplayModeTests {
  @Test("all display choices persist through their raw values")
  func rawValuesRoundTrip() {
    for mode in MenuBarDisplayMode.allCases {
      #expect(MenuBarDisplayMode(rawValue: mode.rawValue) == mode)
      #expect(!mode.label.isEmpty)
    }
  }

  @Test("menu bar fan icon fills only while FanBar owns acceleration")
  func fanIconReflectsControlState() {
    #expect(FanController.ControlState.manual.menuBarSymbolName == "fan.fill")
    #expect(FanController.ControlState.automatic.menuBarSymbolName == "fan")
    #expect(FanController.ControlState.monitoring.menuBarSymbolName == "fan")
    #expect(FanController.ControlState.error.menuBarSymbolName == "fan")
    #expect(
      MenuBarPresentation.symbolName(state: .manual, hasControllableFans: false)
        == "thermometer.medium")
  }

  @Test("fanless devices only offer temperature menu bar modes")
  func fanlessMenuModes() {
    #expect(MenuBarDisplayMode.available(hasControllableFans: false) == [.iconOnly, .temperature])
    #expect(MenuBarDisplayMode.available(hasControllableFans: true) == MenuBarDisplayMode.allCases)
  }

  @Test("controller enters monitoring-only mode when hardware has no fans")
  @MainActor
  func fanlessControllerMode() async {
    let hardware = MockFanHardware()
    hardware.count = 0
    hardware.sensorReadings = [TemperatureReading(key: "TB0T", value: 34)]
    let controller = FanController(
      service: FanService(hardware: hardware), pollInterval: 3_600)

    await controller.refresh()

    #expect(controller.isFanless)
    #expect(!controller.hasControllableFans)
    #expect(controller.state == .monitoring)
    #expect(controller.menuBarSymbolName == "thermometer.medium")
    #expect(controller.availableMenuBarDisplayModes == [.iconOnly, .temperature])
    #expect(controller.statusText.contains("仅监控") || controller.statusText.contains("监控温度"))
    _ = await controller.shutdown()
  }

  @Test("popover height adapts to tab and sensor rows")
  func popoverHeightAdapts() {
    #expect(PopoverTab.sensors.preferredHeight(sensorGroupCount: 2) == 600)
    #expect(
      PopoverTab.sensors.preferredHeight(sensorGroupCount: 7)
        > PopoverTab.sensors.preferredHeight(sensorGroupCount: 2))
    #expect(PopoverTab.sensors.preferredHeight(sensorGroupCount: 7) == 722)
    #expect(PopoverTab.sensors.preferredHeight(sensorGroupCount: 100) == 780)
    #expect(
      PopoverTab.sensors.preferredHeight(
        sensorGroupCount: 2, hasControllableFans: false) == 590)
    #expect(PopoverTab.settings.preferredHeight(sensorGroupCount: 0) == 620)
    #expect(
      PopoverTab.settings.preferredHeight(sensorGroupCount: 0, hasControllableFans: false) == 500)
    #expect(PopoverSizing.height(preferred: 628, visibleScreenHeight: 900) == 628)
    #expect(PopoverSizing.height(preferred: 700, visibleScreenHeight: 600) == 568)
    #expect(PopoverSizing.height(preferred: 628, visibleScreenHeight: nil) == 628)
  }

  @Test("hotspot menu alert appears only above 90°C and includes its source")
  func hotspotMenuAlertThreshold() {
    #expect(HotspotMenuAlert.text(temperature: 90, source: "TCMz") == nil)
    #expect(
      HotspotMenuAlert.text(temperature: 90.6, source: "TCMz")
        == "🌡 CPU 芯片最高热点 91°")
    #expect(HotspotMenuAlert.text(temperature: 95, source: nil) == "🌡 CPU 最高热点 95°")
    #expect(
      HotspotMenuAlert.text(temperature: 96, source: "TXYZ")
        == "🌡 温度传感器（TXYZ） 96°")
  }

  @Test("login item service statuses map to clear settings states")
  @MainActor
  func loginItemStatusMapping() {
    #expect(LaunchAtLoginManager.state(for: .notRegistered) == .disabled)
    #expect(LaunchAtLoginManager.state(for: .enabled) == .enabled)
    #expect(LaunchAtLoginManager.state(for: .requiresApproval) == .approvalRequired)
    #expect(LaunchAtLoginManager.state(for: .notFound) == .unavailable)
  }

  @Test("battery menu alert uses the configured threshold")
  func batteryMenuAlertThreshold() {
    #expect(BatteryMenuAlert.text(temperature: 40, threshold: 40) == nil)
    #expect(
      BatteryMenuAlert.text(temperature: 40.6, threshold: 40)
        == "🔋 电池区域 41°")
  }

  @Test("power connection notice replaces menu bar content only on a new connection")
  @MainActor
  func powerConnectionNoticeTransition() async {
    let hardware = MockFanHardware()
    hardware.count = 0
    hardware.power = PowerReading(
      isExternalPowerConnected: false, inputCapacityWatts: nil, systemPowerWatts: 24.5)
    let controller = FanController(
      service: FanService(hardware: hardware), pollInterval: 3_600)

    await controller.refresh()
    #expect(controller.menuBarPowerConnectionText == nil)
    #expect(controller.systemPowerText == "24.5 W")

    hardware.power = PowerReading(
      isExternalPowerConnected: true, inputCapacityWatts: 67.8, systemPowerWatts: 31.2)
    await controller.refresh()

    #expect(controller.menuBarPowerConnectionText == "67.8 W")
    #expect(controller.menuBarText == "67.8 W")
    #expect(controller.menuBarSymbolName == "powerplug.fill")
    #expect(controller.menuBarHotspotAlertText == nil)
    #expect(controller.inputCapacityText == "67.8 W")
    _ = await controller.shutdown()
  }

  @Test("power connection notice lasts two seconds without alerting at initial launch")
  func powerConnectionNoticeTiming() {
    let start = Date(timeIntervalSince1970: 100)
    #expect(PowerConnectionNotice.duration == 2)
    #expect(!PowerConnectionNotice.didConnect(previous: nil, current: true))
    #expect(PowerConnectionNotice.didConnect(previous: false, current: true))
    #expect(!PowerConnectionNotice.didConnect(previous: true, current: true))
    #expect(PowerConnectionNotice.isVisible(until: start.addingTimeInterval(2), now: start))
    #expect(
      !PowerConnectionNotice.isVisible(
        until: start.addingTimeInterval(2), now: start.addingTimeInterval(2)))
  }
}

@Suite("CPU temperature selection")
struct CPUTemperatureSelectionTests {
  @Test("power telemetry converts live milliwatts and suppresses input on battery")
  func powerTelemetryParsing() throws {
    let connected = try #require(
      PowerTelemetryParser.parse(properties: [
        "ExternalConnected": true,
        "AdapterDetails": ["Watts": 96],
        "PowerDistribution": ["IPDWattageOverride": 140_000],
        "PowerTelemetryData": [
          "SystemPowerIn": 67_890,
          "SystemLoad": 31_250,
        ],
      ]))
    #expect(connected.isExternalPowerConnected)
    #expect(connected.inputCapacityWatts == 96)
    #expect(connected.systemPowerWatts == 31.25)

    let negotiatedFallback = try #require(
      PowerTelemetryParser.parse(properties: [
        "ExternalConnected": true,
        "PowerDistribution": ["IPDWattageOverride": 140_000],
        "PowerTelemetryData": ["SystemLoad": 40_000],
      ]))
    #expect(negotiatedFallback.inputCapacityWatts == 140)

    let battery = try #require(
      PowerTelemetryParser.parse(properties: [
        "ExternalConnected": false,
        "PowerTelemetryData": [
          "SystemPowerIn": 99_000,
          "SystemLoad": 54_277,
        ],
      ]))
    #expect(!battery.isExternalPowerConnected)
    #expect(battery.inputCapacityWatts == nil)
    #expect(battery.systemPowerWatts == 54.277)
  }

  @Test("robust average trims extreme sensor outliers")
  func robustAverageTrimsOutliers() throws {
    let values = [0.0] + Array(repeating: 50.0, count: 8) + [100.0]
    #expect(try #require(SMCClient.robustAverage(values)) == 50)
  }

  @Test("sensor dashboard filters invalid readings and groups known families")
  func sensorGroups() throws {
    let readings = [
      TemperatureReading(key: "TCMz", value: 82),
      TemperatureReading(key: "Tg04", value: 55),
      TemperatureReading(key: "TB0T", value: 33),
      TemperatureReading(key: "TMVR", value: 48),
      TemperatureReading(key: "Tf46", value: 90),
      TemperatureReading(key: "Ta00", value: 0),
    ]
    let groups = TemperatureSensorGroup.make(from: readings)
    #expect(groups.flatMap(\.readings).count == 4)
    #expect(groups.first { $0.category == .cpu }?.maximum == 82)
    #expect(groups.first { $0.category == .gpu }?.average == 55)
    #expect(groups.first { $0.category == .battery }?.average == 33)
    #expect(!groups.flatMap(\.readings).contains { $0.key == "Tf46" })
  }
}

@Suite("Fan service transactions", .serialized)
struct FanServiceTests {
  @Test("zero-fan hardware remains available for temperature monitoring")
  func fanlessHardwareCanMonitor() async throws {
    let hardware = MockFanHardware()
    hardware.count = 0
    hardware.sensorReadings = [TemperatureReading(key: "TB0T", value: 34)]
    hardware.power = PowerReading(
      isExternalPowerConnected: false, inputCapacityWatts: nil, systemPowerWatts: 22)
    let service = FanService(hardware: hardware)
    let snapshot = try await service.prepare()
    #expect(snapshot.fans.isEmpty)
    #expect(snapshot.temperature == hardware.temperature)
    #expect(snapshot.batteryTemperature == 34)
    #expect(snapshot.power?.systemPowerWatts == 22)

    try await service.restoreAutomatic()
    #expect(hardware.automaticWriteCount == 0)
    #expect(hardware.resetCount == 0)
  }

  @Test("sampling uses the hottest valid battery-area sensor")
  func samplesHottestBatterySensor() async throws {
    let hardware = MockFanHardware()
    hardware.sensorReadings = [
      TemperatureReading(key: "TB0T", value: 33),
      TemperatureReading(key: "TB1T", value: 37),
      TemperatureReading(key: "TB2T", value: 35),
      TemperatureReading(key: "TCMz", value: 80),
    ]
    let snapshot = try await FanService(hardware: hardware).prepare()
    #expect(snapshot.batteryTemperature == 37)
    #expect(snapshot.batterySource == "TB1T")
  }

  @Test("partial multi-fan failure rolls back every fan")
  func partialFailureRollsBackEveryFan() async throws {
    let hardware = MockFanHardware()
    hardware.failTargetFan = 1
    let service = FanService(hardware: hardware)
    let snapshot = try await service.prepare()

    await #expect(throws: MockFanHardware.TestError.self) {
      try await service.apply(targets: [4_000, 4_100], snapshot: snapshot)
    }
    let manual = await service.isManual()
    #expect(hardware.modes == [0, 0])
    #expect(hardware.resetCount == 0)
    #expect(!manual)
  }

  @Test("invalid hardware RPM range is rejected")
  func invalidRangeIsRejected() async {
    let hardware = MockFanHardware()
    hardware.maximum[0] = hardware.minimum[0]
    let service = FanService(hardware: hardware)

    await #expect(throws: FanServiceError.invalidFanRange(0)) {
      _ = try await service.prepare()
    }
  }

  @Test("automatic restore failure remains visible in service state")
  func restoreFailureIsRetained() async throws {
    let hardware = MockFanHardware()
    let service = FanService(hardware: hardware)
    let snapshot = try await service.prepare()
    try await service.apply(targets: [4_000, 4_100], snapshot: snapshot)
    hardware.failAutomaticFan = 1

    await #expect(throws: FanServiceError.self) {
      try await service.restoreAutomatic()
    }
    let manual = await service.isManual()
    #expect(manual)
  }

  @Test("controller shutdown returns every fan to macOS automatic control")
  @MainActor
  func controllerShutdownRestoresAutomaticControl() async throws {
    let hardware = MockFanHardware()
    let service = FanService(hardware: hardware)
    let snapshot = try await service.prepare()
    try await service.apply(targets: [4_000, 4_100], snapshot: snapshot)
    hardware.overrideActive = true
    let controller = FanController(service: service, pollInterval: 3_600)

    let restored = await controller.shutdown()

    #expect(restored)
    #expect(hardware.modes == [0, 0])
    #expect(!hardware.overrideActive)
    #expect(hardware.resetCount == 1)
    #expect(controller.targetRPMs.isEmpty)
  }

  @Test("recovery restore opens hardware after a previous crash")
  func recoveryRestoreOpensHardware() async throws {
    let hardware = MockFanHardware()
    hardware.modes = [1, 1]
    hardware.overrideActive = true
    let service = FanService(hardware: hardware)

    try await service.restoreAutomatic()

    #expect(hardware.isOpen)
    #expect(hardware.modes == [0, 0])
    #expect(hardware.resetCount == 1)
  }

  @Test("restore does not write when macOS already owns the fans")
  func automaticStateNeedsNoWrites() async throws {
    let hardware = MockFanHardware()
    hardware.modes = [3, 3]
    let service = FanService(hardware: hardware)

    try await service.restoreAutomatic()

    #expect(hardware.automaticWriteCount == 0)
    #expect(hardware.resetCount == 0)
  }
}

@Suite("AppleSMC ABI")
struct SMCABILayoutTests {
  @Test("parameter structure matches the 80-byte kernel ABI")
  func structureMatchesKernelABI() {
    let layout = SMCClient.abiLayout
    #expect(layout.stride == 80)
    #expect(layout.result == 40)
    #expect(layout.data32 == 44)
    #expect(layout.bytes == 48)
  }
}
