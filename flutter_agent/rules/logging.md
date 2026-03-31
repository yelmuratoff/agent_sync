# Logging Rules

## Mandatory

- Always use `ISpect.logger`.
- Do not use `print`, `debugPrint`, or `log`.

## Error Handling

- For caught exceptions, call `ISpect.logger.handle` and include: exception, stackTrace, message.

## Security & Privacy

- Never log PII or secrets (tokens, credentials, session IDs).
- Sanitize user-provided strings before logging (truncate, remove identifiers).
