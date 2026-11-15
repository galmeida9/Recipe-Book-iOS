# RecipeBookUI

Original SwiftUI design and screens for **Recipe Book**. This is a local Swift package with two products:

| Product | Platforms | Contents |
| --- | --- | --- |
| `RecipeBookPresentation` | any Swift platform | UI value types, the `RecipeBookService` protocol, and portable presentation rules (permissions, leave rules, quantity parsing, Reel link validation, draft validation, have/need selection) |
| `RecipeBookUI` | iOS 17+ (`#if os(iOS)`) | SwiftUI screens, theme and components |

## Integration

```swift
.package(path: "ios/RecipeBookUI")
```

1. Implement `RecipeBookService` (in `RecipeBookPresentation`) in the app target on top of RecipeBookCore. Every method must map to a real backend operation and throw on failure. Never return fabricated success.
2. Show `RecipeBookRootView(service: adapter, incomingReel: $sharedReelURL)`. This view renders sign-in, awaiting invite (shows the account ID), profile setup and the tab app: Library, Cook, Imports, Shopping and Account.
3. For links from the share inbox, set `incomingReel` or present `ReelImportConfirmView(url:service:onFinished:)`. Nothing is submitted without the user tapping Import. Acknowledge the inbox entry in `onFinished`.

If no service is injected, the app falls back to `UnconfiguredRecipeBookService`, whose every call fails visibly. `PreviewSupport.swift` is compiled only under `DEBUG` for Xcode previews. It is not a demo mode.

## Behaviour rules

- Identity is the account UUID, and there is no email. App access is granted separately by the app administrator (the awaiting-access screen shows the account ID to send them). Book owners add already-active accounts to shared books by account ID; that does not grant app access.
- Import review shows `RecipeDraft.evidenceText` (caption, comments or transcript) as read-only, selectable "Source evidence". The UI never fills recipe fields from it.
- Shared books: everyone can view and add recipes. Owners manage all recipes and members and can appoint several owners. Members edit and delete only their own recipes.
- The last owner of a shared book who leaves or deletes their account must choose a new owner or delete the book. Nobody is promoted automatically.
- Quantities are decimal strings, and `nil` means unknown. Imported amounts marked `amountNeedsReview` block saving until the user sets an amount or taps **Keep Unspecified**.
- Import review never preselects a destination book.
- Suggestions come only from saved recipes the user can access.
- Shopping lists are personal. "Have" checkboxes exclude ingredients the user already has before adding them to a list.

## Design language

The design follows the current iOS design language: Liquid Glass, introduced in iOS 26 and refined in iOS 27. It is based on Apple's HIG pages "Materials", "Branding" and "Color", and on the SwiftUI documentation.

- **Navigation and controls use system components.** `TabView` uses `Tab` on iOS 18+ and minimizes on scroll on iOS 26+. Navigation bars, toolbars, sheets, menus and search are standard, so they get Liquid Glass from the system.
- **Glass is limited to the control layer.** Bottom action bars use `safeAreaBar` with the system scroll-edge effect and `.glassProminent` buttons. The shopping add-item field is a single glass capsule. Recipe text, lists and book covers stay opaque and readable.
- **Toolbars keep primary actions reachable.** On iOS 27, primary actions get `.visibilityPriority(.high)` and secondary or destructive actions go in `ToolbarOverflowMenu`. Earlier versions use `.primaryAction` / `.secondaryAction`. See `adaptiveToolbar` in `Components/PlatformStyle.swift`.
- **Color and type are restrained.** The paprika accent is used only for primary actions and status. Serif type is used only for book and recipe headlines; SF is used everywhere else. Custom colors have light, dark and Increase Contrast variants.
- **Accessibility settings are respected.** Reduce Transparency, Increase Contrast and Reduce Motion are honored by the system glass. No custom animations or transparency overrides were added.

Availability: the deployment target stays at iOS 17. Newer APIs sit behind availability guards:
- iOS 18 and iOS 26 APIs: `if #available(...)`.
- iOS 27 APIs (`visibilityPriority`, `ToolbarOverflowMenu`): additionally wrapped in `#if compiler(>=6.4)`, because they need Xcode 27 / Swift 6.4.

## Validation status

- `Tests/RecipeBookPresentationTests` cover the portable rules (`swift test`). **They have not been run.** No Swift toolchain was available in the Windows authoring environment.
- SwiftUI sources have been reviewed but **never compiled**. No native build, simulator, Xcode preview or iPhone visual or VoiceOver review has been done. These remain open gates.
