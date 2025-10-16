// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "SwiftCommitGen",
  platforms: [
    .macOS(.v26)
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0")
  ],
  targets: [
    .executableTarget(
      name: "SwiftCommitGen",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "OrderedCollections", package: "swift-collections")
      ],
      linkerSettings: [
        .linkedFramework("FoundationModels")
      ]
    ),
    .testTarget(
      name: "SwiftCommitGenTests",
      dependencies: ["SwiftCommitGen"]
    )
  ]
)
