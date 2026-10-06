# Headless Lineage 2 Client — тестирование LLM по единому промпту

Этот репозиторий — песочница для проверки того, насколько хорошо современные LLM справляются с реализацией сложного сетевого клиента по одному длинному self-contained промпту.

Цель проекта — получить работающий **headless-клиент Lineage 2** (хроника HighFive, протокол `267`) на **Node.js 24.15.0 + TypeScript**, который без участия человека:

1. Подключается к **Login Server**, проходит аутентификацию по логину/паролю и забирает сессионные ключи.
2. Подключается к **Game Server**, используя эти ключи, выбирает персонажа по слоту и входит в игровой мир.
3. Печатает в консоль `IN_GAME`.
4. Поддерживает соединение, отвечая на серверные пинги.

Стек: Node.js, TypeScript, собственная реализация Blowfish + RSA + XOR-шифрование игрового потока. Никаких веб-фреймворков, баз данных и игровой логики (бой, движение, инвентарь) — только автологин.

## Что находится в репозитории

- [PLANE.md](PLANE.md) — **Источник правды / спецификация протокола** на английском. Содержит полную спецификацию для создания клиента: протокол, карту опкодов, reusable-реализации криптографии, FSM логин- и гейм-сервера, формат отчёта и troubleshooting. Блок «Единый промпт» ниже — это оркестрационный промпт, который ссылается на `PLANE.md`, а не заменяет его.
- [.env](.env) — Файл с реальными credentials (не шаблон): IP/порт серверов, логин, пароль, ID игрового сервера, слот персонажа, протокол. Читать только, не перезаписывать.
- `.env.example` — Шаблон конфигурации; генерируется вместе с каркасом по `## PROJECT SETUP`, в `main` отсутствует.
- [`src/`](src/) — Исходный код клиента. **Генерируется LLM по единому промпту** на основе [PLANE.md](PLANE.md); в начальном состоянии отсутствует.
- [`README.md`](README.md) — Этот файл — вводное описание и инструкция по работе с LLM.
- [INFO.md](INFO.md) — Каталог скилов и специализированных агентов проекта (`.claude/skills/`, `.claude/agents/`): назначение, инструменты и типовой поток работы (сборка с нуля, аудит, запуск и диагностика FAIL).

## Архитектура клиента

Клиент — **единая линейная программа**: один запуск `npm run dev` выполняет весь сценарий от подключения до keep-alive. Никаких фаз и переменной окружения `PHASE` — `index.ts` последовательно:

1. Загружает и валидирует конфиг из `.env`.
2. Прогоняет крипто-self-tests (`runLoginCryptoSelfTests()` + `runGameCryptoSelfTests()`) **до** любого сокет-I/O: round-trip **и** known-answer-векторы (KAT).
3. Логин-сервер: аутентификация, получение 4 session id + адреса игрового сервера.
4. Игровой сервер: новое соединение, выбор персонажа, вход в мир.
5. Печатает `IN_GAME`, отвечает на пинги ≥ 60 секунд, затем чисто закрывает сокет и выходит.

При любой ошибке (упавший self-test, `LoginFail`/`PlayFail`, таймаут, разрыв соединения до `UserInfo`) программа печатает финальный отчёт со `status: FAIL` и завершается с ненулевым кодом. Зависаний быть не должно: все ожидания ограничены (`## TIMEOUTS & LIVENESS` — 10 с на connect, 15 с на состояние, 45 с watchdog до `IN_GAME`).

**Структура кода (`src/`):**

- `types.ts` — общие типы-контракты (`Config`, `LoginResult`, `GameInput`, `Artifacts`, union-состояния FSM); единственный дом для типов, которые нужны сразу нескольким модулям.
- `net/` — `Connection.ts` (TCP + реассембли пакетов по `[uint16LE size][opcode][payload]`), `PacketReader.ts`, `PacketWriter.ts`.
- `crypto/` — криптография: `Blowfish.ts`, `NewCrypt.ts`, `ScrambledRsaKey.ts`, `RsaCrypt.ts`, `LoginCrypt.ts`, `GameCrypt.ts` (16-байтовое скользящее XOR игрового потока), `selfTests.ts` (round-trip-самотесты до сокетов).
- `game/` — `GameClient.ts`, `Opcodes.ts` (карта опкодов HighFive).
- `login/` — `LoginClient.ts`.
- `debug/` — `DebugTools.ts` (счётчики `check`, `[STATE]`-лог, финальный отчёт); зависит только от `types.ts`, поэтому создаётся вместе с каркасом.
- `selftest.ts` — точка входа `npm run selftest`: прогоняет оба крипто-набора без единого сокета. Это и есть проверяемый gate 1 — он работает ещё до появления `index.ts`.

