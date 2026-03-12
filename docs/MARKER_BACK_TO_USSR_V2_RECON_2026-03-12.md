# MARKER_BACK_TO_USSR_V2_RECON_2026-03-12

Status: `RECON COMPLETE`
Protocol: `RECON -> REPORT -> WAIT GO -> IMPLEMENT`
Date: `2026-03-12`
Target: `tools/back_to_ussr_app`

## 0) Что именно проверено

Проверено по коду:
- `src/main.swift`
- `build_back_to_ussr_app.command`
- `scripts/run_tests.sh`
- `tests/run_unit_tests.py`
- `tests/test_subscription_parser.py`
- `docs/ARCHITECTURE.md`
- `docs/TESTING.md`

Проверено по runtime:
- текущий bundled бинарь: `sing-box version 1.9.3`
- `sing-box check` на локальном конфиге с двумя inbound (`socks` + `http`) проходит успешно
- текущий локальный test entrypoint проходит успешно, но это не `XCTest`

Проверено по официальной документации:
- `sing-box` official docs: `Mixed Inbound`
- `sing-box` official docs: `HTTP Inbound`
- `sing-box` official docs: `VLESS Outbound`

---

## 1) Что реально есть сейчас

## MARKER_BTU20_BASELINE_V1

### 1.1 State и runtime-файлы
- `~/Library/Application Support/BACK_TO_USSR/state.json` уже используется.
- `~/Library/Application Support/BACK_TO_USSR/runtime-sing-box.json` уже генерируется.
- `active-ports.json` сейчас не создаётся.

### 1.2 Портовая модель
- В коде захардкожен один локальный порт: `12334`.
- Этот порт используется и для runtime-конфига `sing-box`, и для локального теста IP, и для системных proxy-настроек.
- Портов `1080` и `1087` сейчас нет.

### 1.3 Тип inbound
- Сейчас генерируется один inbound:
  - `type: "mixed"`
  - `listen: 127.0.0.1`
  - `listen_port: 12334`
- То есть приложение не поднимает отдельный `http` listener на `1087`.

### 1.4 Логика connect/reconnect
- `autoConnect(reason:)` строит приоритетный порядок нод:
  - выбранная
  - последняя успешная
  - все остальные
- Затем ноды перебираются строго последовательно.
- Для каждой ноды есть fallback `flow on -> flow off`.
- После каждого провала `sing-box` останавливается и стартует заново для следующей ноды.

### 1.5 Мониторинг
- Монитор тикает раз в `30` секунд.
- При провале `testIP(timeout: 6)` вызывается `autoConnect(reason: "monitor")`.
- Backoff, лимит попыток и счётчик reconnect-попыток отсутствуют.

### 1.6 Системный proxy
- Включение происходит через `osascript` + `networksetup`.
- Web proxy, secure web proxy и SOCKS proxy настраиваются на один и тот же локальный порт.
- Это совместимо с текущим `mixed` inbound, но не даёт отдельного фиксированного HTTP-порта для инструментов, которые ожидают `127.0.0.1:1087`.

### 1.7 Тестовый контур
- `XCTest` отсутствует.
- Нет `Package.swift`.
- Нет `.xcodeproj`.
- Нет Swift test target.
- Имеющиеся тесты покрывают только decode/parse VLESS и написаны на Python.

---

## 2) Подтверждённые точки в коде

## MARKER_BTU20_CODE_MAP_V1

- `src/main.swift:75`
  - жёсткий локальный порт `12334`
- `src/main.swift:103`
  - путь к `state.json`
- `src/main.swift:104`
  - путь к `runtime-sing-box.json`
- `src/main.swift:568`
  - вход в последовательный reconnect/auto-dial
- `src/main.swift:583`
  - последовательный цикл по нодам
- `src/main.swift:587`
  - fallback `flow on -> flow off`
- `src/main.swift:624`
  - запуск `sing-box`
- `src/main.swift:657`
  - единственный inbound типа `mixed`
- `src/main.swift:684`
  - проверка IP идёт только через SOCKS
- `src/main.swift:702`
  - системные proxy-настройки
- `src/main.swift:827`
  - monitor timer
- `src/main.swift:834`
  - reconnect без backoff
- `build_back_to_ussr_app.command:17`
  - pinned binary `sing-box v1.9.3`
- `scripts/run_tests.sh:1`
  - test harness без Swift/XCTest

