# Routing Rules

## Libraries

- Use `go_router` exclusively for navigation and deep linking.
- Do not use `Navigator` 1.0 (push/pop) directly unless wrapping a legacy imperative flow is unavoidable.

## Structure

- Define a centralized `GoRouter` configuration (e.g., in `core/router/`).
- Prefer nested/sub-routes over a flat root-level route list to preserve hierarchy and back navigation semantics.
- Use separate route files or static constants for route paths/names to avoid string literals in UI code.

## Type Safety

- Prefer typed routes using `go_router_builder`. Annotate route data classes with `@TypedGoRoute<RouteDataClass>` and extend `GoRouteData`. This eliminates path-string typos at compile time and makes refactoring safe:
  ```dart
  @TypedGoRoute<OrdersRoute>(name: 'orders', path: '/orders')
  @immutable
  class OrdersRoute extends GoRouteData {
    const OrdersRoute();
    @override
    Widget build(BuildContext context, GoRouterState state) => const OrdersScreen();
  }
  // Navigate:
  const OrdersRoute().go(context);
  ```
- Fall back to `goNamed` with string constants in a central route-names file only when `go_router_builder` is unavailable.
- Prefer route names (`goNamed`/typed route APIs) over raw path strings where possible.
- Use path params for resource identity and query params for filtering/sorting state.
- Pass complex objects via `extra`, but prefer passing IDs and re-fetching data in the new screen's BLoC/Repository.

## Navigation Semantics

- Prefer `go`/`goNamed` for normal app navigation and deep-linkable flows.
- Use `push`/`pushNamed` when you need a result back from transient routes (dialogs, pickers, short-lived flows).
- Prefer `BuildContext` navigation extensions (`context.goNamed`, `context.pushNamed`) over direct `GoRouter.of(context)` calls.
- Keep URL path segments lowercase `kebab-case` (for example: `/user/update-address`).
