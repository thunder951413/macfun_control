import FanBarHardware
import Foundation

struct TemperatureDashboard: Sendable, Equatable {
  let package: Double?
  let coreAverage: Double?
  let hotspot: Double?
  let readings: [TemperatureReading]

  static let empty = TemperatureDashboard(
    package: nil, coreAverage: nil, hotspot: nil, readings: [])

  func value(for source: CPUTemperatureSource) -> Double? {
    switch source {
    case .package: package
    case .coreAverage: coreAverage
    case .hotspot: hotspot
    }
  }
}

struct TemperatureSensorGroup: Identifiable, Equatable {
  enum Category: Int, CaseIterable, Sendable {
    case cpu
    case soc
    case gpu
    case memory
    case enclosure
    case other

    var label: String {
      switch self {
      case .cpu: "CPU 与核心"
      case .soc: "SoC 与芯片"
      case .gpu: "GPU"
      case .memory: "内存与供电"
      case .enclosure: "机身与接口"
      case .other: "其他"
      }
    }

    var symbol: String {
      switch self {
      case .cpu: "cpu"
      case .soc: "square.stack.3d.up"
      case .gpu: "display"
      case .memory: "memorychip"
      case .enclosure: "macstudio"
      case .other: "sensor"
      }
    }
  }

  let category: Category
  let readings: [TemperatureReading]

  var id: Int { category.rawValue }
  var average: Double {
    readings.map(\.value).reduce(0, +) / Double(max(1, readings.count))
  }
  var maximum: Double { readings.map(\.value).max() ?? 0 }

  static func make(from readings: [TemperatureReading]) -> [TemperatureSensorGroup] {
    let valid = readings.filter { $0.value.isFinite && (10...125).contains($0.value) }
    return Category.allCases.compactMap { category in
      let values = valid.filter { categoryForKey($0.key) == category }.sorted { $0.key < $1.key }
      return values.isEmpty ? nil : TemperatureSensorGroup(category: category, readings: values)
    }
  }

  private static func categoryForKey(_ key: String) -> Category {
    if key.hasPrefix("Tg") { return .gpu }
    if key.hasPrefix("TM") || key.hasPrefix("TV") { return .memory }
    if key.hasPrefix("Ts") || key.hasPrefix("TPD") || key.hasPrefix("TRD")
      || key == "TPMP" || key == "TPSP"
    {
      return .soc
    }
    if key.hasPrefix("TC") || key.hasPrefix("Tp") || key.hasPrefix("Te")
      || key.hasPrefix("Tf")
    {
      return .cpu
    }
    if key.hasPrefix("TA") || key.hasPrefix("Ta") || key.hasPrefix("TB")
      || key.hasPrefix("TD") || key.hasPrefix("TH") || key.hasPrefix("TW")
    {
      return .enclosure
    }
    return .other
  }
}
