---
name: dependencies
description: When evaluating, adding, updating, or removing pub.dev packages while preserving existing architecture and project conventions.
---

# Dependency Management

## When to use

- Adding a package for a new feature.
- Replacing an existing package.
- Adding/removing dev tooling dependencies.
- Investigating whether a package should be removed.

## Steps

### 1) Validate necessity first

- Confirm the problem cannot be solved with current project dependencies or Dart/Flutter SDK APIs.
- If a package is still needed, define the exact capability gap it fills.

### 2) Evaluate candidate quality

Check package fitness before adding:

- maintenance signal (recent stable releases, issue activity)
- documentation quality and usage examples
- compatibility with current architecture and target platforms
- risk of overlap with existing stack (state management, DI, logging, serialization)

### 3) Add dependency with correct scope

Use the standard commands:

```bash
flutter pub add <package>
flutter pub add dev:<package>
flutter pub add override:<package>:<version>
dart pub remove <package>
```

Only use overrides when strictly required and time-bound.

### 4) Verify the integration

- run `dart analyze`
- run targeted `flutter test` for changed areas
- remove imports/usages of replaced packages to avoid dead dependencies

### 5) Document the decision briefly

When introducing a new package, state:

- why current stack was insufficient
- why this package was selected over alternatives
- rollback/removal condition if the package is temporary
