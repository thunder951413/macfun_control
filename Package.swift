// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "FanBar",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "FanBar", targets: ["FanBar"]),
    .executable(name: "FanBarHelper", targets: ["FanBarHelper"]),
  ],
  targets: [
    .target(name: "FanBarC"),
    .target(
      name: "FanBarHardware",
      dependencies: ["FanBarC"],
      linkerSettings: [
        .linkedFramework("IOKit")
      ]
    ),
    .executableTarget(
      name: "FanBar",
      dependencies: ["FanBarHardware"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("ServiceManagement"),
        .linkedFramework("SwiftUI"),
      ]
    ),
    .executableTarget(
      name: "FanBarHelper",
      dependencies: ["FanBarHardware"],
      linkerSettings: [
        .linkedFramework("Security")
      ]
    ),
    .testTarget(
      name: "FanBarTests",
      dependencies: ["FanBar", "FanBarHardware"]
    ),
  ]
)
