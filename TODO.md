# AgentSync — Init/Sync UX Refactor

Цель: сделать так, чтобы после `agentsync init` в проекте лежало **ровно то**, что нужно конкретному пользователю, а не все 15+ конфигов всех поддерживаемых AI-инструментов. Расширить существующую модель «base + override» (которая уже работает для `tools/*.yaml`) на `hooks/`, `mcp/`, `settings/`.

## Принципы

1. **Progressive disclosure** — на старте минимум, остальное подключается явно.
2. **Uniform resource model** — один паттерн (base + override) для всех ресурсов.
3. **Reproducibility** — `sync` из одного `agent_sync.yaml` даёт одинаковый результат везде.
4. **Security-first** — хуки это код, их никогда не scaffold'им молча.
5. **Backward compatibility** — существующие проекты продолжают работать без изменений.
6. **Fallback всегда работает** — удалил override, sync взял base.

## Архитектура «после»

```
Base:     <install-dir>/lib/templates/<resource>/<tool>.<ext>   (shipped)
Override: <repo>/.ai/src/<resource>/<tool>.<ext>                (optional)

resource ∈ { tools, hooks, mcp, settings, commands, skills, agents, rules }
```

Resolver: `user override ?? base`.

`.ai/src/` после init у Claude-only пользователя:
```
.ai/
├── agent_sync.yaml          # tools.enabled: [claude]
└── src/
    ├── AGENTS.md
    └── rules/
        └── core.md
```

---

## Phase 0 — Подготовка (0.5 дня)

Зафиксировать текущее поведение тестами, чтобы ничего не сломать в рефакторе.

- [ ] Снять baseline поведения `agentsync init` (что именно создаётся сейчас) в `tests/fixtures/init_current_snapshot/`.
- [ ] Добавить интеграционный тест `tests/init_snapshot_test.sh`: запуск init во временном каталоге + сравнение дерева с fixture.
- [ ] Снять baseline `sync` с пустым оверрайдом (проверить что все 15 инструментов syncятся из base).
- [ ] Убедиться, что все существующие тесты зелёные перед стартом: `bash tests/run_all.sh`.
- [ ] Создать ветку `feat/lazy-resource-scaffold`.

**Acceptance:** есть snapshot-тест, который падает в Phase 1, подтверждая изменение поведения.

---

## Phase 1 — Минимальный init (быстрая победа, 1–2 дня) ✅ DONE

`init` перестаёт eager-копировать `hooks/mcp/settings` для всех инструментов. Создаёт ресурс только для auto-detected или явно указанных через `--tools`.

### Файлы

- `lib/helpers/init.sh`
- `bin/agentsync.sh` (router: `cmd_init "$@"`)
- `tests/init.bats`, `tests/sync.bats` (фиксация под новое поведение)

### Задачи

- [x] В `_init_copy_source_templates` вынести логику hooks/mcp/settings в отдельную функцию `_init_copy_tool_payloads <ai_dir> <templates_dir> <tool_list>`.
- [x] Функция копирует из `templates/{hooks,mcp,settings}/` **только файлы** `<tool>.{json,yaml,toml}` для `tool ∈ tool_list`.
- [x] Если `tool_list` пуст — не создавать пустые директории `hooks/`, `mcp/`, `settings/` вообще.
- [x] В `cmd_init` принимать флаг `--tools <csv>` (ручной список, union с auto-detect).
- [x] В `cmd_init` принимать флаг `--no-detect` (чистый init без маркеров).
- [x] В `cmd_init` принимать флаг `--content <csv>` где `csv ⊂ {agents,rules,skills,commands,subagents}`. По умолчанию всё.
- [x] Если `--tools` + auto-detect оба дали результат — объединить (union), не override.
- [x] В `_init_print_summary` показывать, **какие именно** payload-файлы скопированы (per-resource счётчики).
- [x] Обновить финальное сообщение: источник (`detect`/`flag`/`mixed`) + step numbering.
- [x] В `_init_create_directories` убрать безусловное `mkdir` для `settings/`, `mcp/`, `hooks/` — делать lazy.
- [x] `_init_create_project_config` корректно пишет `tools.enabled` из объединённого списка.
- [x] Флаг `--help` / `-h` с usage-строкой.
- [x] Валидация unknown `--content` токена с понятной ошибкой.

