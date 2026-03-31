---
name: localization
description: When adding Flutter localizations (gen-l10n), ARB keys, parameters, and pluralization, and wiring localized strings into widgets.
---

# Localization (gen-l10n / intl)

## When to use

- Adding a new screen/feature with user-visible strings.
- Introducing parameters or pluralization.
- Replacing hardcoded strings with localized strings.

## Steps

### 1) Enable Flutter localization generation

Add a `l10n.yaml` (or use your existing config) and ensure Flutter gen-l10n is enabled.

Example `l10n.yaml`:

```yaml
arb-dir: lib/l10n
template-arb-file: app_en.arb
output-localization-file: app_localizations.dart
output-class: AppLocalizations
```

### 2) Add ARB keys (stable and descriptive)

Example `lib/l10n/app_en.arb`:

```json
{
  "@@locale": "en",
  "ordersTitle": "Orders",
  "ordersCount": "{count, plural, =0{No orders} =1{1 order} other{{count} orders}}",
  "@ordersCount": {
    "description": "Shown on the orders screen",
    "placeholders": { "count": { "type": "int" } }
  }
}
```

Avoid concatenation; use placeholders and plural rules.

### 3) Use generated localizations in widgets

```dart
import 'package:flutter/widgets.dart';

Widget build(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  return Text(l10n.ordersTitle);
}
```

### 4) Test critical localization-driven logic

If UI logic depends on localized output (rare), test with a fixed locale and golden/widget tests.

### 5) Support directionality (RTL/LTR)

Use directional widgets and values when layout should mirror by locale:

- `EdgeInsetsDirectional` instead of fixed left/right paddings
- `AlignmentDirectional` and `PositionedDirectional` for mirrored layouts
- `matchTextDirection: true` for icons/images that should mirror in RTL

Validate at least one critical screen in an RTL locale.
