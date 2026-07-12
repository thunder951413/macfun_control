import Foundation
import FanBarHardware

enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
  case iconOnly
  case temperature
  case fanSpeed
  case temperatureAndFan

  var id: String { rawValue }

  var label: String {
    switch self {
    case .iconOnly: "仅图标"
    case .temperature: "温度"
    case .fanSpeed: "风扇转速"
    case .temperatureAndFan: "温度＋转速"
    }
  }
}

enum PopoverTab: String, Hashable {
  case sensors
  case settings

  func preferredHeight(sensorGroupCount: Int) -> Double {
    switch self {
    case .sensors:
      let rows = max(1, Int(ceil(Double(sensorGroupCount) / 2)))
      return min(620, max(390, 220 + Double(rows) * 68))
    case .settings:
      return 670
    }
  }
}

enum HotspotMenuAlert {
  static func text(temperature: Double?, source: String?) -> String? {
    guard let temperature, temperature.isFinite, temperature > 90 else { return nil }
    return "🌡 \(readableSource(source)) \(Int(temperature.rounded()))°"
  }

  static func readableSource(_ source: String?) -> String {
    switch source {
    case "TCMz": "CPU 芯片最高热点"
    case "TCMb": "CPU 核心最高温"
    case "CPU hotspot": "CPU 最高热点"
    case .some(let key): "温度传感器（\(key)）"
    case nil: "CPU 最高热点"
    }
  }
}

extension CPUTemperatureSource: Identifiable {
  public var id: String { rawValue }

  var label: String {
    switch self {
    case .package: "CPU 封装（推荐）"
    case .coreAverage: "CPU 核心平均"
    case .hotspot: "CPU 最高热点"
    }
  }

  var shortLabel: String {
    switch self {
    case .package: "封装"
    case .coreAverage: "核心平均"
    case .hotspot: "最高热点"
    }
  }
}
