#if os(iOS)
import SwiftUI
import UIKit

/// Custom "Continue with Google" button following Google's Sign in with Google branding guidelines
/// (developers.google.com/identity/branding-guidelines): light theme in Light Mode, dark theme in
/// Dark Mode, pill shape, iOS padding 16 / 12 / 16, and the official 20 pt standard-colour "G"
/// taken unmodified from Google's signin-assets bundle. Google's brand colours are intentionally not
/// replaced by the app accent or Liquid Glass. The text uses the system font so it scales with
/// Dynamic Type; the logo stays at its fixed size as the guidelines require.
@MainActor
struct GoogleSignInButton: View {
    let isRunning: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    private static let title = "Continue with Google"

    private var isDark: Bool { colorScheme == .dark }
    private var fill: Color { isDark ? Color(hex: 0x131314) : Color(hex: 0xFFFFFF) }
    private var stroke: Color { isDark ? Color(hex: 0x8E918F) : Color(hex: 0x747775) }
    private var textColor: Color { isDark ? Color(hex: 0xE3E3E3) : Color(hex: 0x1F1F1F) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                logo
                Text(Self.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(textColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if isRunning {
                    ProgressView()
                        .tint(textColor)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(stroke, lineWidth: 1))
            .contentShape(Capsule())
            .opacity(isEnabled && !isRunning ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .disabled(isRunning)
        .accessibilityLabel(isRunning ? "\(Self.title), in progress" : Self.title)
    }

    @ViewBuilder
    private var logo: some View {
        if let image = UIImage(named: isDark ? "GoogleG-dark" : "GoogleG-light", in: .module, with: nil) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        }
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
#endif