### Тесты

- [ ] `tests/init_no_tools_test.sh`: `agentsync init --no-detect` → только `AGENTS.md` + `rules/core.md`.
- [ ] `tests/init_auto_detect_claude_test.sh`: подложить `.claude/` → `init` → только `settings/claude.json`, `mcp/claude.json` в `.ai/src/`.
- [ ] `tests/init_explicit_tools_test.sh`: `agentsync init --tools cursor,claude` → payload только для этих двух.
- [ ] `tests/init_content_flag_test.sh`: `--content agents,rules,skills` → есть skills/, нет commands/agents/.
- [ ] `tests/init_union_test.sh`: `--tools claude` + маркер `.cursor/` → enabled: [claude, cursor].
- [ ] Обновить snapshot из Phase 0.

### Acceptance

- [ ] `agentsync init` в пустом каталоге = 3 файла (`.ai/agent_sync.yaml`, `AGENTS.md`, `rules/core.md`).
- [ ] `agentsync init --tools claude` добавляет ровно 2 payload-файла (settings/mcp для claude).
- [ ] Существующие проекты (где уже есть `.ai/src/`) — `init` по-прежнему no-op с warning.
- [ ] `sync` в новом минимальном проекте работает для enabled-инструментов (fallback на base).

### Changelog

- [ ] `BREAKING` в секции CHANGELOG: «init больше не копирует payload'ы для не-enabled инструментов; существующие проекты не затронуты».

---

## Phase 2 — Единый resource resolver (2–3 дня) ✅ DONE

Обобщить `tool_resolver.sh` так, чтобы sync искал hooks/mcp/settings по пути override→base, а не требовал файл в `.ai/src/`.

### Файлы

- `lib/helpers/tool_resolver.sh` — добавлена секция «Payload resolution», функции `resolve_payload_source`, `_find_base_payload`, `_payload_base_dir`.
- `lib/sync.sh` — блоки settings/mcp/hooks переписаны на `resolve_payload_source`.
- `tests/resource_resolver.bats` — новый.
- `tests/sync.bats` — revert тактического фикса; теперь init минимальный, sync тянет из base.

### Задачи

- [x] Ввести функцию `resolve_payload_source <tool> <resource>`:
  - override: `.ai/src/<resource>/<tool>.<ext>` (путь из tool YAML или конвенция)
  - base: `<install-dir>/lib/templates/<resource>/<tool>.*` (glob по расширению)
  - override wins; fallback на base; иначе empty.
- [x] В `sync.sh` блоки settings/mcp/hooks переписаны на новый helper.
- [x] `targets.<resource>.source` в tool YAML остаётся уважаемым (backward compat); если не задан — deriveится из base по convention.
- [x] Override wins verified в demo.
- [x] Base fallback verified в demo (чистый init, enable cursor/windsurf/gemini → sync создаёт hooks/mcp/settings из базы без оверрайдов).
- [x] `tests/sync.bats` setup_file вернул минимальный init.

### Отложено (не блокирует)

- [ ] Дополнить `lib/templates/hooks/` недостающими стартерами для Claude/Gemini/etc. — когда появится реальная необходимость.
- [ ] Очистка `targets.<resource>.source` из tool YAML (cleanup, не функциональное).
- [ ] `simplify` расширение для payload-файлов — включу в Phase 6.

### Тесты

- [ ] `tests/sync_fallback_base_test.sh`: проект без `.ai/src/hooks/` → `sync` создаёт `.cursor/hooks.json` из `lib/templates/hooks/cursor.json`.
- [ ] `tests/sync_override_wins_test.sh`: проект с `.ai/src/hooks/cursor.json` → `sync` использует override.
- [ ] `tests/sync_no_base_no_override_test.sh`: инструмент без base hooks → `sync` молча пропускает (не создаёт пустой файл, не падает).
- [ ] `tests/resource_resolver_unit_test.sh`: таблица случаев resolution order.
- [ ] Regression: все существующие `tests/sync_*` проходят.

### Acceptance

