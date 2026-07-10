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
    guard (1...8).contains(count) else { throw FanServiceError.invalidFanCount(count) }
    return try sample(source: source)
  }

  func sample(source: CPUTemperatureSource = .package) throws -> FanSnapshot {
    guard hardware.isOpen else { return try prepare(source: source) }
    let temperature = try hardware.cpuTemperature(source: source)
    let hotspot =
      source == .hotspot ? temperature : try? hardware.cpuTemperature(source: .hotspot)
    guard temperature.isFinite, (0...125).contains(temperature) else {
      throw SMCClient.SMCError.invalidValue("CPU temperature")
    }

    var fans: [FanReading] = []
    for index in 0..<count {
      let actual = try hardware.fanActualRPM(fan: index)
      let minimum = try hardware.fanMinimumRPM(fan: index)
      let maximum = try hardware.fanMaximumRPM(fan: index)
      guard actual.isFinite, minimum.isFinite, maximum.isFinite,
        minimum >= 0, maximum > minimum, maximum <= 20_000,
        actual >= 0, actual <= 20_000
      else {
        throw FanServiceError.invalidFanRange(index)
      }
      fans.append(
        FanReading(
          index: index, actualRPM: actual,
          minimumRPM: minimum, maximumRPM: maximum))
    }
    return FanSnapshot(temperature: temperature, hotspotTemperature: hotspot, fans: fans)
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
      guard (1...8).contains(count) else { throw FanServiceError.invalidFanCount(count) }
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

  func close() {
    hardware.close()
    count = 0
    manualFans.removeAll()
  }
}
