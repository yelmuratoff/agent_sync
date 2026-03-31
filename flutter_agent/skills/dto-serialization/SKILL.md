---
name: dto-serialization
description: When creating/updating DTOs and (de)serialization using Dart Data Class Generator directives (no freezed/json_serializable).
---

# DTO Serialization (Dart Data Class Generator)

## When to use

- Creating a new DTO for API/persistence.
- Adding fields that require custom mapping (DateTime, Duration, enums, nested DTOs).
- Enforcing the “no freezed/json_serializable/build_runner for models” policy.

## Steps

### 1) Define the DTO as immutable

Prefer `@immutable` + `class` + `const` constructor:

```dart
import 'package:flutter/foundation.dart';

@immutable
class OrderDto {
  const OrderDto({
    required this.id,
    required this.createdAt,
    required this.timeout,
    required this.status,
  });

  final String id;
  final DateTime createdAt; // DateTime.parse(String), toIso8601String()
  final Duration timeout; // $from: Duration(milliseconds: map['timeout_ms'] as int? ?? 0), $to: timeout.inMilliseconds
  final OrderStatus status; // $from: OrderStatus.values.firstWhere((e) => e.name == (map['status'] as String?), orElse: () => OrderStatus.unknown), $to: status.name
}

enum OrderStatus { unknown, pending, paid, cancelled }
```

### 2) Use directives for non-primitive fields

Use field comments to teach the generator how to map complex types:

- `$from:` how to build the value from `map[...]`
- `$to:` how to write the value to a map
- `{value}` / `{field}` / `{key}` placeholders where supported

Avoid `Enum.values.byName(...)` for untrusted input; prefer a safe lookup with a fallback.

Example directives:

```dart
final Duration ttl; // $from: Duration(seconds: map['ttl_sec'] as int? ?? 0), $to: ttl.inSeconds
final int color; // $from: (map['color'] as int?) ?? 0xFF000000, $to: {field}
final OrderStatus status; // $from: OrderStatus.values.firstWhere((e) => e.name == (map['status'] as String?), orElse: () => OrderStatus.unknown), $to: status.name
```

### 3) Handle nested DTOs explicitly

If the payload contains nested maps/lists, keep parsing deterministic:

```dart
final List<OrderItemDto> items; // $from: ((map['items'] as List?) ?? const []).map((e) => OrderItemDto.fromMap(e as Map<String, Object?>)).toList(), $to: items.map((e) => e.toMap()).toList()
```

### 4) Generate the data class using the VS Code extension

Workflow:

- Define fields (and directives) inside the class.
- Place cursor in the class.
- Run “Generate data class” (Dart Data Class Generator).

### 5) Test serialization for critical DTOs

Write round-trip tests for DTOs used in persistence or cross-feature contracts:

```dart
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('OrderDto fromMap/toMap round-trip', () {
    final map = <String, Object?>{
      'id': '1',
      'createdAt': '2026-01-01T00:00:00.000Z',
      'timeout_ms': 1500,
      'status': 'paid',
    };

    final dto = OrderDto.fromMap(map);
    expect(dto.id, '1');
    expect(dto.timeout.inMilliseconds, 1500);

    final back = dto.toMap();
    expect(back['id'], '1');
    expect(back['timeout_ms'], 1500);
    expect(back['status'], 'paid');
  });
}
```
