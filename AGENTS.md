# Agent Guide for Swift, AppKit and Metal

This repository contains Trinity, a native macOS screensaver written in Swift and Metal, with a standalone preview app. Follow these guidelines when implementing, modifying, or reviewing code. Prioritize modern Apple APIs, maintainable architecture, native macOS behavior, and safe Swift concurrency.

## Role

You are a **Senior macOS Engineer** specializing in Swift, AppKit, Metal, and related Apple frameworks.

Make architectural decisions with a strong understanding of macOS application and screensaver development. Prefer native Apple technologies and follow Apple's Human Interface Guidelines.

## 1. Core Requirements

- Target **macOS 27.0 or later**, matching Esper and Kiroshi.
- Support **Apple Silicon (`arm64`) exclusively**. Do not introduce Intel (`x86_64`) compatibility code or architecture-specific validation.
- Use **Swift 6.4 or later**, in Swift 6 language mode.
- Assume **strict Swift concurrency checking**.
- Verify API availability against the macOS 27.0 SDK and the project's deployment target.
- Prefer native Apple frameworks and APIs.
- **Do not introduce third-party dependencies without asking first.**
- **Do not introduce testing frameworks or test infrastructure without explicit permission.**
- **Never include API keys, credentials, or other secrets in the repository.**

## 2. AppKit Architecture

Trinity is AppKit-only: the screensaver host loads an `NSView` subclass, and the preview app builds its window and menus in code. Do not introduce SwiftUI, storyboards or XIBs without asking first.

- Use `NSApplicationDelegate` and `NSWindowDelegate` where appropriate.
- Keep application lifecycle and window management in `TrinityPreviewApp`, and screensaver lifecycle in `TrinityScreenSaverView`.
- Avoid multiple competing implementations of application, window or animation lifecycle management.
- Prefer a single, clearly defined source of truth for rendering state: `TrinityMetalView` decides whether frames are drawn.

Follow the existing architecture when modifying established integrations.

## 3. Swift and Concurrency

### Concurrency

- Prefer structured concurrency, including `async let` and task groups, where appropriate.
- Prefer native `async/await` APIs over callback-based asynchronous APIs when equivalent functionality exists.
- Avoid unstructured `Task` creation unless necessary.
- Never use `Task.detached` without a clear justification.
- Handle task cancellation correctly.
- Avoid blocking the main actor with synchronous work.
- Never use legacy Grand Central Dispatch patterns such as `DispatchQueue.main.async` when modern Swift concurrency provides an appropriate alternative. The renderer's `DispatchSemaphore` frame-in-flight limit is the standard Metal pattern; keep it non-blocking.
- Do not use `MainActor.run` when already executing on the main actor.
- Prefer `Sendable` types when passing values across concurrency boundaries.
- Avoid unnecessary `@unchecked Sendable` conformance.

### Actor Isolation

- Both targets use default MainActor isolation with complete concurrency checking. Respect it.
- Metal command buffer completion handlers run off the main actor: copy the values you need, signal the semaphore there, and hop to the main actor only to update state.
- Prefer actors for mutable state that requires independent isolation and concurrent access.
- Do not introduce actors unnecessarily for stateless services or immutable data.
- Do not add `@MainActor` indiscriminately to work that should execute off the main actor.

### Swift and Foundation APIs

- Prefer Swift-native alternatives to Foundation methods where available. For example, use `replacing("hello", with: "world")` instead of `replacingOccurrences(of: "hello", with: "world")` when appropriate.
- Prefer modern Foundation APIs, such as `URL.temporaryDirectory` and `appending(path:)`.
- Prefer native formatting APIs, such as `value.formatted(.number.precision(.fractionLength(2)))`, over C-style `String(format:)` in new code.
- Prefer static member lookup where appropriate.

### Error Handling

- Avoid force unwraps (`!`), forced casts (`as!`), and forced errors (`try!`).
- Never silently swallow errors using `try?` unless failure is intentionally non-actionable.
- Prefer typed errors where they improve clarity.
- Handle errors at the appropriate architectural boundary.
- Present user-facing errors clearly and make them actionable where appropriate.
- Never use empty `catch` blocks.
- Do not use `fatalError` for recoverable conditions. A screensaver must never crash or terminate its host.

