#if os(iOS)
import SwiftUI
import UIKit
import RecipeBookPresentation

// Covers and thumbnails. Only real images (user-chosen photos or imported Reel thumbnails) are
// shown as photos; everything else uses an obviously illustrative, non-photographic placeholder
// (tinted gradient + SF Symbol) so nothing pretends to be a picture of the dish.

/// In-memory decoded image cache, keyed by `ImageRef.id`.
@MainActor
final class CoverImageCache {
    static let shared = CoverImageCache()
    private let cache = NSCache<NSString, UIImage>()

    init() { cache.countLimit = 120 }

    func image(for ref: ImageRef) -> UIImage? { cache.object(forKey: ref.id as NSString) }
    func store(_ image: UIImage, for ref: ImageRef) { cache.setObject(image, forKey: ref.id as NSString) }
}

/// Fills its frame with the referenced image, or with a placeholder while loading / when absent /
/// when loading fails (failure is not an error worth interrupting the user for).
@MainActor
struct CoverImage: View {
    let image: ImageRef?
    /// Stable seed for the placeholder tint (book or recipe id).
    let seed: String
    var symbol: String = "fork.knife"
    @Environment(\.recipeBookService) private var service
    @State private var loaded: UIImage?

    var body: some View {
        ZStack {
            if let loaded {
                Image(uiImage: loaded)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                CoverPlaceholder(seed: seed, symbol: symbol)
            }
        }
        .clipped()
        .accessibilityHidden(true)
        .task(id: image) { await load() }
    }

    private func load() async {
        guard let image else { loaded = nil; return }
        if let cached = CoverImageCache.shared.image(for: image) { loaded = cached; return }
        guard let data = try? await service.imageData(image), !Task.isCancelled else { return }
        let decoded = await Task.detached(priority: .userInitiated) { UIImage(data: data)?.preparingForDisplay() }.value
        guard let decoded else { return }
        CoverImageCache.shared.store(decoded, for: image)
        loaded = decoded
    }
}

@MainActor
struct CoverPlaceholder: View {
    let seed: String
    var symbol: String = "fork.knife"

    var body: some View {
        let tint = RecipeBookTheme.tint(for: seed)
        ZStack {
            LinearGradient(colors: [tint.opacity(0.85), tint.opacity(0.55)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { proxy in
                Image(systemName: symbol)
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width * 0.42)
                    .foregroundStyle(.white.opacity(0.28))
                    .rotationEffect(.degrees(-12))
                    .position(x: proxy.size.width * 0.72, y: proxy.size.height * 0.62)
            }
        }
    }
}

/// Square, rounded recipe thumbnail used in lists, the planner and pickers.
@MainActor
struct RecipeThumbnail: View {
    let recipe: RecipeSummary?
    var fallbackSeed: String = "recipe"
    var size: CGFloat = 64

    var body: some View {
        CoverImage(image: recipe?.coverImage, seed: recipe?.id ?? fallbackSeed,
                   symbol: recipe?.mealStyle?.systemImage ?? "fork.knife")
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).strokeBorder(.quaternary))
    }
}

/// Explicit meal-style label. Never shown for unlabelled recipes.
@MainActor
struct MealStyleBadge: View {
    let style: MealStyle
    var prominent = false

    var body: some View {
        Label(style.title, systemImage: style.systemImage)
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(prominent ? Color.white : RecipeBookTheme.accent)
            .background(Capsule().fill(prominent ? AnyShapeStyle(.black.opacity(0.45)) : AnyShapeStyle(RecipeBookTheme.accent.opacity(0.12))))
            .accessibilityLabel("Meal style: \(style.title)")
    }
}

// MARK: - Photo encoding

enum CoverPhotoEncoder {
    /// Downscales so the longest side is at most `maxPixel` and re-encodes as JPEG. Runs off the
    /// main actor. Returns `nil` for data that isn't a readable image.
    static func jpeg(from data: Data, maxPixel: CGFloat = 1600, quality: CGFloat = 0.85) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data) else { return nil }
            let longest = max(image.size.width * image.scale, image.size.height * image.scale)
            let factor = longest > maxPixel ? maxPixel / longest : 1
            let target = CGSize(width: (image.size.width * image.scale * factor).rounded(),
                                height: (image.size.height * image.scale * factor).rounded())
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: target))
            }
            return resized.jpegData(compressionQuality: quality)
        }.value
    }
}
#endif
