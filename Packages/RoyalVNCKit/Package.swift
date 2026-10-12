// swift-tools-version: 6.0

// Vendored fork of RoyalVNCKit (https://github.com/royalapplications/royalvnc).
// Upstream revision: 090b96eddeee183e9fec293c5cd881d302a4349d (2026-09-21, repository archived 2026-10).
// See PATCHES.md for every change made against upstream.

import PackageDescription

let package = Package(
    name: "RoyalVNCKit",

    platforms: [
        .macOS(.v14)
    ],

    products: [
        // Upstream builds a dynamic library with library evolution enabled. emvnc links it
        // statically so the app bundle does not need an embedded framework.
        .library(
            name: "RoyalVNCKit",
            targets: [ "RoyalVNCKit" ]
        )
    ],

    dependencies: [
        // Pinned to the exact revision recorded in upstream's Package.resolved instead of a moving branch.
        .package(url: "https://github.com/royalapplications/CryptoSwift.git",
                 revision: "a59b4d91ebb22011656c830f874fe7152e183a57")
    ],

    targets: [
        .target(
            name: "RoyalVNCKit",

            dependencies: [
                "d3des",
                "Z",
                .product(name: "CryptoSwift", package: "CryptoSwift")
            ],

            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],

            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),

        .target(name: "d3des"),

        .target(name: "Z", linkerSettings: [
            .linkedLibrary("z")
        ]),

        // emvnc fork addition: tests for the RSA-AES crypto, record layer, Extended Clipboard and pointer input
        .testTarget(
            name: "RoyalVNCKitTests",
            dependencies: [ "RoyalVNCKit" ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
