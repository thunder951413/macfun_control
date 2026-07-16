import FanBarHardware
import SwiftUI

struct FanPopoverView: View {
  @ObservedObject var controller: FanController
  @ObservedObject private var helperManager: PrivilegedHelperManager
  @ObservedObject private var launchAtLoginManager: LaunchAtLoginManager

  init(controller: FanController) {
    self.controller = controller
    helperManager = controller.helperManager
    launchAtLoginManager = controller.launchAtLoginManager
  }

  private var stateColor: Color {
    switch controller.state {
    case .manual: .orange
    case .error: .red
    case .automatic: .green
    default: .secondary
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
        .padding(.horizontal, 20)
        .padding(.top, 17)
        .padding(.bottom, 12)
      Divider()
      TabView(
        selection: Binding(
          get: { controller.selectedPopoverTab },
          set: { controller.setPopoverTab($0) }
        )
      ) {
        sensorTab
          .tag(PopoverTab.sensors)
          .tabItem { Label("传感器", systemImage: "thermometer.medium") }
        settingsTab
          .tag(PopoverTab.settings)
          .tabItem { Label("设置", systemImage: "slider.horizontal.3") }
      }
    }
    .frame(width: 520, height: controller.preferredPopoverHeight)
    .onAppear {
      helperManager.refresh()
      launchAtLoginManager.refresh()
    }
  }