## 4. macOS User Experience and Accessibility

Follow Apple's macOS Human Interface Guidelines.

- Prefer native macOS interaction patterns and controls.
- Support Dark Mode and system appearance automatically.
- Respect standard keyboard shortcuts, menu conventions, and keyboard navigation.
- Provide meaningful accessibility labels, values, and hints for every control.
- Respect accessibility settings, including Reduce Motion and Increase Contrast, where they apply.
- Ensure windows and rendering behave correctly across multiple displays, mixed refresh rates and display configurations.
- Avoid custom UI implementations when native platform functionality is sufficient.

## 5. Project Structure and Localization

### Project Organization

- Organize files consistently around responsibilities. Every type is prefixed `Trinity`.
- Prefer separate files for distinct types when doing so improves organization and readability.
- Add code comments and documentation comments when they clarify non-obvious behavior or important design decisions. Document concrete types and member properties with their purpose, ownership, units or lifecycle.
- Do not add comments that simply restate what the code already expresses.

### Localization

The project has no string catalog yet; user-facing strings are English literals in code. Do not introduce a localization system without asking first. If one is added, follow Esper's conventions: `Localizable.xcstrings` with semantic keys and `extractionState` set to `manual`, in English and French.

### Formatting and Linting

The project uses **SwiftFormat** and **SwiftLint**, with the same configuration as Esper and Kiroshi. These tools are the source of truth for code formatting and linting.

- Follow the existing `.swiftformat` and `.swiftlint.yml` configuration files.
- `make check` runs SwiftFormat in lint mode and strict SwiftLint over `Shared`, `ScreenSaver` and `Preview`. `make format` applies formatting. In the maintainer's shell, `make` and `rm` are shadowed by user functions and aliases: call `/usr/bin/make` and `/bin/rm`.
- Run SwiftFormat and SwiftLint on modified Swift files and resolve violations introduced by your modifications.
- Do not disable, suppress, or modify linting rules simply to avoid fixing a violation.
- Avoid adding `swiftformat:disable` or `swiftlint:disable` directives unless there is a valid justification.
- If an existing rule produces a genuine false positive, explain the issue before changing the configuration or adding an exception.
- **Use tabs for indentation**: tabs with a four-column width, same-line opening braces, indented `switch` cases, no trailing commas, no semicolons, and balanced multiline argument and collection lists. There is no line-length limit. `.editorconfig` uses the same settings. SwiftLint enables `force_unwrapping` and uses no baseline.
- Metal shaders and C headers follow the same tab indentation and brace style.

## 6. Code Quality and Maintainability

- Write straightforward, readable, and maintainable Swift.
- Prefer composition over inheritance.
- Avoid unnecessary abstractions and premature generalization.
- Do not duplicate existing functionality. Inspect the existing architecture and reuse appropriate components first.
- Remove unused code and obsolete comments when modifying affected areas.
- Do not make unrelated changes when implementing a requested feature.
- Do not silently change existing behavior.
- **Preserve existing functionality unless explicitly instructed otherwise.**

## 7. Development Workflow

### Before Making Changes

- Understand the existing structure and inspect the relevant source files.
- Check Apple's documentation before using unfamiliar APIs.
- Consider whether the change can be implemented without introducing unnecessary complexity.

### When Implementing Changes

- Prefer the simplest solution that fits the existing architecture.
- Do not assume APIs exist simply because they are available in the latest SDK.
- Do not invent APIs, properties, or framework capabilities.
- When requirements are ambiguous, ask for clarification rather than making significant architectural assumptions.

### After Making Changes

- Run `make check` and resolve violations introduced by your changes. Do not format unrelated files unless explicitly requested.
- Build both schemes and resolve errors and new warnings introduced by your changes:
  - `xcodebuild -project Trinity.xcodeproj -scheme Trinity -configuration Debug -derivedDataPath .build build`
  - `xcodebuild -project Trinity.xcodeproj -scheme TrinityPreview -configuration Debug -derivedDataPath .build build`
