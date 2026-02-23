# Architecture Rules

## Feature Boundaries

- Each feature owns presentation + data (and optionally a domain layer) under a single feature.
- Dependency direction is strict: presentation → (domain) → data.

## Layer Constraints (Project Simplifications)

- **Optional Domain Layer**: The Domain layer (Use Cases) is optional. You should only use and add it if there is a concrete necessity for complex business logic that justifies separation. Otherwise, Presentation components (BLoC) can interact directly with the Data layer (Repositories).
- No mapping layer by default: DTOs defined in the data layer are used across layers unless there is a concrete need to split models.

## Separation (Strict)

- Presentation depends on the domain contracts (if present) or directly on the data layer repositories.
- If a Domain layer exists, it has zero Flutter/framework imports.
- Data contains all I/O details and implementations.
- Presentation screens follow a `Screen` + `View` split: `Screen` wires route/dependencies, `View` contains UI for easier widget testing.

## Models & Serialization

- DTOs live in the feature data layer and are immutable.
- Serialization follows the Dart Data Class Generator approach; do not introduce `freezed`/`json_serializable`.

## Packages (Extract When Reused)

- Extract to packages when code is shared across features or needs independent testing:
  - clients (api_client), shared datasources, repositories used by multiple features
  - cross-feature domain contracts/models
  - core utilities (logging, analytics, secure storage wrappers)

## Services (Cross-Cutting Platform Capabilities)

- A _service_ encapsulates a platform capability used by multiple features (e.g., `AnalyticsService`, `NotificationsService`, `LocalStorageService`, `PermissionsService`).
- Services live outside feature boundaries, typically in `lib/src/core/services/` or as dedicated packages.
- Services are injected via the app's `DependenciesContainer`—never accessed as singletons or via a service locator.
- A service has a domain interface and a concrete implementation; features depend only on the interface.
- Do not model a service as a BLoC. Services are stateless helpers exposing methods/streams; they hold no UI state.

## Public API Exports

- Use barrel files for public feature/package APIs to avoid deep, brittle imports.
- Keep exports intentional: expose stable entry points and do not export private internals.
- BLoC files with `part` directives already act as the public entry point for their state/event units.

## Anti-Patterns

- **Service Locator**: Do not use `GetIt` or any global service locator. All dependencies are injected through `DependenciesContainer` or constructor injection. Service locators hide dependencies, prevent compile-time safety, and make testing difficult.
- **Global scope**: Do not use global variables, global singletons, or static mutable state. These create hidden coupling and reduce testability.
