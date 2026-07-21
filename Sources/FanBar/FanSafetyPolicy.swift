import FanBarHardware
import Foundation

enum FanAccelerationProfile {
  static let range = 0.5...2.0
  static let defaultFactor = 1.0

  static func clamp(_ factor: Double) -> Double {
    min(max(factor, range.lowerBound), range.upperBound)
  }

  static func adjustedFraction(_ fraction: Double, factor: Double) -> Double {
    let fraction = min(max(fraction, 0), 1)
    guard fraction > 0, fraction < 1 else { return fraction }
    return pow(fraction, 1 / clamp(factor))
  }
}

struct FanReading: Sendable, Equatable, Identifiable {
  let index: Int
  let actualRPM: Double
  let reportedTargetRPM: Double?
  let minimumRPM: Double
  let maximumRPM: Double

  var id: Int { index }

  init(
    index: Int, actualRPM: Double, reportedTargetRPM: Double? = nil, minimumRPM: Double,
    maximumRPM: Double
  ) {
    self.index = index
    self.actualRPM = actualRPM
    self.reportedTargetRPM = reportedTargetRPM
    self.minimumRPM = minimumRPM
    self.maximumRPM = maximumRPM
  }

  var activeTargetFloor: Double {
    max(actualRPM, reportedTargetRPM ?? actualRPM)
  }
}

enum ManualControlSafety {
  static let systemDemandAuditInterval: TimeInterval = 10

  static func shouldAudit(startedAt: Date?, now: Date = Date()) -> Bool {
    guard let startedAt else { return false }
    return now.timeIntervalSince(startedAt) >= systemDemandAuditInterval
  }
}

struct FanSnapshot: Sendable, Equatable {
  let temperature: Double
  let hotspotTemperature: Double?
  let hotspotSource: String?
  let batteryTemperature: Double?
  let batterySource: String?
  let power: PowerReading?
  let fans: [FanReading]

  init(
    temperature: Double, hotspotTemperature: Double? = nil, hotspotSource: String? = nil,
    batteryTemperature: Double? = nil, batterySource: String? = nil, power: PowerReading? = nil,
    fans: [FanReading]
  ) {
    self.temperature = temperature
    self.hotspotTemperature = hotspotTemperature
    self.hotspotSource = hotspotSource
    self.batteryTemperature = batteryTemperature
    self.batterySource = batterySource
    self.power = power
    self.fans = fans
  }
}

struct BatteryFanPolicy: Sendable {
  static let thresholdRange = 30.0...45.0
  static let defaultThreshold = 38.0
  static let maximumTemperature = 50.0

  let hysteresis: Double

  init(hysteresis: Double = 2) {
    self.hysteresis = hysteresis
  }

