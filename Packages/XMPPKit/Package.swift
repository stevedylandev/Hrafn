// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XMPPKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "XMPPXML", targets: ["XMPPXML"]),
        .library(name: "XMPPCore", targets: ["XMPPCore"]),
        .library(name: "XMPPTransport", targets: ["XMPPTransport"]),
        .library(name: "XMPPStream", targets: ["XMPPStream"]),
        .library(name: "XMPPClient", targets: ["XMPPClient"]),
        .library(name: "XMPPIM", targets: ["XMPPIM"]),
        // Fake and stand-in servers, for HrafnKit's tests. Not linked by the app.
        .library(name: "XMPPTestSupport", targets: ["XMPPTestSupport"]),
    ],
    targets: [
        // libxml2 ships in the Apple SDKs (MIT). `<libxml/...>` resolves via the
        // sysroot, so no header search paths or pkg-config are needed.
        .systemLibrary(name: "CLibXML2", path: "Sources/CLibXML2"),

        .target(
            name: "XMPPXML",
            dependencies: ["CLibXML2"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "XMPPCore",
            dependencies: ["XMPPXML"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "XMPPTransport",
            dependencies: ["XMPPCore", "XMPPXML"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "XMPPStream",
            dependencies: ["XMPPCore", "XMPPXML", "XMPPTransport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "XMPPClient",
            dependencies: ["XMPPCore", "XMPPXML", "XMPPTransport", "XMPPStream"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // RFC 6121 and the IM extensions: roster, presence, messages, carbons,
        // archive, blocking.
        .target(
            name: "XMPPIM",
            dependencies: ["XMPPCore", "XMPPXML", "XMPPClient"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(name: "XMPPXMLTests", dependencies: ["XMPPXML", "XMPPTestSupport"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "XMPPCoreTests", dependencies: ["XMPPCore", "XMPPTestSupport"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "XMPPTransportTests", dependencies: ["XMPPTransport", "XMPPTestSupport"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        // Scripted fake server shared by the stream and client tests.
        .target(name: "XMPPTestSupport", dependencies: ["XMPPTransport", "XMPPXML"],
                path: "Tests/XMPPTestSupport",
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "XMPPStreamTests", dependencies: ["XMPPStream", "XMPPTransport", "XMPPTestSupport"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "XMPPClientTests", dependencies: ["XMPPClient", "XMPPStream", "XMPPTransport", "XMPPTestSupport"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "XMPPIMTests", dependencies: ["XMPPIM", "XMPPClient", "XMPPStream", "XMPPTransport", "XMPPTestSupport"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
