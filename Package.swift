// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexQuotaFloat",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CodexQuotaFloat", targets: ["CodexQuotaFloat"])
    ],
    targets: [
        .target(
            name: "CodexQuotaCore",
            path: "Sources/CodexQuotaCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "CodexQuotaFloat",
            dependencies: ["CodexQuotaCore"],
            path: "Sources/CodexQuotaFloat"
        ),
        .testTarget(
            name: "CodexQuotaCoreTests",
            dependencies: ["CodexQuotaCore"],
            path: "Tests/CodexQuotaCoreTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
