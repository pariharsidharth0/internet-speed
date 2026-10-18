# Combining Two Internet Connections on Windows for Faster Downloads

A full writeup of the investigation done on `KHTR9K` (Windows 11 Pro, build 26200)
on 18 August 2026 — the reasoning, the commands, the wrong turns, and how to
replicate it on another machine.

---

## 1. The goal, and the crucial distinction

The starting question was "how do I do link aggregation / network bonding with my
two Ethernet ports." Partway through, the real goal turned out to be different:
**combine a wired ISP connection with a phone's 5G tether so downloads go faster.**

Those are two completely different problems, and conflating them wastes a lot of
time. Get this straight first:

| | Link aggregation (LACP / 802.3ad) | Multi-WAN aggregation |
|---|---|---|
| What's combined | Two NICs into **one switch**, one network | Two **separate internet connections** |
| Purpose | Aggregate throughput + redundancy on a LAN | More total internet bandwidth |
| Single transfer faster? | **No** — flows are hashed to one link | Only with the right technique (see §3) |
| Needs switch config | Yes (channel-group / LAG) | No |
| Windows support | Server only | N/A |

If your two links go to *different ISPs*, LACP is simply the wrong tool. It cannot
work, because LACP requires both ends of the bundle to be the same switch.

---

## 2. Why Windows NIC teaming is a dead end on client editions

Windows has a native teaming feature called **LBFO** (Load Balancing and Failover).
The cmdlets ship with Windows 11, which makes it look available. It isn't.

```powershell
New-NetLbfoTeam -Name "Team1" -TeamMembers "Ethernet","Ethernet 2" `
  -TeamingMode LACP -LoadBalancingAlgorithm Dynamic
```

Run **without** administrator rights, you get a misleading error:

```
New-NetLbfoTeam : Access is denied.
    + FullyQualifiedErrorId : Windows System Error -2147024891,New-NetLbfoTeam
```

That `-2147024891` is `0x80070005`. It looks like a permissions problem, and it
partly is — but fixing elevation doesn't help. Run it **elevated** and you get the
honest error:

```
New-NetLbfoTeam : The LBFO feature is not currently enabled, or LBFO is not
supported on this SKU.
    + FullyQualifiedErrorId : MI RESULT 1,New-NetLbfoTeam
```

**Conclusion: LBFO is a Windows Server feature.** The "not currently enabled" half
of that message refers to the Server optional feature; on a client SKU there is
nothing to turn on. Don't go looking for a registry hack — verify your SKU and move on:

```powershell
# ProductType 1 = Workstation (client), 2 = Domain Controller, 3 = Server
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, ProductType
```

Third-party driver teaming (Intel PROSet ANS, Broadcom) historically filled this
gap, but Intel has wound ANS down on modern Windows 10/11 drivers, and consumer
Realtek parts don't ship a teaming stack at all. Treat vendor teaming as unlikely
to be available.

---

## 3. The key insight: a *file* is not a *stream*

This is the concept that makes the whole thing work, and it's worth understanding
properly.

**A single TCP connection cannot be split across two links.** A TCP connection
binds to one source address when it opens and stays there for its entire life. The
packets have to come back to that address. So there is no way, locally, to make one
connection use two ISPs.

To speed up a single *stream* you need a **middleman server**: your PC sprays
packets across both links to a server, which reassembles them and fetches the
content on your behalf. That's what Speedify and OpenMPTCProuter do. It always
costs money — either a subscription or a VPS.

**But a large file download doesn't have to be one connection.** HTTP supports
**range requests** (`Range: bytes=0-1048575`). A client can open many independent
connections, each asking for a different slice of the same file, and stitch the
slices together on disk. Each connection is independent, so each can be bound to a
*different network interface*.

```
                    ┌── conn 1..8  ── wired ISP   ──┐
file on CDN ────────┤                               ├──► reassembled on your disk
                    └── conn 9..16 ── 5G tether   ──┘
