# Multilink — project notes

Speeds up single large downloads on Windows by spreading HTTP range requests
(aria2) over every interface with its own default gateway — typically wired
Ethernet + a USB-tethered phone. The user-facing app is a local browser console.

## Layout

| Path | Role |
|---|---|
| `multilink.bat` | One-click launcher: asks for admin (UAC), falls back to non-admin. The only entry point. |
| `multilink.ps1` | Engine data functions (paths, latency, metrics, aria2 locate). Executed → starts the console; dot-sourced → defines functions only. |
| `console/Server.ps1` | `Start-MultilinkConsole`: HttpListener on `http://localhost:<port>/` (8642–8662), routes, lifecycle. Facade over the engine. |
| `console/Http.ps1` | Request gate (loopback + Host + Origin + token + JSON-only POST), JSON helpers, `Get-FreePort`. |
| `console/Store.ps1` | Synchronized state, settings (`%LOCALAPPDATA%\multilink\settings.json`), sampler runspace, `Start-BackgroundRunspace`, state DTO. |
| `console/Jobs.ps1` | Long actions as runspace jobs (check, latency pass); page polls `/api/jobs/<id>`. |
| `console/Watch.ps1` | Separation watcher (public IP per link, 60 s), range probe, wired baseline. |
| `console/Downloads.ps1` | One aria2c per download over JSON-RPC, mobile data cap. |
| `console/Network.ps1` | Prefer / Undo metrics, Reset (runs `reset-network.ps1`). |
| `console/Apps.ps1` + `NetMonitor.cs` | Per-app traffic: ETW Kernel-Network when admin, TCP/UDP tables otherwise. |
| `console/Native.cs` | `IfStats`/`IfPoller` (GetIfEntry2 counters), Job Object, console-close flag, argv split. |
| `console/index.html` | The page. Single file, no external requests, polls the API. |
| `reset-network.ps1` | Reverts everything; must keep working standalone (escape hatch when the console won't start). |
| `multilink.sh` + `multilink.desktop` | Linux terminal tool; the console is Windows-only. |
| `docs/superpowers/` | Design spec and implementation plan for the console. |

## Runtime rules

- Target **Windows PowerShell 5.1** (`powershell.exe`), not pwsh 7 — no `??`, `?.`, ternaries, `-Parallel`.
- C# compiled with `Add-Type` must be **C# 5** (no `$""`, `?.`, `nameof`, expression bodies, `out var`).
- No new dependencies: aria2 (auto-installed via winget) and curl.exe only. The page loads nothing external.
- Background work runs in runspaces created by `Start-BackgroundRunspace`; scriptblocks cross runspaces as text, and every `console/*.ps1` except `Server.ps1` is dot-sourced into each runspace.
- Never block the request loop: slow handlers use `Start-DeferredResponse` or a job.
- `Get-NetAdapterStatistics` is far too slow here (seconds per call; the RNDIS tether driver ~1.8 s/query) — use `Multilink.IfPoller`.
- aria2 `--multiple-interface` uses the **first** IP for the initial request: keep wired IPs first.

## Tests

```
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Invoke-Pester -Path tests -EnableExit"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests/integration.ps1          # real HTTP, real download
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests/integration.ps1 -Quick   # no internet-heavy checks
```

Pester is the in-box 3.4.0: `Should Be`, `Should Throw`, `Should BeNullOrEmpty` (no `-Be`).
Integration runs a non-elevated console, so admin-only paths (ETW monitor, Prefer/Undo/Apply reset) need a manual elevated run.
