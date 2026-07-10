import Foundation
@preconcurrency import IOKit

public enum CPUTemperatureSource: String, CaseIterable, Sendable {
  case package
  case coreAverage
  case hotspot
}

public protocol FanHardware: Sendable {
  var isOpen: Bool { get }
  func open() throws
  func close()
  func fanCount() throws -> Int
  func cpuTemperature() throws -> Double
  func cpuTemperature(source: CPUTemperatureSource) throws -> Double
  func fanActualRPM(fan index: Int) throws -> Double
  func fanMinimumRPM(fan index: Int) throws -> Double
  func fanMaximumRPM(fan index: Int) throws -> Double
  func fanMode(fan index: Int) throws -> UInt8
  func setManualMode(fan index: Int) throws
  func setTargetRPM(_ rpm: Double, fan index: Int) throws
  func setAutomaticMode(fan index: Int) throws
  func controlOverrideActive() throws -> Bool
  func resetControlOverride() throws
}

extension FanHardware {
  public func cpuTemperature(source: CPUTemperatureSource) throws -> Double {
    try cpuTemperature()
  }
}

public final class SMCClient: FanHardware, @unchecked Sendable {
  public struct TemperatureReading: Sendable, Equatable {
    public let key: String
    public let value: Double

    public init(key: String, value: Double) {
      self.key = key
      self.value = value
    }
  }

  public enum SMCError: LocalizedError, Equatable {
    case serviceNotFound
    case connectionFailed(kern_return_t)
    case notOpen
    case callFailed(String, kern_return_t)
    case firmwareError(String, UInt8)
    case keyUnavailable(String)
    case invalidValue(String)
    case verificationFailed(String, expected: Double, actual: Double)
    case noTemperatureKey
    case noFans
    case manualModeTimeout(Int)

    public var errorDescription: String? {
      switch self {
      case .serviceNotFound: "AppleSMC service not found"
      case .connectionFailed(let code):
        "AppleSMC connection failed (0x\(String(UInt32(bitPattern: code), radix: 16)))"
      case .notOpen: "AppleSMC connection is not open"
      case .callFailed(let key, let code):
        "AppleSMC call failed for \(key) (0x\(String(UInt32(bitPattern: code), radix: 16)))"
      case .firmwareError(let key, let code):
        "AppleSMC rejected \(key) (0x\(String(code, radix: 16)))"
      case .keyUnavailable(let key): "SMC key unavailable: \(key)"
      case .invalidValue(let key): "SMC returned an invalid value for \(key)"
      case .verificationFailed(let key, let expected, let actual):
        "SMC verification failed for \(key): expected \(Int(expected)), read \(Int(actual))"
      case .noTemperatureKey: "No valid CPU temperature sensor was found"
      case .noFans: "This Mac reports no controllable fans"
      case .manualModeTimeout(let fan): "Fan \(fan + 1) did not enter manual mode"
      }
    }

    public var isPermissionDenied: Bool {
      if case .callFailed(_, let code) = self { return code == kIOReturnNotPrivileged }
      return false
    }
  }

  private struct SMCKeyDataVers {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
  }

