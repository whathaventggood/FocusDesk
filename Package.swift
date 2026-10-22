// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FocusDeskCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "FocusDeskCore", targets: ["FocusDeskCore"])],
    targets: [
        .target(
            name: "FocusDeskCore",
            path: "FocusDesk",
            exclude: ["App", "Views", "Resources", "Services/PlanStore.swift"],
            sources: ["Models", "Services/ScheduleEngine.swift", "Services/ProgressStore.swift"]
        ),
        .testTarget(name: "FocusDeskCoreTests", dependencies: ["FocusDeskCore"], path: "FocusDeskTests")
    ]
)
