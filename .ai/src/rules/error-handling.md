# Error Handling Rules

## Exceptions (Typed, Explicit)

- Throw typed exceptions for expected failure modes: network, timeout, parse, cache/storage.
- Do not throw raw strings; do not swallow exceptions.
- Document thrown exceptions in public API dartdoc using the `Throws:` convention:
  ```dart
  /// Throws [NetworkException] if connectivity is unavailable.
  /// Throws [ParseException] if the server response is malformed.
  Future<List<OrderDto>> getOrders();
  ```

## Either/Result Anti-Pattern

- Do not use `Either` or `Result` wrapper types as a replacement for Dart's native `throw`/`catch`. Dart's runtime is inherently throwable (network libraries, JSON parsers, SDK APIs all throw), so mixing Either with try/catch creates inconsistency—solving the same problem two ways.
- Primary cost: Either types lose the automatic stack trace that Dart attaches at the throw site. Stack traces are critical for debugging production issues.
- The correct pattern is typed exceptions (`on NetworkException catch`, `on ParseException catch`) combined with native `throw`/`catch` at every layer boundary.

## Where Errors Are Mapped

- Datasources/clients: throw low-level errors.
- Repositories: translate low-level failures into explicit, feature-meaningful exceptions.

## Logging & Privacy

- For caught exceptions, call `ISpect.logger.handle` and include `exception`, `stackTrace`, `message`.
- Never log PII or secrets (tokens, credentials, session IDs).