```

The file arrives faster even though no individual connection got faster. **No
server, no subscription, no VPN.** This is what `aria2 --multiple-interface` does,
and — as we discovered — what Steam already does by itself.

Requirements and limits:

* The source must support range requests (`Accept-Ranges: bytes`). Most CDNs do.
* It only helps **file downloads through a tool that does this**. Web browsing,
  video streaming, and game launchers that don't do it won't benefit.
* It burns mobile data at the full combined rate.

---

## 4. The diagnostic sequence

Do these in order. Steps 4.3 and 4.4 are the ones that are easy to skip and will
silently ruin your results — I got both wrong on the first pass.

### 4.1 Inventory your interfaces

```powershell
Get-NetAdapter | Select-Object Name, InterfaceDescription, Status, LinkSpeed, DriverProvider
```

Be sceptical about what counts as a NIC. On this machine the output was:

```
Name          InterfaceDescription                          Status  LinkSpeed
----          --------------------                          ------  ---------
Ethernet      Realtek Gaming 2.5GbE Family Controller       Up      1 Gbps
Ethernet 2    SAMSUNG Mobile USB Remote NDIS Network Device Up      426.0 Mbps
vEthernet ... Hyper-V Virtual Ethernet Adapter              Up      10 Gbps
```

There is only **one** physical Ethernet port here. "Ethernet 2" is a phone
tethering over USB (RNDIS), and the `vEthernet` adapter is a Hyper-V virtual
switch, not a real link. `LinkSpeed` is the *local* link rate — it tells you
nothing about your internet speed.

### 4.2 Find the interfaces that are real internet paths

An interface is a usable internet path only if it has **its own default gateway**:

```powershell
Get-NetIPConfiguration | Where-Object { $_.IPv4Address -and $_.IPv4DefaultGateway } |
  Select-Object InterfaceAlias,
    @{n='IPv4';e={($_.IPv4Address.IPAddress -join ', ')}},
    @{n='Gateway';e={($_.IPv4DefaultGateway.NextHop -join ', ')}}

# And confirm there are two default routes:
Get-NetRoute -DestinationPrefix '0.0.0.0/0' |
  Select-Object InterfaceAlias, NextHop, RouteMetric
```

On this machine:

```
InterfaceAlias   IPv4            Gateway
--------------   ----            -------
Ethernet         192.168.29.78   192.168.29.1      <- wired ISP
Ethernet 2       10.209.14.212   10.209.14.180     <- 5G tether
```

Two interfaces, two gateways, both metric 25. That's the precondition for
everything that follows.

### 4.3 CRITICAL: verify the paths are genuinely separate

**Do not skip this.** Two interfaces with two gateways can still exit through the
same ISP — most commonly because the phone you're tethering is itself on Wi-Fi,
so its traffic goes phone → your home Wi-Fi → your home router → same ISP.

Check the **public egress IP of each interface** independently:

```powershell
$aria = "$env:LOCALAPPDATA\Microsoft\WinGet\Links\aria2c.exe"
$tmp  = "$env:TEMP\ipcheck"; New-Item -ItemType Directory -Force -Path $tmp | Out-Null

foreach ($ip in @('192.168.29.78','10.209.14.212')) {
  Remove-Item "$tmp\ip.txt","$tmp\ip.txt.aria2" -Force -ErrorAction SilentlyContinue
  & $aria --interface=$ip -x1 -s1 --allow-overwrite=true --file-allocation=none `
          --summary-interval=0 --console-log-level=error -d $tmp -o ip.txt `
          "https://api.ipify.org" 2>&1 | Out-Null
  "$ip -> $(Get-Content "$tmp\ip.txt" -Raw)"
}
```

**First run on this machine — the failure case:**

```
192.168.29.78  -> 49.36.245.236
10.209.14.212  -> 49.36.245.236     <- IDENTICAL. Nothing is being split.
```

The phone was on Wi-Fi. After turning the phone's Wi-Fi **off** (mobile data on,
USB tethering still enabled):

```
192.168.29.78  -> 49.36.245.236     <- home ISP
10.209.14.212  -> 157.48.71.40      <- mobile carrier. Two real paths.
```

This test also proves something useful: **Windows honours `--interface` source
binding.** Traffic bound to a source address does leave via that interface, so no
routing-table surgery is needed. (I initially suspected the opposite and tried to
prove it with a temporary host route — see §5.)

### 4.4 CRITICAL: check for background traffic before benchmarking

**This is the step I skipped, and it produced a completely wrong conclusion.**

```powershell
# Is anything using the links right now?
$a = Get-NetAdapterStatistics -Name "Ethernet","Ethernet 2" | Select Name, ReceivedBytes
Start-Sleep -Seconds 8
$b = Get-NetAdapterStatistics -Name "Ethernet","Ethernet 2" | Select Name, ReceivedBytes
foreach ($x in $a) {
  $y = $b | Where-Object Name -eq $x.Name
  "{0,-12} {1,6:N1} MB/s = {2,6:N0} Mbps" -f $x.Name,
    (($y.ReceivedBytes-$x.ReceivedBytes)/8/1MB), ((($y.ReceivedBytes-$x.ReceivedBytes)/8/1MB)*8)
}

