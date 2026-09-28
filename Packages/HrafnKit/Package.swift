// swift-tools-version: 6.0
import PackageDescription

/// The app's persistence and services: the parts of Hrafn above the protocol
/// that the app, the notification service extension and the share extension
/// all need. Kept out of XMPPKit so the protocol package stays dependency-free.
let package = Package(
    name: "HrafnKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HrafnStore", targets: ["HrafnStore"]),
        .library(name: "HrafnServices", targets: ["HrafnServices"]),
    ],
    dependencies: [
        .package(path: "../XMPPKit"),
        .package(path: "../OMEMOKit"),
        // MIT. On the licence allowlist in scripts/license-audit.sh.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.9.0"),
    ],
    targets: [
        // GRDB/SQLite in the App Group: the single source of truth (PLAN §2.5).
        .target(
            name: "HrafnStore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            resources: [.process("Localizable.xcstrings")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // One session per account: protocol events in, database writes out.
        .target(
            name: "HrafnServices",
            dependencies: [
                "HrafnStore",
                .product(name: "XMPPCore", package: "XMPPKit"),
                .product(name: "XMPPXML", package: "XMPPKit"),
                .product(name: "XMPPTransport", package: "XMPPKit"),
                .product(name: "XMPPStream", package: "XMPPKit"),
                .product(name: "XMPPClient", package: "XMPPKit"),
                .product(name: "XMPPIM", package: "XMPPKit"),
                .product(name: "OMEMOCrypto", package: "OMEMOKit"),
                .product(name: "OMEMOProtocol", package: "OMEMOKit"),
            ],
            resources: [.process("Localizable.xcstrings")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "HrafnStoreTests", dependencies: ["HrafnStore", .product(name: "GRDB", package: "GRDB.swift")],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "HrafnServicesTests", dependencies: [
                        "HrafnServices", "HrafnStore",
                        .product(name: "GRDB", package: "GRDB.swift"),
                        .product(name: "XMPPCore", package: "XMPPKit"),
                        .product(name: "XMPPIM", package: "XMPPKit"),
                        .product(name: "XMPPXML", package: "XMPPKit"),
                        .product(name: "XMPPTransport", package: "XMPPKit"),
                        .product(name: "XMPPClient", package: "XMPPKit"),
                        .product(name: "XMPPStream", package: "XMPPKit"),
                        .product(name: "XMPPTestSupport", package: "XMPPKit"),
                        .product(name: "OMEMOCrypto", package: "OMEMOKit"),
                        .product(name: "OMEMOProtocol", package: "OMEMOKit"),
                    ],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
