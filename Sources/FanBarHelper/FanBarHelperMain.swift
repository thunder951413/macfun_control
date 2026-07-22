import FanBarHardware
import Foundation
import OSLog
import Security

private final class HelperService: NSObject, FanBarHelperProtocol, @unchecked Sendable {
  private let queue = DispatchQueue(label: "local.fanbar.helper.smc")
  private let smc = SMCClient()
  private let logger = Logger(subsystem: "local.fanbar", category: "helper")

  func ping(withReply reply: @escaping @Sendable (String?) -> Void) {
    reply(geteuid() == 0 ? nil : "Helper is not running as root")
  }

  func setManualMode(fan: Int, withReply reply: @escaping @Sendable (String?) -> Void) {
    perform("manual fan \(fan)", reply) {
      try self.validateFan(fan)
      try self.smc.setManualMode(fan: fan)
    }
  }

  func setTargetRPM(
    _ rpm: Double, fan: Int, withReply reply: @escaping @Sendable (String?) -> Void
  ) {
    perform("target fan \(fan) rpm \(Int(rpm))", reply) {
      try self.validateFan(fan)
      let minimum = try self.smc.fanMinimumRPM(fan: fan)
      let maximum = try self.smc.fanMaximumRPM(fan: fan)
      guard rpm.isFinite, rpm >= minimum, rpm <= maximum else {
        throw HelperError.invalidTarget
      }
      try self.smc.setTargetRPM(rpm, fan: fan)
    }
  }

  func setAutomaticMode(fan: Int, withReply reply: @escaping @Sendable (String?) -> Void) {
    perform("automatic fan \(fan)", reply) {
      try self.validateFan(fan)
      try self.smc.setAutomaticMode(fan: fan)
    }
  }

  func resetControlOverride(withReply reply: @escaping @Sendable (String?) -> Void) {
    perform("reset override", reply) { try self.smc.resetControlOverride() }
  }

  func setBatteryChargeLimit(
    enabled: Bool, upperPercent: Int, withReply reply: @escaping @Sendable (String?) -> Void
  ) {
    perform("battery charge limit \(enabled ? upperPercent : 100)", reply) {
      try self.smc.setBatteryChargeLimit(enabled: enabled, upperPercent: upperPercent)
    }
  }

  func getBatteryChargeLimitState(
    withReply reply: @escaping @Sendable (Bool, Bool, Int, Int, String?) -> Void
  ) {
    queue.async {
      do {
        try self.ensureOpen()
        let state = try self.smc.batteryChargeLimitStateOrThrow()
        reply(
          state.isSupported, state.isEnabled, state.lowerPercent ?? -1,
          state.upperPercent ?? -1, nil)
      } catch {
        reply(false, false, -1, -1, error.localizedDescription)
      }
    }
  }

  func restoreAll() {
    logger.notice("restoreAll requested by connection lifecycle")
    queue.async {
      var lastFailures: [String] = []
      for attempt in 1...3 {
        lastFailures = self.restoreAllOnce()
        if lastFailures.isEmpty {
          self.logger.notice(
            "restored macOS fan control after client exit attempt=\(attempt, privacy: .public)"
          )
          return
        }
        if attempt < 3 { Thread.sleep(forTimeInterval: 0.15) }
      }
      self.logger.fault(
        "failed to restore macOS fan control after client exit: \(lastFailures.joined(separator: "; "), privacy: .public)"
      )
    }
  }

  private func restoreAllOnce() -> [String] {
    do {
      try ensureOpen()
      let count = try smc.fanCount()
      var failures: [String] = []
      for index in 0..<count {
        do {
          let mode = try smc.fanMode(fan: index)
          if mode != 0, mode != 3 { try smc.setAutomaticMode(fan: index) }
          let restoredMode = try smc.fanMode(fan: index)
          if restoredMode != 0, restoredMode != 3 {
            failures.append("fan \(index + 1) remains manual")
          }
        } catch {
          failures.append("fan \(index + 1): \(error.localizedDescription)")
        }
      }
      do {
        if try smc.controlOverrideActive() { try smc.resetControlOverride() }
        if try smc.controlOverrideActive() { failures.append("override remains active") }
      } catch {
        failures.append("override: \(error.localizedDescription)")
      }
      return failures
    } catch {
      return [error.localizedDescription]
    }
  }