# Who has connections open to the internet?
Get-NetTCPConnection -State Established |
  Where-Object { $_.RemoteAddress -notmatch '^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|::1|fe80)' } |
  Group-Object OwningProcess | Sort-Object Count -Descending | Select-Object -First 10 |
  ForEach-Object {
    $p = Get-Process -Id $_.Name -ErrorAction SilentlyContinue
    "{0,-28} {1,3} connections" -f $(if($p){$p.ProcessName}else{"PID $($_.Name)"}), $_.Count
  }
```

Output at the time:

```
Ethernet 2     28.61 MB/s =    229 Mbps
Ethernet       24.29 MB/s =    194 Mbps

steam                         53 connections
msedge                         8 connections
```

Steam was downloading a 137.9 GB game and pulling ~423 Mbps across both links.
Every benchmark taken before this point measured *leftover scraps*, not link
capacity.

Also worth checking cumulative volume — especially for metered links:

```powershell
Get-NetAdapterStatistics | ForEach-Object {
  "{0,-14} {1,8:N1} GB received" -f $_.Name, ($_.ReceivedBytes/1GB) }
```

### 4.5 Install aria2 and benchmark properly

```powershell
winget install --id aria2.aria2 --accept-package-agreements --accept-source-agreements
# lands at: %LOCALAPPDATA%\Microsoft\WinGet\Links\aria2c.exe  (PATH needs a new shell)
```

Pick a test file that is **large, close to you, and range-capable**. Verify it
before trusting it:

```powershell
$r = Invoke-WebRequest -Uri "https://speedtest.mumbai1.linode.com/100MB-mumbai.bin" `
       -Method Head -UseBasicParsing
$r.Headers['Content-Length']; $r.Headers['Accept-Ranges']   # want a real size + "bytes"
```

Known-good at time of writing: `speedtest.mumbai1.linode.com`,
`speedtest.singapore.linode.com`, `proof.ovh.net/files/`. The old
`cachefly.cachefly.net/100mb.test` now returns a **0-byte file** and will silently
report a nonsense speed.

Then run the three tests. `--stop=N` makes aria2 exit after N seconds, which keeps
each run bounded and comparable:

```powershell
$aria = "$env:LOCALAPPDATA\Microsoft\WinGet\Links\aria2c.exe"
$d = "$env:TEMP\bondtest"; New-Item -ItemType Directory -Force -Path $d | Out-Null
$u = "https://speedtest.mumbai1.linode.com/1GB-mumbai.bin"
$common = @("-k1M","--stop=15","--allow-overwrite=true","--file-allocation=none",
            "--summary-interval=0","--download-result=full","--console-log-level=error","-d",$d)

# A: link 1 alone
& $aria --interface=192.168.29.78 -x16 -s16 @common -o a.bin $u

# B: link 2 alone
& $aria --interface=10.209.14.212 -x16 -s16 @common -o b.bin $u

# C: both together
& $aria --multiple-interface=192.168.29.78,10.209.14.212 -x16 -s16 @common -o c.bin $u
```

**Keep the connection count identical across all three runs.** If test C uses more
connections than A and B, you cannot tell whether a gain came from bonding or just
from more parallelism. Run an explicit control — one link at test C's connection
count — to rule it out.

Read the `avg speed` column of the `Download Results` table, not the on-disk file
size. With `-x16`, aria2 writes 16 slices at different offsets, so the file appears
nearly full-size while only a fraction has actually arrived.

---

## 5. Wrong turns, and what they teach

Documented deliberately — these are the traps, and most of the time here was spent
in them.

1. **Dead test file.** The first benchmark returned `0B/0B ... 6B/s`. The CacheFly
   test URL now serves an empty file. *Always verify `Content-Length` before
   trusting a speed number.*

2. **Misread the on-disk file size.** `eth.bin` was 96 MB while aria2 reported only
   38 MiB downloaded. Multi-connection writes are sparse-at-offsets. *Trust the
   tool's counter, not `ls`.*

