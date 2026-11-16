# RecipeBookUI

Original SwiftUI design and screens for **Recipe Book**. This is a local Swift package with two products:

| Product | Platforms | Contents |
| --- | --- | --- |
| `RecipeBookPresentation` | any Swift platform | UI value types, the `RecipeBookService` protocol, and portable presentation rules (permissions, leave rules, quantity parsing, Reel link validation, draft validation, have/need selection, weekly-plan day rules, step ordering) |
| `RecipeBookUI` | iOS 17+ (`#if os(iOS)`) | SwiftUI screens, theme and components |

## Integration

```swift
.package(path: "ios/RecipeBookUI")
```

1. Implement `RecipeBookService` (in `RecipeBookPresentation`) in the app target on top of RecipeBookCore. Every method must map to a real backend operation and throw on failure. Never return fabricated success.
2. Show `RecipeBookRootView(service: adapter, incomingReel: $sharedReelURL)`. This view renders sign-in (a single "Continue with Google" action that calls `signIn()`, plus "Continue without signing in"; no Apple or Microsoft account options), awaiting invite (shows the account ID), profile setup and the tab app: Library, Plan, Shopping and Account. There is no Imports tab. The tab app is used both signed in and as an on-device guest.
3. **Instagram Reels go into a chosen book.**
   - Share Extension: host `ShareReelDestinationView(sharedText:service:onQueued:onCancel:)` over a `ReelShareService`. It asks which account book to save into, or lets the user create one. It calls `onQueued` only after `queueImport` returns, so call `completeRequest` there. Errors stay on screen with Try Again. If the service throws `signInRequired`, the view asks the user to open the app and continue with Google. The view doesn't use `UIApplication.shared`.
   - In the app: `incomingReel`, `ReelImportConfirmView(url:service:onFinished:)` and Add Recipe › Paste Instagram Link all show the same picker. They call `submitImport(url:bookID:)` and then close. Acknowledge the inbox entry in `onFinished`.
   - Processing happens on the server, so it continues with the app closed. Library book covers show "Importing" with a spinner, "N new" for unseen drafts (`reviewRequired && isUnseen`), or a failure marker. All of these come from `importJobs()` grouped by `ImportJob.bookID` (`BookImportActivity.byBook`).
   - Inside the book, each import shows as a card: the backend's `stageDetail` while it works, "Review Recipe" when the draft is ready, or the failure reason with Try Again (when `canRetry`) and Discard. Opening the book calls `markImportSeen(id:)` for unseen drafts; failures are ignored and nothing is decremented locally.
   - Review opens the inline flow with the job's bound book; there's no book picker. Nothing is saved before the user reviews it. Older jobs with no `bookID` still appear as "Imports in progress" on the Library.
