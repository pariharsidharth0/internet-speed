<#
  reset-network.ps1 - undo every network change the multilink tools can make,
                      and optionally remove the tools themselves.

  SAFE BY DEFAULT. Running it with no arguments only *reports*: it compares your
  current settings against Windows defaults and prints what it would change.
  Nothing is modified until you add -Apply.

    .\reset-network.ps1                    report only (default, changes nothing)
    .\reset-network.ps1 -Apply             revert network settings to defaults
    .\reset-network.ps1 -Apply -RemoveTools  also uninstall aria2 + delete scripts

  WHAT IT REVERTS
    * Interface metrics  -> back to AutomaticMetric Enabled (undoes menu option 4)
    * NIC teams (LBFO)   -> removed if any exist
    * Temp working dirs  -> deleted

  WHAT IT DELIBERATELY DOES NOT TOUCH, and why
    * Hyper-V virtual adapters (vEthernet / Default Switch). These legitimately
      run with a manual metric; "fixing" them would break Hyper-V networking.
    * The Bridge Driver binding, or any other adapter binding. The multilink
      tools never change bindings, so anything set there predates them.
    * Your own static routes. It lists them so you can decide, but never deletes
      them - guessing which routes are yours would be reckless.
    * Windows "Metered connection" flags. There is no reliable cmdlet for these;
      the script tells you where to click instead.
    * Your phone's Wi-Fi setting. That lives on the phone, not on this PC.

  Linux equivalent: sudo ./multilink.sh undo
#>
[CmdletBinding()]
param(
  [switch]$Apply,
  [switch]$RemoveTools
)

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

# Virtual / pseudo adapters must be left alone. Matching on the *description*
# rather than the name, because users rename connections.
$SkipPattern = 'Hyper-V|Virtual|Loopback|WAN Miniport|Bluetooth|Kernel Debug|Teredo|IP-HTTPS|RAS Async|6to4|ISATAP'

function Get-RealInterfaces {
  Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object {
    $ad = Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue
    if (-not $ad) { return }
    if ($ad.InterfaceDescription -match $SkipPattern) { return }
    [pscustomobject]@{
      Alias       = $_.InterfaceAlias
      Description = $ad.InterfaceDescription
      Metric      = $_.InterfaceMetric
      Automatic   = $_.AutomaticMetric
      State       = $_.ConnectionState
    }
  }
}

$mode = if ($Apply) { "APPLY" } else { "REPORT ONLY" }
Say ""
Info "===== reset-network.ps1  [$mode] ====="
if (-not $Apply) { Dim "Nothing will be modified. Re-run with -Apply to actually revert." }
Say ""

# ---------------------------------------------------------------- 1. metrics
Info "1. Interface metrics"
$ifs = @(Get-RealInterfaces)
if ($ifs.Count -eq 0) { Warn "   no physical interfaces found" }
$toFix = @($ifs | Where-Object { $_.Automatic -ne 'Enabled' })
foreach ($i in $ifs) {
  $tag = if ($i.Automatic -eq 'Enabled') { "default (ok)" } else { "MANUAL - would be reverted" }
  "   {0,-16} metric {1,-6} automatic={2,-9} {3}" -f $i.Alias, $i.Metric, $i.Automatic, $tag | Say
}
if ($toFix.Count -eq 0) {
  Good "   All physical interfaces already on automatic metrics. Nothing to undo."
} elseif ($Apply) {
  foreach ($i in $toFix) {
    foreach ($fam in @('IPv4','IPv6')) {
      try {
        Set-NetIPInterface -InterfaceAlias $i.Alias -AddressFamily $fam -AutomaticMetric Enabled -ErrorAction Stop
        Good ("   restored {0} ({1}) to automatic" -f $i.Alias, $fam)
      } catch {
        $msg = $_.Exception.Message.Split("`n")[0]
        if ($msg -match 'Access is denied') { Fail "   $($i.Alias) ($fam): needs an elevated shell" }
        else { Dim "   $($i.Alias) ($fam): $msg" }
      }
    }
  }
} else {
  Warn ("   {0} interface(s) would be reverted to automatic metrics." -f $toFix.Count)
}
Say ""

