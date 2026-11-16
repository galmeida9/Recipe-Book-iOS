// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RecipeBookCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RecipeBookCore", targets: ["RecipeBookCore"]),
        .library(name: "RecipeBookAuth", targets: ["RecipeBookAuth"]),
        .library(name: "RecipeBookSharedAuth", targets: ["RecipeBookSharedAuth"])
    ],
    dependencies: [
        .package(url: "https://github.com/openid/AppAuth-iOS.git", exact: "2.0.0")
    ],
    targets: [
        .target(name: "RecipeBookCore", path: "ios/RecipeBookCore"),
        .target(name: "RecipeBookAuth", dependencies: [
            "RecipeBookCore",
            "RecipeBookSharedAuth",
            .product(name: "AppAuth", package: "appauth-ios", condition: .when(platforms: [.iOS]))
        ], path: "ios/RecipeBookAuth"),
        .target(name: "RecipeBookSharedAuth", dependencies: [
            "RecipeBookCore",
            .product(name: "AppAuthCore", package: "appauth-ios", condition: .when(platforms: [.iOS]))
        ], path: "ios/RecipeBookSharedAuth"),
        .testTarget(name: "RecipeBookCoreTests", dependencies: ["RecipeBookCore"], path: "ios/RecipeBookCoreTests")
    ]
)
