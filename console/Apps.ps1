<#
  Apps.ps1 - which apps use the network, and over which link.

  Admin: exact bytes per process from an ETW session (NetMonitor.cs), TCP and
  UDP. Not admin: which processes hold connections on which link, no rates.
#>

if (-not ('Multilink.NetMonitor' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'NetMonitor.cs') }

$script:Games = @('VALORANT-Win64-Shipping.exe', 'cs2.exe', 'FortniteClient-Win64-Shipping.exe', 'r5apex.exe',
  'LeagueofLegends.exe', 'RocketLeague.exe', 'Overwatch.exe', 'GTA5.exe', 'eldenring.exe', 'RainbowSix.exe', 'dota2.exe')

function Test-IsGame {
  param([string]$Exe)
  [bool]($script:Games | Where-Object { $_ -ieq $Exe })
}

function Get-LinkMap {
  param($Paths)
  $map = @{}
  foreach ($p in @($Paths)) {
    $map[$p.IP] = $p.Alias
    foreach ($v6 in @($p.IPv6)) { if ($v6) { $map[([Net.IPAddress]::Parse($v6)).ToString()] = $p.Alias } }
  }
  $map
}

# $ProcessNames: pid -> @{exe; name}. Rows from different PIDs of the same
# program (chrome.exe has dozens) merge into one line.
function Group-AppTraffic {
  param([object[]]$Rows, $Paths, [double]$Seconds, [hashtable]$ProcessNames, [string]$MobileAlias)
  $links = Get-LinkMap $Paths
  $apps = @{}
  foreach ($r in @($Rows)) {
    $alias = $links[$r.LocalIp]
    if (-not $alias) { continue }
    $info = $ProcessNames[[int]$r.Pid]
    if (-not $info) { $info = @{ exe = "pid $($r.Pid)"; name = "Process $($r.Pid)" } }
    $a = $apps[$info.exe]
    if (-not $a) {
      $a = @{ exe = $info.exe; name = $info.name; rx = 0.0; tx = 0.0; conns = 0; protos = @{}; perLink = @{} }
      $apps[$info.exe] = $a
    }
    $a.rx += $r.Rx; $a.tx += $r.Tx; $a.conns += $r.Conns
    $a.protos[$r.Proto] = $true
    if (-not $a.perLink.ContainsKey($alias)) { $a.perLink[$alias] = 0.0 }
    $a.perLink[$alias] += $r.Rx
  }
  $toMbps = { param($bytes) [math]::Round($bytes * 8 / $Seconds / 1e6, 1) }
  $out = foreach ($a in $apps.Values) {
    $per = @{}
    foreach ($k in $a.perLink.Keys) { $per[$k] = & $toMbps $a.perLink[$k] }
    $game = Test-IsGame $a.exe
    $mobileShare = 0
    if ($MobileAlias -and $a.rx -gt 0 -and $a.perLink.ContainsKey($MobileAlias)) { $mobileShare = $a.perLink[$MobileAlias] / $a.rx }
    [ordered]@{
      exe = $a.exe; name = $a.name; protos = @($a.protos.Keys | Sort-Object)
      downMbps = (& $toMbps $a.rx); upMbps = (& $toMbps $a.tx); conns = $a.conns
      perLink = $per; game = $game; laggy = [bool]($game -and $mobileShare -gt 0.05)
    }
  }
  @($out | Sort-Object { $_.downMbps } -Descending)
}

$script:NameCache = @{}
function Get-ProcessNames {
  param([int[]]$Pids)
  $names = @{}
  foreach ($id in ($Pids | Select-Object -Unique)) {
    if ($script:NameCache.ContainsKey($id)) { $names[$id] = $script:NameCache[$id]; continue }
    $info = $null
    if ($id -le 4) { $info = @{ exe = 'System'; name = 'Windows (system)' } }
    else {
      $p = Get-Process -Id $id -ErrorAction SilentlyContinue
      if ($p) {
        $desc = $null
        try { $desc = $p.MainModule.FileVersionInfo.FileDescription } catch { }
        if (-not $desc) { $desc = $p.Description }
        if (-not $desc) { $desc = $p.ProcessName }
        $info = @{ exe = "$($p.ProcessName).exe"; name = "$desc".Trim() }
      }
    }
    if ($info) { $script:NameCache[$id] = $info; $names[$id] = $info }
  }
  $names
}

