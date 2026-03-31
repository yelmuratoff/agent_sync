# Analytics Rules

## Mandatory

- Always use `analytics_gen` (no manual event strings).
- Log analytics only through generated, type-safe methods.
- YAML is the single source of truth: `/events/<domain>.yaml`.

## Naming & Types

- Event keys and parameter keys are `snake_case`.
- Use explicit `event_name` for human-readable naming.
- Prefer non-nullable parameters; mark optional only when the data can truly be absent.

## Deprecation

- Deprecate via `deprecated: true` in YAML; do not delete events abruptly.

## Validation

- Before committing analytics changes, run: `dart run analytics_gen:generate --validate-only`.
