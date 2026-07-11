import FanBarHardware
import Foundation
import OSLog

@MainActor
final class FanController: ObservableObject {
  private let logger = Logger(subsystem: "local.fanbar", category: "control")
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
  @Published private(set) var temperatureDashboard = TemperatureDashboard.empty
  @Published private(set) var fanReadings: [FanReading] = []
  @Published private(set) var targetRPMs: [Double] = []
  @Published private(set) var state: ControlState = .starting
  @Published private(set) var statusText = "正在连接 AppleSMC…"
  @Published private(set) var menuBarDisplayMode: MenuBarDisplayMode
  @Published private(set) var temperatureSource: CPUTemperatureSource
  @Published private(set) var selectedPopoverTab: PopoverTab = .sensors
  let helperManager: PrivilegedHelperManager

  private static let thresholdKey = "thresholdCelsius"
  private static let enabledKey = "controlEnabled"
  private static let activeSessionKey = "ownsActiveManualSession"
  private static let menuBarDisplayKey = "menuBarDisplayMode"
  private static let temperatureSourceKey = "temperatureSource"
  private let service: FanService
  private let policy: FanSafetyPolicy
  private let slewLimiter: FanTargetSlewLimiter
  private let pollInterval: TimeInterval
  private var timer: Timer?
  private var isRefreshing = false
  private var hasStarted = false
  private var isSuspended = false
  private var needsRecovery: Bool
  private var consecutiveCoolSamples = 0
  private var temperatureFilter = TemperatureSafetyFilter()
  private var dashboardRefreshCountdown = 0

  init(
    service: FanService = FanService(),
    policy: FanSafetyPolicy = FanSafetyPolicy(),
    slewLimiter: FanTargetSlewLimiter = FanTargetSlewLimiter(),
    pollInterval: TimeInterval = 2,
    helperManager: PrivilegedHelperManager = PrivilegedHelperManager()
  ) {
    self.service = service
    self.policy = policy
    self.slewLimiter = slewLimiter
    self.pollInterval = pollInterval
    self.helperManager = helperManager

    let defaults = UserDefaults.standard
    let savedThreshold = defaults.object(forKey: Self.thresholdKey) as? Double
    thresholdCelsius = min(
      max(
        savedThreshold ?? FanSafetyPolicy.defaultThreshold,
        FanSafetyPolicy.thresholdRange.lowerBound),
      FanSafetyPolicy.thresholdRange.upperBound)
    // Upgrades retain the prior user's intent. Fresh installs start in
    // monitor-only mode until the user explicitly enables hardware writes.
    isControlEnabled =
      (defaults.object(forKey: Self.enabledKey) as? Bool ?? false)
      && helperManager.isReady
    needsRecovery = defaults.bool(forKey: Self.activeSessionKey)
    menuBarDisplayMode =
      MenuBarDisplayMode(
        rawValue: defaults.string(forKey: Self.menuBarDisplayKey) ?? "") ?? .temperature
    temperatureSource =
      CPUTemperatureSource(
        rawValue: defaults.string(forKey: Self.temperatureSourceKey) ?? "") ?? .package
  }

  var temperatureText: String {
    currentTemperature.map { "\(Int($0.rounded()))°C" } ?? "--°C"
  }

  var fanText: String {
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
    let temperature = currentTemperature.map { "\(Int($0.rounded()))°" } ?? "--°"
    let averageRPM =
      fanReadings.isEmpty
      ? nil
      : fanReadings.map(\.actualRPM).reduce(0, +) / Double(fanReadings.count)
    let rpm =
      averageRPM.map { value in
        value >= 1_000 ? String(format: "%.1fk", value / 1_000) : "\(Int(value.rounded()))"
      } ?? "--"
    return switch menuBarDisplayMode {
    case .iconOnly: ""
    case .temperature: temperature
    case .fanSpeed: rpm
    case .temperatureAndFan: "\(temperature)  \(rpm)"
    }
  }

  var curvePercent: Int? {
    guard let currentTemperature,
      let fraction = policy.curveFraction(
        temperature: currentTemperature, threshold: thresholdCelsius)
    else { return nil }
    return Int((fraction * 100).rounded())
  }

  var preferredPopoverHeight: Double {
    let groupCount = TemperatureSensorGroup.make(from: temperatureDashboard.readings).count
    return selectedPopoverTab.preferredHeight(sensorGroupCount: groupCount)
  }

  func setMenuBarDisplayMode(_ mode: MenuBarDisplayMode) {
    menuBarDisplayMode = mode
    UserDefaults.standard.set(mode.rawValue, forKey: Self.menuBarDisplayKey)
  }

  func setPopoverTab(_ tab: PopoverTab) {
    selectedPopoverTab = tab
  }

  func setTemperatureSource(_ source: CPUTemperatureSource) {
    guard source != temperatureSource else { return }
    temperatureSource = source
    temperatureFilter.reset()
    UserDefaults.standard.set(source.rawValue, forKey: Self.temperatureSourceKey)
    Task { await refresh() }
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
    UserDefaults.standard.set(thresholdCelsius, forKey: Self.thresholdKey)
  }

