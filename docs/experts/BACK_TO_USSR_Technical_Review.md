# ТЕХНИЧЕСКАЯ ЭКСПЕРТИЗА: BACK_TO_USSR VPN Client
## macOS Menu Bar App — Swift + AppKit + sing-box subprocess

**Дата экспертизы:** 2026-03-13  
**Эксперт:** Claude Code  
**Версия кода:** Current HEAD

---

## EXECUTIVE SUMMARY

Экспертиза выявила **4 критических**, **8 высокорисковых** и **6 среднерисковых** проблем. Код имеет серьезные проблемы с concurrency, thread safety и error handling, которые могут привести к:
- Race conditions и data races
- UI freezes и deadlocks
- Потере VPN-соединения в критичных моментах
- Конфликтам с OAuth/MCP сервисами
- Утечкам DNS/IP в цензурируемых регионах

**Рекомендация:** Исправить все CRITICAL и HIGH-Risk issues перед production release.

---

## 1. CRITICAL FINDINGS (Release Blockers)

### 1.1 Race Condition: Некорректная отмена Task.detached
**Файл:** `main.swift:490-558`  
**Сложность исправления:** Low  
**Влияние:** High

```swift
private func autoConnect(reason: String, scheduleOnFailure: Bool) {
    currentConnectTask?.cancel()
    let task = Task.detached { [weak self] in
        guard let self else { return }
        guard !Task.isCancelled else { return }  // ← БАГ!
        // ...
    }
    currentConnectTask = task
}
```

**Проблема:** `Task.detached` создает независимый таск, который не наследует cancellation context. Проверка `Task.isCancelled` внутри detached task проверяет cancellation ТОЛЬКО этого нового таска, а не `currentConnectTask`.

**Последствия:**
- `disconnectTapped()` вызывает `resetReconnectState()` → `currentConnectTask?.cancel()`
- Но detached task продолжает выполняться
- Происходит попытка подключения даже после явного disconnect
- Возможен concurrent access к `runtimeManager.process`

**Исправление:**
```swift
let task = Task { [weak self] in  // Не detached!
    guard let self else { return }
    guard !Task.isCancelled else { return }
    // ...
}
```

---

### 1.2 Deadlock Risk: Thread.sleep в MainActor
**Файл:** `SingBoxRuntimeManager.swift:91-105`  
**Сложность исправления:** Low  
**Влияние:** High

```swift
func stop() {
    if let runningProcess = process, runningProcess.isRunning {
        runningProcess.terminate()
        Thread.sleep(forTimeInterval: 0.3)  // ← БЛОКИРУЕТ ПОТОК!
        if runningProcess.isRunning {
            runningProcess.interrupt()
            Thread.sleep(forTimeInterval: 0.2)  // ← БЛОКИРУЕТ ПОТОК!
        }
    }
}
```

**Проблема:** `Thread.sleep` в главном потоке блокирует UI на 500ms. При reconnect из `monitorTick()` это создает видимый UI freeze.

**Исправление:**
```swift
func stop() async {
    if let runningProcess = process, runningProcess.isRunning {
        runningProcess.terminate()
        try? await Task.sleep(nanoseconds: 300_000_000)
        if runningProcess.isRunning {
            runningProcess.interrupt()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}
```

---

### 1.3 Data Race: Небезопасный доступ к process
**Файл:** `main.swift:720-747`, `SingBoxRuntimeManager.swift`  
**Сложность исправления:** Medium  
**Влияние:** High

```swift
private func monitorTick() {
    guard runtimeManager.isRunning else { return }  // ← Чтение
    DispatchQueue.global().async {
        do {
            let ip = try self.testIP(timeout: 6)
        } catch {
            self.stopSingBox()  // ← Запись из другого потока
        }
    }
}
```

**Проблема:** Нет синхронизации доступа к `process` property. `isRunning` читается из главного потока, `stop()` вызывается из глобальной очереди.

**Исправление:** Использовать `actor` или `NSLock` для синхронизации.

---

### 1.4 Orphaned Process: Зомби-процессы sing-box
**Файл:** `SingBoxRuntimeManager.swift`  
**Сложность исправления:** Low  
**Влияние:** High

**Проблема:** Если приложение крашится или force-quit, sing-box процесс остается висеть. При следующем запуске порт может быть занят.

**Исправление:** При старте cleanup orphaned процессов:
```swift
private func cleanupOrphanedSingBoxProcesses() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    p.arguments = ["-f", "sing-box.*runtime-sing-box"]
    try? p.run()
}
```

---

## 2. HIGH-RISK FINDINGS

### 2.1 Нет graceful shutdown для TCP probes
**Файл:** `NodeProbe.swift:45-81`

