import FanBarHardware
import Foundation
import OSLog

@MainActor
final class FanController: ObservableObject {
  private let logger = Logger(subsystem: "local.fanbar", category: "control")
  enum FanCapability: Equatable {
    case unknown
    case available
    case unavailable
  }

  enum ControlState: Equatable {
    case starting
    case monitoring
    case automatic
    case manual
    case suspended
    case error

    var label: String {
      switch self {
      case .starting: "启动中"
      case .monitoring: "仅监控"
      case .automatic: "系统自动"
      case .manual: "智能曲线"
      case .suspended: "已暂停"
      case .error: "安全回退"
      }
    }

    var menuBarSymbolName: String {
      self == .manual ? "fan.fill" : "fan"
    }
  }

  @Published private(set) var thresholdCelsius: Double
  @Published private(set) var isControlEnabled: Bool
  @Published private(set) var currentTemperature: Double?
  @Published private(set) var currentHotspotTemperature: Double?
  @Published private(set) var currentHotspotSource: String?
  @Published private(set) var currentBatteryTemperature: Double?
  @Published private(set) var currentBatterySource: String?
  @Published private(set) var currentPower: PowerReading?
  @Published private(set) var batteryChargeLimitState = BatteryChargeLimitState.unsupported
  @Published private(set) var batteryChargeLimitEnabled: Bool
  @Published private(set) var batteryChargeLimitPercent: Int
  @Published private(set) var batteryChargeLimitError: String?
  @Published private(set) var temperatureDashboard = TemperatureDashboard.empty
  @Published private(set) var fanReadings: [FanReading] = []
  @Published private(set) var targetRPMs: [Double] = []
  @Published private(set) var state: ControlState = .starting
  @Published private(set) var statusText = "正在连接 AppleSMC…"
  @Published private(set) var menuBarDisplayMode: MenuBarDisplayMode
  @Published private(set) var batteryMenuBarStyle: BatteryMenuBarStyle
  @Published private(set) var showsBatteryIconInMenuBar: Bool
  @Published private(set) var showsBatteryPercentageInMenuBar: Bool
  @Published private(set) var showsHotspotMenuAlert: Bool
  @Published private(set) var showsBatteryMenuAlert: Bool
  @Published private(set) var batteryAlertThreshold: Double
  @Published private(set) var isBatteryCurveEnabled: Bool
  @Published private(set) var batteryCurveThreshold: Double
  @Published private(set) var fanAccelerationFactor: Double
  @Published private(set) var temperatureSource: CPUTemperatureSource
  @Published private(set) var samplingIntervalOption: SamplingIntervalOption
  @Published private(set) var selectedPopoverTab: PopoverTab = .sensors
  @Published private(set) var fanCapability: FanCapability = .unknown
  @Published private var powerConnectionNoticeUntil: Date?
  let helperManager: PrivilegedHelperManager
  let launchAtLoginManager: LaunchAtLoginManager

  private static let thresholdKey = "thresholdCelsius"
  private static let enabledKey = "controlEnabled"
  private static let activeSessionKey = "ownsActiveManualSession"
  private static let menuBarDisplayKey = "menuBarDisplayMode"
  private static let batteryMenuBarStyleKey = "batteryMenuBarStyle"
  private static let batteryMenuBarIconKey = "showsBatteryIconInMenuBar"
  private static let batteryMenuBarPercentageKey = "showsBatteryPercentageInMenuBar"
  private static let hotspotMenuAlertKey = "showsHotspotMenuAlert"
  private static let batteryMenuAlertKey = "showsBatteryMenuAlert"
  private static let batteryAlertThresholdKey = "batteryAlertThreshold"
  private static let batteryCurveEnabledKey = "batteryCurveEnabled"
  private static let batteryCurveThresholdKey = "batteryCurveThreshold"
  private static let fanAccelerationFactorKey = "fanAccelerationFactor"
  private static let temperatureSourceKey = "temperatureSource"
  private static let samplingIntervalKey = "samplingInterval"
  private static let batteryChargeLimitEnabledKey = "batteryChargeLimitEnabled"
  private static let batteryChargeLimitPercentKey = "batteryChargeLimitPercent"
  private let service: FanService
  private let preferences: UserDefaults
  private var controlLoop: FanControlLoop
  private let pollIntervalOverride: TimeInterval?
  private var timer: Timer?
  private var isRefreshing = false
  private var hasStarted = false
  private var isSuspended = false
  private var needsRecovery: Bool
  private var temperatureFilter = TemperatureSafetyFilter()
  private var batteryTemperatureFilter = TemperatureSafetyFilter(capacity: 3)
  private var dashboardRefreshCountdown = 0
  private var didConfigureHelperForCapability = false
  private var previousExternalPowerConnected: Bool?
  private var powerConnectionNoticeTask: Task<Void, Never>?

