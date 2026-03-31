---
trigger: always_on
---

# Visual Design & UI Rules

## Theming (Strict)

- **ThemeData**: Define a centralized `ThemeData`.
- **ColorScheme**: Always generate palettes using `ColorScheme.fromSeed`.
- **Extensions**: Use `ThemeExtension` for custom design tokens (colors/styles not in Material).
- **Theme Modes**: When dark mode is supported, define `theme`, `darkTheme`, and `themeMode`.
- **Component States**: Style interactive components with `WidgetStateProperty` in theme definitions.
- **Hardcoding**: Do not hardcode colors or styles in widgets; access everything via `Theme.of(context)`.

## Layout Best Practices

- **Responsive**: Use `LayoutBuilder` or `MediaQuery` for adaptive UIs.
- **Flexibility**:
  - `Expanded`: Fills remaining space.
  - `Flexible`: Shrinks to fit (don't combine with Expanded in same flex).
  - `Wrap`: For overflow safety.
- **Overlays**: Use `OverlayPortal` for complex floating UI (dropdowns, tooltips).

## Typography

- **Scale**: Define a consistent typographic scale in `TextTheme` (display/title/body/label).
- **Families**: Limit app typography to one or two font families for consistency and readability.

## Images & Media

- **Network Images**: Always provide `loadingBuilder` and `errorBuilder` for `Image.network`.
- **Assets**: Declare assets in `pubspec.yaml` and prefer semantic, feature-scoped asset paths.

## Accessibility (A11Y)

- **Contrast**: Ensure text has at least **4.5:1** contrast ratio (or **3:1** for large text).
- **Scaling**: UI must remain usable when system font size is increased (test dynamic type up to 200%).
- **Semantics**: Use `Semantics` widget for screen reader labels.
- **Touch Targets**: Ensure interactive elements are at least 48x48dp.
- **Screen Readers**: Validate critical flows with TalkBack (Android) and VoiceOver (iOS).
