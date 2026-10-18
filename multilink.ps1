<#
  multilink.ps1 - use every internet connection at once for faster downloads

  Splits one file into many HTTP range requests and spreads them across every
  network interface that has its own default gateway (e.g. wired ethernet + a
  phone's 5G tether). The file is reassembled locally, so no VPN, bonding
  service or paid tunnel is needed.

  Double-click multilink.bat, or run:
    .\multilink.ps1                        interactive menu
    .\multilink.ps1 -Action check          paths, egress IPs, contention, latency
    .\multilink.ps1 -Action get   -Url <U> download over ALL paths
    .\multilink.ps1 -Action only  -Url <U> -Only <ALIAS|IP>   one path only
    .\multilink.ps1 -Action optimise       prefer the low-latency link (admin)
    .\multilink.ps1 -Action undo           restore automatic metrics (admin)

  NOTE: Windows client editions cannot do NIC teaming (LBFO is Server-only),
  and teaming would not help across two different ISPs anyway. This script uses
  parallel range requests instead, which is what actually works.
#>
[CmdletBinding()]
param(
  [ValidateSet('menu','check','get','only','optimise','undo')]
  [string]$Action = 'menu',
  [string]$Url,
  [string]$Only,
  [string]$OutDir = "$env:USERPROFILE\Downloads",
  [int]$Connections = 16
)

$ErrorActionPreference = 'Continue'

# These accept BOTH  Say "text"  and  "text" | Say  - the pipeline form needs
# ValueFromPipeline plus a process block, or piped input is silently dropped
# and every line prints blank.
function Say  { param([Parameter(ValueFromPipeline=$true)]$m) process { Write-Host $m } }
function Info { param([Parameter(ValueFromPipeline=$true)]$m) process { Write-Host $m -ForegroundColor Cyan } }
function Warn { param([Parameter(ValueFromPipeline=$true)]$m) process { Write-Host $m -ForegroundColor Yellow } }
function Fail { param([Parameter(ValueFromPipeline=$true)]$m) process { Write-Host $m -ForegroundColor Red } }
function Good { param([Parameter(ValueFromPipeline=$true)]$m) process { Write-Host $m -ForegroundColor Green } }
function Dim  { param([Parameter(ValueFromPipeline=$true)]$m) process { Write-Host $m -ForegroundColor DarkGray } }

function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Elevated {
  param([string]$Act)
  Warn "This action needs administrator rights. Requesting elevation..."
  try {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
      '-NoProfile','-ExecutionPolicy','Bypass','-NoExit',
      '-File', "`"$PSCommandPath`"", '-Action', $Act) | Out-Null
  } catch { Fail "Elevation was cancelled or failed." }
}

# --- aria2 ------------------------------------------------------------------
function Get-Aria {
  $p = "$env:LOCALAPPDATA\Microsoft\WinGet\Links\aria2c.exe"
  if (Test-Path $p) { return $p }
  $c = (Get-Command aria2c -ErrorAction SilentlyContinue).Source
  if ($c) { return $c }
  Warn "aria2 is not installed."
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Fail "winget is unavailable. Install aria2 manually from https://aria2.github.io/"
    return $null
  }
  Info "Installing aria2 via winget..."
  winget install --id aria2.aria2 --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
  if (Test-Path $p) { Good "aria2 installed."; return $p }
  $c = (Get-Command aria2c -ErrorAction SilentlyContinue).Source
  if ($c) { Good "aria2 installed."; return $c }
  Fail "aria2 install failed."; return $null
}

# --- discovery --------------------------------------------------------------
# A usable internet path = an IPv4 address AND its own default gateway.
function Get-Paths {
  $out = @()
  foreach ($cfg in (Get-NetIPConfiguration -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPv4Address -and $_.IPv4DefaultGateway })) {
    $ip = ($cfg.IPv4Address | Select-Object -First 1).IPAddress
    if (-not $ip -or $ip -like '169.254.*') { continue }
    $mi = (Get-NetIPInterface -InterfaceIndex $cfg.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    $v6 = @(Get-NetIPAddress -InterfaceIndex $cfg.InterfaceIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike 'fe80*' } | ForEach-Object { $_.IPAddress })
    $out += [pscustomobject]@{
      Alias          = $cfg.InterfaceAlias
      IP             = $ip
      Gateway        = ($cfg.IPv4DefaultGateway.NextHop | Select-Object -First 1)
      Metric         = $(if ($mi) { $mi.InterfaceMetric } else { $null })
      Auto           = $(if ($mi) { $mi.AutomaticMetric } else { $null })
      InterfaceIndex = $cfg.InterfaceIndex
      Description    = $cfg.InterfaceDescription
      IPv6           = $v6
    }
  }
  $out | Sort-Object IP -Unique
}

function Show-Paths {
  $p = @(Get-Paths)
  Info "Internet paths detected:"
  if ($p.Count -eq 0) { Fail "  none - no interface has its own default gateway."; return $p }
  foreach ($x in $p) {
    "  {0,-14} {1,-16} gw {2,-16} metric {3} (auto: {4})" -f $x.Alias, $x.IP, $x.Gateway, $x.Metric, $x.Auto | Say
  }
  Dim  ("  {0} path(s)." -f $p.Count)
  return $p
}

# PowerShell's -match treats $null as a collection and returns nothing (falsy),
# so a failed lookup used to skip the "no response" branch, print a blank IP,
# then crash on Hashtable.ContainsKey($null).
function Test-Ipv4Text {
  param($s)
  if ($null -eq $s) { return $false }
  $t = "$s".Trim()
  if ([string]::IsNullOrWhiteSpace($t)) { return $false }
  return [regex]::IsMatch($t, '^\d{1,3}(\.\d{1,3}){3}$')
}

# Bind a GET to a local IPv4. curl.exe is more reliable than aria2 for this;
# aria2's async DNS often ignores --interface and then writes no file.
function Get-EgressVia {
  param([string]$LocalIP, [string]$Aria, [string]$Dir, [string]$OutFile)
  $urls = @('https://api.ipify.org','https://ipv4.icanhazip.com','https://ifconfig.me/ip')
  $curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
  if ($curl) {
    foreach ($u in $urls) {
      $raw = & $curl -sS --ipv4 --max-time 8 --retry 1 --interface $LocalIP $u 2>$null
      $t = if ($null -eq $raw) { '' } else { "$raw".Trim() }
      if (Test-Ipv4Text $t) { return $t }
    }
  }
  if ($Aria) {
    foreach ($u in $urls) {
      Remove-Item (Join-Path $Dir $OutFile), (Join-Path $Dir "$OutFile.aria2") -Force -ErrorAction SilentlyContinue
      & $Aria --interface=$LocalIP --async-dns=false -x1 -s1 --allow-overwrite=true `
              --file-allocation=none --summary-interval=0 --console-log-level=error `
              --timeout=10 --max-tries=1 -d $Dir -o $OutFile $u 2>&1 | Out-Null
      $t = (Get-Content (Join-Path $Dir $OutFile) -Raw -ErrorAction SilentlyContinue)
      if (Test-Ipv4Text $t) { return "$t".Trim() }
    }
  }
  return $null
}

# --- latency ----------------------------------------------------------------
function ConvertFrom-PingOutput {
  param([string]$Text)
  $times = @([regex]::Matches($Text, 'time[=<](\d+)ms') | ForEach-Object { [int]$_.Groups[1].Value })
  $m = [regex]::Match($Text, '\((\d+)% loss\)')
  $loss = if ($m.Success) { [int]$m.Groups[1].Value } else { 100 }
  @{ Times = $times; LossPct = $loss }
}

# Jitter = mean absolute difference between successive replies.
function Get-LatencyStats {
  param([int[]]$Times, [int]$LossPct)
  $avg = [math]::Round(($Times | Measure-Object -Average).Average, 1)
  $max = ($Times | Measure-Object -Maximum).Maximum
  $d = @(); for ($i = 1; $i -lt $Times.Count; $i++) { $d += [math]::Abs($Times[$i] - $Times[$i-1]) }
  $jit = if ($d.Count) { [math]::Round(($d | Measure-Object -Average).Average, 1) } else { 0 }
  @{ avgMs = $avg; maxMs = $max; jitterMs = $jit; lossPct = $LossPct }
}

# ICMP to 8.8.8.8 is often blocked, so try a few targets; if all ICMP fails,
# time a TCP connect to 1.1.1.1:443 instead.
function Measure-PathLatency {
  param($Path)
  $times = @(); $loss = 100
  foreach ($dst in @('1.1.1.1','8.8.8.8',$Path.Gateway)) {
    if (-not $dst) { continue }
    $p = ConvertFrom-PingOutput (& ping.exe -n 6 -w 1500 -S $Path.IP $dst 2>&1 | Out-String)
    $times = @($p.Times); $loss = $p.LossPct
    if ($times.Count -gt 1) { break }
  }
  $now = (Get-Date).ToString('o')
  if ($times.Count -gt 1) {
    $s = Get-LatencyStats $times $loss
    $s.tcpOnly = $false; $s.measuredAt = $now
    return $s
  }
  $tcpMs = $null
  try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Client.Bind((New-Object System.Net.IPEndPoint ([Net.IPAddress]$Path.IP, 0)))
    $iar = $tcp.BeginConnect([Net.IPAddress]::Parse('1.1.1.1'), 443, $null, $null)
    if ($iar.AsyncWaitHandle.WaitOne(2000)) {
      $tcp.EndConnect($iar)
      $tcpMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 0)
    }
    $tcp.Close()
  } catch { }
  if ($tcpMs) { return @{ avgMs = $tcpMs; maxMs = $tcpMs; jitterMs = $null; lossPct = $loss; tcpOnly = $true; measuredAt = $now } }
  return @{ avgMs = $null; maxMs = $null; jitterMs = $null; lossPct = $loss; tcpOnly = $false; measuredAt = $now }
}

# --- metrics ----------------------------------------------------------------
# Preferred link gets metric 10, the rest 60. Both keep their default route,
# so multi-path downloads still work. Returns log lines; needs admin.
function Set-PathMetrics {
  param([string]$PreferredAlias)
  $lines = @()
  foreach ($x in @(Get-Paths)) {
    $m = if ($x.Alias -eq $PreferredAlias) { 10 } else { 60 }
    try {
      Set-NetIPInterface -InterfaceAlias $x.Alias -AddressFamily IPv4 -InterfaceMetric $m -ErrorAction Stop
      $lines += ("  {0,-14} metric -> {1}" -f $x.Alias, $m)
    } catch { $lines += ("  {0}: {1}" -f $x.Alias, $_.Exception.Message.Split("`n")[0]) }
  }
  $lines
}

function Reset-PathMetrics {
  $lines = @()
  foreach ($x in @(Get-Paths)) {
    try {
      Set-NetIPInterface -InterfaceAlias $x.Alias -AddressFamily IPv4 -AutomaticMetric Enabled -ErrorAction Stop
      $lines += ("  {0,-14} automatic metric restored" -f $x.Alias)
    } catch { $lines += ("  {0}: {1}" -f $x.Alias, $_.Exception.Message.Split("`n")[0]) }
  }
  $lines
}

# --- the check that actually matters ---------------------------------------
function Invoke-Check {
  $aria = Get-Aria; if (-not $aria) { return }
  $paths = @(Show-Paths); if ($paths.Count -eq 0) { return }

  Say ""; Info "Public egress IP per path (the test that decides everything):"
  $tmp = Join-Path $env:TEMP "ml-check"; New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $seen = @{}; $dup = $false; $fail = 0
  foreach ($x in $paths) {
    $pub = Get-EgressVia -LocalIP $x.IP -Aria $aria -Dir $tmp -OutFile 'ip.txt'
    if (-not (Test-Ipv4Text $pub)) {
      "  {0,-14} -> (no response)" -f $x.Alias | Say; $fail++; continue
    }
    "  {0,-14} -> {1}" -f $x.Alias, $pub | Say
    if ($seen.ContainsKey($pub)) { $dup = $true } else { $seen[$pub] = $x.Alias }
  }
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

  Say ""
  if ($fail -eq $paths.Count) {
    Warn "No path returned a public IP - cannot tell if they are separate."
    Dim  "  HTTP to ipify/icanhazip failed when bound to each NIC. Check the link, proxy, or firewall."
  } elseif ($dup) {
    Warn "Duplicate egress IPs - your paths are NOT separate. Nothing will be split."
    Say  "Causes, most common first:"
    Say  "  1. A tethered phone is on Wi-Fi. Turn the phone's Wi-Fi OFF (leave mobile data on)."
    Say  "  2. Both interfaces genuinely go to the same router/ISP."
  } elseif ($fail -gt 0) {
    Warn "$fail path(s) gave no answer - separation is UNVERIFIED."
  } elseif ($paths.Count -lt 2) {
    Warn "Only 1 usable path - nothing to aggregate yet."
    Say  "Add a second connection (USB-tether a phone with its Wi-Fi off, or add a NIC)."
  } else {
    Good ("{0} paths with distinct egress IPs - aggregation will work." -f $paths.Count)
  }

  # Which path does ordinary traffic (browsing, games) use?
  Say ""; Info "Path used by ordinary traffic (games, browsing) right now:"
  $tmp2 = Join-Path $env:TEMP "ml-def"; New-Item -ItemType Directory -Force -Path $tmp2 | Out-Null
  $def = $null
  $curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
  if ($curl) {
    $raw = & $curl -sS --ipv4 --max-time 8 --retry 1 "https://api.ipify.org" 2>$null
    if (Test-Ipv4Text $raw) { $def = "$raw".Trim() }
  }
  if (-not $def) {
    & $aria --async-dns=false -x1 -s1 --allow-overwrite=true --file-allocation=none --summary-interval=0 `
            --console-log-level=error --timeout=10 --max-tries=1 -d $tmp2 -o d.txt `
            "https://api.ipify.org" 2>&1 | Out-Null
    $raw = (Get-Content "$tmp2\d.txt" -Raw -ErrorAction SilentlyContinue)
    if (Test-Ipv4Text $raw) { $def = "$raw".Trim() }
  }
  Remove-Item $tmp2 -Recurse -Force -ErrorAction SilentlyContinue
  if ($def -and $seen.ContainsKey($def)) { Say ("  -> {0}  (egress {1})" -f $seen[$def], $def) }
  elseif ($def) { Say ("  -> egress {0}" -f $def) }
  else { Say "  -> (no response)" }

  # Contention: a busy link makes every measurement a lie.
  Say ""; Info "Background traffic (pause downloads before trusting any speed test):"
  $a = Get-NetAdapterStatistics -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in $paths.Alias } | Select-Object Name, ReceivedBytes
  Start-Sleep -Seconds 5
  $b = Get-NetAdapterStatistics -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in $paths.Alias } | Select-Object Name, ReceivedBytes
  $busy = $false
  foreach ($x in $a) {
    $y = $b | Where-Object Name -eq $x.Name
    $mbs = ($y.ReceivedBytes - $x.ReceivedBytes)/5/1MB
    "  {0,-14} {1,7:N1} MB/s = {2,6:N0} Mbps" -f $x.Name, $mbs, ($mbs*8) | Say
    if ($mbs*8 -gt 5) { $busy = $true }
  }
  if ($busy) {
    Warn "A link is already busy. Pause Steam / Windows Update / torrents first."
    Dim  "  (Measuring on a busy link is the single easiest way to get a wrong answer.)"
  }

  # Latency: what games actually care about. ICMP to 8.8.8.8 is often blocked,
  # so try a few targets; if all ICMP fails, time a TCP connect to 1.1.1.1:443.
  Say ""; Info "Latency per path (games care about this, not bandwidth):"
  foreach ($x in $paths) {
    $l = Measure-PathLatency $x
    if ($l.avgMs -eq $null) {
      "  {0,-14} no replies (ICMP loss {1}%)" -f $x.Alias, $l.lossPct | Say
    } elseif ($l.tcpOnly) {
      "  {0,-14} TCP ~{1} ms to 1.1.1.1:443 (ICMP blocked)" -f $x.Alias, $l.avgMs | Say
    } else {
      "  {0,-14} avg {1,6} ms | max {2,5} ms | jitter {3,5} ms | loss {4}%" -f $x.Alias,$l.avgMs,$l.maxMs,$l.jitterMs,$l.lossPct | Say
    }
  }
  Dim "  Lowest avg+jitter is your gaming link. Send bulk downloads over the other one."
}