---

## 3) Что из prompt уже подтверждено документацией

## MARKER_BTU20_DOC_VALIDATION_V1

1. `mixed` inbound в `sing-box` действительно поддерживает несколько proxy-протоколов на одном порту.
2. `http` inbound как отдельный listener поддерживается официально.
3. `socks` inbound как отдельный listener поддерживается bundled бинарём `sing-box 1.9.3`.
4. Текущая конфигурация приложения не использует эти возможности раздельно, хотя бинарь их принимает.

Практическая проверка:
- локальный `sing-box check -c /tmp/back_to_ussr_singbox_check.json` с `socks:1080` и `http:1087` завершился успешно на bundled `1.9.3`

Вывод:
- требование prompt про два fixed listener не конфликтует с текущим бинарём
- менять `sing-box` только ради `socks + http` не требуется

---

## 4) Gap matrix по вашему prompt

## MARKER_BTU20_GAP_MATRIX_V1

### 4.1 Параллельный пинг нод перед подключением
Статус: `MISSING`

Что есть:
- только последовательный запуск полной connect-попытки на каждую ноду

Что отсутствует:
- предварительный параллельный TCP probe
- измерение RTT
- выбор лучшей ноды среди успешных

Последствие:
- при пачке мёртвых нод приложение тратит время на полный цикл `start sing-box -> curl -> fail -> stop`
- это и есть главный источник лишней нагрузки и медленного reconnect

### 4.2 Умный HTTP proxy port
Статус: `MISSING`

Что есть:
- один `mixed` inbound на `12334`

Что отсутствует:
- фиксированный `SOCKS 1080`
- фиксированный `HTTP 1087`
- preflight-проверка занятости портов
- выборочное убийство только своего старого `sing-box`

Последствие:
- внешние инструменты не могут стабильно рассчитывать на `127.0.0.1:1087`
- LaunchAgent/CLI-интеграции не на что опереться кроме хардкода или ручного знания

### 4.3 Защита OAuth портов
Статус: `MISSING`

Что есть:
- никакой динамический allocator пока не реализован
- никакой protected-port policy нет

Что отсутствует:
- список защищённых портов
- исключение защищённых портов из fallback-аллокатора
- warning-лог вместо hard fail

Последствие:
- как только появится динамический fallback, без policy можно случайно занять `8080/3000/4000/5000/5001`

### 4.4 CPU throttle при reconnect
Статус: `MISSING`

Что есть:
- reconnect запускается сразу при падении monitor-проверки
- лимита попыток нет
- backoff нет

Что отсутствует:
- градация `2s -> 10s -> 30s`
- максимум `20` попыток
- UI alert `"Нет доступных серверов"`

Последствие:
- при враждебной сети приложение может бесконечно крутить reconnect-путь

### 4.5 Тесты в песочнице
Статус: `MISSING`

Что есть:
- Python unit tests
- live subscription smoke
- binary architecture smoke

Что отсутствует:
- `XCTest`
- тестируемые Swift-абстракции для ping/port/backoff/runtime-config
- детерминированные mocks для соединений и времени

Последствие:
- prompt v2.0 нельзя закрыть без выноса connectivity-логики из `NSApplicationDelegate` в тестируемые pure/Foundation-компоненты

### 4.6 LaunchAgent интеграция
Статус: `MISSING`

Что есть:
- только `state.json` и `runtime-sing-box.json`

Что отсутствует:
- `active-ports.json`
- запись ISO8601 времени старта
- контракт для внешних потребителей

Последствие:
- Claude/Codex/OpenCode неоткуда читать актуальные локальные proxy-порты

---

## 5) Критичные архитектурные выводы

## MARKER_BTU20_ARCH_DECISIONS_V1

1. Главная доработка должна идти не в UI, а в выделение отдельного connectivity-слоя.
2. Текущий `main.swift` перегружен:
   - AppKit menu logic
   - subscription parsing
   - connect orchestration
   - process management
   - proxy setup
   - health monitoring
3. Для `XCTest` почти неизбежен вынос логики в отдельные типы, например:
   - `NodeProbeService`
   - `PortManager`
   - `ReconnectPolicy`
   - `SingBoxConfigBuilder`
   - `SingBoxRuntimeManager`
4. AppKit-слой должен остаться thin wrapper над этими сервисами.
5. Без такого разрезания любые sandbox-тесты будут хрупкими или вообще невозможными.

