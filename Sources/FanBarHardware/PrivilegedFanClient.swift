import Foundation
import OSLog

public final class PrivilegedFanClient: @unchecked Sendable {
  private let logger = Logger(subsystem: "local.fanbar", category: "xpc-client")
  private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Void, Error>?

    func set(_ value: Result<Void, Error>) {
      lock.lock()
      self.value = value
      lock.unlock()
    }

    func get() -> Result<Void, Error>? {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
  }

  private let lock = NSLock()
  private var connection: NSXPCConnection?

  public init() {}

  deinit { invalidate() }

  public func ping() throws {
    try request(timeout: 3) { proxy, reply in proxy.ping(withReply: reply) }
  }

  public func setManualMode(fan: Int) throws {
    try request(timeout: 22) { proxy, reply in proxy.setManualMode(fan: fan, withReply: reply) }
  }

  public func setTargetRPM(_ rpm: Double, fan: Int) throws {
    try request(timeout: 5) { proxy, reply in
      proxy.setTargetRPM(rpm, fan: fan, withReply: reply)
    }
  }

  public func setAutomaticMode(fan: Int) throws {
    try request(timeout: 22) { proxy, reply in proxy.setAutomaticMode(fan: fan, withReply: reply) }
  }

  public func resetControlOverride() throws {
    try request(timeout: 5) { proxy, reply in proxy.resetControlOverride(withReply: reply) }
  }

  public func invalidate() {
    lock.lock()
    let oldConnection = connection
    connection = nil
    lock.unlock()
    oldConnection?.invalidate()
  }

  private func request(
    timeout: TimeInterval,
    operation: (FanBarHelperProtocol, @escaping @Sendable (String?) -> Void) -> Void
  ) throws {
    let semaphore = DispatchSemaphore(value: 0)
    let result = ResultBox()

    let connection = try activeConnection()
    guard
      let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
        result.set(.failure(FanBarHelperError.unavailable(error.localizedDescription)))
        semaphore.signal()
      }) as? FanBarHelperProtocol
    else {
      throw FanBarHelperError.unavailable("XPC protocol negotiation failed")
    }

    operation(proxy) { message in
      result.set(message.map { .failure(FanBarHelperError.rejected($0)) } ?? .success(()))
      semaphore.signal()
    }

    guard semaphore.wait(timeout: .now() + timeout) == .success else {
      invalidate()
      throw FanBarHelperError.timedOut
    }
    try result.get()?.get()
  }

  private func activeConnection() throws -> NSXPCConnection {
    lock.lock()
    defer { lock.unlock() }
    if let connection { return connection }

    let connection = NSXPCConnection(
      machServiceName: FanBarHelperConstants.machServiceName,
      options: .privileged)
    connection.remoteObjectInterface = NSXPCInterface(with: FanBarHelperProtocol.self)
    connection.invalidationHandler = { [weak self] in
      self?.logger.error("XPC connection invalidated")
      self?.lock.lock()
      self?.connection = nil
      self?.lock.unlock()
    }
    connection.interruptionHandler = { [weak self] in
      self?.logger.error("XPC connection interrupted")
    }
    connection.resume()
    logger.notice("XPC connection resumed")
    self.connection = connection
    return connection
  }
}

public final class RoutedFanHardware: FanHardware, @unchecked Sendable {
  private let local: SMCClient
  private let helper: PrivilegedFanClient

  public init(local: SMCClient = SMCClient(), helper: PrivilegedFanClient = PrivilegedFanClient()) {
    self.local = local
    self.helper = helper
  }

  public var isOpen: Bool { local.isOpen }
  public func open() throws { try local.open() }
  public func close() {
    local.close()
    helper.invalidate()
  }
  public func fanCount() throws -> Int { try local.fanCount() }
  public func cpuTemperature() throws -> Double { try local.cpuTemperature() }
  public func cpuTemperature(source: CPUTemperatureSource) throws -> Double {
    try local.cpuTemperature(source: source)
  }
  public func cpuHotspotReading() throws -> TemperatureReading {
    try local.cpuHotspotReading()
  }
  public func batteryTemperatureReading() throws -> TemperatureReading {
    try local.batteryTemperatureReading()
  }
  public func allTemperatureReadings() -> [TemperatureReading] {
    local.allTemperatureReadings()
  }
  public func powerReading() -> PowerReading? { local.powerReading() }
  public func fanActualRPM(fan index: Int) throws -> Double { try local.fanActualRPM(fan: index) }
  public func fanTargetRPM(fan index: Int) throws -> Double { try local.fanTargetRPM(fan: index) }
  public func fanMinimumRPM(fan index: Int) throws -> Double { try local.fanMinimumRPM(fan: index) }
  public func fanMaximumRPM(fan index: Int) throws -> Double { try local.fanMaximumRPM(fan: index) }
  public func fanMode(fan index: Int) throws -> UInt8 { try local.fanMode(fan: index) }
  public func setManualMode(fan index: Int) throws { try helper.setManualMode(fan: index) }
  public func setTargetRPM(_ rpm: Double, fan index: Int) throws {
    try helper.setTargetRPM(rpm, fan: index)
  }
  public func setAutomaticMode(fan index: Int) throws { try helper.setAutomaticMode(fan: index) }
  public func controlOverrideActive() throws -> Bool { try local.controlOverrideActive() }
  public func resetControlOverride() throws { try helper.resetControlOverride() }

  public func helperAvailable() -> Bool { (try? helper.ping()) != nil }
}