`net/Connection.ts`, `PacketReader.ts`, `PacketWriter.ts`, `Opcodes.ts`, `DebugTools.ts`, `crypto/selfTests.ts`, `types.ts` даны в PLANE.md готовыми листингами (**COPY VERBATIM**), не прозой. `npm run dev` — нативный TS Node 24 (`node --experimental-strip-types`), без `ts-node`; версии зависимостей закреплены точно. Формат модулей фиксирован: `"type": "module"` + явное расширение `.ts` в каждом относительном импорте — единственная комбинация, которую Node 24 запускает (`tsc` переписывает расширения в `dist/` сам). Единый путь байтов «кадр → тело → парсинг» описан в `## PACKET PIPELINE`, точные экспортируемые сигнатуры модулей — в `## MODULE CONTRACTS`.

### Логин-сервер (FSM)

`LoginClient` FSM: `WAIT_INIT → WAIT_GG_AUTH → WAIT_LOGIN_OK → WAIT_SERVER_LIST → WAIT_PLAY_OK`. Шаги: подключиться; `decryptInit` → модуль RSA (128 байт) + Blowfish-ключ (`setSessionKey` — сразу при разборе `Init`, до первой отправки); `RequestGGAuth` (сервер без GameGuard просто молчит — через 3 с взять `ggResponse = 0` и идти дальше); `RequestAuthLogin` → `LoginOk`; `RequestServerList` → выбрать `L2_SERVER_ID` (хост и порт — из этой записи, `L2_GAME_PORT` только фолбэк); `RequestServerLogin` → `PlayOk`; закрыть логин-соединение. Результат, который несётся дальше в игровую часть: `loginOkId1`, `loginOkId2`, `playOkId1`, `playOkId2`, `gameHost`, `gamePort`.

### Игровой сервер (FSM)

`GameClient` FSM: `WAIT_CRYPT_INIT → WAIT_CHAR_LIST → WAIT_CHAR_SELECTED → WAIT_USER_INFO → IN_GAME`. Шаги: подключиться к `gameHost:gamePort`; отправить сырой `ProtocolVersion 0x0E`; прочитать `CryptInit 0x2E` и включить `GameCrypt` только если `encryptionFlag !== 0`; `AuthRequest 0x2B` (порядок ключей `playOkId2, playOkId1, loginOkId1, loginOkId2`, без языкового поля); `CharSelectInfo 0x09` (проверить `charCount >= 1`); `CharacterSelected 0x12` (+ 14 нулевых байт); `RequestKeyMapping` (`0xD0 0x0021`) + `EnterWorld` (`0x11` + 104 нулевых байта, каждый — не более одного раза); на `UserInfo 0x32` печатать `IN_GAME`.

**Устойчивость:** допускать до 10 неизвестных пакетов **в каждом** состоянии `WAIT_*` — расшифровать тело, залогировать опкод, отбросить (отбросить *до* расшифровки нельзя: оба ключа `GameCrypt` сдвигаются на размер каждого обработанного тела, и поток рассинхронизируется навсегда); 11-й — FAIL. После `IN_GAME` молча отбрасывать все пакеты, кроме пингов. Если `UserInfo` приходит ещё в `WAIT_CHAR_SELECTED` (сервер пропустил `CharSelected`) — перейти к enter-world-последовательности с защитой от повторной отправки `RequestKeyMapping`/`EnterWorld`.

**Keep-alive:** отвечать на каждый `NetPingRequest` (`0xD3` или `0xFE 0x00D3`), полученный в `WAIT_USER_INFO` или `IN_GAME`, пакетом `NetPing` (`0xA8` + `D pingId` + `D 0x00000000` + `D 0x00080000`; тело 13 байт, кадр 15); держать соединение 60 секунд **от момента печати `IN_GAME`**, затем закрыть и выйти с кодом 0.

### Отчёт

В конце `DebugTools.report(...)` печатает финальный отчёт (ровно один; `notes` заполняется **только** при ошибке — непустой `notes` переводит статус в `FAIL`):

```
=== REPORT ===
status: PASS | FAIL
self-tests: <passed>/<total>
state-path: IDLE -> ... -> <final>
artifacts: <key=value session data>
notes: <first failing assertion / error, if any>
```

## Как работать с LLM

Клиент реализуется **одним промптом в одной сессии** — вся спецификация помещается в контекст сразу.

### Подготовка

1. Убедитесь, что в `.env` заполнены реальные значения для вашего сервера.
2. Убедитесь, что [PLANE.md](PLANE.md) целиком помещается в контекст модели.

### Единый промпт

