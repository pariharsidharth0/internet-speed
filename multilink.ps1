<#
  multilink.ps1 - engine for the Multilink console: use every internet
  connection at once for faster downloads.

  Splits one file into many HTTP range requests and spreads them across every
  network interface that has its own default gateway (e.g. wired ethernet + a
  phone's 5G tether). The file is reassembled locally, so no VPN, bonding
  service or paid tunnel is needed.

  Double-click multilink.bat to start the console. Running this script does
  the same; dot-sourcing it (". .\multilink.ps1") only defines the engine
  functions, which is how console\Server.ps1 and the tests use it.

  NOTE: Windows client editions cannot do NIC teaming (LBFO is Server-only),
  and teaming would not help across two different ISPs anyway. Parallel range
  requests are what actually works.
#>

$ErrorActionPreference = 'Continue'

# These accept BOTH  Info "text"  and  "text" | Info  - the pipeline form needs
# ValueFromPipeline plus a process block, or piped input is silently dropped.
function Info { param([Parameter(ValueFromPipeline=$true)]$m) process { Write-Host $m -ForegroundColor Cyan } }
function Warn { param([Parameter(ValueFromPipeline=$true)]$m) process { Write-Host $m -ForegroundColor Yellow } }
function Fail { param([Parameter(ValueFromPipeline=$true)]$m) process { Write-Host $m -ForegroundColor Red } }
function Good { param([Parameter(ValueFromPipeline=$true)]$m) process { Write-Host $m -ForegroundColor Green } }

function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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

# --- console ----------------------------------------------------------------
function Start-ConsoleApp {
  . (Join-Path $PSScriptRoot 'console\Server.ps1')
  $Host.UI.RawUI.WindowTitle = 'Multilink console'
  if (-not (Get-Aria)) { Read-Host 'aria2 is needed for downloads. Press Enter to close'; return }
  $settings = Get-Settings
  if (-not $settings.shortcutAsked) {
    $answer = Read-Host 'Create a desktop shortcut for Multilink? [Y/n]'
    if ($answer -notmatch '^[nN]') {
      try {
        $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Multilink.lnk'))
        $lnk.TargetPath = Join-Path $PSScriptRoot 'multilink.bat'
        $lnk.WorkingDirectory = $PSScriptRoot
        $lnk.Description = 'Use every internet connection at once'
        $lnk.Save()
        Good 'Shortcut created on your desktop.'
      } catch { Warn "Couldn't create the shortcut: $($_.Exception.Message)" }
    }
    $settings.shortcutAsked = $true
    Save-Settings -Settings $settings
  }
  Start-MultilinkConsole -Root $PSScriptRoot
}

# Dot-sourcing (". .\multilink.ps1") only defines the functions.
if ($MyInvocation.InvocationName -eq '.') { return }

Start-ConsoleApp
