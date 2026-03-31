---
name: error-handling
description: When designing typed exceptions, mapping low-level failures in repositories, and converting errors to UI states via `handleException` and `ISpect.logger.handle`.
---

# Error Handling (Typed, Layered, Testable)

## When to use

- Introducing a new network/storage flow.
- Handling backend error responses and mapping them to domain-level failures.
- Ensuring BLoC error states are consistent and user-safe.

## Steps

### 1) Define explicit exception types

Keep them small and descriptive:

```dart
final class NetworkException implements Exception {
  const NetworkException(this.message, {this.cause});
  final String message;
  final Object? cause;
}

final class TimeoutAppException implements Exception {
  const TimeoutAppException(this.message, {this.cause});
  final String message;
  final Object? cause;
}

final class ParseException implements Exception {
  const ParseException(this.message, {this.cause});
  final String message;
  final Object? cause;
}
```

### 2) Translate low-level failures in the repository

Repository is the boundary that converts transport/storage details into app-level meaning:

```dart
final class OrdersRepository implements IOrdersRepository {
  OrdersRepository({required this.remote});
  final IOrdersRemoteDataSource remote;

  @override
  Future<List<OrderDto>> getOrders() async {
    try {
      final maps = await remote.fetchOrders();
      return maps.map(OrderDto.fromMap).toList();
    } on FormatException catch (e) {
      throw ParseException('Invalid orders payload', cause: e);
    } on TimeoutException catch (e) {
      throw TimeoutAppException('Orders request timed out', cause: e);
    } catch (e) {
      throw NetworkException('Failed to fetch orders', cause: e);
    }
  }
}
```

### 3) Handle exceptions at async boundaries and log safely

When catching, log via ISpect and include stack trace; never log PII or secrets:

```dart
try {
  await repo.getOrders();
} catch (e, st) {
  ISpect.logger.handle(
    exception: e,
    stackTrace: st,
    message: 'Orders load failed',
  );
  rethrow;
}
```

### 4) Convert exceptions into UI state via handleException in BLoC

Use the project’s `handleException` helper to map exceptions to user-facing messages consistently:

```dart
try {
  final orders = await repository.getOrders();
  emit(OrdersLoadedState(orders: orders));
} catch (e, st) {
  handleException(
    exception: e,
    stackTrace: st,
    onError: (message, _, __, ___) => emit(
      OrdersErrorState(message: message, error: e, stackTrace: st),
    ),
  );
}
```

### 5) Test error mapping

Unit test that repositories map failures deterministically:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _RemoteMock extends Mock implements IOrdersRemoteDataSource {}

void main() {
  test('maps unknown errors to NetworkException', () async {
    final remote = _RemoteMock();
    when(() => remote.fetchOrders()).thenThrow(Exception('boom'));
    final repo = OrdersRepository(remote: remote);
    expect(repo.getOrders(), throwsA(isA<NetworkException>()));
  });
}
```
