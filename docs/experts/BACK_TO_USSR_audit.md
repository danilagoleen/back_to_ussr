# BACK_TO_USSR — Independent Technical Audit
**Reviewed files:** `main.swift`, `Models.swift`, `NodeProbe.swift`, `PortManager.swift`,
`ReconnectPolicy.swift`, `SingBoxConfigBuilder.swift`, `SingBoxRuntimeManager.swift`,
`SubscriptionParser.swift`, `Package.swift`, `build_back_to_ussr_app.command`, `run_tests.sh`

---

## Critical Findings

### C-1 · `SingBoxRuntimeManager` mutated from multiple threads simultaneously (data race, crash risk)

`monitorTick` dispatches to `DispatchQueue.global()` and calls `self.stopSingBox()` from that
background thread. `stopSingBox()` calls `runtimeManager.stop()` which writes to `process`,
`activePorts`, `launchWarnings`, and deletes files on disk — all unguarded. Concurrently,
the `Task.detached` inside `autoConnect` also calls `startSingBox` / `stopSingBox` on its
cooperative thread pool thread. `SingBoxRuntimeManager` is a `final class` with zero
synchronization. This is undefined behaviour under Swift's memory model and will cause torn
reads/writes, and sporadic crashes on Apple Silicon.

**Concrete trigger:** sing-box crashes while connected → monitor fires testIP → fails →
background thread calls `stopSingBox()` → at the same moment `autoConnect` task (from a
previous `scheduleReconnect`) calls `runtimeManager.start()`. Both threads mutate `process`
and `activePorts` simultaneously.

**Fix:** Make `SingBoxRuntimeManager` an `actor`, or put all mutation behind a `NSLock` /
`DispatchQueue(label:…, target: .main)` serial queue.

---

### C-2 · Sing-box config routes ALL traffic through proxy — breaks localhost MCP, OAuth, and Claude/Codex

`SingBoxConfigBuilder.buildRuntimeConfig` produces:
```json
"route": { "final": "proxy", "rules": [{ "protocol": "dns", "outbound": "dns-out" }] }
```
There is no rule exempting private or loopback addresses. When macOS system proxy is enabled
(via `runAdminProxy`), any application that honours the system proxy and contacts a local
server (MCP servers on 127.0.0.1:3000–5001, OAuth loopback callbacks per RFC 8252,
Claude Desktop, Codex, OpenCode) will have that request routed **through the remote VLESS
server**, which will attempt to connect to `127.0.0.1:PORT` on the *remote* machine — failing
silently or returning wrong content. This directly breaks the stated Priority #1.

**Fix:** Add a route rule *before* `final`:
```swift
["ip_cidr": ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
             "::1/128", "fc00::/7"],
 "outbound": "direct"]
```

---

### C-3 · `testIP` false-positive: falls back to port 1080 when `activePorts` is nil

```swift
let socksPort = runtimeManager.activePorts?.socks ?? SingBoxPorts.defaults.socks  // = 1080
```

