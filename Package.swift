// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Twinkle",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything that isn't AppKit or WebKit: settings, containers, the
        // session, address parsing, window titles, the filter-list converter.
        // Foundation only, so a Linux or Windows shell could reuse it later.
        .target(
            name: "TwinkleCore",
            path: "Sources/TwinkleCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The macOS app: AppKit windows around WKWebView.
        .executableTarget(
            name: "Twinkle",
            dependencies: ["TwinkleCore"],
            path: "Sources/Twinkle",
            // The UI is main-thread by nature; Swift 6's strict isolation
            // checking would mostly add ceremony around WebKit delegates.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TwinkleCoreTests",
            dependencies: ["TwinkleCore"],
            path: "Tests/TwinkleCoreTests"
        ),
    ]
)
