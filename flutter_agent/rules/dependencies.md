# Dependency Management Rules

## Selection

- Prefer existing project dependencies and Dart/Flutter SDK features before introducing a new package.
- Add a new dependency only when it provides clear, concrete value that cannot be achieved reasonably with current tooling.
- Avoid overlapping frameworks that duplicate current architecture choices (state management, logging, serialization, DI).

## Quality Gates

- Prefer stable, well-maintained packages with active releases and clear documentation.
- Avoid pre-release versions unless the requirement explicitly depends on unreleased capabilities.
- Keep dependency footprint minimal; remove packages that are no longer used.

## Commands

- Add runtime dependency with `flutter pub add <package>`.
- Add dev dependency with `flutter pub add dev:<package>`.
- Add override only when strictly required and scoped: `flutter pub add override:<package>:<version>`.
- Remove unused dependency with `dart pub remove <package>`.

## Verification

- After dependency changes, run `dart analyze` and relevant `flutter test` suites.