  func curveFraction(
    temperature: Double, threshold: Double,
    accelerationFactor: Double = FanAccelerationProfile.defaultFactor
  ) -> Double? {
    let threshold = min(
      max(threshold, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound)
    guard temperature > threshold else { return nil }
    let fraction = min(
      1, max(0, (temperature - threshold) / (Self.maximumTemperature - threshold)))
    return FanAccelerationProfile.adjustedFraction(fraction, factor: accelerationFactor)
  }

  func decision(
    temperature: Double?, fans: [FanReading], threshold: Double, wasManual: Bool,
    accelerationFactor: Double = FanAccelerationProfile.defaultFactor
  ) -> FanSafetyPolicy.Decision {
    guard let temperature, temperature.isFinite, (10...80).contains(temperature) else {
      return .automatic
    }
    let threshold = min(
      max(threshold, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound)
    let shouldBeManual =
      wasManual ? temperature > threshold - hysteresis : temperature > threshold
    guard shouldBeManual else { return .automatic }

    let curveTargets = fans.map { fan in
      guard
        let progress = curveFraction(
          temperature: temperature, threshold: threshold,
          accelerationFactor: accelerationFactor)
      else {
        return fan.activeTargetFloor
      }
      let curveTarget = fan.minimumRPM + (fan.maximumRPM - fan.minimumRPM) * progress
      return min(fan.maximumRPM, max(fan.activeTargetFloor, curveTarget))
    }
    guard wasManual || zip(curveTargets, fans).contains(where: { $0 > $1.activeTargetFloor })
    else { return .automatic }
    return .manual(curveTargets)
  }
}

struct TemperatureSafetyFilter: Sendable {
  private let capacity: Int
  private var samples: [Double] = []

  init(capacity: Int = 5) {
    self.capacity = max(1, capacity)
  }

  mutating func record(_ temperature: Double) -> Double {
    samples.append(temperature)
    if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    let sorted = samples.sorted()
    return sorted[sorted.count / 2]
  }

  mutating func reset() { samples.removeAll() }
}

struct FanTargetSlewLimiter: Sendable {
  let increaseRPMPerSecond: Double
  let decreaseRPMPerSecond: Double

  init(increaseRPMPerSecond: Double = 250, decreaseRPMPerSecond: Double = 100) {
    self.increaseRPMPerSecond = max(0, increaseRPMPerSecond)
    self.decreaseRPMPerSecond = max(0, decreaseRPMPerSecond)
  }

  func limit(
    desired: [Double], previous: [Double], fans: [FanReading], interval: TimeInterval,
    bypass: Bool
  ) -> [Double] {
    guard desired.count == fans.count else { return desired }
    if bypass { return zip(desired, fans).map { min($1.maximumRPM, $0) } }

    let seconds = max(0, interval)
    return desired.enumerated().map { index, desiredTarget in
      let fan = fans[index]
      let baseline = max(
        fan.activeTargetFloor,
        previous.indices.contains(index) ? previous[index] : fan.activeTargetFloor)
      let limited =
        desiredTarget >= baseline
        ? min(desiredTarget, baseline + increaseRPMPerSecond * seconds)
        : max(desiredTarget, baseline - decreaseRPMPerSecond * seconds)
      return min(fan.maximumRPM, max(fan.activeTargetFloor, max(fan.minimumRPM, limited)))
    }
  }
}

struct FanSafetyPolicy: Sendable {
  static let thresholdRange = 40.0...80.0
  static let defaultThreshold = 68.0

  let hysteresis: Double
  let emergencyTemperature: Double

  init(hysteresis: Double = 3, emergencyTemperature: Double = 90) {
    self.hysteresis = hysteresis
    self.emergencyTemperature = emergencyTemperature
  }

  enum Decision: Equatable {
    case automatic
    case manual([Double])
  }

  func isEmergency(_ snapshot: FanSnapshot) -> Bool {
    snapshot.temperature >= emergencyTemperature
  }

  func curveFraction(
    temperature: Double, threshold: Double,
    accelerationFactor: Double = FanAccelerationProfile.defaultFactor
  ) -> Double? {
    let threshold = min(
      max(threshold, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound)
    guard temperature > threshold else { return nil }
    let span = max(1, emergencyTemperature - threshold)
    let fraction = min(1, max(0, (temperature - threshold) / span))
    return FanAccelerationProfile.adjustedFraction(fraction, factor: accelerationFactor)
  }

  func decision(
    for snapshot: FanSnapshot, threshold: Double, wasManual: Bool,
    emergencyOverride: Bool? = nil,
    accelerationFactor: Double = FanAccelerationProfile.defaultFactor
  ) -> Decision {
    let threshold = min(
      max(threshold, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound)
    let emergency = emergencyOverride ?? isEmergency(snapshot)
    let shouldBeManual =
      emergency
      || (wasManual
        ? snapshot.temperature > threshold - hysteresis
        : snapshot.temperature > threshold)

    guard shouldBeManual else { return .automatic }

    let targets = snapshot.fans.map { fan in
      if emergency { return fan.maximumRPM }
      guard
        let progress = curveFraction(
          temperature: snapshot.temperature, threshold: threshold,
          accelerationFactor: accelerationFactor)
      else { return fan.activeTargetFloor }
      let curveTarget = fan.minimumRPM + (fan.maximumRPM - fan.minimumRPM) * progress

      // F?Tg is macOS's requested target in automatic mode and FanBar's last
      // target in manual mode. Keeping it as a floor both avoids overriding a
      // higher system request on entry and makes a manual session monotonic.
      return min(fan.maximumRPM, max(fan.activeTargetFloor, curveTarget))
    }
    guard
      emergency || wasManual
        || zip(targets, snapshot.fans).contains(where: { $0 > $1.activeTargetFloor })
    else { return .automatic }
    return .manual(targets)
  }
}