  func setControlEnabled(_ enabled: Bool) {
    guard enabled != isControlEnabled else { return }
    if enabled, !helperManager.isReady {
      helperManager.enable()
      statusText = "请先启用 FanBar 特权控制组件"
      return
    }
    isControlEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
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
      helperManager.refresh()
      let rawSnapshot = try await service.sample(source: temperatureSource)
      guard !isSuspended else { return }
      let filteredTemperature = temperatureFilter.record(rawSnapshot.temperature)
      let snapshot = FanSnapshot(
        temperature: filteredTemperature, hotspotTemperature: rawSnapshot.hotspotTemperature,
        fans: rawSnapshot.fans)
      currentTemperature = filteredTemperature
      currentHotspotTemperature = rawSnapshot.hotspotTemperature
      fanReadings = rawSnapshot.fans
      if dashboardRefreshCountdown <= 0 {
        if let dashboard = try? await service.temperatureDashboard() {
          temperatureDashboard = dashboard
        }
        dashboardRefreshCountdown = 5
      } else {
        dashboardRefreshCountdown -= 1
      }

      if needsRecovery {
        logger.notice("restore requested reason=unfinished-session")
        try await service.restoreAutomatic()
        setSessionActive(false)
      }

      guard isControlEnabled else {
        if await service.isManual() {
          logger.notice("restore requested reason=control-disabled")
          try await service.restoreAutomatic()
        }
        targetRPMs = []
        state = .monitoring
        statusText = "每 \(Int(pollInterval)) 秒更新一次"
        return
      }

      let wasManual = await service.isManual()
      switch policy.decision(for: snapshot, threshold: thresholdCelsius, wasManual: wasManual) {
      case .automatic:
        if wasManual {
          consecutiveCoolSamples += 1
          logger.notice(
            "cool sample temperature=\(snapshot.temperature, privacy: .public) count=\(self.consecutiveCoolSamples, privacy: .public)"
          )
          if consecutiveCoolSamples < 3 {
            state = .manual
            statusText = "正在确认温度已稳定下降，再交还 macOS 控制"
            return
          }
          logger.notice("restore requested reason=stable-cooldown")
          try await service.restoreAutomatic()
          setSessionActive(false)
        }
        consecutiveCoolSamples = 0
        targetRPMs = []
        state = .automatic
        statusText = "低于设定温度；风扇由 macOS 自动控制"
      case .manual(let targets):
        consecutiveCoolSamples = 0
        setSessionActive(true)
        let limitedTargets = slewLimiter.limit(
          desired: targets, previous: targetRPMs, fans: snapshot.fans,
          interval: pollInterval, bypass: policy.isEmergency(snapshot))
        try await service.apply(targets: limitedTargets, snapshot: snapshot)
        logger.notice(
          "manual curve applied temperature=\(snapshot.temperature, privacy: .public) desired=\(String(describing: targets), privacy: .public) limited=\(String(describing: limitedTargets), privacy: .public)"
        )
        targetRPMs = limitedTargets
        state = .manual
        statusText =
          snapshot.temperature >= policy.emergencyTemperature
            || (snapshot.hotspotTemperature ?? 0) >= policy.emergencyHotspotTemperature
          ? "紧急散热：已请求最大转速"
          : "智能风扇曲线正在运行"
      }
    } catch {
      logger.error("control cycle failed: \(error.localizedDescription, privacy: .public)")
      let hadManualControl = await service.isManual() || needsRecovery
      let restoreError = await attemptSafetyRestore()
      targetRPMs = []
      if isPermissionDenied(error) {
        isControlEnabled = false
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        if let restoreError {
          state = .error
          statusText = "macOS 拒绝风扇控制。警告：\(restoreError.localizedDescription)"
        } else {
          state = .monitoring
          statusText = "此 Mac 不允许风扇控制；已切换为仅监控"
        }
      } else if isHelperUnavailable(error) {
        isControlEnabled = false
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
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
  }

  func suspend() async {
    isSuspended = true
    temperatureFilter.reset()
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
    timer?.invalidate()
    timer = nil
    if let error = await attemptSafetyRestore() {
      state = .error
      statusText = "警告：无法恢复系统控制，已取消退出。\(error.localizedDescription)"
      isSuspended = false
      scheduleTimer()
      return false
    }
    await service.close()
    return true
  }

  private func scheduleTimer() {
    guard timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
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
    if !active { needsRecovery = false }
    UserDefaults.standard.set(active, forKey: Self.activeSessionKey)
  }

  private func isPermissionDenied(_ error: Error) -> Bool {
    (error as? SMCClient.SMCError)?.isPermissionDenied == true
  }

  private func isHelperUnavailable(_ error: Error) -> Bool {
    (error as? FanBarHelperError)?.isConnectionFailure == true
  }
}
