// swift-tools-version: 6.0
import PackageDescription

// Swift 5 language mode on purpose: AppKit is overwhelmingly main-actor-bound
// legacy API, and strict Swift 6 concurrency checking against it buys us
// nothing here while costing a great deal of annotation noise.
let package = Package(
    name: "cbm",
    platforms: [.macOS("14.0")],
    targets: [
        .executableTarget(
            name: "cbm",
            path: "Sources/cbm",
            // Plain -O, not -Ounchecked: dropping bounds and overflow checks
            // would turn a parsing bug on clipboard data into memory corruption,
            // and buys nothing measurable in a program that spends its time
            // asleep.
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        )
    ]
)