# No admin: who holds connections on which link. Rates are unknown (null).
function Get-ConnectionRows {
  param($Paths, [string]$MobileAlias)
  $links = Get-LinkMap $Paths
  $conns = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | Select-Object LocalAddress, OwningProcess, @{ n = 'P'; e = { 'TCP' } })
  $conns += @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Select-Object LocalAddress, OwningProcess, @{ n = 'P'; e = { 'UDP' } })
  $names = Get-ProcessNames @($conns | ForEach-Object { [int]$_.OwningProcess })
  $apps = @{}
  foreach ($c in $conns) {
    $alias = $links["$($c.LocalAddress)"]
    if (-not $alias) { continue }
    $info = $names[[int]$c.OwningProcess]
    if (-not $info) { continue }
    $a = $apps[$info.exe]
    if (-not $a) { $a = @{ exe = $info.exe; name = $info.name; conns = 0; protos = @{}; perLink = @{} }; $apps[$info.exe] = $a }
    $a.conns++; $a.protos[$c.P] = $true; $a.perLink[$alias] = $null
  }
  $out = foreach ($a in $apps.Values) {
    $game = Test-IsGame $a.exe
    [ordered]@{ exe = $a.exe; name = $a.name; protos = @($a.protos.Keys | Sort-Object); downMbps = $null; upMbps = $null
                conns = $a.conns; perLink = $a.perLink; game = $game; laggy = [bool]($game -and $MobileAlias -and $a.perLink.ContainsKey($MobileAlias)) }
  }
  @($out | Sort-Object { $_.conns } -Descending)
}

# Runspace: drain every second, publish a 2 s window. Falls back to the
# connections view when not elevated or when the ETW session can't start.
function Start-AppMonitor {
  param($State)
  Start-BackgroundRunspace $State 'apps' {
    $mon = $null
    if ($state.IsAdmin) {
      try { $mon = New-Object Multilink.NetMonitor; $mon.Start(); $state.NetMonitor = $mon; $state.AppMonitorMode = 'etw' }
      catch {
        [void]$state.Log.Add(@{ t = (Get-Date).ToString('o'); text = "Per-app monitor unavailable: $($_.Exception.Message)"; level = 'warn' })
        $mon = $null; $state.AppMonitorMode = 'connections'
      }
    }
    $window = New-Object Collections.Queue
    $tick = 0
    try {
      while (-not $state.Stopping) {
        $paths = @($state.Paths)
        if ($mon) {
          $locals = @($paths | ForEach-Object { $_.IP; @($_.IPv6) } | Where-Object { $_ })
          $mon.Aggregator.SetLocalAddresses([string[]]$locals)
          $window.Enqueue($mon.Aggregator.Drain())
          while ($window.Count -gt 2) { [void]$window.Dequeue() }
          $rows = @($window.ToArray() | ForEach-Object { $_ })
          $names = Get-ProcessNames @($rows | ForEach-Object { $_.Pid })
          $state.Apps = @{ mode = 'etw'; rows = @(Group-AppTraffic -Rows $rows -Paths $paths -Seconds $window.Count -ProcessNames $names -MobileAlias $state.Mobile.Alias) }
        } elseif ($tick % 2 -eq 0) {
          $state.Apps = @{ mode = 'connections'; rows = @(Get-ConnectionRows $paths $state.Mobile.Alias) }
        }
        $tick++
        Start-Sleep -Milliseconds 1000
      }
    } finally { if ($mon) { $mon.Dispose() } }
  } | Out-Null
}
