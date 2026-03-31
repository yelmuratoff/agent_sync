# Data Persistence Rules

## Technology Selection

- Drift (SQLite): large lists/JSON, offline cache, queryable data.
- SharedPreferences: user settings and small flags only.
- flutter_secure_storage: secrets/tokens/credentials only.

## Drift (SQLite)

- Centralize table definitions in the app database file.
- Put DAOs in `features/<feature>/data/datasource/` (feature-first).
- Cache strategy: delete old records, then insert new in a single batch/transaction.

## SharedPreferences

- Do not call `SharedPreferences.getInstance()` inside features.
- Always use `TypedPreferencesDao` with a per-feature namespace (`typed_<feature>`).
- Never store secrets, tokens, or credentials in SharedPreferences.

## Secure Storage (Mandatory For Secrets)

- Store tokens/credentials/secrets only via `flutter_secure_storage`.
- Wrap secure storage behind a small interface/package so it is mockable in tests.
