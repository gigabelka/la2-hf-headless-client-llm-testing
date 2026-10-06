# Скилы и агенты проекта

Краткое описание всех скилов (`.claude/skills/`) и специализированных агентов (`.claude/agents/`) репозитория. Источник истины по протоколу — [PLANE.md](PLANE.md).

## Скилы

Скилы вызываются через `/имя` или подхватываются автоматически по описанию.

| Скил | Назначение | Когда использовать |
|------|-----------|-------------------|
| **build-l2** | Порядок сборки headless-клиента L2 (HighFive, протокол 267) с нуля из PLANE.md: scaffold (`config.ts` + дословные `types.ts` / `game/Opcodes.ts` / `net/PacketReader.ts` / `net/PacketWriter.ts` / `debug/DebugTools.ts`) → крипто (включая `crypto/selfTests.ts`) → self-tests до сокетов → дословный `net/Connection.ts` → FSM логина → FSM игры → один линейный `index.ts`. | Когда `src/` пуст/отсутствует или нужно сгенерировать клиент заново из единого промпта. |
| **l2-guardrails** | Чеклист жёстких ограничений и типовых ошибок, ломающих сборку: фрейминг пакетов (двойной length-prefix), «учебные» опкоды вместо HighFive, крипто (копировать дословно), порядок ключей AuthRequest, флаг GameCrypt, keepalive; плюс разделы Packet pipeline (снятие 2-байтового префикса, кто шифрует, смещения от опкода), Timeouts (10 с connect / 15 с на состояние / 45 с watchdog / 3 с на GGAuth) и TypeScript/build — нативный TS-раннер без `ts-node`, `"type": "module"` + `.ts` в относительных импортах, запрет `enum`/`namespace`/parameter-properties, общие типы только в `src/types.ts`, сверка с `## MODULE CONTRACTS`. | При написании или ревью кода фрейминга, опкодов, крипто, FSM логина/игры, keepalive, а также scaffold/tsconfig/package.json. |
| **debug-l2** | Диагностика провального прогона: сначала проверка крипто в изоляции, затем сопоставление симптома с таблицей TROUBLESHOOTING из PLANE.md. | Когда прогон даёт FAIL, клиент отключается, пакеты «мусорные» или `IN_GAME` не появляется. |
| **run** | Запуск клиента end-to-end (`npm run dev`, ~75 с таймаут) и разбор единого блока `=== REPORT ===` (PASS/FAIL, self-tests, state-path, артефакты). | Когда клиент нужно запустить или проверить против живого сервера. |
| **writing-great-skills** | Справочник по написанию и редактированию скилов: словарь и принципы, делающие скил предсказуемым. | При создании/правке любого скила в этом репо. |

## Агенты

Агенты запускаются как субагенты (через инструмент Agent) и зеркалят основной рабочий процесс.

| Агент | Инструменты | Назначение |
|-------|-------------|-----------|
| **crypto-porter** | Read, Write, Edit, Bash, Grep | Портирует крипто-модули (Blowfish, NewCrypt, LoginCrypt, GameCrypt, RsaCrypt) и `crypto/selfTests.ts` дословно из PLANE.md (каркас с `types.ts` и `debug/DebugTools.ts` создаётся раньше, оркестратором) и доводит крипто self-tests до зелёного (гейт 1 — все 12 проверок: round-trip **и** KAT) до любой работы с сокетами. Вызывать, когда `src/crypto` пуст/подозрителен или self-tests красные — но только после того, как каркас уже есть. |
| **fsm-builder** | Read, Write, Edit, Bash, Grep | Строит дословный `net/Connection.ts`, FSM логина и игры и линейный `index.ts` (шаги 5–8 build-l2), считая крипто-гейт уже пройденным; модули каркаса (`types.ts`, `Opcodes.ts`, `PacketReader/Writer`, `DebugTools.ts`, `config.ts`) не переписывает, типы берёт из `src/types.ts`, сверяет сигнатуры с `## MODULE CONTRACTS`. Вызывать после crypto-porter, чтобы довести клиент до `IN_GAME`. |
| **guardrails-reviewer** | Read, Grep, Glob (read-only) | Аудит текущего `src/` свежим контекстом по чеклисту l2-guardrails: ловит тихие ошибки (двойной length-prefix, опкоды, порядок ключей AuthRequest, нулевые паддинги, флаг GameCrypt, keepalive). Ничего не меняет. Вызывать после сборки/правок, до запуска против сервера. |
| **run-debugger** | Bash, Read, Grep, Edit | Запускает `npm run dev`, разбирает `=== REPORT ===`, при FAIL диагностирует по debug-l2 (крипто в изоляции → таблица «симптом→фикс» → временный hexdump), чинит и перезапускает. Вызывать для прогона против живого сервера или воспроизведения/фикса FAIL. |
| **plane-navigator** | Read, Grep, Glob (read-only) | Точечный справочник по PLANE.md (~1700 строк): на вопрос «что спека говорит про X» возвращает раздел и точные значения (опкод, смещение, порядок полей, паддинги) с цитатой и номером строки. Кода не пишет. Вызывать, чтобы не перечитывать всю спеку в основном контексте. |

## Типовой поток работы

**Сборка с нуля** (полная цепочка из `build-l2` → *Who owns which step*; субагент не может звать субагента, поэтому цепочку ведёт оркестратор):

`оркестратор` (шаги 1–2: scaffold, `config.ts`, дословные модули, `npm install`) → `crypto-porter` (крипто + self-tests, гейт 1) → `guardrails-reviewer` → `fsm-builder` (Connection, FSM, index.ts, до `IN_GAME`) → `guardrails-reviewer` → `run-debugger` (гейт 2: typecheck + прогон).

**Аудит и запуск по отдельности:** `guardrails-reviewer` (проверка src/ до запуска) → `run-debugger` (прогон + диагностика FAIL). Повторять `guardrails-reviewer` после любой правки фрейминга, опкодов, крипто, FSM или keepalive. Для вопросов по спецификации — `plane-navigator`.
