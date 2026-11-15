// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RecipeBookCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RecipeBookCore", targets: ["RecipeBookCore"]),
        .library(name: "RecipeBookAuth", targets: ["RecipeBookAuth"])
    ],
    targets: [
        .target(name: "RecipeBookCore", path: "ios/RecipeBookCore"),
        .target(name: "RecipeBookAuth", dependencies: ["RecipeBookCore"], path: "ios/RecipeBookAuth"),
        .testTarget(name: "RecipeBookCoreTests", dependencies: ["RecipeBookCore"], path: "ios/RecipeBookCoreTests")
    ]
)
