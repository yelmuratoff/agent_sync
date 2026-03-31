---
name: database
description: When persisting data (Drift/SharedPreferences) and storing secrets securely (flutter_secure_storage).
---

# Data Persistence (Drift, Preferences, Secure Storage)

## When to use

- Drift: large lists/JSON, offline cache, queryable local data.
- SharedPreferences: user settings and small flags (non-sensitive).
- flutter_secure_storage: tokens, credentials, secrets (sensitive).

## Steps

### 1) Drift (SQLite): centralized tables, feature-first DAOs

Tables live in the app database file; DAOs live per feature in `data/datasource/`.

Table example (caching raw JSON by key):

```dart
class CachedOrders extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get data => text()();
  TextColumn get cacheKey => text()();
  DateTimeColumn get cachedAt => dateTime().withDefault(currentDateAndTime)();
}
```

DAO example (delete old → insert new, batch/transaction):

```dart
part 'orders_dao.g.dart';

@DriftAccessor(tables: [CachedOrders])
class OrdersDao extends DatabaseAccessor<AppDatabase> with _$OrdersDaoMixin {
  OrdersDao(super.attachedDatabase);

  Future<void> cacheOrders({required String cacheKey, required List<String> jsons}) async {
    await batch((batch) {
      batch.deleteWhere(cachedOrders, (t) => t.cacheKey.equals(cacheKey));
      batch.insertAll(
        cachedOrders,
        jsons.map((json) => CachedOrdersCompanion.insert(data: json, cacheKey: cacheKey)).toList(),
      );
    });
  }

  Future<List<String>> readOrders({required String cacheKey}) async {
    final query = select(cachedOrders)..where((t) => t.cacheKey.equals(cacheKey));
    return (await query.get()).map((r) => r.data).toList();
  }
}
```

Regenerate Drift code using the project’s existing command (typically `dart run build_runner build -d`).

### 2) SharedPreferences: typed DAO only (no direct getInstance)

Create a typed DAO in the feature datasource folder:

```dart
abstract interface class IOrdersPrefsDao {
  PreferencesEntry<bool> get hasSeenOnboarding;
}

final class OrdersPrefsDao extends TypedPreferencesDao implements IOrdersPrefsDao {
  OrdersPrefsDao({required SharedPreferences sharedPreferences})
      : super(sharedPreferences, name: 'orders'); // => typed_orders

  @override
  PreferencesEntry<bool> get hasSeenOnboarding => boolEntry('has_seen_onboarding');
}
```

Use `.value` and `.setValue()`:

```dart
final seen = prefs.hasSeenOnboarding.value ?? false;
await prefs.hasSeenOnboarding.setValue(true);
```

Never store secrets/tokens/credentials in SharedPreferences.

### 3) Secure storage: flutter_secure_storage for secrets

Wrap `flutter_secure_storage` behind a small interface so it can be mocked in tests:

```dart
abstract interface class ISecureStorage {
  Future<void> write({required String key, required String value});
  Future<String?> read({required String key});
  Future<void> delete({required String key});
}
```

```dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

final class FlutterSecureStorageAdapter implements ISecureStorage {
  FlutterSecureStorageAdapter(this._storage);
  final FlutterSecureStorage _storage;

  @override
  Future<void> write({required String key, required String value}) =>
      _storage.write(key: key, value: value);

  @override
  Future<String?> read({required String key}) => _storage.read(key: key);

  @override
  Future<void> delete({required String key}) => _storage.delete(key: key);
}
```