`connection.cancel()` немедленно разрывает соединение без FIN handshake → half-open connections, RST floods.

### 2.2 Command Injection в runAdminProxy
**Файл:** `main.swift:594-629`

```swift
let service = activeNetworkServiceName() ?? "Wi-Fi"  // ← Нет sanitization!
```

Имя сетевого интерфейса может содержать `"` → command injection.

**Исправление:** Использовать массив arguments вместо shell string.

### 2.3 Нет timeout на lsof
**Файл:** `PortManager.swift:12-50`

`process.waitUntilExit()` может зависнуть навсегда.

### 2.4 IPv6 blind spot в canBind
**Файл:** `PortManager.swift:208-227`

Проверяется только IPv4, но sing-box может слушать на `::1`.

### 2.5 Port exhaustion attack
**Файл:** `PortManager.swift:154-166`

Linear scan 16383+ портов в worst case → CPU spike.

### 2.6 waitForPortRelease не гарантирует освобождение
**Файл:** `PortManager.swift:145-152`

Нет возвращаемого значения, нет SIGKILL fallback.

### 2.7 Нет retry с exponential backoff
**Файл:** `main.swift:428-461`

Одиночный timeout, нет retry для transient failures.

### 2.8 Нет fallback IP detection сервисов
**Файл:** `main.swift:575-592`

`api.ipify.org` может быть недоступен из-за цензуры.

---

## 3. MEDIUM-RISK FINDINGS

### 3.1 Неполный protected ports list
Отсутствуют: `11434` (Ollama), `5432` (PostgreSQL), `6379` (Redis), `8888` (Jupyter), и др.

### 3.2 Нет cleanup при applicationWillTerminate
Системный proxy остается включенным при force quit.

### 3.3 isBusy flag не thread-safe
Читается/пишется из разных потоков без синхронизации.

### 3.4 Нет валидации VLESS UUID format
Невалидный UUID → silent failure в sing-box.

### 3.5 Нет проверки sing-box code signature
Только executable bit, не signature/team ID.

### 3.6 Нет сохранения предыдущих proxy settings
Corporate proxy будет сброшен.

---

## 4. OAUTH / MCP / DEV TOOLS COMPATIBILITY

### Текущий статус: ⚠️ PARTIAL

**Работает:**
- Protected ports list блокирует основные dev порты
- Dynamic port allocation в 56000-56999 range
- `active-ports.json` для discovery

**Проблемы:**
1. **Runtime conflicts:** Если OAuth/MCP стартует ПОСЛЕ VPN — возможен конфликт
2. **Incomplete port list:** Многие популярные порты не защищены
3. **No coordination protocol:** Нет file-based reservation

**Рекомендации:**
```swift
// Добавить в protected ports:
let additionalProtectedPorts = [
    11434,  // Ollama
    6333,   // Qdrant
    6379,   // Redis
    5432,   // PostgreSQL
    3306,   // MySQL
    27017,  // MongoDB
    8888,   // Jupyter
    7860,   // Gradio
    3001,   // Next.js alt
    4200,   // Angular
    5175, 5176,  // Vite range
]
```

---

## 5. ARCHITECTURE ASSESSMENT

### 5.1 Testability: ⚠️ POOR
- Нет dependency injection
- Tight coupling через прямые вызовы
- Невозможно mock внешние зависимости

### 5.2 Single Responsibility: ❌ VIOLATED
`VPNApp` (876 строк) отвечает за:
- UI coordination
- State management
- Network operations
- Process management
- Audio playback
- Proxy configuration

### 5.3 Concurrency Safety: ❌ UNSAFE
- Data races на shared state
- Некорректное использование Task.detached
- Thread.sleep в MainActor

### 5.4 Error Handling: ⚠️ PARTIAL
- Многие ошибки игнорируются (`try?`)
- Нет structured error propagation
- Нет retry logic

---

## 6. MISSING TESTS

### Unit Tests: ❌ NONE
- [ ] PortManager.resolvePorts()
- [ ] SingBoxRuntimeManager.start()/stop()
- [ ] NodeProbeService.probe()
- [ ] SubscriptionParser.decodeSubscription()
- [ ] ReconnectPolicy.delay()

### Integration Tests: ❌ NONE
- [ ] Full connect/disconnect cycle
- [ ] Reconnect after network failure
- [ ] Port conflict resolution
- [ ] OAuth service coexistence

### E2E Tests: ❌ NONE
- [ ] Real subscription fetch
- [ ] Actual VPN connection
- [ ] IP leak detection

---

## 7. RECOMMENDED ARCHITECTURE CHANGES