  private var sensorTab: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        if controller.isFanless {
          fanlessMonitorNotice
        } else {
          metrics
        }
        temperatureOverview
        sensorTemperatures
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 16)
    }
  }

  private var settingsTab: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        menuBarSettings
        batterySettings
        if controller.isFanless {
          fanlessSettingsNotice
        } else {
          controls
          curvePreview
          safetyNote
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 16)
    }
  }

  private var header: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 7) {
          Text("FanBar").font(.headline)
          Circle().fill(stateColor).frame(width: 7, height: 7)
          Text(controller.state.label).font(.caption).foregroundStyle(stateColor)
        }
        Text(controller.statusText)
          .font(.caption)
          .foregroundStyle(controller.state == .error ? .red : .secondary)
          .lineLimit(3)
      }
      Spacer()
      Button {
        NSApp.terminate(nil)
      } label: {
        Image(systemName: "power")
      }
      .buttonStyle(.borderless)
      .help("退出 FanBar")
      .accessibilityLabel("退出 FanBar")
    }
  }

  private var metrics: some View {
    HStack(spacing: 12) {
      Image(systemName: "fan")
        .font(.title3)
        .foregroundStyle(controller.state == .manual ? .orange : .secondary)
        .frame(width: 32, height: 32)
        .background(.quaternary.opacity(0.5), in: Circle())
      VStack(alignment: .leading, spacing: 3) {
        Text("风扇状态").fontWeight(.medium)
        Text("目标转速 · \(controller.targetText)")
          .font(.caption)
          .foregroundStyle(controller.state == .manual ? .orange : .secondary)
      }
      Spacer(minLength: 12)
      Text(controller.fanText)
        .font(.system(.callout, design: .rounded).monospacedDigit())
        .fontWeight(.semibold)
    }
    .padding(12)
    .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
    .font(.callout)
  }

  private var fanlessMonitorNotice: some View {
    HStack(spacing: 12) {
      Image(systemName: "thermometer.medium")
        .font(.title3)
        .foregroundStyle(.blue)
        .frame(width: 32, height: 32)
        .background(.blue.opacity(0.1), in: Circle())
      VStack(alignment: .leading, spacing: 3) {
        Text("无风扇设备").fontWeight(.medium)
        Text("FanBar 仅监控温度并提供高温提醒")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(12)
    .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
  }

  private var temperatureOverview: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Label("主要温度", systemImage: "thermometer.medium")
          .font(.callout).fontWeight(.medium)
        Spacer()
        Text("控制依据：\(controller.temperatureSource.shortLabel)")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8
      ) {
        TemperatureMetricCard(
          title: "CPU 封装", value: dashboardValue(.package),
          isControlSource: controller.temperatureSource == .package)
        TemperatureMetricCard(
          title: "核心平均", value: dashboardValue(.coreAverage),
          isControlSource: controller.temperatureSource == .coreAverage)
        TemperatureMetricCard(
          title: "最高热点", value: dashboardValue(.hotspot),
          isControlSource: controller.temperatureSource == .hotspot)
      }
    }
  }

  private var sensorTemperatures: some View {
    let groups = TemperatureSensorGroup.make(from: controller.temperatureDashboard.readings)
    return VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("其他传感器", systemImage: "sensor.tag.radiowaves.forward")
          .font(.callout).fontWeight(.medium)
        Spacer()
        Text("\(groups.flatMap(\.readings).count) 个有效读数")
          .font(.caption2).foregroundStyle(.secondary)
      }

      if groups.isEmpty {
        Text("正在读取 SMC 传感器…")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        LazyVGrid(
          columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8
        ) {
          ForEach(groups) { group in
            SensorGroupSummary(group: group)
          }
        }

      }
    }
  }

  private func dashboardValue(_ source: CPUTemperatureSource) -> Double? {
    if let value = controller.temperatureDashboard.value(for: source) { return value }
    if source == controller.temperatureSource { return controller.currentTemperature }
    if source == .hotspot { return controller.currentHotspotTemperature }
    return nil
  }

  private var menuBarSettings: some View {
    PopoverSection(title: "常规", symbol: "gearshape") {
      SettingRow(
        title: "菜单栏显示", subtitle: "选择图标旁显示的信息", symbol: "menubar.rectangle"
      ) {
        Picker(
          "菜单栏显示",
          selection: Binding(
            get: { controller.menuBarDisplayMode },
            set: { controller.setMenuBarDisplayMode($0) }
          )
        ) {
          ForEach(controller.availableMenuBarDisplayModes) { mode in Text(mode.label).tag(mode) }
        }
        .labelsHidden()
        .frame(width: 172)
      }
      SectionDivider()
      SettingRow(
        title: controller.isFanless ? "主要温度" : "控制温度",
        subtitle: controller.isFanless ? "菜单栏与监控状态使用的来源" : "智能曲线采用的温度来源",
        symbol: "cpu"
      ) {
        Picker(
          "温度来源",
          selection: Binding(
            get: { controller.temperatureSource },
            set: { controller.setTemperatureSource($0) }
          )
        ) {
          ForEach(CPUTemperatureSource.allCases) { source in Text(source.label).tag(source) }
        }
        .labelsHidden()
        .frame(width: 172)
      }
      SectionDivider()
      SettingRow(
        title: "高温热点提醒", subtitle: "超过 90°C 时在菜单栏以红色提示",
        symbol: "thermometer.high"
      ) {
        Toggle(
          "高温热点提醒",
          isOn: Binding(
            get: { controller.showsHotspotMenuAlert },
            set: { controller.setShowsHotspotMenuAlert($0) }
          )
        )
        .labelsHidden()
        .toggleStyle(.switch)
      }
      SectionDivider()
      SettingRow(
        title: "开机启动", subtitle: launchAtLoginSubtitle, symbol: "power"
      ) {
        HStack(spacing: 8) {
          if launchAtLoginManager.state == .approvalRequired {
            Button("去批准") { launchAtLoginManager.openApprovalSettings() }
              .controlSize(.small)
          }
          Toggle(
            "开机启动",
            isOn: Binding(
              get: { launchAtLoginManager.isEnabled },
              set: { launchAtLoginManager.setEnabled($0) }
            )
          )
          .labelsHidden()
          .toggleStyle(.switch)
          .disabled(launchAtLoginManager.state == .unavailable)
        }
      }
    }
  }

  private var batterySettings: some View {
    PopoverSection(title: "电池温度", symbol: "battery.75percent") {
      SettingRow(
        title: "当前区域最高温", subtitle: "三个电池区域传感器中的最高值", symbol: "sensor"
      ) {
        Text(controller.batteryTemperatureText)
          .font(.system(.callout, design: .rounded).monospacedDigit())
          .fontWeight(.semibold)
      }
      SectionDivider()
      SettingRow(
        title: "菜单栏高温提醒", subtitle: "超过阈值时显示电池图标和温度",
        symbol: "exclamationmark.triangle"
      ) {
        Toggle(
          "菜单栏高温提醒",
          isOn: Binding(
            get: { controller.showsBatteryMenuAlert },
            set: { controller.setShowsBatteryMenuAlert($0) }
          )
        )
        .labelsHidden()
        .toggleStyle(.switch)
      }
      SectionDivider()
      SettingRow(
        title: "提醒温度", subtitle: "可设置 30–50°C", symbol: "thermometer.medium"
      ) {
        BatteryTemperatureSlider(
          value: Binding(
            get: { controller.batteryAlertThreshold },
            set: { controller.setBatteryAlertThreshold($0) }
          ), range: BatteryTemperaturePreferences.alertRange)
      }
      .disabled(!controller.showsBatteryMenuAlert)
      if !controller.isFanless {
        SectionDivider()
        SettingRow(
          title: "影响风扇转速", subtitle: "与 CPU 曲线比较并采用较高目标", symbol: "fan"
        ) {
          Toggle(
            "影响风扇转速",
            isOn: Binding(
              get: { controller.isBatteryCurveEnabled },
              set: { controller.setBatteryCurveEnabled($0) }
            )
          )
          .labelsHidden()
          .toggleStyle(.switch)
        }
        SectionDivider()
        SettingRow(
          title: "曲线介入温度", subtitle: "超过后线性加速，50°C 达到最大转速",
          symbol: "chart.line.uptrend.xyaxis"
        ) {
          BatteryTemperatureSlider(
            value: Binding(
              get: { controller.batteryCurveThreshold },
              set: { controller.setBatteryCurveThreshold($0) }
            ), range: BatteryFanPolicy.thresholdRange)
        }
        .disabled(!controller.isBatteryCurveEnabled)
      }
    }
  }

  private var fanlessSettingsNotice: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "checkmark.shield")
        .foregroundStyle(.green)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 3) {
        Text("已启用纯监控模式").fontWeight(.medium)
        Text("未检测到可控风扇，因此风扇控制、转速显示和散热曲线已停用；温度监控与提醒保持可用。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
  }

  private var launchAtLoginSubtitle: String {
    if let error = launchAtLoginManager.errorMessage { return "设置失败：\(error)" }
    return switch launchAtLoginManager.state {
    case .disabled: "登录 macOS 后自动运行 FanBar"
    case .enabled: "已加入系统登录项"
    case .approvalRequired: "请在系统设置中允许后台项目"
    case .unavailable: "当前应用位置或签名不支持登录项"
    }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 12) {
      PopoverSection(title: "风扇控制", symbol: "fan") {
        SettingRow(
          title: "特权控制组件", subtitle: helperManager.state.label, symbol: "lock.shield"
        ) {
          if helperManager.isReady {
            Label("可用", systemImage: "checkmark.circle.fill")
              .font(.caption)
              .foregroundStyle(.green)
          } else {
            Button(helperManager.state == .approvalRequired ? "打开设置" : "启用") {
              if helperManager.state == .approvalRequired {
                helperManager.openApprovalSettings()
              } else {
                helperManager.enable()
              }
            }
            .controlSize(.small)
          }
        }
        SectionDivider()
        SettingRow(
          title: "智能风扇曲线", subtitle: "CPU 与电池曲线取较高转速目标",
          symbol: "chart.line.uptrend.xyaxis"
        ) {
          Toggle(
            "智能风扇曲线",
            isOn: Binding(
              get: { controller.isControlEnabled },
              set: { controller.setControlEnabled($0) }
            )
          )
          .labelsHidden()
          .toggleStyle(.switch)
          .disabled(!helperManager.isReady)
        }
      }

      VStack(alignment: .leading, spacing: 7) {
        HStack {
          Text("CPU 开始加速温度")
          Spacer()
          Text("\(Int(controller.thresholdCelsius.rounded()))°C")
            .font(.system(.title3, design: .rounded).monospacedDigit())
            .fontWeight(.semibold)
        }
        Slider(
          value: Binding(
            get: { controller.thresholdCelsius },
            set: { controller.setThreshold($0) }
          ), in: FanSafetyPolicy.thresholdRange, step: 1
        )
        .accessibilityLabel("开始加速温度")
        Text(
          "设为 40°C 可在轻中负载时更早持续散热。FanBar 只依据所选温度来源补充 macOS 控制；"
            + "普通升速每 2 秒最多 500 rpm、降速最多 200 rpm，达到 90°C 时立即满速。"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .padding(12)
      .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
      .disabled(!controller.isControlEnabled)

    }
  }

  private var curvePreview: some View {
    PopoverSection(title: "曲线预览", symbol: "chart.xyaxis.line") {
      FanCurvePreview(
        name: "CPU",
        threshold: controller.thresholdCelsius,
        currentTemperature: controller.currentTemperature,
        curvePercent: controller.curvePercent,
        domainMinimum: FanSafetyPolicy.thresholdRange.lowerBound,
        maximumTemperature: 90,
        color: .orange,
        isEnabled: controller.isControlEnabled)
      SectionDivider()
      FanCurvePreview(
        name: "电池区域",
        threshold: controller.batteryCurveThreshold,
        currentTemperature: controller.currentBatteryTemperature,
        curvePercent: controller.batteryCurvePercent,
        domainMinimum: BatteryFanPolicy.thresholdRange.lowerBound,
        maximumTemperature: BatteryFanPolicy.maximumTemperature,
        color: .cyan,
        isEnabled: controller.isControlEnabled && controller.isBatteryCurveEnabled)
    }
  }

  private var safetyNote: some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: "shield.checkered")
        .foregroundStyle(.green)
        .frame(width: 18)
      Text("目标转速绝不会低于当前实际转速；传感器或控制异常时会恢复 macOS 自动控制。")
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(11)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
  }
}

