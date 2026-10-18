# Multilink Web Console Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace multilink's text menu with a one-click, live browser console (buttons, live per-link graph, per-app monitor, data cap, boost-lost alert), then delete the scripts it supersedes.

**Architecture:** `multilink.ps1` becomes an engine of data functions plus the console entry point. `console/Server.ps1` runs an `HttpListener` on localhost (Facade over the engine) with background runspaces writing into one synchronized hashtable (producer/consumer); `console/index.html` polls JSON endpoints. aria2 runs one RPC-enabled process per download; per-app accounting comes from an ETW session compiled from C# with `Add-Type`.

**Tech Stack:** Windows PowerShell 5.1, C# 5 via `Add-Type`, aria2c, curl.exe, Pester 3.4.0, vanilla HTML/CSS/JS.

**Spec:** `docs/superpowers/specs/2026-10-19-multilink-web-console-design.md` (read it alongside this plan). Visual target: the preview HTML at
`C:\Users\parih\AppData\Local\Temp\claude\C--Users-parih-Desktop-projects-internet-speed\0507daba-ef21-4e6c-9cea-18dbc5bd204c\scratchpad\multilink-console.html`.

## Global Constraints

- Runtime is **Windows PowerShell 5.1** (`powershell.exe`), never `pwsh`. Run every script and test through `powershell.exe -NoProfile -ExecutionPolicy Bypass`. The dev shell is pwsh 7.6; don't let that leak in (`??`, `?.`, ternaries, `-Parallel` are forbidden).
- C# passed to `Add-Type` must compile with the 5.1 in-box compiler: **C# 5**. No string interpolation, `?.`, `nameof`, expression-bodied members, or `out var`.
- No new installs: only aria2 (auto-installed via winget, as today) and curl.exe. No modules beyond in-box Pester 3.4.0 (syntax: `Should Be`, `Should Throw`, `Should BeNullOrEmpty`; no `-Be`).
- The page makes **no external requests**. System font stacks: `"Segoe UI", system-ui, sans-serif` and `"Cascadia Mono", Consolas, ui-monospace, monospace`.
- Listener prefix `http://localhost:<port>/`, port 8642 with fallback up to 8662. Drop every request whose `RemoteEndPoint` isn't loopback. Required header: `X-Multilink-Token`. `Host` must equal `localhost:<port>`. `Origin`, when present, must equal `http://localhost:<port>`. POST bodies must be `application/json`.
- Settings are stored at `%LOCALAPPDATA%\multilink\settings.json` with keys `capGB` (default 10), `mobileAlias` (null = auto), `baselineMbps`, `baselineAt`, `shortcutAsked`.
- The ETW session is named `MultilinkNetMon`, on provider `Microsoft-Windows-Kernel-Network` `{7DD42A49-5329-4832-8DFD-43D979153A88}`.
- aria2 flags kept from today: `-x16 -s16 -k1M --continue=true --file-allocation=none --async-dns=false --max-tries=5 --retry-wait=2`. Every aria2c also gets `--enable-rpc --rpc-listen-all=false --rpc-listen-port=<free> --rpc-secret=<random> --stop-with-process=<console PID>`, and the console's Job Object.
- Metric values for Prefer: preferred link **10**, others **60** (same as today's `Invoke-Optimise`).
- Mobile adapter auto-detect regex on `InterfaceDescription`: `Remote NDIS|RNDIS|Mobile Broadband|Cellular`.
- UI copy follows the preview, including these strings: "Speed boost lost", "Mobile data cap reached", "A download is already running", "Restart the console as administrator", "The console has stopped. Double-click multilink.bat to start it again."
- Superseded scripts are deleted **only in Task 10**, after the console has been verified.
- Commit after each task. End commit messages with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Shared JSON contract (server ⇄ page)

Every task that touches the API uses these shapes. Errors use HTTP status + `{ "error": "<message>" }`.

```
GET /api/state → {
  isAdmin, appMonitorMode: "etw"|"connections",
  paths: [{ alias, ip, gateway, metric, autoMetric, isMobile, publicIp|null,
            rxMbps, txMbps,
            latency: { avgMs, maxMs, jitterMs, lossPct, tcpOnly, measuredAt } | null }],
  separation: { status: "ok"|"lost"|"unverified"|"single"|"unknown", checkedAgoSec|null },
  suggestedGamingLink: alias|null,  defaultRouteAlias: alias|null,  preferredAlias: alias|null,
  mobile: { alias|null, sessionGB, capGB, capHit },
  baseline: { mbps, measuredAt } | null
}
GET /api/series → { intervalSec: 1, samples: [{ t, links: { <alias>: { rx, tx } } }] }   // ≤60, Mbps
GET /api/apps   → { mode, rows: [{ exe, name, protos: [..], downMbps|null, upMbps|null, conns,
                                    perLink: { <alias>: downMbps|null }, game, laggy }] }
GET /api/jobs/<id> → { id, kind, state: "running"|"done"|"failed",
                       log: [{ text, level: "info"|"good"|"warn"|"bad"|"dim"|"cmd" }], result }
GET /api/downloads → { current: Dl|null, finished: [Dl] }
  Dl = { id, url, filename, dir, mode: "all"|"one", link|null, totalBytes, completedBytes, speedMbps,
         perLinkBytes: { <alias>: bytes } | null,
         state: "active"|"complete"|"error"|"cancelled", switchedByCap, stoppedByCap, message|null }
POST /api/check | /api/baseline | /api/reset {apply} → { jobId }
POST /api/range {url}              → { splits, sizeBytes|null, filename|null, reason }
POST /api/downloads {url,mode,link,dir} → { id }        POST /api/downloads/<id>/cancel → {}
POST /api/prefer {alias} | /api/undo → { log: [...] }   POST /api/settings {capGB?, mobileAlias?} → state
POST /api/recheck → { jobId }       POST /api/stop → {}
```

## Review Focus

1. **The phone is unplugged or re-plugged mid-session.** Aliases disappear or reappear. The sampler, graph, and cards must not throw or show a stale link. The series keys simply change. *Test: Task 3 `Get-RateTable` with a link missing from the previous sample.*
2. **The download URL has no filename, redirects, or contains spaces, quotes, or `&`.** Values must reach aria2 as separate argv entries. A filename must still be shown, falling back to aria2's reported name. *Test: Task 6 `New-Aria2ArgList` with a URL containing `"&` and spaces.*
3. **Another program already holds port 8642.** The console must pick the next free port, and the browser must open on that port. *Test: Task 2 `Get-FreePort` with 8642 occupied by a test listener.*
4. **The cap is lowered below current usage while a download runs.** The next watcher tick must apply it (all-links download → wired; 5G-only download → stopped). *Test: Task 6 `Get-CapAction` table.*
5. **The console is not elevated.** Admin actions return 409 with "Restart the console as administrator". The app monitor runs in `connections` mode with null rates. Nothing crashes. *Test: Task 7 `Invoke-PreferApi` with `-IsAdmin:$false`, and Task 8 fallback rows have null Mbps.*

---

## File structure

| File | Responsibility |
|---|---|
| `multilink.ps1` | Engine data functions (paths, egress, latency, aria2 locate, metrics) + entry point that starts the console when executed, defines functions only when dot-sourced. |
| `console/Server.ps1` | `Start-MultilinkConsole`: listener loop, routing, wiring of the modules below. |
| `console/Http.ps1` | Pure request gate + JSON/response helpers + `Get-FreePort`. |
| `console/Store.ps1` | Settings load/save, synchronized state creation, rate math, ring buffer, mobile detection, sampler runspace. |
| `console/Jobs.ps1` | Job runner (runspace per job, log lines into state), check job, latency pass. |
| `console/Watch.ps1` | Separation logic, egress watcher, range probe, baseline. |
| `console/Downloads.ps1` | aria2 process + RPC client, download lifecycle, cap decisions. |
| `console/Network.ps1` | Prefer / undo / reset endpoints logic. |
| `console/Apps.ps1` + `console/NetMonitor.cs` | Per-app monitor (ETW + connections fallback), aggregation, game flag. |
| `console/Native.cs` | Job Object (kill-on-close) and console close handler. |
| `console/index.html` | The page. |
| `tests/*.Tests.ps1` | Pester tests; `tests/integration.ps1` HTTP smoke test. |

Run all unit tests with:
`powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path tests -EnableExit"`

---

### Task 1: Engine data functions in `multilink.ps1`

Add object-returning functions next to the existing code. The old menu and CLI keep working until Task 10.

**Files:**
- Modify: `multilink.ps1`
- Test: `tests/Engine.Tests.ps1`

**Interfaces:**
- Produces:
  - `Get-Paths` → objects `{Alias, IP, Gateway, Metric, Auto, InterfaceIndex, Description, IPv6: string[]}`. It extends the existing function; existing callers are unaffected.
  - `Test-Ipv4Text($s) → bool` (exists).
  - `Get-EgressVia -LocalIP -Aria -Dir -OutFile → string|$null` (exists).
  - `ConvertFrom-PingOutput([string]$text) → @{Times=int[]; LossPct=int}`.
  - `Get-LatencyStats([int[]]$times, [int]$lossPct) → @{avgMs; maxMs; jitterMs; lossPct}` (jitter = mean absolute successive difference, rounded to 0.1).
  - `Measure-PathLatency($path) → @{avgMs;maxMs;jitterMs;lossPct;tcpOnly;measuredAt}`. Same targets and fallback as today's `Invoke-Check` latency block; `tcpOnly=$true` when only the TCP 1.1.1.1:443 connect time was available (then avg=max=that ms, jitter=$null).
  - `Set-PathMetrics([string]$PreferredAlias) → string[]` (log lines) and `Reset-PathMetrics() → string[]`. These hold the bodies of `Invoke-Optimise`/`Invoke-Undo` without `Read-Host`, `Write-Host` or elevation.
  - The dot-source guard: the bottom `switch ($Action)` runs only when `$MyInvocation.InvocationName -ne '.'`.

- [ ] **Step 1: Write failing tests** in `tests/Engine.Tests.ps1` (dot-source `..\multilink.ps1` at the top):
  - `ConvertFrom-PingOutput` on a captured English `ping.exe -n 6` output with times 11,12,10,15,11,12 and "(0% loss)" → `Times` equals those six, `LossPct` 0. On output with "Request timed out." ×6 and "(100% loss)" → `Times.Count` 0, `LossPct` 100.
  - `Get-LatencyStats @(11,12,10,15,11,12) 0` → avgMs 11.8, maxMs 15, jitterMs 2.2, lossPct 0.
  - Dot-sourcing `multilink.ps1` doesn't print the menu: `(. .\multilink.ps1) | Should BeNullOrEmpty` and `Get-Command Get-Paths` exists.
  - `Test-Ipv4Text $null` → False; `' 49.36.112.87 '` → True; `'abc'` → False.
- [ ] **Step 2: Run** the test command. Expected: FAIL (functions missing).
- [ ] **Step 3: Implement** the functions above. Make `Invoke-Check`, `Invoke-Optimise` and `Invoke-Undo` call the new data functions so the logic exists once. Their printed text stays as it is today.
- [ ] **Step 4: Run tests.** Expected: PASS. Also run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File multilink.ps1 -Action check` and confirm the output has the same sections as before.
- [ ] **Step 5: Commit** `refactor: expose multilink engine as data functions`.

---

### Task 2: HTTP gate, port picking, server skeleton

**Files:**
- Create: `console/Http.ps1`, `console/Server.ps1`, `console/index.html` (temporary stub: `<title>Multilink Console</title><meta name="ml-token" content="{{TOKEN}}">`)
- Test: `tests/Http.Tests.ps1`, `tests/integration.ps1`

**Interfaces:**
- Produces:
  - `Test-RequestAllowed -RemoteAddress [string] -HostHeader [string] -Origin [string] -Method [string] -ContentType [string] -Token [string] -ExpectedToken [string] -Port [int] -IsApi [bool] → @{Allowed=bool; Status=int; Reason=string}`. Non-loopback → 403. Bad Host → 403. Bad Origin → 403. API with a missing or wrong token → 403. API POST whose content type isn't `application/json*` → 415. Non-API paths (only `/` and `/index.html`) need no token but still need loopback + Host.
  - `Get-FreePort -Start 8642 -End 8662 → int`. Throws "No free port between 8642 and 8662" if none is free.
  - `New-Token → string` (64 hex chars, `RNGCryptoServiceProvider`).
  - `Send-Json($ctx, $obj, [int]$status=200)`, `Read-JsonBody($ctx) → hashtable` (PS 5.1: `ConvertFrom-Json` then convert to hashtable).
  - `Start-MultilinkConsole -Root <folder> [-NoBrowser] [-Port <int>]`. Starts the listener and dispatches `/api/*` through a route table `@{ 'GET /api/state' = { param($ctx,$state) ... } }`. Serves `index.html` with `{{TOKEN}}` replaced. Uses a `BeginGetContext`/`AsyncWaitHandle.WaitOne(250)` loop so the thread is never blocked indefinitely. The loop ends when `$state.Stopping` is true. Writes `$state.Port` and the URL to `%TEMP%\multilink-console.url` for tests.
  - For this task, `GET /api/state` returns `{ ok: true }`. `POST /api/stop` sets `Stopping`.
- [ ] **Step 1: Write failing unit tests:**
  - `Test-RequestAllowed` cases:
    - remote `192.168.1.50` → 403;
    - `::1` and `127.0.0.1` allowed;
    - Host `evil.com:8642` → 403;
    - Origin `http://evil.com` → 403;
    - API with token `x` vs expected `y` → 403;
    - POST `text/plain` → 415;
    - GET `/` without a token → allowed.
  - `New-Token` length 64, matches `^[0-9a-f]+$`, two calls differ.
  - `Get-FreePort`: occupy 8642 with a `System.Net.Sockets.TcpListener` on loopback → returns 8643.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** `console/Http.ps1` and the skeleton of `console/Server.ps1`.
- [ ] **Step 4: Write `tests/integration.ps1`.** It starts `Start-MultilinkConsole -NoBrowser` in a background `powershell.exe` process, reads the URL file, then uses `curl.exe` to check:
  - `/api/state` without the token → 403;
  - with the token (read from the served HTML's meta tag) → 200 `{"ok":true}`;
  - Host header `evil.com` → 403;
  - `/api/stop` → the process exits within 5 s.

  Print `PASS`/`FAIL` per check; exit code 1 on any failure.
- [ ] **Step 5: Run** unit tests + `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/integration.ps1`. Expected: all PASS.
- [ ] **Step 6: Commit** `feat: localhost console server with token gate`.

---

### Task 3: Store: settings, live rates, series, mobile detection

**Files:**
- Create: `console/Store.ps1`
- Modify: `console/Server.ps1` (routes `GET /api/state`, `GET /api/series`, `POST /api/settings`)
- Test: `tests/Store.Tests.ps1`

**Interfaces:**
- Consumes: `Get-Paths` (Task 1), the route table (Task 2).
- Produces:
  - `New-ConsoleState → [hashtable]::Synchronized` with keys `Paths, Series (ArrayList), Rates, Separation, PublicIps, Latency, Mobile, Settings, Jobs, Downloads, Apps, Log, Stopping, IsAdmin, Port, Token`.
  - `Get-Settings([string]$Path) → hashtable` (defaults merged; corrupt file → defaults) / `Save-Settings($Path, $settings)`.
  - `Get-RateTable($prev, $curr, [double]$seconds) → @{ <alias> = @{rx; tx} }`. `$prev`/`$curr` map alias → `@{Rx=bytes;Tx=bytes}`; aliases missing from `$prev` give 0; negative deltas (counter reset) give 0; values are Mbps rounded to 0.1.
  - `Add-Sample($series, $sample, [int]$max=60)`.
  - `Find-MobileAlias($paths, $overrideAlias) → alias|$null`. The override wins if it is present; otherwise the first `Description` matching the regex.
  - `Start-Sampler($state)`. Runspace: every 1 s, `Get-NetAdapterStatistics` → rates → series; accumulates `Mobile.sessionBytes` (rx+tx delta on the mobile alias); re-runs `Get-Paths` every 10 s.
  - `Get-StateDto($state) → object` matching the `GET /api/state` contract.
- [ ] **Step 1: Write failing tests:**
  - `Get-RateTable` with `Ethernet` 0→18_875_000 rx bytes over 1 s → rx 151.0. A link present only in `$curr` → rx 0. A counter going down → 0.
  - `Add-Sample` keeps 60 when 61 are added, oldest removed.
  - `Find-MobileAlias`: paths `Ethernet`/"Realtek Gaming 2.5GbE" and `Ethernet 2`/"SAMSUNG Mobile USB Remote NDIS Network Device" → `Ethernet 2`; override `Ethernet` → `Ethernet`; override not present → auto.
  - `Get-Settings` on a missing file → capGB 10; on a file containing `{bad` → capGB 10; round-trip `capGB 5` → 5.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** and wire the routes. `POST /api/settings` validates `capGB` is a number ≥ 1 (else 400 "Cap must be at least 1 GB"), saves, and returns the state DTO.
- [ ] **Step 4: Run** unit tests. Extend `tests/integration.ps1`: `/api/series` after 3 s has ≥2 samples, and every sample has a key for each current path alias. Expected: PASS.
- [ ] **Step 5: Commit** `feat: live per-link rates and settings store`.

---

### Task 4: The page: live summary, graph, link cards

**Files:**
- Modify: `console/index.html` (replace the stub)

**Interfaces:**
- Consumes: `GET /api/state`, `GET /api/series` (contract above). All fetches send header `X-Multilink-Token` read from `<meta name="ml-token">`.
- Produces: JS helpers used by later tasks, `api(method, path, body) → Promise<json>` (throws `Error(json.error)` on non-2xx), `pollJob(jobId, onLine) → Promise<job>` (500 ms), `log(text, level)`.

- [ ] **Step 1: Port the preview.** Copy the preview HTML into `console/index.html`. Replace the Google Fonts link with the system font stacks. Delete all simulation code, the "Simulate: phone joins Wi-Fi" link and the "Preview" tag.
- [ ] **Step 2: Render from the API.** Build the header pill, summary strip, graph and link cards from `/api/state` + `/api/series`, polling each every 1 s.
  - Graph series are keyed by alias. Colours: the mobile alias uses the tether token, the other uses the wired token. If there are more than 2 links, the third and later use slot 3 (`#1baf7a` / dark `#199e70`) and so on from the dataviz palette.
  - Speed-up shows "Measure wired first" when `baseline` is null.
  - Link-card latency shows "Measuring…" when null, otherwise the values plus "measured N min ago".
  - The header label reads `localhost:<port> · local only`.
  - The mobile-data tile has a small "Mobile link" select (Auto + each alias) that posts `{mobileAlias}` to `/api/settings`. "Auto" sends `null`.
- [ ] **Step 3: Add the stopped notice.** After 3 consecutive failed polls, show a full-width notice "The console has stopped. Double-click multilink.bat to start it again." and stop polling.
- [ ] **Step 4: Verify.** Start the console with `-NoBrowser`, open the URL in a browser, and check by eye that the cards show both real adapters (`Ethernet`, `Ethernet 2`) and the graph moves when you run `curl.exe -o NUL https://speed.cloudflare.com/__down?bytes=100000000`. Check the theme in both OS light and dark mode. Stop the console and confirm the stopped notice appears.
- [ ] **Step 5: Commit** `feat: live console page with per-link graph`.

---

### Task 5: Jobs, Check, latency pass, separation watcher, range probe, baseline

**Files:**
- Create: `console/Jobs.ps1`, `console/Watch.ps1`
- Modify: `console/Server.ps1`, `console/index.html` (Run check button + output log, boost-lost banner, Re-check, range line under the URL, Re-measure link)
- Test: `tests/Watch.Tests.ps1`

**Interfaces:**
- Consumes: `Measure-PathLatency`, `Get-EgressVia`, `Get-Paths` (Task 1); state (Task 3).
- Produces:
  - `Start-ConsoleJob($state, [string]$kind, [scriptblock]$work) → jobId`. Runs `$work` in its own runspace with `param($state, $emit)`. `$emit.Invoke(text, level)` appends to `state.Jobs[id].log`. The job state becomes done or failed, and its result is the scriptblock's return value.
  - `Get-SeparationStatus([object[]]$results) → "ok"|"lost"|"unverified"|"single"|"unknown"`. Each result is `@{Alias; PublicIp|null}`. Zero results → unknown; one → single; any duplicate non-null IP → lost; else any null → unverified; else ok.
  - `ConvertFrom-RangeProbe([string]$headText, [int]$rangeStatus) → @{splits; sizeBytes; filename; reason}`. `$headText` is `curl -sSIL` output (use the **last** response block after redirects). Splits if `Accept-Ranges: bytes` or `$rangeStatus -eq 206`. Size comes from `Content-Length` (or the total in `Content-Range` when 206). Filename comes from `Content-Disposition` filename, else is left null (the server then uses the URL's last path segment, URL-decoded).
  - `Start-Watcher($state)`: an egress check for every path every 60 s, writing `PublicIps`, `Separation`, `checkedAt`.
  - `Invoke-Baseline($state, $emit)`: runs 4 parallel `curl.exe --interface <wired IP>` processes for 10 s against `https://speed.cloudflare.com/__down?bytes=500000000` and measures the wired adapter's rx delta.
  - Routes `POST /api/check`, `POST /api/recheck`, `POST /api/range`, `POST /api/baseline`.
  - A latency pass job starts automatically at console start.
  - The Check job's log lines reuse the old `-Action check` wording and levels (cyan section headers → `info`, green → `good`, yellow → `warn`).
- [ ] **Step 1: Verify the baseline endpoint first.** Run `curl.exe -s -o NUL -w "%{size_download} %{http_code}" --max-time 10 "https://speed.cloudflare.com/__down?bytes=500000000"`.
  - Expected: 200, and a large size_download that is still growing at the 10 s cut.
  - If it returns 4xx, or a size far below what 10 s at 150 Mbps would deliver (~180 MB), switch to looping `bytes=25000000` requests until 10 s pass.
  - Record which variant you picked in a code comment.
- [ ] **Step 2: Write failing tests:**
  - `Get-SeparationStatus`:
    - two distinct IPs → ok;
    - two equal → lost;
    - one IP + one null → unverified;
    - one result → single;
    - empty → unknown;
    - three results with two equal → lost.
  - `ConvertFrom-RangeProbe`:
    - a 302 block followed by a 200 block with `Accept-Ranges: bytes` and `Content-Length: 6114656256` → splits, size 6114656256;
    - a 200 without Accept-Ranges and rangeStatus 200 → not split, reason contains "does not accept range requests";
    - rangeStatus 206 with `Content-Range: bytes 0-0/1288490188` → splits, size 1288490188;
    - `Content-Disposition: attachment; filename="a b.iso"` → filename `a b.iso`.
  - `Start-ConsoleJob` with a work block that emits two lines and returns 42 → after polling, the state is done, the log has 2 entries and the result is 42.
- [ ] **Step 3: Run.** Expected: FAIL.
- [ ] **Step 4: Implement.** In the page:
  - Run check → `POST /api/check` → `pollJob` streams lines into the output log. Map levels to the console colour classes, and give `cmd` lines the dim style with a `> ` prefix.
  - When `separation.status == "lost"`, show the banner and turn the pill red. Unverified turns the pill amber.
  - The range line updates 600 ms after the last keystroke in the URL field.
- [ ] **Step 5: Run** unit tests + integration. Extend `tests/integration.ps1`: `POST /api/range` for `https://releases.ubuntu.com/24.04/ubuntu-24.04.3-desktop-amd64.iso` → `splits:true`. (If that exact file 404s, use any current ISO listed at `https://releases.ubuntu.com/24.04/`.) Expected: PASS.
- [ ] **Step 6: Manual check.** Click Run check and see real egress IPs for both links. Turn the phone's Wi-Fi ON with tethering still on, then click Re-check: the banner appears. Turn Wi-Fi OFF, Re-check: the banner clears.
- [ ] **Step 7: Commit** `feat: check, separation watcher, range probe, baseline`.

---

### Task 6: Downloads over aria2 RPC, with the data cap

**Files:**
- Create: `console/Downloads.ps1`, `console/Native.cs`
- Modify: `console/Server.ps1`, `console/index.html` (download panel: start, cancel, resume, progress bar split per link, finished list, cap input wired to `/api/settings`, cap banner with Raise cap)
- Test: `tests/Downloads.Tests.ps1`

**Interfaces:**
- Consumes: `Get-Aria` (exists in `multilink.ps1`), state, `Start-ConsoleJob`.
- Produces:
  - `Native.cs`, namespace `Multilink`:
    - `public static class JobObject { public static IntPtr CreateKillOnClose(); public static void Assign(IntPtr job, IntPtr processHandle); }`
    - `public static class ConsoleClose { public static void Register(Action onClose); }` (wraps `SetConsoleCtrlHandler`; the handler calls `onClose` and returns true).
  - `New-Aria2ArgList -Mode all|one -IPs string[] -Dir string -Port int -Secret string -ConsolePid int → string[]`. Each value is its own array element; the URL is **not** in the list (it is added via RPC).
  - `Invoke-Aria2Rpc -Port -Secret -Method -Params → object`. JSON-RPC 2.0 POST to `http://127.0.0.1:<port>/jsonrpc` using `Invoke-RestMethod`; params are prefixed with `"token:<secret>"`.
  - `Start-Download($state, $req) → id`. Validates the request (URL `^https?://` → else 400 "Enter a link that starts with http:// or https://"; dir creatable → else 400 "Can't save to <dir>"). If a download is active → 409 "A download is already running". If the cap is hit and the mode is all, run it wired-only; if it is one with the mobile link → 409 "Mobile data cap reached". Then: start aria2c, assign it to the Job Object, wait for RPC to be ready (≤5 s), call `aria2.addUri([url], {dir})`.
  - `Update-Downloads($state)`, called every 1 s from the sampler:
    - `tellStatus` → completedBytes, totalBytes, speed, filename;
    - on complete/error/removed → final state, `aria2.shutdown`, kill after 5 s;
    - per-link bytes accumulate from per-link rx while the download is active, minus that link's non-aria2 app traffic when `appMonitorMode` is etw; otherwise `perLinkBytes = $null`.
  - `Get-CapAction -CapHit bool -Mode all|one -Link alias -MobileAlias alias → "none"|"switch-to-wired"|"stop"`.
  - `Stop-Download($state, $id, [switch]$ByCap)`; `Restart-DownloadWired($state, $id)`. That one does `forceShutdown`, then starts again with `--interface=<wired IP>` into the same dir and filename (`out` option), with `--continue=true`.
  - Cap enforcement is in the sampler tick: `capHit = sessionGB >= capGB`. On the rising edge, apply `Get-CapAction` to the current download. Raising the cap above usage clears `capHit`.
  - Routes `POST /api/downloads`, `GET /api/downloads`, `POST /api/downloads/<id>/cancel`.
- [ ] **Step 1: Write failing tests:**
  - `New-Aria2ArgList -Mode all -IPs '192.168.1.24','192.168.42.129' ...` contains `--multiple-interface=192.168.1.24,192.168.42.129`, `-x16`, `--stop-with-process=<pid>` and `--rpc-listen-all=false`, and has no element starting with `http`.
  - `-Mode one -IPs '192.168.42.129'` contains `--interface=192.168.42.129` and no `--multiple-interface`.
  - A dir of `C:\Users\x\My "Downloads" & more` appears as exactly one element.
  - `Get-CapAction`:

    | CapHit | Mode | Link | MobileAlias | → |
    |---|---|---|---|---|
    | F | all | – | E2 | none |
    | T | all | – | E2 | switch-to-wired |
    | T | one | E2 | E2 | stop |
    | T | one | Ethernet | E2 | none |
    | T | all | – | $null | none |

  - `Add-Type` of `Native.cs` succeeds under 5.1, and `[Multilink.JobObject]::CreateKillOnClose()` returns a non-zero handle.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** unit tests. Extend the integration test:
  - start an `all` download of the Ubuntu ISO into `%TEMP%\ml-it`;
  - after 8 s, `completedBytes` > 0 and both aliases have rx > 5 Mbps in `/api/series`;
  - cancel → state cancelled, `aria2c` process gone within 6 s, and the `.aria2` file still present;
  - delete the folder.

  Expected: PASS.
- [ ] **Step 5: Manual check.**
  - Set the cap to 1 GB in the page, start an all-links download, and watch the cap trip: the log line appears, the 5G band drops, and the download continues on blue.
  - Repeat with One link: 5G → the download stops with "Mobile data cap reached".
  - Raise the cap and press Resume → it continues.
- [ ] **Step 6: Commit** `feat: aria2 RPC downloads with mobile data cap`.

---

### Task 7: Prefer / Undo / Reset in the console

**Files:**
- Create: `console/Network.ps1`
- Modify: `console/Server.ps1`, `console/index.html` (Fix game lag: button labelled `Prefer <suggestedGamingLink>` plus a small select to change the link; Undo; a new Reset section with Preview reset → Apply reset)
- Modify: `reset-network.ps1` (in `-Apply`, stop a stale `MultilinkNetMon` session with `logman stop MultilinkNetMon -ets`; add `%LOCALAPPDATA%\multilink\` and `%USERPROFILE%\Desktop\Multilink.lnk` to `-RemoveTools`; add `ml-it` to the temp-dir regex)
- Test: `tests/Network.Tests.ps1`

**Interfaces:**
- Consumes: `Set-PathMetrics`, `Reset-PathMetrics` (Task 1), `Start-ConsoleJob` (Task 5).
- Produces: `Invoke-PreferApi($state, $alias, [bool]$IsAdmin) → @{Status; Body}` and `Invoke-UndoApi($state, [bool]$IsAdmin)`. When not admin → 409 "Restart the console as administrator". An unknown alias → 400 "No link named <alias>". `POST /api/reset {apply}` runs `powershell.exe -NoProfile -ExecutionPolicy Bypass -File reset-network.ps1 [-Apply]` as a job and streams stdout lines (level `info`; lines containing "would" → `warn`).
- [ ] **Step 1: Write failing tests.**
  - `Invoke-PreferApi` with `IsAdmin:$false` → 409 with that exact message.
  - Alias `Nope` with `IsAdmin:$true` → 400.
  - (Mock `Set-PathMetrics` with Pester 3 `Mock` so the tests never change real metrics.)
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run tests.**
  - Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File reset-network.ps1` standalone: it still prints the report and changes nothing.
  - In the elevated console, click Prefer, then confirm `Get-NetIPInterface -AddressFamily IPv4` shows metric 10/60.
  - Click Undo, then confirm automatic metrics are back.
  - Click Preview reset: the log shows the report.
- [ ] **Step 5: Commit** `feat: prefer, undo and reset from the console`.

---

### Task 8: Per-app monitor

**Files:**
- Create: `console/NetMonitor.cs`, `console/Apps.ps1`
- Modify: `console/Server.ps1` (`GET /api/apps`, start/stop the monitor), `console/index.html` (apps table from the preview; header chip "Admin · exact bytes, TCP + UDP" or "Run as admin for live speeds per app")
- Test: `tests/Apps.Tests.ps1`

**Interfaces:**
- Produces:
  - `NetMonitor.cs`, namespace `Multilink`:
    - `public sealed class NetMonitor : IDisposable { public static void StopStale(); public void Start(); public NetRecord[] Drain(); public void Dispose(); }`.
    - `public struct NetRecord { public int Pid; public bool Send; public int Size; public string LocalIp; public string RemoteIp; public int RemotePort; public bool Udp; }`.
    - Implementation: real-time session `MultilinkNetMon` via `StartTrace` / `EnableTraceEx2` (keywords for TCP/UDP IP traffic) / `OpenTrace` with `PROCESS_TRACE_MODE_REAL_TIME | PROCESS_TRACE_MODE_EVENT_RECORD` / `ProcessTrace` on a background thread. Events go into a `ConcurrentQueue<NetRecord>`.
    - Event IDs: 10/11 TCPv4 send/recv, 26/27 TCPv6, 42/43 UDPv4, 58/59 UDPv6.
    - IPv4 payload starts `PID u32, size u32, daddr u32, saddr u32, dport u16, sport u16` (ports in network byte order). IPv6 has 16-byte addresses.
  - `Group-AppTraffic -Records NetRecord[] -Paths -Seconds -ProcessNames hashtable → rows` (the contract's `/api/apps` rows).
    - Local IP maps to an alias via each path's `IP` and `IPv6`; records whose local IP matches no path are dropped.
    - The protocol is `UDP`, `QUIC` (UDP and remote port 443) or `TCP`.
    - `conns` counts distinct local/remote endpoint pairs in the window.
    - Rows are sorted by downMbps, descending.
  - `Get-ConnectionRows -Paths → rows`, the no-admin fallback: `Get-NetTCPConnection -State Established` + `Get-NetUDPEndpoint` grouped by `OwningProcess` and `LocalAddress`, with `downMbps/upMbps/perLink` values `$null`.
  - `Test-IsGame([string]$exe) → bool` from a list in `Apps.ps1`: `VALORANT-Win64-Shipping.exe, cs2.exe, FortniteClient-Win64-Shipping.exe, r5apex.exe, LeagueofLegends.exe, RocketLeague.exe, Overwatch.exe, GTA5.exe, eldenring.exe, RainbowSix.exe, dota2.exe`. `laggy` = game and mobile share > 5 %.
  - `Start-AppMonitor($state)`: a runspace that drains every 1 s and keeps a 2 s window. When not admin, or if `Start()` throws, set `appMonitorMode = "connections"` and use the fallback every 2 s.
- [ ] **Step 1: Spike the event layout.** In an elevated `powershell.exe`, compile `NetMonitor.cs`, run it for 10 s while `curl.exe --interface <wired IP>` downloads, and print the first 20 records. **Confirm which address field holds the local IP for both send and receive** (expected: saddr = local). Fix the mapping before going on, and leave a comment stating what you observed.
- [ ] **Step 2: Write failing tests:**
  - `Group-AppTraffic` with synthetic records. PID 100 (`aria2c.exe`): recv 18,875,000 bytes on `192.168.1.24` and 31,500,000 on `192.168.42.129` over 1 s. PID 200 (`chrome.exe`): UDP recv to remote port 443, 400,000 bytes on `192.168.1.24`. A record whose local IP is `172.20.0.5` is dropped. Expected:
    - aria2c first, downMbps 403.0, perLink Ethernet 151.0 and Ethernet 2 252.0;
    - chrome protocol `QUIC`, downMbps 3.2;
    - two rows total.
  - `Test-IsGame 'cs2.exe'` → True; `'chrome.exe'` → False.
  - Laggy: a game row with 10 % on the mobile alias → laggy True; 0 % → False.
  - `Add-Type` of `NetMonitor.cs` compiles under 5.1 (no admin needed for compiling).
- [ ] **Step 3: Run.** Expected: FAIL.
- [ ] **Step 4: Implement.**
- [ ] **Step 5: Run** unit tests.
  - Manual, elevated: the apps table shows aria2c during a download, split across both links.
  - Manual, non-elevated: connection rows appear, Mbps shows "—", and the header says "Run as admin for live speeds per app".
  - Close the console, then `logman query -ets` doesn't list `MultilinkNetMon` after the next start sweep.
- [ ] **Step 6: Commit** `feat: per-app network monitor with link attribution`.

---

### Task 9: One-click launcher and lifecycle

**Files:**
- Modify: `multilink.bat`, `multilink.ps1` (entry point), `console/Server.ps1`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - `multilink.bat`: no arguments.
    1. Try `powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','\"%~dp0multilink.ps1\"'"`.
    2. If that exits non-zero (UAC declined), run `powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0multilink.ps1"` directly.
  - `multilink.ps1`, when executed: dot-source `console\*.ps1` → `Get-Aria` → first-run shortcut prompt → `Start-MultilinkConsole -Root $PSScriptRoot`.
    - The shortcut prompt: `Create a desktop shortcut? [Y/n]`, then `WScript.Shell` creates `Multilink.lnk` → `multilink.bat`; `shortcutAsked=true` is saved.
  - Startup sweep, before listening:
    - `[Multilink.NetMonitor]::StopStale()`;
    - kill `aria2c.exe` processes whose command line contains `--stop-with-process=` with a PID that no longer exists (via `Get-CimInstance Win32_Process`).
  - Browser opened with `explorer.exe "http://localhost:<port>/"` (de-elevated).
  - `[Multilink.ConsoleClose]::Register({ cleanup })`. Cleanup: set `Stopping`, `aria2.shutdown` all, dispose `NetMonitor`, close the Job Object handle. `POST /api/stop` runs the same cleanup.
  - The console window prints one line per API action (`HH:mm:ss  POST /api/check`).
  - Page: a Stop console button in the header → `POST /api/stop`.
- [ ] **Step 1: Write the test.** Extend `tests/integration.ps1`:
  - after the console starts, `explorer.exe` is not called when `-NoBrowser`;
  - `/api/stop` → the process exits, no `aria2c` started by it is left, and `logman query MultilinkNetMon -ets` reports not found.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Manual check.**
  1. Double-click `multilink.bat`, accept UAC: the browser opens on the console as a normal (non-admin) Edge window, and the shortcut prompt appears once.
  2. Double-click again and decline UAC: the console opens in non-admin mode.
  3. Start a download, then close the PowerShell window with X: `aria2c` is gone in Task Manager within 5 s.
- [ ] **Step 4: Commit** `feat: one-click launcher with clean shutdown`.

---

### Task 10: Delete superseded scripts, update docs

**Files:**
- Delete: `fastdl.ps1`
- Modify: `multilink.ps1` (remove `Show-Menu`, `Invoke-Check`, `Invoke-Get`, `Invoke-Only`, `Invoke-Optimise`, `Invoke-Undo`, `Invoke-Elevated`, the `-Action` param and switch, and the `Say/Info/Warn/Fail/Good/Dim` helpers if they are no longer used), `README.md`, `multi-link-downloads.md` (§11–12 rewritten for the console; the history sections kept), `reset-network.ps1` (header text: drop "menu option 4" wording → "the console's Prefer button")
- Create: `multilink.desktop`, `CLAUDE.md`

- [ ] **Step 1: Delete and strip.** Delete `fastdl.ps1` (`git rm`) and remove the CLI and menu code from `multilink.ps1`.
- [ ] **Step 2: Confirm nothing references the removed code.** Run `git grep -n -E "fastdl|Show-Menu|-Action |Invoke-(Check|Get|Only|Optimise|Undo)"`. Expected: matches only in `docs/superpowers/` and the history narrative in `multi-link-downloads.md`.
- [ ] **Step 3: Rewrite the README.** "Just want it to work?" becomes: plug in the phone, Wi-Fi off, double-click `multilink.bat`, accept the prompt, and the console opens. Update the file table to match §6.1a. Explain admin vs non-admin and the cap, alert and reset buttons. Remove the menu section. Keep the gaming, data warning, limits and Linux sections; add the `multilink.desktop` install line (`cp multilink.desktop ~/.local/share/applications/` after editing its `Exec=` path).
- [ ] **Step 4: Create the Linux launcher.** `multilink.desktop`: `[Desktop Entry]`, `Type=Application`, `Name=Multilink`, `Terminal=true`, `Exec=bash -c 'cd "$(dirname "%k")" && ./multilink.sh'`.
- [ ] **Step 5: Create the project `CLAUDE.md`.** It covers:
  - layout (the file table above);
  - runtime rules (PS 5.1, C# 5, no installs);
  - the test command and `tests/integration.ps1`;
  - "the console is the only entry point; `reset-network.ps1` must keep working standalone".
- [ ] **Step 6: Verify.** Run all unit tests + integration; run `reset-network.ps1` standalone; launch via `multilink.bat` once. Expected: all PASS, and the console works end to end.
- [ ] **Step 7: Commit** `chore: remove superseded scripts and document the console`.