  init(
    service: FanService = FanService(),
    policy: FanSafetyPolicy = FanSafetyPolicy(),
    batteryPolicy: BatteryFanPolicy = BatteryFanPolicy(),
    slewLimiter: FanTargetSlewLimiter = FanTargetSlewLimiter(),
    pollInterval: TimeInterval = 0,
    helperManager: PrivilegedHelperManager = PrivilegedHelperManager(),
    launchAtLoginManager: LaunchAtLoginManager = LaunchAtLoginManager(),
    preferences: UserDefaults = .standard,
    controlEnabledOverride: Bool? = nil
  ) {
    self.service = service
    self.preferences = preferences
    controlLoop = FanControlLoop(
      cpuPolicy: policy, batteryPolicy: batteryPolicy, slewLimiter: slewLimiter)
    pollIntervalOverride = pollInterval > 0 ? pollInterval : nil
    self.helperManager = helperManager
    self.launchAtLoginManager = launchAtLoginManager

    let defaults = preferences
    let savedThreshold = defaults.object(forKey: Self.thresholdKey) as? Double
    thresholdCelsius = min(
      max(
        savedThreshold ?? FanSafetyPolicy.defaultThreshold,
        FanSafetyPolicy.thresholdRange.lowerBound),
      FanSafetyPolicy.thresholdRange.upperBound)
    // Upgrades retain the prior user's intent. Fresh installs start in
    // monitor-only mode until the user explicitly enables hardware writes.
    isControlEnabled =
      controlEnabledOverride
      ?? ((defaults.object(forKey: Self.enabledKey) as? Bool ?? false) && helperManager.isReady)
    needsRecovery = defaults.bool(forKey: Self.activeSessionKey)
    menuBarDisplayMode =
      MenuBarDisplayMode(
        rawValue: defaults.string(forKey: Self.menuBarDisplayKey) ?? "") ?? .temperature
    batteryMenuBarStyle =
      BatteryMenuBarStyle(
        rawValue: defaults.string(forKey: Self.batteryMenuBarStyleKey) ?? "") ?? .fanBarStatus
    showsBatteryIconInMenuBar =
      defaults.object(forKey: Self.batteryMenuBarIconKey) as? Bool ?? true
    showsBatteryPercentageInMenuBar =
      defaults.object(forKey: Self.batteryMenuBarPercentageKey) as? Bool ?? true
    showsHotspotMenuAlert = defaults.object(forKey: Self.hotspotMenuAlertKey) as? Bool ?? true
    showsBatteryMenuAlert = defaults.object(forKey: Self.batteryMenuAlertKey) as? Bool ?? true
    let savedBatteryAlertThreshold =
      defaults.object(forKey: Self.batteryAlertThresholdKey) as? Double
    batteryAlertThreshold = min(
      max(
        savedBatteryAlertThreshold ?? BatteryTemperaturePreferences.defaultAlertThreshold,
        BatteryTemperaturePreferences.alertRange.lowerBound),
      BatteryTemperaturePreferences.alertRange.upperBound)
    isBatteryCurveEnabled =
      defaults.object(forKey: Self.batteryCurveEnabledKey) as? Bool ?? false
    let savedBatteryCurveThreshold =
      defaults.object(forKey: Self.batteryCurveThresholdKey) as? Double
    batteryCurveThreshold = min(
      max(
        savedBatteryCurveThreshold ?? BatteryFanPolicy.defaultThreshold,
        BatteryFanPolicy.thresholdRange.lowerBound),
      BatteryFanPolicy.thresholdRange.upperBound)
    let savedAccelerationFactor =
      defaults.object(forKey: Self.fanAccelerationFactorKey) as? Double
    fanAccelerationFactor = FanAccelerationProfile.clamp(
      savedAccelerationFactor ?? FanAccelerationProfile.defaultFactor)
    temperatureSource =
      CPUTemperatureSource(
        rawValue: defaults.string(forKey: Self.temperatureSourceKey) ?? "") ?? .package
    samplingIntervalOption =
      SamplingIntervalOption(
        rawValue: defaults.string(forKey: Self.samplingIntervalKey) ?? "") ?? .responsive
    batteryChargeLimitEnabled =
      defaults.object(forKey: Self.batteryChargeLimitEnabledKey) as? Bool ?? false
    batteryChargeLimitPercent = min(
      100, max(80, defaults.object(forKey: Self.batteryChargeLimitPercentKey) as? Int ?? 80))
  }

