import Foundation

struct FanControlLoop: Sendable {
  struct Configuration: Sendable {
    let cpuThreshold: Double
    let batteryCurveEnabled: Bool
    let batteryThreshold: Double
    let accelerationFactor: Double
    let interval: TimeInterval
  }

  struct ManualCommand: Sendable, Equatable {
    let desiredTargets: [Double]
    let limitedTargets: [Double]
    let cpuEmergency: Bool
    let batteryEmergency: Bool
    let batteryDominant: Bool
  }

  enum Outcome: Sendable, Equatable {
    case automatic(curveAboveThreshold: Bool)
    case confirmingCooldown(sampleCount: Int)
    case releaseToAutomatic
    case manual(ManualCommand)
  }

  private let cpuPolicy: FanSafetyPolicy
  private let batteryPolicy: BatteryFanPolicy
  private let slewLimiter: FanTargetSlewLimiter
  private(set) var capturedSystemFloors: [Double] = []
  private(set) var consecutiveCoolSamples = 0

  init(
    cpuPolicy: FanSafetyPolicy = FanSafetyPolicy(),
    batteryPolicy: BatteryFanPolicy = BatteryFanPolicy(),
    slewLimiter: FanTargetSlewLimiter = FanTargetSlewLimiter()
  ) {
    self.cpuPolicy = cpuPolicy
    self.batteryPolicy = batteryPolicy
    self.slewLimiter = slewLimiter
  }

  mutating func evaluate(
    snapshot: FanSnapshot,
    rawCPUTemperature: Double,
    rawBatteryTemperature: Double?,
    configuration: Configuration,
    wasManual: Bool,
    previousTargets: [Double]
  ) -> Outcome {
    if !wasManual {
      capturedSystemFloors = snapshot.fans.map(\.activeTargetFloor)
    }
    let decisionSnapshot = snapshot.applyingSystemFloors(capturedSystemFloors)
    let cpuEmergency = rawCPUTemperature >= cpuPolicy.emergencyTemperature
    let batteryEmergency =
      configuration.batteryCurveEnabled
      && (rawBatteryTemperature ?? 0) >= BatteryFanPolicy.maximumTemperature
    let cpuDecision = cpuPolicy.decision(
      for: decisionSnapshot,
      threshold: configuration.cpuThreshold,
      wasManual: wasManual,
      emergencyOverride: cpuEmergency,
      accelerationFactor: configuration.accelerationFactor)
    let batteryDecision =
      configuration.batteryCurveEnabled
      ? batteryPolicy.decision(
        temperature: decisionSnapshot.batteryTemperature,
        fans: decisionSnapshot.fans,
        threshold: configuration.batteryThreshold,
        wasManual: wasManual,
        accelerationFactor: configuration.accelerationFactor)
      : .automatic
    let combined = combine(cpu: cpuDecision, battery: batteryDecision)

    switch combined.decision {
    case .automatic:
      if wasManual {
        consecutiveCoolSamples += 1
        if consecutiveCoolSamples < 3 {
          return .confirmingCooldown(sampleCount: consecutiveCoolSamples)
        }
        consecutiveCoolSamples = 0
        return .releaseToAutomatic
      }
      consecutiveCoolSamples = 0
      let curveAboveThreshold =
        snapshot.temperature > configuration.cpuThreshold
        || (configuration.batteryCurveEnabled
          && (snapshot.batteryTemperature ?? -.infinity) > configuration.batteryThreshold)
      return .automatic(curveAboveThreshold: curveAboveThreshold)

    case .manual(let desiredTargets):
      consecutiveCoolSamples = 0
      let limitedTargets = slewLimiter.limit(
        desired: desiredTargets,
        previous: previousTargets,
        fans: decisionSnapshot.fans,
        interval: configuration.interval,
        bypass: cpuEmergency || batteryEmergency)
      return .manual(
        ManualCommand(
          desiredTargets: desiredTargets,
          limitedTargets: limitedTargets,
          cpuEmergency: cpuEmergency,
          batteryEmergency: batteryEmergency,
          batteryDominant: combined.batteryDominant))
    }
  }

  mutating func reset() {
    capturedSystemFloors = []
    consecutiveCoolSamples = 0
  }

  func cpuCurveFraction(
    temperature: Double, threshold: Double, accelerationFactor: Double
  ) -> Double? {
    cpuPolicy.curveFraction(
      temperature: temperature, threshold: threshold, accelerationFactor: accelerationFactor)
  }

  func batteryCurveFraction(
    temperature: Double, threshold: Double, accelerationFactor: Double
  ) -> Double? {
    batteryPolicy.curveFraction(
      temperature: temperature, threshold: threshold, accelerationFactor: accelerationFactor)
  }

  private func combine(
    cpu: FanSafetyPolicy.Decision, battery: FanSafetyPolicy.Decision
  ) -> (decision: FanSafetyPolicy.Decision, batteryDominant: Bool) {
    switch (cpu, battery) {
    case (.automatic, .automatic):
      return (.automatic, false)
    case (.manual(let targets), .automatic):
      return (.manual(targets), false)
    case (.automatic, .manual(let targets)):
      return (.manual(targets), true)
    case (.manual(let cpuTargets), .manual(let batteryTargets)):
      let combinedTargets = zip(cpuTargets, batteryTargets).map(max)
      let batteryDominant = zip(cpuTargets, batteryTargets).contains { $1 > $0 }
      return (.manual(combinedTargets), batteryDominant)
    }
  }
}
