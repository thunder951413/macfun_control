import FanBarHardware
import Foundation

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

  static func available(hasControllableFans: Bool) -> [MenuBarDisplayMode] {
    hasControllableFans ? allCases : [.iconOnly, .temperature]
  }
}

enum MenuBarPresentation {
  static func symbolName(state: FanController.ControlState, hasControllableFans: Bool) -> String {
    guard hasControllableFans else { return "thermometer.medium" }
    return state.menuBarSymbolName
  }
}

enum PowerConnectionNotice {
  static let duration: TimeInterval = 2

  static func didConnect(previous: Bool?, current: Bool) -> Bool {
    previous == false && current
  }

  static func isVisible(until: Date?, now: Date = Date()) -> Bool {
    guard let until else { return false }
    return now < until
  }

  static func text(for power: PowerReading) -> String {
    guard let watts = power.inputCapacityWatts else { return "-- W" }
    return String(format: "%.1f W", watts)
  }
}

enum PopoverTab: String, Hashable {
  case sensors
  case settings

  func preferredHeight(sensorGroupCount: Int, hasControllableFans: Bool = true) -> Double {
    switch self {
    case .sensors:
      let rows = max(1, Int(ceil(Double(sensorGroupCount) / 2)))
      // Include popover chrome, fan/fanless status, the primary-temperature
      // cards, section headings, padding, and the two-column sensor rows.
      // The previous base omitted most of that fixed content and clipped the
      // last rows even though the row-count calculation itself was correct.
      let baseHeight = hasControllableFans ? 450.0 : 442.0
      let minimumHeight = hasControllableFans ? 600.0 : 590.0
      return min(780, max(minimumHeight, baseHeight + Double(rows) * 68))
    case .settings:
      return hasControllableFans ? 620 : 500
    }
  }
}

enum PopoverSizing {
  static func height(preferred: Double, visibleScreenHeight: Double?) -> Double {
    guard let visibleScreenHeight, visibleScreenHeight.isFinite, visibleScreenHeight > 0 else {
      return preferred
    }
    return min(preferred, max(350, visibleScreenHeight - 32))
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

enum BatteryTemperaturePreferences {
  static let alertRange = 30.0...50.0
  static let defaultAlertThreshold = 40.0
}

enum BatteryMenuAlert {
  static func text(temperature: Double?, threshold: Double) -> String? {
    guard let temperature, temperature.isFinite, temperature > threshold else { return nil }
    return "🔋 电池区域 \(Int(temperature.rounded()))°"
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
