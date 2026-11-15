// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [
    .library(name: "RainCore", targets: ["RainCore"]),
    .executable(name: "RainProbe", targets: ["RainProbe"])
]
var targets: [Target] = [
    .target(name: "RainCore"),
    .executableTarget(name: "RainProbe", dependencies: ["RainCore"]),
    .testTarget(name: "RainCoreTests", dependencies: ["RainCore"])
]
#if os(macOS)
products.append(.executable(name: "Otsukaresama", targets: ["Otsukaresama"]))
targets.append(.executableTarget(name: "Otsukaresama", dependencies: ["RainCore"], path: "App"))
#endif

let package = Package(
    name: "Otsukaresama",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
