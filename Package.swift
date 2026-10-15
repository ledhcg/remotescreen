// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemoteScreen",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "RFBCrypto", targets: ["RFBCrypto"]),
        .library(name: "RFBKit", targets: ["RFBKit"]),
        .library(name: "RemoteDisplay", targets: ["RemoteDisplay"]),
        .library(name: "InputKit", targets: ["InputKit"]),
        .library(name: "ConnectionKit", targets: ["ConnectionKit"]),
        .library(name: "SessionKit", targets: ["SessionKit"]),
    ],
    targets: [
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(
            name: "RFBCrypto",
            // Số lớn 4096-bit chạy ở bản debug (-Onone) chậm hơn ~25 lần, khiến mỗi lần chạy thử tốn cả chục giây
            // chỉ để xác thực. Luôn tối ưu riêng target này. unsafeFlags chỉ được phép với gói gốc/cục bộ như gói này.
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .target(
            name: "RFBKit", dependencies: ["RFBCrypto", "CZlib"],
            // Giải mã ZRLE ghi từng pixel: đo trên luồng thật của Mac (2560x1440), bản debug (-Onone) mất 702 ms mỗi cập nhật
            // so với 11 ms khi tối ưu, tức chỉ 1-2 khung hình/giây trên iPad cài bằng Xcode mặc định. Luôn tối ưu đường dữ liệu.
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .target(
            name: "RemoteDisplay", dependencies: ["RFBKit", "InputKit"],
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))] // tải lên GPU, vẽ con trỏ: cùng đường nóng
        ),
        .target(name: "InputKit", dependencies: ["RFBKit"]),
        .target(name: "ConnectionKit"),
        .target(name: "SessionKit", dependencies: ["RFBKit", "InputKit"]),
        .executableTarget(
            name: "rfbprobe",
            dependencies: ["RFBKit"],
            path: "Tools/rfbprobe"
        ),
        .testTarget(name: "RFBCryptoTests", dependencies: ["RFBCrypto"]),
        .testTarget(name: "RFBKitTests", dependencies: ["RFBKit", "RFBCrypto"]),
        .testTarget(name: "RemoteDisplayTests", dependencies: ["RemoteDisplay", "RFBKit"]),
        .testTarget(name: "InputKitTests", dependencies: ["InputKit", "RFBKit"]),
        .testTarget(name: "SessionKitTests", dependencies: ["SessionKit", "RFBKit", "InputKit", "CZlib"]),
        .testTarget(name: "ConnectionKitTests", dependencies: ["ConnectionKit", "RFBKit"]),
    ]
)
