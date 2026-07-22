import AppKit
import FanBarHardware

@MainActor
enum BatteryMenuBarImageRenderer {
  static func image(
    style: BatteryMenuBarStyle,
    power: PowerReading?,
    accessibilityDescription: String
  ) -> NSImage {
    switch style {
    case .fanBarStatus, .macOSNative:
      return systemBatteryImage(
        power: power,
        accessibilityDescription: accessibilityDescription)
    case .macOSColored:
      return blueBatteryImage(
        power: power,
        accessibilityDescription: accessibilityDescription)
    case .iOSNative:
      return compactBatteryImage(
        power: power,
        accessibilityDescription: accessibilityDescription)
    }
  }

  private static func systemBatteryImage(
    power: PowerReading?,
    accessibilityDescription: String
  ) -> NSImage {
    let symbolName = BatteryStatusPresentation.symbolName(for: power)
    let base =
      NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)
      ?? NSImage(
        systemSymbolName: "battery.0percent", accessibilityDescription: accessibilityDescription)!
    let pointConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
    let image = base.withSymbolConfiguration(pointConfiguration) ?? base
    image.isTemplate = true
    image.accessibilityDescription = accessibilityDescription
    return image
  }

  /// A native-proportioned battery with a fixed white shell and blue charge level.
  /// This is deliberately non-template artwork so AppKit does not replace either color.
  private static func blueBatteryImage(
    power: PowerReading?,
    accessibilityDescription: String
  ) -> NSImage {
    let size = NSSize(width: 30, height: 14)
    let image = NSImage(size: size, flipped: false) { _ in
      let level = CGFloat(min(100, max(0, power?.batteryLevelPercent ?? 0))) / 100
      let bodyRect = NSRect(x: 0.75, y: 1.25, width: 26, height: 11.5)
      let body = NSBezierPath(roundedRect: bodyRect, xRadius: 3.1, yRadius: 3.1)
      NSColor.white.setStroke()
      body.lineWidth = 1.35
      body.stroke()

      // Keep a consistent inset like the system battery rather than tinting the entire symbol.
      let innerRect = bodyRect.insetBy(dx: 2, dy: 2)
      let fillWidth = innerRect.width * level
      if fillWidth > 0 {
        let fillRect = NSRect(
          x: innerRect.minX, y: innerRect.minY,
          width: fillWidth, height: innerRect.height)
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 1.5, yRadius: 1.5).fill()
      }

      let terminal = NSBezierPath(
        roundedRect: NSRect(x: 27.55, y: 4.25, width: 1.7, height: 5.5),
        xRadius: 0.85,
        yRadius: 0.85)
      NSColor.white.setFill()
      terminal.fill()

      if power?.isBatteryCharging == true,
        let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)
      {
        let configuration = NSImage.SymbolConfiguration(
          paletteColors: [.white]
        ).applying(NSImage.SymbolConfiguration(pointSize: 8, weight: .bold))
        let configuredBolt = bolt.withSymbolConfiguration(configuration) ?? bolt
        configuredBolt.draw(
          in: NSRect(x: 10.5, y: 2.5, width: 7, height: 9),
          from: .zero,
          operation: .sourceOver,
          fraction: 1)
      }
      return true
    }
    image.isTemplate = false
    image.accessibilityDescription = accessibilityDescription
    return image
  }

  private static func compactBatteryImage(
    power: PowerReading?,
    accessibilityDescription: String
  ) -> NSImage {
    let size = NSSize(width: 30, height: 14)
    let image = NSImage(size: size, flipped: false) { rect in
      let level = CGFloat(min(100, max(0, power?.batteryLevelPercent ?? 0))) / 100
      let bodyRect = NSRect(x: 0.75, y: 1, width: 26, height: 12)
      let body = NSBezierPath(roundedRect: bodyRect, xRadius: 3.2, yRadius: 3.2)
      let outline = nativeStatusColor(for: power)
      outline.setStroke()
      body.lineWidth = 1.35
      body.stroke()

      let fillWidth = max(0, (bodyRect.width - 3) * level)
      if fillWidth > 0 {
        let fillRect = NSRect(
          x: bodyRect.minX + 1.5, y: bodyRect.minY + 1.5,
          width: fillWidth, height: bodyRect.height - 3)
        outline.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 1.8, yRadius: 1.8).fill()
      }

      let tip = NSBezierPath(
        roundedRect: NSRect(x: 27.4, y: 4.5, width: 2, height: 5), xRadius: 1, yRadius: 1)
      outline.setFill()
      tip.fill()

      let percentage = power?.batteryLevelPercent.map(String.init) ?? "--"
      let textColor: NSColor = level >= 0.48 ? .controlBackgroundColor : outline
      let paragraph = NSMutableParagraphStyle()
      paragraph.alignment = .center
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 8.2, weight: .semibold),
        .foregroundColor: textColor,
        .paragraphStyle: paragraph,
      ]
      (percentage as NSString).draw(
        in: NSRect(x: 1, y: 2.1, width: 25.5, height: 10),
        withAttributes: attributes)
      return true
    }
    image.isTemplate = false
    image.accessibilityDescription = accessibilityDescription
    return image
  }

  private static func nativeStatusColor(for power: PowerReading?) -> NSColor {
    guard let level = power?.batteryLevelPercent else { return .secondaryLabelColor }
    if power?.isBatteryCharging == true || power?.isBatteryFullyCharged == true {
      return .systemGreen
    }
    if level <= 10 { return .systemRed }
    if level <= 20 { return .systemYellow }
    return .labelColor
  }
}
