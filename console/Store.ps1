<#
  Store.ps1 - shared console state, settings, live per-link rates.

  Producer/consumer: background runspaces (sampler, watcher, jobs) write into
  one synchronized hashtable; request handlers on the main thread read it.
#>

$script:StoreDir = $PSScriptRoot
$script:SettingsPath = Join-Path $env:LOCALAPPDATA 'multilink\settings.json'
$script:MobilePattern = 'Remote NDIS|RNDIS|Mobile Broadband|Cellular'
if (-not ('Multilink.IfPoller' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'Native.cs') }

# --- settings -------------------------------------------------------------------
function Get-DefaultSettings {
  @{ capGB = 10; mobileAlias = $null; baselineMbps = $null; baselineAt = $null; shortcutAsked = $false }
}

function Get-Settings {
  param([string]$Path = $script:SettingsPath)
  $s = Get-DefaultSettings
  if (Test-Path $Path) {
    try {
      $j = Get-Content $Path -Raw | ConvertFrom-Json -ErrorAction Stop
      foreach ($p in $j.PSObject.Properties) { if ($s.ContainsKey($p.Name)) { $s[$p.Name] = $p.Value } }
    } catch { }
  }
  $s
}

function Save-Settings {
  param([string]$Path = $script:SettingsPath, [hashtable]$Settings)
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllText($Path, (ConvertTo-Json $Settings -Compress))
}

# --- state ----------------------------------------------------------------------
function New-ConsoleState {
  $s = [hashtable]::Synchronized(@{})
  $s.Paths = @()
  $s.Series = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
  $s.Rates = @{}
  $s.Separation = @{ status = 'unknown'; checkedAt = $null }
  $s.PublicIps = [hashtable]::Synchronized(@{})
  $s.Latency = [hashtable]::Synchronized(@{})
  $s.Mobile = [hashtable]::Synchronized(@{ Alias = $null; SessionBytes = [double]0 })
  $s.Settings = Get-Settings
  $s.Jobs = [hashtable]::Synchronized(@{})
  $s.Downloads = [hashtable]::Synchronized(@{ Current = $null; Finished = (New-Object Collections.ArrayList) })
  $s.Apps = @{ mode = 'connections'; rows = @() }
  $s.AppMonitorMode = 'connections'
  $s.Log = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
  $s.Runspaces = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
  $s.Stopping = $false
  $s.IsAdmin = $false
  $s.Port = 0
  $s.Token = ''
  $s.ConsoleDir = $script:StoreDir
  $s.IfPoller = New-Object Multilink.IfPoller
  $s
}

# Runs $Script in its own runspace with the engine and console modules loaded
# and $state bound. Scriptblocks don't cross runspaces, so it travels as text.
function Start-BackgroundRunspace {
  param($State, [string]$Name, [scriptblock]$Script, [object[]]$Arguments = @())
  $boot = @'
param($state, $consoleDir, $body, $argsList)
. (Join-Path (Split-Path -Parent $consoleDir) 'multilink.ps1')
Get-ChildItem $consoleDir -Filter *.ps1 | Where-Object { $_.Name -ne 'Server.ps1' } | ForEach-Object { . $_.FullName }
$work = [scriptblock]::Create($body)
try { & $work @argsList }
catch { [void]$state.Log.Add(@{ t = (Get-Date).ToString('o'); text = "background error: $($_.Exception.Message)"; level = 'bad' }) }
'@
  $rs = [runspacefactory]::CreateRunspace()
  $rs.Name = $Name
  $rs.Open()
  $ps = [powershell]::Create()
  $ps.Runspace = $rs
  [void]$ps.AddScript($boot).AddArgument($State).AddArgument($State.ConsoleDir).AddArgument($Script.ToString()).AddArgument($Arguments)
  $handle = $ps.BeginInvoke()
  [void]$State.Runspaces.Add(@{ Name = $Name; PowerShell = $ps; Handle = $handle })
  $ps
}

