// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Phocus2Importer",
    platforms: [
        .macOS(.v12)
    ],
    dependencies: [
        .package(url: "https://github.com/realm/realm-swift.git", from: "10.54.6")
    ],
    targets: [
        .target(
            name: "Phocus2Importer",
            dependencies: [
                .product(name: "RealmSwift", package: "realm-swift")
            ]
        ),
    ]
)
