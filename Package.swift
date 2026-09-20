// swift-tools-version: 6.2
import PackageDescription

let mainActor: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "Yowl",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AlarmCore", targets: ["AlarmCore"]),
        .library(name: "AlarmApp", targets: ["AlarmApp"]),
        .executable(name: "Yowl", targets: ["Yowl"]),
    ],
    targets: [
        .target(name: "AlarmCore", swiftSettings: mainActor),
        // The app's logic lives in a library so it can be tested. Every serious
        // defect this project hit was in AppModel, and none was catchable while
        // it sat in an executable target with no tests.
        .target(name: "AlarmApp", dependencies: ["AlarmCore"], swiftSettings: mainActor),
        .executableTarget(name: "Yowl", dependencies: ["AlarmApp"],
                          swiftSettings: mainActor),
        .testTarget(name: "AlarmCoreTests", dependencies: ["AlarmCore"],
                    swiftSettings: mainActor),
        .testTarget(name: "AlarmAppTests", dependencies: ["AlarmApp"],
                    swiftSettings: mainActor),
    ]
)
