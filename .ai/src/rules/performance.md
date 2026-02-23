# Performance Rules

## General

- Measure before optimizing; use Flutter DevTools and real metrics.
- Avoid work on the UI thread that can be moved to isolates (parsing, heavy transforms).
- Use `compute()` for CPU-intensive tasks (e.g., large JSON parsing, image processing) to prevent frame drops.

## UI & Rendering

- Prefer const widgets and stable keys where appropriate to reduce rebuild cost.
- Use lazy lists for large collections; avoid building huge widget trees at once.
- Avoid expensive effects (saveLayer-heavy patterns, excessive opacity/clip) unless justified.
- Use `RepaintBoundary` to isolate widgets that repaint frequently (animations, clocks, progress indicators, streaming values) from the surrounding tree. Without a boundary, a single animating child can cause the entire ancestor tree to repaint every frame. Verify isolation using DevTools' "Highlight Repaints" toggle.

## Data

- Cache and paginate large datasets; do not load “everything” by default.
- Do not block frames with synchronous I/O.
