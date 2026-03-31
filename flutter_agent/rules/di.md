# Dependency Injection Rules

## Global DI (Mandatory)

- Use `DependenciesContainer` and access via `context.dependencies` / `context.repository`.
- Do not use GetIt (`get_it`) or other DI containers/service locators.

## Feature Scopes (Mandatory)

- Provide BLoCs through custom Scope widgets (never raw `BlocProvider` in feature UI).
- Every scope exposes (per BLoC it provides):
  - a `BlocScope<...>` constant used for selection and dispatch
  - `ScopeData<T>` getters for derived reads (suffix: `Of`)
  - scope methods for event dispatch (unary/binary, named by action)

## BLoC Creation

- Create BLoCs inside the scope and inject repositories from `context.repository`.
- If needed, dispatch a single “started/init” event immediately after creation.