  private func perform(
    _ name: String,
    _ reply: @escaping @Sendable (String?) -> Void,
    operation: @escaping @Sendable () throws -> Void
  ) {
    queue.async {
      do {
        try self.ensureOpen()
        try operation()
        self.logger.notice("operation succeeded: \(name, privacy: .public)")
        reply(nil)
      } catch {
        self.logger.error(
          "operation failed: \(name, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        reply(error.localizedDescription)
      }
    }
  }

  private func ensureOpen() throws {
    guard geteuid() == 0 else { throw HelperError.notRoot }
    if !smc.isOpen { try smc.open() }
  }

  private func validateFan(_ fan: Int) throws {
    let count = try smc.fanCount()
    guard fan >= 0, fan < count else { throw HelperError.invalidFan }
  }

  private enum HelperError: LocalizedError {
    case notRoot
    case invalidFan
    case invalidTarget

    var errorDescription: String? {
      switch self {
      case .notRoot: "FanBarHelper must run as root"
      case .invalidFan: "Invalid fan index"
      case .invalidTarget: "Target RPM is outside the hardware range"
      }
    }
  }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
  private let service = HelperService()
  private let logger = Logger(subsystem: "local.fanbar", category: "xpc-listener")
  private let ownTeamIdentifier: String?
  private let connectionLock = NSLock()
  private var activeConnections = 0

  override init() {
    ownTeamIdentifier = Self.signingIdentityForSelf()?.teamIdentifier
    super.init()
  }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
    -> Bool
  {
    guard geteuid() == 0,
      let ownTeamIdentifier,
      let client = Self.signingIdentity(pid: connection.processIdentifier),
      client.identifier == FanBarHelperConstants.appBundleIdentifier,
      client.teamIdentifier == ownTeamIdentifier
    else {
      return false
    }

    connection.exportedInterface = NSXPCInterface(with: FanBarHelperProtocol.self)
    connection.exportedObject = service
    connectionLock.lock()
    activeConnections += 1
    let connectionCount = activeConnections
    connectionLock.unlock()
    logger.notice(
      "accepted client pid=\(connection.processIdentifier, privacy: .public) active=\(connectionCount, privacy: .public)"
    )
    connection.invalidationHandler = { [weak self] in self?.connectionClosed() }
    connection.resume()
    return true
  }

  private func connectionClosed() {
    connectionLock.lock()
    activeConnections = max(0, activeConnections - 1)
    let shouldRestore = activeConnections == 0
    let connectionCount = activeConnections
    connectionLock.unlock()
    logger.notice(
      "client closed active=\(connectionCount, privacy: .public) restore=\(shouldRestore, privacy: .public)"
    )
    if shouldRestore { service.restoreAll() }
  }

  private static func signingIdentityForSelf() -> (identifier: String, teamIdentifier: String)? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    return signingIdentity(code: code)
  }

  private static func signingIdentity(pid: pid_t) -> (identifier: String, teamIdentifier: String)? {
    let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
      let code,
      SecCodeCheckValidity(code, [], nil) == errSecSuccess
    else { return nil }
    return signingIdentity(code: code)
  }

  private static func signingIdentity(code: SecCode) -> (
    identifier: String, teamIdentifier: String
  )? {
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
      return nil
    }
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        == errSecSuccess,
      let values = information as? [String: Any],
      let identifier = values[kSecCodeInfoIdentifier as String] as? String,
      let teamIdentifier = values[kSecCodeInfoTeamIdentifier as String] as? String
    else { return nil }
    return (identifier, teamIdentifier)
  }
}

@main
private struct FanBarHelperMain {
  static func main() {
    guard geteuid() == 0 else { exit(EXIT_FAILURE) }
    let delegate = ListenerDelegate()
    let listener = NSXPCListener(machServiceName: FanBarHelperConstants.machServiceName)
    listener.delegate = delegate
    listener.resume()
    RunLoop.current.run()
  }
}
