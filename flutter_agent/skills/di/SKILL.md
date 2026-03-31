---
name: di
description: When adding dependencies, repositories, or feature scopes using `DependenciesContainer` and Scope widgets (no GetIt).
---

# Dependency Injection (DependenciesContainer + Scopes)

## When to use

- Adding a new repository, datasource, client, or service.
- Wiring dependencies into a feature’s BLoC.
- Creating a feature scope widget that provides BLoCs and exposes a small, stable UI API.

## Steps

### 1) Put long-lived dependencies into the container

Conceptually, these live in `DependenciesContainer` (repositories, clients, DAOs, shared utilities).

Access pattern:

```dart
final repo = context.repository.ordersRepository;
final deps = context.dependencies;
```

Do not introduce GetIt or any other global service locator.

### 2) Provide feature state via Scope widgets (not raw BlocProvider)

Instead of sprinkling `BlocProvider` in widgets, create a Scope widget that:

- creates the BLoC(s)
- injects dependencies from `context.repository`
- exposes typed selectors and typed event dispatchers

Template:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:your_app/src/common/presentation/scopes/bloc_scope.dart';

import '../bloc/orders_bloc.dart';
import '../bloc/orders_event.dart';
import '../bloc/orders_state.dart';

final class OrdersScope extends StatelessWidget {
  const OrdersScope({required this.child, super.key});

  final Widget child;

  static const BlocScope<OrdersEvent, OrdersState, OrdersBloc> _scope = BlocScope();

  static ScopeData<bool> get isLoadingOf =>
      _scope.select((state) => state is OrdersLoadingState);

  static UnaryScopeMethod<void> get refresh =>
      _scope.unary((context, _) => const OrdersRefreshEvent());

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => OrdersBloc(
        repository: context.repository.ordersRepository,
      )..add(const OrdersStartedEvent()),
      child: child,
    );
  }
}
```

### 3) Consume in UI via the scope API

```dart
final isLoading = OrdersScope.isLoadingOf(context);
OrdersScope.refresh(context, null);
```

If the scope becomes too large, split by sub-feature scopes rather than exposing raw BLoCs.
