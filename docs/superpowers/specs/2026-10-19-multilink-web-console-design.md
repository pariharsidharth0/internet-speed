# Multilink Web Console — Design

Date: 2026-10-19
Status: draft for approval (builder check done)
Visual reference: the clickable preview at
https://claude.ai/code/artifact/8ff88441-ce7e-4864-87cb-d386d0e83860
(simulated data; its layout, copy and behaviour are the target for the real UI).

---

## 1. Intent

Multilink already works: it makes a single download faster by spreading HTTP
range requests over wired Ethernet and a USB-tethered 5G phone (measured
151 → 403 Mbps on this PC). Using it today means a text menu, PowerShell
flags, and remembering to re-run checks.

This project gives it a **one-click, live browser console**:

- double-click one file → a local page opens with clickable buttons for every
  action the scripts can do;
- a **live graph** shows how much each link is carrying, second by second;
- a **per-app monitor** shows which programs are using the network and
  **which link** each one is on;
- the console **watches for the two failures that bite in practice**:
  burning through mobile data (24.5 GB in one past session) and the phone
  silently rejoining Wi-Fi (boost gone, nobody notices).

The user is a single person on their own Windows 11 PC, mostly downloading
large files and gaming. Gaming matters: the 5G link has ~523 ms ping and
~91 ms jitter, so the console must make it obvious when a game is on the bad link.

## 2. Goals

1. **One click to start.** Double-click `multilink.bat` → admin prompt (once)
   → browser opens on the console. No PowerShell knowledge needed.
2. **Every existing action as a button:** Check connections, Download over all
   links, Download over one link, Prefer low-latency link, Undo, Reset network
   (preview first, then Apply).
3. **Live throughput graph**, stacked per link, last 60 s, 1 s resolution,
   hover tooltip. Combined Mbps, per-link Mbps, speed-up vs a measured wired baseline.
4. **Per-app monitor:** app name, exe, protocol, down/up rate, connection
   count, and the Ethernet/5G split per app. Flag a game that is partly on 5G.
5. **Mobile data cap:** user sets N GB; when the phone link has carried N GB
   this session, multilink downloads switch to wired-only automatically
   without losing progress.
6. **Boost-lost alert:** background re-check of each link's public IP every
   60 s; a red banner if they become identical.
7. **Range pre-check:** before a download starts, tell the user whether the
   server will split across links, and the file size.
8. **Measured speed-up:** a "Re-measure wired (10 s)" action; the speed-up
   figure uses that number, not a hard-coded 151.
9. **Locked-down local server:** loopback only, per-session token, so no
   website open in the browser can drive it.
10. **One-click for the rest of the folder:** desktop shortcut on first run;
    Linux gets a `.desktop` launcher.
11. **No superseded scripts left behind** (user decision): once the console
    works, everything it replaces is deleted — see §6.1a.

## 3. Non-goals

- **Per-app routing** ("force Steam onto 5G"). Windows can't do it without
  installing a WFP/NDIS driver. The monitor shows which link an app uses; it
  does not move apps.
- Remote access from other devices, phones, or the LAN.
- A web console on Linux (the per-app monitor is Windows-only API). Linux
  keeps `multilink.sh` plus a launcher.
- Download history that persists across restarts, download queues/scheduling.
- Live ping graphs (considered and deferred by the user).
- An installer, a tray icon, auto-start at boot.

## 4. Anti-goals (would make this a failure even if it "works")

- Leaving permanent network changes beyond what exists today (interface
  metrics via the existing optimise/undo). Everything must still be reverted by
  `reset-network.ps1`.
- Listening on anything other than loopback, or any API call succeeding
  without the session token.
- Requiring installs beyond aria2 (already auto-installed via winget). No
  Node, Python, .NET SDK, or third-party PowerShell modules.
- Breaking `multilink.sh` (Linux) or the standalone use of `reset-network.ps1`
  (the escape hatch when the console itself won't start).
- Deleting a superseded script before its replacement in the console works
  (deletion is the last build step).
- Showing made-up numbers. If a figure can't be measured (no admin, no
  baseline yet), the UI says so instead of estimating.

