---
name: effective-commenting
description: Best practices for writing meaningful and clean code comments.
---

# Effective Commenting

## When to use

- Explaining complex business logic or algorithms.
- Documenting public APIs (Data layer → Domain layer).
- Clarifying non-obvious workarounds, hacks, or side effects.
- Warning about potential pitfalls or future refactoring needs.

## Steps

1.  **Assess Necessity**: Review if the code can explain itself; if so, proceed without comments. Only comment if the code cannot convey the full context.
2.  **Clarify via Naming**: Rename methods and variables to describe their purpose explicitly.
3.  **Document Intent**: Write comments that explain the "why" (business context, constraints) behind the implementation.
4.  **Finalize Output**: Ensure only the active, necessary code remains, removing any temporary artifacts or disabled blocks.
5.  **Distinguish Scope**: Use `///` for public API documentation and `//` for internal implementation notes.

## Code

### Bad Examples (Avoid)

```dart
// Step 1: Initialize list of users
// This variable stores user data
final users = <User>[];

// Loop through users to save them
for (var u in users) {
  // validation logic
  if (u.isValid) {
    save(u); // AI thought: saving to database here
  }
}

// Code below is deprecated
// void oldFunction() {
//   print('old logic');
// }
```

### Good Examples

```dart
/// Syncs user data with remote backend.
///
/// Throws [SyncException] if network fails or data is invalid.
Future<void> syncUser() async {
  // Use a LinkedHashMap to preserve insertion order for UI rendering,
  // as the backend returns unordered JSON but order matters here.
  final cache = <String, User>{};

  try {
    await _api.fetch();
  } catch (e) {
    // Suppress 404 errors as they indicate "no data yet" for this specific
    // endpoint, which is a valid state for new users.
    if (e is NetworkException && e.statusCode == 404) return;
    rethrow;
  }
}

/// Example of self-explanatory code (No comments needed)
bool get isAdult => age >= 18;

```
