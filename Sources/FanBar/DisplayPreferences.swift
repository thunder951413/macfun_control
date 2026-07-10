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