- [ ] Удалил `.ai/src/hooks/cursor.json` → `sync` всё равно создаёт `.cursor/hooks.json` из base.
- [ ] Положил `.ai/src/hooks/cursor.json` → `sync` использует его.
- [ ] `show <tool>` показывает источник каждого ресурса: `(override)` или `(base)`.

---

## Phase 3 — `customize <tool> <resource>` (1 день) ✅ DONE

Расширить `customize` до per-resource. Единственный путь, которым файл появляется в `.ai/src/{hooks,mcp,settings}/`.

### Файлы

- `lib/helpers/customize.sh`
- `bin/agentsync` (роутинг CLI, если меняется сигнатура)
- `README.md` / docs

### Задачи

- [x] Расширить `cmd_customize`: принимать опциональный второй позиционный аргумент `<resource>`.
  - `agentsync customize cursor` → override `tools/cursor.yaml` (как сейчас).
  - `agentsync customize cursor hooks` → копия `lib/templates/hooks/cursor.json` → `.ai/src/hooks/cursor.json`.
  - `agentsync customize cursor mcp` → аналогично для mcp.
  - `agentsync customize cursor settings` → аналогично для settings.
- [x] Валидировать `<resource> ∈ {tool, hooks, mcp, settings}` (extend later).
- [x] Если base-файла для `<resource>/<tool>` нет — ошибка с подсказкой.
- [x] Если override уже есть — то же поведение, что для tools (предупреждение, показать путь).
- [x] Для `hooks` при создании показывать краткое содержимое base + требовать `--yes` или интерактивное подтверждение (security).
- [x] Обновить `cmd_show` и `cmd_diff` чтобы принимали `<resource>`:
  - `agentsync show cursor hooks` → показать effective hooks-файл + откуда он (base/override).
  - `agentsync diff cursor hooks` → дельта override vs base.
- [x] Обновить help-строки в `bin/agentsync`.

### Тесты

- [ ] `tests/customize_hooks_test.sh`: `customize cursor hooks` → файл создан.
- [ ] `tests/customize_hooks_confirm_test.sh`: без `--yes` в non-TTY — отказ; с `--yes` — создаёт.
- [ ] `tests/customize_hooks_existing_test.sh`: повторный вызов → warning, файл не перезаписан.
- [ ] `tests/customize_unknown_resource_test.sh`: `customize cursor bogus` → error.
- [ ] `tests/show_resource_test.sh`: `show cursor hooks` показывает источник.

### Acceptance

- [x] Единственный способ создать файл в `.ai/src/{hooks,mcp,settings}/` — `customize <tool> <resource>`.
- [x] Все существующие вызовы `customize <tool>` работают как раньше.

---

## Phase 4 — Интерактивный init + prompts (1–2 дня) ✅ DONE

TTY-friendly опыт для новичков. `--yes` для автоматизации.

### Файлы

- `lib/helpers/prompts.sh` — новый модуль: `is_tty`, `prompt_confirm`, `prompt_multiselect`.
- `lib/helpers/init.sh` — добавлены `--yes`, `--dry-run`, интерактивный флоу, `_init_print_plan`, `_init_list_available_tools`.
- `bin/agentsync.sh` — подтянут `prompts.sh` в загрузчик.
- `tests/init.bats` — новые тесты для dry-run / --yes / non-TTY / --help.

### Задачи

- [x] Утилита `prompt_multiselect <title> <options_sep> <preselected_sep>`:
  - TTY → чекбоксы (↑/↓ или j/k, space toggle, a all, n none, enter confirm, q/esc cancel).
  - non-TTY → возвращает `preselected` без вопроса.
- [x] Утилита `prompt_confirm <question> <default>`:
  - TTY → `[Y/n]` prompt, читает из `/dev/tty`.
  - non-TTY → `default` silently.
- [x] Утилита `is_tty` — централизованный guard.
- [x] В `cmd_init`:
  - если TTY и нет `--yes`/`--tools`/`--content` → интерактив.
  - если non-TTY или любой из этих флагов → режим без промптов.
- [x] Интерактивный флоу:
  1. multiselect над всеми base tools из `lib/templates/tools/`, auto-detected preselected.
  2. multiselect над content sections, текущие defaults preselected.
  3. plan → confirm → write.
