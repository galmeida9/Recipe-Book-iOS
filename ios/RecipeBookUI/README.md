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

## Validation status

- `Tests/RecipeBookPresentationTests` cover the portable rules (`swift test`). **They have not been run.** No Swift toolchain was available in the Windows authoring environment.
- SwiftUI sources have been reviewed but **never compiled**. No native build, simulator, Xcode preview or iPhone visual or VoiceOver review has been done. These remain open gates.
