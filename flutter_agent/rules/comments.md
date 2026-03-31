# Code Comments

## Constraints

- **Focus on Business Logic**: Comment on _why_ complex logic exists (business rules, workarounds), rather than _what_ the code does.
- **Trust the Code**: Omit comments if the code's purpose and logic are immediately clear from naming and structure.
- **Maintain Clean History**: Remove unused code and rely on version control (git) to track history.
- **Deliver Polished Code**: Ensure the final output is free of "AI thoughts", step markers, or temporary debugging notes.
- **Document Public APIs**: Use `///` documentation comments for libraries and public members.
- **Standardize Formatting**: Begin all comments with a single space `// Like this` for readability.
- **Refactor First**: Prioritize renaming variables and functions to clarify intent before resorting to comments.
- **No Trailing Comments**: Avoid end-of-line comments that duplicate obvious code behavior.
- **Mark Intentional No-Ops**: If a method intentionally does nothing (for interface/contract reasons), document that explicitly.

## Public API Docs

- **Summary First**: Start doc comments with a single-sentence summary that ends with a period.
- **Placement**: Put doc comments before annotations.
- **Behavioral Details**: Document non-obvious side effects, constraints, and thrown exceptions for public APIs.
- **Throws Section**: For any public function that can throw, list each exception with the triggering condition using the `Throws:` dartdoc convention:
  ```dart
  /// Fetches the user from the remote API.
  ///
  /// Throws [NetworkException] if connectivity is unavailable.
  /// Throws [ParseException] if the response payload is malformed.
  /// Throws [UnauthorizedException] if the session has expired.
  Future<UserDto> fetchUser(String id);
  ```
  Do not document programming errors (`ArgumentError`, `StateError`)—those indicate a caller bug, not a recoverable runtime condition.
- **Avoid Duplication**: Do not document both getter and setter for the same property unless behavior differs.