  var samplingInterval: TimeInterval {
    pollIntervalOverride ?? samplingIntervalOption.seconds
  }

  var temperatureText: String {
    currentTemperature.map { "\(Int($0.rounded()))°C" } ?? "--°C"
  }

  var batteryTemperatureText: String {
    currentBatteryTemperature.map { "\(Int($0.rounded()))°C" } ?? "--°C"
  }

  var inputCapacityText: String {
    guard currentPower?.isExternalPowerConnected == true else { return "-- W" }
    return Self.powerText(currentPower?.inputCapacityWatts)
  }

  var systemPowerText: String {
    Self.powerText(currentPower?.systemPowerWatts)
  }

  var batteryChargingPowerText: String {
    guard currentPower?.isBatteryCharging == true else { return "未充电" }
    return Self.powerText(currentPower?.batteryChargingPowerWatts)
  }

  var batteryChargingPowerSubtitle: String {
    if currentPower?.isBatteryCharging == true { return "电池端实时净输入" }
    return currentPower?.isExternalPowerConnected == true ? "当前未向电池充电" : "正在使用电池供电"
  }

  var batteryLevelText: String { BatteryStatusPresentation.text(for: currentPower) }

  var batteryStatusText: String {
    guard let power = currentPower else { return "正在读取电池状态" }
    if power.isBatteryCharging { return "正在充电" }
    if power.isBatteryFullyCharged { return "已充满" }
    if power.isExternalPowerConnected { return "已接电源 · 暂停充电" }
    return "正在使用电池"
  }

  var batteryChargeLimitSubtitle: String {
    if let batteryChargeLimitError { return "设置失败：\(batteryChargeLimitError)" }
    guard batteryChargeLimitState.isSupported else {
      return "macOS 已阻止第三方写入；请使用系统原生充电上限"
    }
    if batteryChargeLimitState.isEnabled, let upper = batteryChargeLimitState.upperPercent {
      return "固件正在维持 \(upper)% 上限"
    }
    return "由 macOS 正常充电至 100%"
  }

  var fanText: String {
    if fanCapability == .unavailable { return "无风扇" }
    guard !fanReadings.isEmpty else { return "-- rpm" }
    if fanReadings.count == 1 { return "\(Int(fanReadings[0].actualRPM.rounded())) rpm" }
    let values = fanReadings.map { String(Int($0.actualRPM.rounded())) }.joined(separator: " / ")
    return "\(values) rpm"
  }

  var targetText: String {
    guard !targetRPMs.isEmpty else { return "系统管理" }
    return targetRPMs.map { String(Int($0.rounded())) }.joined(separator: " / ") + " rpm"
  }

  var menuBarText: String {
    if let notice = menuBarPowerConnectionText { return notice }
    return [menuBarNonBatteryText, menuBarBatteryText]
      .filter { !$0.isEmpty }
      .joined(separator: "  ")
  }

  var menuBarNonBatteryText: String {
    let temperature = currentTemperature.map { "\(Int($0.rounded()))°" } ?? "--°"
    let averageRPM =
      fanReadings.isEmpty
      ? nil
      : fanReadings.map(\.actualRPM).reduce(0, +) / Double(fanReadings.count)
    let rpm =
      averageRPM.map { value in
        value >= 1_000 ? String(format: "%.1fk", value / 1_000) : "\(Int(value.rounded()))"
      } ?? "--"
    var components: [String] = []
    if effectiveMenuBarDisplayMode.includesTemperature { components.append(temperature) }
    if effectiveMenuBarDisplayMode.includesFan { components.append(rpm) }
    return components.joined(separator: "  ")
  }

  var menuBarBatteryText: String {
    guard effectiveMenuBarDisplayMode.includesBattery else { return "" }
    return BatteryStatusPresentation.text(
      for: currentPower,
      style: batteryMenuBarStyle,
      showsPercentage: showsBatteryPercentageInMenuBar)
  }

  var hasControllableFans: Bool { fanCapability == .available }
  var isFanless: Bool { fanCapability == .unavailable }

  var availableMenuBarDisplayModes: [MenuBarDisplayMode] {
    MenuBarDisplayMode.available(hasControllableFans: !isFanless)
  }

  var effectiveMenuBarDisplayMode: MenuBarDisplayMode {
    if hasControllableFans { return menuBarDisplayMode }
    return switch menuBarDisplayMode {
    case .fanSpeed, .temperatureAndFan: .temperature
    case .fanAndBattery: .battery
    case .temperatureFanAndBattery: .temperatureAndBattery
    default: menuBarDisplayMode
    }
  }