### 7.1 Actor-based State Management
```swift
actor ConnectionState {
    private var process: Process?
    private var isConnecting = false
    
    func start() async throws { ... }
    func stop() async { ... }
}
```

### 7.2 Dependency Injection
```swift
protocol SingBoxRunning {
    func start(node: VlessNode) async throws
    func stop() async
}

class VPNApp {
    private let runtime: any SingBoxRunning
    
    init(runtime: any SingBoxRunning = SingBoxRuntimeManager()) {
        self.runtime = runtime
    }
}
```

### 7.3 State Machine
```swift
enum ConnectionState: Equatable {
    case disconnected
    case connecting(attempt: Int)
    case connected(node: VlessNode, since: Date)
    case reconnecting(reason: String, attempt: Int)
    case failed(lastError: Error)
}
```

---

## 8. RELEASE BLOCKERS

| # | Issue | Priority | Effort |
|---|-------|----------|--------|
| 1 | Task.detached cancellation bug | CRITICAL | 1h |
| 2 | Thread.sleep deadlock | CRITICAL | 1h |
| 3 | Data race on process | CRITICAL | 2h |
| 4 | Orphaned sing-box processes | CRITICAL | 1h |
| 5 | Command injection | HIGH | 2h |
| 6 | lsof timeout | HIGH | 1h |

---

## 9. RISKS FOR CENSORED REGIONS

### 9.1 Traffic Fingerprinting: ⚠️ MEDIUM
- sing-box имеет характерный TLS fingerprint
- VLESS + XTLS-Reality детектируется DPI

**Рекомендация:** Добавить WebSocket + TLS obfuscation

### 9.2 DNS Leak: ⚠️ MEDIUM
- DNS queries могут leak до подключения

**Рекомендация:** Firewall rules до подключения

### 9.3 No Kill Switch: ❌ HIGH
- При разрыве VPN трафик идет напрямую

**Рекомендация:** Implement firewall-based kill switch

---

## 10. SUMMARY

| Category | Count | Status |
|----------|-------|--------|
| Critical | 4 | 🔴 Must Fix |
| High Risk | 8 | 🟠 Should Fix |
| Medium Risk | 6 | 🟡 Nice to Fix |
| Missing Tests | 7 | ⚪ Add Soon |
| Release Blockers | 6 | 🔴 Block Release |

### Overall Code Quality: C+
- **Architecture:** C (нарушение SRP, tight coupling)
- **Concurrency:** D (data races, deadlocks)
- **Error Handling:** C (partial, inconsistent)
- **Testability:** D (no DI, no tests)
- **Security:** C (command injection, no signature check)

### Recommendation
**DO NOT RELEASE** в production до исправления CRITICAL issues. Текущий код имеет серьезные проблемы с concurrency, которые приведут к нестабильной работе в production.

---

## 11. DETAILED CODE REVIEW

### 11.1 main.swift

#### Lines 66-76: State Management
```swift
private var isBusy = false  // Нет синхронизации
private var reconnectAttempt = 0
private var reconnectWorkItem: DispatchWorkItem?
private var currentConnectTask: Task<Void, Never>?
```

**Проблема:** `isBusy` используется как флаг для предотвращения concurrent operations, но не thread-safe.

#### Lines 288-297: connectTapped
```swift
@objc private func connectTapped() {
    guard !isBusy else { return }
    resetReconnectState()
    setConnectedCheck(false)
    autoConnect(reason: "manual", scheduleOnFailure: false)
}
```

**Проблема:** `isBusy` проверяется, но не устанавливается в `true` здесь. Устанавливается только в `autoConnect()`.

#### Lines 490-558: autoConnect (CRITICAL)
```swift
let task = Task.detached { [weak self] in
    // ...
    for probe in probeResults {
        guard !Task.isCancelled else { return }  // Не работает!
        // ...
        try self.startSingBox(node: node, useFlow: useFlow)
        // ...
    }
}
```

**Критическая проблема:** `Task.detached` не наследует cancellation.

#### Lines 720-747: monitorTick
```swift
private func monitorTick() {
    guard state.autoReconnect else { return }
    guard !isBusy else { return }
    guard runtimeManager.isRunning else { return }
    
    DispatchQueue.global().async {
        do {
            let ip = try self.testIP(timeout: 6)
            DispatchQueue.main.async { self.setIP(ip) }
        } catch {
            self.stopSingBox()  // Data race!
        }
    }
}
```

**Проблема:** `stopSingBox()` вызывается из global queue, `isRunning` читается из main thread.

### 11.2 SingBoxRuntimeManager.swift