- [x] Флаг `--yes` — skip all prompts, accept defaults.
- [x] Флаг `--dry-run` для init (показать план, ничего не писать).

### Тесты

- [ ] `tests/init_non_tty_default_test.sh`: non-TTY без флагов → auto-detect, content=agents,rules.
- [ ] `tests/init_yes_flag_test.sh`: `--yes` в TTY тоже пропускает промпты.
- [ ] `tests/init_dry_run_test.sh`: `--dry-run` ничего не пишет.
- [ ] Тесты прокидывают stdin через heredoc для симуляции ответов (limited coverage интерактива в bash-тестах).

### Acceptance

- [x] Человек в терминале видит понятный wizard.
- [x] CI/скрипты работают без изменений (non-TTY = silent defaults).
- [x] `--yes` + `--tools claude,cursor` + `--content agents,rules` — полностью детерминированный init.

---

## Phase 5 — Security, doctor, discoverability (2 дня) ✅ DONE

### Файлы

- `lib/helpers/doctor.sh` — расширен: `_doctor_scan_overrides`, `_doctor_scan_file`, `_doctor_validate_json`, сверка `agentsync_version`.
- `lib/helpers/init.sh` — `agentsync_version: "<VERSION>"` пишется при init; добавлен `cmd_upgrade_config`.
- `lib/helpers/list.sh` — колонка H/M/S с индикатором override.
- `bin/agentsync.sh` — роутинг `upgrade-config`, help-строка.
- `tests/doctor.bats` — новые тесты: secret/JSON/version/list.

### Задачи

#### Security

- [x] `agentsync doctor` проверяет `.ai/src/mcp/*` и `.ai/src/settings/*` regex-ом на утечки:
  - `sk-*` (OpenAI/Anthropic), `ghp_*` / `github_pat_*` (GitHub), `AKIA*` (AWS), `xox[baprs]-*` (Slack), `AIza*` (Google), JWT.
  - Плейсхолдеры (`${VAR}`, `<PLACEHOLDER>`) не ругает.
- [x] `doctor` валидирует JSON-синтаксис mcp/settings (через python3/node, если доступны).
- [ ] `doctor` проверяет executable-флаг для скриптов, на которые ссылаются hooks. _(отложено: hooks.json у нас не ссылается на внешние скрипты, добавлю когда появится такой tool.)_
- [x] Все base-шаблоны в `lib/templates/{mcp,settings}/` содержат только плейсхолдеры (проверено grep; специальный bats-тест можно добавить позже).
- [x] `customize <tool> hooks` показывает summary хука + требует `--yes` в non-TTY (сделано в Phase 3).

#### Version pinning

- [x] `agent_sync.yaml` при `init` пишет `agentsync_version: "<VERSION>"`.
- [x] `doctor` сравнивает с текущим CLI. Mismatch → warning с подсказкой `upgrade-config`.
- [x] Команда `agentsync upgrade-config` обновляет/добавляет поле.

#### Template integrity (optional, стретч)

- [ ] Ship `lib/templates/**/*.sha256` manifest. _(стретч — в scope не входит.)_
- [ ] `doctor --strict` валидирует checksums.

#### Discoverability

- [x] `agentsync list` расширен: колонка H M S показывает hooks/mcp/settings с `*` при override.
- [x] `agentsync show <tool>` — effective config + путь каждого ресурса (сделано в Phase 3: `source_label` для каждого targets.*.*).
- [ ] `agentsync show <tool> --resources` — отдельный флаг только для payload-таблицы. _(отложено: текущий `show` уже покрывает это инлайн.)_
- [x] `agentsync diff <tool> [<resource>]` — дельта (сделано в Phase 3).
- [x] После `init` в summary `Next steps:` уже перечисляет list / enable / sync.

### Тесты

- [ ] `tests/doctor_secret_leak_test.sh`: подложить `sk-xxx...` → doctor ловит.
- [ ] `tests/doctor_invalid_json_test.sh`: битый mcp.json → doctor репортит.
- [ ] `tests/templates_no_secrets_test.sh`: база чистая.
- [ ] `tests/list_columns_test.sh`: новые колонки присутствуют.

