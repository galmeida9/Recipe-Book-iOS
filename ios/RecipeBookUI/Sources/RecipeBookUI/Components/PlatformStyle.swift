#if os(iOS)
import SwiftUI
import RecipeBookPresentation

// Adopts the current iOS design language (Liquid Glass, refined in iOS 27) while keeping the
// iOS 17 deployment target. Rules, from Apple's HIG "Materials" and "Branding":
//  - Liquid Glass belongs to the control/navigation layer only, never to recipe content.
//  - Standard bars, tab bars, toolbars, sheets and menus pick up glass automatically, so screens
//    use them instead of custom chrome.
//  - Accent colour is reserved for primary actions and status.
// Glass appearance adapts to Reduce Transparency, Increase Contrast and the user's Liquid Glass
// preference automatically, so the UI does not override it.
//
// API gates: iOS 26 APIs use `#available(iOS 26, *)`. iOS 27 toolbar APIs also need the
// iOS 27 SDK, which ships with Xcode 27 / Swift 6.4, so they are wrapped in `#if compiler(>=6.4)`.

// MARK: - Buttons

extension View {
    /// Prominent style for a primary action floating in the control layer (e.g. a bottom action
    /// bar). Liquid Glass on iOS 26+, bordered prominent before.
    @ViewBuilder
    func floatingPrimaryButtonStyle() -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// Hosts a floating bottom control bar. On iOS 26+ `safeAreaBar` gives content beneath it the
    /// system scroll-edge effect, so no opaque background is drawn; earlier versions use the
    /// standard bar material.
    @ViewBuilder
    func bottomControlBar<Bar: View>(isPresented: Bool = true, @ViewBuilder _ bar: () -> Bar) -> some View {
        if !isPresented {
            self
        } else if #available(iOS 26, *) {
            safeAreaBar(edge: .bottom) {
                bar()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }
        } else {
            safeAreaInset(edge: .bottom) {
                bar()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.bar)
            }
        }
    }

    /// Glass capsule for a small custom control group floating over content (iOS 26+). Before
    /// iOS 26 the surrounding `bottomControlBar` material already separates it.
    @ViewBuilder
    func controlGlass() -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: .capsule)
        } else {
            self
        }
    }
}

// MARK: - Navigation

extension View {
    /// Secondary navigation-bar line (iOS 26+). On earlier versions the same information is
    /// already shown in the screen content, so nothing is lost.
    @ViewBuilder
    func navigationSubtitleIfAvailable(_ subtitle: String?) -> some View {
        if #available(iOS 26, *), let subtitle, !subtitle.isEmpty {
            navigationSubtitle(subtitle)
        } else {
            self
        }
    }

    /// Lets the tab bar shrink while reading long content (iOS 26+).
    @ViewBuilder
    func minimizingTabBarOnScroll() -> some View {
        if #available(iOS 26, *) {
            tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}

// MARK: - Toolbar actions

/// One toolbar command. Actions run through the screen's own callbacks/`ActionRunner`.
struct ToolbarAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var role: ButtonRole?
    let action: () -> Void

    init(_ title: String, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.id = title
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.action = action
    }
}

extension View {
    /// Standard toolbar with `primary` actions always reachable and `secondary` actions in the
    /// overflow ("More") menu. On iOS 27 primary actions get high visibility priority so the
    /// system keeps them when space is tight (Dynamic Type, narrow widths) and secondary actions
    /// use the system overflow menu. Earlier versions use `.primaryAction` / `.secondaryAction`.
    @ViewBuilder
    func adaptiveToolbar(primary: [ToolbarAction], secondary: [ToolbarAction]) -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27, *) {
            toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    ForEach(primary) { ToolbarActionButton(action: $0) }
                }
                .visibilityPriority(.high)
                if !secondary.isEmpty {
                    ToolbarOverflowMenu {
                        ForEach(secondary) { ToolbarActionButton(action: $0) }
                    }
                }
            }
        } else {
            legacyToolbar(primary: primary, secondary: secondary)
        }
        #else
        legacyToolbar(primary: primary, secondary: secondary)
        #endif
    }

    private func legacyToolbar(primary: [ToolbarAction], secondary: [ToolbarAction]) -> some View {
        toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ForEach(primary) { ToolbarActionButton(action: $0) }
            }
            ToolbarItemGroup(placement: .secondaryAction) {
                ForEach(secondary) { ToolbarActionButton(action: $0) }
            }
        }
    }
}

private struct ToolbarActionButton: View {
    let action: ToolbarAction

    var body: some View {
        Button(action.title, systemImage: action.systemImage, role: action.role, action: action.action)
    }
}
#endif