  var usesBatteryAsPrimaryMenuBarIcon: Bool {
    menuBarPowerConnectionText == nil
      && effectiveMenuBarDisplayMode == .battery
      && (showsBatteryIconInMenuBar || batteryMenuBarStyle.embedsPercentage)
  }

  var showsBatteryAccessoryMenuBarIcon: Bool {
    menuBarPowerConnectionText == nil
      && effectiveMenuBarDisplayMode.includesBattery
      && effectiveMenuBarDisplayMode != .battery
      && (showsBatteryIconInMenuBar || batteryMenuBarStyle.embedsPercentage)
  }

  var menuBarSymbolName: String {
    if menuBarPowerConnectionText != nil { return "powerplug.fill" }
    if usesBatteryAsPrimaryMenuBarIcon {
      return BatteryStatusPresentation.symbolName(for: currentPower)
    }
    return MenuBarPresentation.symbolName(state: state, hasControllableFans: !isFanless)
  }

  var menuBarAccessibilityDescription: String {
    if let notice = menuBarPowerConnectionText { return "FanBar 已接入电源 \(notice)" }
    if isFanless { return "FanBar 温度监控" }
    return state == .manual ? "FanBar 正在加速风扇" : "FanBar 系统自动风扇"
  }

  var menuBarHotspotAlertText: String? {
    guard menuBarPowerConnectionText == nil else { return nil }
    guard showsHotspotMenuAlert else { return nil }
    return HotspotMenuAlert.text(
      temperature: currentHotspotTemperature, source: currentHotspotSource)
  }

  var menuBarBatteryAlertText: String? {
    guard menuBarPowerConnectionText == nil else { return nil }
    guard showsBatteryMenuAlert else { return nil }
    return BatteryMenuAlert.text(
      temperature: currentBatteryTemperature, threshold: batteryAlertThreshold)
  }

  var menuBarPowerConnectionText: String? {
    guard PowerConnectionNotice.isVisible(until: powerConnectionNoticeUntil),
      let currentPower, currentPower.isExternalPowerConnected
    else { return nil }
    return PowerConnectionNotice.text(for: currentPower)
  }

  var curvePercent: Int? {
    guard let currentTemperature,
      let fraction = controlLoop.cpuCurveFraction(
        temperature: currentTemperature, threshold: thresholdCelsius,
        accelerationFactor: fanAccelerationFactor)
    else { return nil }
    return Int((fraction * 100).rounded())
  }

  var batteryCurvePercent: Int? {
    guard let currentBatteryTemperature,
      let fraction = controlLoop.batteryCurveFraction(
        temperature: currentBatteryTemperature, threshold: batteryCurveThreshold,
        accelerationFactor: fanAccelerationFactor)
    else { return nil }
    return Int((fraction * 100).rounded())
  }

  var preferredPopoverHeight: Double {
    let groupCount = TemperatureSensorGroup.make(from: temperatureDashboard.readings).count
    return selectedPopoverTab.preferredHeight(
      sensorGroupCount: groupCount, hasControllableFans: !isFanless)
  }

  func setMenuBarDisplayMode(_ mode: MenuBarDisplayMode) {
    menuBarDisplayMode = mode
    preferences.set(mode.rawValue, forKey: Self.menuBarDisplayKey)
  }

  func setBatteryMenuBarStyle(_ style: BatteryMenuBarStyle) {
    batteryMenuBarStyle = style
    if style.embedsPercentage { showsBatteryIconInMenuBar = true }
    preferences.set(style.rawValue, forKey: Self.batteryMenuBarStyleKey)
    preferences.set(showsBatteryIconInMenuBar, forKey: Self.batteryMenuBarIconKey)
  }

  func setShowsBatteryIconInMenuBar(_ enabled: Bool) {
    showsBatteryIconInMenuBar = batteryMenuBarStyle.embedsPercentage ? true : enabled
    if !showsBatteryIconInMenuBar && !showsBatteryPercentageInMenuBar {
      showsBatteryPercentageInMenuBar = true
      preferences.set(true, forKey: Self.batteryMenuBarPercentageKey)
    }
    preferences.set(showsBatteryIconInMenuBar, forKey: Self.batteryMenuBarIconKey)
  }

  func setShowsBatteryPercentageInMenuBar(_ enabled: Bool) {
    if batteryMenuBarStyle.embedsPercentage {
      showsBatteryIconInMenuBar = true
      preferences.set(true, forKey: Self.batteryMenuBarIconKey)
      return
    }
    showsBatteryPercentageInMenuBar = enabled
    if !showsBatteryPercentageInMenuBar && !showsBatteryIconInMenuBar {
      showsBatteryIconInMenuBar = true
      preferences.set(true, forKey: Self.batteryMenuBarIconKey)
    }
    preferences.set(
      showsBatteryPercentageInMenuBar, forKey: Self.batteryMenuBarPercentageKey)
  }

