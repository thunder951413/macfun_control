import FanBarHardware
import Foundation

enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
  case iconOnly
  case temperature
  case fanSpeed
  case temperatureAndFan
  case battery
  case temperatureAndBattery
  case fanAndBattery
  case temperatureFanAndBattery

  var id: String { rawValue }

  var label: String {
    switch self {
    case .iconOnly: "仅图标"
    case .temperature: "温度"
    case .fanSpeed: "风扇转速"
    case .temperatureAndFan: "温度＋转速"
    case .battery: "电量与充电状态"
    case .temperatureAndBattery: "温度＋电量"
    case .fanAndBattery: "转速＋电量"
    case .temperatureFanAndBattery: "温度＋转速＋电量"
    }
  }

  static func available(hasControllableFans: Bool) -> [MenuBarDisplayMode] {
    hasControllableFans
      ? allCases
      : [.iconOnly, .temperature, .battery, .temperatureAndBattery]
  }

  var includesTemperature: Bool {
    self == .temperature || self == .temperatureAndFan || self == .temperatureAndBattery
      || self == .temperatureFanAndBattery
  }

  var includesFan: Bool {
    self == .fanSpeed || self == .temperatureAndFan || self == .fanAndBattery
      || self == .temperatureFanAndBattery
  }

  var includesBattery: Bool {
    self == .battery || self == .temperatureAndBattery || self == .fanAndBattery
      || self == .temperatureFanAndBattery
  }

  static func compose(temperature: Bool, fan: Bool, battery: Bool) -> Self {
    switch (temperature, fan, battery) {
    case (false, false, false): .iconOnly
    case (true, false, false): .temperature
    case (false, true, false): .fanSpeed
    case (true, true, false): .temperatureAndFan
    case (false, false, true): .battery
    case (true, false, true): .temperatureAndBattery
    case (false, true, true): .fanAndBattery
    case (true, true, true): .temperatureFanAndBattery
    }
  }
}

enum MenuBarPresentation {
  static func symbolName(state: FanController.ControlState, hasControllableFans: Bool) -> String {
    guard hasControllableFans else { return "thermometer.medium" }
    return state.menuBarSymbolName
  }
}

enum SamplingIntervalOption: String, CaseIterable, Identifiable {
  case responsive
  case balanced
  case efficient

  var id: String { rawValue }

  var seconds: TimeInterval {
    switch self {
    case .responsive: 2
    case .balanced: 3
    case .efficient: 5
    }
  }

  var label: String {
    switch self {
    case .responsive: "2 秒 · 灵敏"
    case .balanced: "3 秒 · 均衡"
    case .efficient: "5 秒 · 节能"
    }
  }

  var detail: String {
    switch self {
    case .responsive: "高温变化最快约 2 秒响应"
    case .balanced: "减少约三分之一读取，响应仍及时"
    case .efficient: "减少约六成读取，高温响应最迟约 5 秒"
    }
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

enum BatteryStatusPresentation {
  static func text(for power: PowerReading?) -> String {
    guard let level = power?.batteryLevelPercent else { return "--%" }
    if power?.isBatteryCharging == true { return "\(level)% ⚡︎" }
    if power?.isBatteryFullyCharged == true { return "\(level)% ✓" }
    if power?.isExternalPowerConnected == true { return "\(level)% ⏸" }
    return "\(level)%"
  }

  static func symbolName(for power: PowerReading?) -> String {
    guard let level = power?.batteryLevelPercent else { return "battery.0percent" }
    let bucket = min(100, max(0, Int((Double(level) / 25).rounded()) * 25))
    let base = "battery.\(bucket)percent"
    return power?.isBatteryCharging == true ? "battery.100percent.bolt" : base
  }
}

enum PopoverTab: String, Hashable {
  case sensors
  case battery
  case fan

  func preferredHeight(sensorGroupCount: Int, hasControllableFans: Bool = true) -> Double {
    switch self {
    case .sensors:
      let rows = max(1, Int(ceil(Double(sensorGroupCount) / 2)))
      // Include popover chrome, fan/fanless status, the primary-temperature
      // cards, section headings, padding, and the two-column sensor rows.
      // The previous base omitted most of that fixed content and clipped the
      // last rows even though the row-count calculation itself was correct.
      let baseHeight = hasControllableFans ? 518.0 : 510.0
      let minimumHeight = hasControllableFans ? 668.0 : 658.0
      return min(780, max(minimumHeight, baseHeight + Double(rows) * 68))
    case .battery:
      return 680
    case .fan:
      return hasControllableFans ? 700 : 430
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