  private struct SMCKeyDataPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
  }

  private struct SMCKeyDataKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
  }

  // AppleSMC's user-client ABI is exactly 80 bytes. The explicit padding is
  // required because Swift otherwise packs result at offset 37.
  private struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCKeyDataVers()
    var pLimitData = SMCKeyDataPLimitData()
    var keyInfo = SMCKeyDataKeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes = (
      UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(),
      UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(),
      UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(),
      UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8()
    )
  }

  private struct KeyValue {
    let type: String
    let bytes: [UInt8]
  }

  public static var abiLayout: (stride: Int, result: Int, data32: Int, bytes: Int) {
    (
      MemoryLayout<SMCKeyData>.stride,
      MemoryLayout<SMCKeyData>.offset(of: \.result) ?? -1,
      MemoryLayout<SMCKeyData>.offset(of: \.data32) ?? -1,
      MemoryLayout<SMCKeyData>.offset(of: \.bytes) ?? -1
    )
  }

  private let handleYPCEvent: UInt32 = 2
  private let readKeyCommand: UInt8 = 5
  private let writeKeyCommand: UInt8 = 6
  private let readIndexCommand: UInt8 = 8
  private let getKeyInfoCommand: UInt8 = 9
  private var connection: io_connect_t = 0
  private var modeKeyFormat: String?
  private var hasForceTestKey = false
  private var cachedKeys: [String]?

  public var isOpen: Bool { connection != 0 }

  public init() {}

  deinit { close() }

  public func open() throws {
    guard connection == 0 else { return }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
    guard service != 0 else { throw SMCError.serviceNotFound }
    defer { IOObjectRelease(service) }

    var newConnection: io_connect_t = 0
    let result = IOServiceOpen(service, mach_task_self_, 0, &newConnection)
    guard result == kIOReturnSuccess else { throw SMCError.connectionFailed(result) }
    connection = newConnection

    modeKeyFormat = ["F%dmd", "F%dMd"].first { format in
      (try? readKey(String(format: format, 0))) != nil
    }
    hasForceTestKey = (try? readKey("Ftst")) != nil
  }

  public func close() {
    guard connection != 0 else { return }
    IOServiceClose(connection)
    connection = 0
    modeKeyFormat = nil
    hasForceTestKey = false
    cachedKeys = nil
  }

  public func fanCount() throws -> Int {
    let count = Int(try readUInt8("FNum"))
    guard (1...8).contains(count) else { throw SMCError.noFans }
    return count
  }

  public func cpuTemperature() throws -> Double {
    try cpuTemperature(source: .package)
  }

  public func cpuTemperature(source: CPUTemperatureSource) throws -> Double {
    let value: Double?
    switch source {
    case .package:
      value = firstValidTemperature(["TPMP", "TCHP", "TCMb"])
    case .hotspot:
      value = firstValidTemperature(["TCMz", "TCMb"])
    case .coreAverage:
      let keys = try allKeys().filter {
        ($0.hasPrefix("Tp") && !$0.hasPrefix("Tpx"))
          || ($0.hasPrefix("Te") && !$0.hasPrefix("Tex"))
      }
      value = Self.robustAverage(
        keys.compactMap { key in
          guard let reading = try? readNumeric(key), (15...115).contains(reading) else { return nil }
          return reading
        })
    }
    guard let value, value.isFinite, (0...125).contains(value) else {
      throw SMCError.noTemperatureKey
    }
    return value
  }

  public static func robustAverage(_ values: [Double]) -> Double? {
    let sorted = values.filter(\.isFinite).sorted()
    guard !sorted.isEmpty else { return nil }
    let trim = sorted.count >= 10 ? sorted.count / 10 : 0
    let retained = sorted[trim..<(sorted.count - trim)]
    return retained.reduce(0, +) / Double(retained.count)
  }

  public func temperatureReadings() -> [TemperatureReading] {
    let keys = [
      "TC0P", "TC0E", "TC0F", "TC0D", "TC0H", "TCMz",
      "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D",
      "Tm0P", "Ts0P", "TA0P",
    ]
    return keys.compactMap { key -> TemperatureReading? in
      guard let value = try? self.readNumeric(key), value.isFinite, (0...125).contains(value) else {
        return nil
      }
      return TemperatureReading(key: key, value: value)
    }
  }

  public func allTemperatureReadings() -> [TemperatureReading] {
    guard let keys = try? allKeys() else { return temperatureReadings() }
    return keys.compactMap { key -> TemperatureReading? in
      guard key.first == "T" || key.first == "t",
        let value = try? readNumeric(key), value.isFinite, (0...125).contains(value)
      else { return nil }
      return TemperatureReading(key: key, value: value)
    }
  }

  private func firstValidTemperature(_ keys: [String]) -> Double? {
    keys.lazy.compactMap { key -> Double? in
      guard let value = try? self.readNumeric(key), value.isFinite, (0...125).contains(value) else {
        return nil
      }
      return value
    }.first
  }

  public func fanActualRPM(fan index: Int) throws -> Double { try readRPM("F\(index)Ac") }
  public func fanTargetRPM(fan index: Int) throws -> Double { try readRPM("F\(index)Tg") }
  public func fanMinimumRPM(fan index: Int) throws -> Double { try readRPM("F\(index)Mn") }
  public func fanMaximumRPM(fan index: Int) throws -> Double { try readRPM("F\(index)Mx") }

  public func fanMode(fan index: Int) throws -> UInt8 {
    try readUInt8(modeKey(fan: index))
  }

  public func setManualMode(fan index: Int) throws {
    let key = modeKey(fan: index)
    do {
      try writeUInt8(key, value: 1)
      guard try fanMode(fan: index) == 1 else { throw SMCError.manualModeTimeout(index) }
      return
    } catch {
      guard hasForceTestKey else { throw error }
    }

    try writeUInt8("Ftst", value: 1)
    Thread.sleep(forTimeInterval: 0.5)
    let deadline = Date().addingTimeInterval(15)
    repeat {
      do {
        try writeUInt8(key, value: 1)
        if try fanMode(fan: index) == 1 { return }
      } catch {
        // thermalmonitord may reject mode writes until it yields control.
      }
      Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline

    throw SMCError.manualModeTimeout(index)
  }

  public func setTargetRPM(_ rpm: Double, fan index: Int) throws {
    let key = "F\(index)Tg"
    try writeNumeric(key, value: rpm)
    let deadline = Date().addingTimeInterval(2)
    var confirmed = try readNumeric(key)
    while Date() < deadline {
      if confirmed.isFinite, abs(confirmed - rpm) <= max(100, rpm * 0.05) { return }
      Thread.sleep(forTimeInterval: 0.1)
      confirmed = try readNumeric(key)
    }
    throw SMCError.verificationFailed(key, expected: rpm, actual: confirmed)
  }

  public func setAutomaticMode(fan index: Int) throws {
    let key = modeKey(fan: index)
    let currentMode = try fanMode(fan: index)
    guard currentMode != 0, currentMode != 3 else { return }
    do {
      try writeUInt8(key, value: 0)
    } catch {
      guard hasForceTestKey else { throw error }
      // Recovery for a crashed/interrupted session where the fan remained in
      // manual mode after Ftst had already returned to zero.
      try writeUInt8("Ftst", value: 1)
      Thread.sleep(forTimeInterval: 0.5)
      // If firmware continues rejecting the mode transition, never leave a
      // stranded manual fan with a stale low target while system ownership is
      // being reclaimed.
      if let maximum = try? fanMaximumRPM(fan: index) {
        try? writeNumeric("F\(index)Tg", value: maximum)
      }
      let unlockDeadline = Date().addingTimeInterval(15)
      var wroteAutomatic = false
      repeat {
        do {
          try writeUInt8(key, value: 0)
          wroteAutomatic = true
          break
        } catch {
          Thread.sleep(forTimeInterval: 0.1)
        }
      } while Date() < unlockDeadline
      // Some Apple Silicon firmware rejects F?Md=0 but still returns control
      // after Ftst is cleared. The caller clears Ftst after processing all fans.
      if !wroteAutomatic { return }
    }

    let deadline = Date().addingTimeInterval(6)
    var mode = try fanMode(fan: index)
    while mode != 0, mode != 3, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.1)
      mode = try fanMode(fan: index)
    }
    guard mode == 0 || mode == 3 else {
      throw SMCError.verificationFailed(key, expected: 0, actual: Double(mode))
    }
  }

  public func controlOverrideActive() throws -> Bool {
    guard hasForceTestKey else { return false }
    return try readUInt8("Ftst") != 0
  }

  public func resetControlOverride() throws {
    guard try controlOverrideActive() else { return }
    try writeUInt8("Ftst", value: 0)
    let deadline = Date().addingTimeInterval(6)
    while try controlOverrideActive(), Date() < deadline {
      Thread.sleep(forTimeInterval: 0.2)
    }
    guard try !controlOverrideActive() else {
      throw SMCError.verificationFailed("Ftst", expected: 0, actual: 1)
    }
  }

  private func modeKey(fan index: Int) -> String {
    String(format: modeKeyFormat ?? "F%dMd", index)
  }

  private func readRPM(_ key: String) throws -> Double {
    let value = try readNumeric(key)
    guard value.isFinite, (0...20_000).contains(value) else { throw SMCError.invalidValue(key) }
    return value
  }

  private func readNumeric(_ key: String) throws -> Double {
    let data = try readKey(key)
    switch data.type {
    case "sp78" where data.bytes.count >= 2:
      let raw = Int16(bitPattern: UInt16(data.bytes[0]) << 8 | UInt16(data.bytes[1]))
      return Double(raw) / 256
    case "fpe2" where data.bytes.count >= 2:
      return Double(UInt16(data.bytes[0]) << 8 | UInt16(data.bytes[1])) / 4
    case "flt " where data.bytes.count >= 4:
      let bits =
        UInt32(data.bytes[0]) | UInt32(data.bytes[1]) << 8 | UInt32(data.bytes[2]) << 16 | UInt32(
          data.bytes[3]) << 24
      return Double(Float(bitPattern: bits))
    case "ui8 " where !data.bytes.isEmpty:
      return Double(data.bytes[0])
    case "ui16" where data.bytes.count >= 2:
      return Double(UInt16(data.bytes[0]) << 8 | UInt16(data.bytes[1]))
    default:
      throw SMCError.keyUnavailable(key)
    }
  }

  private func readUInt8(_ key: String) throws -> UInt8 {
    let data = try readKey(key)
    guard let first = data.bytes.first else { throw SMCError.keyUnavailable(key) }
    return first
  }

  private func writeUInt8(_ key: String, value: UInt8) throws {
    try writeKey(key, bytes: [value])
  }

  private func writeNumeric(_ key: String, value: Double) throws {
    let info = try keyInfo(key)
    switch info.type {
    case "fpe2":
      let encoded = UInt16(max(0, min(value * 4, Double(UInt16.max))))
      try writeKey(key, bytes: [UInt8(encoded >> 8), UInt8(encoded & 0xff)], knownInfo: info)
    case "flt ":
      let bits = Float(value).bitPattern
      try writeKey(
        key,
        bytes: [
          UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff),
          UInt8((bits >> 16) & 0xff), UInt8((bits >> 24) & 0xff),
        ], knownInfo: info)
    default:
      throw SMCError.keyUnavailable(key)
    }
  }

  private func keyInfo(_ key: String) throws -> (type: String, size: Int) {
    var input = SMCKeyData()
    input.key = try fourCharCode(key)
    input.data8 = getKeyInfoCommand
    let output = try call(key, input: input)
    let size = Int(output.keyInfo.dataSize)
    guard (1...32).contains(size) else { throw SMCError.invalidValue(key) }
    return (fourCharString(output.keyInfo.dataType), size)
  }

  private func readKey(_ key: String) throws -> KeyValue {
    let info = try keyInfo(key)
    var input = SMCKeyData()
    input.key = try fourCharCode(key)
    input.keyInfo.dataSize = UInt32(info.size)
    input.data8 = readKeyCommand
    let output = try call(key, input: input)
    return KeyValue(type: info.type, bytes: Array(tupleBytes(output.bytes).prefix(info.size)))
  }

  private func allKeys() throws -> [String] {
    if let cachedKeys { return cachedKeys }
    let countData = try readKey("#KEY")
    guard countData.bytes.count >= 4 else { throw SMCError.invalidValue("#KEY") }
    let count =
      UInt32(countData.bytes[0]) << 24 | UInt32(countData.bytes[1]) << 16
      | UInt32(countData.bytes[2]) << 8 | UInt32(countData.bytes[3])
    guard (1...20_000).contains(count) else { throw SMCError.invalidValue("#KEY") }

    var keys: [String] = []
    keys.reserveCapacity(Int(count))
    for index in 0..<count {
      var input = SMCKeyData()
      input.data8 = readIndexCommand
      input.data32 = index
      let output = try call("index \(index)", input: input)
      let key = fourCharString(output.key)
      if key.utf8.count == 4 { keys.append(key) }
    }
    cachedKeys = keys
    return keys
  }

  private func writeKey(_ key: String, bytes: [UInt8], knownInfo: (type: String, size: Int)? = nil)
    throws
  {
    let info = try knownInfo ?? keyInfo(key)
    guard bytes.count == info.size else { throw SMCError.invalidValue(key) }
    var input = SMCKeyData()
    input.key = try fourCharCode(key)
    input.keyInfo.dataSize = UInt32(info.size)
    input.data8 = writeKeyCommand
    input.bytes = makeByteTuple(bytes)
    _ = try call(key, input: input)
  }

  private func call(_ key: String, input: SMCKeyData) throws -> SMCKeyData {
    guard connection != 0 else { throw SMCError.notOpen }
    precondition(MemoryLayout<SMCKeyData>.stride == 80, "AppleSMC ABI layout changed")
    var input = input
    var output = SMCKeyData()
    var outputSize = MemoryLayout<SMCKeyData>.stride
    let result = IOConnectCallStructMethod(
      connection, handleYPCEvent, &input, MemoryLayout<SMCKeyData>.stride, &output, &outputSize
    )
    guard result == kIOReturnSuccess else { throw SMCError.callFailed(key, result) }
    guard outputSize >= 44 else { throw SMCError.invalidValue(key) }
    guard output.result == 0 else { throw SMCError.firmwareError(key, output.result) }
    return output
  }

  private func fourCharCode(_ string: String) throws -> UInt32 {
    guard string.utf8.count == 4 else { throw SMCError.keyUnavailable(string) }
    return string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
  }

  private func fourCharString(_ code: UInt32) -> String {
    String(
      bytes: [
        UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
        UInt8((code >> 8) & 0xff), UInt8(code & 0xff),
      ], encoding: .ascii) ?? ""
  }

  private func tupleBytes(_ tuple: SMCKeyDataBytes) -> [UInt8] {
    withUnsafeBytes(of: tuple) { Array($0) }
  }

  private typealias SMCKeyDataBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
  )

  private func makeByteTuple(_ bytes: [UInt8]) -> SMCKeyDataBytes {
    let value = bytes + Array(repeating: 0, count: 32 - bytes.count)
    return (
      value[0], value[1], value[2], value[3], value[4], value[5], value[6], value[7],
      value[8], value[9], value[10], value[11], value[12], value[13], value[14], value[15],
      value[16], value[17], value[18], value[19], value[20], value[21], value[22], value[23],
      value[24], value[25], value[26], value[27], value[28], value[29], value[30], value[31]
    )
  }
}