  var showsSensorStatusInMenuBar: Bool { menuBarDisplayMode.includesTemperature }
  var showsFanStatusInMenuBar: Bool { menuBarDisplayMode.includesFan }
  var showsBatteryStatusInMenuBar: Bool { menuBarDisplayMode.includesBattery }

  func setShowsSensorStatusInMenuBar(_ enabled: Bool) {
    setMenuBarComponents(temperature: enabled)
  }

  func setShowsFanStatusInMenuBar(_ enabled: Bool) {
    setMenuBarComponents(fan: enabled)
  }

  func setShowsBatteryStatusInMenuBar(_ enabled: Bool) {
    setMenuBarComponents(battery: enabled)
  }

  func setShowsHotspotMenuAlert(_ enabled: Bool) {
    showsHotspotMenuAlert = enabled
    preferences.set(enabled, forKey: Self.hotspotMenuAlertKey)
  }

  func setShowsBatteryMenuAlert(_ enabled: Bool) {
    showsBatteryMenuAlert = enabled
    preferences.set(enabled, forKey: Self.batteryMenuAlertKey)
  }

  func setBatteryAlertThreshold(_ value: Double) {
    batteryAlertThreshold = min(
      max(value, BatteryTemperaturePreferences.alertRange.lowerBound),
      BatteryTemperaturePreferences.alertRange.upperBound)
    preferences.set(batteryAlertThreshold, forKey: Self.batteryAlertThresholdKey)
  }

  func setBatteryCurveEnabled(_ enabled: Bool) {
    guard enabled != isBatteryCurveEnabled else { return }
    isBatteryCurveEnabled = enabled
    preferences.set(enabled, forKey: Self.batteryCurveEnabledKey)
    Task { await refresh() }
  }

  func setBatteryCurveThreshold(_ value: Double) {
    batteryCurveThreshold = min(
      max(value, BatteryFanPolicy.thresholdRange.lowerBound),
      BatteryFanPolicy.thresholdRange.upperBound)
    preferences.set(batteryCurveThreshold, forKey: Self.batteryCurveThresholdKey)
  }

  func setFanAccelerationFactor(_ value: Double) {
    fanAccelerationFactor = FanAccelerationProfile.clamp(value)
    preferences.set(fanAccelerationFactor, forKey: Self.fanAccelerationFactorKey)
    Task { await refresh() }
  }

  func setPopoverTab(_ tab: PopoverTab) {
    selectedPopoverTab = tab
  }

  func setTemperatureSource(_ source: CPUTemperatureSource) {
    guard source != temperatureSource else { return }
    temperatureSource = source
    temperatureFilter.reset()
    preferences.set(source.rawValue, forKey: Self.temperatureSourceKey)
    Task { await refresh() }
  }

  func setSamplingIntervalOption(_ option: SamplingIntervalOption) {
    guard option != samplingIntervalOption else { return }
    samplingIntervalOption = option
    preferences.set(option.rawValue, forKey: Self.samplingIntervalKey)
    dashboardRefreshCountdown = 0
    guard pollIntervalOverride == nil else { return }
    if timer != nil {
      timer?.invalidate()
      timer = nil
      scheduleTimer()
    }
    if state == .monitoring, isFanless {
      statusText = "此设备没有可控风扇；每 \(Int(samplingInterval)) 秒监控温度与提醒"
    } else if state == .monitoring {
      statusText = "每 \(Int(samplingInterval)) 秒更新一次"
    }
  }

  func setBatteryChargeLimitEnabled(_ enabled: Bool) {
    batteryChargeLimitEnabled = enabled
    preferences.set(enabled, forKey: Self.batteryChargeLimitEnabledKey)
    Task { await applyBatteryChargeLimit() }
  }

  func setBatteryChargeLimitPercent(_ value: Int) {
    batteryChargeLimitPercent = min(100, max(80, value))
    preferences.set(batteryChargeLimitPercent, forKey: Self.batteryChargeLimitPercentKey)
    guard batteryChargeLimitEnabled else { return }
    Task { await applyBatteryChargeLimit() }
  }

  func start() {
    guard !hasStarted else { return }
    hasStarted = true
    scheduleTimer()
    Task { await refresh() }
  }

  func setThreshold(_ value: Double) {
    thresholdCelsius = min(
      max(value, FanSafetyPolicy.thresholdRange.lowerBound),
      FanSafetyPolicy.thresholdRange.upperBound)
    preferences.set(thresholdCelsius, forKey: Self.thresholdKey)
  }