## 5. Constraints

- **Windows PowerShell 5.1** (built into Windows 11) is the runtime. Scripts
  must not require PowerShell 7. C# compiled via `Add-Type` must be
  **C# 5 compatible** (the 5.1 compiler) — no `$"..."`, `?.`, expression-bodied
  members, etc.
- No external network calls from the page itself; the page talks only to the
  local server. Fonts are bundled or fall back to system fonts (the console
  must work offline-from-CDN; use system font stacks in the shipped page —
  `Segoe UI` / `Cascadia Mono` / `Consolas` — rather than Google Fonts).
- aria2 and curl.exe are the only external tools (both already used).
- Keep the flat folder layout the README promises ("keep the files together"),
  with the new web pieces in one subfolder.

## 6. Architecture

Pattern: **thin API layer (Facade) over the existing engine**, with a
**producer/consumer** shared-state model for the live data.

```
multilink.bat ──elevate──► multilink.ps1  (starts the console)
                                   │ dot-sources nothing; it IS the engine
                                   ▼
                           console/server.ps1  (HttpListener on localhost)
                           ├─ request loop (main thread): routes /api/*, serves index.html
                           ├─ sampler runspace: adapter byte counters every 1 s → shared state
                           ├─ watcher runspace: egress IP re-check every 60 s, cap enforcement
                           ├─ app-monitor runspace: NetMonitor (ETW) or TCP/UDP-table fallback
                           └─ job runspaces: check, baseline, reset (long-running actions)
                                   │
                                   ├─► aria2c (one process per download, RPC on its own port)
                                   └─► curl.exe (egress IP, range check, baseline)
```

Shared state is a `[hashtable]::Synchronized(@{})` read by request handlers
and written by runspaces. The request loop never blocks on a long action: it
starts a job and returns a job id; the page polls.

### 6.1 Files

