// swift-tools-version: 6.0
import PackageDescription

/// OMEMO end-to-end encryption (XEP-0384): the X3DH key agreement, the Double
/// Ratchet and the wire formats of OMEMO 0.3 (`eu.siacs.conversations.axolotl`),
/// written from the specifications, and the XEP-0384 protocol over XMPPKit.
/// Kept out of XMPPKit, which stays
/// dependency-free: the Edwards-curve operations CryptoKit does not expose
/// (XEdDSA) come from libsodium.
let package = Package(
    name: "OMEMOKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OMEMOCrypto", targets: ["OMEMOCrypto"]),
        .library(name: "OMEMOProtocol", targets: ["OMEMOProtocol"]),
    ],
    dependencies: [
        .package(path: "../XMPPKit"),
        // ISC. On the licence allowlist in scripts/license-audit.sh. Only the
        // C library (`Clibsodium`) is used, not the Swift wrapper.
        .package(url: "https://github.com/jedisct1/swift-sodium.git", from: "0.9.1"),
    ],
    targets: [
        .target(
            name: "OMEMOCrypto",
            dependencies: [.product(name: "Clibsodium", package: "swift-sodium")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The XML of XEP-0384, PEP, and the engine that ties sessions to JIDs.
        .target(
            name: "OMEMOProtocol",
            dependencies: [
                "OMEMOCrypto",
                .product(name: "XMPPCore", package: "XMPPKit"),
                .product(name: "XMPPXML", package: "XMPPKit"),
                .product(name: "XMPPClient", package: "XMPPKit"),
                .product(name: "XMPPIM", package: "XMPPKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "OMEMOProtocolTests", dependencies: [
                        "OMEMOProtocol", "OMEMOCrypto",
                        .product(name: "XMPPCore", package: "XMPPKit"),
                        .product(name: "XMPPXML", package: "XMPPKit"),
                        .product(name: "XMPPIM", package: "XMPPKit"),
                        .product(name: "XMPPClient", package: "XMPPKit"),
                        .product(name: "XMPPStream", package: "XMPPKit"),
                        .product(name: "XMPPTransport", package: "XMPPKit"),
                        .product(name: "XMPPTestSupport", package: "XMPPKit"),
                    ],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "OMEMOCryptoTests", dependencies: ["OMEMOCrypto", .product(name: "Clibsodium", package: "swift-sodium")],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