### Acceptance

- [x] `doctor` ловит закоммиченный токен в `.ai/src/mcp/claude.json`.
- [x] `show cursor` показывает: `hooks → (base) lib/templates/hooks/cursor.json`.
- [x] Новый пользователь через 3 команды (`init`, `list`, `enable`) понимает возможности системы.

---

## Phase 6 — Миграция для существующих пользователей (0.5 дня) ✅ DONE

### Файлы

- `lib/helpers/simplify.sh` — новая функция `_simplify_payload_overrides`, `cmd_simplify` больше не уходит в early-return при отсутствии tool-YAML оверрайдов.
- `CHANGELOG.md` — релизная запись 0.10.0.
- `README.md` — новая секция "How Resources Resolve", обновлена Quick Start и Project Structure.
- `VERSION` — 0.9.0 → 0.10.0.
- `tests/simplify.bats` — новые тесты для payload simplify.

### Задачи

- [x] Расширить `simplify`:
  - проходит по `.ai/src/{hooks,mcp,settings}/*` и сравнивает с `lib/templates/<resource>/<file>`;
  - byte-identical → предложить удалить (dry-run по умолчанию, `--apply` применяет);
  - отчёт: сколько файлов redundant, сколько настоящих оверрайдов.
- [x] Release notes в CHANGELOG: что поменялось, почему, существующие проекты работают, новый init минимальный, `simplify --apply` для очистки.
- [x] README: новая секция «How Resources Resolve» с диаграммой base→override, обновлены Quick Start и Project Structure.
- [x] Bump version в `VERSION` → `0.10.0`.

### Acceptance

- [x] Проект со scaffolded payload'ами: `simplify --apply` удаляет все byte-identical файлы; sync после этого работает через base fallback.
- [x] README объясняет новую модель новичку за 2 минуты чтения.

---

---

# 0.11 — Tool colocation, shared MCP, discoverability

После 0.10 init минимальный, base+override работает. Но остался разрыв: юзер `enable claude`, делает sync, хочет изменить настройки Claude — **где ему редактировать?** Дефолтный `.claude/settings.json` в gitignore и затирается следующим sync. Нужен явный source-of-truth под редактирование, и он должен быть **очевидным**.

Параллельно — MCP. Серверы одинаковые во всех тулах, но сейчас надо 5 раз копировать один и тот же JSON через `customize`. Единый `.ai/src/mcp.json` решает это.

Главный критерий успеха: юзер без чтения README должен после `enable` понимать, куда идти и что править.

## Архитектура «после 0.11»

```
.ai/src/
├── AGENTS.md, rules/, skills/, commands/, agents/   ← shared (без изменений)
├── mcp.json                                         ← NEW: shared MCP source
└── tools/
    ├── claude.yaml                                  ← tool config (без изменений)
    ├── claude/                                      ← NEW: per-tool payload dir
    │   └── settings.json                            ← здесь юзер редактирует
    ├── cursor.yaml
    └── cursor/
        ├── hooks.json
        └── mcp.json                                 ← опциональный override shared mcp.json
```

Resolution для MCP:
1. `.ai/src/tools/<tool>/mcp.json` (per-tool override) — wins
2. `.ai/src/mcp.json` (shared) — wins
3. `lib/templates/mcp/<tool>.json` (shipped base) — fallback

Resolution для hooks/settings (per-tool по природе):
1. `.ai/src/tools/<tool>/<resource>.<ext>` — wins
2. `lib/templates/<resource>/<tool>.<ext>` — fallback

Старая раскладка `.ai/src/{hooks,mcp,settings}/<tool>.<ext>` читается с deprecation warning до 0.12.

---

## Phase 7 — Layout refactor: per-tool directories (2 дня) ✅ DONE

### Цель

Перевести payload-оверрайды из flat-by-resource в nested-by-tool. Один `.ai/src/tools/<tool>/` = всё tool-specific в одном месте.

### Что делаем

- [x] `tool_resolver.sh::resolve_payload_source`: новый порядок поиска:
  1. `.ai/src/tools/<tool>/<resource>.<ext>` (новый путь)
  2. `targets.<resource>.source` из tool YAML (если задан)
  3. `.ai/src/<resource>/<tool>.<ext>` (старый путь, с `_warn_legacy_payload_path` один раз за запуск через PID-marker)
  4. base template
