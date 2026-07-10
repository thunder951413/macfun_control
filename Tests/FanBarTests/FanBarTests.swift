import FanBarHardware
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

  func open() throws { isOpen = true }
  func close() { isOpen = false }
  func fanCount() throws -> Int { count }
  func cpuTemperature() throws -> Double { temperature }
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

  @Test("hotspot emergency overrides a cool package temperature")
  func hotspotEmergencyOverridesPackage() throws {
    let fan = FanReading(index: 0, actualRPM: 2_000, minimumRPM: 1_800, maximumRPM: 6_500)
    let decision = policy.decision(
      for: FanSnapshot(temperature: 53, hotspotTemperature: 101, fans: [fan]),
      threshold: 68, wasManual: false)
    #expect(try #require(manualTargets(decision)) == [6_500])
  }

  @Test("curve preview maps threshold to zero and 90°C to maximum")
  func curvePreviewFractions() {
    #expect(policy.curveFraction(temperature: 68, threshold: 68) == nil)
    #expect(policy.curveFraction(temperature: 79, threshold: 68) == 0.5)
    #expect(policy.curveFraction(temperature: 90, threshold: 68) == 1)
    #expect(policy.curveFraction(temperature: 100, threshold: 68) == 1)
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
}

@Suite("CPU temperature selection")
struct CPUTemperatureSelectionTests {
  @Test("robust average trims extreme sensor outliers")
  func robustAverageTrimsOutliers() throws {
    let values = [0.0] + Array(repeating: 50.0, count: 8) + [100.0]
    #expect(try #require(SMCClient.robustAverage(values)) == 50)
  }
}

@Suite("Fan service transactions", .serialized)
struct FanServiceTests {
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
