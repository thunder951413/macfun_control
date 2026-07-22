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
        color: nil,
        accessibilityDescription: accessibilityDescription)
    case .macOSColored:
      return systemBatteryImage(
        power: power,
        color: coloredStatusColor(for: power),
        accessibilityDescription: accessibilityDescription)
    case .iOSNative:
      return compactBatteryImage(
        power: power,
        accessibilityDescription: accessibilityDescription)
    }
  }

  private static func systemBatteryImage(
    power: PowerReading?,
    color: NSColor?,
    accessibilityDescription: String
  ) -> NSImage {
    let symbolName = BatteryStatusPresentation.symbolName(for: power)
    let base =
      NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)
      ?? NSImage(
        systemSymbolName: "battery.0percent", accessibilityDescription: accessibilityDescription)!
    let pointConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
    let image: NSImage
    if let color {
      let palette = NSImage.SymbolConfiguration(paletteColors: [color])
      image = base.withSymbolConfiguration(pointConfiguration.applying(palette)) ?? base
      image.isTemplate = false
    } else {
      image = base.withSymbolConfiguration(pointConfiguration) ?? base
      image.isTemplate = true
    }
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

  private static func coloredStatusColor(for power: PowerReading?) -> NSColor {
    guard let level = power?.batteryLevelPercent else { return .secondaryLabelColor }
    if level <= 10 { return .systemRed }
    if level <= 20 { return .systemYellow }
    return .systemGreen
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
