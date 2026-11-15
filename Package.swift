// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RecipeBookCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RecipeBookCore", targets: ["RecipeBookCore"]),
        .library(name: "RecipeBookAuth", targets: ["RecipeBookAuth"])
    ],
    dependencies: [
        .package(url: "https://github.com/google/GoogleSignIn-iOS.git", exact: "9.0.0")
    ],
    targets: [
        .target(name: "RecipeBookCore", path: "ios/RecipeBookCore"),
        .target(name: "RecipeBookAuth", dependencies: [
            "RecipeBookCore",
            .product(name: "GoogleSignIn", package: "googlesignin-ios", condition: .when(platforms: [.iOS]))
        ], path: "ios/RecipeBookAuth"),
        .testTarget(name: "RecipeBookCoreTests", dependencies: ["RecipeBookCore"], path: "ios/RecipeBookCoreTests")
    ]
)