  func setControlEnabled(_ enabled: Bool) {
    guard enabled != isControlEnabled else { return }
    guard !isFanless else {
      isControlEnabled = false
      statusText = "此设备没有可控风扇；仅监控温度与提醒"
      return
    }
    if enabled, !helperManager.isReady {
      helperManager.enable()
      statusText = "请先启用 FanBar 特权控制组件"
      return
    }
    isControlEnabled = enabled
    preferences.set(enabled, forKey: Self.enabledKey)
    Task {
      if enabled {
        await refresh()
      } else {
        await restoreForSafety(
          successState: .monitoring,
          successMessage: "仅监控；风扇由 macOS 控制")
      }
    }
  }

  func refresh() async {
    guard !isRefreshing, !isSuspended else { return }
    isRefreshing = true
    defer { isRefreshing = false }

    do {
      let cycle = try await sampleAndPublish()
      guard !isSuspended else { return }
      if needsRecovery {
        logger.notice("restore requested reason=unfinished-session")
        try await service.restoreAutomatic()
        setSessionActive(false)
        targetRPMs = []
        state = .automatic
        statusText = "已恢复上次会话；风扇由 macOS 自动控制"
        return
      }

      guard hasControllableFans else {
        targetRPMs = []
        state = .monitoring
        statusText = "此设备没有可控风扇；正在监控温度与提醒"
        return
      }

      let integrity = await service.reconcileManualControl(snapshot: cycle.raw)
      if integrity == .partial {
        logger.error("manual ownership partially lost; restoring all fans")
        try await service.restoreAutomatic()
        setSessionActive(false)
        targetRPMs = []
        state = .automatic
        statusText = "检测到风扇控制权不一致；已整组交还 macOS"
        return
      }
      if integrity == .lost {
        logger.notice("manual ownership lost to macOS; deferring takeover")
        setSessionActive(false)
        targetRPMs = []
        state = .automatic
        statusText = "macOS 已收回风扇控制；本周期不再争抢"
        return
      }
      if integrity == .external {
        targetRPMs = []
        state = .automatic
        statusText = "检测到其他进程正在控制风扇；FanBar 保持监控"
        return
      }
      let currentlyManual = integrity == .intact
      guard isControlEnabled else {
        if currentlyManual {
          logger.notice("restore requested reason=control-disabled")
          try await service.restoreAutomatic()
        }
        targetRPMs = []
        state = .monitoring
        statusText = "每 \(Int(samplingInterval)) 秒更新一次"
        return
      }

      let outcome = controlLoop.evaluate(
        snapshot: cycle.filtered,
        rawCPUTemperature: cycle.raw.temperature,
        rawBatteryTemperature: cycle.raw.batteryTemperature,
        configuration: controlConfiguration,
        wasManual: currentlyManual,
        previousTargets: targetRPMs)
      try await applyControlOutcome(outcome, snapshot: cycle.raw)
    } catch {
      await handleControlCycleError(error)
    }
  }

  private struct ControlCycleSample {
    let raw: FanSnapshot
    let filtered: FanSnapshot
  }

  private var controlConfiguration: FanControlLoop.Configuration {
    FanControlLoop.Configuration(
      cpuThreshold: thresholdCelsius,
      batteryCurveEnabled: isBatteryCurveEnabled,
      batteryThreshold: batteryCurveThreshold,
      accelerationFactor: fanAccelerationFactor,
      interval: samplingInterval)
  }

  private func sampleAndPublish() async throws -> ControlCycleSample {
    helperManager.refresh()
    let raw = try await service.sample(source: temperatureSource)
    let filteredTemperature = temperatureFilter.record(raw.temperature)
    let filteredBatteryTemperature = raw.batteryTemperature.map {
      batteryTemperatureFilter.record($0)
    }
    let filtered = FanSnapshot(
      temperature: filteredTemperature,
      hotspotTemperature: raw.hotspotTemperature,
      hotspotSource: raw.hotspotSource,
      batteryTemperature: filteredBatteryTemperature,
      batterySource: raw.batterySource,
      power: raw.power,
      fans: raw.fans)

    currentTemperature = filteredTemperature
    currentHotspotTemperature = raw.hotspotTemperature
    currentHotspotSource = raw.hotspotSource
    currentBatteryTemperature = filteredBatteryTemperature
    currentBatterySource = raw.batterySource
    currentPower = raw.power
    updatePowerConnectionNotice(raw.power)
    fanReadings = raw.fans
    updateFanCapability(hasControllableFans: !raw.fans.isEmpty)
    await refreshSupplementaryTelemetryIfNeeded()
    return ControlCycleSample(raw: raw, filtered: filtered)
  }

