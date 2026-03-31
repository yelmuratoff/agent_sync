---
name: testing
description: When writing unit/widget tests for repositories, DTO parsing, and BLoCs using Given/When/Then and mocked I/O.
---

# Testing

## When to use

- Adding a repository, datasource, or parsing logic.
- Implementing or refactoring a BLoC/Cubit.
- Adding regression coverage for a bug.

## Steps

### 1) Organize tests to mirror source folders

- Keep `test/` structure aligned with the source layout so ownership and coverage are obvious.
- Do not add dedicated tests for pure barrel export files.
- Group tests by behavior domain (render/navigation, BLoC event name, repository method name).

### 2) Unit test pure logic first

Prefer tests around:

- parsing/serialization
- mapping and validation logic
- small helpers/services

Example (DTO parsing):

```dart
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('OrderDto parses expected payload', () {
    final dto = OrderDto.fromMap({
      'id': '1',
      'createdAt': '2026-01-01T00:00:00.000Z',
      'timeout_ms': 0,
      'status': 'unknown',
    });

    expect(dto.id, '1');
  });
}
```

### 3) Test repositories with mocked datasources/clients

Use `mocktail` (or your project’s standard) to isolate I/O:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _RemoteMock extends Mock implements IOrdersRemoteDataSource {}

void main() {
  test('repository maps failures to typed exceptions', () async {
    final remote = _RemoteMock();
    when(() => remote.fetchOrders()).thenThrow(Exception('boom'));

    final repo = OrdersRepository(remote: remote);

    expect(repo.getOrders(), throwsA(isA<NetworkException>()));
  });
}
```

### 4) Test BLoCs for success + failure paths

Prefer `bloc_test` and keep expectations explicit:

```dart
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _RepoMock extends Mock implements IOrdersRepository {}

void main() {
  blocTest<OrdersBloc, OrdersState>(
    'emits Loading then Loaded',
    build: () {
      final repo = _RepoMock();
      when(() => repo.getOrders()).thenAnswer((_) async => const []);
      return OrdersBloc(repository: repo);
    },
    act: (bloc) => bloc.add(const OrdersStartedEvent()),
    expect: () => [const OrdersLoadingState(), const OrdersLoadedState(orders: [])],
  );
}
```

If event ordering is part of the expected behavior, separate event dispatches in `act`:

```dart
act: (bloc) async {
  bloc.add(const FirstEvent());
  await Future<void>.delayed(Duration.zero);
  bloc.add(const SecondEvent());
},
```

### 5) Keep widget tests focused

Widget tests should verify:

- key UI states (loading/error/loaded)
- critical interactions
- behavior that can regress, not static constants

Prefer one scenario per test for easier failure diagnosis.

### 6) Use `package:checks` for Assertions

For clearer failure messages and a fluent API, prefer `package:checks` over `matcher`:

```dart
import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

test('validates value', () {
  final value = 42;
  check(value).equals(42);
  check(value).isGreaterThan(0);
});
```

### 7) Keep tests isolated and order-independent

- Keep `setUp`/`tearDown` inside `group(...)` blocks.
- Recreate mutable collaborators per test; avoid shared static mutable state.
- Run randomized ordering periodically in CI to expose hidden coupling:

```bash
flutter test --test-randomize-ordering-seed random
```

### 8) Golden tests

- Tag golden tests consistently (for example `golden`) so they can run separately.
- Use `--update-goldens` only in explicit golden update workflows.

```bash
flutter test --tags golden
flutter test --tags golden --update-goldens
```

### 9) Integration Tests

Use `integration_test` for critical user flows (e.g., login, checkout).

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:my_app/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('full login flow', (tester) async {
    app.main();
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('email_field')), 'test@example.com');
    await tester.tap(find.byKey(const Key('login_btn')));
    await tester.pumpAndSettle();

    expect(find.text('Welcome back!'), findsOneWidget);
  });
}
```
