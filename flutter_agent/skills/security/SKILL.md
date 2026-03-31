---
name: security
description: When handling secrets, authentication tokens, PII, or adding storage/network/logging that could affect user privacy.
---

# Security & Privacy

## When to use

- Storing or reading tokens/credentials/session data.
- Logging user actions, errors, or request context.
- Persisting any user-identifiable data.
- Implementing auth flows or “remember me”.

## Steps

### 1) Classify the data first

Treat as sensitive unless proven otherwise:

- secrets: tokens, API keys, credentials, session IDs
- PII: emails, phones, names, addresses, document numbers
- payloads: request/response bodies may contain secrets or PII

### 2) Apply OWASP baseline for sensitive features

For auth, storage, and network-heavy changes, validate decisions against:

- OWASP Mobile Top 10 (threat categories)
- OWASP MASVS/MAS checklist (implementation verification)

Document threat assumptions and chosen mitigations in PR notes or docs.

### 3) Store secrets only in flutter_secure_storage

Never store secrets in SharedPreferences, Drift, or plain files.

Use a wrapper interface so it is mockable:

```dart
abstract interface class ISecureStorage {
  Future<void> write({required String key, required String value});
  Future<String?> read({required String key});
  Future<void> delete({required String key});
}
```

Inject `ISecureStorage` via `DependenciesContainer` and use it in repositories/datasources.

### 4) Keep auth and storage testable

Test security behavior with fakes:

- fake secure storage (in-memory map)
- fake repositories/clients

Example fake:

```dart
final class InMemorySecureStorage implements ISecureStorage {
  final _store = <String, String>{};

  @override
  Future<void> write({required String key, required String value}) async {
    _store[key] = value;
  }

  @override
  Future<String?> read({required String key}) async => _store[key];

  @override
  Future<void> delete({required String key}) async {
    _store.remove(key);
  }
}
```

### 5) Prefer least-privilege data flow

- UI reads only what it needs (selectors/scopes).
- Avoid passing tokens through widget trees.
- Keep sensitive operations inside repositories/datasources.

### 6) Verify supply-chain and transport safety

- Screen new dependencies for maintenance and known vulnerabilities before adoption.
- Use HTTPS/TLS only for production traffic; never allow plaintext transport in release flows.