# --- rates ----------------------------------------------------------------------
# $Prev/$Curr: alias -> @{Rx=bytes; Tx=bytes; At=seconds (optional)}.
# Returns alias -> @{rx; tx} in Mbps. With At, each adapter uses its own time
# delta; an adapter with no new reading keeps its rate from $LastRates.
function Get-RateTable {
  param([hashtable]$Prev, [hashtable]$Curr, [double]$Seconds, [hashtable]$LastRates = @{})
  $out = @{}
  foreach ($alias in $Curr.Keys) {
    $rx = 0; $tx = 0
    $dt = $Seconds
    if ($Prev.ContainsKey($alias) -and $Curr[$alias].ContainsKey('At') -and $Prev[$alias].ContainsKey('At')) {
      $dt = [double]$Curr[$alias].At - [double]$Prev[$alias].At
      if ($dt -le 0) {
        if ($LastRates.ContainsKey($alias)) { $out[$alias] = $LastRates[$alias] } else { $out[$alias] = @{ rx = 0; tx = 0 } }
        continue
      }
    }
    if ($Prev.ContainsKey($alias) -and $dt -gt 0) {
      $dRx = [double]$Curr[$alias].Rx - [double]$Prev[$alias].Rx
      $dTx = [double]$Curr[$alias].Tx - [double]$Prev[$alias].Tx
      if ($dRx -gt 0) { $rx = [math]::Round($dRx * 8 / $dt / 1e6, 1) }
      if ($dTx -gt 0) { $tx = [math]::Round($dTx * 8 / $dt / 1e6, 1) }
    }
    $out[$alias] = @{ rx = $rx; tx = $tx }
  }
  $out
}

# Every sample carries every current path, so the graph's series stay aligned
# even before a slow adapter's first reading.
function Complete-RateTable {
  param([hashtable]$Rates, $Paths)
  foreach ($p in @($Paths)) { if (-not $Rates.ContainsKey($p.Alias)) { $Rates[$p.Alias] = @{ rx = 0; tx = 0 } } }
  $Rates
}

function Add-Sample {
  param($Series, $Sample, [int]$Max = 60)
  [void]$Series.Add($Sample)
  while ($Series.Count -gt $Max) { $Series.RemoveAt(0) }
}

function Find-MobileAlias {
  param($Paths, [string]$OverrideAlias)
  if ($OverrideAlias -and (@($Paths | Where-Object { $_.Alias -eq $OverrideAlias }).Count)) { return $OverrideAlias }
  $m = @($Paths | Where-Object { $_.Description -match $script:MobilePattern }) | Select-Object -First 1
  if ($m) { return $m.Alias }
  $null
}

function Get-CounterTable {
  param($Paths, $Poller)
  $t = @{}
  $want = @($Paths | ForEach-Object { [uint32]$_.InterfaceIndex })
  foreach ($i in $Poller.Tracked()) { if ($want -notcontains $i) { $Poller.Untrack($i) } }
  foreach ($p in @($Paths)) {
    $Poller.Track([uint32]$p.InterfaceIndex)
    $v = $Poller.Read([uint32]$p.InterfaceIndex)
    if ($v) { $t[$p.Alias] = @{ Rx = $v[0]; Tx = $v[1]; At = $v[2] } }
  }
  $t
}

function Update-Paths {
  param($State)
  $State.Paths = @(Get-Paths)
  $State.Mobile.Alias = Find-MobileAlias $State.Paths $State.Settings.mobileAlias
}

