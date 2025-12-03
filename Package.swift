// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "scg",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .executable(name: "scg", targets: ["SwiftCommitGen"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
  ],
  targets: [
    .executableTarget(
      name: "SwiftCommitGen",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser")
      ],
      linkerSettings: [
        .linkedFramework("FoundationModels")
      ]
    ),
    .testTarget(
      name: "SwiftCommitGenTests",
      dependencies: ["SwiftCommitGen"]
    ),
  ]
)