3. **Silent failure from `-ErrorAction SilentlyContinue`.** I tried to add a
   temporary host route to prove which interface was being used. Nothing happened
   and the test looked inconclusive. The cause was an unelevated shell —
   `New-NetRoute` needs admin and was failing with "Access is denied", swallowed by
   my own error suppression. *Suppress errors only after you've seen them once.*

4. **Confounded repeat.** I re-ran the combined test against a *different* server
   (Singapore instead of Mumbai) and got a lower number. That result was
   meaningless — two variables changed at once. *Change one thing per run.*

5. **Connection-count confound.** The combined test used 16 connections while the
   single-link tests used 8. The apparent gain could have been parallelism alone.
   Fixed with a control run (one link, 16 connections). *Always control the obvious
   alternative explanation.*

6. **The big one — benchmarking on a busy link.** I measured the wired link at
   0.23 MB/s and concluded it was "badly broken", and advised investigating the
   cable and the ISP. It was fine. Steam was consuming 194 Mbps of it at the time.
   A clean measurement afterwards gave **18 MiB/s (~151 Mbps)**. *Check for
   contention* ***before*** *you measure, and be suspicious of a result that implies
   hardware is broken — contention is far more common than a fault.*

7. **Assuming the tool must be the answer.** After all of this, the discovery was
   that **Steam was already aggregating both links by itself**, over IPv6:

   ```
   2405:201:5c1a:...  12 connections   <- wired ISP
   2409:40d4:4082:...  42 connections  <- Jio 5G
   ```

   Steam reported **339.6 Mbps sustained, 449.5 Mbps peak**. No configuration. The
   mechanism is exactly §3 — many connections, two default routes, Windows spreads
   them. *Check whether the problem is already solved before building a solution.*

---

## 6. Results from this machine

Invalid numbers included on purpose, so the contrast is visible.

