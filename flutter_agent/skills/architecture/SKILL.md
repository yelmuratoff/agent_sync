---
name: architecture
description: When creating/refactoring features, DTOs, and packages under the feature-first Clean Architecture standard.
---

# Feature-First Clean Architecture

This project uses a feature-first Clean Architecture with intentional simplifications:

- BLoC talks directly to repository interfaces (no “use case” layer).
- DTOs are used across layers by default (no mapping layer by default).

## When to use

- Creating a new feature folder (UI + domain + data).
- Adding a new DTO or updating serialization.
- Deciding whether shared code belongs in a feature or must be extracted into a package.
- Refactoring code that violates dependency direction (presentation importing data, etc.).

## Steps

### 1) Decide: feature vs package

Extract code into a package when it is reused across features or must be independently testable:

- shared clients (e.g., `api_client`), shared datasources, shared repositories
- cross-feature domain contracts/models
- core utilities (logging, analytics, secure storage wrappers, typed preferences)

Otherwise, keep code inside the owning feature.

### 2) Create the feature slice

Use a single feature folder that owns its UI, domain contract, and data implementation:

```text
lib/src/features/<feature>/
  presentation/
    bloc/
    screen/
    widget/
  domain/
    <feature>_repository.dart
  data/
    datasource/
    models/
    repository/
```

Dependency direction:

- `presentation/` imports only `domain/` (and shared packages), never `data/`.
- `domain/` contains only Dart code (no Flutter imports).
- `data/` implements domain interfaces and contains all I/O details.

Presentation convention:

- `<Feature>Screen`: route/dependency wiring only.
- `<Feature>View`: UI implementation only (easy to test with mocked dependencies).

### 3) Define domain contracts (interfaces, types)

Keep domain minimal and stable:

- Repository interfaces return DTOs by default.
- Errors are explicit and typed (network/parse/cache/timeout).

Example repository interface:

```dart
abstract interface class IOrdersRepository {
  Future<List<OrderDto>> getOrders();
}
```

### 4) Implement data (datasources + repo)

Data layer owns:

- remote/local datasources (HTTP, DB, prefs, secure storage)
- DTO definitions
- repository implementations that translate low-level failures into explicit exception types

### 5) DTOs + serialization (Dart Data Class Generator)

DTOs are immutable and generated via the VS Code “Dart Data Class Generator” extension.

Base shape:

```dart
import 'package:flutter/foundation.dart';

@immutable
final class OrderDto {
  const OrderDto({
    required this.id,
    required this.createdAt,
    required this.timeout,
  });

  final String id;
  final DateTime createdAt; // DateTime.parse(String), toIso8601String()
  final Duration timeout; // $from: Duration(milliseconds: map['timeout'] as int? ?? 0), $to: timeout.inMilliseconds
}
```

Directives you may use in field comments:

- `$from:` construct the value from the raw map
- `$to:` write the value back into a map
- `{value}` / `{field}` / `{key}` placeholders for dynamic generation

### 6) Splitting API vs domain models (rare)

Default: do not split. Use DTOs across layers.

Split only when forced by a concrete reason:

- external API model is unstable/huge and would leak into UI or tests
- you need to enforce domain invariants that the API does not guarantee
- security/privacy requires a “safe” domain model (e.g., redacted fields)

If you split, keep mapping explicit and minimal, and document why.

### 7) Expose stable public APIs with barrel files

For reusable feature/package surfaces:

- create folder-level barrel files for public units
- provide a single top-level entry barrel for consumers
- avoid exporting private/internal-only files

For BLoC state/event units built with `part` directives, the `*_bloc.dart` file is already the entry point and does not need an additional barrel.