private struct TemperatureMetricCard: View {
  let title: String
  let value: Double?
  let isControlSource: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 4) {
        Text(title).font(.caption).foregroundStyle(.secondary)
        Spacer(minLength: 2)
        if isControlSource {
          Text("控制").font(.system(size: 9, weight: .semibold)).foregroundStyle(.orange)
        }
      }
      Text(value.map { "\(Int($0.rounded()))°C" } ?? "--°C")
        .font(.system(.title3, design: .rounded).monospacedDigit())
        .fontWeight(.semibold)
    }
    .padding(9)
    .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(isControlSource ? Color.orange.opacity(0.8) : .clear, lineWidth: 1)
    }
  }
}

private struct SensorGroupSummary: View {
  let group: TemperatureSensorGroup

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: group.category.symbol)
        .frame(width: 16).foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(group.category.label).font(.caption)
        Text(
          group.category == .battery
            ? "\(group.readings.count) 个传感器 · 最高" : "\(group.readings.count) 个传感器"
        )
        .font(.caption2).foregroundStyle(.secondary)
      }
      Spacer(minLength: 3)
      Text("\(Int(displayValue.rounded()))°")
        .font(.caption.monospacedDigit()).fontWeight(.medium)
    }
    .padding(7)
    .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
  }

  private var displayValue: Double {
    group.category == .battery ? group.maximum : group.average
  }
}

