import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginManager: ObservableObject {
  enum State: Equatable {
    case disabled
    case enabled
    case approvalRequired
    case unavailable

    var label: String {
      switch self {
      case .disabled: "已关闭"
      case .enabled: "已开启"
      case .approvalRequired: "需要系统批准"
      case .unavailable: "不可用"
      }
    }
  }

  @Published private(set) var state: State = .disabled
  @Published private(set) var errorMessage: String?

  private let service: SMAppService

  init(service: SMAppService = .mainApp) {
    self.service = service
    refresh()
  }

  var isEnabled: Bool {
    state == .enabled || state == .approvalRequired
  }

  func refresh() {
    state = Self.state(for: service.status)
  }

  func setEnabled(_ enabled: Bool) {
    errorMessage = nil
    do {
      if enabled {
        guard service.status == .notRegistered else {
          refresh()
          return
        }
        try service.register()
      } else {
        guard service.status != .notRegistered else {
          refresh()
          return
        }
        try service.unregister()
      }
    } catch {
      errorMessage = error.localizedDescription
    }
    refresh()
  }

  func openApprovalSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }

  static func state(for status: SMAppService.Status) -> State {
    switch status {
    case .notRegistered: .disabled
    case .enabled: .enabled
    case .requiresApproval: .approvalRequired
    case .notFound: .unavailable
    @unknown default: .unavailable
    }
  }
}