> Текущая ревизия — **PROMPT VERSION 3** (см. шапку PLANE.md). Ветки моделей, собранные по версиям 1 и 2, напрямую с ней не сопоставимы. В v2 был починен формат модулей, добавлены разделы `## PACKET PIPELINE` и `## TIMEOUTS & LIVENESS`, а тавтологичные round-trip-самотесты заменены на known-answer-векторы. В v3 закрыты места, на которых падала даже корректная реализация: требование `import type` при `verbatimModuleSyntax`, единственное разрешённое исключение `login/ → game/Opcodes.ts`, тупик с `UserInfo` до `CharSelected`, запускаемый крипто-гейт (`npm run selftest`), разметка байтов `CryptInit`, семантика счётчика неизвестных пакетов и таймера состояния, ответ на ping в любом состоянии и опциональный `L2_GAME_IP`.

> Задача промпта — **создать клиент с нуля**. В ветке `main` нет ни `src/`, ни `package.json`, ни `tsconfig.json` — модель должна создать весь проект сама (каркас по `## PROJECT SETUP`, затем крипто, net, FSM и `index.ts`). Ничего «дописывать» в существующий код не нужно: пустой `src/` — это ожидаемое стартовое состояние.

> Первая строка промпта — placeholder: вместо `[PASTE THE FULL CONTENTS OF PLANE.md HERE]` вставьте полное содержимое [PLANE.md](PLANE.md) (или прикрепите файл к сессии, если инструмент это позволяет).

```text
[PASTE THE FULL CONTENTS OF PLANE.md HERE]

CREATE, FROM SCRATCH, a headless Lineage 2 client (chronicle HighFive, protocol 267) on
Node.js 24 + TypeScript. The repository currently contains ONLY the specification above and
a filled .env — there is no package.json, no tsconfig.json and no src/. Create every file
yourself.

The client is ONE straight-line program. `npm run dev` does the whole run in a single
pass: authenticate on the login server; obtain the 4 session ids + game server address;
open a fresh game connection; select the character in slot L2_CHAR_SLOT; enter the world;
print IN_GAME; answer server pings for 60 seconds; close cleanly and exit 0.
No build phases, no PHASE env var, no per-phase functions, no per-phase reports — one
linear flow, one `=== REPORT ===`.

PLANE.md above owns every byte, opcode, crypto algorithm, field layout, timeout and FSM
state list — follow the referenced section, do NOT restate or re-derive it here; copy every
"COPY VERBATIM" block exactly. This block only orchestrates: order, control flow, edge cases.

Build order
1. Create the scaffold per `## PROJECT SETUP` — none of these files exist yet: package.json
   ("type": "module", dev = `node --experimental-strip-types src/index.ts`, NO ts-node,
   versions pinned exact),
   tsconfig.json, .env.example, src/config.ts per `## MODULE CONTRACTS`, plus src/types.ts and
   src/game/Opcodes.ts and src/net/PacketReader.ts / PacketWriter.ts and src/debug/DebugTools.ts —
   these five COPY VERBATIM.
   Every relative import carries its `.ts` extension. Run npm install; `npx tsc --noEmit`
   clean. Every module's exported signature must match `## MODULE CONTRACTS`.
2. `.env` already holds real credentials — READ it, never overwrite. Load via dotenv,
   parseInt numbers, throw a clear error on any missing var from `### .env.example`.
3. Crypto from `## REUSABLE CODE — COPY VERBATIM` (incl. src/crypto/selfTests.ts and
   src/selftest.ts), then run `npm run selftest` BEFORE any socket I/O — abort if any check
   fails. Gate 1 is every round-trip AND every KAT green (`self-tests: 12/12`); a red KAT means
   that module was not pasted verbatim — re-copy it, never edit the expected hex. Shared types
   come only from src/types.ts and ALWAYS via `import type` (verbatimModuleSyntax is on — a
   value import of a type is a hard TS1484 error). login/ and game/ never import each other,
   with one exception: login/LoginClient.ts imports OPCODES from game/Opcodes.ts. No
   enum/namespace/parameter-properties (native type-stripping).
4. Framing per `## PACKET PIPELINE`: on receive strip the 2-byte length, decrypt the body,
   parse from offset 0; on send build the body, encrypt it, pass it to Connection.send(),
   which prepends the length itself. Offsets in the protocol tables start at the opcode.
5. Login flow per `### PART A — LOGIN SERVER`: Init (setSessionKey while handling it) →
   GGAuth → AuthLogin → ServerList (pick L2_SERVER_ID; gameHost/gamePort come from that
   record) → ServerLogin → PlayOk; close the login connection; carry forward the 4 session
   ids + gameHost/gamePort in memory.
