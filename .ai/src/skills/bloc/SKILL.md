---
name: bloc
description: When implementing feature state using BLoC (default), Cubit (small UI state), or Provider (lightweight UI controllers).
---

# State Management (BLoC Default)

## When to use

- BLoC: default for feature flows, async orchestration, and business-facing UI state.
- Cubit: small UI-only state (toggles, selected tab) where events/transformers are unnecessary.
- Provider: a lightweight UI controller (e.g., filters) when it stays UI-scoped and does not contain business logic.

## Steps

### 1) Choose the right tool

Quick rule:

- If it coordinates async work and talks to repositories: BLoC.
- If it only holds ephemeral UI state: Cubit.
- If it’s a tiny widget-scoped controller and BLoC would be noise: Provider.

State-shape rule:

- Prefer `sealed` states when each state has distinct payloads (`Loading/Loaded/Error`).
- For progressive forms where previously entered values must survive status changes, use one immutable state + enum status + `copyWith`.

### 2) Define events (sealed, manual)

```dart
part of 'orders_bloc.dart';

sealed class OrdersEvent {
  const OrdersEvent();
}

final class OrdersStartedEvent extends OrdersEvent {
  const OrdersStartedEvent();
}

final class OrdersRefreshEvent extends OrdersEvent {
  const OrdersRefreshEvent();
}
```

### 3) Define states (sealed, minimal, Equatable only when needed)

```dart
part of 'orders_bloc.dart';

sealed class OrdersState {
  const OrdersState();
}

final class OrdersInitialState extends OrdersState {
  const OrdersInitialState();
}

final class OrdersLoadingState extends OrdersState {
  const OrdersLoadingState();
}

final class OrdersLoadedState extends OrdersState with EquatableMixin {
  const OrdersLoadedState({required this.orders});

  final List<OrderDto> orders;

  @override
  List<Object?> get props => [orders];
}

final class OrdersErrorState extends OrdersState with EquatableMixin {
  const OrdersErrorState({
    required this.message,
    this.error,
    this.stackTrace,
  });

  final String? message;
  final Object? error;
  final StackTrace? stackTrace;

  @override
  List<Object?> get props => [message, error, stackTrace];
}
```

### 4) Implement the BLoC with explicit concurrency

Pick the transformer intentionally:

- `droppable()` for “tap spam should not queue”
- `restartable()` for “latest wins” (search, refresh)
- `sequential()` for strict ordering

Example with `restartable()`:

```dart
import 'package:bloc/bloc.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:equatable/equatable.dart';

part 'orders_event.dart';
part 'orders_state.dart';

final class OrdersBloc extends Bloc<OrdersEvent, OrdersState> {
  OrdersBloc({required this.repository}) : super(const OrdersInitialState()) {
    on<OrdersEvent>(
      (event, emit) => switch (event) {
        OrdersStartedEvent() => _load(emit),
        OrdersRefreshEvent() => _load(emit),
      },
      transformer: restartable(),
    );
  }

  final IOrdersRepository repository;

  Future<void> _load(Emitter<OrdersState> emit) async {
    emit(const OrdersLoadingState());
    try {
      final orders = await repository.getOrders();
      emit(OrdersLoadedState(orders: orders));
    // Known exceptions: catch specifically, emit error state, do NOT call onError.
    // Unexpected exceptions: fall through to outer catch, call onError(e, st).
    } catch (e, st) {
      handleException(
        exception: e,
        stackTrace: st,
        onError: (message, _, _, _) => emit(
          OrdersErrorState(message: message, error: e, stackTrace: st),
        ),
      );
    }
  }
}
```

### 5) Keep business logic out of widgets

BLoC orchestrates UI state; business rules live in repositories/services (or in small injected helpers).

If the BLoC grows because of data formatting:

- move formatting to DTO extensions
- move procedural logic to an injected service

### 6) Test BLoCs at the boundary

Use `bloc_test` and mock repositories. Cover:

- success path
- expected failures (network/timeout/cache)
- concurrency behavior (e.g., restartable cancels previous)
- order-sensitive event tests (insert `await Future<void>.delayed(Duration.zero)` between `add(...)` calls when needed)

Example:

```dart
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _OrdersRepositoryMock extends Mock implements IOrdersRepository {}

void main() {
  late IOrdersRepository repo;

  setUp(() => repo = _OrdersRepositoryMock());

  blocTest<OrdersBloc, OrdersState>(
    'emits [Loading, Loaded] on success',
    build: () {
      when(() => repo.getOrders()).thenAnswer((_) async => const []);
      return OrdersBloc(repository: repo);
    },
    act: (bloc) => bloc.add(const OrdersStartedEvent()),
    expect: () => [
      const OrdersLoadingState(),
      const OrdersLoadedState(orders: []),
    ],
  );
}
```

### 7) Verify anti-patterns are avoided

Before finishing, check:

- [ ] No `ShowDialog`, `Navigate*`, or other UI-command states emitted from the BLoC. Side effects belong in `BlocListener` in the widget layer.
- [ ] No direct BLoC dependencies in the constructor. BLoC-to-BLoC synchronization must go through the widget layer.
- [ ] Error handling uses two tiers: known exceptions → emit error state only; unexpected exceptions → emit error state AND call `onError(e, st)`.
- [ ] BLoC is not managing simple UI-only state. If it is a toggle or a filter with no async work, downgrade to Cubit or `ValueNotifier`.
- [ ] If the success listener needs to distinguish *why* success was reached, `lastEvent` is stored in the state.
