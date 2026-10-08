// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Computah",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Computah", targets: ["Computah"])],
    dependencies: [
        // Local Parakeet TDT v3 speech recognition on the Apple Neural Engine.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .target(name: "ComputahCore", resources: [.process("Prompts")]),
        .executableTarget(name: "Computah", dependencies: ["ComputahCore", .product(name: "FluidAudio", package: "FluidAudio")],
                          resources: [.copy("Resources/Sounds")]),
    ],
    swiftLanguageModes: [.v5]
)
