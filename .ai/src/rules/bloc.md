# BLoC / Cubit / Provider Rules

## Defaults

- Use BLoC for feature state and async flows.
- Use Cubit only for small, isolated UI-only state where events/transformers add no value.
- Use Provider only as a lightweight UI controller (e.g., filters); no business logic inside Providers.
- Use `ValueNotifier` (with `ValueListenableBuilder`) for the simplest ephemeral widget-local state (a single toggle, scroll offset, text-field focus) where even Cubit adds unnecessary overhead.

## Core Constraints (BLoC/Cubit)

- Events are `sealed class` hierarchies (manual, no codegen).
- Default state modeling: `sealed class` hierarchies with explicit payload per state.
- Exception: for multi-step forms/progressive input where previous field values must persist, use one immutable state class with a status enum + `copyWith`.
- Do not use `freezed` or `json_serializable` in BLoC/state code.
- Use `EquatableMixin` only when the type has fields that affect equality.
- State subtype names end with `State`; use Dart 3 `switch` for exhaustiveness (no manual “when” APIs).

## Standard State Set (BLoC)

- Initial, Loading, Loaded (with data), Error (message, error, stackTrace).

## Concurrency & Errors (Mandatory)

- Choose an event transformer intentionally:
  - droppable for non-stacking actions (tap spam)
  - restartable for “latest wins” (search, refresh)
  - sequential for strict ordering
- Wrap handlers in try/catch using two-tier error handling:
  - **Known exceptions** (network, parse, cache, timeout): catch with `on KnownException`, emit an error state; do NOT call `onError`.
  - **Unexpected exceptions** (programming bugs, null dereferences): catch with `on Object catch (e, st)`, emit an error state, AND call `onError(e, st)` so the BLoC observer reports them.

## Anti-Patterns (Mandatory)

- Never emit navigation/dialog states from a BLoC (e.g., `ShowDialogState`, `NavigateToHomeState`). BLoC must remain environment-independent. Use `BlocListener` in the widget layer to react to state and trigger navigation or dialogs.
- Never create direct BLoC-to-BLoC dependencies. Synchronize BLoCs exclusively through the widget layer using `BlocListener` or stream subscriptions in `StatefulWidget.initState`.
- Reserve BLoC for async operations and repository interactions. Client-side filtering, toggles, and local UI flags do not belong in a BLoC; use Cubit or `ValueNotifier`.
- When the UI needs to distinguish *why* a success state was reached, store `lastEvent` in the state to allow listeners to differentiate reasons.

## Organization

- Prefer a single `*_bloc.dart` with `part` files for events and states.