# ------------------------------------------------------------------ 2. teams
Info "2. NIC teams (LBFO)"
$teams = @(Get-NetLbfoTeam -ErrorAction SilentlyContinue)
if ($teams.Count -eq 0) {
  Good "   None. (Expected - Windows client editions cannot create them.)"
} elseif ($Apply) {
  foreach ($t in $teams) {
    try { Remove-NetLbfoTeam -Name $t.Name -Confirm:$false -ErrorAction Stop; Good "   removed team $($t.Name)" }
    catch { Fail "   $($t.Name): $($_.Exception.Message.Split("`n")[0])" }
  }
} else {
  foreach ($t in $teams) { Warn "   would remove team: $($t.Name)" }
}
Say ""

# ----------------------------------------------------------------- 3. routes
Info "3. Static routes (listed only - never auto-deleted)"
$pr = @(Get-NetRoute -PolicyStore PersistentStore -ErrorAction SilentlyContinue |
        Where-Object { $_.DestinationPrefix -notin @('0.0.0.0/0','::/0') })
if ($pr.Count -eq 0) {
  Good "   No persistent custom routes. Nothing was left behind."
} else {
  Warn "   Persistent routes exist. Review them; delete manually if unwanted:"
  foreach ($r in $pr) {
    "     {0,-20} via {1,-16} on {2}" -f $r.DestinationPrefix, $r.NextHop, $r.InterfaceAlias | Say
  }
  Dim  "     Remove one with:  Remove-NetRoute -DestinationPrefix <prefix> -Confirm:`$false"
}
Say ""

# ------------------------------------------------------------- 4. temp files
Info "4. Temporary working directories"
$tmp = @(Get-ChildItem $env:TEMP -Directory -ErrorAction SilentlyContinue |
         Where-Object { $_.Name -match '^(bondtest|fastdl-test|splittest|tmtest|ml-check|ml-def|ml-restore|ml-it|ml-shot-profile|ipcheck|docverify|ispack|mlxfer)$' })
if ($tmp.Count -eq 0) {
  Good "   None left."
} elseif ($Apply) {
  foreach ($t in $tmp) { Remove-Item $t.FullName -Recurse -Force -ErrorAction SilentlyContinue; Good "   deleted $($t.Name)" }
} else {
  foreach ($t in $tmp) { Warn "   would delete $($t.FullName)" }
}
Say ""

# ------------------------------------------------------- 5. console leftovers
# The console's per-app monitor runs an ETW session; it is stopped when the
# console exits, but a crash can leave it running.
Info "5. Console leftovers"
$etw = (& logman query MultilinkNetMon -ets 2>&1 | Out-String) -notmatch 'not found|cannot find'
if (-not $etw) {
  Good "   No monitor session left running."
} elseif ($Apply) {
  & logman stop MultilinkNetMon -ets 2>&1 | Out-Null
  Good "   stopped leftover monitor session MultilinkNetMon"
} else {
  Warn "   would stop leftover monitor session MultilinkNetMon"
}
Say ""

# ------------------------------------------------------------------ 6. tools
Info "6. Tools and scripts"
$aria = "$env:LOCALAPPDATA\Microsoft\WinGet\Links\aria2c.exe"
$files = @("$env:USERPROFILE\multilink.ps1", "$env:USERPROFILE\fastdl.ps1",
           (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Multilink.lnk'))
$settingsDir = Join-Path $env:LOCALAPPDATA 'multilink'
$ariaThere = Test-Path $aria
$filesThere = @($files | Where-Object { Test-Path $_ })
"   aria2 installed : $(if ($ariaThere) {'yes'} else {'no'})" | Say
"   loose scripts / desktop shortcut: $($filesThere.Count)" | Say
"   console settings folder: $(if (Test-Path $settingsDir) {'yes'} else {'no'})" | Say
Dim  "   (the Desktop 'internet speed' folder is left alone - delete it yourself if you want)"
if (-not $RemoveTools) {
  Dim "   Add -RemoveTools to uninstall aria2 and delete the loose home-folder scripts."
} elseif ($Apply) {
  foreach ($f in $filesThere) { Remove-Item $f -Force -ErrorAction SilentlyContinue; Good "   deleted $f" }
  if (Test-Path $settingsDir) { Remove-Item $settingsDir -Recurse -Force -ErrorAction SilentlyContinue; Good "   deleted $settingsDir" }
  if ($ariaThere) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
      Info "   uninstalling aria2..."
      winget uninstall --id aria2.aria2 --disable-interactivity 2>&1 | Out-Null
      Good "   aria2 uninstalled: $(-not (Test-Path $aria))"
    } else { Warn "   winget unavailable - remove aria2 manually" }
  }
} else {
  Warn "   would delete $($filesThere.Count) file(s), the console settings folder, and uninstall aria2"
}
Say ""

# ------------------------------------------------------------------ 7. manual
Info "7. Things only you can undo"
Say  "   * Metered connection flag:  Settings > Network & Internet > <adapter> >"
Say  "     Metered connection.  No reliable cmdlet exists for this."
Say  "   * Your phone's Wi-Fi / USB tethering toggles live on the phone."
Say  "   * Apps hold connections on whichever link they started on. After changing"
Say  "     metrics, restart browsers / Steam / sync tools so they move over."
Say ""

if ($Apply) {
  Info "===== Final state ====="
  Get-RealInterfaces | ForEach-Object {
    "   {0,-16} metric {1,-6} automatic={2}" -f $_.Alias, $_.Metric, $_.Automatic | Say
  }
  "   LBFO teams: $((Get-NetLbfoTeam -ErrorAction SilentlyContinue | Measure-Object).Count)" | Say
  Say ""
  if (-not (Test-Admin)) {
    Warn "You were NOT running elevated, so metric and team changes were skipped."
    Warn "Re-run from an admin PowerShell to complete the reset."
  } else {
    Good "Reset complete."
  }
} else {
  Dim "Report finished. Re-run with -Apply (in an admin shell) to make these changes."
}