4. Images: `imageData(_:)` returns bytes for `ImageRef` covers (books, recipes, imported Reel thumbnails). Saving a draft applies `RecipeDraft.coverImageEdit` (`.unchanged`, `.replace(jpegData:)` from the user's photo pick, or `.remove`). Without an image, the UI draws a clearly non-photographic placeholder.
5. Weekly plan: `readWeek`, `generateWeek`, `replacePlanDay` and `deleteWeek` map to the planner domain. Shopping items carry `origin` (`.manual` or `.generated(PlanProvenance)`). Check generated items through `setShoppingItem`, using the provenance's plan ID and version.

If no service is injected, the app falls back to `UnconfiguredRecipeBookService`, whose every call fails visibly. `PreviewSupport.swift` is compiled only under `DEBUG` for Xcode previews. It is not a demo mode.

## Behaviour rules

- Identity is the account UUID, and there is no email. App access is granted separately by the app administrator (the awaiting-access screen shows the account ID to send them). Book owners add already-active accounts to shared books by account ID; that does not grant app access.
- Import review shows `RecipeDraft.evidenceText` (caption, comments or transcript) as read-only, selectable "Source evidence". The UI never fills recipe fields from it.
- Shared books: everyone can view and add recipes. Owners manage all recipes and members and can appoint several owners. Members edit and delete only their own recipes.
- The last owner of a shared book who leaves or deletes their account must choose a new owner or delete the book. Nobody is promoted automatically.
- Quantities are decimal strings, and `nil` means unknown. Imported amounts marked `amountNeedsReview` block saving until the user sets an amount or taps **Keep Unspecified**.
- An import's destination is chosen before it is queued, and review keeps that book. Older jobs with no book never get one preselected.
- Suggestions come only from saved recipes the user can access. `suggestions()` stays in the contract, but the redesigned UI doesn't show it.
- Weekly plan: the user picks a book and a rule (whole week, weekdays and weekend, or specific days), each with an explicit meal type (simple, more involved or full meal). Every rule expands to seven styles, Monday first. Meal types are only what the user labelled; the UI never infers them. Replacing a day offers other recipes from the same book, labelled matches first, and sends the replacement recipe's own servings (`nil` only when its yield is unknown).
- Shopping shows "Automatic · from your meal plan" items in their own section, separate from "Added by you". Generated rows can be checked but not deleted; they change when the plan changes.
- Recipe editor: add, delete and reorder steps (drag, plus Move Up and Move Down in the context menu and as VoiceOver actions), choose or remove a cover photo, and set the meal type.
- Imported recipes show "Watch on Instagram", which opens the validated canonical `https://www.instagram.com/reel/<id>/` link with the system `openURL`.
- Shopping lists are personal. "Have" checkboxes exclude ingredients the user already has before adding them to a list.

## Guest mode (continue without signing in)

- **Entering guest mode:** sign-in, awaiting-access and profile-setup screens offer "Continue without signing in" or "Continue on this iPhone". These call `continueWithoutSignIn()`, which returns `SessionState.guest`. The UI never falls back to guest mode on an auth error.
- **What guests can use:** the Library, recipes, editor, weekly Plan and Shopping, all using the app's real on-device store. An "On this iPhone" banner says the data is saved only on this device.
- **Sign-in prompts:** sharing (creating a shared book, or Share… on an on-device book), Paste Instagram Link, incoming Reels and the Account tab all show a contextual Google sign-in prompt. A guest service throws `RecipeBookUIError.signInRequired(_:)` for any cloud-only call.
- **After sign-in:** books whose `BookSummary.storage == .onDevice` stay on the device and appear on an "On This iPhone" shelf. Share… on such a book opens an explicit consent sheet. Only after the user confirms does it call `copyLocalBookToAccount(id:kind:)`, which uploads a copy and keeps the original. Nothing is migrated automatically.
- **Signing out from guest mode:** `signOut()` returns to the sign-in screen, and the on-device data is kept.
- **Compatibility:** `continueWithoutSignIn()` and `copyLocalBookToAccount(id:kind:)` are protocol requirements with default implementations that throw. Existing adapters keep compiling, but guest mode doesn't work until the app layer implements them.

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

## Brand assets

- **App icon:** `AppIcon/Assets.xcassets` holds an original, opaque 1024×1024 single-size `AppIcon`, supported from Xcode 14 and iOS 17. It shows a cream recipe book with a herb ribbon and leaf on a terracotta gradient. It's outside `Sources`, so SwiftPM ignores it. The app target adds this catalog and sets `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`.
- **Google sign-in button:** `GoogleSignInButton` follows Google's [Sign in with Google branding guidelines](https://developers.google.com/identity/branding-guidelines):
  - It uses the light theme in Light Mode and the dark theme in Dark Mode, with the specified fill, stroke and text colours.
  - It's a pill with iOS padding of 16, 12 and 16 points.
  - It shows a fixed 20 pt standard-colour "G".
  - `Resources/GoogleG-{light,dark}[@2x,@3x].png` are pixel-exact 20 pt crops of Google's official iOS "Show text=No, Shape=Square" assets from `signin-assets.zip`. They aren't redrawn, recoloured or resampled.
  - Deviation: the label uses the system font, not Google Sans Medium, which isn't bundled. That lets it scale with Dynamic Type.
  - The Google "G" is Google's trademark, used only as the guidelines allow.

## Validation status

- **Simulator fixture showcase (DEBUG + Simulator only):** `FixtureShowcaseView(screen:)` shows the real screens over the preview fixtures, with a "Fixture preview — no live backend or Google sign-in" banner. Pick the screen with `FixtureShowcaseScreen.fromLaunchArguments()`, which reads `-RecipeBookFixtureShowcase sign-in|library|recipe-detail|shopping|plan`. In this mode sign-in and import actions fail visibly. The showcase is compiled out of release and device builds.

- Foundation's hosted macOS CI run 43752216145 built UI checkpoint 0f102aa (integrated as 0b067b5) with Xcode 26.6 / iOS SDK 26.5. In that run, the 15 presentation tests passed and an unconfigured-launch Simulator smoke test ran. No toolchain is available in the Windows authoring environment.
- The redesign (Plan tab, inline import flow, covers, generated shopping, step reordering) has **not been compiled yet**; its new presentation tests have not run.
- The iOS 27-only paths (`#if compiler(>=6.4)`) have **not been compiled yet**. No iPhone visual, VoiceOver or iOS 27 runtime review has been done. These remain open gates.
- The book-scoped share flow (`ShareReelDestinationView`, book badges, pending import cards) has **not been compiled or run**. It needs the app layer's `ReelShareService`, `submitImport(url:bookID:)` and `markImportSeen(id:)`, and a working import provider, before Instagram import can be called ready.
