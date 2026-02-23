# Networking Rules

## Boundaries

- UI (widgets) never performs network calls directly.
- Repositories call datasources/clients; datasources own request/response details.
- All networking dependencies are injected (no singletons in feature code).

## Reliability

- Set explicit timeouts for requests and parsing.
- Translate low-level failures into explicit error types (network/timeout/parse).
- Do not retry blindly; retries must be intentional and bounded.

## Auth Token Refresh (Interceptor Pattern)

When implementing authenticated APIs, use three collaborating components:

- **TokenStorage**: Stores the token pair in `flutter_secure_storage` (never `SharedPreferences`). Exposes a `Stream<T?>` for real-time token change notification. Provides `save`, `load`, and `clear` methods.
- **AuthorizationClient**: Validates JWT expiry locally and calls the refresh endpoint. Throws `RevokeTokenException` when the refresh token itself is invalid—triggering logout.
- **OAuthInterceptor (SequentialInterceptor)**: Attaches `Authorization: Bearer <token>` to every request. On a 401 response, acquires a sequential lock so concurrent requests do not each trigger their own refresh—only the first refresh fires; subsequent 401s await its result and retry with the new token. Calls `TokenStorage.clear()` and triggers logout on `RevokeTokenException`.

Constraints:
- The interceptor must use a mutex/sequential lock to prevent N concurrent 401 responses from triggering N separate refresh calls.
- Token refresh is bounded: one retry per original request; on second failure, revoke and sign out.

## Parsing

- Do not parse large JSON on the UI thread; use background parsing (compute/isolates).
- DTO construction must be deterministic and testable.

## Testing

- Unit test repositories with mocked clients/datasources.
- Avoid real HTTP in unit tests; use integration tests only when explicitly requested.
