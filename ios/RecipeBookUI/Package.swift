// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RecipeBookUI",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RecipeBookUI", targets: ["RecipeBookUI"]),
        .library(name: "RecipeBookPresentation", targets: ["RecipeBookPresentation"]),
    ],
    targets: [
        // Foundation-only presentation values, the UI service contract and portable UI rules.
        .target(name: "RecipeBookPresentation"),
        // SwiftUI screens. Depends only on the presentation contract.
        .target(name: "RecipeBookUI", dependencies: ["RecipeBookPresentation"]),
        .testTarget(name: "RecipeBookPresentationTests", dependencies: ["RecipeBookPresentation"]),
    ]
)
