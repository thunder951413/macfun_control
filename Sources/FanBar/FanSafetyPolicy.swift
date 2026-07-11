import Foundation

struct FanReading: Sendable, Equatable, Identifiable {
  let index: Int
  let actualRPM: Double
  let minimumRPM: Double
  let maximumRPM: Double

  var id: Int { index }
}

struct FanSnapshot: Sendable, Equatable {
  let temperature: Double
  let hotspotTemperature: Double?
  let fans: [FanReading]

  init(temperature: Double, hotspotTemperature: Double? = nil, fans: [FanReading]) {
    self.temperature = temperature
    self.hotspotTemperature = hotspotTemperature
    self.fans = fans
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
      let baseline = previous.indices.contains(index) ? previous[index] : fan.actualRPM
      let limited =
        desiredTarget >= baseline
        ? min(desiredTarget, baseline + increaseRPMPerSecond * seconds)
        : max(desiredTarget, baseline - decreaseRPMPerSecond * seconds)
      return min(fan.maximumRPM, max(fan.actualRPM, max(fan.minimumRPM, limited)))
    }
  }
}

struct FanSafetyPolicy: Sendable {
  static let thresholdRange = 55.0...80.0
  static let defaultThreshold = 68.0

  let hysteresis: Double
  let emergencyTemperature: Double
  let emergencyHotspotTemperature: Double

  init(
    hysteresis: Double = 3, emergencyTemperature: Double = 90,
    emergencyHotspotTemperature: Double = 90
  ) {
    self.hysteresis = hysteresis
    self.emergencyTemperature = emergencyTemperature
    self.emergencyHotspotTemperature = emergencyHotspotTemperature
  }

  enum Decision: Equatable {
    case automatic
    case manual([Double])
  }

  func isEmergency(_ snapshot: FanSnapshot) -> Bool {
    snapshot.temperature >= emergencyTemperature
      || (snapshot.hotspotTemperature ?? -.infinity) >= emergencyHotspotTemperature
  }

  func curveFraction(temperature: Double, threshold: Double) -> Double? {
    let threshold = min(
      max(threshold, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound)
    guard temperature > threshold else { return nil }
    let span = max(1, emergencyTemperature - threshold)
    return min(1, max(0, (temperature - threshold) / span))
  }

  func decision(for snapshot: FanSnapshot, threshold: Double, wasManual: Bool) -> Decision {
    let threshold = min(
      max(threshold, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound)
    let emergency = isEmergency(snapshot)
    let shouldBeManual = emergency
      || (wasManual
        ? snapshot.temperature > threshold - hysteresis
        : snapshot.temperature > threshold)

    guard shouldBeManual else { return .automatic }

    let targets = snapshot.fans.map { fan in
      if emergency { return fan.maximumRPM }
      guard
        let progress = curveFraction(
          temperature: snapshot.temperature, threshold: threshold)
      else { return fan.actualRPM }
      let curveTarget = fan.minimumRPM + (fan.maximumRPM - fan.minimumRPM) * progress

      // Entering manual control must never slow a fan that the system was
      // already driving faster.
      return min(fan.maximumRPM, max(fan.actualRPM, curveTarget))
    }
    return .manual(targets)
  }
}