private struct PopoverSection<Content: View>: View {
  let title: String
  let symbol: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Label(title, systemImage: symbol)
        .font(.callout)
        .fontWeight(.semibold)
        .foregroundStyle(.primary)
      VStack(spacing: 0) {
        content
      }
      .padding(.horizontal, 12)
      .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .stroke(.separator.opacity(0.22), lineWidth: 0.5)
      }
    }
  }
}

private struct SettingRow<Control: View>: View {
  let title: String
  let subtitle: String
  let symbol: String
  @ViewBuilder let control: Control

  var body: some View {
    HStack(alignment: .center, spacing: 11) {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 24, height: 24)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.callout)
          .foregroundStyle(.primary)
        Text(subtitle)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      control
        .frame(width: 172, alignment: .trailing)
    }
    .frame(minHeight: 49)
  }
}

private struct SectionDivider: View {
  var body: some View {
    Divider().padding(.leading, 35)
  }
}

private struct BatteryTemperatureSlider: View {
  @Binding var value: Double
  let range: ClosedRange<Double>

  var body: some View {
    HStack(spacing: 7) {
      Slider(
        value: $value,
        in: range,
        step: 1
      )
      .accessibilityLabel("温度")
      Text("\(Int(value.rounded()))°C")
        .font(.caption.monospacedDigit())
        .frame(width: 34, alignment: .trailing)
    }
  }
}

