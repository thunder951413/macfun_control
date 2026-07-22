import Darwin
import FanBarHardware
import Foundation

enum SystemThermalSeverity: Int, Codable, Sendable {
  case nominal = 0
  case fair = 1
  case serious = 2
  case critical = 3

  static var current: Self {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: .nominal
    case .fair: .fair
    case .serious: .serious
    case .critical: .critical
    @unknown default: .fair
    }
  }
}

struct FanDeviceProfile: Codable, Equatable, Sendable {
  let modelIdentifier: String
  let architecture: String

  static var current: Self {
    Self(
      modelIdentifier: sysctlString("hw.model") ?? "UnknownMac",
      architecture: architectureName)
  }

  var exportStem: String {
    modelIdentifier.map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce("") {
      $0 + String($1)
    }
  }

  private static var architectureName: String {
    #if arch(arm64)
      return "arm64"
    #elseif arch(x86_64)
      return "x86_64"
    #else
      return "unknown"
    #endif
  }

  private static func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    if buffer.last == 0 { buffer.removeLast() }
    return String(decoding: buffer.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}

struct MacOSFanTargetSample: Codable, Equatable, Sendable {
  let index: Int
  let targetRPM: Double
  let minimumRPM: Double
  let maximumRPM: Double
}

struct MacOSFanHistorySample: Codable, Equatable, Sendable {
  let recordedAt: Date
  let operatingSystemVersion: String?
  let controlSource: String
  let cpuTemperature: Double
  let batteryTemperature: Double?
  let systemPowerWatts: Double?
  let externalPowerConnected: Bool
  let thermalSeverity: SystemThermalSeverity
  let fans: [MacOSFanTargetSample]

  init?(
    snapshot: FanSnapshot, controlSource: CPUTemperatureSource,
    thermalSeverity: SystemThermalSeverity, recordedAt: Date = Date(),
    operatingSystemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
  ) {
    let targets = snapshot.fans.compactMap { fan -> MacOSFanTargetSample? in
      guard let target = fan.reportedTargetRPM, target.isFinite, target >= 0 else { return nil }
      return MacOSFanTargetSample(
        index: fan.index, targetRPM: target,
        minimumRPM: fan.minimumRPM, maximumRPM: fan.maximumRPM)
    }
    guard !targets.isEmpty, targets.count == snapshot.fans.count else { return nil }
    self.recordedAt = recordedAt
    self.operatingSystemVersion = operatingSystemVersion
    self.controlSource = controlSource.rawValue
    cpuTemperature = snapshot.temperature
    batteryTemperature = snapshot.batteryTemperature
    systemPowerWatts = snapshot.power?.systemPowerWatts
    externalPowerConnected = snapshot.power?.isExternalPowerConnected ?? false
    self.thermalSeverity = thermalSeverity
    fans = targets
  }
}

struct MacOSFanHistoryDataset: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let device: FanDeviceProfile
  let privacy: String
  var updatedAt: Date
  var samples: [MacOSFanHistorySample]

  init(device: FanDeviceProfile, now: Date = Date()) {
    schemaVersion = Self.currentSchemaVersion
    self.device = device
    privacy = "No serial number, user name, file path, or application data is collected."
    updatedAt = now
    samples = []
  }
}

struct MacOSFanLearningQuery: Sendable {
  let controlSource: String
  let cpuTemperature: Double
  let batteryTemperature: Double?
  let systemPowerWatts: Double?
  let externalPowerConnected: Bool
  let thermalSeverity: SystemThermalSeverity
  let fanCount: Int
}

struct MacOSFanPrediction: Equatable, Sendable {
  let targets: [Double]
  let sampleCount: Int
  let confidence: Double
}

enum MacOSFanCurveModel {
  static let minimumSamples = 6
  static let neighborLimit = 32

  static func predict(
    samples: [MacOSFanHistorySample], query: MacOSFanLearningQuery
  ) -> MacOSFanPrediction? {
    let candidates = samples.compactMap { sample -> (MacOSFanHistorySample, Double)? in
      guard sample.fans.count == query.fanCount, sample.controlSource == query.controlSource else {
        return nil
      }
      let distance = contextDistance(sample: sample, query: query)
      return (sample, distance)
    }.sorted { $0.1 < $1.1 }

    let neighbors = Array(candidates.prefix(neighborLimit))
    guard neighbors.count >= minimumSamples else { return nil }

    let targets = (0..<query.fanCount).compactMap { fanIndex -> Double? in
      let values = neighbors.compactMap { sample, distance -> (Double, Double)? in
        guard let fan = sample.fans.first(where: { $0.index == fanIndex }) else { return nil }
        return (fan.targetRPM, 1 / (0.25 + distance))
      }
      return weightedPercentile(values, percentile: 0.8)
    }
    guard targets.count == query.fanCount else { return nil }

    let meanDistance = neighbors.map(\.1).reduce(0, +) / Double(neighbors.count)
    let support = min(1, Double(neighbors.count) / Double(neighborLimit))
    let locality = max(0, 1 - meanDistance / 5)
    return MacOSFanPrediction(
      targets: targets, sampleCount: neighbors.count,
      confidence: min(1, max(0, support * locality)))
  }

  private static func contextDistance(
    sample: MacOSFanHistorySample, query: MacOSFanLearningQuery
  ) -> Double {
    var distance = abs(sample.cpuTemperature - query.cpuTemperature) / 5
    if let sampleBattery = sample.batteryTemperature, let queryBattery = query.batteryTemperature {
      distance += abs(sampleBattery - queryBattery) / 5
    } else if sample.batteryTemperature != nil || query.batteryTemperature != nil {
      distance += 0.5
    }
    if let samplePower = sample.systemPowerWatts, let queryPower = query.systemPowerWatts {
      distance += abs(samplePower - queryPower) / 25
    } else if sample.systemPowerWatts != nil || query.systemPowerWatts != nil {
      distance += 0.5
    }
    if sample.externalPowerConnected != query.externalPowerConnected { distance += 0.75 }
    distance += Double(abs(sample.thermalSeverity.rawValue - query.thermalSeverity.rawValue)) * 1.5
    return distance
  }