---

## 6) Предлагаемый безопасный план имплементации

## MARKER_BTU20_IMPL_PLAN_V1

### Phase 1. Extract logic from `main.swift`
- вынести node probing
- вынести port policy
- вынести reconnect policy
- вынести runtime config builder
- вынести process lifecycle

### Phase 2. Add deterministic Swift tests
- поднять `SwiftPM` package или minimal `xcodeproj`
- покрыть pure logic через `XCTest`
- мокнуть:
  - TCP dialer
  - clock/sleeper
  - process runner
  - port inspector

### Phase 3. Replace sequential reconnect
- сначала параллельный probe всех кандидатов
- затем connect only to best node
- fallback на следующий best node только после реальной connect failure

### Phase 4. Add fixed listeners and port policy
- default:
  - `SOCKS 1080`
  - `HTTP 1087`
- если порт занят:
  - попытаться убрать только собственный stale `sing-box`
  - затем перейти в safe fallback-порт вне protected list
  - залогировать warning, не падать

### Phase 5. Add reconnect throttling
- policy:
  - attempts `1...3` -> `2s`
  - attempts `4...6` -> `10s`
  - attempts `7...20` -> `30s`
- после `20`:
  - прекратить loop
  - показать UI alert

### Phase 6. Publish active ports contract
- записывать `active-ports.json` после успешного старта runtime
- обновлять файл при port fallback
- удалять или помечать stale state при disconnect

---

## 7) Что уже доказано и что пока нет

## MARKER_BTU20_PROVEN_VS_UNPROVEN_V1

### Proven
- текущий bundled `sing-box` = `1.9.3`
- этот бинарь принимает конфиг с двумя inbound `socks + http`
- текущий app действительно использует только один `mixed` inbound
- текущий reconnect действительно последовательный
- current test harness не покрывает v2.0 задачи

### Unproven
- реальная семантика `lsof`/PID cleanup для stale `sing-box` в бою
- поведение `curl -x http://127.0.0.1:1087 https://api.anthropic.com` именно в sandbox окружении этого проекта
- детали LaunchAgent consumer-side контракта вне JSON-файла

---

## 8) Минимальный scope change для prompt v2.0

## MARKER_BTU20_MIN_SCOPE_V1

Если делать минимально и без UI-изменений, scope такой:

1. Не трогать menu layout.
2. Не менять subscription UX.
3. Не менять audio/anthem code.
4. Переписать только:
   - reconnect selection
   - runtime config builder
   - port management
   - health/retry policy
   - active ports publishing
   - tests

Это соответствует вашему ограничению:
- `НЕ менять UI — только логику connectivity и port management`

---

## 9) Baseline verification log

## MARKER_BTU20_BASELINE_VERIFIED_V1

Команды, которые были подтверждены локально:

```bash
cd /Users/danilagulin/Documents/VETKA_Project/vetka_live_03
./tools/back_to_ussr_app/scripts/run_tests.sh
./tools/back_to_ussr_app/dist/BACK_TO_USSR.app/Contents/Resources/sing-box version
./tools/back_to_ussr_app/dist/BACK_TO_USSR.app/Contents/Resources/sing-box check -c /tmp/back_to_ussr_singbox_check.json
```

Результат:
- текущие Python tests: `OK`
- bundled `sing-box`: `1.9.3`
- отдельные inbound `socks + http`: `config accepted`

---

## 10) Ключевой вывод recon

## MARKER_BTU20_CONCLUSION_V1

Ваш prompt технически реалистичен на текущем baseline.

Главный вывод:
- проблема не в том, что `sing-box` не умеет `HTTP` inbound
- проблема в том, что приложение сейчас построено вокруг одного `mixed` listener и последовательного reconnect-цикла

Значит правильный путь такой:
- не переписывать UI
- не менять протокол провайдера
- вынести connectivity runtime в отдельные тестируемые Swift-компоненты
- затем закрыть prompt v2.0 поверх уже существующего app shell

## 11) Официальные ссылки

- `Mixed Inbound`: https://sing-box.sagernet.org/configuration/inbound/mixed/
- `HTTP Inbound`: https://sing-box.sagernet.org/configuration/inbound/http/
- `VLESS Outbound`: https://sing-box.sagernet.org/configuration/outbound/vless/
