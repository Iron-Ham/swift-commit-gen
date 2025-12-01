// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "scg",
  platforms: [
    .macOS(.v15)
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
      swiftSettings: [
        .unsafeFlags(
          ["-Xfrontend", "-warn-long-function-bodies=500"],
          .when(configuration: .debug)
        )
      ]
    ),
    .testTarget(
      name: "SwiftCommitGenTests",
      dependencies: ["SwiftCommitGen"]
    ),
  ]
)
