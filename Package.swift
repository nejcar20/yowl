// swift-tools-version: 6.2
import PackageDescription

let mainActor: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "LaptopAlarm",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AlarmCore", targets: ["AlarmCore"]),
        .executable(name: "LaptopAlarm", targets: ["LaptopAlarm"]),
    ],
    targets: [
        .target(name: "AlarmCore", swiftSettings: mainActor),
        .executableTarget(name: "LaptopAlarm", dependencies: ["AlarmCore"],
                          swiftSettings: mainActor),
        .testTarget(name: "AlarmCoreTests", dependencies: ["AlarmCore"],
                    swiftSettings: mainActor),
    ]
)