| File | Change |
|---|---|
| `multilink.bat` | Elevate (UAC) and run `multilink.ps1`, which starts the console. If UAC is declined, run it non-elevated. No other modes. |
| `multilink.ps1` | Becomes **the engine + console entry point**. Keep the discovery/egress/latency/aria2/metric logic, rewritten as **data functions** returning objects (no `Write-Host`). Remove the text menu (`Show-Menu`), the `-Action` switch and all CLI print paths. Running the script starts the console; dot-sourcing it (`$MyInvocation.InvocationName -eq '.'`) only defines the functions, for `server.ps1` and tests. |
| `console/server.ps1` | New. HttpListener, routing, token check, runspaces, aria2 process management. Dot-sources `multilink.ps1` to reuse its data functions. |
| `console/index.html` | New. The UI from the preview with the simulation removed and `fetch` calls to `/api/*`. Single file, inline CSS/JS, no CDN. |
| `console/NetMonitor.cs` | New. ETW per-process network accounting, compiled at runtime with `Add-Type`. |
| `fastdl.ps1` | **Deleted** (superseded by the console's download). |
| `reset-network.ps1` | Add `%LOCALAPPDATA%\multilink\` (settings) to what `-RemoveTools` deletes; add stale ETW session `MultilinkNetMon` to what `-Apply` stops; add the desktop shortcut to what `-RemoveTools` deletes. Output text otherwise unchanged. |
| `multilink.desktop` | New. Linux app-menu launcher that opens a terminal running `multilink.sh`. |
| `README.md`, `multi-link-downloads.md` | Update "Just want it to work?" to the console flow; document the console, cap, alerts, admin/no-admin difference. |
| `CLAUDE.md` | New project CLAUDE.md describing layout, runtime constraints (PS 5.1, C# 5), and how to test. |

### 6.1a What gets deleted, and what deliberately stays

Deleted in the final build step, after the console is verified working:
- `fastdl.ps1` — an older duplicate of "download over all links".
- The text menu and every CLI `-Action` print path in `multilink.ps1`;
  `multilink.bat menu`.
- Any README / guide sections that teach the menu, `-Action` flags or `fastdl.ps1`
  (rewritten to the console flow, not just cut).

Stays, and why:
- `multilink.ps1` (engine), `multilink.bat` (launcher), `console/*` (new).
- `reset-network.ps1` — the console's Reset button runs it, and it must still
  run standalone if the console won't start.
- `multilink.sh` — the console is Windows-only; this is the only Linux path.
- `multi-link-downloads.md` — the explanation document, updated not deleted.
- `internet speed.zip` — untracked, git-ignored archive; left for the user to
  decide (deleting it is not recoverable through git).

### 6.2 Launch sequence

1. `multilink.bat` → `powershell -NoProfile -ExecutionPolicy Bypass -Command Start-Process powershell -Verb RunAs ...`.
   If elevation fails/declined → same command without `-Verb RunAs`.
2. `multilink.ps1` (console start):
   - `Get-Aria` (auto-installs aria2 as today).
   - Generate a 32-byte random token (`RNGCryptoServiceProvider`), hex.
   - Pick port 8642; if taken, the next free port up to 8662.
   - Start HttpListener with prefix `http://localhost:<port>/`.
   - Start runspaces. Open the browser **de-elevated** via `explorer.exe "http://localhost:<port>/"`, so an elevated console never starts the browser as administrator.
   - Run one quick latency pass per link (the latency part of Check) in the background so the link cards have data from the start.
   - First run only (no settings file): ask in the console window "Create a
     desktop shortcut? [Y/n]" and create `Multilink.lnk` pointing at
     `multilink.bat` via `WScript.Shell`.
3. The PowerShell window stays open, minimised-friendly, printing one line per
   API action. Cleanup is **layered**, because closing the window with X kills
   powershell.exe without running PowerShell exit handlers, and ETW sessions are
   kernel-owned and outlive the process:
   - the request loop uses `BeginGetContext` (non-blocking) so a
     `SetConsoleCtrlHandler` (P/Invoke) close handler can run cleanup in the
     few seconds Windows allows;
   - every aria2c is started with `--stop-with-process=<console PID>` **and**
     assigned to a Windows Job Object with `KILL_ON_JOB_CLOSE`, so they die with
     the console no matter how it ends;
   - at startup, stop any stale `MultilinkNetMon` ETW session and kill orphan
     aria2c processes whose command line carries the multilink RPC marker;
   - **Stop console** (button) does the full orderly shutdown.

### 6.3 Security

- Listener prefix is `http://localhost:<port>/`. **This alone is not loopback-only:**
  http.sys accepts the connection on every interface and only filters by Host
  header, which a LAN client can forge. So every request whose
  `Request.RemoteEndPoint.Address` is not loopback (`IPAddress.IsLoopback`) is
  dropped with 403 before any other processing.
- Every `/api/*` request must carry header `X-Multilink-Token: <token>`;
  otherwise 403. The token is written into `index.html` when it is served
  (a `<meta name="ml-token">` substituted server-side).
- Reject any request whose `Host` header isn't exactly `localhost:<port>`
  (blocks DNS rebinding). The UI label reads `localhost:<port> · local only`.
- Reject any request with an `Origin` header that isn't `http://localhost:<port>`.
- `/api/*` accepts only `GET` for reads and `POST` with
  `Content-Type: application/json` for actions (blocks simple-form CSRF).
- Download URLs must be `http`/`https`; output dir must be an existing or
  creatable local path. Values are passed to aria2 as separate argv entries,
  never through a shell string.
- aria2 RPC listens on loopback only (`--rpc-listen-all=false`) with a random
  `--rpc-secret`.

### 6.4 API

All responses JSON. "Job" endpoints return `{ jobId }`; poll `GET /api/jobs/<id>`
→ `{ state: running|done|failed, log: [...lines], result }`.

| Method & path | Purpose |
|---|---|
| `GET /api/state` | Paths (alias, local IP, gateway, metric, auto), per-link rx/tx Mbps (last sample), separation status + seconds since last check, public IP per link, mobile GB this session, cap, capHit, baseline Mbps + timestamp, preferred alias, isAdmin, appMonitorMode (`etw`/`connections`), and per link the **last measured latency** `{avgMs, maxMs, jitterMs, lossPct, measuredAt}` (from the startup latency pass or the last Check), plus `suggestedGamingLink` = lowest avg+jitter. |
| `GET /api/series` | Last 60 samples `{t, links:{alias:{rx,tx}}}`. |
| `GET /api/apps` | Rows `{exe, name, pid[], proto[], downMbps, upMbps, conns, perLink:{alias:Mbps}}`. In `connections` mode, Mbps fields are `null`. |
| `POST /api/check` | Job. Full check (paths, egress IPs, default route, background traffic, latency). Log lines use the same wording the old `-Action check` printed. Result structured. |
| `POST /api/range` | `{url}` → `{splits: bool, sizeBytes, filename, reason}`. Uses `curl.exe -sS -I` then, if no `Accept-Ranges`, a `Range: bytes=0-0` GET expecting 206. 8 s timeout. |
| `POST /api/downloads` | `{url, mode: all|one, link?, dir}` → `{id}`. **One active download at a time**; a second request while one is active gets 409 "A download is already running". Re-posting the same url+dir after a cancel resumes it (aria2 `--continue`). |
| `GET /api/downloads` | List: id, filename, dir, totalBytes, completedBytes, speed, perLink bytes, mode, state (active/complete/error/cancelled), switchedByCap. The current download plus the finished ones from this session. |
| `POST /api/downloads/<id>/cancel` | Stops it; partial file + `.aria2` control file kept. The UI then shows **Resume**, which re-posts the same url/dir/mode. |
| `POST /api/prefer` | `{alias}` (UI defaults to `suggestedGamingLink`; a small dropdown lets the user pick another) → sets metrics as `Invoke-Optimise` does (10 / 60). Requires admin; if not admin, 409 with message "Restart the console as administrator". |
| `POST /api/undo` | Restores automatic metrics. Same admin rule. |
| `POST /api/baseline` | Job. 10 s wired-only throughput measurement (see 6.8). |
| `POST /api/settings` | `{capGB?, mobileAlias?}`. |
| `POST /api/reset` | `{apply: bool}` → Job running `reset-network.ps1` (with `-Apply` if true) as a child process, streaming its stdout lines into the job log. |
| `POST /api/stop` | Shut the console down cleanly. |

### 6.5 Live throughput (sampler)

- Every 1 s: `Get-NetAdapterStatistics` for the current path aliases; Mbps =
  Δbytes × 8 / Δt / 1e6. Keep a 60-entry ring buffer.
- Paths are re-discovered every 10 s via `Get-Paths` so plugging/unplugging the
  phone shows up without a restart.
- **Mobile link identification:** the adapter whose `InterfaceDescription`
  matches `Remote NDIS|RNDIS|Mobile Broadband|Cellular` is the mobile link by
  default; the user can override in settings. "Mobile GB this session" =
  Δ(ReceivedBytes + SentBytes) on that adapter since console start.

### 6.6 Downloads (aria2)

- **One aria2c process per download**, each started with `--enable-rpc
  --rpc-listen-port=<free port> --rpc-secret=<random> --rpc-listen-all=false`
  plus today's flags (`-x16 -s16 -k1M --continue=true --file-allocation=none
  --async-dns=false --max-tries=5 --retry-wait=2`) and either
  `--multiple-interface=<all IPs>` or `--interface=<one IP>`. The URI is
  added via RPC `aria2.addUri`. Reason: `interface`/`multiple-interface` are
  process-level, so a per-process model is the simplest way to support mixed
  modes and the cap switch.
- Progress: poll `aria2.tellStatus` (total/completed/downloadSpeed) every 1 s.
- **Per-link share of a download:** aria2 doesn't report bytes per interface.
  Estimate it from the adapter counters: since only one download runs at a time,
  the per-link split is the per-link Δbytes minus that link's non-aria2 traffic
  (from the app monitor in ETW mode). In `connections` mode, show the split as
  "unavailable". *(Builder may choose a better attribution if one exists; it
  must not be fabricated.)*
- An RPC-enabled aria2c does **not** exit when its download finishes. When
  `tellStatus` reports `complete`/`error`/`removed`, the server records the
  final state and calls `aria2.shutdown` (then kills the process after 5 s if
  it is still alive).

### 6.7 Mobile data cap (watcher)

- Default cap 10 GB, persisted in settings. Scope: this console session.
- When mobile GB ≥ cap:
  - an active **all-links** download is stopped (RPC `aria2.forceShutdown`)
    and restarted with `--interface=<wired IP> --continue=true` into the same
    dir/filename, so pieces already on disk are kept;
  - an active **5G-only** download (the user chose it, typically to keep the
    cable free for a game) is **paused, not moved**: stopped with progress kept,
    state `cancelled` + `stoppedByCap`, so the game is never disturbed. *(User
    decision: the cap is a hard limit and wins over an explicit 5G choice.)*
  - new downloads requested with `mode: all` run wired-only; new **5G-only**
    requests are refused with 409 "Mobile data cap reached";
  - the UI shows "cap reached · downloads now wired-only" and a banner with a
    **Raise cap** control; raising the cap lets the paused 5G download be resumed;
  - a log line is emitted, matching the preview's wording.
- The cap only governs multilink downloads; it cannot stop other apps, and
  the UI says so in the cap tooltip.
- Raising the cap above current usage clears `capHit`; new downloads may use
  both links again (already-switched downloads stay wired).

### 6.8 Boost-lost alert and baseline

- Watcher re-runs `Get-EgressVia` for each path every 60 s (and immediately on
  "Re-check now"). Identical IPs across ≥2 paths → `separation = lost` → red
  banner + red pill. Any path with no answer → `separation = unverified`
  (amber pill, no banner).
- **Baseline:** for 10 s, `curl.exe --interface <wired IP>` downloads from
  `https://speed.cloudflare.com/__down?bytes=500000000` with 4 parallel
  connections (4 curl processes), measuring wired adapter Δbytes. *Verify early in the build* that this endpoint serves the requested size; if it caps or rejects it, use several smaller requests in a loop, or a known large range-capable file (e.g. an Ubuntu ISO mirror), aborting after 10 s. Result
  (Mbps, timestamp) saved to settings. If no baseline exists, the speed-up
  tile shows "Measure wired first" instead of a number.

### 6.9 Per-app monitor

**Admin (`etw` mode)** — `NetMonitor.cs`:
- Real-time ETW session named `MultilinkNetMon` on provider
  `Microsoft-Windows-Kernel-Network` (`{7DD42A49-5329-4832-8DFD-43D979153A88}`),
  via P/Invoke (`StartTrace`, `EnableTraceEx2`, `OpenTrace`, `ProcessTrace`,
  `ControlTrace`) on a background thread.
- Consume TCP/UDP send/receive events for IPv4 and IPv6; read `PID`, `size`,
  `saddr`/`daddr`. Local address → link via the current path list; anything else
  (loopback, Hyper-V) is ignored.
- Aggregate per PID per link per second; expose `GetSnapshot()` returning the
  last second's rows.
- On start, stop any stale `MultilinkNetMon` session first. On stop, stop the session.
- PID → name via `Get-Process` (cached; exe name + `FileDescription` for the
  friendly name, e.g. `chrome.exe` → "Google Chrome").
- Protocol label: TCP, UDP; UDP to port 443 is labelled QUIC.
- `conns` = distinct (local endpoint, remote endpoint) pairs seen in the last 5 s.

**Not admin (`connections` mode)**: `Get-NetTCPConnection -State Established`
plus `Get-NetUDPEndpoint`, grouped by `OwningProcess` and `LocalAddress` →
which apps hold connections on which link, no rates. The panel header says
"Run as admin for live speeds per app".

**Game flag:** an app is flagged "laggy link" when it is a known game
(exe matches a small built-in list, plus any process with UDP traffic and a
window title, at builder's discretion) and >5 % of its traffic is on the
mobile link.

### 6.10 UI

Follow the preview: header with separation pill, local-only label; summary
strip (combined Mbps, speed-up, ordinary-traffic route, mobile GB + cap);
live stacked graph; two link cards; apps table; output log; actions rail
(Check, Download with range line and All/One toggle, Fix game lag + Undo).
Additions vs. the preview:
- **Reset network** section at the bottom of the actions rail: "Preview reset"
  button → shows the report in the log → "Apply reset" button appears.
- **Stop console** button in the header.
- When the server stops responding: a full-width notice "The console has
  stopped. Double-click multilink.bat to start it again."
- Non-admin: admin-only buttons stay visible but show "needs admin" and the
  API's 409 message on click.
- The preview's "Simulate: phone joins Wi-Fi" link and "Preview" tag are removed.
- Link cards show the last measured ping/jitter/loss with "measured N min ago";
  before any measurement, "Measuring…".
- The download panel holds one download; finished ones from this session are
  listed compactly below it (filename, size, avg speed, GB over 5G).
- Polling: `/api/state` + `/api/series` + `/api/downloads` every 1 s;
  `/api/apps` every 2 s; job logs every 500 ms while a job runs.
- Fonts: system stacks (see §5). Light/dark follows the OS.

### 6.11 Linux

`multilink.desktop` (Type=Application, Terminal=true, Exec runs
`multilink.sh` from its folder). README explains copying it to
`~/.local/share/applications/`. `multilink.sh` is otherwise unchanged.

## 7. Testing

- **Unit (Pester 3.4, ships with Windows PowerShell 5.1):** pure functions —
  egress duplicate/unverified logic, range-response parsing, Mbps-from-counters
  math, token/Host/Origin validation, cap decision logic, settings load/save,
  app aggregation from synthetic ETW records.
- **Integration (scripted, on this PC):** start console non-elevated; hit each
  endpoint with and without token; confirm 403s; run a small range-capable
  download in both modes; confirm `reset-network.ps1` still runs standalone; confirm `multilink.ps1` dot-sourced defines functions without starting anything.
- **Manual checklist** (in the plan): admin vs non-admin launch, phone
  unplugged mid-session, phone on Wi-Fi (banner), cap trip with a low cap
  (e.g. 1 GB), reset preview/apply, console stop kills aria2 and ETW session.

## 8. Decisions made, and by whom

User decided:
- Real, working browser console (not a static command builder).
- Live network graph; per-app monitor with link attribution.
- The cap is a hard limit: it pauses an explicit 5G-only download rather than moving or ignoring it.
- Must-haves: data-cap auto-switch, boost-lost alert, range pre-check,
  locked-down server; plus measured speed-up.
- One-click start for everything; delete every script and mode the console supersedes (`fastdl.ps1`, the text menu, CLI `-Action` modes).
- Ping graph and download queue/history: not now.

My calls (open to change):
- ETW for per-app accuracy (covers UDP games/QUIC), with a no-admin fallback.
- Elevate once at launch rather than per action.
- PowerShell `HttpListener` + runspaces; no new runtimes.
- One aria2 process per download.
- System fonts in the shipped page (offline-safe), not the preview's web fonts.
- Mobile link auto-detected by adapter description, overridable.
- Default cap 10 GB, session-scoped.
- Port 8642 with fallback range.
- One active download at a time (consistent with deferring queues).
- Resume = re-post the same download after a cancel; no separate pause.
- Link-card latency comes from a startup latency pass and the last Check;
  "Prefer" defaults to the lowest avg+jitter link with an override.
- `reset-network.ps1` and `multilink.sh` are kept (escape hatch / Linux), despite the "delete superseded" rule.

## 9. Left to the builder

- Internal module structure of `server.ps1` and the exact JSON field names
  (as long as the UI and API agree).
- The known-games list and window-title heuristic.
- Exact runspace count/pooling.
- Whether the per-link download split can be attributed more precisely than
  §6.6 describes.
- How the first-run shortcut prompt is presented (console prompt is fine).
