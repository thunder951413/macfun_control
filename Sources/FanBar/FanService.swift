import FanBarHardware
import Foundation

enum FanServiceError: LocalizedError, Equatable {
  case invalidFanCount(Int)
  case invalidFanRange(Int)
  case targetCountMismatch
  case automaticRestoreFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidFanCount(let count): "Invalid fan count reported by SMC: \(count)"
    case .invalidFanRange(let index): "Invalid RPM range for fan \(index + 1)"
    case .targetCountMismatch: "Fan target count does not match detected hardware"
    case .automaticRestoreFailed(let details):
      "Could not fully restore automatic control: \(details)"
    }
  }
}

actor FanService {
  private let hardware: any FanHardware
  private var count = 0
  private var manualFans = Set<Int>()

  init(hardware: any FanHardware = RoutedFanHardware()) {
    self.hardware = hardware
  }

  func prepare(source: CPUTemperatureSource = .package) throws -> FanSnapshot {
    if !hardware.isOpen { try hardware.open() }
    count = try hardware.fanCount()
    guard (0...8).contains(count) else { throw FanServiceError.invalidFanCount(count) }
    return try sample(source: source)
  }

  func sample(source: CPUTemperatureSource = .package) throws -> FanSnapshot {
    guard hardware.isOpen else { return try prepare(source: source) }
    let hotspotReading = try? hardware.cpuHotspotReading()
    let batteryReading = try? hardware.batteryTemperatureReading()
    let powerReading = hardware.powerReading()
    let temperature =
      if source == .hotspot, let hotspotReading {
        hotspotReading.value
      } else {
        try hardware.cpuTemperature(source: source)
      }
    let hotspot = hotspotReading?.value
    guard temperature.isFinite, (0...125).contains(temperature) else {
      throw SMCClient.SMCError.invalidValue("CPU temperature")
    }

    var fans: [FanReading] = []
    for index in 0..<count {
      let actual = try hardware.fanActualRPM(fan: index)
      let reportedTarget = try hardware.fanTargetRPM(fan: index)
      let minimum = try hardware.fanMinimumRPM(fan: index)
      let maximum = try hardware.fanMaximumRPM(fan: index)
      guard actual.isFinite, minimum.isFinite, maximum.isFinite,
        minimum >= 0, maximum > minimum, maximum <= 20_000,
        actual >= 0, actual <= 20_000,
        reportedTarget.isFinite, reportedTarget >= 0, reportedTarget <= 20_000
      else {
        throw FanServiceError.invalidFanRange(index)
      }
      fans.append(
        FanReading(
          index: index, actualRPM: actual,
          reportedTargetRPM: reportedTarget,
          minimumRPM: minimum, maximumRPM: maximum))
    }
    return FanSnapshot(
      temperature: temperature, hotspotTemperature: hotspot,
      hotspotSource: hotspotReading?.key, batteryTemperature: batteryReading?.value,
      batterySource: batteryReading?.key, power: powerReading, fans: fans)
  }

  func temperatureDashboard() throws -> TemperatureDashboard {
    if !hardware.isOpen { try hardware.open() }
    let package = try? hardware.cpuTemperature(source: .package)
    let coreAverage = try? hardware.cpuTemperature(source: .coreAverage)
    let hotspot = try? hardware.cpuTemperature(source: .hotspot)
    let readings = hardware.allTemperatureReadings()
    return TemperatureDashboard(
      package: package, coreAverage: coreAverage, hotspot: hotspot, readings: readings)
  }

  func batteryChargeLimitState() throws -> BatteryChargeLimitState {
    if !hardware.isOpen { try hardware.open() }
    return hardware.batteryChargeLimitState()
  }

  func setBatteryChargeLimit(enabled: Bool, upperPercent: Int) throws {
    if !hardware.isOpen { try hardware.open() }
    try hardware.setBatteryChargeLimit(enabled: enabled, upperPercent: upperPercent)
  }

  func observeAutomaticDemand(
    source: CPUTemperatureSource = .package, observationCount: Int = 4,
    interval: Duration = .milliseconds(200)
  ) async throws -> FanSnapshot {
    let count = max(1, observationCount)
    var observations: [FanSnapshot] = []
    observations.reserveCapacity(count)
    for index in 0..<count {
      if index > 0 { try await Task.sleep(for: interval) }
      observations.append(try sample(source: source))
    }

    guard let latest = observations.last else { return try sample(source: source) }
    let fans = latest.fans.map { fan in
      let systemTarget = observations.compactMap { observation in
        observation.fans.first(where: { $0.index == fan.index })?.reportedTargetRPM
      }.max()
      return FanReading(
        index: fan.index, actualRPM: fan.actualRPM,
        reportedTargetRPM: systemTarget,
        minimumRPM: fan.minimumRPM, maximumRPM: fan.maximumRPM)
    }
    return FanSnapshot(
      temperature: latest.temperature, hotspotTemperature: latest.hotspotTemperature,
      hotspotSource: latest.hotspotSource, batteryTemperature: latest.batteryTemperature,
      batterySource: latest.batterySource, power: latest.power, fans: fans)
  }

  func apply(targets: [Double], snapshot: FanSnapshot) throws {
    guard targets.count == count, snapshot.fans.count == count else {
      throw FanServiceError.targetCountMismatch
    }

    do {
      for index in 0..<count {
        let fan = snapshot.fans[index]
        let target = min(fan.maximumRPM, max(fan.minimumRPM, targets[index]))
        if !manualFans.contains(index) {
          try hardware.setManualMode(fan: index)
          manualFans.insert(index)
        }
        try hardware.setTargetRPM(target, fan: index)
      }
    } catch {
      // A partial multi-fan transition is unsafe. Roll back every fan,
      // including fans whose local state was not updated yet.
      try? restoreAutomatic()
      throw error
    }
  }

  func restoreAutomatic() throws {
    if !hardware.isOpen {
      try hardware.open()
      count = try hardware.fanCount()
      guard (0...8).contains(count) else { throw FanServiceError.invalidFanCount(count) }
    }

    if count == 0 {
      manualFans.removeAll()
      return
    }

    var failures: [String] = []
    for index in 0..<count {
      do {
        let mode = try hardware.fanMode(fan: index)
        if mode != 0, mode != 3 {
          try hardware.setAutomaticMode(fan: index)
        }
      } catch {
        failures.append("fan \(index + 1): \(error.localizedDescription)")
      }
    }
    do {
      if try hardware.controlOverrideActive() {
        try hardware.resetControlOverride()
      }
    } catch {
      failures.append("override: \(error.localizedDescription)")
    }

    if failures.isEmpty {
      let deadline = Date().addingTimeInterval(8)
      var pending = Array(0..<count)
      repeat {
        pending = pending.filter { index in
          guard let mode = try? hardware.fanMode(fan: index) else { return true }
          return mode != 0 && mode != 3
        }
        if !pending.isEmpty { Thread.sleep(forTimeInterval: 0.2) }
      } while !pending.isEmpty && Date() < deadline
      if !pending.isEmpty {
        failures.append("fans still manual after restore: \(pending.map { $0 + 1 })")
      }
    }

    if failures.isEmpty {
      manualFans.removeAll()
    } else {
      throw FanServiceError.automaticRestoreFailed(failures.joined(separator: "; "))
    }
  }

  func isManual() -> Bool { !manualFans.isEmpty }

  func isAutomaticControlActive() throws -> Bool {
    guard hardware.isOpen else { return false }
    for index in 0..<count {
      let mode = try hardware.fanMode(fan: index)
      if mode != 0, mode != 3 { return false }
    }
    return try !hardware.controlOverrideActive()
  }

  func close() {
    hardware.close()
    count = 0
    manualFans.removeAll()
  }
}