If sing-box isn't running (activePorts is nil), `testIP` connects via SOCKS5 to port 1080.
If *any other* SOCKS5 proxy occupies 1080 (user's corporate VPN, another VPN tool, Dante),
`testIP` succeeds, returns an IP, and `handleConnectSuccess` is called — telling the user
they are "Connected" via BACK_TO_USSR when they are actually routing through a foreign proxy.

This is also triggered during the reconnect flow: between `stopSingBox()` and the new
`startSingBox()`, a monitor testIP can race in and hit port 1080.

**Fix:** Fail hard if `activePorts` is nil:
```swift
guard let ports = runtimeManager.activePorts else { throw ... }
let socksPort = ports.socks
```

---

### C-4 · System proxy stays enabled forever when reconnect is exhausted or app crashes

When 20 reconnect attempts are exhausted, `scheduleReconnect` shows an alert and returns
without calling `runAdminProxy(enable: false)`. The macOS HTTP/HTTPS/SOCKS proxy settings
keep pointing to the dead port, making **all internet access fail** for the user. In a
censored-country context, this is catastrophic: the direct connection is also blocked by the
censor, so the user is left with zero internet access until they manually open System
Settings → Network → Proxies and turn them off.

Same problem occurs on force-quit or crash: there is no `applicationWillTerminate` delegate
method, so the proxy is never cleaned up.

**Fix:**
1. Add `func applicationWillTerminate(_ notification: Notification)` that calls
   `stopSingBox()` and `runAdminProxy(enable: false)`.
2. In `scheduleReconnect`, after exhausting attempts, call `runAdminProxy(enable: false)`.
3. Consider registering a `signal(SIGTERM, ...)` / `atexit` handler as a last-resort cleanup.

---

### C-5 · `runAdminProxy(enable: true)` blocks the main thread (and the MainActor) with a UAC dialog

`handleConnectSuccess` is called inside `await MainActor.run { }`. From there it calls
`runAdminProxy(enable: true)`, which:
1. Spawns `networksetup -listnetworkserviceorder` and `waitUntilExit()` synchronously.
2. Spawns `osascript` with `with administrator privileges` and `waitUntilExit()`.

Step 2 raises a password dialog and waits for user interaction — all while the main thread
(and the MainActor) is completely frozen. The menu bar becomes unresponsive, timers stop
firing, and macOS may show the beach ball. This can also leave the app in a half-connected
state if the user clicks Cancel (sing-box is up but proxy is not set).

**Fix:** Move `runAdminProxy` to a background thread / `Task.detached`. Consider switching to
`SMJobBless` / a privileged helper (launchd daemon) or `systemextension` so that proxy
management does not require repeated UAC prompts.

---

## High-Risk Findings

### H-1 · `setConnectedCheck` copy-paste bug: Disconnect menu item never shows checkmark

```swift
private func setConnectedCheck(_ connected: Bool) {
    menu.item(withTag: 1001)?.state = connected ? .on : .off  // Connect
    menu.item(withTag: 1002)?.state = connected ? .off : .off  // ← always .off
}
```
The Disconnect item is hardcoded to `.off` regardless of `connected`. Users get no visual
confirmation that they are connected. This is a regression visible to every user.

**Fix:** `connected ? .off : .on` for the Disconnect item (or use a single status icon).

---

### H-2 · In-flight `curl` subprocess from `testIP` not killed on task cancellation — 10-second stall on Disconnect

When `disconnectTapped` calls `resetReconnectState()` → `currentConnectTask.cancel()`, the
`Task.detached` has a cooperative cancellation check (`guard !Task.isCancelled`). But
`testIP` calls `p.run()` then `p.waitUntilExit()` — a blocking POSIX wait that Swift
concurrency cannot preempt. The curl process will run for up to 10 seconds after the user
clicked Disconnect. During that time:
- `runtimeManager.process` is already nil (stopSingBox was called).
- When testIP finally returns (curl fails because sing-box is dead), the guard fires,
  and `stopSingBox()` is called again — harmless but messy.

In a censored-country context, users may click Disconnect urgently. A 10-second "ghost"
curl subprocess is a leak and a bad UX.

**Fix:** Set `p.terminationHandler` or call `p.terminate()` in a cancellation-aware wrapper.
Alternatively, use `URLSession` async APIs that can be cancelled.

---

### H-3 · `ReconnectCoordinator` is dead code — `VPNApp` reimplements reconnect logic inline

`ReconnectPolicy.swift` defines a `ReconnectCoordinator` struct with a `run(operation:)` method,
but `VPNApp` in `main.swift` manages `reconnectAttempt`, `reconnectWorkItem`, and
`reconnectPolicy.delay` manually. `ReconnectCoordinator` is never instantiated. The duplicate
logic has already diverged: the coordinator uses a loop with `await sleeper.sleep()`, the
app uses `DispatchWorkItem` on the main queue. The coordinator's sleep is testable with a
mock `SleepControlling`; the inline version is not.

**Fix:** Either delete `ReconnectCoordinator` and document that the DispatchWorkItem approach
is intentional, or remove the inline logic and use `ReconnectCoordinator` (running in a
`Task.detached` with proper cancellation).

---

### H-4 · Shell injection risk in `runAdminProxy` via network service name

The service name from `activeNetworkServiceName()` is interpolated directly into the osascript
shell string. The escaping only handles `\` and `"`:
```swift
let escaped = shell
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
```
A network service name containing a semicolon (e.g., a VPN that names itself
`My VPN; echo pwned`) would inject commands into the shell executed with administrator
privileges. macOS does allow custom service names via `networksetup -createnetworkservice`.

**Fix:** Use `Process` with individual argument arrays rather than a shell string, or
validate/sanitize the service name before interpolation.

---

### H-5 · Build: hardcoded developer-specific absolute paths break all CI and contributor builds

```bash
MUSIC_SRC_DIR="/Users/danilagulin/Documents/ussr_vpn/music/compress"
HERO_IMAGE_SRC="/Users/danilagulin/Documents/ussr_vpn/logo_ussr/..."
```
Any build on any other machine silently skips music and the subscription hero image.
The build "succeeds" with a degraded bundle. For release builds this means shipping a
different (worse) app than what was tested locally — a regression in branding/UX.

**Fix:** Resolve relative to `$ROOT` (e.g., `$ROOT/assets/music/`, `$ROOT/assets/logo/`).
Add a CI check that asserts the expected files exist in the bundle after build.

---

### H-6 · Build: Intel (x86_64) only — runs under Rosetta 2 on Apple Silicon, sing-box too

The compiler target is `-target x86_64-apple-macos11.0` and sing-box is the
`darwin-amd64` binary. On Apple Silicon Macs (M1–M4), both the app and the sing-box
subprocess run under Rosetta 2. Rosetta introduces:
- ~10–30ms extra startup latency per process spawn.
- Incompatibility with future macOS versions where Rosetta may be removed.
- `sing-box` amd64 is not tested by Apple's arm64 Notarization pipeline.

**Fix:** Build a universal binary (`-target arm64-apple-macos11.0` + `lipo`) and bundle both
`sing-box-darwin-amd64` and `sing-box-darwin-arm64`, selecting at runtime via
`uname -m` or `ProcessInfo.processInfo.machineHardwareIdentifier`.

---

## Medium-Risk Findings

### M-1 · `lsof` invoked sequentially for each protected port — 1–2s startup and port-resolve penalty

`snapshotProtectedPorts()` calls `inspector.listeningProcess(on:)` for each of the 13
protected ports one by one. Each call forks `lsof` and waits. On a loaded system, each
lsof invocation can take 80–150ms. Total: up to ~2 seconds at startup and on every
`resolvePorts` call. This delay blocks the calling thread.

**Fix:** Run a single `lsof -nP -iTCP -sTCP:LISTEN -Fpc` invocation, parse all ports from
the output at once.

---

### M-2 · `canBind` TOCTOU race: port can be stolen between availability check and sing-box bind

`canBind` opens a socket, binds to check availability, then closes it. sing-box then starts
and tries to bind the same port. Between the close and sing-box's bind, another process can
grab the port. If sing-box fails to bind, it exits silently (stderr is consumed by a Pipe and
never checked). The app then enters the connected state pointing to a dead process.

**Partial mitigation:** `runtimeManager.isRunning` will detect the dead process on next
monitor tick. But the 30-second gap means the user sees "Connected" for up to 30s while
traffic fails.

**Fix:** Check `runtimeManager.process?.isRunning` a second time ~200ms after `start()`, or
parse sing-box's stderr for bind errors.

---

### M-3 · `SingBoxPorts.defaults` (`1080/1087`) should not exist — it's an invitation to use the old ports

The `static let defaults` remains on `SingBoxPorts` even though the new architecture
explicitly forbids using 1080/1087. Any accidental `?? .defaults` (as seen in `testIP` and
`runAdminProxy`) silently reintroduces the old conflict-prone behaviour. Having the constant
exist is a footgun.

**Fix:** Remove `static let defaults`. Any site that needs a fallback should `throw` or
return an explicit error instead of silently routing to a legacy port.

---

### M-4 · Monitor timer continues while `isBusy = false` during reconnect delay — potential double reconnect on edge cases

`scheduleReconnect` sets `isBusy = false` before the `DispatchWorkItem` fires (to allow
menu interaction during the delay). However, there is a narrow window where:
1. Reconnect workItem is pending (`isBusy = false`).
2. The workItem fires and `autoConnect` is called (`isBusy = true`).
3. Between `autoConnect` setting `isBusy = true` and the Task.detached checking
   `Task.isCancelled`, the monitor timer fires — it sees `!isBusy` is false, so it
   is blocked. Safe.

In practice the main-thread guard works. But the code is fragile: any path that sets
`isBusy = false` prematurely can break this invariant. Document it explicitly or use an
`enum ConnectionState` instead of a bare Bool.

---

### M-5 · No proxy bypass list for localhost in system proxy setup

Even if C-2 (sing-box routing) is fixed, `networksetup` should also be called with:
```
-setproxybypassdomains "Wi-Fi" "localhost" "127.0.0.1" "*.local"
```
Some macOS system services, Apple Push Notification service, and Bonjour bypass this
anyway, but Electron-based apps (Claude Desktop, VS Code, OpenCode) use CEF's proxy
resolution and *do* honour system proxy for loopback if not exempted. Without this bypass
list, fixing C-2 at the sing-box routing layer is not sufficient.

---

### M-6 · `Thread.sleep` on cooperative Swift concurrency threads

`SingBoxRuntimeManager.start()` calls `Thread.sleep(forTimeInterval: startupDelay)` (1.2s)
and `stop()` calls `Thread.sleep(forTimeInterval: 0.3)`. These are called from inside a
`Task.detached` context. `Thread.sleep` blocks a cooperative thread pool thread for its
duration, potentially starving other async tasks. Should be `try await Task.sleep(…)` in
async contexts.

---

### M-7 · sing-box v1.9.3 is not current — security and protocol improvements missed

Latest sing-box is v1.11.x (as of mid-2025). Version 1.9.x predates several VLESS/XTLS
stability fixes. In a censored-country context, running an older sing-box version may mean:
- Fingerprint detection vulnerability (DPI probes for old TLS handshake patterns).
- XTLS bugs fixed in 1.10+ (including flow-related crashes).
Hardcoding the version in the build script means there is no automated security update.

---

### M-8 · `autoReconnect = true` by default in saved state — user who disabled it may not notice it re-enables

`AppState.init(from:)` decodes `autoReconnect` with `?? true`. If the state file is missing
or corrupted, auto-reconnect silently re-enables. In a corporate/privacy-sensitive context,
users who turned off auto-reconnect (to prevent unexpected traffic) will be surprised.

---

### M-9 · No `CFBundleVersion` increment mechanism — Gatekeeper and Sparkle can't detect updates

`Info.plist` always writes `1.0`. Every build produces the same version. macOS Gatekeeper
logs, system crash reports, and any future auto-update mechanism (Sparkle) depend on
unique bundle versions. Also, if the user has two versions installed, macOS can't
disambiguate them.

---

## Missing Tests

### MT-1 · No test for `testIP` when `activePorts` is nil (C-3 scenario)
Asserts that `testIP` throws rather than falling back to port 1080.

### MT-2 · No test for concurrent `stopSingBox` calls (C-1 scenario)
Spawn two Tasks that both call stop/start; assert no crash and consistent final state.

### MT-3 · No test for system proxy cleanup on termination (C-4 scenario)
Mock `runAdminProxy` and assert it is called with `enable: false` in quit/crash paths.

### MT-4 · No test for `setConnectedCheck` correctness (H-1 regression)
Assert that when connected=true, tag 1001 is `.on` and tag 1002 is `.on`.

### MT-5 · No test for route config including private IP bypass (C-2 scenario)
Parse the generated JSON config and assert a rule exists for `127.0.0.0/8` → direct.

### MT-6 · No integration test for full reconnect cycle
Start → simulate sing-box death → assert reconnect fires, backoff increments, proxy stays
managed correctly through all state transitions.

### MT-7 · No test for `ReconnectCoordinator` vs inline logic parity
If both exist, they should produce identical delay sequences. Currently untested.

### MT-8 · No test for port selection race / TOCTOU
Simulate another process grabbing a port between `canBind` and `start`. Assert the app
detects the failure and does not report "Connected".

### MT-9 · No test for `activeNetworkServiceName` with service names containing special characters (H-4)
Assert that a service name like `My VPN; rm -rf /` does not execute arbitrary commands.

### MT-10 · No test for build-bundle completeness
Assert that the built `.app` contains `sing-box`, at least one `.mp3`, `subscription_hero.png`,
and `AppIcon.icns`. This would catch the hardcoded-path regression (H-5) in CI.

---

## Recommended Architecture Changes

### A-1 · Make `SingBoxRuntimeManager` an `actor`

```swift
actor SingBoxRuntimeManager {
    private(set) var process: Process?
    private(set) var activePorts: SingBoxPorts?
    // …
    func start(…) async throws -> SingBoxPorts { … }
    func stop() async { … }
}
```

Callers in `autoConnect` (already async) and `monitorTick` (needs to become async or
use `Task { await runtimeManager.stop() }`) gain automatic mutual exclusion for free.

### A-2 · Replace `DispatchWorkItem` reconnect scheduling with structured `Task` + `ReconnectCoordinator`

```swift
private var reconnectTask: Task<Void, Never>?

private func scheduleReconnect() {
    reconnectTask?.cancel()
    reconnectTask = Task.detached { [weak self] in
        guard let self else { return }
        let succeeded = await ReconnectCoordinator(policy: reconnectPolicy, sleeper: SystemSleeper())
            .run { attempt in
                await MainActor.run { self.setStatus("Reconnecting \(attempt)/…") }
                return await self.tryConnect()
            }
        if !succeeded {
            await MainActor.run { self.handleReconnectExhausted() }
        }
    }
}
```

This makes cancellation correct (`Task.cancel()` is immediate and propagates through
`Task.sleep`), makes the reconnect logic testable with mock sleepers, and eliminates
the `DispatchWorkItem` + `reconnectAttempt` counter duplication.

### A-3 · Introduce `ConnectionState` enum to replace `isBusy: Bool`

```swift
enum ConnectionState {
    case idle
    case connecting(Task<Void, Never>)
    case connected(SingBoxPorts, String) // ports, ip
    case reconnecting(Int, DispatchWorkItem) // attempt, workItem
    case disconnecting
}
```

This makes impossible states impossible (can't be both `connecting` and `reconnecting`),
simplifies all the `guard !isBusy` / `guard runtimeManager.isRunning` pairs, and
makes state transitions explicit and auditable.

### A-4 · Extract proxy management into a dedicated `SystemProxyManager`

Responsibilities: setting/clearing system proxy, managing bypass list, detecting the
active network interface, and running the privileged helper. Extracting this makes it
mockable in tests and separates the concern from connection lifecycle.

### A-5 · Port selection: combine `canBind` + `lsof` into one atomic check, log the decision

Run one `lsof` sweep, build a `Set<Int>` of all occupied ports, then select from the
preferred range without spawning additional processes. Write the full decision (what was
available, what was selected, why) to `port-diagnostics.json` at every call.

---

## Release Blockers

| # | Finding | Why it blocks release |
|---|---------|----------------------|
| RB-1 | C-2 (localhost routing) | Breaks MCP, OAuth, Claude, Codex for every user |
| RB-2 | C-4 (proxy not cleaned up) | User loses all internet on reconnect exhaustion or crash |
| RB-3 | C-3 (testIP false positive) | App reports "Connected" when it is not |
| RB-4 | H-1 (setConnectedCheck bug) | UI regression visible to every user |
| RB-5 | H-5 (hardcoded paths) | Bundles without music/logo assets on every non-developer build |
| RB-6 | H-6 (Intel only) | Degraded performance on all M-chip Macs; future Rosetta removal risk |

---

## Nice-to-Have Improvements

**NTH-1 · Discovery contract hardening**
Add a `machine-readable-schema-version` field to `active-ports.json`. External tools
(Claude, MCP servers) can check this before trusting the file. Add a `BACK_TO_USSR_SOCKS`
and `BACK_TO_USSR_HTTP` environment variable set by a launchd plist so tools can discover
ports without parsing JSON.

**NTH-2 · Proxy bypass list auto-management**
Before enabling the system proxy, snapshot the current bypass list and restore it on
disconnect. This prevents the common issue of users losing their custom bypass domains.

**NTH-3 · Graceful sing-box stderr monitoring**
Read sing-box's stderr asynchronously and log errors to the diagnostics file. Currently
the stderr Pipe is consumed but never read, so fatal errors from sing-box are silently lost.

**NTH-4 · Multiple network interface awareness**
`runAdminProxy` sets proxy for only one interface (the default route interface at connection
time). If the user switches from Wi-Fi to Ethernet while connected, the new interface has
no proxy. Consider setting proxy on all active interfaces, or using `scutil --proxy`.

**NTH-5 · `sing-box` process group management**
Use `setpgid(0, 0)` on the sing-box process so that if the parent app is killed, sing-box
doesn't become an orphan that holds ports and keeps the proxy semi-alive.

**NTH-6 · Notarization path**
The current ad-hoc `codesign --sign -` build cannot be notarized. For distribution outside
the developer's machine, users must override Gatekeeper each time. In a censored-country
context, non-technical users will be blocked at this step. Budget time for a Developer ID
signing + notarization workflow.

**NTH-7 · `refreshTapped` blocks background thread during network fetch**
`fetchURL` uses `DispatchSemaphore.wait` to block a `DispatchQueue.global()` thread.
Subscribes a background thread for 20–25 seconds per URL. With many subscription URLs, this
can exhaust the global concurrent queue. Convert to `async/await` with `URLSession.data(for:)`.

---

## Risk Summary for Users in Censored Countries

| Risk | Impact |
|------|--------|
| C-2 (localhost routing) | OAuth flows silently break; Claude/Codex/MCP tools stop working while VPN is on |
| C-4 (proxy not cleaned on crash/exhaustion) | Total internet loss until manual proxy reset — can strand user |
| C-3 (testIP false positive) | User believes they have VPN protection when traffic may be going direct or through wrong proxy |
| M-7 (old sing-box) | Older fingerprint may be detectable by DPI; potential XTLS bugs |
| H-2 (10s stall on disconnect) | User can't quickly disconnect if they need to switch to direct connection |
| M-5 (no proxy bypass for localhost) | Even with C-2 fixed, Electron apps still break |

The most urgent fix for this user population is C-2 + C-4 + C-3 together, as they directly
affect safety and reliability in a hostile network environment.