private struct FanCurvePreview: View {
  let name: String
  let threshold: Double
  let currentTemperature: Double?
  let curvePercent: Int?
  let domainMinimum: Double
  let maximumTemperature: Double
  let color: Color
  let isEnabled: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text("\(name) · \(isEnabled ? "曲线已启用" : "曲线未启用")")
          .foregroundStyle(isEnabled ? color : .secondary)
        Spacer()
        if let currentTemperature {
          Text("当前 \(Int(currentTemperature.rounded()))°C").font(.caption).monospacedDigit()
        }
      }

      Canvas { context, size in
        let left = 18.0
        let right = size.width - 10
        let top = 10.0
        let bottom = size.height - 18
        let width = right - left
        let height = bottom - top
        func x(_ temperature: Double) -> Double {
          left
            + min(1, max(0, (temperature - domainMinimum) / (maximumTemperature - domainMinimum)))
            * width
        }
        func y(_ fraction: Double) -> Double { bottom - min(1, max(0, fraction)) * height }

        var grid = Path()
        grid.move(to: CGPoint(x: left, y: bottom))
        grid.addLine(to: CGPoint(x: right, y: bottom))
        grid.move(to: CGPoint(x: left, y: top))
        grid.addLine(to: CGPoint(x: right, y: top))
        context.stroke(grid, with: .color(.secondary.opacity(0.25)), lineWidth: 1)

        var curve = Path()
        curve.move(to: CGPoint(x: left, y: bottom))
        curve.addLine(to: CGPoint(x: x(threshold), y: bottom))
        curve.addLine(to: CGPoint(x: x(maximumTemperature), y: top))
        context.stroke(
          curve, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))

        if let currentTemperature {
          let fraction =
            currentTemperature <= threshold
            ? 0
            : min(1, (currentTemperature - threshold) / max(1, maximumTemperature - threshold))
          let point = CGPoint(x: x(currentTemperature), y: y(fraction))
          context.fill(
            Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)),
            with: .color(.white))
          context.stroke(
            Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)),
            with: .color(color), lineWidth: 3)
        }
      }
      .frame(height: 92)
      .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))

      HStack {
        Text("\(Int(domainMinimum))°C")
        Spacer()
        Text("\(Int(threshold))°C 开始")
        Spacer()
        Text("\(Int(maximumTemperature))°C 最大")
      }
      .font(.caption2.monospacedDigit())
      .foregroundStyle(.secondary)

      if let currentTemperature {
        if let curvePercent {
          Text(
            "\(isEnabled ? "当前控制" : "按当前设置")：\(Int(currentTemperature.rounded()))°C 时处于最低到最大转速区间的 \(curvePercent)%；若现有转速更高则不会降低。"
          )
        } else {
          Text("当前 \(Int(currentTemperature.rounded()))°C：低于设定温度，由 macOS 自动控制。")
        }
      }
    }
    .font(.caption)
  }
}
