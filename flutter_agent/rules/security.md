# Security Rules

## Baseline

- Treat OWASP Mobile Top 10 and OWASP MASVS as baseline guidance for security-sensitive features.
- For auth/storage/network changes, document threat assumptions and mitigation in the PR or feature docs.

## Secrets & Sensitive Data

- Never hardcode secrets (API keys, client secrets, credentials, signing material).
- Store tokens/credentials only through approved secure storage abstractions.
- Never expose secrets or PII in logs, analytics events, crash reports, or exception messages.

## Network & Validation

- Production traffic must use HTTPS/TLS; plaintext HTTP is allowed only for explicit local development workflows.
- Validate and sanitize untrusted input (user input, deep links, remote payloads) before use or persistence.
- Retries, auth refresh, and token handling must be explicit and bounded.

## Supply Chain

- New dependencies must be screened for maintenance quality and known vulnerabilities before adoption.
- Do not ignore security advisories without a tracked exception and remediation plan.

## Privacy

- Collect and persist only the minimum user data needed for the feature.
- Define data retention and deletion behavior for newly persisted sensitive data.
