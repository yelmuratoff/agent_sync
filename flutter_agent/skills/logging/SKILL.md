---
name: logging
description: When logging or handling exceptions using `ISpect.logger` (no print/debugPrint, no PII).
---

# Logging (ISpect)

## When to use

- Logging operational information (startup, navigation milestones, feature boundaries).
- Logging warnings (non-fatal but important issues).
- Handling and reporting exceptions at async boundaries (BLoC/repository/datasource).

## Steps

### 1) Use ISpect for all logging

```dart
ISpect.logger.info('Orders screen opened');
ISpect.logger.warning('Slow response from orders API');
ISpect.logger.debug('Orders refreshed (count: $count)');
```

Do not use `print`, `debugPrint`, or `log`.

### 2) Use ISpect.logger.handle for caught exceptions

```dart
try {
  await repository.getOrders();
} catch (e, st) {
  ISpect.logger.handle(
    exception: e,
    stackTrace: st,
    message: 'Failed to load orders',
  );
  rethrow;
}
```

### 3) Avoid PII and secrets

Never log:

- tokens, credentials, session identifiers
- emails/phones, names, addresses, IDs
- raw request/response payloads that may include user data

### 4) Attach structured context when safe

If ISpect is configured for structured logging, attach small non-sensitive context:

```dart
ISpect.logger.log(
  'Orders refresh completed',
  key: 'orders_refresh',
  data: {'count': count, 'source': source},
);
```