| Measurement | Result | Valid? |
|---|---|---|
| Wired alone, during Steam download | 0.23 MB/s (~1.8 Mbps) | ❌ contended |
| 5G alone, during Steam download | 4.3 MB/s (~35 Mbps) | ❌ contended |
| Both combined, during Steam download | 5.3 MB/s (~42 Mbps) | ❌ contended |
| **Wired alone, link quiet** | **18 MiB/s (~151 Mbps)** | ✅ |
| Wired, measured via adapter counters under load | ~194 Mbps | ✅ |
| 5G tether, measured via adapter counters under load | ~229 Mbps | ✅ |
| **Both combined (Steam's own counter)** | **339.6 Mbps sustained / 449.5 peak** | ✅ |
| **Both combined, links quiet (aria2, `--multiple-interface`)** | **48 MiB/s (~403 Mbps)** | ✅ |

The headline comparison is the two clean measurements: **151 Mbps on the wired
link alone versus 403 Mbps with both links combined — a 2.7× gain**, and closely
consistent with what Steam achieves on its own.

The other lesson in that table: the three contended measurements were off by
roughly a factor of ten, and they were internally consistent enough to look
entirely believable. Two of them even showed the "expected" combined-is-faster
pattern, which is exactly why a wrong result can survive a sanity check.

---

## 7. Replication runbook for another device

1. **Confirm the OS.** `Get-CimInstance Win32_OperatingSystem | Select Caption, ProductType`.
   ProductType 1 = client, so no LBFO teaming. Don't waste time on it.
2. **Inventory interfaces** (§4.1). Identify which are *real* separate internet
   paths — each needs its own default gateway (§4.2). Discount Hyper-V adapters
   and anything link-local.
3. **If tethering a phone: turn the phone's Wi-Fi OFF.** Otherwise its traffic
   rides your home ISP and there is nothing to combine.
4. **Verify distinct egress IPs** (§4.3). If they match, stop and fix that first.
5. **Check for background traffic** (§4.4). Pause Steam, Windows Update, torrents,
   cloud sync. Verify the links are near zero before measuring.
6. **Install aria2** and verify your test file is real and range-capable (§4.5).
7. **Benchmark A / B / C with a matched connection count**, plus a control.
8. **Use the console** (double-click `multilink.bat`) for real downloads. It
   re-detects paths every few seconds, so a tether's changing IP doesn't matter.
9. **Watch metered data.** See §8.

---

## 8. Caveats and limits

* **Only helps tools that do multi-connection range downloads.** aria2 does.
  Steam does. Browsers generally use one connection per file and won't benefit.
  Streaming and gaming won't benefit at all.
* **A single stream still can't be split** without a paid bonding service or a
  self-hosted MPTCP setup (§3).
* **Never faster than the source will serve you.** If the server caps you at
  10 Mbps, two links won't change that.
* **Metered data is the real risk.** On this machine 24.5 GB crossed the phone
  tether in a 1h34m session. At ~29 MB/s a combined download eats mobile data
  faster than most plans can absorb. Check your carrier's usage counter, not just
  Windows'.
* **The tether's IP changes** every time you reconnect. Hard-coded IPs will break;
  auto-detect instead.
* **Windows metered-connection settings** can throttle some traffic on a link
  marked metered — worth checking if one path underperforms:
  `Get-NetConnectionProfile`.

---

## 9. Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| Both interfaces show the same public IP | Tethered phone is on Wi-Fi | §4.3; turn phone Wi-Fi off |
| `New-NetLbfoTeam`: "Access is denied" | Shell not elevated | Run as admin; then expect the SKU error |
| `New-NetLbfoTeam`: "not supported on this SKU" | Client Windows | Expected — LBFO is Server-only |
| Speeds absurdly low, and variable | Background download | §4.4 — check Steam, Windows Update, torrents |
| Speed reported as a few B/s | Test file is 0 bytes | Verify `Content-Length` |
| Combined is no faster than one link | Server doesn't honour ranges, or one link is tiny | Check `Accept-Ranges`; compare per-link speeds |
| Combined is *slower* than the fast link alone | Slow link's slices are stragglers | Drop the slow link, or raise `-x`/`-s` |
| `New-NetRoute`: "Access is denied" | Not elevated | Run as admin |
| File looks full-size but download is incomplete | Sparse multi-offset writes | Read aria2's own counter |

---

## 10. Command reference

```powershell
# --- Inventory -------------------------------------------------------------
Get-CimInstance Win32_OperatingSystem | Select Caption, Version, BuildNumber, ProductType
Get-NetAdapter | Select Name, InterfaceDescription, Status, LinkSpeed
Get-NetIPConfiguration | Where { $_.IPv4Address -and $_.IPv4DefaultGateway }
Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Select InterfaceAlias, NextHop, RouteMetric
Get-NetConnectionProfile                      # check for metered flags

# --- Am I elevated? --------------------------------------------------------
([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# --- Traffic and contention ------------------------------------------------
Get-NetAdapterStatistics
Get-NetTCPConnection -State Established | Group-Object OwningProcess

# --- aria2 -----------------------------------------------------------------
winget install --id aria2.aria2
aria2c --interface=<SRC_IP> -x16 -s16 <URL>                       # one link
aria2c --multiple-interface=<IP1>,<IP2> -x16 -s16 <URL>           # both links
#   -x N   max connections per server        -s N  number of splits
#   -k1M   minimum split size                --stop=N  exit after N seconds
#   --continue=true  resume                  --file-allocation=none  no preallocation

# --- The console -----------------------------------------------------------
# Double-click multilink.bat, or:
powershell -NoProfile -ExecutionPolicy Bypass -File .\multilink.ps1
```

---

## 11. The Multilink console

Everything in this guide is now behind one double-click: `multilink.bat` opens a
local web page with buttons for every action and live numbers for both links.
It replaced the earlier `fastdl.ps1` and the text menu.

### What it does

- **Live throughput graph**, stacked per link, last 60 seconds.
- **Check connections** (§4.2–4.4 in one click): paths, public IP per path,
  which link ordinary traffic uses, background traffic, ping and jitter.
- **Download over all links or one link**, with a "will this split?" check
  before you start (§3: the server must accept range requests).
- **Apps using the network**, with which link each one is on. A game that is
  partly on the 5G link is flagged.
- **Mobile data cap**: when the phone has carried N GB this session, downloads
  switch to wired-only without losing progress. A download you put on 5G only is
  paused instead, so a game on the cable is never disturbed.
- **"Speed boost lost" alert**: each link's public IP is re-checked every
  60 seconds; if they become identical (the phone joined Wi-Fi, §5), a red
  banner says so.
- **Fix game lag** / **Undo** (interface metrics, §7) and **Reset network**
  (runs `reset-network.ps1`, preview first).

### How it is built

```
multilink.bat --(UAC once)--> multilink.ps1 --> console/Server.ps1
                                                  |-- HttpListener on http://localhost:8642/
                                                  |-- sampler: per-link byte counters every 1 s
                                                  |-- watcher: public IP per link every 60 s
                                                  |-- app monitor: ETW Kernel-Network (admin)
                                                  `-- one aria2c per download, driven over RPC
```

- **Local only.** Requests from anything other than this PC are refused, and
  every API call needs a random per-session token embedded in the page. Without
  both, any website open in your browser could drive `localhost`.
- **Admin is optional.** Without it the console still runs; per-app speeds fall
  back to "which apps hold connections on which link", and Fix game lag / Reset
  ask you to restart as administrator.
- **Nothing outlives it.** Every aria2c is tied to the console
  (`--stop-with-process` plus a kill-on-close Job Object), and the ETW session is
  stopped on exit or swept on the next start.
- **Settings** (cap, chosen mobile link, wired baseline) live in
  `%LOCALAPPDATA%\multilink\settings.json`. `reset-network.ps1 -Apply -RemoveTools`
  deletes them.

## 12. Linux

The console is Windows-only (the per-app monitor uses Windows APIs). Linux keeps
the terminal script, plus `multilink.desktop` to launch it from the app menu.

### Linux: `multilink.sh`

```bash
chmod +x multilink.sh
./multilink.sh              # interactive menu
./multilink.sh check
./multilink.sh get  "https://example.com/big.iso" ~/Downloads
./multilink.sh only eth0 "https://example.com/big.iso"
sudo ./multilink.sh setup   # policy routing - see below
sudo ./multilink.sh undo
```

It installs `aria2` and `iproute2` itself via whichever package manager it finds
(apt / dnf / yum / pacman / zypper / apk).

### The one important Linux/Windows difference

**On Windows, binding a socket to a source address is enough** to make traffic
leave via that interface. That is why `--multiple-interface` works there with no
routing changes, and it's worth knowing because it makes Windows the easier
platform for this.

**On Linux it usually is not enough.** Route lookup is done on the destination,
so both sockets follow the single preferred default route regardless of the
source address you bound, and reverse-path filtering may drop the replies that
do come back. The fix is per-interface routing tables plus source-based rules —
what `sudo ./multilink.sh setup` does:

```bash
# conceptually, per interface:
echo "200 ml_eth0" >> /etc/iproute2/rt_tables
ip route replace default via <GW> dev eth0 table 200
ip rule add from <SRC_IP> table 200 priority 1000
sysctl -w net.ipv4.conf.eth0.rp_filter=2      # loose mode
```

Diagnostic order on Linux: run `./multilink.sh check` first. If all paths report
the **same** public IP, either a tethered phone is on Wi-Fi (fix that first) or
you need `sudo ./multilink.sh setup`. Re-run `check` afterwards to confirm.

These rules are runtime-only and disappear on reboot. To persist them, re-run
`sudo ./multilink.sh setup` at boot from a systemd unit or `rc.local`.

### Bugs found while testing these (all now fixed)

Worth recording, because each failed *silently* rather than erroring:

* **`multilink.sh` reported "no default route found" when `iproute2` was simply
  missing.** A missing dependency masqueraded as a network problem. It now
  detects and installs `iproute2`, and says so.
* **`multilink.ps1` printed every detail line blank.** The helpers were declared
  `function Say { param($m) Write-Host $m }` but called as `"text" | Say`.
  PowerShell will not bind pipeline input without `[Parameter(ValueFromPipeline=$true)]`
  **and** a `process { }` block, so `$m` was always `$null`. The control flow
  worked perfectly, which is what made it deceptive — only the output was empty.
* **The live graph updated every 2.5 s instead of every second.** On this PC
  `Get-NetAdapterStatistics` takes 4–5 s per call, and the phone's USB tether
  driver (RNDIS) takes ~1.8 s to answer any stats query. The console reads
  counters with `GetIfEntry2` on one thread per adapter, so the slow phone only
  delays its own readings.
* **Downloads sat at 0 bytes with the phone tethered but offline.** aria2 makes
  its first request (file size, redirects) on the *first* interface in
  `--multiple-interface`; with the dead tether first it waited 60 s. Wired links
  now go first, and aria2 gets `--connect-timeout=10 --timeout=20`.
