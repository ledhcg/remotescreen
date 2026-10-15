// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Screon",
    defaultLocalization: "en",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "RFBCrypto", targets: ["RFBCrypto"]),
        .library(name: "RFBKit", targets: ["RFBKit"]),
        .library(name: "RemoteDisplay", targets: ["RemoteDisplay"]),
        .library(name: "InputKit", targets: ["InputKit"]),
        .library(name: "ConnectionKit", targets: ["ConnectionKit"]),
        .library(name: "SessionKit", targets: ["SessionKit"]),
        .library(name: "Localization", targets: ["Localization"]),
        .library(name: "LinkProtocol", targets: ["LinkProtocol"]),
        .library(name: "LinkTransport", targets: ["LinkTransport"]),
        .library(name: "WindowKit", targets: ["WindowKit"]),
        .library(name: "HelperCore", targets: ["HelperCore"]),
    ],
    targets: [
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(
            name: "RFBCrypto",
            // A 4096-bit number in a debug build (-Onone) is ~25 times slower, making each test run cost tens of seconds
            // just to authenticate. Always optimize this target. unsafeFlags is only allowed for root/local packages like this one.
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .target(
            name: "RFBKit", dependencies: ["RFBCrypto", "CZlib"],
            // ZRLE decoding writes pixel by pixel: measured on a real Mac stream (2560x1440), a debug build (-Onone) takes 702 ms per update
            // versus 11 ms optimized, i.e. only 1-2 frames per second on an iPad installed with default Xcode settings. Always optimize the data path.
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .target(
            name: "RemoteDisplay", dependencies: ["RFBKit", "InputKit", "Localization"],
            resources: [.process("Resources")],
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))] // GPU upload, cursor drawing: same hot path
        ),
        // Localized UI string lookup: English is the source (the key string itself), Vietnamese lives in Resources/vi.lproj.
        .target(name: "Localization"),
        .target(
            name: "InputKit", dependencies: ["RFBKit", "Localization"],
            resources: [.process("Resources")]
        ),
        .target(name: "ConnectionKit", dependencies: ["Localization"], resources: [.process("Resources")]),
        .target(
            name: "SessionKit", dependencies: ["RFBKit", "InputKit", "Localization"],
            resources: [.process("Resources")]
        ),
        // App Mode: wire format of the Screon link between the iPad app and the Mac helper. Pure, iOS + macOS.
        .target(name: "LinkProtocol"),
        // App Mode transport: QUIC/TLS over Network.framework, identities, pairing, resume. iOS + macOS.
        .target(name: "LinkTransport", dependencies: ["LinkProtocol"]),
        // App Mode client model: apps, windows, surfaces, coordinates, input routing. Pure logic.
        .target(
            name: "WindowKit", dependencies: ["LinkProtocol", "InputKit", "Localization"],
            resources: [.process("Resources")]
        ),
        // App Mode Mac side: window tracking, capture, encoding, input injection, stage. macOS only (#if os(macOS)).
        .target(
            name: "HelperCore", dependencies: ["LinkProtocol", "LinkTransport", "Localization"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "mock-link-helper",
            dependencies: ["LinkProtocol", "LinkTransport"],
            path: "Tools/mock-link-helper"
        ),
        .executableTarget(
            name: "rfbprobe",
            dependencies: ["RFBKit"],
            path: "Tools/rfbprobe"
        ),
        .testTarget(name: "RFBCryptoTests", dependencies: ["RFBCrypto"]),
        .testTarget(name: "RFBKitTests", dependencies: ["RFBKit", "RFBCrypto"]),
        .testTarget(name: "RemoteDisplayTests", dependencies: ["RemoteDisplay", "RFBKit", "Localization"]),
        .testTarget(name: "InputKitTests", dependencies: ["InputKit", "RFBKit", "Localization"]),
        .testTarget(name: "SessionKitTests", dependencies: ["SessionKit", "RFBKit", "InputKit", "CZlib", "Localization"]),
        .testTarget(name: "ConnectionKitTests", dependencies: ["ConnectionKit", "RFBKit", "Localization"]),
        .testTarget(name: "LinkProtocolTests", dependencies: ["LinkProtocol"]),
        .testTarget(name: "LinkTransportTests", dependencies: ["LinkTransport", "LinkProtocol"]),
        .testTarget(name: "WindowKitTests", dependencies: ["WindowKit", "LinkProtocol", "InputKit", "Localization"]),
        .testTarget(name: "HelperCoreTests", dependencies: ["HelperCore", "LinkProtocol", "LinkTransport", "Localization"]),
    ]
)