  private static func weightedPercentile(
    _ values: [(value: Double, weight: Double)], percentile: Double
  ) -> Double? {
    let sorted = values.filter { $0.value.isFinite && $0.weight > 0 }.sorted {
      $0.value < $1.value
    }
    guard !sorted.isEmpty else { return nil }
    let totalWeight = sorted.map(\.weight).reduce(0, +)
    let threshold = totalWeight * min(1, max(0, percentile))
    var accumulated = 0.0
    for item in sorted {
      accumulated += item.weight
      if accumulated >= threshold { return item.value }
    }
    return sorted.last?.value
  }
}

extension FanSnapshot {
  func learningQuery(
    source: CPUTemperatureSource, thermalSeverity: SystemThermalSeverity
  ) -> MacOSFanLearningQuery {
    MacOSFanLearningQuery(
      controlSource: source.rawValue,
      cpuTemperature: temperature,
      batteryTemperature: batteryTemperature,
      systemPowerWatts: power?.systemPowerWatts,
      externalPowerConnected: power?.isExternalPowerConnected ?? false,
      thermalSeverity: thermalSeverity,
      fanCount: fans.count)
  }

  func applyingLearnedSystemFloor(_ targets: [Double]?) -> FanSnapshot {
    guard let targets, targets.count == fans.count else { return self }
    let adjustedFans = fans.enumerated().map { index, fan in
      let learned = min(fan.maximumRPM, max(fan.minimumRPM, targets[index]))
      return FanReading(
        index: fan.index, actualRPM: fan.actualRPM,
        reportedTargetRPM: max(fan.reportedTargetRPM ?? 0, learned),
        minimumRPM: fan.minimumRPM, maximumRPM: fan.maximumRPM)
    }
    return FanSnapshot(
      temperature: temperature, hotspotTemperature: hotspotTemperature,
      hotspotSource: hotspotSource, batteryTemperature: batteryTemperature,
      batterySource: batterySource, power: power, fans: adjustedFans)
  }
}

struct MacOSFanHistoryExport: Sendable {
  let data: Data
  let suggestedFilename: String
}

private struct MacOSFanContributionDataset: Encodable {
  let schemaVersion: Int
  let format: String
  let device: FanDeviceProfile
  let privacy: String
  let samples: [MacOSFanContributionSample]
}

private struct MacOSFanContributionSample: Encodable {
  let operatingSystemVersion: String?
  let controlSource: String
  let cpuTemperature: Double
  let batteryTemperature: Double?
  let systemPowerWatts: Double?
  let externalPowerConnected: Bool
  let thermalSeverity: SystemThermalSeverity
  let fans: [MacOSFanTargetSample]

  init(_ sample: MacOSFanHistorySample) {
    operatingSystemVersion = sample.operatingSystemVersion
    controlSource = sample.controlSource
    cpuTemperature = sample.cpuTemperature
    batteryTemperature = sample.batteryTemperature
    systemPowerWatts = sample.systemPowerWatts
    externalPowerConnected = sample.externalPowerConnected
    thermalSeverity = sample.thermalSeverity
    fans = sample.fans
  }
}

actor MacOSFanHistoryStore {
  static let maximumSamples = 10_000

  private let fileURL: URL
  private let device: FanDeviceProfile
  private var dataset: MacOSFanHistoryDataset

  init(
    fileURL: URL = MacOSFanHistoryStore.defaultFileURL(),
    device: FanDeviceProfile = .current
  ) {
    self.fileURL = fileURL
    self.device = device
    if let data = try? Data(contentsOf: fileURL),
      let decoded = try? Self.decoder.decode(MacOSFanHistoryDataset.self, from: data),
      decoded.schemaVersion == MacOSFanHistoryDataset.currentSchemaVersion,
      decoded.device == device
    {
      dataset = decoded
    } else {
      dataset = MacOSFanHistoryDataset(device: device)
    }
  }

  func sampleCount() -> Int { dataset.samples.count }

  func record(_ sample: MacOSFanHistorySample) throws {
    dataset.samples.append(sample)
    if dataset.samples.count > Self.maximumSamples {
      dataset.samples.removeFirst(dataset.samples.count - Self.maximumSamples)
    }
    dataset.updatedAt = sample.recordedAt
    try persist()
  }

  func prediction(for query: MacOSFanLearningQuery) -> MacOSFanPrediction? {
    MacOSFanCurveModel.predict(samples: dataset.samples, query: query)
  }

  func makeExport() throws -> MacOSFanHistoryExport {
    let filename = "fanbar-profile-\(device.exportStem)-v\(dataset.schemaVersion).json"
    let contribution = MacOSFanContributionDataset(
      schemaVersion: dataset.schemaVersion,
      format: "fanbar.machine-profile",
      device: device,
      privacy:
        "No serial number, user name, host name, file path, exact timestamp, or application data is included.",
      samples: dataset.samples.map(MacOSFanContributionSample.init))
    return MacOSFanHistoryExport(
      data: try Self.encoder.encode(contribution), suggestedFilename: filename)
  }

  nonisolated static func defaultFileURL() -> URL {
    let root =
      FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support")
    return root.appendingPathComponent("FanBar/macOS-fan-history-v1.json")
  }

  private func persist() throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Self.encoder.encode(dataset).write(to: fileURL, options: .atomic)
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}
