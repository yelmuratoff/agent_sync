---
name: routing
description: When adding screens, deep links, or complex navigation flows using `go_router`.
---

# Routing (GoRouter)

## When to use

- Adding a new screen or feature entry point.
- Implementing deep linking or redirection (e.g., AuthGuard).
- Passing arguments between screens.

## Setup

Define a centralized `local_router.dart` (or similar) in `core/router/` or `app/router/`.
Prefer nested/sub-routes over a flat list so deep links and back navigation remain predictable.

```dart
final goRouter = GoRouter(
  initialLocation: '/',
  debugLogDiagnostics: true,
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const HomePage(),
      routes: [
        GoRoute(
          path: 'details/:id',
          builder: (context, state) {
            final id = state.pathParameters['id']!;
            return DetailPage(id: id);
          },
        ),
      ],
    ),
  ],
);
```

## Best Practices

### 1) Type-Safe Arguments

**Preferred: `go_router_builder` with `@TypedGoRoute`**

When `go_router_builder` is available, annotate route data classes:

```dart
@TypedGoRoute<OrdersRoute>(name: 'orders', path: '/orders')
@immutable
class OrdersRoute extends GoRouteData {
  const OrdersRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return const OrdersScreen();
  }
}

// With parameters:
@TypedGoRoute<OrderDetailRoute>(name: 'order-detail', path: '/orders/:id')
@immutable
class OrderDetailRoute extends GoRouteData {
  const OrderDetailRoute({required this.id});
  final String id;

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return OrderDetailScreen(id: id);
  }
}

// Navigate:
const OrdersRoute().go(context);
OrderDetailRoute(id: orderId).go(context);
```

**Fallback (no go_router_builder)**: Use `goNamed` with string constants defined in a central route-names file. Never inline path strings in widget code.

- Use path parameters for IDs (e.g. `details/:id`).
- Use query parameters for filtering/sorting state (for example: `?status=paid&page=2`).
- Use `extra` for complex objects **only if necessary**. Prefer passing an ID and refetching data to ensure the screen is independent and deep-linkable.
- Prefer typed routes or `goNamed` over raw path strings where possible.
- Keep route path segments lowercase `kebab-case` (for example `user/update-address`).

### 2) Redirects (Guards)

- implement `redirect` logic at the top level or per-route.

```dart
redirect: (context, state) {
  final isLoggedIn = authBloc.state.isAuthenticated;
  final isLoggingIn = state.uri.path == '/login';

  if (!isLoggedIn && !isLoggingIn) return '/login';
  if (isLoggedIn && isLoggingIn) return '/';

  return null;
},
```

### 3) Navigation

- Use `context.go('/details/123')` or `context.goNamed(...)` for normal app/deep-linkable navigation.
- Use `context.push('/details/123')` when the route is transient and should return a result on pop.
- Prefer `BuildContext` extensions (`context.goNamed`, `context.pushNamed`) over `GoRouter.of(context)` for consistency.