6. Game flow per `### PART B — GAME SERVER`: fresh connection → ProtocolVersion sent raw
   → CryptInit, enable GameCrypt only if encryptionFlag !== 0 → AuthRequest →
   CharSelectInfo → CharacterSelected → RequestKeyMapping → EnterWorld → on UserInfo
   print IN_GAME. Send RequestKeyMapping and EnterWorld at most once each.
7. Keepalive per `### PART B`: answer every ping, in every state from WAIT_CRYPT_INIT onwards,
   and never count a ping as an unknown packet; hold the connection 60 seconds counted from the
   IN_GAME line, then close cleanly and exit 0.
8. Print the final self-debug report per `### src/debug/DebugTools.ts` — exactly one, and
   pass `notes` only on failure (a non-empty notes flips the status to FAIL).

Edge cases (control flow)
- Every wait is bounded per `## TIMEOUTS & LIVENESS`: 10 s per connect, 15 s per WAIT_*
  state (a no-progress timer — restart it on every frame parsed in that state, dropped and
  ping frames included), 45 s whole-run watchdog as a hard global ceiling. A hang is a bug.
  Clear every timer before resolving.
- Skipped GGAuth: a server without GameGuard answers with silence. After 3 s with no GGAuth,
  or on any other opcode, use ggResponse = 0 and proceed (re-dispatch that packet).
- Skipped CharSelected: if UserInfo (0x32) arrives while still WAIT_CHAR_SELECTED, send the
  enter-world sequence (respecting the at-most-once guards) and treat THAT SAME packet as the
  UserInfo — print IN_GAME and go straight to IN_GAME. Do not then wait for a second 0x32.
- Tolerate up to 10 unknown packets per entry into a WAIT_* state (counter resets on every
  transition): decrypt the body, log the opcode, drop it — never drop before decrypting, that
  desynchronizes GameCrypt permanently. The 11th within one entry is a FAIL. WAIT_USER_INFO and
  IN_GAME are exempt from the counter entirely: there, silently drop every non-ping packet.
- LoginFail / PlayFail, a timeout, or the server closing the socket before UserInfo: settle
  the run promise (never leave it pending), report FAIL, exit non-zero.

If anything looks scrambled or stalls, consult `## TROUBLESHOOTING`.

Run: npm run dev
```

## Запуск

### Bash / zsh / Git Bash

```bash
# 1. Установка зависимостей
npm install

# 2. Проверить/заполнить .env
#    L2_LOGIN_IP, L2_LOGIN_PORT, L2_GAME_PORT,
#    L2_USERNAME, L2_PASSWORD,
#    L2_SERVER_ID, L2_CHAR_SLOT, L2_PROTOCOL

# 3. Запуск (весь сценарий за один прогон)
npm run dev
```

### PowerShell (Windows)

```powershell
npm install
npm run dev
```

## Definition of Done

Проект считается успешно реализованным, если:

- `npx tsc --noEmit` не выдаёт ошибок.
- `npm run dev` подключается к логин-серверу, доходит до `PlayOk` и получает 4 session id.
- Клиент входит в игровой мир и печатает `IN_GAME`.
- Клиент остаётся подключённым не менее 60 секунд, отвечая на серверные пинги.
- Программа печатает финальный self-debug report со `status: PASS`.

## Советы

- **Не меняйте опкоды** — в [PLANE.md](PLANE.md) используется собственная карта HighFive, не «учебная».
- **Красный KAT — это не повод править эталон**: модуль перенесён неверно, скопируйте его заново.
- **Копируйте reusable-код дословно** — алгоритмы Blowfish, RSA, XOR описаны именно в том виде, в котором их ожидает сервер.
- **Honor the crypt flag:** игра включает XOR-шифрование только если `CryptInit` прислал `encryptionFlag !== 0`.
- **Connection.send()** сам добавляет 2-байтовый little-endian префикс длины; не добавляйте его повторно.
- **EnterWorld** требует предварительного `RequestKeyMapping` (`0xD0 0x0021`) и ровно 104 нулевых байта после опкода `0x11`.
- Если сервер пропускает `CharSelected` и сразу шлёт `UserInfo` — обработайте это; не отправляйте `EnterWorld` дважды.
- **Смещения в таблицах протокола считаются от опкода**, а `onPacket` отдаёт кадр вместе с 2-байтовой длиной: сначала `frame.subarray(2)`, потом расшифровка, потом разбор.
- **Прогон не должен висеть:** таймауты из `## TIMEOUTS & LIVENESS` обязательны, а промис стадии обязан быть settle-нут на любом исходе, включая `onClose`.

## Лицензия

Проект создаётся в образовательных/исследовательских целях для тестирования возможностей LLM. Используйте ответственно и только на серверах, где у вас есть разрешение.
