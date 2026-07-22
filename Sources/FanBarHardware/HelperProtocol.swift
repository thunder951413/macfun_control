import Foundation

public enum FanBarHelperConstants {
  public static let machServiceName = "local.fanbar.helper"
  public static let plistName = "local.fanbar.helper.plist"
  public static let appBundleIdentifier = "local.fanbar"
}

@objc(FanBarHelperProtocol)
public protocol FanBarHelperProtocol {
  func ping(withReply reply: @escaping @Sendable (String?) -> Void)
  func setManualMode(fan: Int, withReply reply: @escaping @Sendable (String?) -> Void)
  func setTargetRPM(
    _ rpm: Double, fan: Int, withReply reply: @escaping @Sendable (String?) -> Void)
  func setAutomaticMode(fan: Int, withReply reply: @escaping @Sendable (String?) -> Void)
  func resetControlOverride(withReply reply: @escaping @Sendable (String?) -> Void)
  func setBatteryChargeLimit(
    enabled: Bool, upperPercent: Int, withReply reply: @escaping @Sendable (String?) -> Void)
  func getBatteryChargeLimitState(
    withReply reply: @escaping @Sendable (Bool, Bool, Int, Int, String?) -> Void)
}

public enum FanBarHelperError: LocalizedError, Equatable {
  case unavailable(String)
  case timedOut
  case rejected(String)

  public var errorDescription: String? {
    switch self {
    case .unavailable(let message): "Privileged fan helper unavailable: \(message)"
    case .timedOut: "Privileged fan helper timed out"
    case .rejected(let message): message
    }
  }

  public var isConnectionFailure: Bool {
    switch self {
    case .unavailable, .timedOut: true
    case .rejected: false
    }
  }
}
