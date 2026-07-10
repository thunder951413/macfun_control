import FanBarHardware
import Foundation
import ServiceManagement

@MainActor
final class PrivilegedHelperManager: ObservableObject {
  enum State: Equatable {
    case ready
    case notInstalled
    case approvalRequired
    case unavailable(String)

    var label: String {
      switch self {
      case .ready: "已就绪"
      case .notInstalled: "未启用"
      case .approvalRequired: "需要批准"
      case .unavailable: "不可用"
      }
    }
  }

  @Published private(set) var state: State = .notInstalled
  private let service = SMAppService.daemon(plistName: FanBarHelperConstants.plistName)

  init() {
    refresh()
  }

  var isReady: Bool { state == .ready }

  func enableIfNeeded() {
    refresh()
    if state == .notInstalled { enable() }
  }

  func refresh() {
    switch service.status {
    case .enabled: state = .ready
    case .requiresApproval: state = .approvalRequired
    case .notRegistered, .notFound: state = .notInstalled
    @unknown default: state = .unavailable("未知组件状态")
    }
  }

  func enable() {
    do {
      try service.register()
      refresh()
      if state == .approvalRequired { SMAppService.openSystemSettingsLoginItems() }
    } catch {
      refresh()
      if state == .notInstalled { state = .unavailable(error.localizedDescription) }
    }
  }

  func openApprovalSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }
}
