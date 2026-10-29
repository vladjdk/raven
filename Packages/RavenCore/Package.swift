// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "RavenCore",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "RavenCore", targets: ["RavenCore"]),
  ],
  targets: [
    .target(name: "RavenCore", linkerSettings: [.linkedLibrary("sqlite3")]),
    .testTarget(name: "RavenCoreTests", dependencies: ["RavenCore"]),
  ]
)
