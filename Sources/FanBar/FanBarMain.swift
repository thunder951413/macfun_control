import AppKit
import Combine
import FanBarHardware
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let controller = FanController()
  private var statusItem: NSStatusItem!
  private let popover = NSPopover()
  private var isTerminating = false
  private var sleepObserver: NSObjectProtocol?
  private var wakeObserver: NSObjectProtocol?
  private var statusObserver: AnyCancellable?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = statusItem.button {
      button.action = #selector(togglePopover)
      button.target = self
    }
    statusObserver = controller.objectWillChange.sink { [weak self] in
      DispatchQueue.main.async {
        self?.updateStatusItem()
        self?.updatePopoverSize()
      }
    }
    updateStatusItem()

    popover.behavior = .transient
    popover.contentSize = NSSize(width: 520, height: controller.preferredPopoverHeight)
    popover.contentViewController = NSHostingController(
      rootView: FanPopoverView(controller: controller))

    controller.helperManager.enableIfNeeded()
    controller.start()
    sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in await self?.controller.suspend() }
    }
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.controller.resume() }
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !isTerminating else { return .terminateNow }
    isTerminating = true
    Task { @MainActor in
      let restored = await controller.shutdown()
      if !restored { isTerminating = false }
      NSApp.reply(toApplicationShouldTerminate: restored)
    }
    return .terminateLater
  }

  func applicationWillTerminate(_ notification: Notification) {
    if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
  }

  @objc private func togglePopover() {
    guard let button = statusItem.button else { return }
    if popover.isShown {
      popover.performClose(nil)
    } else {
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      popover.contentViewController?.view.window?.makeKey()
    }
  }

  private func updateStatusItem() {
    guard let button = statusItem?.button else { return }
    let description =
      controller.state == .manual ? "FanBar 正在加速风扇" : "FanBar 系统自动风扇"
    let image =
      NSImage(
        systemSymbolName: controller.state.menuBarSymbolName,
        accessibilityDescription: description)
      ?? NSImage(systemSymbolName: "fan", accessibilityDescription: description)
    image?.isTemplate = true
    button.image = image
    button.title = controller.menuBarText
    button.imagePosition = controller.menuBarText.isEmpty ? .imageOnly : .imageLeading
    button.toolTip = "FanBar · CPU \(controller.temperatureText) · \(controller.fanText)"
  }

  private func updatePopoverSize() {
    let desiredSize = NSSize(width: 520, height: controller.preferredPopoverHeight)
    guard popover.contentSize != desiredSize else { return }
    popover.contentSize = desiredSize
  }
}

@main
struct FanBarMain {
  @MainActor
  static func main() {
    if runCommandLineUtilityIfRequested() { return }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
  }

  @MainActor
  private static func runCommandLineUtilityIfRequested() -> Bool {
    let arguments = ProcessInfo.processInfo.arguments
    let service = SMAppService.daemon(plistName: FanBarHelperConstants.plistName)
    if arguments.contains("--helper-status") {
      print("helper-status=\(service.status.rawValue)")
      return true
    }
    if arguments.contains("--register-helper") {
      do {
        try service.register()
        print("helper-status=\(service.status.rawValue)")
      } catch {
        print("register-error=\(error)")
        print("helper-status=\(service.status.rawValue)")
        exit(EXIT_FAILURE)
      }
      return true
    }
    if arguments.contains("--unregister-helper") {
      do {
        try service.unregister()
        print("helper-status=\(service.status.rawValue)")
      } catch {
        print("unregister-error=\(error)")
        exit(EXIT_FAILURE)
      }
      return true
    }
    if arguments.contains("--helper-ping") {
      do {
        try PrivilegedFanClient().ping()
        print("helper=ready")
      } catch {
        print("helper-error=\(error.localizedDescription)")
        exit(EXIT_FAILURE)
      }
      return true
    }
    if arguments.contains("--helper-self-test") {
      if !runHelperSelfTest() { exit(EXIT_FAILURE) }
      return true
    }
    if arguments.contains("--smc-diagnostics") {
      runSMCDiagnostics()
      return true
    }
    if arguments.contains("--temperature-diagnostics") {
      runTemperatureDiagnostics()
      return true
    }
    if arguments.contains("--helper-restore") {
      if !runHelperRestore() { exit(EXIT_FAILURE) }
      return true
    }
    return false
  }

