import SwiftUI
import FanBarHardware

struct FanPopoverView: View {
  @ObservedObject var controller: FanController
  @ObservedObject private var helperManager: PrivilegedHelperManager

  init(controller: FanController) {
    self.controller = controller
    helperManager = controller.helperManager
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
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
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
  }

  private var sensorTab: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        metrics
        temperatureOverview
        sensorTemperatures
      }
      .padding(18)
    }
  }

  private var settingsTab: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        menuBarSettings
        Divider()
        controls
        curvePreview
        Divider()
        safetyNote
      }
      .padding(18)
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
    VStack(spacing: 9) {
      HStack {
        Label("风扇状态", systemImage: "fan")
        Spacer()
        Text(controller.fanText).monospacedDigit()
      }
      HStack {
        Text("目标转速").foregroundStyle(.secondary)
        Spacer()
        Text(controller.targetText)
          .monospacedDigit()
          .foregroundStyle(controller.state == .manual ? .orange : .secondary)
      }
      .font(.caption)
    }
    .font(.callout)
  }

  private var temperatureOverview: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("主要温度", systemImage: "thermometer.medium")
          .font(.callout).fontWeight(.medium)
        Spacer()
        Text("控制依据：\(controller.temperatureSource.shortLabel)")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
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
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
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
    VStack(spacing: 10) {
      HStack {
        Label("菜单栏显示", systemImage: "menubar.rectangle")
        Spacer()
        Picker(
          "菜单栏显示",
          selection: Binding(
            get: { controller.menuBarDisplayMode },
            set: { controller.setMenuBarDisplayMode($0) }
          )
        ) {
          ForEach(MenuBarDisplayMode.allCases) { mode in Text(mode.label).tag(mode) }
        }
        .labelsHidden()
        .frame(width: 160)
      }
      HStack {
        Label("温度来源", systemImage: "cpu")
        Spacer()
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
        .frame(width: 160)
      }
    }
    .font(.callout)
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("特权控制组件", systemImage: "lock.shield")
        Spacer()
        Text(helperManager.state.label)
          .foregroundStyle(helperManager.isReady ? .green : .orange)
        if !helperManager.isReady {
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
      .font(.caption)

      Toggle(
        "启用智能风扇曲线",
        isOn: Binding(
          get: { controller.isControlEnabled },
          set: { controller.setControlEnabled($0) }
        )
      )
      .toggleStyle(.switch)
      .disabled(!helperManager.isReady)

      VStack(alignment: .leading, spacing: 7) {
        HStack {
          Text("开始加速温度")
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
        Text("FanBar 只依据所选温度来源补充 macOS 控制。普通升速每 2 秒最多 500 rpm、降速最多 200 rpm；所选温度达到 90°C 时立即满速。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .disabled(!controller.isControlEnabled)
    }
  }

  private var curvePreview: some View {
    FanCurvePreview(
      threshold: controller.thresholdCelsius,
      currentTemperature: controller.currentTemperature,
      curvePercent: controller.curvePercent,
      isEnabled: controller.isControlEnabled)
  }

  private var safetyNote: some View {
    Label(
      "目标转速绝不会低于当前实际转速；传感器或控制异常时会恢复 macOS 自动控制。",
      systemImage: "shield.checkered"
    )
    .font(.caption)
    .foregroundStyle(.secondary)
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
        Text("\(group.readings.count) 个传感器")
          .font(.caption2).foregroundStyle(.secondary)
      }
      Spacer(minLength: 3)
      Text("\(Int(group.average.rounded()))°")
        .font(.caption.monospacedDigit()).fontWeight(.medium)
    }
    .padding(7)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
  }
}

private struct FanCurvePreview: View {
  let threshold: Double
  let currentTemperature: Double?
  let curvePercent: Int?
  let isEnabled: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(isEnabled ? "风扇调整预览" : "风扇调整预览（未启用）")
          .font(.callout).fontWeight(.medium)
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
          left + min(1, max(0, (temperature - 50) / 40)) * width
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
        curve.addLine(to: CGPoint(x: x(90), y: top))
        context.stroke(
          curve, with: .color(.orange), style: StrokeStyle(lineWidth: 3, lineCap: .round))

        if let currentTemperature {
          let fraction =
            currentTemperature <= threshold
            ? 0 : min(1, (currentTemperature - threshold) / max(1, 90 - threshold))
          let point = CGPoint(x: x(currentTemperature), y: y(fraction))
          context.fill(
            Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)),
            with: .color(.white))
          context.stroke(
            Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)),
            with: .color(.orange), lineWidth: 3)
        }
      }
      .frame(height: 92)
      .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))

      HStack {
        Text("50°C")
        Spacer()
        Text("\(Int(threshold))°C 开始")
        Spacer()
        Text("90°C 最大")
      }
      .font(.caption2.monospacedDigit())
      .foregroundStyle(.secondary)

      if let currentTemperature {
        if let curvePercent {
          Text(
            "\(isEnabled ? "当前控制" : "按当前设置")：\(Int(currentTemperature.rounded()))°C 时基础曲线约为最大转速的 \(curvePercent)%；若现有转速更高则不会降低。"
          )
        } else {
          Text("当前 \(Int(currentTemperature.rounded()))°C：低于设定温度，由 macOS 自动控制。")
        }
      }
    }
    .font(.caption)
  }
}