  private func refreshSupplementaryTelemetryIfNeeded() async {
    guard dashboardRefreshCountdown <= 0 else {
      dashboardRefreshCountdown -= 1
      return
    }
    do {
      temperatureDashboard = try await service.temperatureDashboard()
    } catch {
      logger.debug("dashboard refresh skipped: \(error.localizedDescription, privacy: .public)")
    }
    do {
      let limitState = try await service.batteryChargeLimitState()
      batteryChargeLimitState = limitState
      if limitState.isSupported {
        batteryChargeLimitEnabled = limitState.isEnabled
        if let upper = limitState.upperPercent, (80...100).contains(upper) {
          batteryChargeLimitPercent = upper
        }
      }
    } catch {
      logger.debug("charge-limit refresh skipped: \(error.localizedDescription, privacy: .public)")
    }
    dashboardRefreshCountdown = 5
  }

  private func applyControlOutcome(
    _ outcome: FanControlLoop.Outcome, snapshot: FanSnapshot
  ) async throws {
    switch outcome {
    case .automatic(let curveAboveThreshold):
      targetRPMs = []
      state = .automatic
      statusText =
        curveAboveThreshold
        ? "macOS 当前目标已不低于曲线；保持系统控制"
        : "低于设定温度；风扇由 macOS 自动控制"

    case .confirmingCooldown(let sampleCount):
      logger.notice(
        "cool sample temperature=\(snapshot.temperature, privacy: .public) count=\(sampleCount, privacy: .public)"
      )
      state = .manual
      statusText = "正在确认温度已稳定下降，再交还 macOS 控制"

    case .releaseToAutomatic:
      logger.notice("restore requested reason=stable-cooldown")
      try await service.restoreAutomatic()
      setSessionActive(false)
      targetRPMs = []
      state = .automatic
      statusText = "低于设定温度；风扇由 macOS 自动控制"

    case .manual(let command):
      setSessionActive(true)
      try await service.apply(targets: command.limitedTargets, snapshot: snapshot)
      logger.notice(
        "manual curve applied temperature=\(snapshot.temperature, privacy: .public) systemFloors=\(String(describing: self.controlLoop.capturedSystemFloors), privacy: .public) desired=\(String(describing: command.desiredTargets), privacy: .public) limited=\(String(describing: command.limitedTargets), privacy: .public)"
      )
      targetRPMs = command.limitedTargets
      state = .manual
      statusText =
        if command.cpuEmergency {
          "CPU 紧急散热：已请求最大转速"
        } else if command.batteryEmergency {
          "电池区域紧急散热：已请求最大转速"
        } else if command.batteryDominant {
          "电池区域风扇曲线正在运行"
        } else {
          "CPU 智能风扇曲线正在运行"
        }
    }
  }

  private func handleControlCycleError(_ error: Error) async {
    logger.error("control cycle failed: \(error.localizedDescription, privacy: .public)")
    let hadManualControl = await service.isManual() || needsRecovery
    let restoreError = await attemptSafetyRestore()
    targetRPMs = []
    if isPermissionDenied(error) {
      isControlEnabled = false
      preferences.set(false, forKey: Self.enabledKey)
      if let restoreError {
        state = .error
        statusText = "macOS 拒绝风扇控制。警告：\(restoreError.localizedDescription)"
      } else {
        state = .monitoring
        statusText = "此 Mac 不允许风扇控制；已切换为仅监控"
      }
    } else if isHelperUnavailable(error) {
      isControlEnabled = false
      preferences.set(false, forKey: Self.enabledKey)
      state = .monitoring
      statusText = "特权控制组件不可用；已切换为仅监控"
    } else if let restoreError {
      state = .error
      statusText = "\(error.localizedDescription). ALERT: \(restoreError.localizedDescription)"
    } else if hadManualControl {
      state = .error
      statusText = "\(error.localizedDescription). Restored system control."
    } else {
      state = .error
      statusText = error.localizedDescription
    }
    logger.notice(
      "control state=\(self.state.label, privacy: .public) status=\(self.statusText, privacy: .public)"
    )
  }

  func suspend() async {
    isSuspended = true
    temperatureFilter.reset()
    batteryTemperatureFilter.reset()
    timer?.invalidate()
    timer = nil
    await restoreForSafety(
      successState: .suspended,
      successMessage: "睡眠前已恢复系统自动控制")
  }

  func resume() {
    isSuspended = false
    scheduleTimer()
    Task { await refresh() }
  }