# Every second: adapter counters -> rates -> series, plus mobile session bytes.
# Paths are re-discovered every 10 s so plugging the phone in shows up.
function Start-Sampler {
  param($State)
  Start-BackgroundRunspace $State 'sampler' {
    $prev = $null; $prevAt = $null; $tick = 0
    while (-not $state.Stopping) {
      $started = [DateTime]::UtcNow
      if ($tick % 10 -eq 0) { Update-Paths $state }
      $curr = Get-CounterTable $state.Paths $state.IfPoller
      $now = [DateTime]::UtcNow
      if ($prev) {
        $rates = Complete-RateTable (Get-RateTable $prev $curr ($now - $prevAt).TotalSeconds $state.Rates) $state.Paths
        $state.Rates = $rates
        Add-Sample $state.Series @{ t = [long]($now - [DateTime]'1970-01-01').TotalMilliseconds; links = $rates } 60
        $m = $state.Mobile.Alias
        if ($m -and $prev.ContainsKey($m) -and $curr.ContainsKey($m)) {
          $d = ($curr[$m].Rx - $prev[$m].Rx) + ($curr[$m].Tx - $prev[$m].Tx)
          if ($d -gt 0) { $state.Mobile.SessionBytes += $d }
        }
        foreach ($hook in @('Update-Downloads', 'Update-Cap')) {
          if (Get-Command $hook -ErrorAction SilentlyContinue) {
            try { & $hook $state } catch { [void]$state.Log.Add(@{ t = $now.ToString('o'); text = "$hook failed: $($_.Exception.Message)"; level = 'bad' }) }
          }
        }
      }
      $prev = $curr; $prevAt = $now; $tick++
      $wait = 1000 - ([DateTime]::UtcNow - $started).TotalMilliseconds
      if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]$wait) }
    }
  } | Out-Null
}

# --- DTO ------------------------------------------------------------------------
function Get-SessionGB { param($State) [math]::Round($State.Mobile.SessionBytes / 1GB, 2) }

function Get-StateDto {
  param($State)
  $paths = @($State.Paths)
  $sepAgo = $null
  if ($State.Separation.checkedAt) { $sepAgo = [int]([DateTime]::UtcNow - [DateTime]$State.Separation.checkedAt).TotalSeconds }

  $best = $null; $bestScore = [double]::MaxValue
  $dtoPaths = foreach ($p in $paths) {
    $r = $State.Rates[$p.Alias]
    $lat = $State.Latency[$p.Alias]
    if ($lat -and $lat.avgMs -ne $null) {
      $score = [double]$lat.avgMs + [double]$(if ($lat.jitterMs -ne $null) { $lat.jitterMs } else { 0 })
      if ($score -lt $bestScore) { $bestScore = $score; $best = $p.Alias }
    }
    [ordered]@{
      alias = $p.Alias; ip = $p.IP; gateway = $p.Gateway; metric = $p.Metric
      autoMetric = ("$($p.Auto)" -eq 'Enabled'); isMobile = ($p.Alias -eq $State.Mobile.Alias)
      publicIp = $State.PublicIps[$p.Alias]
      rxMbps = $(if ($r) { $r.rx } else { 0 }); txMbps = $(if ($r) { $r.tx } else { 0 })
      latency = $lat
    }
  }
  $default = @($paths | Sort-Object Metric | Select-Object -First 1)
  $pref = @($paths | Where-Object { "$($_.Auto)" -ne 'Enabled' -and $_.Metric -eq 10 } | Select-Object -First 1)
  $baseline = $null
  if ($State.Settings.baselineMbps) { $baseline = @{ mbps = $State.Settings.baselineMbps; measuredAt = $State.Settings.baselineAt } }

  [ordered]@{
    isAdmin = [bool]$State.IsAdmin
    appMonitorMode = $State.AppMonitorMode
    paths = @($dtoPaths)
    separation = @{ status = $State.Separation.status; checkedAgoSec = $sepAgo }
    suggestedGamingLink = $best
    defaultRouteAlias = $(if ($default) { $default[0].Alias } else { $null })
    preferredAlias = $(if ($pref) { $pref[0].Alias } else { $null })
    mobile = @{ alias = $State.Mobile.Alias; sessionGB = (Get-SessionGB $State); capGB = $State.Settings.capGB; capHit = [bool]$State.CapHit }
    baseline = $baseline
    port = $State.Port
    defaultDir = (Join-Path $env:USERPROFILE 'Downloads')
  }
}
