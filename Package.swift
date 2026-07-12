// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AIQuotaBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AIQuotaBar", targets: ["AIQuotaBar"])
    ],
    targets: [
        .target(name: "AIQuotaBarCore"),
        .executableTarget(
            name: "AIQuotaBar",
            dependencies: ["AIQuotaBarCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedLibrary("sqlite3")
            ])
    ],
    swiftLanguageModes: [.v5])