- [x] `customize <tool> <resource>` пишет в новый путь. При наличии старого — мигрирует inline (mv + сообщение).
- [x] `simplify` сканирует новый путь первым, старый — только для миграционного warning (legacy файлы не удаляются byte-compare'ом).
- [x] `list.sh` H/M/S-колонка читает новый путь; `~` маркирует legacy-only override.
- [x] `doctor.sh` secret scan включает новый путь, и детектит legacy layout → warning с hint «re-run customize для миграции».
- [x] Тесты: `resource_resolver.bats` (new-path wins, legacy warning) + `customize.bats` (writes new path, migrates legacy) + `simplify.bats` (legacy flagged, not deleted) + `doctor.bats` (new-layout scan + legacy warn).

### Acceptance

- [x] Проект с 0.10-раскладкой продолжает работать (sync, list, doctor) без ручных правок, но doctor печатает migration hint.
- [x] `customize claude settings` создаёт `.ai/src/tools/claude/settings.json`, не `.ai/src/settings/claude.json`.

---

## Phase 8 — Shared MCP (1 день) ✅ DONE

### Цель

Один файл `.ai/src/mcp.json` для MCP-серверов, применяется ко всем тулам. Per-tool override — редкое исключение.

### Что делаем

- [x] Резолвер MCP с порядком per-tool override → declared → legacy flat → shared → base (логика в `resolve_payload_source`, shared слой срабатывает только для `resource == mcp`).
- [x] `sync.sh` MCP-шаг использует новый резолвер и печатает отдельную строку-метку `mcp source: shared|override|legacy|base|declared`.
- [x] Новая команда `agentsync add mcp <server> [--url …] [--command …] [--args …] [--env …] [--force]`:
  - Создаёт `.ai/src/mcp.json` если нет (scaffold `{"mcpServers": {}}`).
  - Добавляет сервер в `mcpServers` через `python3` (безопасный JSON-merge).
  - Печатает: «Will apply to every enabled tool on next sync.»
- [x] `list`: footer-hint с путём `.ai/src/mcp.json` и количеством per-tool оверрайдов; если shared нет — подсказка про `add mcp`.
- [x] `init` больше не создаёт пустые `.ai/src/mcp/<tool>.json` (они бы теневали shared). Сохранено только scaffolding `settings/hooks`; MCP тянется из shared/base.
- [x] Тесты: `tests/resource_resolver.bats` — shared propagates, per-tool wins, legacy wins, source labels; `tests/add.bats` — create/append/args/env/force/validation.

### Acceptance

- [x] `agentsync add mcp github --command "npx @github/mcp-server"` → один файл; `sync` раскатал его в `.claude/mcp.json` (aka `.mcp.json`), `.cursor/mcp.json` и т.д.
- [x] Демо: `init --tools claude,cursor` → `add mcp github` → `sync` → `diff .mcp.json .cursor/mcp.json` пустой.
- [x] Per-tool override `.ai/src/tools/cursor/mcp.json` → у cursor своя карта, у claude shared.

---

## Phase 9 — `enable` scaffolds + сигнальные сообщения (2 дня) ✅ DONE

### Цель

После `enable <tool>` юзер **сразу видит**, где редактировать. Без необходимости читать README или искать команду.

### Что делаем

- [x] `enable <tool>` после обновления YAML:
  - Создаёт `.ai/src/tools/<tool>/`.
  - Копирует туда base-шаблоны тех payload'ов, которые есть для тула (settings/hooks). MCP — нет, для него есть shared.
  - TTY: `prompt_confirm "Scaffold editable copies for <tool>?" y` перед копированием (идемпотентно).
  - Non-TTY: флаг `--scaffold` / `--no-scaffold` (default: `--scaffold`).
  - Идемпотентно также для legacy flat override (не создаёт shadow).
- [x] `enable` в конце печатает per-tool блок:
  ```
  Claude Code
    Edit settings:  .ai/src/tools/claude/settings.json
    Edit MCP:       .ai/src/mcp.json  (shared — agentsync add mcp to extend)
  ```
  Для payload'ов, у которых есть base, но нет оверрайда, печатается подсказка `agentsync customize <tool> <resource>`. Финальная строка `Run agentsync sync to apply.` остаётся общим footer'ом (consistent с текущим стилем команды).
- [x] `init` в конце печатает Next steps с MCP + customize подсказками (sub-блок «Customize:»).
- [x] `doctor` — новая секция «Edit paths» для каждого enabled тула: список существующих override-файлов + где можно создать новый (подсказка `customize` или `add mcp`).
- [x] Тесты: `enable claude` создаёт `.ai/src/tools/claude/settings.json` и печатает путь; `enable claude --no-scaffold` создаёт только YAML.

### Acceptance

- [x] Новичок после `init` → `enable claude` видит ровно одну строку «Edit settings: …» и этот файл реально существует.
- [x] Повторный `enable claude` не затирает правки (scaffold skipped если файл уже есть или есть legacy-override).

---

## Phase 10 — Migration для 0.10 users (1 день)

### Цель

Апгрейд с 0.10 на 0.11 без ручной возни. Старая раскладка продолжает работать, но явно помечена как deprecated.

### Что делаем

- [ ] Новая команда `agentsync migrate`:
  - Сканирует `.ai/src/{hooks,mcp,settings}/*` → перемещает в `.ai/src/tools/<tool>/<resource>.<ext>`.
  - Если `.ai/src/mcp/*.json` все одинаковые и юзер согласен — сводит в `.ai/src/mcp.json`.
  - Dry-run по умолчанию, `--apply` применяет.
- [ ] `doctor` детектит legacy layout → пункт «Legacy override layout detected. Run `agentsync migrate` to move to per-tool dirs.»
- [ ] `update` после pull с 0.10→0.11 печатает migration banner.
- [ ] Deprecation timeline: legacy-пути читаются до 0.12, потом удаляются.

### Acceptance

- [ ] Проект с 0.10 после `update` → `migrate --apply` → sync работает, старые файлы и директории удалены.
- [ ] Без `migrate` sync всё равно работает, но с warning.

---

## Phase 11 — Docs + release 0.11 (0.5 дня)

### Что делаем

- [ ] README: новая секция «Customization workflow» с диаграммой per-tool dirs + shared MCP.
- [ ] README Quick Start обновить — в nonce-шаге подсказать `add mcp` / путь к settings.
- [ ] CHANGELOG 0.11: shared MCP, per-tool layout, `add mcp`, `migrate`, enable-scaffold, deprecation старой раскладки.
- [ ] Bump `VERSION` → `0.11.0`.

### Acceptance

- [ ] README-разделу «Customization workflow» достаточно чтобы новичок понял `add mcp` vs `customize` vs `enable` без чтения остального.

---

## Cross-phase checklist

- [ ] Обратная совместимость: любой проект с текущей версии обновляется без ручных правок.
- [ ] `bash tests/run_all.sh` — зелёный на каждой фазе.
- [ ] `shellcheck lib/**/*.sh` — нет новых warnings.
- [ ] `agentsync doctor` — зелёный на install-dir репо (self-sync).
- [ ] Каждая фаза — отдельный PR, с ссылкой на этот TODO.
- [ ] CHANGELOG обновляется в каждой фазе, не в конце.

## Что сознательно НЕ делаем (YAGNI)

- Profiles/presets (backend/frontend стэки) — ждём реального запроса.
- `.ai/agent_sync.local.yaml` для персональных оверрайдов — добавим, если команды попросят.
- Плагинная система для кастомных инструментов — достаточно `.ai/src/tools/<name>.yaml`.
- Автокоммит/автопуш сгенерированных артефактов — вне scope CLI.
- GUI/TUI поверх CLI.

## Метрики успеха

- Новый проект Claude-only: `.ai/src/` = 3 файла (было ~20).
- Время от `agentsync init` до первого успешного `sync` ≤ 60 сек для новичка.
- Ноль случаев «я не понял, почему у меня куча конфигов для инструментов, которые я не использую».
- Ноль закоммиченных секретов благодаря `doctor`.