#### Lines 54-89: start
```swift
let ownedProcessIDs = process.map { Set([$0.processIdentifier]) } ?? []
stop()  // Вызывается до получения ownedProcessIDs
```

**Проблема:** `stop()` вызывается ПОСЛЕ получения ownedProcessIDs, но ДО их использования. Если `stop()` успешно завершит процесс, `ownedProcessIDs` будет содержать несуществующий PID.

#### Lines 91-105: stop (CRITICAL)
```swift
func stop() {
    if let runningProcess = process, runningProcess.isRunning {
        runningProcess.terminate()
        Thread.sleep(forTimeInterval: 0.3)  // Блокирует поток!
        // ...
    }
}
```

**Критическая проблема:** `Thread.sleep` в главном потоке.

### 11.3 PortManager.swift

#### Lines 68-73: Protected Ports
```swift
protectedPorts: Set<Int> = [
    1080, 1087,
    3000, 4000, 5000, 5001, 5003,
    5173, 5174,
    8000, 8080, 8081, 8082, 8787,
]
```

**Проблема:** Неполный список. Отсутствуют многие популярные dev порты.

#### Lines 119-143: resolvePort
```swift
if let preferredPort, !protectedPorts.contains(preferredPort) {
    if let occupant = inspector.listeningProcess(on: preferredPort) {
        if ownedProcessIDs.contains(occupant.pid) {
            _ = terminator.terminate(pid: occupant.pid)
            waitForPortRelease(preferredPort)
        }
    }
    // Проблема: не проверяем, освободился ли порт!
    if let occupant = inspector.listeningProcess(on: preferredPort) {
        // Используем fallback
    }
}
```

**Проблема:** Если terminate не сработал, мы все равно пытаемся использовать preferredPort.

#### Lines 145-152: waitForPortRelease
```swift
private func waitForPortRelease(_ port: Int) {
    for _ in 0..<10 {
        if inspector.listeningProcess(on: port) == nil {
            return
        }
        usleep(100_000)
    }
}
```

**Проблема:** Нет возвращаемого значения. Caller не знает, успешно ли освобождение.

#### Lines 208-227: canBind
```swift
private func canBind(port: Int) -> Bool {
    let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)  // Только IPv4
    // ...
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    // ...
}
```

**Проблема:** Проверяется только IPv4. sing-box может слушать на IPv6.

### 11.4 NodeProbe.swift

#### Lines 45-81: TCPNodeDialer.dial
```swift
case .ready:
    timeoutBox.cancel()
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000.0
    connection.cancel()  // Нет graceful shutdown!
    box.resume(continuation, with: .success(elapsed))
```

**Проблема:** `connection.cancel()` немедленно разрывает соединение.

### 11.5 SubscriptionParser.swift

#### Lines 16-37: decodeSubscription
```swift
let candidates = [normal, urlsafeToStd].flatMap { [$0, $0 + "=", $0 + "==", $0 + "==="] }
```

**Проблема:** Бесконечный перебор padding вариантов.

---

## 12. RECOMMENDED FIXES (Priority Order)

### Priority 1: CRITICAL (Fix Before Release)

1. **Fix Task.detached cancellation bug**
   - File: `main.swift:497`
   - Change: `Task.detached` → `Task`
   - Effort: 5 minutes

2. **Fix Thread.sleep deadlock**
   - File: `SingBoxRuntimeManager.swift:91-105`
   - Change: Make `stop()` async, use `Task.sleep`
   - Effort: 30 minutes

3. **Fix data race on process**
   - File: `SingBoxRuntimeManager.swift`
   - Change: Use `actor` or `NSLock`
   - Effort: 2 hours

4. **Fix orphaned processes**
   - File: `SingBoxRuntimeManager.swift`
   - Change: Add cleanup on startup
   - Effort: 30 minutes

### Priority 2: HIGH (Fix Soon After Release)

5. **Fix command injection**
   - File: `main.swift:594-629`
   - Change: Use array arguments
   - Effort: 1 hour

6. **Add lsof timeout**
   - File: `PortManager.swift:12-50`
   - Change: Add timeout mechanism
   - Effort: 30 minutes

7. **Fix IPv6 blind spot**
   - File: `PortManager.swift:208-227`
   - Change: Check both IPv4 and IPv6
   - Effort: 1 hour

8. **Add fallback IP detection**
   - File: `main.swift:575-592`
   - Change: Multiple IP services
   - Effort: 30 minutes

### Priority 3: MEDIUM (Nice to Have)

9. **Extend protected ports list**
10. **Add applicationWillTerminate cleanup**
11. **Add UUID validation**
12. **Add sing-box signature check**

---

*Экспертиза проведена Claude Code на основе анализа исходного кода.*