  private static func runHelperSelfTest() -> Bool {
    let smc = SMCClient()
    let helper = PrivilegedFanClient()
    var manualFans: [Int] = []
    defer {
      for fan in manualFans { try? helper.setAutomaticMode(fan: fan) }
      try? helper.resetControlOverride()
      smc.close()
    }

    do {
      try smc.open()
      let count = try smc.fanCount()
      let temperature = try smc.cpuTemperature()
      print("temperature=\(Int(temperature.rounded()))C fans=\(count)")
      for fan in 0..<count {
        let actual = try smc.fanActualRPM(fan: fan)
        let minimum = try smc.fanMinimumRPM(fan: fan)
        let maximum = try smc.fanMaximumRPM(fan: fan)
        let safeTarget = min(maximum, max(actual, minimum + (maximum - minimum) * 0.65))
        try helper.setManualMode(fan: fan)
        manualFans.append(fan)
        try helper.setTargetRPM(safeTarget, fan: fan)
        print("fan=\(fan) before=\(Int(actual)) target=\(Int(safeTarget))")
      }
      Thread.sleep(forTimeInterval: 2)
      for fan in 0..<count {
        print("fan=\(fan) observed=\(Int(try smc.fanActualRPM(fan: fan)))")
      }
      print("self-test=passed; restoring macOS automatic control")
      return true
    } catch {
      print("self-test-error=\(error.localizedDescription)")
      return false
    }
  }

  private static func runSMCDiagnostics() {
    let smc = SMCClient()
    do {
      try smc.open()
      defer { smc.close() }
      let count = try smc.fanCount()
      print("temperature=\(try smc.cpuTemperature()) fans=\(count)")
      for fan in 0..<count {
        print(
          "fan=\(fan) mode=\(try smc.fanMode(fan: fan)) actual=\(try smc.fanActualRPM(fan: fan)) target=\(try smc.fanTargetRPM(fan: fan)) min=\(try smc.fanMinimumRPM(fan: fan)) max=\(try smc.fanMaximumRPM(fan: fan))"
        )
      }
      print("override=\(try smc.controlOverrideActive())")
    } catch {
      print("diagnostic-error=\(error.localizedDescription)")
    }
  }

  private static func runTemperatureDiagnostics() {
    let smc = SMCClient()
    do {
      try smc.open()
      defer { smc.close() }
      for source in CPUTemperatureSource.allCases {
        print("source.\(source.rawValue)=\(String(format: "%.3f", try smc.cpuTemperature(source: source)))")
      }
      let readings = smc.temperatureReadings()
      for reading in readings {
        print("\(reading.key)=\(String(format: "%.3f", reading.value))")
      }
      print("-- all readable temperature keys --")
      for reading in smc.allTemperatureReadings() {
        print("\(reading.key)=\(String(format: "%.3f", reading.value))")
      }
    } catch {
      print("temperature-diagnostic-error=\(error.localizedDescription)")
    }
  }

  private static func runHelperRestore() -> Bool {
    let smc = SMCClient()
    let helper = PrivilegedFanClient()
    do {
      try smc.open()
      defer { smc.close() }
      let count = try smc.fanCount()
      for fan in 0..<count {
        try helper.setAutomaticMode(fan: fan)
        print("fan=\(fan) automatic=ok")
      }
      try helper.resetControlOverride()
      let deadline = Date().addingTimeInterval(6)
      while try smc.controlOverrideActive(), Date() < deadline {
        Thread.sleep(forTimeInterval: 0.2)
      }
      guard try !smc.controlOverrideActive() else {
        print("restore-error=Ftst remained enabled")
        return false
      }
      print("restore=passed")
      return true
    } catch {
      print("restore-error=\(error.localizedDescription)")
      return false
    }
  }
}