# --- downloads --------------------------------------------------------------
function Invoke-Get {
  param([string]$U, [string]$Dir, [int]$Conn)
  if (-not $U) { Fail "No URL given."; return }
  $aria = Get-Aria; if (-not $aria) { return }
  $paths = @(Get-Paths)
  if ($paths.Count -eq 0) { Fail "No usable interface found."; return }
  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  Info ("Paths in use: " + (($paths.Alias) -join ', '))
  $a = @("-x$Conn","-s$Conn","-k1M","--continue=true","--file-allocation=none",
         "--async-dns=false","--max-tries=5","--retry-wait=2","-d",$Dir)
  if ($paths.Count -gt 1) { $a += "--multiple-interface=$(($paths.IP) -join ',')" }
  else { Warn "Only one path - ordinary download." }
  $a += $U
  & $aria @a
}

function Invoke-Only {
  param([string]$U, [string]$Want, [string]$Dir, [int]$Conn)
  if (-not $U -or -not $Want) { Fail "Need both -Url and -Only."; return }
  $aria = Get-Aria; if (-not $aria) { return }
  $m = @(Get-Paths) | Where-Object { $_.Alias -eq $Want -or $_.IP -eq $Want } | Select-Object -First 1
  if (-not $m) { Fail "No path matching '$Want'. Run -Action check to list them."; return }
  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  Info ("Using only {0} ({1}) - other links stay free." -f $m.Alias, $m.IP)
  & $aria --interface=$($m.IP) --async-dns=false "-x$Conn" "-s$Conn" -k1M --continue=true `
          --file-allocation=none --max-tries=5 --retry-wait=2 -d $Dir $U
}

# --- routing preference -----------------------------------------------------
function Invoke-Optimise {
  if (-not (Test-Admin)) { Invoke-Elevated 'optimise'; return }
  $paths = @(Show-Paths)
  if ($paths.Count -lt 2) { Warn "Need 2+ paths for this to be meaningful."; return }
  Say ""
  Say "Ordinary traffic - browsing, and crucially GAMES - should use your"
  Say "lowest-latency link. Bonding never helps latency; picking the right"
  Say "single link does. Run -Action check first if you're unsure which is best."
  Say ""
  for ($i=0; $i -lt $paths.Count; $i++) { "  [{0}] {1,-14} {2}" -f $i, $paths[$i].Alias, $paths[$i].IP | Say }
  $sel = Read-Host "Which path should ordinary traffic prefer? [0-$($paths.Count-1)]"
  if ($sel -notmatch '^\d+$' -or [int]$sel -ge $paths.Count) { Fail "Invalid selection."; return }
  $pref = $paths[[int]$sel]
  Set-PathMetrics $pref.Alias | Good
  Say ""
  Good ("Ordinary traffic will now prefer {0}." -f $pref.Alias)
  Say  "Both paths keep their default route, so multi-path downloads still work."
  Warn "Verify with: -Action check  (you should still see distinct egress IPs)"
  Say  ""
  Say  "Also consider marking a mobile link as metered so Windows throttles"
  Say  "background use of it:  Settings > Network & Internet > <adapter> >"
  Say  "Metered connection."
}

function Invoke-Undo {
  if (-not (Test-Admin)) { Invoke-Elevated 'undo'; return }
  Reset-PathMetrics | Good
}

# --- menu -------------------------------------------------------------------
function Show-Menu {
  while ($true) {
    Say ""
    Info "==== multilink ===="
    Say  "  1) Check my connections (paths, egress IPs, contention, latency)"
    Say  "  2) Download a file using ALL connections"
    Say  "  3) Download using ONE connection (keeps the others free for gaming)"
    Say  "  4) Prefer my low-latency link for normal traffic + games (admin)"
    Say  "  5) Undo that (restore automatic metrics) (admin)"
    Say  "  6) Quit"
    $c = Read-Host "Choose [1-6]"
    switch ($c) {
      '1' { Invoke-Check }
      '2' { $u = Read-Host "URL"
            $d = Read-Host "Save to [$OutDir]"; if (-not $d) { $d = $OutDir }
            Invoke-Get -U $u -Dir $d -Conn $Connections }
      '3' { $p = @(Show-Paths)
            if ($p.Count -gt 0) {
              $w = Read-Host "Which interface (alias or IP)"
              $u = Read-Host "URL"
              $d = Read-Host "Save to [$OutDir]"; if (-not $d) { $d = $OutDir }
              Invoke-Only -U $u -Want $w -Dir $d -Conn $Connections } }
      '4' { Invoke-Optimise }
      '5' { Invoke-Undo }
      '6' { return }
      default { Warn "Pick 1-6." }
    }
  }
}

# Dot-sourcing (". .\multilink.ps1") only defines the functions.
if ($MyInvocation.InvocationName -eq '.') { return }

switch ($Action) {
  'check'    { Invoke-Check }
  'get'      { Invoke-Get  -U $Url -Dir $OutDir -Conn $Connections }
  'only'     { Invoke-Only -U $Url -Want $Only -Dir $OutDir -Conn $Connections }
  'optimise' { Invoke-Optimise }
  'undo'     { Invoke-Undo }
  default    { Show-Menu }
}
