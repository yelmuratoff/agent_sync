---
name: performance
description: When diagnosing jank, reducing rebuild cost, optimizing lists/rendering, or moving work off the UI thread.
---

# Performance (Measure, Then Optimize)

## When to use

- Jank (missed frames) during scrolling, animations, or screen transitions.
- Slow startup, slow screen open, or large memory usage.
- Large lists/images causing stutters.
- Heavy parsing/formatting done in the UI layer.

## Steps

### 1) Measure first (don’t guess)

Use Flutter DevTools:

- frame chart (UI vs raster time)
- CPU profiler
- memory (leaks, churn)

Define a small “before/after” metric (e.g., 99th percentile frame time while scrolling).

### 2) Reduce rebuild cost

Common wins:

```dart
// Prefer const when possible
const SizedBox(height: 8);
```

```dart
// Keep BLoC states minimal; avoid putting large mutable objects in state.
```

Avoid passing large objects through widget constructors if a selector can read it from a scope/BLoC.

### 3) Make lists lazy and stable

Prefer lazy builders:

```dart
ListView.builder(
  itemCount: items.length,
  itemBuilder: (context, index) => ItemTile(item: items[index]),
)
```

If items can reorder, use stable keys on item widgets.

### 4) Avoid expensive painting

Avoid unnecessary `Opacity`, `Clip.*`, and patterns that trigger saveLayer unless needed.

### 4b) Isolate frequent repainters with RepaintBoundary

Wrap any widget driven by an `AnimationController`, `Ticker`, or high-frequency stream:

```dart
RepaintBoundary(
  child: AnimatedCounter(value: elapsed),
)
```

When to apply: DevTools "Highlight Repaints" shows the parent tree flashing on every animation frame.

Caution: Do not wrap everything—`RepaintBoundary` allocates an extra layer and increases GPU memory. Apply only where profiling identifies propagating repaints as the bottleneck.

### 5) Move heavy work off the UI thread

Use isolates/compute for:

- large JSON parsing
- heavy mapping/sorting
- complex formatting

```dart
final result = await Isolate.run(() => heavyWork(input));
```

### 6) Keep performance fixes testable

Refactor heavy logic into pure functions/classes so it can be unit tested and benchmarked in isolation.