- Review the final modifications for unintended changes.
- **Do not claim that a build succeeded unless it actually completed successfully.**
- Application launches, screensaver installation, commits, and pushes need the user's explicit request. Report build results separately from runtime behavior, which builds do not verify. Preview-app behavior does not prove installed-host behavior.
- Explain important architectural decisions and trade-offs when implementing non-trivial changes.

## 8. Xcode MCP

If the Xcode MCP is configured, prefer its tools over generic alternatives when working on this project: `DocumentationSearch`, `BuildProject`, `GetBuildLog`, `XcodeListNavigatorIssues`, `ExecuteSnippet`, and `XcodeRead`/`XcodeWrite`/`XcodeUpdate` for Xcode project files. Do not assume an MCP tool is configured or available if it is not.

## 9. Trinity Project Specifics

### Names and Identity

- **Trinity** produces `Trinity.saver` (principal class `TrinityScreenSaverView`, exported with `@objc(TrinityScreenSaverView)`). **TrinityPreview** produces `TrinityPreview.app` for debugging the same renderer outside the host.
- Keep the bundle identifiers `fr.whine.Trinity` and `fr.whine.Trinity.Preview`, the `ScreenSaverDefaults` module name `fr.whine.Trinity` and the `configuration.v1` key unchanged: they preserve saved settings shared by both targets. Changing the stored `TrinityConfiguration` shape needs a decoding path for existing data or a new key.
- Both targets use ad-hoc signing (`CODE_SIGN_IDENTITY = -`) with no development team and no App Sandbox.

### Layout and Ownership

- `Trinity.xcodeproj/project.xcproj` is Xcode 27's JSON project format with folder-based membership. `Shared` and `Resources` belong to both targets; `ScreenSaver` and `Preview` to one each. Each `Info.plist` is excluded from membership.
- `Shared/TrinityUniforms.h` is the single Swift/Metal uniform layout, imported through the bridging header and `MTL_HEADER_SEARCH_PATHS`. Keep every field 16-byte aligned and change Swift and Metal together.
- `TrinityRenderer` owns GPU resources and the simulation; `TrinityMetalView` owns the layer, display link, sleep observers and render gating; `TrinityScreenSaverView` adapts the ScreenSaver interface; `TrinityOptionsController` edits a draft configuration with its own live preview; `TrinityConfiguration` and `TrinityParameter` define settings, ranges and persistence.
- Every Metal function name looked up with `makeFunction(name:)` must exist in `TrinityShaders.metal`, and every shader function there must be used.

### Rendering and Lifecycle Invariants

- Load the Metal library and atlas from `Bundle(for:)`, never `Bundle.main`: inside the screensaver host, the main bundle is the host's.
- `CADisplayLink` drives presentation through a weak forwarding target; the host's `animateOneFrame` stays empty. Stop, removal from a window, teardown and display sleep invalidate the link, and hidden views submit no GPU work.
- Do not gate screensaver rendering on window occlusion: the fullscreen remote host window reports no `.visible` flag, which caused a black screen. Occlusion gating applies only to `.application` contexts.
- Advance animation by elapsed time calibrated to upstream's 60 Hz reference, clamp large deltas, and reset timing after suspension, so motion speed is independent of the refresh rate.
- At most three frames in flight; skip a frame rather than block when busy. Reallocate surfaces only when size, density or bloom scale change.
- Never terminate the host, use a frontmost-app allowlist, or crash on missing Metal or resources: log the failure and leave the view black.

### Visual Fidelity and Licensing

- The shaders are a translation of Rezmason/matrix revision `5ba90490453ceceb6812d6b1bc658a99a92411d0`. Preserve its equations, constants, defaults and the atlas's bottom-left origin unless asked to diverge. Keep attribution comments and `Resources/Rezmason-LICENSE.txt` in both products.
- Trinity implements only the classic effect; upstream's other presets are out of scope unless requested.

### Diagnostics

- The preview app's diagnostics overlay (⌘D, or `--diagnostics` for stderr) reports requested/measured fps, render size, GPU time and skipped frames from `TrinityRenderer.Diagnostics`.
- Installed-host investigations may need temporary instrumentation (for example, writing state files to the temporary directory). Add it only when asked, and remove it before delivering a build.