  func shutdown() async -> Bool {
    isSuspended = true
    temperatureFilter.reset()
    batteryTemperatureFilter.reset()
    timer?.invalidate()
    timer = nil
    powerConnectionNoticeTask?.cancel()
    powerConnectionNoticeTask = nil
    powerConnectionNoticeUntil = nil
    state = .suspended
    statusText = "正在退出并交还 macOS 风扇控制…"
    if let error = await attemptSafetyRestore() {
      state = .error
      statusText = "警告：无法恢复系统控制，已取消退出。\(error.localizedDescription)"
      isSuspended = false
      scheduleTimer()
      return false
    }
    targetRPMs = []
    await service.close()
    return true
  }

  private func scheduleTimer() {
    guard timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: samplingInterval, repeats: true) {
      [weak self] _ in
      Task { @MainActor [weak self] in await self?.refresh() }
    }
  }

  private func restoreForSafety(successState: ControlState, successMessage: String) async {
    if let error = await attemptSafetyRestore() {
      state = .error
      statusText = "警告：\(error.localizedDescription)"
    } else {
      setSessionActive(false)
      targetRPMs = []
      state = successState
      statusText = successMessage
    }
  }

  private func attemptSafetyRestore() async -> Error? {
    guard await service.isManual() || needsRecovery else { return nil }
    logger.notice("restore requested reason=safety-fallback")
    var lastError: Error?
    for attempt in 0..<3 {
      do {
        try await service.restoreAutomatic()
        setSessionActive(false)
        return nil
      } catch {
        lastError = error
        if attempt < 2 { try? await Task.sleep(for: .milliseconds(150)) }
      }
    }
    return lastError
  }

  private func setSessionActive(_ active: Bool) {
    // needsRecovery represents a session inherited from a previous process.
    // The current process tracks live ownership through FanService.manualFans.
    if !active {
      needsRecovery = false
      controlLoop.reset()
    }
    preferences.set(active, forKey: Self.activeSessionKey)
  }

  private func isPermissionDenied(_ error: Error) -> Bool {
    (error as? SMCClient.SMCError)?.isPermissionDenied == true
  }

  private func isHelperUnavailable(_ error: Error) -> Bool {
    (error as? FanBarHelperError)?.isConnectionFailure == true
  }

  private func updateFanCapability(hasControllableFans: Bool) {
    let detected: FanCapability = hasControllableFans ? .available : .unavailable
    guard fanCapability != detected else { return }
    fanCapability = detected

    if hasControllableFans {
      if !didConfigureHelperForCapability {
        didConfigureHelperForCapability = true
        helperManager.enableIfNeeded()
      }
    } else {
      isControlEnabled = false
      targetRPMs = []
      if menuBarDisplayMode.includesFan { setMenuBarComponents(fan: false) }
    }
  }

  private func updatePowerConnectionNotice(_ power: PowerReading?) {
    guard let connected = power?.isExternalPowerConnected else { return }
    if PowerConnectionNotice.didConnect(
      previous: previousExternalPowerConnected, current: connected)
    {
      powerConnectionNoticeTask?.cancel()
      powerConnectionNoticeUntil = Date().addingTimeInterval(PowerConnectionNotice.duration)
      powerConnectionNoticeTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(PowerConnectionNotice.duration))
        guard !Task.isCancelled else { return }
        self?.powerConnectionNoticeUntil = nil
        self?.powerConnectionNoticeTask = nil
      }
    } else if !connected {
      powerConnectionNoticeTask?.cancel()
      powerConnectionNoticeTask = nil
      powerConnectionNoticeUntil = nil
    }
    previousExternalPowerConnected = connected
  }

  private static func powerText(_ value: Double?) -> String {
    guard let value else { return "-- W" }
    return String(format: "%.1f W", value)
  }

  private func setMenuBarComponents(
    temperature: Bool? = nil, fan: Bool? = nil, battery: Bool? = nil
  ) {
    setMenuBarDisplayMode(
      MenuBarDisplayMode.compose(
        temperature: temperature ?? menuBarDisplayMode.includesTemperature,
        fan: fan ?? menuBarDisplayMode.includesFan,
        battery: battery ?? menuBarDisplayMode.includesBattery))
  }

  private func applyBatteryChargeLimit() async {
    do {
      try await service.setBatteryChargeLimit(
        enabled: batteryChargeLimitEnabled, upperPercent: batteryChargeLimitPercent)
      batteryChargeLimitState = try await service.batteryChargeLimitState()
      batteryChargeLimitError = nil
    } catch {
      batteryChargeLimitError = error.localizedDescription
      if batteryChargeLimitEnabled { batteryChargeLimitEnabled = false }
    }
  }
}
