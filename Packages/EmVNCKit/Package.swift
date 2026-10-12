// swift-tools-version: 6.0

import PackageDescription

// Note on SwiftData: the models in EmVNCCore conform to PersistentModel by hand instead of using @Model,
// because the SwiftDataMacros compiler plugin ships only with Xcode, not with the Command Line Tools.
// The hand-written conformance compiles identically under both toolchains.

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5)
]

let package = Package(
    name: "EmVNCKit",

    platforms: [
        .macOS(.v14)
    ],

    products: [
        .library(name: "EmVNCCore", targets: [ "EmVNCCore" ])
    ],

    dependencies: [
        .package(path: "../RoyalVNCKit")
    ],

    targets: [
        // Models, persistence, Keychain, screenshots, clipboard sync, keyboard mapping, VNC engine adapter
        .target(
            name: "EmVNCCore",
            dependencies: [
                .product(name: "RoyalVNCKit", package: "RoyalVNCKit")
            ],
            swiftSettings: swiftSettings
        ),

        .testTarget(
            name: "EmVNCCoreTests",
            dependencies: [ "EmVNCCore" ],
            swiftSettings: swiftSettings
        )
    ]
)
